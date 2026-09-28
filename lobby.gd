class_name LocalNetLobby
extends RefCounted
## Players gather, choose things and start together.
##
## The host owns the member list, shared settings and the start time. Clients ping the
## host several times a second and keep an estimate of the host's clock, so a start time
## the host picks becomes the same wall-clock moment on every device.
## Control messages are JSON over the reliable channel; pings are binary and unreliable.
## Call [method poll] every frame.

signal members_changed
signal joined(id: int)
signal rejected(reason: String)
signal closed(reason: String)
signal member_left(id: int)
## [param start_usec] is on this device's [method Time.get_ticks_usec] clock.
signal started(config: Dictionary, start_usec: int)

const KIND_PING := 1
const KIND_PONG := 2
const PING_INTERVAL_USEC := 250_000
const CLOCK_SAMPLES := 16
## A client counts as synced after this many pings.
const SYNCED_AFTER := 5
const START_DELAY_USEC := 1_500_000

var link := LocalNetLink.new()
var game_id: String
var version: int
var is_host := false
var local_id := 0
var max_players := 2
var session_id := ""
var session_name := ""
var members := {}
var config := {}
## idle, joining, lobby, started or closed.
var state := "idle"

## Host clock minus this device's clock, from the fastest recent ping.
var clock_offset_usec := 0
var clock_rtt_usec := 0

var _join_code_hash := ""
var _name := ""
var _samples := []
var _next_ping_usec := 0
var _reported_synced := false


func _init(game: String, game_version: int) -> void:
	game_id = game
	version = game_version
	link.peer_connected.connect(_on_peer_connected)
	link.peer_disconnected.connect(_on_peer_disconnected)
	link.received.connect(_on_received)
	link.connect_failed.connect(_on_connect_failed)


func host(player_name: String, players := 2, join_code := "") -> Error:
	# Spare peer slots let the host explain a rejection before disconnecting.
	var err := link.host(0, players + 2)
	if err != OK:
		return err
	is_host = true
	local_id = LocalNetLink.HOST_ID
	max_players = players
	session_id = "%08x%08x" % [randi(), randi()]
	session_name = player_name
	_join_code_hash = _hash_code(join_code)
	members = {local_id: _member(player_name, 0)}
	members[local_id].synced = true
	state = "lobby"
	members_changed.emit()
	return OK


func join(address: String, port: int, player_name: String, join_code := "") -> Error:
	var err := link.join(address, port)
	if err != OK:
		return err
	is_host = false
	_name = player_name
	_join_code_hash = _hash_code(join_code)
	_samples.clear()
	_reported_synced = false
	state = "joining"
	return OK


func leave() -> void:
	link.close()
	state = "closed"


func poll() -> void:
	link.poll()
	if not is_host and state in ["lobby", "started"] and link.is_open():
		var now := Time.get_ticks_usec()
		if now >= _next_ping_usec:
			_next_ping_usec = now + PING_INTERVAL_USEC
			var ping := PackedByteArray([KIND_PING])
			ping.resize(9)
			ping.encode_s64(1, now)
			link.send(LocalNetLink.HOST_ID, LocalNetLink.CHANNEL_REALTIME, ping, false)
	link.flush()


## What discovery should tell scanners about this session.
func advert() -> Dictionary:
	return {"id": session_id, "name": session_name, "port": link.port, "players": members.size(), "max": max_players, "state": state, "code": _join_code_hash != ""}


func set_ready(ready: bool) -> void:
	_update_self({"ready": ready})


func set_data(data: Dictionary) -> void:
	_update_self({"data": data})


## Host only: shared settings every member sees, such as stage or rules.
func set_config(values: Dictionary) -> void:
	if is_host:
		config = values.duplicate(true)
		_broadcast_members()


func can_start(require_ready := false) -> bool:
	if not is_host or state != "lobby" or members.size() < 2:
		return false
	for member in members.values():
		if not member.synced or (require_ready and not member.ready):
			return false
	return true


## Host only: numbers the slots in join order and starts everyone at the same moment.
func start() -> void:
	if not is_host or state != "lobby":
		return
	state = "started"
	var ids := members.keys()
	ids.sort()
	for i in ids.size():
		members[ids[i]].slot = i
	_broadcast_members()
	var start_at := Time.get_ticks_usec() + START_DELAY_USEC
	_send_all({"t": "start", "config": config, "start_at": start_at})
	link.flush()
	started.emit(config, start_at)


func local_slot() -> int:
	return members[local_id].slot if members.has(local_id) else -1


## Which slot each link peer sends. Clients only hear from the host, which relays.
func peer_slots() -> Dictionary:
	if not is_host:
		return {LocalNetLink.HOST_ID: -1}
	var slots := {}
	for id in members:
		if id != local_id:
			slots[id] = members[id].slot
	return slots


func host_to_local_usec(host_usec: int) -> int:
	return host_usec - clock_offset_usec


func _member(player_name: String, slot: int) -> Dictionary:
	return {"name": player_name, "slot": slot, "ready": false, "synced": false, "data": {}}


