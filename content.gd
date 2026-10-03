class_name LocalNetContent
extends RefCounted
## Moves content (stages, skins, tracks, mods) between lobby members by hash, so every
## device holds the same bytes before a match starts.
##
## LocalNet carries bytes only: the game packs its content (with [ZIPPacker], say),
## describes each piece as an item ([method describe]) and loads what arrives itself. An
## item is [code]{type, id, hash, size}[/code], where the hash is the sha256 of the bytes
## in hex. Items are matched by hash, never by id: a different version under the same id
## counts as missing, since two devices with different content would drift apart.
##
## Every device [method offer]s what it holds. The host [method require]s what the match
## needs, and every member hears the list along with the member list, fetches what it's
## missing and reports how much is left under its member's [code]"content"[/code] key, so
## [method LocalNetLobby.can_start] can wait for it. Guests fetch from the host. When only
## a guest has an item, the host fetches it from that guest, keeps it and passes it on:
## content travels in a star, like everything else. It needs only the lobby and its link,
## whatever kind of match follows.
##
## Transfers use their own reliable channel ([constant LocalNetLink.CHANNEL_CONTENT]), in
## chunks of [constant CHUNK_BYTES], with at most [constant WINDOW] chunks unacknowledged per
## peer and [member budget_bytes] sent per frame. ENet's reliable window is shared by
## all of a peer's channels, so a bigger backlog would hold up lobby messages and checksums.
## Transfers only run in the lobby: they pause while a match is preparing or playing, and
## carry on when everyone returns. Downloads go to [code]<hash>.part[/code] in
## [member cache_dir] and continue from where they stopped after a dropped connection, a
## rematch or a fresh start of the app. A finished download is checked against its hash
## before it's renamed to [code]<hash>[/code]; one that doesn't match is thrown away and
## [signal failed] says so.
##
## A device only accepts chunks of items it asked for, and only serves items it offered
## (the host also serves items the match needs that it has fetched). Never load downloaded
## content through [ResourceLoader]: [code].tres[/code], [code].res[/code] and
## [code].tscn[/code] files can carry scripts. Read it with [GLTFDocument],
## [method Image.load_from_buffer], [JSON] and the like. Call [method poll] every frame,
## after [method LocalNetLobby.poll].

## Bytes of [param hash] received so far, out of [param total].
signal progress(hash: String, bytes: int, total: int)
## A download finished and matched its hash; it's at [param path].
signal received(item: Dictionary, path: String)
## [param item] couldn't be fetched: nobody has it, it's too big, or it didn't match its hash.
signal failed(item: Dictionary, reason: String)
## This device holds everything the match needs.
signal all_present

const KIND_WANT := 20
const KIND_CHUNK := 21
const KIND_ACK := 22
const KIND_NOPE := 23
## Why a request was refused: the device doesn't have the item, nobody in the lobby has it,
## or its source couldn't be read.
enum { NOPE_MISSING = 1, NOPE_UNAVAILABLE, NOPE_UNREADABLE }
const CHUNK_BYTES := 16_384
## Chunks sent to a peer but not yet acknowledged, across all its transfers.
const WINDOW := 4
## Items a device fetches at once; the rest wait their turn.
const FETCHES := 4
## How long to wait before asking again for an item nobody had.
const RETRY_USEC := 2_000_000
## How often an unacknowledged report of what's missing is sent again.
const REPORT_USEC := 1_000_000
const _HEADER := 37

var lobby: LocalNetLobby
## Where downloads are kept, as [code]<hash>[/code] files.
var cache_dir := "user://localnet_content"
## Items bigger than this are never fetched.
var max_item_bytes := 32 * 1024 * 1024
## Bytes of chunks sent per frame, across every transfer.
var budget_bytes := 131_072

var _offers := {}
var _fetches := {}
var _sends := {}
var _held := {}
var _reported := {}
var _next_report_usec := 0
var _present_key := ""
var _signals := []


func _init(lobby_to_use: LocalNetLobby) -> void:
	lobby = lobby_to_use
	_signals = [
		[lobby.link.received, _on_received],
		[lobby.member_left, _on_member_left],
		[lobby.member_resumed, _on_member_resumed],
		[lobby.connection_resumed, _on_connection_resumed],
		[lobby.closed, _on_closed],
	]
	for pair in _signals:
		pair[0].connect(pair[1])


