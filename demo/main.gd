extends Control
# Link test: two or more devices find each other, then run a 120 Hz lockstep toy game and
# measure how late each other's inputs arrive. The results say which input delay lockstep
# needs on this network and whether rollback would be worth building.
#
# Command-line options (after --): --host, --join[=address], --name=NAME, --delay=N,
# --seconds=N, --players=N, --drop=0.1, --latency=MS, --jitter=MS, --loopback, --quit.

const GAME := "localnet-linktest"
const VERSION := 1
const TICK_RATE := 120
const INPUT_BYTES := 2
const LANE_WIDTH := 10000

var discovery := LocalNetDiscovery.new(GAME, VERSION)
var lobby: LocalNetLobby
var sync: LocalNetInputSync
var stats: LocalNetLatencyStats
var slot_stats := {}
var options := {}

var screen := ""
var box: VBoxContainer
var status_label: Label
var list_box: VBoxContainer
var name_edit: LineEdit
var address_edit: LineEdit
var settings := {"delay": 3, "seconds": 60, "players": 2, "mode": "lockstep"}

# Test run.
var run := {}
var positions := PackedInt32Array()
var canvas: Control
var stats_label: Label
var bot := RandomNumberGenerator.new()
var bot_dir := 1
var touch_x := -1.0
var result_text := ""
var my_name := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		options[parts[0]] = parts[1] if parts.size() > 1 else "1"
	for key in ["delay", "seconds", "players"]:
		if options.has(key):
			settings[key] = int(options[key])
	if options.has("free"):
		settings.mode = "free-run"
	var theme_root := Theme.new()
	theme_root.default_font_size = 26
	theme = theme_root
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 14)
	scroll.add_child(box)
	show_home()
	if options.has("host"):
		start_hosting()
	elif options.has("join"):
		show_join()
		if options.join != "1":
			connect_to(options.join, int(options.get("port", 0)))


func _process(_dt: float) -> void:
	discovery.poll()
	if lobby:
		lobby.poll()
		if lobby and lobby.is_host and screen == "host":
			discovery.update_info(lobby.advert())
	match screen:
		"join": refresh_sessions()
		"test": step_test()
		"results":
			# Keep resending the last inputs so slower devices can finish too.
			if sync:
				sync.flush()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		touch_x = event.position.x if event.pressed else -1.0
	elif event is InputEventScreenDrag:
		touch_x = event.position.x


# Screens.

func clear() -> void:
	for child in box.get_children():
		child.queue_free()
	canvas = null


func heading(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 40)
	box.add_child(label)


func text(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(label)
	return label


func button(label: String, action: Callable, parent: Control = box) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 72)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	box.add_child(h)
	return h


func show_home() -> void:
	screen = "home"
	clear()
	heading("LocalNet link test")
	text("Two devices on the same Wi-Fi or hotspot. One hosts, the other joins. No internet needed.")
	name_edit = LineEdit.new()
	name_edit.text = options.get("name", OS.get_model_name() if OS.get_model_name() != "GenericDevice" else OS.get_name())
	name_edit.custom_minimum_size = Vector2(0, 64)
	box.add_child(name_edit)
	var buttons := row()
	button("Host", start_hosting, buttons).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button("Join", show_join, buttons).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text("This device: " + describe_addresses())


func start_hosting() -> void:
	leave()
	lobby = new_lobby()
	var err := lobby.host(player_name(), settings.players)
	if err != OK:
		show_home()
		text("Couldn't host: %s" % error_string(err))
		return
	lobby.set_config(settings)
	var port := LocalNetDiscovery.PORT
	if discovery.advertise(lobby.advert(), port) != OK:
		push_warning("Discovery port busy; guests must join by address")
	show_host()


