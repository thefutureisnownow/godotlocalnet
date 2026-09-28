class_name LocalNetLobby
extends RefCounted
## Players gather, choose things, load and start together, then return for a rematch.
##
## The host owns the member list, shared settings and the start time. Clients ping the
## host several times a second and keep an estimate of the host's clock, so a start time
## the host picks becomes the same wall-clock moment on every device. The pings also say
## how steady each link is, which [method suggested_delay] turns into an input delay.
##
## Control messages are Godot variants ([method @GlobalScope.var_to_bytes], decoded without
## objects) over the reliable channel, so numbers and vectors keep their types. Pings are
## binary and unreliable. Call [method poll] every frame.

signal members_changed
signal joined(id: int)
signal rejected(reason: String)
signal closed(reason: String)
signal member_left(id: int)
## With [member wait_for_loading]: load the match, then call [method mark_loaded].
signal preparing(config: Dictionary)
## [param start_usec] is on this device's [method Time.get_ticks_usec] clock.
signal started(config: Dictionary, start_usec: int)
## The host ended the match; everyone is back in the lobby.
signal returned

const KIND_PING := 1
const KIND_PONG := 2
const PING_INTERVAL_USEC := 250_000
const CLOCK_SAMPLES := 16
## Round trips kept for judging how steady the link is.
const LINK_SAMPLES := 40
## A client counts as synced after this many pings.
const SYNCED_AFTER := 5
const START_DELAY_USEC := 1_000_000

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
## idle, joining, lobby, preparing, started or closed.
var state := "idle"
## When true, [method start] first sends everyone [signal preparing] and waits until
## every member calls [method mark_loaded].
var wait_for_loading := false

## Host clock minus this device's clock, from the fastest recent ping.
var clock_offset_usec := 0
var clock_rtt_usec := 0

var _join_code_hash := ""
var _name := ""
var _samples := []
var _round_trips := PackedInt64Array()
var _next_ping_usec := 0
var _reported_synced := false


func _init(game: String, game_version: int) -> void:
	game_id = game
	version = game_version
	link.peer_connected.connect(_on_peer_connected)
	link.peer_disconnected.connect(_on_peer_disconnected)
	link.received.connect(_on_received)
	link.connect_failed.connect(_on_connect_failed)


## Opens a lobby. [param port] 0 lets the system pick a free game port.
func host(player_name: String, players := 2, join_code := "", port := 0) -> Error:
	# Spare peer slots let the host explain a rejection before disconnecting.
	var err := link.host(port, players + 2)
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
	_round_trips.clear()
	_reported_synced = false
	state = "joining"
	return OK


func leave() -> void:
	link.close()
	state = "closed"


func poll() -> void:
	link.poll()
	if not is_host and state in ["lobby", "preparing", "started"] and link.is_open():
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


## Host only: numbers the slots in join order, then starts everyone at the same moment
## (after everyone has loaded, with [member wait_for_loading]).
func start() -> void:
	if not is_host or state != "lobby":
		return
	var ids := members.keys()
	ids.sort()
	for i in ids.size():
		members[ids[i]].slot = i
		members[ids[i]].loaded = false
	if not wait_for_loading:
		_go()
		return
	state = "preparing"
	_broadcast_members()
	_send_all({"t": "prepare", "config": config})
	link.flush()
	preparing.emit(config)


## Tells the host this device has loaded the match. See [member wait_for_loading].
func mark_loaded() -> void:
	if state != "preparing":
		return
	if is_host:
		members[local_id].loaded = true
		_start_when_loaded()
	else:
		_send(LocalNetLink.HOST_ID, {"t": "member", "loaded": true})
		link.flush()


## Host only: ends the match and brings everyone back for a rematch. Ready flags reset.
func return_to_lobby() -> void:
	if not is_host or state not in ["preparing", "started"]:
		return
	state = "lobby"
	for member in members.values():
		member.ready = false
		member.loaded = false
	_broadcast_members()
	_send_all({"t": "return"})
	link.flush()
	returned.emit()


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


