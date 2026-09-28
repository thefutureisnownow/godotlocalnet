class_name LocalNetDiscovery
extends RefCounted
## Finds hosts on the local network with no router, internet or multicast entitlement.
##
## A host answers small UDP probes on [constant PORT]. A scanner sends a probe to every
## address in each local IPv4 /24 (plus broadcast where the platform allows it) and
## collects the replies. Unicast sweeping works on phone hotspots and on iOS without
## Apple's multicast entitlement; it only needs the local network permission.
##
## Each sweep spreads its probes over short-lived sockets, one per frame. Probes to empty addresses wait
## in the kernel's ARP queue for seconds, charged to the socket that sent them; on
## Android a single socket's send buffer fills after a couple of hundred, and Godot's UDP
## send then blocks the main thread until ARP gives up.
## Call [method poll] every frame.

signal session_found(session: Dictionary)

const PORT := 47650
const PROBES_PER_SOCKET := 32
## Replies to a sweep are read for this long before its sockets close.
const SOCKET_LIFETIME_USEC := 4_000_000
## Cellular, VPN, loopback and Apple peer-to-peer interfaces are never swept.
const SKIP_INTERFACES := ["lo", "rmnet", "ccmni", "pdp_ip", "clat", "v4-", "dummy", "tun", "utun", "ipsec", "ppp", "awdl", "llw", "gif", "stf", "anpi"]

var game_id: String
var version: int
var sweep_interval := 1.0
var stale_after := 3.5
## Broadcast reaches hosts outside a /24 on Android and desktop. iOS needs an entitlement.
var use_broadcast := OS.get_name() != "iOS"

var _advertiser: PacketPeerUDP
var _info := {}
## The longest a frame of the last sweep took, and how many addresses it probed.
var last_sweep_usec := 0
var last_sweep_targets := 0

var _scanning := false
var _pending := []
var _sockets := []
var _scan_port := PORT
var _fixed_targets := PackedStringArray()
var _next_sweep_usec := 0
var _sessions := {}


func _init(game: String, game_version: int) -> void:
	game_id = game
	version = game_version


## Starts answering probes. [param info] should hold id, name, port, players, max and state.
func advertise(info: Dictionary, port := PORT) -> Error:
	stop_advertising()
	_advertiser = PacketPeerUDP.new()
	var err := _advertiser.bind(port)
	if err != OK:
		_advertiser = null
		return err
	if use_broadcast:
		_advertiser.set_broadcast_enabled(true)
	_info = info.duplicate()
	return OK


func update_info(info: Dictionary) -> void:
	_info = info.duplicate()


func stop_advertising() -> void:
	if _advertiser:
		_advertiser.close()
	_advertiser = null


## Starts sweeping. Leave [param targets] empty to sweep every local /24.
func scan(targets := PackedStringArray(), port := PORT) -> Error:
	stop_scanning()
	var probe := PacketPeerUDP.new()
	var err := probe.bind(0)
	probe.close()
	if err != OK:
		return err
	_scanning = true
	_fixed_targets = targets
	_scan_port = port
	_next_sweep_usec = 0
	_sessions.clear()
	return OK


func stop_scanning() -> void:
	for entry in _sockets:
		entry.socket.close()
	_sockets.clear()
	_pending.clear()
	_scanning = false


func stop() -> void:
	stop_advertising()
	stop_scanning()


func poll() -> void:
	if _advertiser:
		_answer_probes()
	if _scanning:
		var now := Time.get_ticks_usec()
		if now >= _next_sweep_usec:
			_sweep(now)
			_next_sweep_usec = now + int(sweep_interval * 1_000_000)
		if not _pending.is_empty():
			_send_chunk()
		_collect_replies()


## Sessions heard from recently, sorted by name.
func sessions() -> Array:
	var now := Time.get_ticks_usec()
	var fresh := []
	for session in _sessions.values():
		if now - session.seen_usec <= int(stale_after * 1_000_000):
			fresh.append(session)
	fresh.sort_custom(func(a, b): return a.name < b.name)
	return fresh


## This device's usable IPv4 addresses as [{address, interface}].
static func local_ipv4() -> Array:
	var found := []
	for iface in IP.get_local_interfaces():
		var name: String = iface.name
		if SKIP_INTERFACES.any(func(prefix): return name.begins_with(prefix)):
			continue
		for address in iface.addresses:
			if address.is_valid_ip_address() and address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
				found.append({"address": address, "interface": name})
	return found


