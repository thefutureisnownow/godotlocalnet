extends Control
# Link test: two or more devices find each other, then run a 120 Hz lockstep toy game and
# measure how late each other's inputs arrive. The results say which input delay lockstep
# needs on this network and whether rollback would be worth building.
#
# Command-line options (after --): --host, --join[=address[:port]], --name=NAME,
# --delay=N (default auto), --seconds=N, --players=N, --matches=N, --free, --port=N,
# --reconnect=SECONDS|forever|off, --drop=0.1, --latency=MS, --jitter=MS, --hiccup=MS, --drop-connection=MS,
# --no-time-sync, --loopback, --results=DIR, --quit.

const GAME := "localnet-linktest"
const VERSION := 5
const TICK_RATE := 120
const INPUT_BYTES := 2
const LANE_WIDTH := 10000

var discovery := LocalNetDiscovery.new(GAME, VERSION)
var lobby: LocalNetLobby
var sync: LocalNetInputSync
var runner: LocalNetLockstep
var stats: LocalNetLatencyStats
var slot_stats := {}
var options := {}

var screen := ""
var box: VBoxContainer
var status_label: Label
var list_box: VBoxContainer
var name_edit: LineEdit
var port_edit: LineEdit
var address_edit: LineEdit
var settings := {"delay": 3, "auto_delay": true, "seconds": 60, "players": 2, "mode": "lockstep", "reconnect": 30}
var matches_played := 0
var joining_address := ""
var joining_since := 0

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
	for key in ["seconds", "players"]:
		if options.has(key):
			settings[key] = int(options[key])
	if options.has("delay"):
		settings.delay = int(options.delay)
		settings.auto_delay = false
	if options.has("free"):
		settings.mode = "free-run"
	if options.has("reconnect"):
		settings.reconnect = {"forever": -1, "off": 0}.get(options.reconnect, int(options.reconnect))
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
			join_address(options.join)


func _process(_dt: float) -> void:
	discovery.poll()
	if lobby:
		lobby.poll()
		if lobby and lobby.is_host and discovery.advertised_port:
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


# Building blocks.

func clear() -> void:
	for child in box.get_children():
		child.queue_free()
	canvas = null


func heading(value: String) -> void:
	var label := Label.new()
	label.text = value
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


func field(placeholder: String, value := "", parent: Control = box) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.text = value
	edit.custom_minimum_size = Vector2(0, 64)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(edit)
	return edit


# Home.

func show_home() -> void:
	screen = "home"
	clear()
	heading("LocalNet link test")
	text("Two devices on the same Wi-Fi or hotspot. One hosts, the others join. No internet needed.")
	name_edit = field("Your name", options.get("name", OS.get_model_name() if OS.get_model_name() != "GenericDevice" else OS.get_name()))
	var buttons := row()
	port_edit = field("Game port (blank: any free port)", options.get("port", ""), buttons)
	button("Host", start_hosting, buttons).custom_minimum_size.x = 200
	button("Join", show_join, buttons).custom_minimum_size.x = 200
	text("This device: " + describe_addresses())


func go_home() -> void:
	leave()
	show_home()


# Hosting.

func start_hosting() -> void:
	player_name()
	var port := int(port_edit.text) if port_edit and is_instance_valid(port_edit) and port_edit.text.is_valid_int() else 0
	leave()
	LocalNetWifiRoute.bind()
	lobby = new_lobby()
	var err := lobby.host(player_name(), settings.players, "", port)
	if err != OK:
		show_home()
		text("Couldn't host on port %d: %s" % [port, error_string(err)])
		return
	lobby.set_config(settings)
	lobby.reconnect_window_msec = reconnect_msec()
	discovery.advertise(lobby.advert())
	show_host()


