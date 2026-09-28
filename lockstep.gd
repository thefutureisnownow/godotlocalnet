class_name LocalNetLockstep
extends RefCounted
## Runs a deterministic game in lockstep on top of [LocalNetInputSync].
##
## Each frame, [method advance] works out which ticks are due on the shared schedule,
## samples local input [member LocalNetInputSync.delay] ticks ahead, steps every tick whose
## inputs are all known, reports checksums and frees old inputs. The game supplies three
## callables: sample input for a tick, step one tick, and hash its state.
##
## When a tick's inputs are missing the game waits ([signal waiting]). Afterwards it does
## not race through the backlog: the schedule moves back so the game resumes smoothly,
## [member slack_ticks] behind at most. A device that can't keep up slows everyone down
## the same way. [member predict] runs on guessed inputs instead of waiting, which
## measures the network alone and is where rollback would start.

signal waiting(slots: Array[int])
signal resumed(stalled_usec: int)

var sync: LocalNetInputSync
var tick := 0
var tick_usec: float
## When tick 0 is due on this device's clock; moves back after stalls.
var schedule_usec: int
var predict := false
var checksum_every := 60
var max_ticks_per_frame := 8
var slack_ticks := 2
## Confirmed inputs kept behind the current tick, for replays or rollback.
var keep_ticks := 240

var sample_input: Callable
var step: Callable
var checksum: Callable

var frames := 0
## Frames where ticks were due but none could run.
var stalled_frames := 0
var longest_stall_usec := 0
var total_stall_usec := 0
var predicted_ticks := 0
var shifted_usec := 0

var _stall_since := 0


## [param sample] is (tick) -> PackedByteArray, [param simulate] is
## (tick, inputs: Array[PackedByteArray]) -> void and [param hash_state] () -> int.
func _init(input_sync: LocalNetInputSync, start_usec: int, ticks_per_second: int, sample: Callable, simulate: Callable, hash_state := Callable()) -> void:
	sync = input_sync
	schedule_usec = start_usec
	tick_usec = 1_000_000.0 / ticks_per_second
	sample_input = sample
	step = simulate
	checksum = hash_state


## Runs every tick due by [param now]; returns how many ran.
func advance(now := Time.get_ticks_usec()) -> int:
	frames += 1
	var due := due_tick(now)
	var ran := 0
	var stalled := false
	while tick <= due and ran < max_ticks_per_frame:
		while sync.next_local_tick() <= tick + sync.delay:
			sync.add_local_input(sync.next_local_tick(), sample_input.call(sync.next_local_tick()))
		var inputs: Array[PackedByteArray]
		if sync.is_ready(tick):
			inputs = sync.inputs(tick)
		elif predict:
			inputs = sync.predicted_inputs(tick)
			predicted_ticks += 1
		else:
			stalled = true
			break
		step.call(tick, inputs)
		tick += 1
		ran += 1
		if tick % checksum_every == 0:
			if checksum.is_valid() and not predict:
				sync.report_checksum(tick, checksum.call())
			sync.discard_before(tick - keep_ticks)
	sync.flush()
	# A frame that stepped some ticks before running out is slow, not frozen.
	_track_stall(stalled and ran == 0, now)
	var behind := due_tick(now) - tick
	if behind > slack_ticks:
		var shift := ceili((behind - slack_ticks) * tick_usec)
		schedule_usec += shift
		shifted_usec += shift
	return ran


## The last tick due by [param now] on the current schedule.
func due_tick(now := Time.get_ticks_usec()) -> int:
	return int(floor((now - schedule_usec) / tick_usec))


## When [param at_tick] is due on the current schedule.
func scheduled_usec(at_tick: int) -> int:
	return schedule_usec + int(at_tick * tick_usec)


func is_waiting() -> bool:
	return _stall_since != 0


## Slots whose input for the current tick hasn't arrived.
func waiting_on() -> Array[int]:
	var slots: Array[int] = []
	for slot in sync.slot_count:
		if sync.latest(slot) < tick:
			slots.append(slot)
	return slots


func _track_stall(stalled: bool, now: int) -> void:
	if stalled:
		stalled_frames += 1
		if _stall_since == 0:
			_stall_since = now
			waiting.emit(waiting_on())
	elif _stall_since != 0:
		var stalled_for := now - _stall_since
		total_stall_usec += stalled_for
		longest_stall_usec = maxi(longest_stall_usec, stalled_for)
		_stall_since = 0
		resumed.emit(stalled_for)


## Closes out a stall still in progress, for final statistics.
func finish(now := Time.get_ticks_usec()) -> void:
	_track_stall(false, now)
