class_name LocalNetLink
extends RefCounted
## A thin wrapper over ENet: one host, any number of clients, three channels.
##
## Channels: [constant CHANNEL_CONTROL] carries reliable lobby messages,
## [constant CHANNEL_REALTIME] unreliable per-frame traffic (inputs, clock pings) and
## [constant CHANNEL_EVENTS] reliable binary events (checksums). Binary packets start with
## a kind byte so several listeners can share a channel. The host is always peer
## [constant HOST_ID]; clients are numbered from 2 on the host.
## Call [method poll] at the start of a frame and [method flush] after sending.

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal received(id: int, channel: int, bytes: PackedByteArray)
signal connect_failed

enum { CHANNEL_CONTROL, CHANNEL_REALTIME, CHANNEL_EVENTS, CHANNEL_COUNT }
const HOST_ID := 1

var is_host := false
var port := 0
## Test impairments: drop a share of unreliable packets, delay every packet.
var debug_drop := 0.0
var debug_latency_msec := 0.0
var debug_jitter_msec := 0.0

var _enet: ENetConnection
var _connecting: ENetPacketPeer
var _peers := {}
var _ids := {}
var _next_id := HOST_ID + 1
var _delayed := []
var _last_reliable_due := 0
var _hold_until := 0
var _rng := RandomNumberGenerator.new()


func host(listen_port := 0, max_peers := 8) -> Error:
	close()
	_enet = ENetConnection.new()
	var err := _enet.create_host_bound("*", listen_port, max_peers, CHANNEL_COUNT)
	if err != OK:
		_enet = null
		return err
	is_host = true
	port = _enet.get_local_port()
	return OK


func join(address: String, host_port: int) -> Error:
	close()
	_enet = ENetConnection.new()
	var err := _enet.create_host(1, CHANNEL_COUNT)
	if err != OK:
		_enet = null
		return err
	_connecting = _enet.connect_to_host(address, host_port, CHANNEL_COUNT)
	if _connecting == null:
		close()
		return ERR_CANT_CONNECT
	is_host = false
	return OK


func is_open() -> bool:
	return _enet != null


func peers() -> Array:
	return _peers.keys()


func poll() -> void:
	if _enet == null:
		return
	_send_delayed()
	while _enet:
		var event := _enet.service()
		var type: int = event[0]
		var peer: ENetPacketPeer = event[1]
		if type == ENetConnection.EVENT_NONE:
			break
		elif type == ENetConnection.EVENT_ERROR:
			push_warning("LocalNet: ENet service failed")
			break
		elif type == ENetConnection.EVENT_CONNECT:
			_on_connect(peer)
		elif type == ENetConnection.EVENT_DISCONNECT:
			_on_disconnect(peer)
		elif type == ENetConnection.EVENT_RECEIVE:
			var bytes := peer.get_packet()
			if _ids.has(peer):
				received.emit(_ids[peer], event[3], bytes)


func send(id: int, channel: int, bytes: PackedByteArray, reliable: bool) -> void:
	if not reliable and debug_drop > 0.0 and _rng.randf() < debug_drop:
		return
	var now := Time.get_ticks_usec()
	if debug_latency_msec > 0.0 or debug_jitter_msec > 0.0 or now < _hold_until:
		var due := maxi(now + int((debug_latency_msec + _rng.randf() * debug_jitter_msec) * 1000.0), _hold_until)
		if reliable:
			# Jitter must never reorder reliable messages.
			due = maxi(due, _last_reliable_due + 1)
			_last_reliable_due = due
		_delayed.append([due, id, channel, bytes, reliable])
		return
	_send_now(id, channel, bytes, reliable)


## Test impairment: holds every outgoing packet for [param msec], then sends them all,
## the way a Wi-Fi hiccup does.
func debug_hold(msec: float) -> void:
	_hold_until = Time.get_ticks_usec() + int(msec * 1000.0)


func broadcast(channel: int, bytes: PackedByteArray, reliable: bool, except_id := 0) -> void:
	for id in _peers:
		if id != except_id:
			send(id, channel, bytes, reliable)


func flush() -> void:
	if _enet:
		_enet.flush()


## Disconnects a peer once its queued messages have gone out.
func kick(id: int) -> void:
	if _peers.has(id):
		_peers[id].peer_disconnect_later()


func close() -> void:
	if _enet:
		for peer in _peers.values():
			peer.peer_disconnect_now()
		if _connecting:
			_connecting.peer_disconnect_now()
		_enet.flush()
		_enet.destroy()
	_enet = null
	_connecting = null
	_peers.clear()
	_ids.clear()
	_delayed.clear()
	_next_id = HOST_ID + 1


## ENet's smoothed round trip, in milliseconds.
func rtt_msec(id: int) -> float:
	if not _peers.has(id):
		return 0.0
	return _peers[id].get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)


## Share of reliable packets ENet had to resend recently, 0 to 1.
func packet_loss(id: int) -> float:
	if not _peers.has(id):
		return 0.0
	return _peers[id].get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / float(ENetPacketPeer.PACKET_LOSS_SCALE)


func address(id: int) -> String:
	return _peers[id].get_remote_address() if _peers.has(id) else ""


func _on_connect(peer: ENetPacketPeer) -> void:
	peer.set_timeout(32, 3000, 6000)
	var id := HOST_ID
	if is_host:
		id = _next_id
		_next_id += 1
	_connecting = null
	_peers[id] = peer
	_ids[peer] = id
	peer_connected.emit(id)


func _on_disconnect(peer: ENetPacketPeer) -> void:
	if _ids.has(peer):
		var id: int = _ids[peer]
		_ids.erase(peer)
		_peers.erase(id)
		peer_disconnected.emit(id)
	elif peer == _connecting:
		_connecting = null
		connect_failed.emit()


func _send_now(id: int, channel: int, bytes: PackedByteArray, reliable: bool) -> void:
	var peer: ENetPacketPeer = _peers.get(id)
	# A peer that is mid-disconnect has no channels left.
	if peer and peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
		peer.send(channel, bytes, ENetPacketPeer.FLAG_RELIABLE if reliable else 0)


func _send_delayed() -> void:
	if _delayed.is_empty():
		return
	var now := Time.get_ticks_usec()
	_delayed.sort_custom(func(a, b): return a[0] < b[0])
	while not _delayed.is_empty() and _delayed[0][0] <= now:
		var item: Array = _delayed.pop_front()
		_send_now(item[1], item[2], item[3], item[4])
	_enet.flush()