func _update_self(values: Dictionary) -> void:
	if is_host:
		members[local_id].merge(values, true)
		_broadcast_members()
	elif state in ["lobby", "started"]:
		var message := {"t": "member"}
		message.merge(values)
		_send(LocalNetLink.HOST_ID, message)
		link.flush()


func _on_peer_connected(id: int) -> void:
	if not is_host:
		_send(id, {"t": "hello", "game": game_id, "v": version, "name": _name, "code": _join_code_hash})
		link.flush()


func _on_peer_disconnected(id: int) -> void:
	if not is_host:
		if state != "closed":
			state = "closed"
			closed.emit("The host left")
		return
	if members.has(id):
		members.erase(id)
		member_left.emit(id)
		_broadcast_members()


func _on_connect_failed() -> void:
	state = "closed"
	closed.emit("Couldn't reach the host")


func _on_received(id: int, channel: int, bytes: PackedByteArray) -> void:
	if channel == LocalNetLink.CHANNEL_CONTROL:
		var message = JSON.parse_string(bytes.get_string_from_utf8())
		if message is Dictionary:
			if is_host:
				_host_message(id, message)
			else:
				_client_message(message)
	elif channel == LocalNetLink.CHANNEL_REALTIME and bytes.size() > 0:
		if bytes[0] == KIND_PING and is_host and bytes.size() >= 9:
			var pong := PackedByteArray([KIND_PONG])
			pong.resize(17)
			pong.encode_s64(1, bytes.decode_s64(1))
			pong.encode_s64(9, Time.get_ticks_usec())
			link.send(id, LocalNetLink.CHANNEL_REALTIME, pong, false)
			link.flush()
		elif bytes[0] == KIND_PONG and not is_host and bytes.size() >= 17:
			_clock_sample(bytes.decode_s64(1), bytes.decode_s64(9), Time.get_ticks_usec())


func _host_message(id: int, message: Dictionary) -> void:
	match message.get("t"):
		"hello":
			var reason := ""
			if message.get("game") != game_id:
				reason = "Different game"
			elif int(message.get("v", -1)) != version:
				reason = "Different version (host has v%d)" % version
			elif _join_code_hash != "" and message.get("code") != _join_code_hash:
				reason = "Wrong join code"
			elif state != "lobby":
				reason = "Already playing"
			elif members.size() >= max_players:
				reason = "Lobby is full"
			if reason != "":
				_send(id, {"t": "reject", "reason": reason})
				link.kick(id)
				return
			members[id] = _member(str(message.get("name", "Player")).left(24), _free_slot())
			_send(id, {"t": "welcome", "id": id})
			_broadcast_members()
		"member":
			if members.has(id):
				for key in ["ready", "synced", "data"]:
					if message.has(key):
						members[id][key] = message[key]
				_broadcast_members()


func _client_message(message: Dictionary) -> void:
	match message.get("t"):
		"welcome":
			local_id = int(message.id)
			state = "lobby"
			joined.emit(local_id)
		"reject":
			state = "closed"
			link.close()
			rejected.emit(str(message.get("reason", "Rejected")))
		"lobby":
			members = {}
			for key in message.members:
				var member: Dictionary = message.members[key]
				member.slot = int(member.slot)
				members[int(key)] = member
			config = message.get("config", {})
			session_name = str(message.get("name", ""))
			members_changed.emit()
		"start":
			config = message.get("config", {})
			state = "started"
			started.emit(config, host_to_local_usec(int(message.start_at)))


func _clock_sample(sent: int, host_time: int, now: int) -> void:
	_samples.append([now - sent, host_time - ((sent + now) >> 1)])
	if _samples.size() > CLOCK_SAMPLES:
		_samples.pop_front()
	# The fastest round trip has the least room for one-sided delay.
	var best: Array = _samples[0]
	for sample in _samples:
		if sample[0] < best[0]:
			best = sample
	clock_rtt_usec = best[0]
	clock_offset_usec = best[1]
	if not _reported_synced and _samples.size() >= SYNCED_AFTER:
		_reported_synced = true
		_update_self({"synced": true})


func _free_slot() -> int:
	var used := members.values().map(func(m): return m.slot)
	var slot := 0
	while used.has(slot):
		slot += 1
	return slot


func _broadcast_members() -> void:
	members_changed.emit()
	if is_host:
		_send_all({"t": "lobby", "members": members, "config": config, "name": session_name})
		link.flush()


func _send(id: int, message: Dictionary) -> void:
	link.send(id, LocalNetLink.CHANNEL_CONTROL, JSON.stringify(message).to_utf8_buffer(), true)


func _send_all(message: Dictionary) -> void:
	var bytes := JSON.stringify(message).to_utf8_buffer()
	for id in members:
		if id != local_id:
			link.send(id, LocalNetLink.CHANNEL_CONTROL, bytes, true)


static func _hash_code(code: String) -> String:
	return "" if code.strip_edges() == "" else code.strip_edges().sha256_text()
