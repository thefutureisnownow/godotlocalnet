class_name LocalNetLobby
extends RefCounted
## Players gather, choose things, load and start together, then return for a rematch.
##
## The host owns the member list, shared settings and the start time. Clients ping the
## host several times a second and keep an estimate of the host's clock, so a start time
## the host picks becomes the same wall-clock moment on every device. The pings also say
## how steady each link is, and every member reports how long its frames take; together
## [method suggested_delay] turns them into an input delay.
##
## Dropped connections: when a guest's link drops, the host keeps its place (see
## [member LocalNetLink.reconnect_window_msec]), marks it not [code]connected[/code] and
## emits [signal member_interrupted] everywhere, while the guest emits
## [signal connection_interrupted] and keeps reconnecting. When it's back, everyone gets
## [signal member_resumed] and the guest [signal connection_resumed]; the host then
## brings it up to date, including a start or return it missed. If the window runs out,
## the host emits [signal member_left] and the guest [signal closed]. The host sets the
## window ([member reconnect_window_msec]) and every guest follows it; either side can
## stop waiting early with [method give_up].
##
## Members are players or spectators ([member max_spectators]). Spectators have no slot
## (-1) and don't hold up players: they don't count towards [member max_players], the
## two players [method can_start] needs or [method suggested_delay], and need no ready flag.
## Only their clock sync, and with [member wait_for_loading] their loading and so the content
## they load, are waited for, so they can follow the match from its first tick. A spectator
## whose connection has dropped isn't waited for.
## A host can also stay out of the match itself ([code]host_plays[/code] in [method host]),
## as a PC driving a big screen while phones play: its member is then a spectator too.
## Roles are a lobby matter only; how a game keeps its spectators' state up to date is its
## own business ([LocalNetInputSync] relays inputs to them for lockstep games).
##
## Control messages are Godot variants ([method @GlobalScope.var_to_bytes], decoded without
## objects) over the reliable channel, so numbers and vectors keep their types. Pings are
## binary and unreliable. Call [method poll] every frame.

signal members_changed
signal joined(id: int)
signal rejected(reason: String)
signal closed(reason: String)
## [param reason] is "left", "kicked" or "lost".
signal member_left(id: int, reason: String)
## A member's connection dropped; the host is holding their place.
signal member_interrupted(id: int)
signal member_resumed(id: int)
## Guest only: the link to the host dropped and it's reconnecting.
signal connection_interrupted
signal connection_resumed
## With [member wait_for_loading]: load the match, then call [method mark_loaded].
signal preparing(config: Dictionary)
## [param start_usec] is on this device's [method Time.get_ticks_usec] clock.
signal started(config: Dictionary, start_usec: int)
## The host ended the match; everyone is back in the lobby.
signal returned

const KIND_PING := 1
const KIND_PONG := 2
## Guests ping this often in the lobby, about as often as a match sends inputs. Phones put
## a quiet Wi-Fi radio into power save, where packets wait for a beacon or three (100 to
## 300 ms), and only wake it fully for steady traffic. Pinging four or ten times a second
## let it nap: the first match was judged from slow pings and still stalled for a second
## as the radio woke up. At this rate it's awake before the match starts.
const PING_INTERVAL_USEC := 16_000
const CLOCK_SAMPLES := 16
## Round trips kept for judging how steady the link is: two seconds' worth.
const LINK_SAMPLES := 120
## Round trips in the first moments after joining are left out of that, while the radio
## wakes up to the pings.
const RADIO_WAKE_USEC := 1_000_000
## How often a guest reports its link quality to the host.
const REPORT_EVERY_USEC := 1_000_000
## A round trip that waited on a frame longer than this at either end measures the device,
## not the network (a host loading its next screen answers pings only between long frames),
## so it's left out of the link quality.
const HITCH_USEC := 50_000
## A client counts as synced, and can be started, once it has this many clock readings and
## LINK_READY round trips measured after the radio woke: a match can't start on a guess.
const SYNCED_AFTER := 5
const LINK_READY := 30
## Frames timed for [method frame_usec], and the longest gap still counted as a frame
## (longer ones are loading or a paused app, not the frame rate).
const FRAME_SAMPLES := 60
const LONGEST_FRAME_USEC := 100_000
## How often the host reports its own frame time while in the lobby.
const HOST_REPORT_USEC := 1_000_000
const START_DELAY_USEC := 1_000_000
## LocalNet's own wire version, sent in [code]hello[/code] apart from the game's version,
## along with the oldest version this one still works with ([constant WIRE_VERSION_MIN]).
## A host lets a guest in when their ranges overlap, and turns it away otherwise, since the
## two would misread each other. Additive changes, which an older peer can do without,
## raise [constant WIRE_VERSION] only; breaking ones raise [constant WIRE_VERSION_MIN] too.
## Each member's version is kept under its member's [code]"ln"[/code] key, so a feature
## added later can check who has it.
const WIRE_VERSION := 3
const WIRE_VERSION_MIN := 3
const PLAYER := "player"
const SPECTATOR := "spectator"