func show_host() -> void:
	screen = "host"
	clear()
	heading("Hosting \"%s\"" % lobby.session_name)
	var joins := PackedStringArray()
	for local in LocalNetDiscovery.local_ipv4():
		joins.append("%s:%d" % [local.address, lobby.link.port])
	var found_by := "Guests find it automatically (discovery port %d%s)." % [discovery.advertised_port, ", a fallback because another host on this device has %d" % LocalNetDiscovery.PORT if discovery.advertised_port != LocalNetDiscovery.PORT else ""] if discovery.advertised_port else "Discovery isn't available on this device, so guests must type the address."
	text("%s Or join by typing %s" % [found_by, " or ".join(joins) if not joins.is_empty() else "127.0.0.1:%d" % lobby.link.port])
	list_box = VBoxContainer.new()
	box.add_child(list_box)
	var tuning := row()
	button("Delay -", func(): change_delay(-1), tuning)
	button("Delay: auto", toggle_auto_delay, tuning).name = "DelayButton"
	button("Delay +", func(): change_delay(1), tuning)
	button("Length", cycle_length, tuning)
	button("Players: %d" % settings.players, cycle_players, tuning).name = "PlayersButton"
	button("Mode", toggle_mode, tuning)
	button("Reconnect: " + reconnect_label(), cycle_reconnect, tuning).name = "ReconnectButton"
	status_label = text("")
	var actions := row()
	button("Start test", start_test, actions)
	button("Back", go_home, actions)
	refresh_members()


func start_test() -> void:
	if not lobby.can_start():
		return
	if settings.auto_delay:
		settings.delay = lobby.suggested_delay(TICK_RATE)
		lobby.set_config(settings)
	lobby.start()


func change_delay(by: int) -> void:
	settings.auto_delay = false
	settings.delay = clampi(settings.delay + by, 0, 16)
	settings_changed()


func toggle_auto_delay() -> void:
	settings.auto_delay = not settings.auto_delay
	settings_changed()


func cycle_players() -> void:
	settings.players = 2 + (settings.players - 1) % 3
	lobby.max_players = settings.players
	settings_changed()


func toggle_mode() -> void:
	settings.mode = "free-run" if settings.mode == "lockstep" else "lockstep"
	settings_changed()


func cycle_reconnect() -> void:
	var windows := [10, 30, 60, -1, 0]
	settings.reconnect = windows[(windows.find(settings.reconnect) + 1) % windows.size()]
	lobby.reconnect_window_msec = reconnect_msec()
	settings_changed()


func reconnect_msec() -> int:
	return LocalNetLink.WAIT_FOREVER if settings.reconnect < 0 else settings.reconnect * 1000


func reconnect_label() -> String:
	return "forever" if settings.reconnect < 0 else ("off" if settings.reconnect == 0 else "%d s" % settings.reconnect)


func cycle_length() -> void:
	var lengths := [30, 60, 120, 300]
	settings.seconds = lengths[(lengths.find(settings.seconds) + 1) % lengths.size()]
	settings_changed()


func settings_changed() -> void:
	lobby.set_config(settings)
	refresh_members()


func delay_label() -> String:
	if settings.auto_delay:
		return "auto (%d)" % lobby.suggested_delay(TICK_RATE)
	return str(settings.delay)


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
		var net: Dictionary = member.get("net", {})
		if net.has("rtt_p50_usec"):
			line += "  · ping %.0f ms, 90%% under %.0f ms" % [net.rtt_p50_usec / 1000.0, net.rtt_p90_usec / 1000.0]
		if net.get("frame_usec", 0) > 0:
			line += "  · %.0f fps" % (1_000_000.0 / net.frame_usec)
		if not member.synced:
			line += "  · syncing clock"
		var label := Label.new()
		label.text = line
		list_box.add_child(label)
	var config := settings if lobby.is_host else lobby.config
	var delay_text := delay_label() if lobby.is_host else str(config.get("delay", "?"))
	var summary := "%s · input delay %s · %d s · up to %d players" % [config.get("mode", "lockstep"), delay_text, config.get("seconds", 60), config.get("players", 2)]
	if config.get("mode") == "free-run":
		summary += "\nFree-run never waits: missing inputs repeat the last one, like rollback before it corrects. It measures the network alone."
	if status_label and is_instance_valid(status_label):
		status_label.text = summary if lobby.is_host else summary + "\nWaiting for the host to start."
	var labels := {"DelayButton": "Delay: " + delay_label(), "PlayersButton": "Players: %d" % settings.players, "ReconnectButton": "Reconnect: " + reconnect_label()}
	for name in labels:
		var b := box.find_child(name, true, false)
		if b:
			b.text = labels[name]
	if lobby.is_host and options.has("host") and screen == "host" and lobby.can_start() and lobby.members.size() >= settings.players:
		start_test.call_deferred()


