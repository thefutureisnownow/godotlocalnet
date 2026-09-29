class_name LocalNetLink
extends RefCounted
## A thin wrapper over ENet: one host, any number of clients, three channels, and
## connections that survive a drop.
##
## Channels: [constant CHANNEL_CONTROL] carries reliable lobby messages,
## [constant CHANNEL_REALTIME] unreliable per-frame traffic (inputs, clock pings) and
## [constant CHANNEL_EVENTS] reliable binary events (checksums). Binary packets start with
## a kind byte so several listeners can share a channel. The host is always peer
## [constant HOST_ID]; clients are numbered from 2 on the host.
##
## Reconnecting: each client sends a random token with its connection request. When a
## connection drops without a goodbye, both sides emit [signal peer_interrupted]; the
## host keeps the client's id for [member reconnect_window_msec] while the client keeps
## trying to reconnect with its token. If it gets back in time, both sides emit
## [signal peer_resumed] and the client has its old id, so everything built on top
## carries on. Otherwise both emit [signal peer_disconnected] with reason "lost". The game
## chooses the window, may wait forever ([constant WAIT_FOREVER]) and may stop waiting at
## any moment with [method give_up]. Leaving
## on purpose ([method close]) or being kicked ends a connection at once. If the system
## breaks the socket itself (as phones can when an app is backgrounded), the link opens a
## new one and treats every connection as dropped.
## Call [method poll] at the start of a frame and [method flush] after sending.

signal peer_connected(id: int)
## A connection dropped unexpectedly; it may still come back.
signal peer_interrupted(id: int)
## An interrupted connection came back, with the same id.
signal peer_resumed(id: int)
## Gone for good. [param reason] is "left", "kicked" or "lost".
signal peer_disconnected(id: int, reason: String)
signal received(id: int, channel: int, bytes: PackedByteArray)
## The first connection attempt failed.
signal connect_failed

enum { CHANNEL_CONTROL, CHANNEL_REALTIME, CHANNEL_EVENTS, CHANNEL_COUNT }
const HOST_ID := 1
## Codes sent with a disconnect, so the other side knows it was deliberate.
enum { BYE_NONE, BYE_LEAVE, BYE_KICK, BYE_FORGOTTEN }
## Set on a reconnect request's token.
const RESUMING := 0x80000000
## A [member reconnect_window_msec] that never runs out; the game ends it with [method give_up].
const WAIT_FOREVER := -1
const _NEVER := 1 << 62

var is_host := false
var port := 0
## How long a dropped connection may take to come back: 0 turns reconnecting off and
## [constant WAIT_FOREVER] waits until [method give_up]. A change applies to later drops.
var reconnect_window_msec := 30_000
## How often a client retries while reconnecting.
var reconnect_attempt_msec := 1_500
## Test impairments: drop a share of unreliable packets, delay every packet.
var debug_drop := 0.0
var debug_latency_msec := 0.0
var debug_jitter_msec := 0.0

var _enet: ENetConnection
var _connecting: ENetPacketPeer
var _peers := {}
var _ids := {}
var _next_id := HOST_ID + 1
var _max_peers := 8
var _delayed := []
var _last_reliable_due := 0
var _hold_until := 0
var _rng := RandomNumberGenerator.new()
# Host: token -> id for every client, and the ids waiting to reconnect.
var _tokens := {}
var _reserved := {}
# Client: where to reconnect, with which token, and until when.
var _address := ""
var _host_port := 0
var _token := 0
var _reconnect_until := 0
var _next_attempt := 0
var _hold_reconnect_until := 0


func host(listen_port := 0, max_peers := 8) -> Error:
	close()
	_enet = ENetConnection.new()
	var err := _enet.create_host_bound("*", listen_port, max_peers, CHANNEL_COUNT)
	if err != OK:
		_enet = null
		return err
	is_host = true
	_max_peers = max_peers
	port = _enet.get_local_port()
	return OK


func join(address: String, host_port: int) -> Error:
	close()
	_enet = ENetConnection.new()
	var err := _enet.create_host(1, CHANNEL_COUNT)
	if err != OK:
		_enet = null
		return err
	_address = address
	_host_port = host_port
	_token = (_rng.randi() & 0x7FFFFFFF) | 1
	_connecting = _enet.connect_to_host(address, host_port, CHANNEL_COUNT, _token)
	if _connecting == null:
		close()
		return ERR_CANT_CONNECT
	is_host = false
	return OK