## Every address worth probing: each local /24, this device itself, and broadcast.
static func sweep_targets(broadcast: bool) -> PackedStringArray:
	var targets := PackedStringArray()
	for local in local_ipv4():
		var parts: PackedStringArray = local.address.split(".")
		var prefix := ".".join(parts.slice(0, 3)) + "."
		for i in range(1, 255):
			var address := prefix + str(i)
			if not targets.has(address):
				targets.append(address)
		if broadcast:
			targets.append(prefix + "255")
	if broadcast and not targets.is_empty():
		targets.append("255.255.255.255")
	return targets


# Queues a sweep; [method _send_chunk] sends one socket's worth per frame.
func _sweep(_now: int) -> void:
	var targets := _fixed_targets if not _fixed_targets.is_empty() else sweep_targets(use_broadcast)
	_pending.clear()
	for first in range(0, targets.size(), PROBES_PER_SOCKET):
		_pending.append(targets.slice(first, first + PROBES_PER_SOCKET))
	last_sweep_targets = targets.size()
	last_sweep_usec = 0


func _send_chunk() -> void:
	var now := Time.get_ticks_usec()
	var chunk: PackedStringArray = _pending.pop_front()
	var socket := PacketPeerUDP.new()
	if socket.bind(0) != OK:
		return
	for address in chunk:
		if address.ends_with(".255"):
			socket.set_broadcast_enabled(true)
			break
	var probe := _encode({"localnet": "probe", "game": game_id, "v": version, "sent": now})
	for address in chunk:
		socket.set_dest_address(address, _scan_port)
		socket.put_packet(probe)
	_sockets.append({"socket": socket, "expires": now + SOCKET_LIFETIME_USEC})
	last_sweep_usec = maxi(last_sweep_usec, Time.get_ticks_usec() - now)


func _answer_probes() -> void:
	while _advertiser.get_available_packet_count() > 0:
		var probe = _decode(_advertiser.get_packet())
		var address := _advertiser.get_packet_ip()
		var port := _advertiser.get_packet_port()
		if probe == null or probe.localnet != "probe" or probe.get("game") != game_id:
			continue
		var reply := _info.duplicate()
		reply.merge({"localnet": "host", "game": game_id, "v": version, "sent": probe.get("sent", 0)}, true)
		_advertiser.set_dest_address(address, port)
		_advertiser.put_packet(_encode(reply))


func _collect_replies() -> void:
	var now := Time.get_ticks_usec()
	for entry in _sockets.duplicate():
		_read_replies(entry.socket)
		if now >= entry.expires:
			entry.socket.close()
			_sockets.erase(entry)


func _read_replies(socket: PacketPeerUDP) -> void:
	while socket.get_available_packet_count() > 0:
		var reply = _decode(socket.get_packet())
		var address := socket.get_packet_ip()
		if reply == null or reply.localnet != "host" or reply.get("game") != game_id or not reply.has("id"):
			continue
		var now := Time.get_ticks_usec()
		var id := str(reply.id)
		var known: Dictionary = _sessions.get(id, {})
		var session := {
			"id": id,
			"name": str(reply.get("name", "Host")),
			# A host seen on several interfaces keeps the address that answered first.
			"address": known.get("address", address),
			"port": int(reply.get("port", 0)),
			"players": int(reply.get("players", 0)),
			"max_players": int(reply.get("max", 0)),
			"state": str(reply.get("state", "")),
			"code_required": bool(reply.get("code", false)),
			"version": int(reply.get("v", 0)),
			"compatible": int(reply.get("v", 0)) == version,
			"ping_ms": (now - int(reply.get("sent", now))) / 1000.0,
			"seen_usec": now,
		}
		_sessions[id] = session
		if known.is_empty():
			session_found.emit(session)


static func _encode(message: Dictionary) -> PackedByteArray:
	return JSON.stringify(message).to_utf8_buffer()


static func _decode(bytes: PackedByteArray) -> Variant:
	var message = JSON.parse_string(bytes.get_string_from_utf8())
	if message is Dictionary and message.has("localnet"):
		return message
	return null