func show_host() -> void:
	screen = "host"
	clear()
	heading("Hosting")
	text("Guests on this network will see \"%s\". Or join by address: %s  port %d" % [lobby.session_name, describe_addresses(), lobby.link.port])
	list_box = VBoxContainer.new()
	box.add_child(list_box)
	var tuning := row()
	button("Delay -", func(): change("delay", -1), tuning)
	button("Delay +", func(): change("delay", 1), tuning)
	button("Length", func(): cycle_length(), tuning)
	button("Players: %d" % settings.players, func(): change("players", 1), tuning).name = "PlayersButton"
	button("Mode", toggle_mode, tuning)
	status_label = text("")
	var actions := row()
	button("Start test", start_test, actions)
	button("Back", go_home, actions)
	lobby.members_changed.connect(refresh_members)
	lobby.started.connect(begin_test)
	refresh_members()


func start_test() -> void:
	if lobby.can_start():
		lobby.start()


func go_home() -> void:
	leave()
	show_home()


func show_closed(reason: String) -> void:
	if screen == "lobby":
		status_label.text = reason


func change(key: String, by: int) -> void:
	if key == "players":
		settings.players = 2 + (settings.players - 1) % 3
		lobby.max_players = settings.players
		var players_button := box.find_child("PlayersButton", true, false)
		if players_button:
			players_button.text = "Players: %d" % settings.players
	else:
		settings[key] = clampi(settings[key] + by, 0, 16)
	lobby.set_config(settings)
	refresh_members()


func toggle_mode() -> void:
	settings.mode = "free-run" if settings.mode == "lockstep" else "lockstep"
	lobby.set_config(settings)
	refresh_members()


func cycle_length() -> void:
	var lengths := [30, 60, 120, 300]
	settings.seconds = lengths[(lengths.find(settings.seconds) + 1) % lengths.size()]
	lobby.set_config(settings)
	refresh_members()


func refresh_members() -> void:
	if list_box == null or not is_instance_valid(list_box) or lobby == null:
		return
	for child in list_box.get_children():
		child.queue_free()
	var ids := lobby.members.keys()
	ids.sort()
	for id in ids:
		var member: Dictionary = lobby.members[id]
		var line := "%s  (slot %d)" % [member.name, member.slot]
		if id == lobby.local_id:
			line += "  · you"
		elif lobby.is_host:
			line += "  · %d ms" % lobby.link.rtt_msec(id)
		if not member.synced:
			line += "  · syncing clock"
		var label := Label.new()
		label.text = line
		list_box.add_child(label)
	var config := lobby.config if not lobby.config.is_empty() else settings
	var summary := "%s · input delay %d ticks (%.1f ms) · %d s · up to %d players" % [config.get("mode", "lockstep"), config.get("delay", 3), config.get("delay", 3) * 1000.0 / TICK_RATE, config.get("seconds", 60), config.get("players", 2)]
	if config.get("mode") == "free-run":
		summary += "\nFree-run never waits: missing inputs repeat the last one, like rollback before it corrects. It measures the network alone."
	if status_label and is_instance_valid(status_label):
		status_label.text = summary if lobby.is_host else summary + "\nWaiting for the host to start."
	if lobby.is_host and options.has("host") and lobby.can_start() and lobby.members.size() >= settings.players:
		start_test.call_deferred()


func show_join() -> void:
	player_name()
	leave()
	screen = "join"
	clear()
	heading("Join")
	status_label = text("Looking for hosts…")
	list_box = VBoxContainer.new()
	box.add_child(list_box)
	var manual := row()
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "Host address, e.g. 192.168.43.1:port"
	address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	manual.add_child(address_edit)
	button("Connect", func(): join_typed(), manual)
	button("Back", go_home)
	var targets := PackedStringArray(["127.0.0.1"]) if options.has("loopback") else PackedStringArray()
	discovery.scan(targets)


func refresh_sessions() -> void:
	var sessions := discovery.sessions()
	if list_box.get_child_count() == sessions.size() and Engine.get_process_frames() % 30 != 0:
		return
	for child in list_box.get_children():
		child.queue_free()
	for session in sessions:
		var label := "%s  ·  %s  ·  %d/%d  ·  %.0f ms" % [session.name, session.address, session.players, session.max_players, session.ping_ms]
		if not session.compatible:
			label += "  ·  needs v%d" % session.version
		var b := button(label, func(): connect_to(session.address, session.port), list_box)
		b.disabled = not session.compatible or session.state != "lobby"
	status_label.text = ("Looking for hosts…" if sessions.is_empty() else "Tap a host to join.") + "  (sweep: %d addresses, longest frame %.1f ms)" % [discovery.last_sweep_targets, discovery.last_sweep_usec / 1000.0]
	if options.has("join") and options.join == "1" and not sessions.is_empty() and sessions[0].compatible:
		connect_to(sessions[0].address, sessions[0].port)