# Joining.

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
	address_edit = field("Host address, with or without :port", "", manual)
	button("Connect", func(): join_address(address_edit.text), manual)
	button("Back", go_home)
	var targets := PackedStringArray(["127.0.0.1"]) if options.has("loopback") else PackedStringArray()
	LocalNetWifiRoute.bind()
	discovery.scan(targets)


func refresh_sessions() -> void:
	var sessions := discovery.sessions()
	if joining_address != "":
		for session in sessions:
			if session.address == joining_address and session.compatible:
				connect_to(session.address, session.port)
				return
		if Time.get_ticks_usec() - joining_since > 4_000_000:
			status_label.text = "No host answered at %s. Check the address, or type the port the host shows." % joining_address
			joining_address = ""
		return
	if list_box.get_child_count() == sessions.size() and Engine.get_process_frames() % 30 != 0:
		return
	for child in list_box.get_children():
		child.queue_free()
	for session in sessions:
		var label := "%s  ·  %s:%d  ·  %d/%d  ·  %.0f ms" % [session.name, session.address, session.port, session.players, session.max_players, session.ping_ms]
		if not session.compatible:
			label += "  ·  needs v%d" % session.version
		elif session.state != "lobby":
			label += "  ·  playing"
		var b := button(label, func(): connect_to(session.address, session.port), list_box)
		b.disabled = not session.compatible or session.state != "lobby"
	status_label.text = ("Looking for hosts…" if sessions.is_empty() else "Tap a host to join.") + "  (%d probes a sweep, longest frame %.1f ms)" % [discovery.last_sweep_targets, discovery.last_sweep_usec / 1000.0]
	if options.has("join") and options.join == "1" and not sessions.is_empty() and sessions[0].compatible:
		connect_to(sessions[0].address, sessions[0].port)


## "address:port" connects straight away; a bare address is asked which port it hosts on.
func join_address(typed: String) -> void:
	var parts := typed.strip_edges().split(":")
	if not parts[0].is_valid_ip_address():
		status_label.text = "Type an address like 192.168.43.1, or 192.168.43.1:51234"
	elif parts.size() == 2 and parts[1].is_valid_int():
		connect_to(parts[0], int(parts[1]))
	else:
		joining_address = parts[0]
		joining_since = Time.get_ticks_usec()
		LocalNetWifiRoute.bind()
		discovery.scan(PackedStringArray([joining_address]))
		status_label.text = "Asking %s…" % joining_address


func connect_to(address: String, port: int) -> void:
	joining_address = ""
	discovery.stop_scanning()
	LocalNetWifiRoute.bind()
	lobby = new_lobby()
	lobby.join(address, port, player_name())
	show_guest_lobby("Joining %s:%d" % [address, port], "Connecting…")


func show_guest_lobby(title: String, status: String) -> void:
	screen = "lobby"
	clear()
	heading(title)
	list_box = VBoxContainer.new()
	box.add_child(list_box)
	status_label = text(status)
	button("Leave", go_home)
	refresh_members()


# Lobby life cycle, shared by host and guests.

