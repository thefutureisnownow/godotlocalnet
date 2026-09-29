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
##
## Time sync keeps devices' schedules together, so the same tick falls due at the same
## moment. They drift apart when devices wait different amounts during a hiccup, or when
## the clock offset measured at the start is a few milliseconds out; the device ahead then
## waits a little on almost every frame and runs ticks in bursts. Each packet says which
## tick its sender's schedule had reached (not the tick it managed to run, which waiting
## holds back and would hide the lead), and the sender's reading of the receiver, so the
## time in flight cancels out ([method LocalNetInputSync.clock_lead]). A device more than
## [member sync_threshold] ticks ahead of any peer eases back, using at most
## [member sync_rate] of the elapsed time.

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
var time_sync := true
var sync_threshold := 0.5
var sync_rate := 0.1
## Fresh packets needed from every peer before acting again, so one correction settles first.
var sync_samples := 5

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
## How much time sync slowed this device down in total.
var eased_usec := 0

var _stall_since := 0
var _last_advance_usec := -1
var _ease_owed := 0


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
	sync.local_tick = tick
	sync.schedule_usec = schedule_usec
	sync.tick_usec = tick_usec
	sync.flush()
	# A frame that stepped some ticks before running out is slow, not frozen.
	_track_stall(stalled and ran == 0, now)
	var behind := due_tick(now) - tick
	if behind > slack_ticks:
		var shift := ceili((behind - slack_ticks) * tick_usec)
		schedule_usec += shift
		shifted_usec += shift
	if time_sync:
		_sync_time(now)
	# Packets arriving before the next frame are timed against the schedule as it now stands.
	sync.schedule_usec = schedule_usec
	return ran


## The last tick due by [param now] on the current schedule.
func due_tick(now := Time.get_ticks_usec()) -> int:
	return int(floor((now - schedule_usec) / tick_usec))


## How many ticks ahead of the slowest peer this device's schedule runs. Negative means
## behind. Until a peer has sent its own reading, half the round trip stands in for the
## time in flight.
func advantage() -> float:
	var worst := -INF
	for id in sync.peers():
		if sync.advantage_samples(id) > 0:
			var lead := sync.clock_lead(id)
			if is_nan(lead):
				lead = sync.tick_advantage(id) - sync.link.rtt_msec(id) * 500.0 / tick_usec
			worst = maxf(worst, lead)
	return worst if worst != -INF else 0.0


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


# Decides how far to ease back once every peer has sent fresh readings, then pays it
# off a little each frame so the game only ever runs slightly slow.
func _sync_time(now: int) -> void:
	var frame := now - _last_advance_usec if _last_advance_usec >= 0 else 0
	_last_advance_usec = now
	if _ease_owed > 0:
		var ease := mini(_ease_owed, int(frame * sync_rate))
		schedule_usec += ease
		eased_usec += ease
		_ease_owed -= ease
		if _ease_owed > 0:
			return
		# Readings taken while easing are out of date.
		sync.clear_advantage()
		return
	for id in sync.peers():
		if sync.advantage_samples(id) < sync_samples:
			return
	var ahead := advantage()
	if ahead > sync_threshold:
		_ease_owed = ceili(ahead * tick_usec)
	sync.clear_advantage()


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