func join_typed() -> void:
	var parts := address_edit.text.strip_edges().split(":")
	if parts.size() == 2 and parts[0].is_valid_ip_address():
		connect_to(parts[0], int(parts[1]))
	else:
		status_label.text = "Type the address and port the host shows, like 192.168.43.1:51234"


func connect_to(address: String, port: int) -> void:
	discovery.stop_scanning()
	lobby = new_lobby()
	lobby.join(address, port, player_name())
	screen = "lobby"
	clear()
	heading("Joining %s" % address)
	list_box = VBoxContainer.new()
	box.add_child(list_box)
	status_label = text("Connecting…")
	button("Leave", go_home)
	lobby.members_changed.connect(refresh_members)
	lobby.started.connect(begin_test)
	lobby.rejected.connect(func(reason): status_label.text = "Turned away: " + reason)
	lobby.closed.connect(show_closed)


func new_lobby() -> LocalNetLobby:
	var l := LocalNetLobby.new(GAME, VERSION)
	l.link.debug_drop = float(options.get("drop", 0))
	l.link.debug_latency_msec = float(options.get("latency", 0))
	l.link.debug_jitter_msec = float(options.get("jitter", 0))
	return l


func leave() -> void:
	discovery.stop()
	if sync:
		sync.close()
	sync = null
	if lobby:
		lobby.leave()
	lobby = null
	run = {}


# The test itself: a deterministic toy where each player slides along a lane.

func begin_test(config: Dictionary, start_usec: int) -> void:
	discovery.stop()
	var players := lobby.members.size()
	var delay := int(config.get("delay", 3))
	sync = LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), delay, INPUT_BYTES)
	stats = LocalNetLatencyStats.new(TICK_RATE)
	slot_stats = {}
	sync.remote_input.connect(on_remote_input)
	sync.desynced.connect(on_desync)
	lobby.member_left.connect(func(_id): end_test("A player left"))
	lobby.closed.connect(end_test)
	positions.resize(players)
	for slot in players:
		positions[slot] = LANE_WIDTH >> 1
	bot.seed = hash(player_name()) + lobby.local_slot()
	run = {"start": start_usec, "tick_usec": 1_000_000.0 / TICK_RATE, "tick": 0, "delay": delay, "total": int(config.get("seconds", 60)) * TICK_RATE,
		"players": players, "stall_frames": 0, "frames": 0, "stall_since": 0, "longest_stall": 0, "stall_time": 0, "catchup_frames": 0,
		"desync_tick": -1, "checksums": 0, "free": config.get("mode") == "free-run", "predicted": 0, "began_usec": Time.get_ticks_usec(), "config": config}
	screen = "test"
	clear()
	heading("%s · slot %d of %d · delay %d" % [config.get("mode", "lockstep"), lobby.local_slot(), players, delay])
	canvas = Control.new()
	canvas.custom_minimum_size = Vector2(0, 60 * players + 20)
	canvas.draw.connect(draw_lanes)
	box.add_child(canvas)
	stats_label = text("")
	button("Stop", func(): end_test("Stopped on this device"))


# How late a remote input arrived, measured from when its sender was due to sample it.
func on_remote_input(_slot: int, tick: int, arrived: int) -> void:
	if not run.is_empty():
		var lateness := int(arrived - (run.start + (tick - run.delay) * run.tick_usec))
		stats.add(lateness)
		if not slot_stats.has(_slot):
			slot_stats[_slot] = LocalNetLatencyStats.new(TICK_RATE)
		slot_stats[_slot].add(lateness)


func on_desync(tick: int, _peer: int) -> void:
	if not run.is_empty() and run.desync_tick < 0:
		run.desync_tick = tick


