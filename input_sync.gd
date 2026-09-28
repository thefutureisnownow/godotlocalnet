class_name LocalNetInputSync
extends RefCounted
## Lockstep input exchange: every device simulates tick t only once it holds every
## player's input for t, so a deterministic game stays identical everywhere.
##
## Local input is scheduled [member delay] ticks ahead to hide the network. Each packet
## carries every input the receiver hasn't acknowledged yet, so lost packets cost nothing
## but a little redundancy. With more than two players the host relays. Confirmed inputs
## are kept until [method discard_before], which leaves room to add rollback later.
## Pair every [method add_local_input] batch with a [method flush].

signal remote_input(slot: int, tick: int, arrived_usec: int)
signal desynced(tick: int, peer_id: int)

const KIND_INPUTS := 10
const KIND_CHECKSUM := 11
const MAX_RUN := 32

var link: LocalNetLink
var slot_count: int
var local_slot: int
var delay: int
var input_size: int

var _peer_slots: Dictionary
var _inputs := []
var _latest := PackedInt32Array()
var _acks := {}
var _heard := {}
var _told := {}
var _discarded_below := 0
var _checksums := {}
var _remote_checksums := {}


## [param peer_slots] maps each link peer to the slot it sends: see [method LocalNetLobby.peer_slots].
func _init(net_link: LocalNetLink, slots: int, own_slot: int, peer_slots: Dictionary, input_delay := 2, bytes_per_input := 2) -> void:
	link = net_link
	slot_count = slots
	local_slot = own_slot
	_peer_slots = peer_slots
	delay = input_delay
	input_size = bytes_per_input
	var blank := PackedByteArray()
	blank.resize(input_size)
	_latest.resize(slot_count)
	for slot in slot_count:
		var inputs := {}
		for tick in delay:
			inputs[tick] = blank
		_inputs.append(inputs)
		_latest[slot] = delay - 1
	for id in _peer_slots:
		_acks[id] = _latest.duplicate()
		_told[id] = _latest.duplicate()
		_heard[id] = false
	link.received.connect(_on_received)


func close() -> void:
	if link.received.is_connected(_on_received):
		link.received.disconnect(_on_received)


## The next tick that needs local input.
func next_local_tick() -> int:
	return _latest[local_slot] + 1


func add_local_input(tick: int, input: PackedByteArray) -> void:
	assert(tick == next_local_tick(), "Local input must arrive one tick at a time")
	var sized := input.duplicate()
	sized.resize(input_size)
	_inputs[local_slot][tick] = sized
	_latest[local_slot] = tick


## Highest tick for which every earlier input of [param slot] is known.
func latest(slot: int) -> int:
	return _latest[slot]


func is_ready(tick: int) -> bool:
	for slot in slot_count:
		if _latest[slot] < tick:
			return false
	return true


func inputs(tick: int) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for slot in slot_count:
		result.append(_inputs[slot][tick])
	return result


## Each slot's input for [param tick], or its last known input where [param tick] hasn't
## arrived yet: the usual guess when running ahead of the network.
func predicted_inputs(tick: int) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for slot in slot_count:
		var known := mini(tick, _latest[slot])
		if _inputs[slot].has(known):
			result.append(_inputs[slot][known])
		else:
			var blank := PackedByteArray()
			blank.resize(input_size)
			result.append(blank)
	return result


## Sends each peer what it's missing and acknowledges what arrived.
func flush() -> void:
	for id in _peer_slots:
		var packet := _packet_for(id)
		if not packet.is_empty():
			link.send(id, LocalNetLink.CHANNEL_REALTIME, packet, false)
	link.flush()


## Frees inputs before [param tick] that every peer has confirmed.
func discard_before(tick: int) -> void:
	for id in _acks:
		for slot in slot_count:
			tick = mini(tick, _acks[id][slot] + 1)
	for old in range(_discarded_below, tick):
		for slot in slot_count:
			_inputs[slot].erase(old)
		_checksums.erase(old)
		_remote_checksums.erase(old)
	_discarded_below = maxi(_discarded_below, tick)