var link := LocalNetLink.new()
var game_id: String
var version: int
var is_host := false
var local_id := 0
var max_players := 2
## How many guests may join to watch. 0 turns spectators away. Set it before [method host]:
## the link makes room for them then.
var max_spectators := 0
var session_id := ""
var session_name := ""
var members := {}
var config := {}
## idle, joining, lobby, preparing, started or closed.
var state := "idle"
## How long a dropped member may take to reconnect. Set it on the host; guests follow.
## 0 turns reconnecting off, [constant LocalNetLink.WAIT_FOREVER] waits until [method give_up].
var reconnect_window_msec := 30_000:
	set(value):
		reconnect_window_msec = value
		link.reconnect_window_msec = value
		if is_host and state != "idle":
			_broadcast_members()
## When true, [method start] first sends everyone [signal preparing] and waits until
## every member calls [method mark_loaded]. Spectators whose connection has dropped
## aren't waited for. Since connected spectators are, [method can_start] then waits for
## their content too.
var wait_for_loading := false
## Content the match needs, as [LocalNetContent] items: the host sets it with
## [method LocalNetContent.require] and every member hears it with the member list.
var needed_content := []

## Host clock minus this device's clock, from the fastest recent ping.
var clock_offset_usec := 0
var clock_rtt_usec := 0

var _join_code_hash := ""
var _name := ""
var _samples := []
var _round_trips := PackedInt64Array()
var _joined_usec := 0
var _next_report_usec := 0
var _next_ping_usec := 0
var _reported_synced := false
var _last_poll_usec := 0
## How long the frame before this poll took: how long a packet could have waited unread.
var _frame_gap_usec := 0
var _frames := PackedInt32Array()
var _next_host_report_usec := 0
var _start_at := 0
var _role := PLAYER
var _needed_key := ""
# Counts the sessions this lobby has opened with [method host] or [method join], so
# [LocalNetContent] can tell a new one from the last.
var _session := 0


func _init(game: String, game_version: int) -> void:
	game_id = game
	version = game_version
	link.peer_connected.connect(_on_peer_connected)
	link.peer_interrupted.connect(_on_peer_interrupted)
	link.peer_resumed.connect(_on_peer_resumed)
	link.peer_disconnected.connect(_on_peer_disconnected)
	link.received.connect(_on_received)
	link.connect_failed.connect(_on_connect_failed)
	link.reconnect_window_msec = reconnect_window_msec


## Opens a lobby. [param port] 0 lets the system pick a free game port. With
## [param host_plays] false the host takes no slot and watches as a spectator, while
## [param players] guests play.
func host(player_name: String, players := 2, join_code := "", port := 0, host_plays := true) -> Error:
	# Spare peer slots let the host explain a rejection before disconnecting.
	var err := link.host(port, players + max_spectators + 2)
	if err != OK:
		return err
	is_host = true
	_session += 1
	local_id = LocalNetLink.HOST_ID
	max_players = players
	session_id = "%08x%08x" % [randi(), randi()]
	session_name = player_name
	_join_code_hash = _hash_code(join_code)
	members = {local_id: _member(player_name, 0, PLAYER) if host_plays else _member(player_name, -1, SPECTATOR)}
	needed_content = []
	_needed_key = ""
	members[local_id].synced = true
	state = "lobby"
	members_changed.emit()
	return OK