func step_test() -> void:
	if run.is_empty():
		return
	var now := Time.get_ticks_usec()
	run.frames += 1
	var due := int(floor((now - run.start) / run.tick_usec))
	var ran := 0
	var stalled := false
	while run.tick <= due and run.tick < run.total and ran < 16:
		while sync.next_local_tick() <= run.tick + run.delay:
			sync.add_local_input(sync.next_local_tick(), sample_input())
		if run.free:
			if not sync.is_ready(run.tick):
				run.predicted += 1
			simulate(sync.predicted_inputs(run.tick))
		elif sync.is_ready(run.tick):
			simulate(sync.inputs(run.tick))
		else:
			stalled = true
			break
		run.tick += 1
		ran += 1
		if run.tick % 60 == 0 and not run.free:
			sync.report_checksum(run.tick, checksum())
			sync.discard_before(run.tick - 240)
			run.checksums += 1
	sync.flush()
	if ran == 16:
		run.catchup_frames += 1
	if stalled:
		run.stall_frames += 1
		if run.stall_since == 0:
			run.stall_since = now
	elif run.stall_since != 0:
		run.stall_time += now - run.stall_since
		run.longest_stall = maxi(run.longest_stall, now - run.stall_since)
		run.stall_since = 0
	if canvas:
		canvas.queue_redraw()
	if Engine.get_process_frames() % 15 == 0:
		stats_label.text = live_stats(now)
	if run.tick >= run.total:
		end_test("Finished")


func sample_input() -> PackedByteArray:
	var dir := 0
	if Input.is_key_pressed(KEY_LEFT):
		dir = -1
	elif Input.is_key_pressed(KEY_RIGHT):
		dir = 1
	elif touch_x >= 0:
		dir = -1 if touch_x < get_viewport_rect().size.x / 2 else 1
	else:
		if bot.randf() < 0.03:
			bot_dir = [-1, 0, 1][bot.randi_range(0, 2)]
		dir = bot_dir
	return PackedByteArray([dir + 1, 1 if touch_x >= 0 else 0])


func simulate(inputs: Array[PackedByteArray]) -> void:
	for slot in inputs.size():
		var dir: int = inputs[slot][0] - 1
		positions[slot] = clampi(positions[slot] + dir * 37, 0, LANE_WIDTH)
		if positions[slot] == 0 or positions[slot] == LANE_WIDTH:
			positions[slot] = LANE_WIDTH >> 1


func checksum() -> int:
	var h := 2166136261
	for value in positions:
		h = ((h ^ value) * 16777619) & 0xFFFFFFFF
	return h ^ run.tick


func draw_lanes() -> void:
	if canvas == null or lobby == null:
		return
	var width := canvas.size.x
	for slot in positions.size():
		var y := 10.0 + slot * 60
		canvas.draw_rect(Rect2(0, y + 22, width, 6), Color(1, 1, 1, 0.15))
		var x := positions[slot] / float(LANE_WIDTH) * (width - 40)
		var colour := Color("f2b134") if slot == lobby.local_slot() else Color("4fc3f7")
		canvas.draw_rect(Rect2(x, y, 40, 50), colour)


func live_stats(now: int) -> String:
	var lines := PackedStringArray()
	var behind: int = int(floor((now - run.start) / run.tick_usec)) - run.tick
	lines.append("Tick %d / %d · %d behind schedule · %s" % [run.tick, run.total, maxi(behind, 0), "DESYNC at %d" % run.desync_tick if run.desync_tick >= 0 else "in sync"])
	lines.append(peer_line())
	lines.append("Stalled frames %d of %d (%.1f%%) · longest stall %.0f ms · total %.0f ms" % [run.stall_frames, run.frames, 100.0 * run.stall_frames / maxi(run.frames, 1), run.longest_stall / 1000.0, run.stall_time / 1000.0])
	lines.append(stats.summary())
	lines.append(per_slot_lines())
	return "\n".join(lines)


