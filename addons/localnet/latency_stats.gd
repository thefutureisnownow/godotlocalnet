class_name LocalNetLatencyStats
extends RefCounted
## Records how late each remote input arrived, measured from the moment the other device
## sampled it on the shared schedule. That answers the design questions directly: with an
## input delay of d ticks, how often would lockstep stall, and how many ticks would
## rollback have to rewrite?

const MAX_SAMPLES := 200_000

var tick_usec: int
var samples := PackedInt64Array()
var _sorted := PackedInt64Array()
var _dirty := false


func _init(ticks_per_second: int) -> void:
	tick_usec = int(1_000_000.0 / ticks_per_second)


func add(lateness_usec: int) -> void:
	if samples.size() < MAX_SAMPLES:
		samples.append(lateness_usec)
		_dirty = true


func count() -> int:
	return samples.size()


## Lateness at percentile [param p] (0 to 100), in milliseconds.
func percentile_msec(p: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := _sorted_samples()
	var index := clampi(int(ceil(p / 100.0 * sorted.size())) - 1, 0, sorted.size() - 1)
	return sorted[index] / 1000.0


## Share of inputs that would arrive after they were needed with [param delay] ticks of input delay.
func stall_share(delay: int) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := _sorted_samples()
	var late := sorted.size() - sorted.bsearch(delay * tick_usec, false)
	return float(late) / sorted.size()


## Smallest input delay that keeps stalls at or under [param share].
func delay_for(share: float) -> int:
	for delay in range(0, 121):
		if stall_share(delay) <= share:
			return delay
	return 120


func summary() -> String:
	if samples.is_empty():
		return "No remote inputs yet"
	var lines := PackedStringArray()
	lines.append("Input lateness over %d inputs (ms): p50 %.1f  p90 %.1f  p99 %.1f  max %.1f" % [count(), percentile_msec(50), percentile_msec(90), percentile_msec(99), percentile_msec(100)])
	var shares := PackedStringArray()
	for delay in range(0, 9):
		shares.append("%d:%s" % [delay, _percent(stall_share(delay))])
	lines.append("Late at input delay (ticks): " + "  ".join(shares))
	lines.append("Delay for <=1%% late: %d ticks (%.1f ms)   <=0.1%%: %d ticks (%.1f ms)" % [delay_for(0.01), delay_for(0.01) * tick_usec / 1000.0, delay_for(0.001), delay_for(0.001) * tick_usec / 1000.0])
	return "\n".join(lines)


func _sorted_samples() -> PackedInt64Array:
	if _dirty:
		_sorted = samples.duplicate()
		_sorted.sort()
		_dirty = false
	return _sorted


static func _percent(share: float) -> String:
	if share == 0.0:
		return "0%"
	if share < 0.01:
		return "%.2f%%" % (share * 100)
	return "%.0f%%" % (share * 100)