## Joins the host at [param address]. [param role] is "player", or "spectator" to watch
## (the host must allow it with [member max_spectators]).
func join(address: String, port: int, player_name: String, join_code := "", role := PLAYER) -> Error:
	var err := link.join(address, port)
	if err != OK:
		return err
	is_host = false
	_session += 1
	_name = player_name
	_role = SPECTATOR if role == SPECTATOR else PLAYER
	needed_content = []
	_needed_key = ""
	_join_code_hash = _hash_code(join_code)
	_samples.clear()
	_round_trips.clear()
	_joined_usec = Time.get_ticks_usec()
	_reported_synced = false
	state = "joining"
	return OK


func leave() -> void:
	link.close()
	state = "closed"


func poll() -> void:
	_time_frame()
	link.poll()
	if is_host and state == "lobby" and link.is_open() and Time.get_ticks_usec() >= _next_host_report_usec and not _frames.is_empty():
		_next_host_report_usec = Time.get_ticks_usec() + HOST_REPORT_USEC
		var net: Dictionary = members[local_id].net if members.has(local_id) else {}
		var reported: int = net.get("frame_usec", 0)
		if not net.has("frame_usec") or absi(frame_usec() - reported) > maxi(1000, reported / 10):
			_update_self({"net": {"frame_usec": frame_usec()}})
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
	return {"id": session_id, "name": session_name, "port": link.port, "players": players().size(), "max": max_players, "spectators": _watching_guests(), "max_spectators": max_spectators, "state": state, "code": _join_code_hash != ""}


## Member ids of the players, in join order.
func players() -> Array:
	return _ids_with_role(PLAYER)


## Member ids of the spectators, in join order, including a host that doesn't play.
func spectators() -> Array:
	return _ids_with_role(SPECTATOR)


## True when member [param id] (this device by default) watches rather than plays.
func is_spectator(id := -1) -> bool:
	var member: Dictionary = members.get(local_id if id == -1 else id, {})
	return member.get("role", PLAYER) == SPECTATOR


func set_ready(ready: bool) -> void:
	_update_self({"ready": ready})


func set_data(data: Dictionary) -> void:
	_update_self({"data": data})


## Host only: shared settings every member sees, such as stage or rules.
func set_config(values: Dictionary) -> void:
	if is_host:
		config = values.duplicate(true)
		_broadcast_members()


## Host only: whether [method start] can go ahead: two players or more, every player
## connected and synced (with [param require_ready], ready too; with [param require_content],
## holding all the [member needed_content]). Spectators only need a synced clock, so they
## can follow the start, unless their connection has dropped. With
## [member wait_for_loading] and [param require_content], connected spectators need the
## content too: the start waits for them to load it, and transfers pause once it begins.
func can_start(require_ready := false, require_content := false) -> bool:
	if not is_host or state != "lobby" or players().size() < 2:
		return false
	for member in members.values():
		var watching: bool = member.get("role", PLAYER) == SPECTATOR
		if watching and not member.connected and not member.synced:
			continue
		if not member.synced:
			return false
		if watching:
			if wait_for_loading and member.connected and require_content and not _holds_content(member):
				return false
			continue
		if not member.connected or (require_ready and not member.ready):
			return false
		if require_content and not _holds_content(member):
			return false
	return true


func _holds_content(member: Dictionary) -> bool:
	if needed_content.is_empty():
		return true
	var content: Dictionary = member.get("content", {})
	return content.get("need") == _needed_key and content.get("missing", 1) == 0


## Host only: numbers the players' slots in join order, then starts everyone at the same
## moment (after everyone has loaded, with [member wait_for_loading]).
func start() -> void:
	if not is_host or state != "lobby":
		return
	var ids := players()
	for i in ids.size():
		members[ids[i]].slot = i
	for id in members:
		members[id].loaded = false
	if not wait_for_loading:
		_go()
		return
	state = "preparing"
	_broadcast_members()
	_send_all({"t": "prepare", "config": config})
	link.flush()
	preparing.emit(config)


## Stops waiting for a dropped connection: the host gives up on member [param id]
## ([signal member_left] follows); a guest gives up on the host ([signal closed] follows).
func give_up(id := LocalNetLink.HOST_ID) -> void:
	link.give_up(id)


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
## Spectators send none (-1).
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


