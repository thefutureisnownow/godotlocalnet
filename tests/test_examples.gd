extends SceneTree
# Plays every example in examples/ as a host and its guests side by side in one process,
# over loopback, through the examples' own functions: find the host, join, start, play
# with the arrow keys held, come back to the lobby, start again, and leave.
# Run: godot --headless --path . --script tests/test_examples.gd

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)


func run() -> void:
	Engine.max_fps = 120
	await player_vs_player()
	await spectators()
	await solo_with_spectator()
	await big_screen()
	await content_sharing()
	print("LOCALNET EXAMPLES: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures:
		print("  FAIL ", failure)
	quit(0 if failures.is_empty() else 1)


func spawn(example: String, settings := {}) -> Control:
	var node: Control = load("res://examples/%s/%s.tscn" % [example, example]).instantiate()
	node.scan_targets = PackedStringArray(["127.0.0.1"])
	for key in settings:
		node.set(key, settings[key])
	root.add_child(node)
	return node


func wait_until(seconds: float, done: Callable) -> bool:
	var until := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < until:
		if done.call():
			return true
		await process_frame
	return done.call()


func wait(seconds: float) -> void:
	await wait_until(seconds, func(): return false)


# A guest finds the host through discovery and joins it.
func join(host: Control, guest: Control, label: String, role := "") -> bool:
	var found := func():
		return guest.discovery.sessions().filter(func(s): return s.id == host.lobby.session_id)
	await wait_until(5.0, func(): return not found.call().is_empty())
	var sessions: Array = found.call()
	check(not sessions.is_empty(), "%s: the guest finds the host" % label)
	if sessions.is_empty():
		return false
	if role:
		guest.join_game(sessions[0], role)
	else:
		guest.join_game(sessions[0])
	var joined := await wait_until(5.0, func(): return guest.lobby and guest.lobby.state == "lobby" and host.lobby.members.has(guest.lobby.local_id))
	check(joined, "%s: the guest joins" % label)
	return joined


# Starts a match, plays it with right and down held, and checks every device ends up
# with the same dots. Returns false if it never got going.
func play(everyone: Array, label: String, moving := true) -> bool:
	var host: Control = everyone[0]
	host.start_match()
	var began := await wait_until(5.0, func(): return everyone.all(func(n): return n.lockstep != null and n.lockstep.tick > 10))
	check(began, "%s: the match starts everywhere" % label)
	if not began:
		return false
	var desyncs := []
	for n in everyone:
		n.lockstep.sync.desynced.connect(func(tick, _peer): desyncs.append(tick))
	var before: Array = host.dots.positions.duplicate()
	if moving:
		Input.action_press("ui_right")
		Input.action_press("ui_down")
	await wait(1.5)
	Input.action_release("ui_right")
	Input.action_release("ui_down")
	await wait(1.5)
	var positions := everyone.map(func(n): return n.dots.positions)
	check(positions.all(func(p): return p == positions[0]), "%s: every device has the same dots (%s)" % [label, positions])
	if moving:
		check(positions[0] != before, "%s: the players' dots moved" % label)
	check(desyncs.is_empty() and everyone.all(func(n): return not n.lockstep.sync._checksums.is_empty()), "%s: checksums agree" % label)
	host.lobby.return_to_lobby()
	var back := await wait_until(3.0, func(): return everyone.all(func(n): return n.lockstep == null and n.lobby.state == "lobby"))
	check(back, "%s: everyone comes back to the lobby" % label)
	return back


# The host leaves; its guests are told and go back to the home screen.
func host_leaves(everyone: Array, label: String) -> void:
	var host: Control = everyone[0]
	host.queue_free()
	var guests := everyone.slice(1)
	check(await wait_until(3.0, func(): return guests.all(func(n): return n.lobby == null)), "%s: when the host leaves, the guests go home" % label)
	for n in guests:
		n.queue_free()
	await wait(0.2)


func player_vs_player() -> void:
	var label := "Player vs player"
	var host := spawn("player_vs_player")
	var guest := spawn("player_vs_player")
	await process_frame
	host.host_game()
	if not await join(host, guest, label):
		await host_leaves([host, guest], label)
		return
	await wait_until(4.0, func(): return host.lobby.members[guest.lobby.local_id].synced)
	check(not host.lobby.can_start(true), "%s: nobody's ready, so the host can't start" % label)
	host.lobby.set_ready(true)
	guest.lobby.set_ready(true)
	check(await wait_until(3.0, func(): return host.lobby.can_start(true)), "%s: once both are ready, it can" % label)
	if await play([host, guest], label):
		check(not host.lobby.can_start(true), "%s: ready flags reset for the rematch" % label)
		host.lobby.set_ready(true)
		guest.lobby.set_ready(true)
		await wait_until(3.0, func(): return host.lobby.can_start(true))
		await play([host, guest], label + ", rematch")
	await host_leaves([host, guest], label)


func spectators() -> void:
	var label := "Spectators"
	var host := spawn("spectators")
	var player := spawn("spectators")
	var watcher := spawn("spectators")
	await process_frame
	host.host_game()
	var joined: bool = await join(host, watcher, label + " (watcher)", LocalNetLobby.SPECTATOR)
	joined = joined and await join(host, player, label + " (player)", LocalNetLobby.PLAYER)
	if joined:
		check(watcher.lobby.is_spectator() and watcher.lobby.local_slot() == -1, "%s: the watcher has no slot" % label)
		check(host.lobby.players().size() == 2 and host.lobby.spectators() == [watcher.lobby.local_id], "%s: two players and a spectator" % label)
		await wait_until(4.0, func(): return host.lobby.can_start())
		if await play([host, player, watcher], label):
			watcher.queue_free()
			await wait_until(3.0, func(): return host.lobby.spectators().is_empty())
			check(host.lobby.spectators().is_empty() and host.lobby.players().size() == 2, "%s: the watcher leaves, the players stay" % label)
	await host_leaves([host, player], label)


func solo_with_spectator() -> void:
	var label := "Solo with a spectator"
	var host := spawn("solo_with_spectator")
	var navigator := spawn("solo_with_spectator")
	await process_frame
	host.host_game()
	check(host.lobby.min_players == 1 and host.lobby.can_start(), "%s: the driver alone could start" % label)
	if await join(host, navigator, label, ""):
		host.lobby.merge_config({"speed": 6})
		host.lobby.merge_config({"maze": true})
		check(await wait_until(3.0, func(): return navigator.lobby.config.get("maze") == true), "%s: the navigator sees the settings" % label)
		check(navigator.lobby.config.get("speed") == 6, "%s: merging one setting kept the other (%s)" % [label, navigator.lobby.config])
		await wait_until(4.0, func(): return host.lobby.can_start())
		if await play([host, navigator], label):
			check(host.dots.walls.size() == 3 and host.dots.speed == 6, "%s: the match used the settings" % label)
	await host_leaves([host, navigator], label)


func big_screen() -> void:
	var label := "Big screen"
	var screen := spawn("big_screen")
	var one := spawn("big_screen")
	var two := spawn("big_screen")
	await process_frame
	screen.host_game()
	check(screen.lobby.is_spectator() and screen.lobby.players().is_empty(), "%s: the screen doesn't play" % label)
	var joined: bool = await join(screen, one, label + " (one)")
	joined = joined and await join(screen, two, label + " (two)")
	if joined:
		await wait_until(4.0, func(): return screen.lobby.can_start())
		if await play([screen, one, two], label):
			check(screen.dots.positions.size() == 2, "%s: two dots, none for the screen" % label)
	await host_leaves([screen, one, two], label)


func content_sharing() -> void:
	var label := "Content sharing"
	var cache := "user://test_examples_cache_%d" % randi()
	var host := spawn("content_sharing")
	var guest := spawn("content_sharing", {"content_cache": cache})
	await process_frame
	host.host_game()
	if await join(host, guest, label):
		check(await wait_until(10.0, func(): return host.lobby.can_start(false, true)), "%s: the guest fetches the stage" % label)
		var item: Dictionary = host.lobby.config.stage
		check(FileAccess.file_exists("%s/%s" % [cache, item.hash]), "%s: it's cached by its hash" % label)
		if await play([host, guest], label):
			check(not host.dots.walls.is_empty() and guest.dots.walls == host.dots.walls, "%s: both loaded the same walls" % label)
	await host_leaves([host, guest], label)
	for file in DirAccess.get_files_at(cache):
		DirAccess.remove_absolute("%s/%s" % [cache, file])
	DirAccess.remove_absolute(cache)
