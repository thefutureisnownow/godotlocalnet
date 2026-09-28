extends SceneTree
# Runs the link test app as real, separate host and guest processes over loopback and
# reads the results each one saves. Covers what the unit tests can't: the app's own flow.
# Run: godot --headless --path . --script tests/test_demo.gd
var checks := 0
var failures: Array[String] = []
var folder := OS.get_cache_dir().path_join("localnet-demo-test")


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)


func run() -> void:
	two_matches_by_address()
	slow_link()
	free_run()
	three_players()
	print("LOCALNET DEMO: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures:
		print("  FAIL ", failure)
	quit(0 if failures.is_empty() else 1)


# Starts the host, then each guest a moment later; waits for all to exit and returns
# the saved results, oldest first.
func play(host_args: Array, guests: Array, timeout := 40.0) -> Array[String]:
	DirAccess.make_dir_recursive_absolute(folder)
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(file))
	var pids := [launch(host_args)]
	OS.delay_msec(1500)
	for guest_args in guests:
		pids.append(launch(guest_args))
		OS.delay_msec(300)
	var until := Time.get_ticks_msec() + int(timeout * 1000)
	while Time.get_ticks_msec() < until and pids.any(func(pid): return OS.is_process_running(pid)):
		OS.delay_msec(200)
	var hung := pids.filter(func(pid): return OS.is_process_running(pid))
	check(hung.is_empty(), "Every process quits on its own")
	for pid in hung:
		OS.kill(pid)
	var files := Array(DirAccess.get_files_at(folder))
	files.sort()
	var results: Array[String] = []
	for file in files:
		results.append(FileAccess.get_file_as_string(folder.path_join(file)))
	return results


func launch(args: Array) -> int:
	var all := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--"] + args + ["--quit", "--results=" + folder]
	return OS.create_process(OS.get_executable_path(), PackedStringArray(all))


func count(results: Array[String], text: String) -> int:
	return results.filter(func(r): return r.contains(text)).size()


func two_matches_by_address() -> void:
	var results := play(["--host", "--name=Host", "--seconds=3", "--matches=2"], [["--join=127.0.0.1", "--name=Guest"]])
	check(results.size() == 4, "Host and guest each save two results (%d)" % results.size())
	check(count(results, "LOCALNET RESULT · Finished") == 4, "Both matches finish on both devices")
	check(count(results, "no desync") == 4, "Neither match drifts apart")
	check(count(results, "· host ·") == 2 and count(results, "· guest ·") == 2, "The guest joined by typing only the address")
	check(count(results, "match 2") == 2, "The rematch runs on both devices")
	check(count(results, "Ran 360 of 360 ticks") == 4, "Every match runs its full length")
	check(count(results, "with input delay 2 ") == 4, "The automatic delay picks the minimum on loopback")


func slow_link() -> void:
	var results := play(["--host", "--name=Host", "--seconds=3", "--delay=1"], [["--join", "--loopback", "--name=Guest", "--latency=40", "--jitter=20"]])
	check(results.size() == 2 and count(results, "Finished") == 2 and count(results, "no desync") == 2, "A link much slower than the delay still finishes in sync")
	var moved := results.filter(func(r): return r.contains("schedule moved back") and not r.contains("schedule moved back 0 ms"))
	check(moved.size() == 2, "Both devices ease their schedule back instead of fast-forwarding")


func free_run() -> void:
	var results := play(["--host", "--name=Host", "--seconds=3", "--free"], [["--join", "--loopback", "--name=Guest", "--latency=30"]])
	check(results.size() == 2 and count(results, "ticks ran on a guess") == 2, "Free-run reports its guesses on both devices")
	check(count(results, "Stalled frames 0 of") == 2, "Free-run never stalls")


func three_players() -> void:
	var results := play(["--host", "--name=Host", "--seconds=3", "--players=3"], [["--join", "--loopback", "--name=One"], ["--join", "--loopback", "--name=Two"]])
	check(results.size() == 3 and count(results, "Finished") == 3 and count(results, "no desync") == 3, "Three players finish in sync")
	check(results.all(func(r): return r.contains("slot") and r.split("  from ").size() == 3), "Each device reports both other players separately")