## An input delay in ticks long enough for an input to reach the other device before
## it's due there, from what the players have reported: half the slowest player's typical
## (75th-percentile) round trip, plus three quarters of the two slowest frame times, plus
## [param margin_msec]. An input can be sampled up to a frame late, since devices only
## sample on frames, and noticed up to a frame late at the other end; half the round trip
## already includes the average quarter of each. Host and guests work it out from the same
## member list, so they agree. On a phone hotspot this comes to 4 or 5 ticks at 120 Hz.
## Spectators' round trips and frames are left out.
##
## When the host doesn't play, every input crosses two links (guest, host, guest), so the
## round trip part becomes half of each of the two slowest players' round trips, plus the
## host's whole frame, since it relays once a frame.
func suggested_delay(tick_rate := 120, margin_msec := 3.0, min_ticks := 2, max_ticks := 12) -> int:
	var round_trips := []
	var frames := []
	for id in players():
		var net: Dictionary = members[id].get("net", {})
		var round_trip: int = net.get("rtt_p75_usec", net.get("rtt_p90_usec", 0))
		if id == local_id and not is_host:
			round_trip = maxi(round_trip, _round_trip_percentile(75))
		round_trips.append(round_trip)
		frames.append(net.get("frame_usec", 0))
	if not is_host and not members.has(local_id):
		round_trips.append(_round_trip_percentile(75))
	round_trips.sort()
	round_trips.reverse()
	# A member that hasn't reported yet counts as a 60 fps device.
	frames = frames.map(func(f): return f if f > 0 else 16_667)
	frames.sort()
	frames.reverse()
	var slowest_two: int = frames[0] + (frames[1] if frames.size() > 1 else frames[0]) if not frames.is_empty() else 33_333
	var path_usec: float = round_trips[0] / 2.0 if not round_trips.is_empty() else 0.0
	if is_spectator(LocalNetLink.HOST_ID):
		var host_frame: int = members[LocalNetLink.HOST_ID].get("net", {}).get("frame_usec", 0)
		path_usec = (round_trips[0] + (round_trips[1] if round_trips.size() > 1 else 0)) / 2.0 if not round_trips.is_empty() else 0.0
		path_usec += host_frame if host_frame > 0 else 16_667
	var msec := path_usec / 1000.0 + slowest_two * 0.75 / 1000.0 + margin_msec
	return clampi(ceili(msec * tick_rate / 1000.0), min_ticks, max_ticks)


## How long this device's frames take, in microseconds: the median time between calls to
## [method poll], which games make once a frame. 0 until measured.
func frame_usec() -> int:
	if _frames.is_empty():
		return 0
	var sorted := _frames.duplicate()
	sorted.sort()
	return sorted[sorted.size() >> 1]


func _time_frame() -> void:
	var now := Time.get_ticks_usec()
	_frame_gap_usec = now - _last_poll_usec if _last_poll_usec > 0 else 0
	if _last_poll_usec > 0 and now - _last_poll_usec <= LONGEST_FRAME_USEC:
		_frames.append(now - _last_poll_usec)
		if _frames.size() > FRAME_SAMPLES:
			_frames.remove_at(0)
	_last_poll_usec = now


func _member(player_name: String, slot: int, role := PLAYER) -> Dictionary:
	return {"name": player_name, "slot": slot, "role": role, "ln": WIRE_VERSION, "ready": false, "synced": false, "loaded": false, "connected": true, "data": {}, "net": {}}


func _ids_with_role(role: String) -> Array:
	var ids := []
	for id in members:
		if members[id].get("role", PLAYER) == role:
			ids.append(id)
	ids.sort()
	return ids


# Spectating guests: the ones [member max_spectators] limits.
func _watching_guests() -> int:
	return spectators().filter(func(id): return id != local_id or not is_host).size()


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
	_start_at = Time.get_ticks_usec() + START_DELAY_USEC
	_send_all({"t": "start", "config": config, "start_at": _start_at})
	link.flush()
	started.emit(config, _start_at)


func _start_when_loaded() -> void:
	if state != "preparing":
		return
	for member in members.values():
		if not member.loaded and (member.connected or member.get("role", PLAYER) == PLAYER):
			_broadcast_members()
			return
	_go()