## Shares a hash of the game state at [param tick]; a mismatch emits [signal desynced].
func report_checksum(tick: int, value: int) -> void:
	value &= 0xFFFFFFFF
	_checksums[tick] = value
	var packet := PackedByteArray([KIND_CHECKSUM])
	packet.resize(9)
	packet.encode_u32(1, tick)
	packet.encode_u32(5, value)
	for id in _peer_slots:
		link.send(id, LocalNetLink.CHANNEL_EVENTS, packet, true)
	_compare(tick)


func _should_send(id: int, slot: int) -> bool:
	if slot == _peer_slots[id]:
		return false
	return link.is_host or slot == local_slot


func _packet_for(id: int) -> PackedByteArray:
	var runs := []
	for slot in slot_count:
		if _should_send(id, slot):
			var first: int = _acks[id][slot] + 1
			var last := mini(_latest[slot], first + MAX_RUN - 1)
			if last >= first:
				runs.append([slot, first, last])
	if runs.is_empty() and not _heard[id] and _told[id] == _latest:
		return PackedByteArray()
	_heard[id] = false
	_told[id] = _latest.duplicate()
	var buffer := StreamPeerBuffer.new()
	buffer.put_u8(KIND_INPUTS)
	buffer.put_u8(slot_count)
	for slot in slot_count:
		buffer.put_32(_latest[slot])
	buffer.put_u8(runs.size())
	for run in runs:
		buffer.put_u8(run[0])
		buffer.put_32(run[1])
		buffer.put_u8(run[2] - run[1] + 1)
		for tick in range(run[1], run[2] + 1):
			buffer.put_data(_inputs[run[0]][tick])
	return buffer.data_array


func _on_received(id: int, channel: int, bytes: PackedByteArray) -> void:
	if bytes.is_empty() or not _peer_slots.has(id):
		return
	if channel == LocalNetLink.CHANNEL_REALTIME and bytes[0] == KIND_INPUTS:
		_read_inputs(id, bytes)
	elif channel == LocalNetLink.CHANNEL_EVENTS and bytes[0] == KIND_CHECKSUM and bytes.size() >= 9:
		var tick := bytes.decode_u32(1)
		_remote_checksums.get_or_add(tick, {})[id] = bytes.decode_u32(5)
		_compare(tick)


func _read_inputs(id: int, bytes: PackedByteArray) -> void:
	if bytes.size() < 2 or bytes[1] != slot_count or bytes.size() < 3 + slot_count * 4:
		return
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	buffer.seek(2)
	for slot in slot_count:
		_acks[id][slot] = maxi(_acks[id][slot], buffer.get_32())
	_heard[id] = true
	var now := Time.get_ticks_usec()
	var runs := buffer.get_u8()
	for i in runs:
		if buffer.get_available_bytes() < 6:
			return
		var slot := buffer.get_u8()
		var first := buffer.get_32()
		var count := buffer.get_u8()
		if slot >= slot_count or buffer.get_available_bytes() < count * input_size:
			return
		var accepted: bool = slot != local_slot and (slot == _peer_slots[id] if link.is_host else true)
		for tick in range(first, first + count):
			var input: PackedByteArray = buffer.get_data(input_size)[1]
			if accepted and tick > _latest[slot] and not _inputs[slot].has(tick):
				_inputs[slot][tick] = input
				remote_input.emit(slot, tick, now)
		while _inputs[slot].has(_latest[slot] + 1):
			_latest[slot] += 1


func _compare(tick: int) -> void:
	if not _checksums.has(tick) or not _remote_checksums.has(tick):
		return
	for id in _remote_checksums[tick]:
		if _remote_checksums[tick][id] != _checksums[tick]:
			desynced.emit(tick, id)
	_remote_checksums.erase(tick)