func new_lobby() -> LocalNetLobby:
	var l := LocalNetLobby.new(GAME, VERSION)
	l.wait_for_loading = true
	l.link.debug_drop = float(options.get("drop", 0))
	l.link.debug_latency_msec = float(options.get("latency", 0))
	l.link.debug_jitter_msec = float(options.get("jitter", 0))
	l.members_changed.connect(refresh_members)
	l.preparing.connect(on_preparing)
	l.started.connect(begin_test)
	l.returned.connect(on_returned)
	l.rejected.connect(func(reason): status_label.text = "Turned away: " + reason)
	l.closed.connect(on_closed)
	l.member_left.connect(func(_id, reason): end_test("A player left" if reason == "left" else "A player lost their connection"))
	l.member_interrupted.connect(func(_id): refresh_members())
	l.member_resumed.connect(on_resumed)
	l.connection_interrupted.connect(show_reconnecting)
	l.connection_resumed.connect(on_resumed)
	return l


func on_resumed(_id := 0) -> void:
	if not run.is_empty():
		run.reconnections += 1
	refresh_members()


func show_reconnecting() -> void:
	if screen == "lobby" and status_label:
		status_label.text = "Connection lost, reconnecting…"


func on_preparing(_config: Dictionary) -> void:
	# A real game loads its stage and fighters here, then reports in.
	lobby.mark_loaded.call_deferred()


func on_returned() -> void:
	stop_sync()
	if lobby.is_host:
		show_host()
	else:
		show_guest_lobby("Back in the lobby", "Waiting for the host to start.")


func on_closed(reason: String) -> void:
	if screen == "test":
		end_test(reason)
	elif screen == "lobby" and status_label:
		status_label.text = reason
	if options.has("quit") and not (lobby and lobby.is_host):
		quit_soon()


func leave() -> void:
	discovery.stop()
	stop_sync()
	if lobby:
		lobby.leave()
	lobby = null
	LocalNetWifiRoute.release()


func stop_sync() -> void:
	if sync:
		sync.close()
	sync = null
	runner = null
	run = {}


# The test itself: a deterministic toy where each player slides along a lane.

func begin_test(config: Dictionary, start_usec: int) -> void:
	var players := lobby.members.size()
	var delay := int(config.get("delay", 3))
	sync = LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), delay, INPUT_BYTES)
	runner = LocalNetLockstep.new(sync, start_usec, TICK_RATE, sample_input, simulate, checksum)
	runner.predict = config.get("mode") == "free-run"
	runner.time_sync = not options.has("no-time-sync")
	stats = LocalNetLatencyStats.new(TICK_RATE)
	slot_stats = {}
	sync.remote_input.connect(on_remote_input)
	sync.desynced.connect(on_desync)
	positions.resize(players)
	for slot in players:
		positions[slot] = LANE_WIDTH >> 1
	bot.seed = hash(player_name()) + lobby.local_slot()
	run = {"delay": delay, "total": int(config.get("seconds", 60)) * TICK_RATE, "players": players, "desync_tick": -1, "checksums": 0, "reconnections": 0, "began_usec": Time.get_ticks_usec()}
	screen = "test"
	clear()
	heading("%s · slot %d of %d · delay %d (%.0f ms)" % [config.get("mode", "lockstep"), lobby.local_slot(), players, delay, delay * 1000.0 / TICK_RATE])
	canvas = Control.new()
	canvas.custom_minimum_size = Vector2(0, 60 * players + 20)
	canvas.draw.connect(draw_lanes)
	box.add_child(canvas)
	stats_label = text("")
	var actions := row()
	button("Stop", func(): end_test("Stopped on this device"), actions)
	# Only while someone is reconnecting: the game, not the library, decides when to stop waiting.
	button("Stop waiting", give_up_waiting, actions).name = "GiveUpButton"