func _on_peer_connected(id: int) -> void:
	if not is_host:
		_send(id, {"t": "hello", "game": game_id, "v": version, "ln": WIRE_VERSION, "ln_min": WIRE_VERSION_MIN, "role": _role, "name": _name, "code": _join_code_hash})
		link.flush()


func _on_peer_interrupted(id: int) -> void:
	if not is_host:
		connection_interrupted.emit()
	elif members.has(id):
		members[id].connected = false
		member_interrupted.emit(id)
		if state == "preparing":
			# A spectator that drops isn't waited for, and may have been the last to load.
			# This shares the member list either way.
			_start_when_loaded()
		else:
			_broadcast_members()


func _on_peer_resumed(id: int) -> void:
	if not is_host:
		connection_resumed.emit()
		if state == "joining":
			_on_peer_connected(id)
		return
	if not members.has(id):
		return
	members[id].connected = true
	member_resumed.emit(id)
	_broadcast_members()
	# Anything sent while it was away is lost; bring it up to date.
	_send(id, {"t": "resume", "state": state, "config": config, "start_at": _start_at})
	link.flush()


func _on_peer_disconnected(id: int, reason: String) -> void:
	if not is_host:
		if state != "closed":
			state = "closed"
			closed.emit("The host left" if reason == "left" else "Lost connection to the host")
		return
	if members.has(id):
		members.erase(id)
		member_left.emit(id, reason)
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
		# Games may share this channel with their own kinds, so only a ping or pong of
		# exactly the right size counts: from a member to the host, or from the host.
		if bytes[0] == KIND_PING and bytes.size() == 9 and is_host and members.has(id):
			var pong := PackedByteArray([KIND_PONG])
			pong.resize(21)
			pong.encode_s64(1, bytes.decode_s64(1))
			pong.encode_s64(9, Time.get_ticks_usec())
			pong.encode_u32(17, mini(_frame_gap_usec, 0xFFFFFFFF))
			link.send(id, LocalNetLink.CHANNEL_REALTIME, pong, false)
			link.flush()
		elif bytes[0] == KIND_PONG and bytes.size() == 21 and not is_host and id == LocalNetLink.HOST_ID:
			_clock_sample(bytes.decode_s64(1), bytes.decode_s64(9), Time.get_ticks_usec(), maxi(bytes.decode_u32(17), _frame_gap_usec) > HITCH_USEC)


func _host_message(id: int, message: Dictionary) -> void:
	match message.get("t"):
		"hello":
			if members.has(id):
				# Said hello again after reconnecting mid-join.
				_send(id, {"t": "welcome", "id": id})
				_broadcast_members()
				return
			var reason := ""
			var watching: bool = message.get("role", PLAYER) == SPECTATOR
			if message.get("game") != game_id:
				reason = "Different game"
			elif message.get("v") != version:
				reason = "Different version (host has v%d)" % version
			elif not _wire_compatible(message):
				reason = "Different LocalNet version"
			elif _join_code_hash != "" and message.get("code") != _join_code_hash:
				reason = "Wrong join code"
			elif state != "lobby":
				reason = "Already playing"
			elif watching and max_spectators <= 0:
				reason = "Spectators aren't allowed"
			elif watching and _watching_guests() >= max_spectators:
				reason = "No room for spectators"
			elif not watching and players().size() >= max_players:
				reason = "Lobby is full"
			if reason != "":
				_send(id, {"t": "reject", "reason": reason})
				link.kick(id)
				return
			var player_name := str(message.get("name", "Player")).left(24)
			members[id] = _member(player_name, -1, SPECTATOR) if watching else _member(player_name, _free_slot())
			members[id].ln = message.ln
			_send(id, {"t": "welcome", "id": id, "reconnect_window_msec": reconnect_window_msec})
			_broadcast_members()
		"member":
			if members.has(id):
				for key in ["ready", "synced", "loaded", "data", "net", "content"]:
					if message.has(key):
						members[id][key] = message[key]
				_broadcast_members()
				if message.has("loaded"):
					_start_when_loaded()