## Stops listening and closes any open files. Partial downloads stay for next time.
func close() -> void:
	for pair in _signals:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
	_reset()


## An item for [param source]: a [PackedByteArray] or a file path. Hashes the whole thing.
static func describe(type: String, id: String, source: Variant) -> Dictionary:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	var size := 0
	if source is PackedByteArray:
		size = source.size()
		if size > 0:
			hashing.update(source)
	else:
		var file := FileAccess.open(str(source), FileAccess.READ)
		if file == null:
			return {}
		size = file.get_length()
		while file.get_position() < size:
			hashing.update(file.get_buffer(1 << 20))
	return {"type": type, "id": id, "hash": hashing.finish().hex_encode(), "size": size}


## Lets this device serve [param item] from [param source]: a file path, a
## [PackedByteArray], or a Callable (offset, length) -> [PackedByteArray].
func offer(item: Dictionary, source: Variant) -> void:
	if _valid(item):
		_offers[item.hash] = {"item": item.duplicate(), "source": source}


## Host only: the items the match needs. Every member starts fetching what it's missing.
func require(items: Array) -> void:
	if not lobby.is_host:
		return
	var needed := items.filter(_valid).map(func(item): return item.duplicate())
	var hashes := needed.map(func(item): return item.hash)
	lobby._set_needed_content(needed, "|".join(hashes).sha256_text().left(16))


## True when this device holds the item with [param hash], offered or downloaded.
func has(hash: String) -> bool:
	return _offers.has(hash) or FileAccess.file_exists(_path(hash))


## Where the item with [param hash] is: the download, or the path it was offered from.
## Empty when it's missing or was offered from memory.
func path_for(hash: String) -> String:
	if FileAccess.file_exists(_path(hash)):
		return _path(hash)
	var source = _offers.get(hash, {}).get("source")
	return source if source is String else ""


## The items the match needs that this device doesn't hold yet.
func missing() -> Array:
	return lobby.needed_content.filter(func(item): return _valid(item) and not has(item.hash))


func poll() -> void:
	if not lobby.link.is_open():
		return
	_follow_needs()
	if lobby.state != "lobby":
		return
	var now := Time.get_ticks_usec()
	_request(now)
	_serve()
	_report(now)
	lobby.link.flush()


func _path(hash: String) -> String:
	return cache_dir.path_join(hash)


func _valid(item) -> bool:
	if not item is Dictionary or not item.get("hash") is String or not item.get("size") is int:
		return false
	var hash: String = item.hash
	return hash.length() == 64 and hash == hash.to_lower() and hash.is_valid_hex_number() and item.size >= 0


func _needed() -> Dictionary:
	var needed := {}
	for item in lobby.needed_content:
		if _valid(item):
			needed[item.hash] = item
	return needed


# Starts a fetch for each needed item this device lacks, and drops fetches no longer needed.
func _follow_needs() -> void:
	var needed := _needed()
	for hash in needed:
		if _fetches.has(hash) or has(hash):
			continue
		var item: Dictionary = needed[hash]
		_fetches[hash] = {"item": item, "from": 0, "offset": 0, "state": "idle", "tried": [], "retry_at": 0, "told": false, "file": null, "hashing": null, "gap": -1}
		if item.size > max_item_bytes:
			_fail(hash, "Too big (%d bytes, at most %d)" % [item.size, max_item_bytes])
	for hash in _fetches.keys():
		if not needed.has(hash):
			if _fetches[hash].file:
				_fetches[hash].file.close()
			_fetches.erase(hash)
			_held.erase(hash)


func _request(now: int) -> void:
	var fetching := _fetches.values().filter(func(fetch): return fetch.state == "fetching").size()
	for hash in _fetches.keys():
		var fetch: Dictionary = _fetches[hash]
		if fetch.state == "waiting" and now >= fetch.retry_at:
			fetch.state = "idle"
			fetch.tried = []
		if fetch.state != "idle" or fetching >= FETCHES:
			continue
		if fetch.file == null and not _open_part(fetch):
			_fail(hash, "Couldn't write to %s" % cache_dir)
			continue
		if fetch.offset >= fetch.item.size:
			_finish(hash)
			continue
		var source := _pick_source(fetch)
		if source < 0:
			continue
		if source == 0:
			fetch.state = "waiting"
			fetch.retry_at = now + RETRY_USEC
			_refuse_held(hash)
			if not fetch.told:
				fetch.told = true
				failed.emit(fetch.item, "Nobody has it")
			continue
		fetch.from = source
		fetch.state = "fetching"
		fetch.gap = -1
		fetching += 1
		_send_want(source, hash, fetch.offset)