func is_open() -> bool:
	return _enet != null


func peers() -> Array:
	return _peers.keys()


## True while the connection to [param id] is up (not interrupted).
func is_peer_connected(id: int) -> bool:
	return _peers.has(id)


## Ids that dropped and may still come back: clients on the host, or the host itself on
## a client that is reconnecting.
func interrupted_peers() -> Array:
	if is_host:
		return _reserved.keys()
	return [HOST_ID] if _reconnect_until != 0 else []


## Seconds left for [param id] to come back: 0 if it isn't interrupted, INF when
## waiting forever.
func reconnect_seconds_left(id: int) -> float:
	var until: int = _reserved[id].until if is_host and _reserved.has(id) else (_reconnect_until if not is_host and id == HOST_ID else 0)
	if until == _NEVER:
		return INF
	return maxf(0.0, (until - Time.get_ticks_usec()) / 1_000_000.0) if until else 0.0


## Stops waiting for an interrupted connection: on the host, a client's reserved place;
## on a client, the host. Emits [signal peer_disconnected] with reason "lost" straight away.
func give_up(id := HOST_ID) -> void:
	if is_host and _reserved.has(id):
		_reserved.erase(id)
		_forget_token(id)
		peer_disconnected.emit(id, "lost")
	elif not is_host and id == HOST_ID and _reconnect_until != 0:
		_reconnect_until = 0
		if _connecting:
			_connecting.reset()
			_connecting = null
		peer_disconnected.emit(HOST_ID, "lost")


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
			push_warning("LocalNet: the network socket failed; opening a new one")
			_recover_socket()
			break
		elif type == ENetConnection.EVENT_CONNECT:
			_on_connect(peer, event[2])
		elif type == ENetConnection.EVENT_DISCONNECT:
			_on_disconnect(peer, event[2])
		elif type == ENetConnection.EVENT_RECEIVE:
			var bytes := peer.get_packet()
			if _ids.has(peer):
				received.emit(_ids[peer], event[3], bytes)
	_tend_reconnects()


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


func broadcast(channel: int, bytes: PackedByteArray, reliable: bool, except_id := 0) -> void:
	for id in _peers:
		if id != except_id:
			send(id, channel, bytes, reliable)


func flush() -> void:
	if _enet:
		_enet.flush()


## Disconnects a peer once its queued messages have gone out. It won't reconnect.
func kick(id: int) -> void:
	if _peers.has(id):
		_peers[id].peer_disconnect_later(BYE_KICK)
		_forget_token(id)


## Leaves on purpose: the other side hears it at once and nobody waits for a reconnect.
func close() -> void:
	if _enet:
		for peer in _peers.values():
			peer.peer_disconnect_now(BYE_LEAVE)
		if _connecting:
			_connecting.peer_disconnect_now(BYE_LEAVE)
		_enet.flush()
		_enet.destroy()
	_enet = null
	_connecting = null
	_peers.clear()
	_ids.clear()
	_delayed.clear()
	_tokens.clear()
	_reserved.clear()
	_reconnect_until = 0
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


## Test impairment: holds every outgoing packet for [param msec], then sends them all,
## the way a Wi-Fi hiccup does.
func debug_hold(msec: float) -> void:
	_hold_until = Time.get_ticks_usec() + int(msec * 1000.0)


## Test impairment: drops the connection to [param id] without a goodbye, as a network
## failure would. A client waits [param pause_msec] before it tries to reconnect.
func debug_drop_connection(id := HOST_ID, pause_msec := 0.0) -> void:
	if not _peers.has(id):
		return
	var peer: ENetPacketPeer = _peers[id]
	peer.peer_disconnect_now(BYE_NONE)
	_enet.flush()
	_hold_reconnect_until = Time.get_ticks_usec() + int(pause_msec * 1000.0)
	_lost(id, peer)


## Test hook: behaves as if the system had broken the socket.
func debug_break_socket() -> void:
	if _enet:
		_recover_socket()