func _client_message(message: Dictionary) -> void:
	match message.get("t"):
		"welcome":
			local_id = message.id
			reconnect_window_msec = message.get("reconnect_window_msec", reconnect_window_msec)
			state = "lobby"
			joined.emit(local_id)
		"reject":
			state = "closed"
			link.close()
			rejected.emit(str(message.get("reason", "Rejected")))
		"lobby":
			var before := members
			members = message.members
			config = message.config
			session_name = message.name
			var needed: Dictionary = message.get("content", {})
			needed_content = needed.get("items", [])
			_needed_key = str(needed.get("key", ""))
			reconnect_window_msec = message.get("reconnect_window_msec", reconnect_window_msec)
			for id in members:
				if id != local_id and before.has(id) and before[id].get("connected", true) != members[id].get("connected", true):
					if members[id].connected:
						member_resumed.emit(id)
					else:
						member_interrupted.emit(id)
			members_changed.emit()
		"resume":
			config = message.config
			if message.state == "started" and state != "started":
				state = "started"
				started.emit(config, host_to_local_usec(message.start_at))
			elif message.state == "preparing" and state != "preparing":
				state = "preparing"
				preparing.emit(config)
			elif message.state == "lobby" and state in ["preparing", "started"]:
				state = "lobby"
				returned.emit()
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


func _clock_sample(sent: int, host_time: int, now: int, hitched := false) -> void:
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
	if now - _joined_usec >= RADIO_WAKE_USEC and not hitched:
		_round_trips.append(now - sent)
		if _round_trips.size() > LINK_SAMPLES:
			_round_trips.remove_at(0)
	if not _reported_synced and _samples.size() >= SYNCED_AFTER and _round_trips.size() >= LINK_READY:
		_reported_synced = true
		_next_report_usec = now + REPORT_EVERY_USEC
		_update_self({"synced": true, "net": _link_quality()})
	elif state == "lobby" and now >= _next_report_usec:
		_next_report_usec = now + REPORT_EVERY_USEC
		_update_self({"net": _link_quality()})


func _link_quality() -> Dictionary:
	return {"rtt_p50_usec": _round_trip_percentile(50), "rtt_p75_usec": _round_trip_percentile(75), "rtt_p90_usec": _round_trip_percentile(90), "rtt_max_usec": _round_trip_percentile(100), "frame_usec": frame_usec()}


func _round_trip_percentile(p: float) -> int:
	if _round_trips.is_empty():
		return 0
	var sorted := _round_trips.duplicate()
	sorted.sort()
	return sorted[clampi(ceili(p / 100.0 * sorted.size()) - 1, 0, sorted.size() - 1)]


func _free_slot() -> int:
	var used := members.values().filter(func(m): return m.get("role", PLAYER) == PLAYER).map(func(m): return m.slot)
	var slot := 0
	while used.has(slot):
		slot += 1
	return slot


func _broadcast_members() -> void:
	members_changed.emit()
	if is_host:
		var message := {"t": "lobby", "members": members, "config": config, "name": session_name, "reconnect_window_msec": reconnect_window_msec}
		if _needed_key != "":
			message.content = {"items": needed_content, "key": _needed_key}
		_send_all(message)
		link.flush()


# For [LocalNetContent]: the host sets what the match needs, and shares it.
func _set_needed_content(items: Array, key: String) -> void:
	if is_host:
		needed_content = items.duplicate(true)
		_needed_key = key
		_broadcast_members()


# For [LocalNetContent]: this device reports how much of [member needed_content] it holds.
func _report_content(report: Dictionary) -> void:
	_update_self({"content": report})


func _needed_content_key() -> String:
	return _needed_key


func _send(id: int, message: Dictionary) -> void:
	link.send(id, LocalNetLink.CHANNEL_CONTROL, var_to_bytes(message), true)


func _send_all(message: Dictionary) -> void:
	var bytes := var_to_bytes(message)
	for id in members:
		if id != local_id:
			link.send(id, LocalNetLink.CHANNEL_CONTROL, bytes, true)


# Whether a guest's LocalNet works with this one: their ranges of versions overlap. A hello
# without "ln" comes from LocalNet 0.2; one without "ln_min" is taken to work only with
# its own version.
static func _wire_compatible(hello: Dictionary) -> bool:
	var newest = hello.get("ln")
	var oldest = hello.get("ln_min", newest)
	return newest is int and oldest is int and newest >= WIRE_VERSION_MIN and WIRE_VERSION >= oldest


static func _hash_code(code: String) -> String:
	return "" if code.strip_edges() == "" else code.strip_edges().sha256_text()