# Who to ask: guests ask the host; the host asks each guest in turn. 0 when nobody is
# left to ask, -1 to wait (the host is reconnecting).
func _pick_source(fetch: Dictionary) -> int:
	if not lobby.is_host:
		if fetch.tried.has(LocalNetLink.HOST_ID):
			return 0
		return LocalNetLink.HOST_ID if lobby.link.is_peer_connected(LocalNetLink.HOST_ID) else -1
	var ids := lobby.members.keys()
	ids.sort()
	for id in ids:
		if id != lobby.local_id and not fetch.tried.has(id) and lobby.link.is_peer_connected(id):
			return id
	return 0


func _open_part(fetch: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var part := _path(fetch.item.hash) + ".part"
	var file := FileAccess.open(part, FileAccess.READ_WRITE if FileAccess.file_exists(part) else FileAccess.WRITE_READ)
	if file == null:
		return false
	var length := file.get_length()
	if length > fetch.item.size:
		file.close()
		file = FileAccess.open(part, FileAccess.WRITE_READ)
		if file == null:
			return false
		length = 0
	# Picks up the hash of what an earlier session already wrote.
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	file.seek(0)
	while file.get_position() < length:
		hashing.update(file.get_buffer(mini(length - file.get_position(), 1 << 20)))
	file.seek(length)
	fetch.file = file
	fetch.hashing = hashing
	fetch.offset = length
	return true


func _finish(hash: String) -> void:
	var fetch: Dictionary = _fetches[hash]
	fetch.file.close()
	fetch.file = null
	var part := _path(hash) + ".part"
	if fetch.hashing.finish().hex_encode() != hash:
		DirAccess.remove_absolute(part)
		fetch.hashing = null
		_fail(hash, "Didn't match its hash")
		return
	if FileAccess.file_exists(_path(hash)):
		DirAccess.remove_absolute(_path(hash))
	if DirAccess.rename_absolute(part, _path(hash)) != OK:
		_fail(hash, "Couldn't write to %s" % cache_dir)
		return
	_fetches.erase(hash)
	# The host passes it on to the guests that asked while it was fetching.
	var waiting: Dictionary = _held.get(hash, {})
	_held.erase(hash)
	for id in waiting:
		_start_send(id, hash, waiting[id])
	received.emit(fetch.item, _path(hash))


func _fail(hash: String, reason: String) -> void:
	var fetch: Dictionary = _fetches[hash]
	if fetch.file:
		fetch.file.close()
		fetch.file = null
	fetch.state = "failed"
	_refuse_held(hash)
	failed.emit(fetch.item, reason)


# The host tells guests waiting for an item it can't get that nobody has it.
func _refuse_held(hash: String) -> void:
	for id in _held.get(hash, {}):
		_send_nope(id, hash, NOPE_UNAVAILABLE)
	_held.erase(hash)


# What this device may serve for [param hash]: its offers, and on the host, needed items
# it has downloaded.
func _source_for(hash: String) -> Dictionary:
	if _offers.has(hash):
		return _offers[hash]
	if lobby.is_host and FileAccess.file_exists(_path(hash)):
		var item: Dictionary = _needed().get(hash, {})
		if not item.is_empty():
			return {"item": item, "source": _path(hash)}
	return {}


func _start_send(id: int, hash: String, offset: int) -> void:
	var offered := _source_for(hash)
	if offered.is_empty():
		_send_nope(id, hash, NOPE_MISSING)
		return
	var key := "%d:%s" % [id, hash]
	_close_send(key)
	_sends[key] = {"id": id, "hash": hash, "raw": hash.hex_decode(), "size": offered.item.size, "source": offered.source, "file": null, "cursor": clampi(offset, 0, offered.item.size), "in_flight": []}


func _close_send(key: String) -> void:
	if _sends.has(key) and _sends[key].file:
		_sends[key].file.close()
	_sends.erase(key)


# Sends chunks round the transfers, one each per pass, within each peer's window and the
# frame's budget.
func _serve() -> void:
	var flying := {}
	for send in _sends.values():
		flying[send.id] = flying.get(send.id, 0) + send.in_flight.size()
	var budget := budget_bytes
	var sent := true
	while sent and budget > 0:
		sent = false
		for key in _sends.keys():
			var send: Dictionary = _sends[key]
			if flying[send.id] >= WINDOW or send.cursor >= send.size or not lobby.link.is_peer_connected(send.id):
				continue
			var length := mini(CHUNK_BYTES, send.size - send.cursor)
			var data := _read(send, length)
			if data.size() != length:
				_send_nope(send.id, send.hash, NOPE_UNREADABLE)
				_close_send(key)
				continue
			var packet := _packet(KIND_CHUNK, send.raw, send.cursor)
			packet.append_array(data)
			lobby.link.send(send.id, LocalNetLink.CHANNEL_CONTENT, packet, true)
			send.in_flight.append(send.cursor)
			flying[send.id] += 1
			send.cursor += length
			budget -= length
			sent = true
			if budget <= 0:
				break


func _read(send: Dictionary, length: int) -> PackedByteArray:
	var source = send.source
	if source is PackedByteArray:
		return source.slice(send.cursor, send.cursor + length)
	if source is Callable:
		var data = source.call(send.cursor, length)
		return data if data is PackedByteArray else PackedByteArray()
	if send.file == null:
		send.file = FileAccess.open(str(source), FileAccess.READ)
		if send.file == null:
			return PackedByteArray()
	send.file.seek(send.cursor)
	return send.file.get_buffer(length)


# Tells the host how much of what the match needs is still missing, and again if the
# member list doesn't show it after a while.
func _report(now: int) -> void:
	var key := lobby._needed_content_key()
	if key == "":
		return
	var report := {"need": key, "missing": missing().size()}
	var shown = lobby.members.get(lobby.local_id, {}).get("content")
	if report != shown and (report != _reported or now >= _next_report_usec):
		_reported = report
		_next_report_usec = now + REPORT_USEC
		lobby._report_content(report)
	if report.missing == 0 and not lobby.needed_content.is_empty() and _present_key != key:
		_present_key = key
		all_present.emit()


func _on_received(id: int, channel: int, bytes: PackedByteArray) -> void:
	if channel != LocalNetLink.CHANNEL_CONTENT or bytes.size() < _HEADER - 4:
		return
	# Guests only hear from the host, and the host only from members.
	if (lobby.is_host and not lobby.members.has(id)) or (not lobby.is_host and id != LocalNetLink.HOST_ID):
		return
	var hash := bytes.slice(1, 33).hex_encode()
	var kind := bytes[0]
	if kind == KIND_NOPE:
		_on_nope(id, hash, bytes[33])
		return
	if bytes.size() < _HEADER:
		return
	var offset := bytes.decode_u32(33)
	match kind:
		KIND_WANT: _on_want(id, hash, offset)
		KIND_CHUNK: _on_chunk(id, hash, offset, bytes.slice(_HEADER))
		KIND_ACK: _on_ack(id, hash, offset)


func _on_want(id: int, hash: String, offset: int) -> void:
	if not _source_for(hash).is_empty():
		_start_send(id, hash, offset)
	elif lobby.is_host and _fetches.has(hash) and _fetches[hash].state in ["idle", "fetching"]:
		# Still fetching it from a guest: pass it on once it's here.
		_held.get_or_add(hash, {})[id] = offset
	else:
		_send_nope(id, hash, NOPE_UNAVAILABLE if lobby.is_host and _fetches.has(hash) else NOPE_MISSING)
	lobby.link.flush()


func _on_chunk(id: int, hash: String, offset: int, data: PackedByteArray) -> void:
	var fetch: Dictionary = _fetches.get(hash, {})
	# Only items this device asked for, from the device it asked.
	if fetch.is_empty() or fetch.state != "fetching" or fetch.from != id:
		return
	if offset < fetch.offset:
		_send_ack(id, hash, offset)
		return
	if offset > fetch.offset:
		# Something went missing (a reconnect); ask again from where this device is.
		if fetch.gap != fetch.offset:
			fetch.gap = fetch.offset
			_send_want(id, hash, fetch.offset)
		return
	if offset + data.size() > fetch.item.size:
		_fail(hash, "Bigger than its size")
		return
	fetch.file.store_buffer(data)
	if fetch.file.get_error() != OK:
		_fail(hash, "Couldn't write to %s" % cache_dir)
		return
	fetch.hashing.update(data)
	fetch.offset += data.size()
	_send_ack(id, hash, offset)
	progress.emit(hash, fetch.offset, fetch.item.size)
	if fetch.offset >= fetch.item.size:
		_finish(hash)


func _on_ack(id: int, hash: String, offset: int) -> void:
	var key := "%d:%s" % [id, hash]
	if not _sends.has(key):
		return
	var send: Dictionary = _sends[key]
	send.in_flight.erase(offset)
	if send.cursor >= send.size and send.in_flight.is_empty():
		_close_send(key)


func _on_nope(id: int, hash: String, reason: int) -> void:
	var fetch: Dictionary = _fetches.get(hash, {})
	if fetch.is_empty() or fetch.state != "fetching" or fetch.from != id:
		return
	fetch.from = 0
	fetch.tried.append(id)
	if lobby.is_host:
		# Ask the next guest.
		fetch.state = "idle"
		return
	fetch.state = "waiting"
	fetch.retry_at = Time.get_ticks_usec() + RETRY_USEC
	if not fetch.told:
		fetch.told = true
		failed.emit(fetch.item, "Couldn't be read" if reason == NOPE_UNREADABLE else "Nobody has it")


# Host: a member left; whatever it was sending is asked of someone else.
func _on_member_left(id: int, _reason: String) -> void:
	_forget_peer(id)
	for hash in _fetches:
		var fetch: Dictionary = _fetches[hash]
		if fetch.from == id and fetch.state == "fetching":
			fetch.from = 0
			fetch.state = "idle"


# Host: a member is back. Anything in flight was lost: it asks again for what it was
# fetching, and this device asks again for what it was fetching from it.
func _on_member_resumed(id: int) -> void:
	if not lobby.is_host:
		return
	_forget_peer(id)
	_ask_again(id)


# Guest: back with the host.
func _on_connection_resumed() -> void:
	_forget_peer(LocalNetLink.HOST_ID)
	_ask_again(LocalNetLink.HOST_ID)


func _forget_peer(id: int) -> void:
	for key in _sends.keys():
		if _sends[key].id == id:
			_close_send(key)
	for hash in _held:
		_held[hash].erase(id)


func _ask_again(id: int) -> void:
	for hash in _fetches:
		var fetch: Dictionary = _fetches[hash]
		if fetch.from == id and fetch.state == "fetching":
			fetch.gap = -1
			_send_want(id, hash, fetch.offset)
	lobby.link.flush()


func _on_closed(_reason: String) -> void:
	_reset()


func _reset() -> void:
	for fetch in _fetches.values():
		if fetch.file:
			fetch.file.close()
	for key in _sends.keys():
		_close_send(key)
	_fetches.clear()
	_held.clear()
	_reported = {}
	_present_key = ""


func _packet(kind: int, raw_hash: PackedByteArray, offset: int) -> PackedByteArray:
	var packet := PackedByteArray([kind])
	packet.append_array(raw_hash)
	packet.resize(_HEADER)
	packet.encode_u32(33, offset)
	return packet


func _send_want(id: int, hash: String, offset: int) -> void:
	lobby.link.send(id, LocalNetLink.CHANNEL_CONTENT, _packet(KIND_WANT, hash.hex_decode(), offset), true)


func _send_ack(id: int, hash: String, offset: int) -> void:
	lobby.link.send(id, LocalNetLink.CHANNEL_CONTENT, _packet(KIND_ACK, hash.hex_decode(), offset), true)


func _send_nope(id: int, hash: String, reason: int) -> void:
	var packet := PackedByteArray([KIND_NOPE])
	packet.append_array(hash.hex_decode())
	packet.append(reason)
	lobby.link.send(id, LocalNetLink.CHANNEL_CONTENT, packet, true)