# How late a remote input arrived, measured from when its sender was due to sample it.
func on_remote_input(slot: int, tick: int, arrived: int) -> void:
	if runner:
		var lateness := arrived - runner.scheduled_usec(tick - sync.delay)
		stats.add(lateness)
		if not slot_stats.has(slot):
			slot_stats[slot] = LocalNetLatencyStats.new(TICK_RATE)
		slot_stats[slot].add(lateness)


func on_desync(tick: int, _peer: int) -> void:
	if not run.is_empty() and run.desync_tick < 0:
		run.desync_tick = tick


func give_up_waiting() -> void:
	for id in lobby.link.interrupted_peers():
		lobby.give_up(id)


func step_test() -> void:
	if runner == null:
		return
	var now := Time.get_ticks_usec()
	if runner.tick < run.total:
		runner.max_ticks_per_frame = mini(8, run.total - runner.tick)
		runner.advance(now)
		# A simulated Wi-Fi hiccup three seconds in, from this device only.
		if options.has("hiccup") and not run.has("hiccup") and runner.tick >= 3 * TICK_RATE:
			run.hiccup = true
			lobby.link.debug_hold(float(options.hiccup))
		# A dropped connection three seconds in, back after the given pause.
		if options.has("drop-connection") and not run.has("dropped") and runner.tick >= 3 * TICK_RATE:
			run.dropped = true
			lobby.link.debug_drop_connection(LocalNetLink.HOST_ID if not lobby.is_host else lobby.link.peers()[0], float(options["drop-connection"]))
	if canvas:
		canvas.queue_redraw()
	var give_up := box.find_child("GiveUpButton", true, false)
	if give_up:
		give_up.visible = not lobby.link.interrupted_peers().is_empty()
	if Engine.get_process_frames() % 15 == 0:
		stats_label.text = live_stats(now)
	if runner.tick >= run.total:
		end_test("Finished")


func sample_input(_tick: int) -> PackedByteArray:
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


func simulate(_tick: int, inputs: Array[PackedByteArray]) -> void:
	for slot in inputs.size():
		var dir: int = inputs[slot][0] - 1
		positions[slot] = clampi(positions[slot] + dir * 37, 0, LANE_WIDTH)
		if positions[slot] == 0 or positions[slot] == LANE_WIDTH:
			positions[slot] = LANE_WIDTH >> 1


func checksum() -> int:
	run.checksums += 1
	var h := 2166136261
	for value in positions:
		h = ((h ^ value) * 16777619) & 0xFFFFFFFF
	return h ^ runner.tick


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
	var waiting := ""
	if runner.is_waiting():
		waiting = " · waiting for " + ", ".join(runner.waiting_on().map(slot_name))
	for id in lobby.link.interrupted_peers():
		var who: String = "the host" if id == LocalNetLink.HOST_ID and not lobby.is_host else lobby.members.get(id, {}).get("name", "a player")
		var left := lobby.link.reconnect_seconds_left(id)
		waiting += " · lost %s, reconnecting (%s)" % [who, "no time limit" if left == INF else "%.0f s left" % left]
	lines.append("Tick %d / %d · %s%s" % [runner.tick, run.total, "DESYNC at %d" % run.desync_tick if run.desync_tick >= 0 else "in sync", waiting])
	lines.append(peer_line())
	lines.append(stall_line())
	lines.append(stats.summary())
	lines.append(per_slot_lines())
	return "\n".join(lines)


func stall_line() -> String:
	return "Stalled frames %d of %d (%.2f%%) · longest stall %.0f ms · total %.0f ms · schedule moved back %.0f ms · time sync eased %.0f ms" % [runner.stalled_frames, runner.frames, 100.0 * runner.stalled_frames / maxi(runner.frames, 1), runner.longest_stall_usec / 1000.0, runner.total_stall_usec / 1000.0, runner.shifted_usec / 1000.0, runner.eased_usec / 1000.0]