## An input delay in ticks that covers most of the link's jitter: half the slowest
## member's 90th-percentile round trip plus [param margin_msec] for frame timing.
## On a phone hotspot this comes to about 3 ticks at 120 Hz.
func suggested_delay(tick_rate := 120, margin_msec := 12.0, min_ticks := 2, max_ticks := 12) -> int:
	var worst := 0
	if is_host:
		for member in members.values():
			worst = maxi(worst, member.get("net", {}).get("rtt_p90_usec", 0))
	else:
		worst = _round_trip_percentile(90)
	var msec := worst / 2000.0 + margin_msec
	return clampi(ceili(msec * tick_rate / 1000.0), min_ticks, max_ticks)


func _member(player_name: String, slot: int) -> Dictionary:
	return {"name": player_name, "slot": slot, "ready": false, "synced": false, "loaded": false, "data": {}, "net": {}}


func _update_self(values: Dictionary) -> void:
	if is_host:
		members[local_id].merge(values, true)
		_broadcast_members()
	elif state in ["lobby", "preparing", "started"]:
		var message := {"t": "member"}
		message.merge(values)
		_send(LocalNetLink.HOST_ID, message)
		link.flush()


func _go() -> void:
	state = "started"
	_broadcast_members()
	var start_at := Time.get_ticks_usec() + START_DELAY_USEC
	_send_all({"t": "start", "config": config, "start_at": start_at})
	link.flush()
	started.emit(config, start_at)


func _start_when_loaded() -> void:
	if state != "preparing":
		return
	for member in members.values():
		if not member.loaded:
			_broadcast_members()
			return
	_go()


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
		_start_when_loaded()


func _on_connect_failed() -> void:
	state = "closed"
	closed.emit("Couldn't reach the host")


func _on_received(id: int, channel: int, bytes: PackedByteArray) -> void:
	if channel == LocalNetLink.CHANNEL_CONTROL:
		var message = bytes_to_var(bytes)
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
			elif message.get("v") != version:
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
				for key in ["ready", "synced", "loaded", "data", "net"]:
					if message.has(key):
						members[id][key] = message[key]
				_broadcast_members()
				if message.has("loaded"):
					_start_when_loaded()


func _client_message(message: Dictionary) -> void:
	match message.get("t"):
		"welcome":
			local_id = message.id
			state = "lobby"
			joined.emit(local_id)
		"reject":
			state = "closed"
			link.close()
			rejected.emit(str(message.get("reason", "Rejected")))
		"lobby":
			members = message.members
			config = message.config
			session_name = message.name
			members_changed.emit()
		"prepare":
			config = message.config
			state = "preparing"
			preparing.emit(config)
		"start":
			config = message.config
			state = "started"
			started.emit(config, host_to_local_usec(message.start_at))
		"return":
			state = "lobby"
			returned.emit()


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
	_round_trips.append(now - sent)
	if _round_trips.size() > LINK_SAMPLES:
		_round_trips.remove_at(0)
	if not _reported_synced and _samples.size() >= SYNCED_AFTER:
		_reported_synced = true
		_update_self({"synced": true, "net": _link_quality()})
	elif state == "lobby" and _round_trips.size() % 8 == 0:
		_update_self({"net": _link_quality()})


func _link_quality() -> Dictionary:
	return {"rtt_p50_usec": _round_trip_percentile(50), "rtt_p90_usec": _round_trip_percentile(90), "rtt_max_usec": _round_trip_percentile(100)}


func _round_trip_percentile(p: float) -> int:
	if _round_trips.is_empty():
		return 0
	var sorted := _round_trips.duplicate()
	sorted.sort()
	return sorted[clampi(ceili(p / 100.0 * sorted.size()) - 1, 0, sorted.size() - 1)]


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
	link.send(id, LocalNetLink.CHANNEL_CONTROL, var_to_bytes(message), true)


func _send_all(message: Dictionary) -> void:
	var bytes := var_to_bytes(message)
	for id in members:
		if id != local_id:
			link.send(id, LocalNetLink.CHANNEL_CONTROL, bytes, true)


static func _hash_code(code: String) -> String:
	return "" if code.strip_edges() == "" else code.strip_edges().sha256_text()