func _on_connect(peer: ENetPacketPeer, data: int) -> void:
	peer.set_timeout(32, 3000, 6000)
	# ENet's throttle drops a share of unreliable packets whenever a round trip looks worse
	# than usual. Lockstep inputs already repeat until acknowledged, so dropping them only
	# makes them late: after a host's loading hitch it cost the first match 300 ms stalls.
	peer.throttle_configure(5000, ENetPacketPeer.PACKET_THROTTLE_SCALE, 0)
	if not is_host:
		_connecting = null
		_peers[HOST_ID] = peer
		_ids[peer] = HOST_ID
		if _reconnect_until != 0:
			_reconnect_until = 0
			peer_resumed.emit(HOST_ID)
		else:
			peer_connected.emit(HOST_ID)
		return
	var token := data & ~RESUMING
	if data & RESUMING:
		if not _tokens.has(token):
			# Too late: the window closed and the host let this client go.
			peer.peer_disconnect_later(BYE_FORGOTTEN)
			return
		var id: int = _tokens[token]
		if _peers.has(id):
			# The client noticed the drop before the host did; retire the dead connection.
			var stale: ENetPacketPeer = _peers[id]
			_ids.erase(stale)
			stale.reset()
		_reserved.erase(id)
		_peers[id] = peer
		_ids[peer] = id
		peer_resumed.emit(id)
		return
	var id := _next_id
	_next_id += 1
	if token != 0:
		_tokens[token] = id
	_peers[id] = peer
	_ids[peer] = id
	peer_connected.emit(id)


func _on_disconnect(peer: ENetPacketPeer, data: int) -> void:
	if _ids.has(peer):
		var id: int = _ids[peer]
		if data == BYE_LEAVE or data == BYE_KICK or data == BYE_FORGOTTEN:
			_ids.erase(peer)
			_peers.erase(id)
			_forget_token(id)
			_reconnect_until = 0
			peer_disconnected.emit(id, "left" if data == BYE_LEAVE else ("kicked" if data == BYE_KICK else "lost"))
		else:
			_lost(id, peer)
	elif peer == _connecting:
		_connecting = null
		if data == BYE_FORGOTTEN or data == BYE_KICK:
			_reconnect_until = 0
			peer_disconnected.emit(HOST_ID, "lost")
		elif _reconnect_until == 0:
			connect_failed.emit()
		# Otherwise a reconnect attempt failed; [method _tend_reconnects] tries again.


# A connection dropped without a goodbye: hold its place and, on a client, start
# reconnecting.
func _lost(id: int, peer: ENetPacketPeer) -> void:
	_ids.erase(peer)
	_peers.erase(id)
	var until := _NEVER if reconnect_window_msec < 0 else Time.get_ticks_usec() + reconnect_window_msec * 1000
	if reconnect_window_msec == 0 or (is_host and _token_of(id) == 0):
		_forget_token(id)
		peer_disconnected.emit(id, "lost")
	elif is_host:
		_reserved[id] = {"until": until}
		peer_interrupted.emit(id)
	else:
		_reconnect_until = until
		_next_attempt = 0
		peer_interrupted.emit(HOST_ID)


func _tend_reconnects() -> void:
	var now := Time.get_ticks_usec()
	for id in _reserved.keys():
		if now >= _reserved[id].until:
			_reserved.erase(id)
			_forget_token(id)
			peer_disconnected.emit(id, "lost")
	if is_host or _reconnect_until == 0 or _connecting or _peers.has(HOST_ID):
		return
	if now >= _reconnect_until:
		_reconnect_until = 0
		peer_disconnected.emit(HOST_ID, "lost")
	elif now >= _next_attempt and now >= _hold_reconnect_until:
		_next_attempt = now + reconnect_attempt_msec * 1000
		_connecting = _enet.connect_to_host(_address, _host_port, CHANNEL_COUNT, _token | RESUMING)
		if _connecting:
			_connecting.set_timeout(8, reconnect_attempt_msec, reconnect_attempt_msec)


# The socket itself failed: open a new one and treat every connection as dropped.
func _recover_socket() -> void:
	var lost := _peers.duplicate()
	var was_connecting := _connecting != null and _reconnect_until == 0
	_enet.destroy()
	_peers.clear()
	_ids.clear()
	_connecting = null
	_enet = ENetConnection.new()
	var err := _enet.create_host_bound("*", port, _max_peers, CHANNEL_COUNT) if is_host else _enet.create_host(1, CHANNEL_COUNT)
	if err != OK:
		_enet = null
		for id in lost:
			peer_disconnected.emit(id, "lost")
		return
	if was_connecting:
		connect_failed.emit()
	for id in lost:
		_peers[id] = lost[id]
		_lost(id, lost[id])


func _token_of(id: int) -> int:
	for token in _tokens:
		if _tokens[token] == id:
			return token
	return 0


func _forget_token(id: int) -> void:
	var token := _token_of(id)
	if token:
		_tokens.erase(token)


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