func slot_name(slot: int) -> String:
	for member in lobby.members.values():
		if member.slot == slot:
			return member.name
	return "slot %d" % slot


# Each remote player's inputs separately; with three or more players, guests hear each other through the host.
func per_slot_lines() -> String:
	var lines := PackedStringArray()
	var slots := slot_stats.keys()
	slots.sort()
	for slot in slots:
		var s: LocalNetLatencyStats = slot_stats[slot]
		lines.append("  from %s (slot %d): p50 %.1f  p90 %.1f  p99 %.1f  max %.1f ms · late at delay %d: %.1f%%" % [slot_name(slot), slot, s.percentile_msec(50), s.percentile_msec(90), s.percentile_msec(99), s.percentile_msec(100), sync.delay, s.stall_share(sync.delay) * 100])
	return "\n".join(lines)


func peer_line() -> String:
	var parts := PackedStringArray()
	for id in lobby.link.peers():
		parts.append("peer %d: ENet RTT %d ms, loss %.1f%%" % [id, lobby.link.rtt_msec(id), lobby.link.packet_loss(id) * 100])
	if not lobby.is_host:
		parts.append("clock RTT %.1f ms, offset %.1f ms" % [lobby.clock_rtt_usec / 1000.0, lobby.clock_offset_usec / 1000.0])
	return " · ".join(parts)


func end_test(reason: String) -> void:
	if screen != "test" or runner == null:
		return
	var now := Time.get_ticks_usec()
	runner.finish(now)
	matches_played += 1
	var lines := PackedStringArray()
	lines.append("LOCALNET RESULT · %s" % reason)
	lines.append("Device: %s (%s %s) · %s · slot %d of %d · match %d" % [player_name(), OS.get_name(), OS.get_version(), "host" if lobby.is_host else "guest", lobby.local_slot(), run.players, matches_played])
	lines.append("Network: " + describe_addresses())
	lines.append("Ran %d of %d ticks at %d Hz with input delay %d (%.1f ms) over %.1f s" % [runner.tick, run.total, TICK_RATE, sync.delay, sync.delay * 1000.0 / TICK_RATE, (now - run.began_usec) / 1_000_000.0])
	lines.append(peer_line())
	lines.append(stall_line())
	lines.append("Reconnections %d" % run.reconnections)
	if runner.predict:
		lines.append("Free-run: %d of %d ticks ran on a guess (%.1f%%): the share rollback would have had to correct" % [runner.predicted_ticks, runner.tick, 100.0 * runner.predicted_ticks / maxi(runner.tick, 1)])
	else:
		lines.append("State checks %d · %s" % [run.checksums, "DESYNC first at tick %d" % run.desync_tick if run.desync_tick >= 0 else "no desync"])
	lines.append(stats.summary())
	lines.append(per_slot_lines())
	result_text = "\n".join(lines)
	print(result_text)
	save_result()
	runner = null
	screen = "results"
	clear()
	heading("Results")
	text(result_text)
	var actions := row()
	if lobby.is_host and lobby.state != "closed":
		button("Rematch", lobby.return_to_lobby, actions)
	elif lobby.state != "closed":
		text("The host can start a rematch.")
	button("Leave", go_home, actions)
	if lobby.is_host and options.has("host"):
		if matches_played < int(options.get("matches", 1)):
			await get_tree().create_timer(1.5).timeout
			lobby.return_to_lobby()
		elif options.has("quit"):
			quit_soon()


func quit_soon() -> void:
	await get_tree().create_timer(1.5).timeout
	leave()
	get_tree().quit()


func save_result() -> void:
	var folder: String = options.get("results", "user://results")
	DirAccess.make_dir_recursive_absolute(folder)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var file := FileAccess.open(folder.path_join("%s-%s-slot%d-match%d.txt" % [stamp, "host" if lobby.is_host else "guest", lobby.local_slot(), matches_played]), FileAccess.WRITE)
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