# Each remote player's inputs separately; with three or more players, guests hear each other through the host.
func per_slot_lines() -> String:
	var lines := PackedStringArray()
	var slots := slot_stats.keys()
	slots.sort()
	for slot in slots:
		var s: LocalNetLatencyStats = slot_stats[slot]
		var who := "slot %d" % slot
		for member in lobby.members.values():
			if member.slot == slot:
				who = "%s (slot %d)" % [member.name, slot]
		lines.append("  from %s: p50 %.1f  p90 %.1f  p99 %.1f  max %.1f ms · late at delay %d: %.1f%%" % [who, s.percentile_msec(50), s.percentile_msec(90), s.percentile_msec(99), s.percentile_msec(100), run.get("delay", 3), s.stall_share(run.get("delay", 3)) * 100])
	return "\n".join(lines)


func peer_line() -> String:
	var parts := PackedStringArray()
	for id in lobby.link.peers():
		parts.append("peer %d: ENet RTT %d ms, loss %.1f%%" % [id, lobby.link.rtt_msec(id), lobby.link.packet_loss(id) * 100])
	if not lobby.is_host:
		parts.append("clock RTT %.1f ms, offset %.1f ms" % [lobby.clock_rtt_usec / 1000.0, lobby.clock_offset_usec / 1000.0])
	return " · ".join(parts)


func end_test(reason: String) -> void:
	if screen != "test":
		return
	var now := Time.get_ticks_usec()
	if run.stall_since != 0:
		run.stall_time += now - run.stall_since
		run.longest_stall = maxi(run.longest_stall, now - run.stall_since)
	var lines := PackedStringArray()
	lines.append("LOCALNET RESULT · %s" % reason)
	lines.append("Device: %s (%s %s) · %s · slot %d of %d" % [player_name(), OS.get_name(), OS.get_version(), "host" if lobby.is_host else "guest", lobby.local_slot(), run.players])
	lines.append("Network: " + describe_addresses())
	lines.append("Ran %d of %d ticks at %d Hz with input delay %d (%.1f ms) over %.1f s" % [run.tick, run.total, TICK_RATE, run.delay, run.delay * 1000.0 / TICK_RATE, (now - run.began_usec) / 1_000_000.0])
	lines.append(peer_line())
	lines.append("Stalled frames %d of %d (%.2f%%) · longest stall %.0f ms · total stalled %.0f ms · catch-up frames %d" % [run.stall_frames, run.frames, 100.0 * run.stall_frames / maxi(run.frames, 1), run.longest_stall / 1000.0, run.stall_time / 1000.0, run.catchup_frames])
	if run.free:
		lines.append("Free-run: %d of %d ticks ran on a guess (%.1f%%): the share rollback would have had to correct" % [run.predicted, run.tick, 100.0 * run.predicted / maxi(run.tick, 1)])
	else:
		lines.append("State checks %d · %s" % [run.checksums, "DESYNC first at tick %d" % run.desync_tick if run.desync_tick >= 0 else "no desync"])
	lines.append(stats.summary())
	lines.append(per_slot_lines())
	result_text = "\n".join(lines)
	print(result_text)
	save_result()
	run = {}
	screen = "results"
	clear()
	heading("Results")
	text(result_text)
	var actions := row()
	button("Again", go_home, actions)
	if options.has("quit"):
		await get_tree().create_timer(1.5).timeout
		leave()
		get_tree().quit()


func save_result() -> void:
	DirAccess.make_dir_recursive_absolute("user://results")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var file := FileAccess.open("user://results/%s-%s.txt" % [stamp, "host" if lobby.is_host else "guest"], FileAccess.WRITE)
	if file:
		file.store_string(result_text + "\n")


func player_name() -> String:
	if name_edit and is_instance_valid(name_edit) and name_edit.text.strip_edges() != "":
		my_name = name_edit.text.strip_edges().left(24)
	return my_name if my_name != "" else options.get("name", "Player")


func describe_addresses() -> String:
	var parts := PackedStringArray()
	for local in LocalNetDiscovery.local_ipv4():
		parts.append("%s (%s)" % [local.address, local.interface])
	return ", ".join(parts) if not parts.is_empty() else "no Wi-Fi address"
