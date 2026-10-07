extends SceneTree
# Runs hosts and clients side by side over loopback, including lossy, laggy links.
# Run: godot --headless --path . --script tests/test_localnet.gd
const GAME := "localnet-test"
const PORT := 47710
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
	discovery()
	lobby_join()
	lobby_rejects()
	clock_and_start()
	ports()
	typed_messages()
	loading_and_rematch()
	suggested_delays()
	lockstep(2, 0.0, 0.0, 0.0, "clean")
	lockstep(2, 0.25, 12.0, 10.0, "lossy")
	lockstep(3, 0.15, 5.0, 5.0, "relayed")
	stalls()
	runner_rules()
	time_sync()
	free_run()
	keeps_unconfirmed_inputs()
	sweep_plan()
	stale_sessions()
	lobby_edges()
	delay_cap()
	reconnects()
	broken_sockets()
	lobby_reconnects()
	reconnect_settings()
	lockstep_through_drop()
	desync()
	departures()
	wifi_route()
	stats()
	wire_version()
	spectator_joins()
	spectator_counts()
	organiser(0.0, 0.0, 0.0, "organiser")
	organiser(0.25, 12.0, 10.0, "organiser, lossy")
	spectator_match()
	slow_spectator()
	spectator_dropped()
	content_basics()
	content_relay()
	content_mismatch()
	content_resume()
	content_limits()
	content_flow()
	content_require_change()
	content_stalls()
	content_new_session()
	content_bad_source()
	content_rehash()
	content_items()
	spectator_drops_loading()
	loaded_while_dropped()
	spectator_content_loading()
	game_channels()
	spectator_told_dropped()
	wire_range()
	spectator_load_wait()
	late_spectators()
	config_merges()
	min_players()
	left_roles()
	print("LOCALNET: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures:
		print("  FAIL ", failure)
	quit(0 if failures.is_empty() else 1)


# Polls everything until [param done] holds or [param seconds] pass.
func pump(things: Array, seconds: float, done := func(): return false) -> bool:
	var until := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < until:
		for thing in things:
			thing.poll()
		if done.call():
			return true
		OS.delay_usec(500)
	return false


# Like [method pump], but each thing is polled only every [param every_usec] (0 for as
# often as possible), as a device with that frame time would.
func pump_frames(things: Array, every_usec: Array, seconds: float, done := func(): return false) -> bool:
	var until := Time.get_ticks_usec() + int(seconds * 1_000_000)
	var next := []
	next.resize(things.size())
	next.fill(0)
	while Time.get_ticks_usec() < until:
		for i in things.size():
			var now := Time.get_ticks_usec()
			if now >= next[i]:
				next[i] = now + every_usec[i]
				things[i].poll()
		if done.call():
			return true
		OS.delay_usec(500)
	return false


func host_lobby(players := 2, code := "") -> LocalNetLobby:
	var lobby := LocalNetLobby.new(GAME, 1)
	check(lobby.host("Host", players, code) == OK, "Host opens a lobby")
	return lobby


func join_lobby(host: LocalNetLobby, player_name: String, code := "", version := 1) -> LocalNetLobby:
	var lobby := LocalNetLobby.new(GAME, version)
	check(lobby.join("127.0.0.1", host.link.port, player_name, code) == OK, "%s starts joining" % player_name)
	return lobby


func discovery() -> void:
	var host := host_lobby()
	var advertiser := LocalNetDiscovery.new(GAME, 1)
	check(advertiser.advertise(host.advert(), PORT) == OK, "Host advertises")
	var scanner := LocalNetDiscovery.new(GAME, 1)
	var found := []
	scanner.session_found.connect(func(s): found.append(s))
	scanner.scan(PackedStringArray(["127.0.0.1"]), PORT)
	pump([advertiser, scanner], 2.0, func(): return not found.is_empty())
	check(found.size() == 1, "Scanner finds the host")
	if found.size() == 1:
		check(found[0].port == host.link.port and found[0].name == "Host", "Found session carries the game port and name")
		check(found[0].compatible and found[0].players == 1 and found[0].max_players == 2, "Found session is compatible with one of two players")
	var newer := LocalNetDiscovery.new(GAME, 2)
	newer.scan(PackedStringArray(["127.0.0.1"]), PORT)
	pump([advertiser, newer], 1.5, func(): return not newer.sessions().is_empty())
	check(newer.sessions().size() == 1 and not newer.sessions()[0].compatible, "A different version is listed as incompatible")
	var stranger := LocalNetDiscovery.new("another-game", 1)
	stranger.scan(PackedStringArray(["127.0.0.1"]), PORT)
	pump([advertiser, stranger], 1.2)
	check(stranger.sessions().is_empty(), "Other games' hosts stay hidden")
	var targets := LocalNetDiscovery.sweep_targets(false)
	check(not targets.has("127.0.0.1") and targets.size() % 254 == 0, "Subnet sweep covers whole /24s and skips loopback")
	for s in [advertiser, scanner, newer, stranger]:
		s.stop()
	host.leave()


func lobby_join() -> void:
	var host := host_lobby()
	var client := join_lobby(host, "Guest")
	var joined := []
	client.joined.connect(func(id): joined.append(id))
	pump([host, client], 3.0, func(): return host.members.size() == 2 and client.members.size() == 2)
	check(joined.size() == 1 and client.local_id == joined[0], "Client is welcomed with its id")
	check(host.members.size() == 2 and client.members.size() == 2, "Both sides list two members")
	check(client.local_slot() == 1 and host.local_slot() == 0, "Host takes slot 0, the guest slot 1")
	client.set_data({"fish": "snoek"})
	host.set_config({"stage": 3})
	pump([host, client], 2.0, func(): return client.config.get("stage") == 3 and host.members[client.local_id].data.get("fish") == "snoek")
	check(host.members[client.local_id].data.get("fish") == "snoek", "Host sees the guest's choice")
	check(client.config.get("stage") == 3, "Guest sees the host's settings")
	client.leave()
	host.leave()


func lobby_rejects() -> void:
	var host := host_lobby(2, "reef")
	for attempt in [["No code", "", 1, "Wrong join code"], ["Old build", "reef", 0, "Different version (host has v1)"]]:
		var client := join_lobby(host, attempt[0], attempt[1], attempt[2])
		var reason := [""]
		client.rejected.connect(func(r): reason[0] = r)
		pump([host, client], 3.0, func(): return reason[0] != "")
		check(reason[0] == attempt[3], "%s is turned away: %s" % [attempt[0], reason[0]])
		check(host.members.size() == 1, "%s never becomes a member" % attempt[0])
	var first := join_lobby(host, "First", "reef")
	pump([host, first], 3.0, func(): return host.members.size() == 2)
	var late := join_lobby(host, "Late", "reef")
	var reason := [""]
	late.rejected.connect(func(r): reason[0] = r)
	pump([host, first, late], 3.0, func(): return reason[0] != "")
	check(reason[0] == "Lobby is full", "A full lobby turns latecomers away")
	for lobby in [first, late, host]:
		lobby.leave()


func clock_and_start() -> void:
	var host := host_lobby()
	var client := join_lobby(host, "Guest")
	pump([host, client], 4.0, func(): return host.can_start())
	check(host.can_start(), "Host can start once the guest's clock is synced")
	check(absi(client.clock_offset_usec) < 5000, "Same machine clocks agree within 5 ms (%d us)" % client.clock_offset_usec)
	host.set_config({"delay": 3})
	var starts := {}
	host.started.connect(func(config, at): starts["host"] = [config, at])
	client.started.connect(func(config, at): starts["client"] = [config, at])
	host.start()
	pump([host, client], 2.0, func(): return starts.size() == 2)
	check(starts.size() == 2, "Both sides start")
	if starts.size() == 2:
		check(starts.client[0].get("delay") == 3, "Start carries the settings")
		check(absi(starts.client[1] - starts.host[1]) < 5000, "Both start within 5 ms of each other")
		check(starts.host[1] > Time.get_ticks_usec(), "Start lies ahead, leaving time to deliver it")
	client.leave()
	host.leave()


# Every device runs LocalNetLockstep; afterwards every device must have stepped the same inputs.
func lockstep(players: int, drop: float, latency: float, jitter: float, label: String, delay := 3) -> Array:
	var host := host_lobby(players)
	var lobbies: Array[LocalNetLobby] = [host]
	for i in range(1, players):
		lobbies.append(join_lobby(host, "Guest %d" % i))
	pump(lobbies, 5.0, func(): return host.can_start() and lobbies.all(func(l): return l.members.size() == players))
	check(host.can_start(), "%s: everyone joins" % label)
	var starts := {}
	for lobby in lobbies:
		lobby.started.connect(func(_config, at): starts[lobby] = at)
	host.start()
	pump(lobbies, 2.0, func(): return starts.size() == players)
	for lobby in lobbies:
		lobby.link.debug_drop = drop
		lobby.link.debug_latency_msec = latency
		lobby.link.debug_jitter_msec = jitter
	var ticks := 480
	var runners := []
	var desyncs := []
	var most_per_frame := [0]
	for lobby in lobbies:
		var sync := LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), delay, 2)
		sync.desynced.connect(func(t, _id): desyncs.append(t))
		var rng := RandomNumberGenerator.new()
		rng.seed = lobby.local_slot() + 11
		var history := PackedInt64Array()
		var runner := LocalNetLockstep.new(sync, starts[lobby], 120,
			func(_t): return PackedByteArray([rng.randi() % 256, rng.randi() % 256]),
			func(_t, inputs): history.append(hash(inputs)),
			func(): return history[-1])
		runners.append({"runner": runner, "history": history})
	var step := func():
		for r in runners:
			if r.runner.tick < ticks:
				r.runner.max_ticks_per_frame = mini(8, ticks - r.runner.tick)
				most_per_frame[0] = maxi(most_per_frame[0], r.runner.advance())
			else:
				r.runner.sync.flush()
		return runners.all(func(r): return r.runner.tick >= ticks)
	var finished := pump(lobbies, 20.0, step)
	pump(lobbies, 0.3)
	check(finished, "%s: all %d players reach tick %d" % [label, players, ticks])
	var same := runners.all(func(r): return r.history == runners[0].history)
	check(same, "%s: every device stepped identical inputs" % label)
	check(desyncs.is_empty(), "%s: checksums agree" % label)
	check(most_per_frame[0] <= runners[0].runner.slack_ticks + 2, "%s: never races through a backlog (at most %d ticks in a frame)" % [label, most_per_frame[0]])
	for r in runners:
		r.runner.sync.close()
	for lobby in lobbies:
		lobby.leave()
	return runners.map(func(r): return r.runner)


# A link far slower than the input delay: the game waits, then eases back in rather than fast-forwarding.
func stalls() -> void:
	var runners := lockstep(2, 0.0, 45.0, 0.0, "slow link", 1)
	if runners.size() == 2:
		check(runners.all(func(r): return r.stalled_frames > 0 and r.shifted_usec > 0), "Slow link: both sides wait and move their schedule back")


func ports() -> void:
	var first := LocalNetDiscovery.new(GAME, 1)
	var second := LocalNetDiscovery.new(GAME, 1)
	var a := host_lobby()
	var b := host_lobby()
	a.session_name = "First"
	b.session_name = "Second"
	check(first.advertise(a.advert(), PORT) == OK and first.advertised_port == PORT, "First host takes the discovery port")
	check(second.advertise(b.advert(), PORT) == OK and second.advertised_port == PORT + 1, "Second host on the same device falls back to the next port")
	var scanner := LocalNetDiscovery.new(GAME, 1)
	scanner.scan(PackedStringArray(["127.0.0.1"]), PORT)
	pump([first, second, scanner], 2.0, func(): return scanner.sessions().size() == 2)
	var names := scanner.sessions().map(func(s): return s.name)
	check(names == ["First", "Second"], "A scan of this device finds both hosts: %s" % [names])
	for d in [first, second, scanner]:
		d.stop()
	a.leave()
	b.leave()
	var fixed := LocalNetLobby.new(GAME, 1)
	check(fixed.host("Fixed", 2, "", 47790) == OK and fixed.link.port == 47790, "A host can choose its game port")
	var clash := LocalNetLobby.new(GAME, 1)
	check(clash.host("Clash", 2, "", 47790) != OK, "A taken game port is refused")
	fixed.leave()


func typed_messages() -> void:
	var host := host_lobby()
	var client := join_lobby(host, "Guest")
	pump([host, client], 3.0, func(): return host.members.size() == 2)
	client.set_data({"fish": 2, "spot": Vector2(1.5, -2)})
	host.set_config({"stage": 4, "rounds": 3})
	pump([host, client], 2.0, func(): return client.config.has("stage") and not host.members[client.local_id].data.is_empty())
	var data: Dictionary = host.members[client.local_id].data
	check(typeof(data.get("fish")) == TYPE_INT and data.fish == 2, "Numbers stay integers across the wire")
	check(data.get("spot") == Vector2(1.5, -2), "Vectors survive the wire")
	check(typeof(client.config.get("stage")) == TYPE_INT, "Settings keep their types")
	client.leave()
	host.leave()


func loading_and_rematch() -> void:
	var host := host_lobby()
	var client := join_lobby(host, "Guest")
	for l in [host, client]:
		l.wait_for_loading = true
	pump([host, client], 4.0, func(): return host.can_start())
	var events := []
	for l in [host, client]:
		var who := "host" if l == host else "guest"
		l.preparing.connect(func(_c): events.append(who + " prepares"))
		l.started.connect(func(_c, _at): events.append(who + " starts"))
		l.returned.connect(func(): events.append(who + " returns"))
	host.start()
	pump([host, client], 1.0, func(): return events.size() == 2)
	check(events.has("host prepares") and events.has("guest prepares") and client.state == "preparing", "Start first asks everyone to load")
	host.mark_loaded()
	pump([host, client], 0.5)
	check(not events.has("host starts"), "Nobody starts while a guest is still loading")
	client.mark_loaded()
	pump([host, client], 2.0, func(): return events.has("guest starts"))
	check(events.has("host starts") and events.has("guest starts"), "Everyone starts once all have loaded")
	host.return_to_lobby()
	pump([host, client], 2.0, func(): return events.has("guest returns"))
	check(client.state == "lobby" and host.state == "lobby" and events.has("guest returns"), "The host brings everyone back for a rematch")
	check(host.members.values().all(func(m): return not m.ready and not m.loaded), "Ready and loaded flags reset for the rematch")
	events.clear()
	host.start()
	pump([host, client], 1.0, func(): return client.state == "preparing")
	client.mark_loaded()
	host.mark_loaded()
	pump([host, client], 2.0, func(): return events.has("guest starts"))
	check(events.has("host starts") and events.has("guest starts"), "A rematch starts like the first match")
	client.leave()
	host.leave()


func suggested_delays() -> void:
	var quick := host_lobby()
	var guest := join_lobby(quick, "Guest")
	pump([quick, guest], 0.6)
	check(guest.state == "lobby" and not quick.can_start(), "A guest can't be started while its radio wakes and its link is measured")
	pump([quick, guest], 4.0, func(): return quick.can_start())
	check(quick.members[guest.local_id].net.get("rtt_p75_usec", 0) > 0, "...so once it can, the delay has round trips to go on")
	pump([quick, guest], 2.5)
	check(quick.suggested_delay() == 2 and guest.suggested_delay() == 2, "A quick link gets the minimum delay (%d, %d)" % [quick.suggested_delay(), guest.suggested_delay()])
	# Pings go out about as often as match inputs, but link reports only once a second:
	# each one has the host send the member list to everyone.
	var lists := [0]
	quick.members_changed.connect(func(): lists[0] += 1)
	var round_trips := guest._round_trips.size()
	pump([quick, guest], 3.0)
	check(guest._round_trips.size() > round_trips + 60 or guest._round_trips.size() == guest.LINK_SAMPLES, "Guests ping many times a second in the lobby")
	check(lists[0] <= 8, "...but report their link about once a second (%d member lists in 3 s)" % lists[0])
	guest.leave()
	quick.leave()
	var slow := host_lobby()
	var far := join_lobby(slow, "Far")
	for l in [slow, far]:
		l.link.debug_latency_msec = 40.0
	pump([slow, far], 6.0, func(): return slow.can_start())
	pump([slow, far], 2.5)
	check(slow.suggested_delay() >= 6 and slow.suggested_delay() == far.suggested_delay(), "An 80 ms round trip gets a longer delay, agreed by both (%d, %d)" % [slow.suggested_delay(), far.suggested_delay()])
	far.leave()
	slow.leave()
	# A quick link to a guest drawing a frame every 15 ms, like the A22 in a fight: its
	# inputs can leave up to a frame late and be noticed up to a frame late.
	var steady := host_lobby()
	var jerky := join_lobby(steady, "Jerky")
	pump_frames([steady, jerky], [0, 15_000], 6.0, func(): return steady.can_start())
	pump_frames([steady, jerky], [0, 15_000], 3.0)
	check(jerky.frame_usec() >= 14_000 and jerky.frame_usec() <= 20_000 and steady.frame_usec() < 5_000, "Each lobby times its own frames (%d, %d us)" % [steady.frame_usec(), jerky.frame_usec()])
	check(steady.members[jerky.local_id].net.get("frame_usec", 0) >= 14_000 and jerky.members[steady.local_id].net.get("frame_usec", -1) >= 0, "Members report their frame times, the host included")
	check(steady.suggested_delay() >= 3 and steady.suggested_delay() == jerky.suggested_delay(), "Slow frames lengthen the delay, agreed by both (%d, %d)" % [steady.suggested_delay(), jerky.suggested_delay()])
	jerky.leave()
	steady.leave()
	# A host drawing a frame every 300 ms, like the A22 loading a screen, answers pings only
	# between frames. Those round trips measure the host, not the network, and are left out.
	var loading := host_lobby()
	var patient := join_lobby(loading, "Patient")
	pump([loading, patient], 4.0, func(): return loading.can_start())
	pump_frames([loading, patient], [300_000, 0], 3.0)
	pump([loading, patient], 1.5)
	var slowest := 0
	for rtt in patient._round_trips:
		slowest = maxi(slowest, rtt)
	check(slowest < patient.HITCH_USEC and loading.suggested_delay() == 2, "Round trips that waited on a host's long frame are left out (slowest kept %d us, delay %d)" % [slowest, loading.suggested_delay()])
	patient.leave()
	loading.leave()


# A link that keeps what it sends, so tests can deliver it by hand.
class MemoryLink extends LocalNetLink:
	var outbox := []
	var round_trip_msec := 0.0

	func rtt_msec(_id: int) -> float:
		return round_trip_msec

	func send(_id: int, channel: int, bytes: PackedByteArray, _reliable: bool) -> void:
		outbox.append([channel, bytes])


# Two input syncs wired to each other in memory: the test decides when packets arrive
# and what time it is, so the runner's rules can be checked tick by tick.
func memory_pair(delay := 2) -> Array:
	var host_link := MemoryLink.new()
	host_link.is_host = true
	var host_sync := LocalNetInputSync.new(host_link, 2, 0, {2: 1}, delay, 1)
	var guest_sync := LocalNetInputSync.new(MemoryLink.new(), 2, 1, {1: -1}, delay, 1)
	return [host_sync, guest_sync]


func deliver(from: LocalNetInputSync, to: LocalNetInputSync, from_id: int) -> void:
	from.flush()
	for packet in from.link.outbox:
		to._on_received(from_id, packet[0], packet[1])
	from.link.outbox.clear()


func host_hears(pair: Array) -> void:
	deliver(pair[1], pair[0], 2)


func guest_hears(pair: Array) -> void:
	deliver(pair[0], pair[1], 1)


func guest_sends(pair: Array, through_tick: int, value := -1) -> void:
	var guest: LocalNetInputSync = pair[1]
	while guest.next_local_tick() <= through_tick:
		guest.add_local_input(guest.next_local_tick(), PackedByteArray([value if value >= 0 else guest.next_local_tick() % 256]))
	host_hears(pair)


func runner_rules() -> void:
	var pair := memory_pair()
	var tick_usec := 1_000_000.0 / 120
	var seen := []
	var runner := LocalNetLockstep.new(pair[0], 0, 120, func(_t): return PackedByteArray([7]), func(_t, inputs): seen.append(inputs[1][0]))
	var waits := []
	var resumes := []
	runner.waiting.connect(func(slots): waits.append(slots))
	runner.resumed.connect(func(usec): resumes.append(usec))
	guest_sends(pair, 4)
	var ran := runner.advance(int(10 * tick_usec))
	check(ran == 5 and runner.tick == 5, "Runner steps every tick whose inputs are known (%d)" % ran)
	check(runner.stalled_frames == 0 and waits.is_empty(), "A frame that ran some ticks before running out isn't a stall")
	check(runner.shifted_usec > 0 and runner.due_tick(int(10 * tick_usec)) - runner.tick <= runner.slack_ticks, "Falling behind moves the schedule back to within the slack")
	check(seen == [0, 0, 2, 3, 4], "Remote inputs arrive in tick order, after the blank delay ticks")
	var now := 11 * tick_usec
	var ran_while_silent := 0
	for frame in 12:
		now += 16_667
		ran_while_silent += runner.advance(int(now))
	check(ran_while_silent == 0, "Nothing runs while the guest is silent")
	check(runner.stalled_frames == 12 and runner.is_waiting(), "Frames with nothing to run count as stalled")
	check(waits.size() == 1 and waits[0] == [1] and runner.waiting_on() == [1], "Waiting is announced once, naming the missing slot")
	guest_sends(pair, 60)
	now += 16_667
	ran = runner.advance(int(now))
	check(resumes.size() == 1 and resumes[0] >= 180_000, "Resuming reports how long the stall lasted (%d us)" % (resumes[0] if resumes else 0))
	check(ran <= runner.slack_ticks + 3, "After a 200 ms stall it eases back in instead of fast-forwarding (%d ticks)" % ran)
	check(not runner.is_waiting() and runner.waiting_on().is_empty(), "Nobody is waited on once inputs arrive")


# A host at 90 fps and a guest at 60, like the A22 and the iPhone, with the host's
# packets held back 400 ms: both stall, for different lengths, and would drift apart.
func time_sync() -> void:
	var without := pair_sim(false, 90, 60, 3000, 400_000, 6.0)
	var with := pair_sim(true, 90, 60, 3000, 400_000, 6.0)
	var calm := pair_sim(true, 90, 60, 3000, 0, 6.0)
	check(without.stalls and without.drift >= 1.5, "Without time sync the host stays ahead after a hiccup (%.2f ticks)" % without.drift)
	check(with.stalls and absf(with.drift) <= 1.0, "With time sync both are back on the same tick (%.2f)" % with.drift)
	check(with.eased > 0 and with.most_eased <= 1667, "Easing back takes at most a tenth of any frame (%d us)" % with.most_eased)
	check(calm.eased == 0 and absf(calm.drift) < 0.5, "Without hiccups time sync leaves the schedule alone (%d us)" % calm.eased)
	# The phone soak's match 3: a 68 fps host and a 120 fps guest whose clock started 25 ms
	# ahead. The guest waits on its inputs so often that the ticks it reaches hide the lead;
	# the schedules' positions, read from both ends, don't.
	var offset := pair_sim(false, 68, 120, 14_500, 0, 10.0, 25_000, 4)
	var found := pair_sim(true, 68, 120, 14_500, 0, 10.0, 25_000, 4)
	var waited := func(result: Dictionary) -> float: return 100.0 * result.runners[1].stalled_frames / result.runners[1].frames
	check(waited.call(offset) > 30.0, "A guest whose clock runs ahead waits on most frames without time sync (%.0f%%)" % waited.call(offset))
	check(waited.call(found) < 3.0 and absf(found.drift) < 1.0, "Time sync finds the lead from both sides' readings and removes it (%.1f%% waiting, %.2f ticks apart)" % [waited.call(found), found.drift])
	check(found.runners[1].sync.clock_lead(1) < 1.0 and not is_nan(found.runners[1].sync.clock_lead(1)), "Each side's reading reaches the other (%.2f)" % found.runners[1].sync.clock_lead(1))


# Two runners on their own frame rates, packets taking [param latency] to arrive and the
# host's packets held back for [param blackout] after one second, as in a Wi-Fi hiccup.
# Returns how many ticks the guest's schedule ended up behind the host's (the host's lead).
## [param guest_lead] starts the guest's clock that far ahead of the host's, as when clock
## sync misjudges the offset; [param delay] is the input delay in ticks.
func pair_sim(enabled: bool, host_fps: float, guest_fps: float, latency: int, blackout: int, seconds: float, guest_lead := 0, delay := 3) -> Dictionary:
	var pair := memory_pair(delay)
	var runners := []
	for side in 2:
		var runner := LocalNetLockstep.new(pair[side], -guest_lead if side == 1 else 0, 120, func(_t): return PackedByteArray([1]), func(_t, _inputs): pass)
		runner.time_sync = enabled
		runners.append(runner)
	# As ENet measures it: both ways across, plus waiting for each side's next poll.
	for side in 2:
		pair[side].link.round_trip_msec = (2 * latency + (500_000.0 / host_fps + 500_000.0 / guest_fps)) / 1000.0
	var next_frame := [1_000_000.0 / host_fps, 1_000_000.0 / guest_fps]
	var fps := [host_fps, guest_fps]
	var in_flight := []
	var ids := [1, 2]
	var most_eased := 0
	var clock := {"now": 0}
	for side in 2:
		pair[side].clock = func(): return clock.now
	while minf(next_frame[0], next_frame[1]) < seconds * 1_000_000:
		var side := 0 if next_frame[0] <= next_frame[1] else 1
		var now := int(next_frame[side])
		clock.now = now
		next_frame[side] += 1_000_000.0 / fps[side]
		for packet in in_flight.duplicate():
			if packet.to == side and packet.due <= now:
				pair[side]._on_received(packet.from, packet.channel, packet.bytes)
				in_flight.erase(packet)
		var eased: int = runners[side].eased_usec
		runners[side].advance(now)
		most_eased = maxi(most_eased, runners[side].eased_usec - eased)
		for sent in pair[side].link.outbox:
			var due := now + latency
			if side == 0 and now >= 1_000_000 and now < 1_000_000 + blackout:
				due = 1_000_000 + blackout + latency
			in_flight.append({"to": 1 - side, "from": ids[side], "channel": sent[0], "bytes": sent[1], "due": due})
		pair[side].link.outbox.clear()
	return {"drift": (runners[1].schedule_usec - runners[0].schedule_usec) / runners[0].tick_usec, "stalls": runners.all(func(r): return r.stalled_frames > 0), "eased": runners[0].eased_usec + runners[1].eased_usec, "most_eased": most_eased, "runners": runners}


func free_run() -> void:
	var pair := memory_pair()
	var seen := []
	var runner := LocalNetLockstep.new(pair[0], 0, 120, func(_t): return PackedByteArray([7]), func(_t, inputs): seen.append(inputs[1][0]))
	runner.predict = true
	guest_sends(pair, 2, 9)
	runner.advance(int(6 * 1_000_000.0 / 120))
	check(seen == [0, 0, 9, 9, 9, 9, 9], "Free-run repeats the last known input for missing ticks: %s" % [seen])
	check(runner.predicted_ticks == 4 and runner.stalled_frames == 0, "Free-run counts its guesses and never stalls")
	var guesses: Array = pair[0].predicted_inputs(50)
	check(guesses[0].size() == 1 and guesses[1][0] == 9, "Predicted inputs cover every slot, blank where nothing is known")


func keeps_unconfirmed_inputs() -> void:
	var pair := memory_pair()
	var host: LocalNetInputSync = pair[0]
	while host.next_local_tick() <= 100:
		host.add_local_input(host.next_local_tick(), PackedByteArray([1]))
	host.discard_before(90)
	check(host._inputs[0].has(2), "Inputs the other side hasn't confirmed are kept")
	guest_hears(pair)
	host_hears(pair)
	host.discard_before(90)
	check(not host._inputs[0].has(2) and host._inputs[0].has(95), "Confirmed inputs before the cut-off are freed, later ones kept")


func sweep_plan() -> void:
	var scanner := LocalNetDiscovery.new(GAME, 1)
	var targets := LocalNetDiscovery.sweep_targets(scanner.use_broadcast)
	var unicast := Array(targets).filter(func(a): return not a.ends_with(".255")).size()
	var own := LocalNetDiscovery.local_ipv4().size()
	scanner._sweep(0)
	var first: int = scanner.last_sweep_targets
	scanner._sweep(0)
	var second: int = scanner.last_sweep_targets
	check(first == targets.size() + unicast * LocalNetDiscovery.FALLBACK_PORTS, "Every fourth sweep also tries the fallback ports across the network (%d probes)" % first)
	check(second == targets.size() + own * LocalNetDiscovery.FALLBACK_PORTS, "Other sweeps try the fallback ports on this device only (%d probes)" % second)
	scanner._pending.clear()


func stale_sessions() -> void:
	var host := host_lobby()
	var advertiser := LocalNetDiscovery.new(GAME, 1)
	advertiser.advertise(host.advert(), PORT)
	var scanner := LocalNetDiscovery.new(GAME, 1)
	scanner.stale_after = 0.6
	scanner.sweep_interval = 0.2
	scanner.scan(PackedStringArray(["127.0.0.1"]), PORT)
	pump([advertiser, scanner], 2.0, func(): return not scanner.sessions().is_empty())
	check(scanner.sessions().size() == 1, "The host is listed while it answers")
	advertiser.stop()
	pump([scanner], 1.0)
	check(scanner.sessions().is_empty(), "A host that stops answering drops off the list")
	scanner.stop()
	host.leave()


func lobby_edges() -> void:
	var host := host_lobby(3)
	var stays := join_lobby(host, "Stays")
	var quits := join_lobby(host, "Quits")
	var everyone := [host, stays, quits]
	for l in everyone:
		l.wait_for_loading = true
	pump(everyone, 4.0, func(): return host.members.size() == 3 and host.can_start())
	host.mark_loaded()
	check(host.state == "lobby", "Marking loaded outside a start does nothing")
	stays.return_to_lobby()
	host.return_to_lobby()
	check(host.state == "lobby" and stays.state == "lobby", "Returning to the lobby from the lobby, or as a guest, does nothing")
	var nets := []
	for id in host.members:
		if id != host.local_id:
			nets.append(host.members[id].net)
	check(nets.all(func(n): return n.has("rtt_p50_usec") and n.has("rtt_p90_usec") and n.has("rtt_max_usec")), "Guests report their link quality in the lobby")
	var starts := []
	host.started.connect(func(_c, _at): starts.append("host"))
	stays.started.connect(func(_c, _at): starts.append("stays"))
	host.start()
	pump(everyone, 1.0, func(): return stays.state == "preparing")
	host.mark_loaded()
	stays.mark_loaded()
	quits.leave()
	pump([host, stays], 5.0, func(): return starts.size() == 2)
	check(starts.size() == 2 and not host.members.has(3), "A player leaving while others load doesn't hold up the start")
	var net_at_start: Dictionary = host.members[stays.local_id].net.duplicate()
	pump([host, stays], 2.5)
	check(host.members[stays.local_id].net == net_at_start, "Link reports stop once the match starts")
	var late := join_lobby(host, "Late")
	var reason := [""]
	late.rejected.connect(func(r): reason[0] = r)
	pump([host, stays, late], 3.0, func(): return reason[0] != "")
	check(reason[0] == "Already playing", "Joining mid-match is turned away: %s" % reason[0])
	for l in [late, stays, host]:
		l.leave()


func delay_cap() -> void:
	var host := host_lobby()
	var guest := join_lobby(host, "Distant")
	for l in [host, guest]:
		l.link.debug_latency_msec = 150.0
	pump([host, guest], 8.0, func(): return host.can_start())
	# Round trips count once the first second after joining has passed.
	pump([host, guest], 2.5)
	check(host.suggested_delay() == 12, "A very slow link is capped at 12 ticks (%d)" % host.suggested_delay())
	check(host.suggested_delay(120, 12.0, 2, 20) > 12 and host.suggested_delay(60) < host.suggested_delay(120), "The cap and tick rate can be changed")
	guest.leave()
	host.leave()


func link_pair(window_msec := 3000) -> Array:
	var host := LocalNetLink.new()
	host.reconnect_window_msec = window_msec
	host.host(0, 4)
	var guest := LocalNetLink.new()
	guest.reconnect_window_msec = window_msec
	guest.join("127.0.0.1", host.port)
	pump([host, guest], 3.0, func(): return host.peers().size() == 1 and guest.peers().size() == 1)
	return [host, guest]


func events_of(link: LocalNetLink) -> Array:
	var log := []
	link.peer_connected.connect(func(id): log.append("connected %d" % id))
	link.peer_interrupted.connect(func(id): log.append("interrupted %d" % id))
	link.peer_resumed.connect(func(id): log.append("resumed %d" % id))
	link.peer_disconnected.connect(func(id, reason): log.append("gone %d %s" % [id, reason]))
	return log


func talks(pair: Array) -> bool:
	var heard := []
	var listen := func(id, _channel, bytes): heard.append([id, bytes.get_string_from_utf8()])
	for link in pair:
		link.received.connect(listen)
	pair[0].send(2, LocalNetLink.CHANNEL_CONTROL, "to guest".to_utf8_buffer(), true)
	pair[1].send(1, LocalNetLink.CHANNEL_CONTROL, "to host".to_utf8_buffer(), true)
	pair[0].flush()
	pair[1].flush()
	pump(pair, 2.0, func(): return heard.size() == 2)
	for link in pair:
		link.received.disconnect(listen)
	return heard.has([1, "to guest"]) and heard.has([2, "to host"])


func reconnects() -> void:
	# The guest's connection drops; it comes back with the same id.
	var pair := link_pair()
	var host_log := events_of(pair[0])
	var guest_log := events_of(pair[1])
	pair[1].debug_drop_connection(LocalNetLink.HOST_ID, 400)
	pump(pair, 0.2)
	check(pair[0].interrupted_peers() == [2] and pair[0].reconnect_seconds_left(2) > 2.0, "The host holds a dropped guest's place (%s)" % [pair[0].interrupted_peers()])
	check(pair[1].interrupted_peers() == [1] and not pair[1].is_peer_connected(1), "The guest knows it's reconnecting")
	pump(pair, 4.0, func(): return guest_log.has("resumed 1") and host_log.has("resumed 2"))
	check(host_log == ["interrupted 2", "resumed 2"], "Host: interrupted, then resumed with the same id: %s" % [host_log])
	check(guest_log == ["interrupted 1", "resumed 1"], "Guest: interrupted, then resumed: %s" % [guest_log])
	check(talks(pair), "Messages flow both ways after reconnecting")
	check(pair[0].interrupted_peers().is_empty() and pair[1].interrupted_peers().is_empty(), "Nothing is left waiting after a resume")
	# The host notices first this time.
	host_log.clear()
	guest_log.clear()
	pair[0].debug_drop_connection(2)
	pump(pair, 4.0, func(): return guest_log.has("resumed 1") and host_log.has("resumed 2"))
	check(host_log == ["interrupted 2", "resumed 2"] and guest_log == ["interrupted 1", "resumed 1"], "A drop the host notices first heals the same way: %s %s" % [host_log, guest_log])
	# Leaving on purpose ends it at once, with no waiting.
	host_log.clear()
	pair[1].close()
	pump([pair[0]], 2.0, func(): return not host_log.is_empty())
	check(host_log == ["gone 2 left"], "A guest leaving on purpose is gone at once: %s" % [host_log])
	pair[0].close()

	pair = link_pair()
	guest_log = events_of(pair[1])
	pair[0].close()
	pump([pair[1]], 2.0, func(): return not guest_log.is_empty())
	pump([pair[1]], 0.5)
	check(guest_log == ["gone 1 left"], "A host leaving on purpose ends it for the guest, with no reconnecting: %s" % [guest_log])
	pair[1].close()

	# Back too late: the host has let the guest go, and says so.
	pair = link_pair(3000)
	pair[0].reconnect_window_msec = 700
	host_log = events_of(pair[0])
	guest_log = events_of(pair[1])
	pair[1].debug_drop_connection(LocalNetLink.HOST_ID, 1500)
	pump(pair, 4.0, func(): return guest_log.has("gone 1 lost"))
	check(host_log == ["interrupted 2", "gone 2 lost"], "The host lets a guest go when the window runs out: %s" % [host_log])
	check(guest_log.back() == "gone 1 lost", "A guest back too late is told it's gone: %s" % [guest_log])
	for link in pair:
		link.close()


func broken_sockets() -> void:
	# The host's socket breaks: it opens a new one, and the guest finds it again.
	var pair := link_pair(10_000)
	var host_log := events_of(pair[0])
	var guest_log := events_of(pair[1])
	var port: int = pair[0].port
	pair[0].debug_break_socket()
	check(pair[0].is_open() and pair[0].port == port and host_log == ["interrupted 2"], "A host with a broken socket reopens it on the same port")
	pump(pair, 12.0, func(): return host_log.has("resumed 2") and guest_log.has("resumed 1"))
	check(host_log == ["interrupted 2", "resumed 2"] and guest_log == ["interrupted 1", "resumed 1"], "The guest times out, reconnects and resumes: %s %s" % [host_log, guest_log])
	# The guest's socket breaks: the host never noticed a drop, but takes it back anyway.
	host_log.clear()
	guest_log.clear()
	pair[1].debug_break_socket()
	pump(pair, 4.0, func(): return guest_log.has("resumed 1"))
	pump(pair, 1.0)
	check(guest_log == ["interrupted 1", "resumed 1"] and host_log == ["resumed 2"], "A guest with a broken socket resumes, replacing its old connection: %s %s" % [host_log, guest_log])
	check(talks(pair), "Messages flow after both kinds of socket failure")
	for link in pair:
		link.close()


func lobby_reconnects() -> void:
	var host := host_lobby()
	var guest := join_lobby(host, "Guest")
	pump([host, guest], 4.0, func(): return host.can_start())
	var events := []
	host.member_interrupted.connect(func(id): events.append("host: %d interrupted" % id))
	host.member_resumed.connect(func(id): events.append("host: %d resumed" % id))
	guest.connection_interrupted.connect(func(): events.append("guest: interrupted"))
	guest.connection_resumed.connect(func(): events.append("guest: resumed"))
	var id := guest.local_id
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 500)
	pump([host, guest], 0.2)
	check(not host.members[id].connected and not host.can_start(), "A dropped member shows as not connected, and blocks the start")
	host.set_config({"stage": 5})
	pump([host, guest], 4.0, func(): return guest.config.get("stage") == 5)
	check(guest.config.get("stage") == 5 and host.members[id].connected and guest.members[id].connected, "Back in the lobby, the guest catches up on what it missed")
	check(events == ["guest: interrupted", "host: %d interrupted" % id, "guest: resumed", "host: %d resumed" % id] or events == ["host: %d interrupted" % id, "guest: interrupted", "guest: resumed", "host: %d resumed" % id], "Both sides hear about the drop and the return: %s" % [events])
	# The match starts while the guest is away: it joins in when it's back.
	var starts := {}
	host.started.connect(func(_c, at): starts["host"] = at)
	guest.started.connect(func(_c, at): starts["guest"] = at)
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 700)
	pump([host, guest], 0.1)
	host.start()
	pump([host, guest], 4.0, func(): return starts.size() == 2)
	check(starts.size() == 2 and absi(starts.get("guest", 0) - starts.get("host", 0)) < 5000, "A guest who missed the start starts with everyone else's clock")
	# The host goes quiet for good: the guest gives up when the window runs out.
	var closed := [""]
	guest.closed.connect(func(r): closed[0] = r)
	guest.link.reconnect_window_msec = 1000
	host.link.debug_drop_connection(id)
	host.link._enet.destroy()
	host.link._enet = null
	pump([guest], 4.0, func(): return closed[0] != "")
	check(closed[0] == "Lost connection to the host", "A guest that can't get back says so: %s" % closed[0])
	guest.leave()


func joined_pair() -> Array:
	var host := host_lobby()
	var guest := join_lobby(host, "Guest")
	pump([host, guest], 4.0, func(): return host.can_start())
	return [host, guest]


func reconnect_settings() -> void:
	# The host picks the window and the guest follows it.
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	check(host.reconnect_window_msec == 30_000 and guest.link.reconnect_window_msec == 30_000, "Both sides wait 30 s by default")
	host.reconnect_window_msec = 5_000
	pump(pair, 2.0, func(): return guest.reconnect_window_msec == 5_000)
	check(guest.reconnect_window_msec == 5_000 and guest.link.reconnect_window_msec == 5_000 and host.link.reconnect_window_msec == 5_000, "A window the host sets reaches the guest")

	# Waiting forever: nothing times out until the game gives up, on either side.
	host.reconnect_window_msec = LocalNetLink.WAIT_FOREVER
	pump(pair, 2.0, func(): return guest.reconnect_window_msec == LocalNetLink.WAIT_FOREVER)
	var id := guest.local_id
	var left := []
	var closed := [""]
	host.member_left.connect(func(i, reason): left.append([i, reason]))
	guest.closed.connect(func(reason): closed[0] = reason)
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 60_000)
	pump(pair, 1.5)
	check(host.members.has(id) and not host.members[id].connected and host.link.reconnect_seconds_left(id) == INF, "Waiting forever holds a dropped guest's place with no countdown")
	host.give_up(id)
	check(left == [[id, "lost"]] and not host.members.has(id), "The host giving up lets the guest go at once: %s" % [left])
	check(guest.link.reconnect_seconds_left(LocalNetLink.HOST_ID) == INF and closed[0] == "", "The guest is still waiting for the host")
	guest.give_up()
	check(closed[0] == "Lost connection to the host" and guest.link.interrupted_peers().is_empty(), "The guest giving up closes it at once")
	host.leave()
	guest.leave()

	# Waiting forever still lets a guest come back.
	pair = joined_pair()
	host = pair[0]
	guest = pair[1]
	host.reconnect_window_msec = LocalNetLink.WAIT_FOREVER
	pump(pair, 1.0)
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 2_500)
	pump(pair, 6.0, func(): return host.members[guest.local_id].connected and guest.link.is_peer_connected(LocalNetLink.HOST_ID))
	check(host.members[guest.local_id].connected and guest.link.is_peer_connected(LocalNetLink.HOST_ID), "A guest that waits forever comes back after a 2.5 s drop")
	host.leave()
	guest.leave()

	# A window of 0 turns reconnecting off: a drop is final straight away.
	pair = joined_pair()
	host = pair[0]
	guest = pair[1]
	host.reconnect_window_msec = 0
	pump(pair, 1.0)
	left = []
	closed = [""]
	host.member_left.connect(func(i, reason): left.append([i, reason]))
	guest.closed.connect(func(reason): closed[0] = reason)
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID)
	pump(pair, 2.0, func(): return not left.is_empty())
	check(left.size() == 1 and left[0][1] == "lost" and closed[0] == "Lost connection to the host", "With no window a drop ends it for both at once: %s, %s" % [left, closed[0]])
	host.leave()
	guest.leave()


# A mid-match drop: both sides wait, the guest reconnects, and the match carries on in sync.
func lockstep_through_drop() -> void:
	var host := host_lobby()
	var guest := join_lobby(host, "Guest")
	var lobbies: Array[LocalNetLobby] = [host, guest]
	pump(lobbies, 4.0, func(): return host.can_start())
	var starts := {}
	for lobby in lobbies:
		lobby.started.connect(func(_config, at): starts[lobby] = at)
	host.start()
	pump(lobbies, 2.0, func(): return starts.size() == 2)
	var runners := []
	var desyncs := []
	for lobby in lobbies:
		var sync := LocalNetInputSync.new(lobby.link, 2, lobby.local_slot(), lobby.peer_slots(), 3, 2)
		sync.desynced.connect(func(t, _id): desyncs.append(t))
		var rng := RandomNumberGenerator.new()
		rng.seed = lobby.local_slot() + 5
		var history := PackedInt64Array()
		var runner := LocalNetLockstep.new(sync, starts[lobby], 120,
			func(_t): return PackedByteArray([rng.randi() % 256, rng.randi() % 256]),
			func(_t, inputs): history.append(hash(inputs)),
			func(): return history[-1])
		runners.append({"runner": runner, "history": history})
	var dropped := [false]
	var ticks := 600
	var step := func():
		for r in runners:
			if r.runner.tick < ticks:
				r.runner.max_ticks_per_frame = mini(8, ticks - r.runner.tick)
				r.runner.advance()
			else:
				r.runner.sync.flush()
		if not dropped[0] and runners[1].runner.tick >= 200:
			dropped[0] = true
			guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 800)
		return runners.all(func(r): return r.runner.tick >= ticks)
	var finished := pump(lobbies, 20.0, step)
	pump(lobbies, 0.3)
	check(dropped[0] and finished, "A match survives an 800 ms disconnection and finishes")
	check(runners[0].history == runners[1].history and desyncs.is_empty(), "After reconnecting, both devices stepped identical inputs")
	check(runners.all(func(r): return r.runner.longest_stall_usec >= 700_000), "Both sides waited out the drop rather than guessing")
	for r in runners:
		r.runner.sync.close()
	for lobby in lobbies:
		lobby.leave()


func desync() -> void:
	var host := host_lobby()
	var client := join_lobby(host, "Guest")
	pump([host, client], 4.0, func(): return host.can_start())
	host.start()
	pump([host, client], 1.0, func(): return client.state == "started")
	var host_sync := LocalNetInputSync.new(host.link, 2, 0, host.peer_slots())
	var client_sync := LocalNetInputSync.new(client.link, 2, 1, client.peer_slots())
	var seen := {}
	host_sync.desynced.connect(func(t, id): seen["host"] = t)
	client_sync.desynced.connect(func(t, id): seen["client"] = t)
	host_sync.report_checksum(60, 1234)
	client_sync.report_checksum(60, 1234)
	host_sync.report_checksum(120, 1234)
	client_sync.report_checksum(120, 999)
	pump([host, client], 2.0, func(): return seen.size() == 2)
	check(seen.get("host") == 120 and seen.get("client") == 120, "Both sides notice the state drifting at tick 120")
	host_sync.close()
	client_sync.close()
	client.leave()
	host.leave()


func departures() -> void:
	var host := host_lobby()
	var client := join_lobby(host, "Guest")
	pump([host, client], 3.0, func(): return host.members.size() == 2)
	var left := []
	host.member_left.connect(func(id, reason): left.append([id, reason]))
	client.leave()
	pump([host], 3.0, func(): return not left.is_empty())
	check(left.size() == 1 and left[0][1] == "left" and host.members.size() == 1, "Host notices a guest leaving, on purpose")
	var again := join_lobby(host, "Again")
	pump([host, again], 3.0, func(): return host.members.size() == 2)
	var reason := [""]
	again.closed.connect(func(r): reason[0] = r)
	host.leave()
	pump([again], 3.0, func(): return reason[0] != "")
	check(reason[0] == "The host left", "Guest notices the host leaving")
	again.leave()


# Off Android there's nothing to bind: the default route already reaches the LAN.
func wifi_route() -> void:
	check(LocalNetWifiRoute.bind() == "n/a" and not LocalNetWifiRoute.is_bound(), "Wi-Fi binding is Android-only")
	LocalNetWifiRoute.release()
	check(not LocalNetWifiRoute.is_bound(), "Releasing without a binding is harmless")


func stats() -> void:
	var s := LocalNetLatencyStats.new(120)
	for lateness in [1000, 2000, 3000, 9000, 30000]:
		s.add(lateness)
	check(is_equal_approx(s.percentile_msec(50), 3.0), "Median lateness is 3 ms")
	check(is_equal_approx(s.stall_share(0), 1.0), "With no delay every input is late")
	check(is_equal_approx(s.stall_share(1), 0.4), "One tick (8.3 ms) hides three of five")
	check(s.delay_for(0.0) == 4, "Four ticks hide everything")


# LocalNet 0.3: a guest from another LocalNet version is turned away, even with the same game.
func wire_version() -> void:
	var host := host_lobby()
	for hello in [{"t": "hello", "game": GAME, "v": 1, "name": "Old"}, {"t": "hello", "game": GAME, "v": 1, "ln": LocalNetLobby.WIRE_VERSION + 1, "name": "Newer"}]:
		var old := LocalNetLink.new()
		old.join("127.0.0.1", host.link.port)
		var reason := [""]
		old.peer_connected.connect(func(id):
			old.send(id, LocalNetLink.CHANNEL_CONTROL, var_to_bytes(hello), true)
			old.flush())
		old.received.connect(func(_id, _channel, bytes):
			var message = bytes_to_var(bytes)
			if message is Dictionary and message.get("t") == "reject":
				reason[0] = message.reason)
		pump([host, old], 3.0, func(): return reason[0] != "")
		check(reason[0] == "Different LocalNet version" and host.members.size() == 1, "A hello %s is turned away: %s" % ["without a LocalNet version" if not hello.has("ln") else "from another LocalNet version", reason[0]])
		old.close()
	host.leave()


func join_as(host: LocalNetLobby, player_name: String, role: String) -> LocalNetLobby:
	var lobby := LocalNetLobby.new(GAME, 1)
	check(lobby.join("127.0.0.1", host.link.port, player_name, "", role) == OK, "%s starts joining" % player_name)
	return lobby


func rejection(host: LocalNetLobby, others: Array, guest: LocalNetLobby) -> String:
	var reason := [""]
	guest.rejected.connect(func(r): reason[0] = r)
	pump([host, guest] + others, 3.0, func(): return reason[0] != "")
	guest.leave()
	return reason[0]


func spectator_joins() -> void:
	var closed := host_lobby()
	check(rejection(closed, [], join_as(closed, "Nosy", "spectator")) == "Spectators aren't allowed", "Spectators are turned away by default")
	closed.leave()
	var host := LocalNetLobby.new(GAME, 1)
	host.max_spectators = 1
	host.host("Host", 2)
	var watcher := join_as(host, "Watcher", "spectator")
	pump([host, watcher], 3.0, func(): return watcher.members.size() == 2)
	var id := watcher.local_id
	check(host.members.has(id) and host.members[id].role == "spectator" and host.members[id].slot == -1, "A spectator joins with no slot")
	check(watcher.is_spectator() and watcher.local_slot() == -1 and not host.is_spectator() and host.members[host.local_id].role == "player", "Each side knows who watches and who plays")
	check(rejection(host, [watcher], join_as(host, "Crowd", "spectator")) == "No room for spectators", "Spectators beyond the limit are turned away")
	var player := join_lobby(host, "Player")
	pump([host, watcher, player], 3.0, func(): return host.members.size() == 3)
	check(host.members.size() == 3 and player.local_slot() == 1, "A spectator doesn't take a player's place")
	check(rejection(host, [watcher, player], join_lobby(host, "Third")) == "Lobby is full", "Players are still limited to max_players")
	for l in [player, watcher, host]:
		l.leave()


func spectator_counts() -> void:
	var host := LocalNetLobby.new(GAME, 1)
	host.max_spectators = 2
	host.host("Host", 3)
	var watcher := join_as(host, "Watcher", "spectator")
	watcher.link.debug_latency_msec = 120.0
	pump([host, watcher], 4.0, func(): return host.members.get(watcher.local_id, {}).get("synced", false))
	check(not host.can_start(), "A host and a spectator aren't enough to start")
	var player := join_lobby(host, "Player")
	var everyone := [host, watcher, player]
	pump(everyone, 5.0, func(): return host.can_start())
	pump(everyone, 2.5)
	var w := watcher.local_id
	var p := player.local_id
	check(host.can_start() and host.players() == [1, p] and host.spectators() == [w], "Players and spectators are listed apart (%s, %s)" % [host.players(), host.spectators()])
	var advert := host.advert()
	check(advert.players == 2 and advert.spectators == 1 and advert.max_spectators == 2, "The advert counts players and spectators apart: %s" % [advert])
	var advertiser := LocalNetDiscovery.new(GAME, 1)
	advertiser.advertise(advert, PORT)
	var scanner := LocalNetDiscovery.new(GAME, 1)
	scanner.scan(PackedStringArray(["127.0.0.1"]), PORT)
	pump(everyone + [advertiser, scanner], 2.0, func(): return not scanner.sessions().is_empty())
	var found: Dictionary = scanner.sessions()[0] if scanner.sessions() else {}
	check(found.get("players") == 2 and found.get("spectators") == 1 and found.get("max_spectators") == 2, "Scanners see the counts too")
	advertiser.stop()
	scanner.stop()
	check(host.members[w].net.get("rtt_p75_usec", 0) > 100_000, "The spectator's slow link is measured (%d us)" % host.members[w].net.get("rtt_p75_usec", 0))
	var delays := everyone.map(func(l): return l.suggested_delay())
	check(delays[0] <= 3 and delays.all(func(d): return d == delays[0]), "A spectator's slow link doesn't lengthen the delay, agreed by all (%s)" % [delays])
	host.set_ready(true)
	player.set_ready(true)
	pump(everyone, 2.0, func(): return host.members[p].ready)
	check(host.can_start(true), "Spectators needn't be ready")
	host.start()
	pump(everyone, 2.0, func(): return watcher.state == "started")
	check(host.members[1].slot == 0 and host.members[p].slot == 1 and host.members[w].slot == -1, "Slots are numbered over the players only")
	check(host.peer_slots() == {w: -1, p: 1} and watcher.peer_slots() == {1: -1}, "The host maps a spectator to no slot (%s)" % [host.peer_slots()])
	for l in everyone:
		l.leave()


# Every lobby runs a lockstep match; afterwards every device, spectators included, must
# have stepped the same inputs. Returns the runners, host first.
func lockstep_match(lobbies: Array, drop: float, latency: float, jitter: float, label: String, delay := 3, ticks := 480) -> Array:
	var host: LocalNetLobby = lobbies[0]
	pump(lobbies, 6.0, func(): return host.can_start() and lobbies.all(func(l): return l.members.size() == lobbies.size()))
	check(host.can_start(), "%s: everyone joins" % label)
	var starts := {}
	for lobby in lobbies:
		lobby.started.connect(func(_config, at): starts[lobby] = at)
	host.start()
	pump(lobbies, 2.0, func(): return starts.size() == lobbies.size())
	for lobby in lobbies:
		lobby.link.debug_drop = drop
		lobby.link.debug_latency_msec = latency
		lobby.link.debug_jitter_msec = jitter
	var players := host.players().size()
	var runners := []
	var desyncs := []
	for lobby in lobbies:
		var sync := LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), delay, 2)
		sync.desynced.connect(func(t, _id): desyncs.append(t))
		var rng := RandomNumberGenerator.new()
		rng.seed = lobby.local_slot() + 11
		var history := PackedInt64Array()
		var runner := LocalNetLockstep.new(sync, starts[lobby], 120,
			func(_t): return PackedByteArray([rng.randi() % 256, rng.randi() % 256]),
			func(_t, inputs): history.append(hash(inputs)),
			func(): return history[-1])
		runners.append({"runner": runner, "history": history})
	var step := func():
		for r in runners:
			if r.runner.tick < ticks:
				r.runner.max_ticks_per_frame = mini(8, ticks - r.runner.tick)
				r.runner.advance()
			else:
				r.runner.sync.flush()
		return runners.all(func(r): return r.runner.tick >= ticks)
	var finished := pump(lobbies, 20.0, step)
	pump(lobbies, 0.3)
	check(finished, "%s: all %d devices reach tick %d" % [label, lobbies.size(), ticks])
	check(runners.all(func(r): return r.history == runners[0].history), "%s: every device stepped identical inputs" % label)
	check(desyncs.is_empty() and runners.all(func(r): return r.runner.sync._checksums.size() > 0), "%s: checksums agree on every device" % label)
	for r in runners:
		r.runner.sync.close()
	for lobby in lobbies:
		lobby.leave()
	return runners.map(func(r): return r.runner)


# A host that doesn't play (a PC driving a big screen) relays two phones' inputs.
func organiser(drop: float, latency: float, jitter: float, label: String) -> void:
	var host := LocalNetLobby.new(GAME, 1)
	check(host.host("Screen", 2, "", 0, false) == OK, "%s: a host can open a lobby it doesn't play in" % label)
	check(host.is_spectator() and host.local_slot() == -1 and host.players().is_empty(), "%s: the host has no slot" % label)
	var lobbies: Array = [host, join_lobby(host, "One")]
	pump(lobbies, 4.0, func(): return host.members.size() == 2 and host.members.values().all(func(m): return m.synced))
	check(host.members.size() == 2 and not host.can_start(), "%s: one player isn't enough to start" % label)
	lobbies.append(join_lobby(host, "Two"))
	pump(lobbies, 6.0, func(): return host.can_start())
	pump(lobbies, 2.5)
	var plays := LocalNetLobby.new(GAME, 1)
	plays.members = host.members.duplicate(true)
	plays.members[1].role = "player"
	var delays := lobbies.map(func(l): return l.suggested_delay())
	check(delays.all(func(d): return d == delays[0]) and delays[0] >= plays.suggested_delay(), "%s: the relayed delay is agreed by all, and no shorter than a direct one (%s, %d)" % [label, delays, plays.suggested_delay()])
	var runners := lockstep_match(lobbies, drop, latency, jitter, label)
	if runners.size() == 3:
		check(runners[0].sync.next_local_tick() == -1 and runners[0].sync._inputs.all(func(slot): return not slot.is_empty()), "%s: the host samples nothing but holds both players' inputs" % label)


# A host and a guest play while a spectator follows the relayed inputs.
func spectator_match() -> void:
	var host := LocalNetLobby.new(GAME, 1)
	host.max_spectators = 1
	host.host("Host", 2)
	var lobbies: Array = [host, join_lobby(host, "Guest"), join_as(host, "Watcher", "spectator")]
	var runners := lockstep_match(lobbies, 0.1, 5.0, 5.0, "spectated")
	if runners.size() == 3:
		check(runners[2].sync.is_spectating() and runners[2].tick >= 480, "Spectated: the spectator follows the whole match")
		check(runners[0].sync.timing_peers() == [lobbies[1].local_id], "Spectated: the host's time sync only counts the player")


# A link that keeps what it sends and who to, so a test can deliver it later.
class AddressedLink extends LocalNetLink:
	var outbox := []

	func send(id: int, channel: int, bytes: PackedByteArray, _reliable: bool) -> void:
		outbox.append([id, channel, bytes])


# A host at 90 fps and a guest at 60 play while a spectator at 20 fps, with a 120 ms
# link, watches. Then a quick spectator that started 100 ms late catches up.
func slow_spectator() -> void:
	var result := trio_sim(true, 20.0, 120_000, 0)
	var alone := trio_sim(false, 20.0, 120_000, 0)
	var host: LocalNetLockstep = result.runners[0]
	var guest: LocalNetLockstep = result.runners[1]
	var watcher: LocalNetLockstep = result.runners[2]
	check(host.stalled_frames == alone.runners[0].stalled_frames and guest.stalled_frames == alone.runners[1].stalled_frames, "A slow spectator never stalls the players (%d, %d frames; %d, %d without it)" % [host.stalled_frames, guest.stalled_frames, alone.runners[0].stalled_frames, alone.runners[1].stalled_frames])
	check(host.eased_usec == alone.runners[0].eased_usec and guest.eased_usec == alone.runners[1].eased_usec, "...and never eases their schedules (%d, %d us)" % [host.eased_usec, guest.eased_usec])
	check(host.sync._acks[3][0] > 400 and host.sync.timing_peers() == [2], "The host hears the spectator but leaves it out of time sync")
	check(watcher.tick >= result.ticks - 40 and result.histories[2] == result.histories[0].slice(0, result.histories[2].size()), "The spectator follows the same inputs, as far behind as its link needs (tick %d of %d)" % [watcher.tick, result.ticks])
	var late := trio_sim(true, 60.0, 3000, 100_000)
	var off: float = (late.runners[2].schedule_usec - late.runners[0].schedule_usec) / host.tick_usec
	check(late.runners[2].caught_up_usec > 0 and absf(off) < 1.0, "A spectator that started late catches up with the schedule (%.2f ticks off)" % off)
	check(late.runners[2].frames - late.runners[2].stalled_frames > 0 and late.runners[0].eased_usec == 0, "...without anyone easing for it (%d us)" % late.runners[0].eased_usec)


func trio_sim(with_spectator: bool, watcher_fps: float, watcher_latency: int, watcher_late: int, seconds := 8.0) -> Dictionary:
	var links := []
	for i in 3:
		links.append(AddressedLink.new())
	links[0].is_host = true
	var syncs := [
		LocalNetInputSync.new(links[0], 2, 0, {2: 1, 3: -1} if with_spectator else {2: 1}, 6, 1),
		LocalNetInputSync.new(links[1], 2, 1, {1: -1}, 6, 1),
		LocalNetInputSync.new(links[2], 2, -1, {1: -1}, 6, 1),
	]
	var fps := [90.0, 60.0, watcher_fps]
	var latency := [3000, 3000, watcher_latency]
	var histories := [PackedInt64Array(), PackedInt64Array(), PackedInt64Array()]
	var runners := []
	var clock := {"now": 0}
	for i in 3:
		var history: PackedInt64Array = histories[i]
		var runner := LocalNetLockstep.new(syncs[i], watcher_late if i == 2 else 0, 120, func(t): return PackedByteArray([t % 7]), func(_t, inputs): history.append(hash(inputs)))
		runners.append(runner)
		syncs[i].clock = func(): return clock.now
	var next_frame := [0.0, 0.0, 0.0]
	var in_flight := []
	var devices := 3 if with_spectator else 2
	while true:
		var side := 0
		for i in devices:
			if next_frame[i] < next_frame[side]:
				side = i
		if next_frame[side] >= seconds * 1_000_000:
			break
		var now := int(next_frame[side])
		clock.now = now
		next_frame[side] += 1_000_000.0 / fps[side]
		for packet in in_flight.duplicate():
			if packet.to == side and packet.due <= now:
				syncs[side]._on_received(packet.from, packet.channel, packet.bytes)
				in_flight.erase(packet)
		runners[side].advance(now)
		for sent in links[side].outbox:
			var to: int = sent[0] - 1
			if to < devices:
				in_flight.append({"to": to, "from": side + 1, "channel": sent[1], "bytes": sent[2], "due": now + maxi(latency[side], latency[to])})
		links[side].outbox.clear()
	return {"runners": runners, "histories": histories, "ticks": int(seconds * 120)}


# A spectator that stops acknowledging is let go once it's keep_ticks behind, so the
# host can free its inputs.
func spectator_dropped() -> void:
	var host_link := AddressedLink.new()
	host_link.is_host = true
	var host := LocalNetInputSync.new(host_link, 2, 0, {2: 1, 3: -1}, 2, 1)
	var guest := LocalNetInputSync.new(AddressedLink.new(), 2, 1, {1: -1}, 2, 1)
	var watcher := LocalNetInputSync.new(AddressedLink.new(), 2, -1, {1: -1}, 2, 1)
	check(watcher.next_local_tick() == -1 and watcher.is_spectating() and not host.is_spectating(), "A device with no slot has no input of its own to give")
	watcher.add_local_input(0, PackedByteArray([1]))
	check(watcher.latest(0) == 1 and watcher.latest(1) == 1, "...and adding some does nothing")
	var dropped := []
	host.spectator_dropped.connect(func(id): dropped.append(id))
	var runner := LocalNetLockstep.new(host, 0, 120, func(_t): return PackedByteArray([1]), func(_t, _inputs): pass)
	runner.keep_ticks = 120
	runner.time_sync = false
	var tick_usec := 1_000_000.0 / 120
	var deliver_all := func(watching: bool):
		for packet in host_link.outbox:
			if packet[0] == 2:
				guest._on_received(1, packet[1], packet[2])
			elif watching:
				watcher._on_received(1, packet[1], packet[2])
		host_link.outbox.clear()
		for pair in [[guest, 2], [watcher, 3]]:
			if pair[1] == 2 or watching:
				pair[0].flush()
				for packet in pair[0].link.outbox:
					host._on_received(pair[1], packet[1], packet[2])
			pair[0].link.outbox.clear()
	for t in range(0, 400):
		while guest.next_local_tick() <= t + 2:
			guest.add_local_input(guest.next_local_tick(), PackedByteArray([2]))
		runner.advance(int(t * tick_usec) + 1)
		deliver_all.call(t < 50)
	check(dropped == [3], "A spectator that falls keep_ticks behind is dropped, once: %s" % [dropped])
	check(host.is_dropped(3) and host._packet_for(3).is_empty() and not host._packet_for(2).is_empty(), "The host stops sending to it, and carries on with the player")
	check(host._inputs[0].size() < 200 and not host._inputs[0].has(100), "Inputs it never confirmed are freed (%d kept)" % host._inputs[0].size())
	check(runner.tick >= 395 and runner.stalled_frames == 0, "The players never waited for it (tick %d, %d stalled frames)" % [runner.tick, runner.stalled_frames])


const CONTENT_ROOT := "user://localnet-test-content"


# Content in a cache of its own, emptied first.
func content_for(lobby: LocalNetLobby, folder: String) -> LocalNetContent:
	var content := LocalNetContent.new(lobby)
	content.cache_dir = CONTENT_ROOT.path_join(folder)
	DirAccess.make_dir_recursive_absolute(content.cache_dir)
	for file in DirAccess.get_files_at(content.cache_dir):
		DirAccess.remove_absolute(content.cache_dir.path_join(file))
	return content


func blob(size: int) -> PackedByteArray:
	return Crypto.new().generate_random_bytes(size)


func content_basics() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "basics-host")
	var gc := content_for(guest, "basics-guest")
	var everything := pair + [hc, gc]
	var bytes := blob(300_000)
	var item := LocalNetContent.describe("stage", "reef", bytes)
	check(item.type == "stage" and item.id == "reef" and item.size == 300_000 and item.hash.length() == 64, "An item says what it is, its hash and its size")
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	check(item.hash == digest.finish().hex_encode(), "The item's hash is the sha256 of its bytes")
	hc.offer(item, bytes)
	hc.require([item])
	var got := []
	var present := []
	gc.received.connect(func(i, path): got.append([i, path]))
	hc.all_present.connect(func(): present.append("host"))
	gc.all_present.connect(func(): present.append("guest"))
	check(host.can_start() and not host.can_start(false, true), "Required content holds up a start that asks for it, and only that")
	pump(everything, 10.0, func(): return got.size() == 1 and host.can_start(false, true))
	check(got.size() == 1 and got[0][0].hash == item.hash and FileAccess.get_file_as_bytes(got[0][1]) == bytes, "The guest fetches what the match needs, byte for byte")
	check(gc.has(item.hash) and gc.missing().is_empty() and gc.path_for(item.hash) == got[0][1] and not FileAccess.file_exists(got[0][1] + ".part"), "The guest holds it in its cache, with nothing partial left")
	check(guest.needed_content.size() == 1 and host.members[guest.local_id].get("content", {}).get("missing", -1) == 0, "The guest heard what's needed and reports nothing missing")
	check(host.can_start(false, true), "...so the host can start")
	check(present.has("host") and present.has("guest") and present.size() == 2, "Both sides say they hold everything, once each: %s" % [present])
	# Already in the cache: a second lobby needs no transfer.
	var progress := [0]
	gc.progress.connect(func(_h, _b, _t): progress[0] += 1)
	hc.require([])
	hc.require([item])
	pump(everything, 2.0, func(): return host.can_start(false, true))
	check(progress[0] == 0 and host.can_start(false, true), "Content already cached isn't fetched again")
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# Only one guest has the item: the host fetches it from that guest and passes it on.
func content_relay() -> void:
	var host := host_lobby(3)
	var has := join_lobby(host, "Has")
	var needs := join_lobby(host, "Needs")
	var lobbies := [host, has, needs]
	pump(lobbies, 5.0, func(): return host.can_start() and host.members.size() == 3)
	var hc := content_for(host, "relay-host")
	var ac := content_for(has, "relay-has")
	var bc := content_for(needs, "relay-needs")
	var bytes := blob(200_000)
	var source := CONTENT_ROOT.path_join("relay-source.bin")
	var file := FileAccess.open(source, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	var item := LocalNetContent.describe("car", "bakkie", source)
	ac.offer(item, source)
	hc.require([item])
	var got := {}
	hc.received.connect(func(_i, path): got["host"] = path)
	bc.received.connect(func(_i, path): got["needs"] = path)
	pump(lobbies + [hc, ac, bc], 10.0, func(): return got.size() == 2 and host.can_start(false, true))
	check(got.size() == 2 and got.values().all(func(path): return FileAccess.get_file_as_bytes(path) == bytes), "An item only a guest has reaches the other guest through the host")
	check(host.can_start(false, true) and not ac._fetches.has(item.hash), "Everyone holds it, and the guest that had it fetched nothing")
	for c in [hc, ac, bc]:
		c.close()
	for l in lobbies:
		l.leave()


func content_mismatch() -> void:
	var pair := joined_pair()
	var hc := content_for(pair[0], "mismatch-host")
	var gc := content_for(pair[1], "mismatch-guest")
	var bytes := blob(100_000)
	var item := LocalNetContent.describe("stage", "reef", bytes)
	var tampered := bytes.duplicate()
	tampered[5000] ^= 0xFF
	hc.offer(item, tampered)
	hc.require([item])
	var failures := []
	gc.failed.connect(func(i, reason): failures.append([i.hash, reason]))
	pump(pair + [hc, gc], 5.0, func(): return not failures.is_empty())
	check(failures == [[item.hash, "Didn't match its hash"]], "Bytes that don't match their hash are rejected: %s" % [failures])
	check(not gc.has(item.hash) and DirAccess.get_files_at(gc.cache_dir).is_empty(), "...and thrown away")
	pump(pair + [hc, gc], 0.5)
	check(not pair[0].can_start(false, true) and failures.size() == 1, "The start waits, and the guest doesn't keep asking for the bad copy")
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# A transfer survives a dropped connection and a match in between, and a fresh start of
# the app picks up where the last one stopped.
func content_resume() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "resume-host")
	var gc := content_for(guest, "resume-guest")
	hc.budget_bytes = LocalNetContent.CHUNK_BYTES
	var bytes := blob(4 * 1024 * 1024)
	var item := LocalNetContent.describe("track", "long", bytes)
	hc.offer(item, bytes)
	hc.require([item])
	var log := []
	gc.progress.connect(func(_h, b, _t): log.append(b))
	var everything := [host, hc, guest, gc]
	var every := [4000, 4000, 0, 0]
	pump_frames(everything, every, 10.0, func(): return not log.is_empty() and log.back() > item.size / 5)
	var before: int = log.back() if log else 0
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 300)
	pump_frames(everything, every, 4.0, func(): return guest.link.is_peer_connected(LocalNetLink.HOST_ID) and log.back() > before + 4 * LocalNetContent.CHUNK_BYTES)
	var after := log.filter(func(b): return b > before)
	check(before > 0 and not after.is_empty(), "The transfer carries on after a dropped connection")
	var increasing := true
	for i in range(1, log.size()):
		increasing = increasing and log[i] > log[i - 1]
	check(increasing, "...from where it stopped, never starting over")
	# A match pauses it, and returning to the lobby picks it up again.
	host.start()
	pump_frames(everything, every, 1.0, func(): return guest.state == "started")
	pump_frames(everything, every, 0.3)
	var paused: int = log.back()
	pump_frames(everything, every, 0.8)
	check(guest.state == "started" and log.back() == paused and paused < item.size, "Transfers pause while a match is on (%d of %d bytes)" % [paused, item.size])
	host.return_to_lobby()
	pump_frames(everything, every, 2.0, func(): return log.back() > paused + 4 * LocalNetContent.CHUNK_BYTES)
	check(log.back() > paused, "...and carry on back in the lobby")
	# The app is closed mid-transfer; a new session picks up the partial file.
	var stopped: int = log.back()
	gc.close()
	guest.leave()
	check(FileAccess.file_exists(gc.cache_dir.path_join(item.hash + ".part")), "A partial download is kept")
	var again := join_lobby(host, "Again")
	var fresh := LocalNetContent.new(again)
	fresh.cache_dir = gc.cache_dir
	var resumed := []
	var got := []
	fresh.progress.connect(func(_h, b, _t): resumed.append(b))
	fresh.received.connect(func(_i, path): got.append(path))
	pump([host, hc, again, fresh], 20.0, func(): return not got.is_empty())
	check(not resumed.is_empty() and resumed[0] > stopped - 8 * LocalNetContent.CHUNK_BYTES and resumed[0] <= stopped + LocalNetContent.CHUNK_BYTES, "A new session carries on from the partial file (%d, stopped at %d)" % [resumed[0] if resumed else -1, stopped])
	check(got.size() == 1 and FileAccess.get_file_as_bytes(got[0]) == bytes, "...and the result matches byte for byte")
	for c in [hc, fresh]:
		c.close()
	for l in [host, again]:
		l.leave()


func content_limits() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "limits-host")
	var gc := content_for(guest, "limits-guest")
	var everything := pair + [hc, gc]
	var bytes := blob(200_000)
	var big := LocalNetContent.describe("mod", "huge", bytes)
	gc.max_item_bytes = 100_000
	hc.offer(big, bytes)
	hc.require([big])
	var failures := []
	gc.failed.connect(func(i, reason): failures.append(reason))
	var sent := [0]
	var count_content := func(_id, channel, _bytes):
		if channel == LocalNetLink.CHANNEL_CONTENT:
			sent[0] += 1
	host.link.received.connect(count_content)
	pump(everything, 2.0)
	check(failures.size() == 1 and failures[0].begins_with("Too big") and sent[0] == 0, "An item over max_item_bytes is never asked for: %s" % [failures])
	# Chunks nobody asked for, sent over the link and handed in directly, are ignored.
	var stray := blob(10_000)
	var stray_item := LocalNetContent.describe("stage", "stray", stray)
	var chunk := hc._packet(LocalNetContent.KIND_CHUNK, stray_item.hash.hex_decode(), 0)
	chunk.append_array(stray)
	host.link.send(guest.local_id, LocalNetLink.CHANNEL_CONTENT, chunk, true)
	var progressed := [0]
	gc.progress.connect(func(_h, _b, _t): progressed[0] += 1)
	gc._on_received(LocalNetLink.HOST_ID, LocalNetLink.CHANNEL_CONTENT, chunk)
	pump(everything, 1.0)
	check(progressed[0] == 0 and sent[0] == 0 and not gc.has(stray_item.hash) and not FileAccess.file_exists(gc.cache_dir.path_join(stray_item.hash + ".part")), "Chunks nobody asked for are ignored, and not acknowledged")
	# Asking for something the host never offered gets a refusal, not the bytes.
	var refused := [0]
	guest.link.received.connect(func(_id, channel, b):
		if channel == LocalNetLink.CHANNEL_CONTENT and b[0] == LocalNetContent.KIND_NOPE:
			refused[0] += 1)
	hc.offer(stray_item, stray)
	var hidden := LocalNetContent.describe("stage", "hidden", blob(5_000))
	gc._send_want(LocalNetLink.HOST_ID, hidden.hash, 0)
	guest.link.flush()
	pump(everything, 1.0, func(): return refused[0] > 0)
	check(refused[0] == 1 and hc._sends.is_empty(), "Only offered items are served")
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# A large transfer keeps a small window, so lobby messages and checksums still go
# through at once.
func content_flow() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "flow-host")
	var gc := content_for(guest, "flow-guest")
	var bytes := blob(16 * 1024 * 1024)
	var item := LocalNetContent.describe("mod", "big", bytes)
	hc.offer(item, bytes)
	hc.require([item])
	var done := []
	gc.received.connect(func(_i, path): done.append(Time.get_ticks_usec()))
	var config_sent := {}
	var config_late := []
	var event_sent := {}
	var event_late := []
	guest.members_changed.connect(func():
		var n: int = guest.config.get("n", -1)
		if config_sent.has(n):
			config_late.append(Time.get_ticks_usec() - config_sent[n])
			config_sent.erase(n))
	guest.link.received.connect(func(_id, channel, b):
		if channel == LocalNetLink.CHANNEL_EVENTS and b.size() == 9 and event_sent.has(b.decode_u32(1)):
			event_late.append(Time.get_ticks_usec() - event_sent[b.decode_u32(1)]))
	var most_in_flight := [0]
	var began := Time.get_ticks_usec()
	var n := [0]
	var next := [0]
	var each := func():
		for send in hc._sends.values():
			most_in_flight[0] = maxi(most_in_flight[0], send.in_flight.size())
		if Time.get_ticks_usec() >= next[0] and done.is_empty():
			next[0] = Time.get_ticks_usec() + 50_000
			n[0] += 1
			config_sent[n[0]] = Time.get_ticks_usec()
			host.set_config({"n": n[0]})
			var checksum := PackedByteArray([LocalNetInputSync.KIND_CHECKSUM])
			checksum.resize(9)
			checksum.encode_u32(1, n[0])
			event_sent[n[0]] = Time.get_ticks_usec()
			host.link.send(guest.local_id, LocalNetLink.CHANNEL_EVENTS, checksum, true)
			host.link.flush()
		return not done.is_empty()
	pump(pair + [hc, gc], 30.0, each)
	var seconds: float = (done[0] - began) / 1_000_000.0 if done else 0.0
	var worst := func(list: Array) -> float: return list.max() / 1000.0 if list else INF
	print("CONTENT 16 MB over loopback in %.2f s (%.1f MB/s); lobby messages at worst %.1f ms, checksums %.1f ms late" % [seconds, 16.0 / seconds if seconds > 0 else 0.0, worst.call(config_late), worst.call(event_late)])
	check(done.size() == 1 and FileAccess.get_file_as_bytes(gc.path_for(item.hash)) == bytes, "A 16 MB item arrives whole (%.1f s)" % seconds)
	check(most_in_flight[0] <= LocalNetContent.WINDOW, "No more than %d chunks are ever in flight (%d)" % [LocalNetContent.WINDOW, most_in_flight[0]])
	check(config_late.size() >= 3 and worst.call(config_late) < 25.0, "Lobby messages arrive at once during the transfer (%d, at worst %.1f ms)" % [config_late.size(), worst.call(config_late)])
	check(event_late.size() >= 3 and worst.call(event_late) < 25.0, "So do checksums (%d, at worst %.1f ms)" % [event_late.size(), worst.call(event_late)])
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# Chunks in flight to [param id] across all of [param content]'s transfers.
func in_flight_to(content: LocalNetContent, id: int) -> int:
	var total := 0
	for send in content._sends.values():
		if send.id == id:
			total += send.in_flight.size()
	return total


# The host changes what the match needs mid-transfer, both ways round: the fetch that's
# called off frees the sender's window, so the new item still comes through.
func content_require_change() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "change-host")
	var gc := content_for(guest, "change-guest")
	var everything := pair + [hc, gc]
	var old_bytes := blob(4 * 1024 * 1024)
	var old := LocalNetContent.describe("track", "old", old_bytes)
	var new_bytes := blob(100_000)
	var new := LocalNetContent.describe("track", "new", new_bytes)
	hc.offer(old, old_bytes)
	hc.offer(new, new_bytes)
	hc.require([old])
	var log := []
	var got := []
	gc.progress.connect(func(_h, b, _t): log.append(b))
	gc.received.connect(func(i, _path): got.append(i.id))
	pump(everything, 5.0, func(): return not log.is_empty() and log.back() > 256 * 1024)
	var cancels := [0]
	host.link.received.connect(func(_id, channel, b):
		if channel == LocalNetLink.CHANNEL_CONTENT and b[0] == LocalNetContent.KIND_CANCEL:
			cancels[0] += 1)
	hc.require([new])
	var most := [0]
	pump(everything, 5.0, func():
		most[0] = maxi(most[0], in_flight_to(hc, guest.local_id))
		return got.has("new"))
	check(got == ["new"] and cancels[0] >= 1, "A guest gets the new item after the host changes what's needed mid-transfer, calling the old one off: %s" % [got])
	pump(everything, 0.5)
	check(hc._sends.is_empty() and gc._fetches.is_empty() and most[0] <= LocalNetContent.WINDOW, "...the old transfer is called off at both ends, and the window held (%d sends, at most %d in flight)" % [hc._sends.size(), most[0]])
	check(FileAccess.file_exists(gc.cache_dir.path_join(old.hash + ".part")), "...keeping what came of the old item for later")
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()
	# The host fetching from a guest, the other way round.
	pair = joined_pair()
	host = pair[0]
	guest = pair[1]
	hc = content_for(host, "change-host")
	gc = content_for(guest, "change-guest")
	everything = pair + [hc, gc]
	gc.offer(old, old_bytes)
	gc.offer(new, new_bytes)
	hc.require([old])
	log = []
	got = []
	hc.progress.connect(func(_h, b, _t): log.append(b))
	hc.received.connect(func(i, _path): got.append(i.id))
	pump(everything, 5.0, func(): return not log.is_empty() and log.back() > 256 * 1024)
	hc.require([new])
	pump(everything, 5.0, func(): return got.has("new"))
	pump(everything, 0.5)
	check(got == ["new"] and gc._sends.is_empty(), "So does a host fetching from a guest: %s, %d sends left" % [got, gc._sends.size()])
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# What a sender does with WANTs it already has a transfer for, or that ask past the end,
# and what each side does when a transfer goes quiet.
func content_stalls() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "stall-host")
	var gc := content_for(guest, "stall-guest")
	var everything := pair + [hc, gc]
	var bytes := blob(1024 * 1024)
	var item := LocalNetContent.describe("track", "quiet", bytes)
	hc.offer(item, bytes)
	var id := guest.local_id
	var key := "%d:%s" % [id, item.hash]
	# Nobody asked the guest to fetch it, so it ignores the chunks: a cancel that went astray.
	hc._on_want(id, item.hash, 0)
	hc.poll()
	check(in_flight_to(hc, id) == LocalNetContent.WINDOW, "A transfer fills the window (%d)" % in_flight_to(hc, id))
	hc._on_want(id, item.hash, 0)
	hc._on_want(id, item.hash, LocalNetContent.CHUNK_BYTES)
	var send: Dictionary = hc._sends[key]
	check(send.in_flight.size() == LocalNetContent.WINDOW and send.cursor == LocalNetContent.WINDOW * LocalNetContent.CHUNK_BYTES, "Asking again for what's already on its way changes nothing")
	hc._on_want(id, item.hash, LocalNetContent.WINDOW * LocalNetContent.CHUNK_BYTES * 2)
	hc.poll()
	check(send.in_flight.size() == LocalNetContent.WINDOW and send.cursor == LocalNetContent.WINDOW * LocalNetContent.CHUNK_BYTES * 2, "Asking from somewhere else moves on without sending past the window (%d in flight)" % send.in_flight.size())
	hc._on_want(id, item.hash, LocalNetContent.CHUNK_BYTES * 5)
	check(send.cursor == LocalNetContent.CHUNK_BYTES * 5 and send.in_flight.size() == LocalNetContent.WINDOW, "...and so does asking for a chunk that isn't on its way: chunks in flight stay counted")
	pump(everything, 0.5)
	check(hc._sends.has(key) and in_flight_to(hc, id) == LocalNetContent.WINDOW, "Chunks nobody acknowledges keep the window full...")
	send.last_usec -= LocalNetContent.STALL_USEC
	hc.poll()
	check(not hc._sends.has(key), "...until the transfer has been quiet for STALL_USEC, when the sender lets it go")
	var other := LocalNetContent.describe("track", "other", blob(1000))
	hc.offer(other, blob(1000))
	hc._on_want(id, item.hash, item.size)
	hc._on_want(id, item.hash, item.size + 5)
	check(hc._sends.is_empty(), "A WANT from the end or past it starts nothing")
	# The guest's side: a fetch that goes quiet asks again.
	hc.require([item])
	var wants := [0]
	host.link.received.connect(func(_from, channel, b):
		if channel == LocalNetLink.CHANNEL_CONTENT and b[0] == LocalNetContent.KIND_WANT:
			wants[0] += 1)
	pump(everything, 3.0, func(): return gc._fetches.has(item.hash) and gc._fetches[item.hash].state == "fetching" and wants[0] > 0)
	# The host forgets it, as a sender that let it go would; what was in flight lands.
	hc._sends.clear()
	pump(everything, 0.3)
	var asked: int = wants[0]
	gc._fetches[item.hash].last_usec -= LocalNetContent.STALL_USEC
	var got := []
	gc.received.connect(func(_i, path): got.append(path))
	pump(everything, 5.0, func(): return not got.is_empty())
	check(wants[0] > asked and got.size() == 1 and FileAccess.get_file_as_bytes(got[0]) == bytes, "A guest whose fetch goes quiet asks again, and gets it all")
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# A lobby that leaves and opens a new session starts its transfers afresh: ids start at 2
# again, so old ones would go to the wrong member.
func content_new_session() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "session-host")
	var gc := content_for(guest, "session-guest")
	var bytes := blob(4 * 1024 * 1024)
	var item := LocalNetContent.describe("track", "long", bytes)
	hc.offer(item, bytes)
	hc.require([item])
	var log := []
	gc.progress.connect(func(_h, b, _t): log.append(b))
	pump(pair + [hc, gc], 5.0, func(): return not log.is_empty() and log.back() > 256 * 1024)
	check(not hc._sends.is_empty() and not gc._fetches.is_empty(), "Both ends are mid-transfer")
	host.leave()
	guest.leave()
	host.host("Host", 2)
	guest.join("127.0.0.1", host.link.port, "Guest")
	hc.poll()
	gc.poll()
	check(hc._sends.is_empty() and gc._fetches.is_empty(), "A new session starts with no transfers left from the last")
	var stray := [0]
	guest.link.received.connect(func(_id, channel, b):
		if channel == LocalNetLink.CHANNEL_CONTENT and b[0] == LocalNetContent.KIND_CHUNK:
			stray[0] += 1)
	pump(pair + [hc, gc], 3.0, func(): return host.can_start())
	check(host.can_start() and stray[0] == 0, "...and the new guest is sent nothing it didn't ask for (%d chunks)" % stray[0])
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


# The host passes content on, so one member's bad copy mustn't stop it: it asks the next
# member, and only fails once nobody is left, still asking members who join later.
func content_bad_source() -> void:
	var host := host_lobby(3)
	var bad := join_lobby(host, "Bad")
	var good := join_lobby(host, "Good")
	var lobbies := [host, bad, good]
	pump(lobbies, 5.0, func(): return host.can_start() and host.members.size() == 3)
	var hc := content_for(host, "bad-host")
	var bc := content_for(bad, "bad-bad")
	var gc := content_for(good, "bad-good")
	var bytes := blob(100_000)
	var item := LocalNetContent.describe("car", "bakkie", bytes)
	var tampered := bytes.duplicate()
	tampered[10] ^= 0xFF
	bc.offer(item, tampered)
	gc.offer(item, bytes)
	hc.require([item])
	var failures := []
	var got := []
	hc.failed.connect(func(_i, reason): failures.append(reason))
	hc.received.connect(func(_i, path): got.append(path))
	pump(lobbies + [hc, bc, gc], 6.0, func(): return not got.is_empty() and host.can_start(false, true))
	check(got.size() == 1 and FileAccess.get_file_as_bytes(got[0]) == bytes and failures.is_empty(), "A host given a bad copy asks the next member, and says nothing failed: %s" % [failures])
	check(host.can_start(false, true), "...so everyone ends up with the right bytes")
	for c in [hc, bc, gc]:
		c.close()
	for l in lobbies:
		l.leave()
	# Only a bad copy to be had: it fails once, then a member who joins with a good one is asked.
	host = host_lobby(3)
	bad = join_lobby(host, "Bad")
	pump([host, bad], 5.0, func(): return host.can_start())
	hc = content_for(host, "bad-host")
	bc = content_for(bad, "bad-bad")
	bc.offer(item, tampered)
	hc.require([item])
	failures = []
	got = []
	hc.failed.connect(func(_i, reason): failures.append(reason))
	hc.received.connect(func(_i, path): got.append(path))
	pump([host, bad, hc, bc], 3.0)
	check(failures == ["Didn't match its hash"] and not hc.has(item.hash), "With only a bad copy about, the host fails once: %s" % [failures])
	good = join_lobby(host, "Good")
	gc = content_for(good, "bad-good")
	gc.offer(item, bytes)
	pump([host, bad, good, hc, bc, gc], 8.0, func(): return not got.is_empty())
	check(got.size() == 1 and FileAccess.get_file_as_bytes(got[0]) == bytes and failures.size() == 1, "...and fetches it from a member who joins later with a good one, without asking the bad one again")
	for c in [hc, bc, gc]:
		c.close()
	for l in [host, bad, good]:
		l.leave()


# A partial download is hashed a little each frame when it resumes, so a big one never
# holds up a frame.
func content_rehash() -> void:
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "rehash-host")
	var gc := content_for(guest, "rehash-guest")
	var bytes := blob(4 * 1024 * 1024)
	var item := LocalNetContent.describe("track", "long", bytes)
	var done := 3 * 1024 * 1024
	var part := FileAccess.open(gc.cache_dir.path_join(item.hash + ".part"), FileAccess.WRITE)
	part.store_buffer(bytes.slice(0, done))
	part.close()
	gc.hash_budget_bytes = 256 * 1024
	hc.offer(item, bytes)
	hc.require([item])
	pump([host, hc, guest], 2.0, func(): return not guest.needed_content.is_empty())
	gc.poll()
	gc.poll()
	var fetch: Dictionary = gc._fetches.get(item.hash, {})
	check(fetch.get("state") == "hashing" and fetch.get("offset") == 256 * 1024, "Resuming hashes hash_budget_bytes of the partial file a frame (%s, %s)" % [fetch.get("state"), fetch.get("offset")])
	var first := []
	var got := []
	gc.progress.connect(func(_h, b, _t): if first.is_empty(): first.append(b))
	gc.received.connect(func(_i, path): got.append(path))
	pump(pair + [hc, gc], 10.0, func(): return not got.is_empty())
	check(not first.is_empty() and first[0] == done + LocalNetContent.CHUNK_BYTES, "...then carries on from the end of it (%s)" % [first])
	check(got.size() == 1 and FileAccess.get_file_as_bytes(got[0]) == bytes, "...and the result matches byte for byte")
	for c in [hc, gc]:
		c.close()
	for l in pair:
		l.leave()


func content_items() -> void:
	var content := LocalNetContent.new(LocalNetLobby.new(GAME, 1))
	var digits := "0123456789abcdef".repeat(4)
	check(content._valid({"hash": digits, "size": 1}), "A hash is 64 lowercase hex digits")
	var odd := ["+" + digits.right(63), "-" + digits.right(63), digits.to_upper(), digits.left(63), digits + "0", digits.left(63) + "g", "0x" + digits.right(62)]
	check(odd.all(func(h): return not content._valid({"hash": h, "size": 1})), "...and nothing else: no sign, capitals, prefix or other length")
	content.offer({"type": "stage", "id": "odd", "hash": odd[0], "size": 1}, PackedByteArray([1]))
	check(not content.has(odd[0]), "An item with a malformed hash can't be offered")
	content.close()
	# describe() touches nothing shared, so a game can run it on a worker thread.
	var bytes := blob(2 * 1024 * 1024)
	var on_thread := [{}]
	var task := WorkerThreadPool.add_task(func(): on_thread[0] = LocalNetContent.describe("mod", "big", bytes))
	WorkerThreadPool.wait_for_task_completion(task)
	check(on_thread[0] == LocalNetContent.describe("mod", "big", bytes), "describe() gives the same item on a worker thread")


func spectated_lobby(players := 2) -> LocalNetLobby:
	var host := LocalNetLobby.new(GAME, 1)
	host.max_spectators = 1
	host.wait_for_loading = true
	check(host.host("Host", players) == OK, "Host opens a lobby")
	return host


# A spectator that drops while it's the last one loading doesn't hold up the start, and
# one that dropped before its clock was synced doesn't block can_start().
func spectator_drops_loading() -> void:
	var host := spectated_lobby()
	var guest := join_lobby(host, "Guest")
	var watcher := join_as(host, "Watcher", "spectator")
	var everyone := [host, guest, watcher]
	pump(everyone, 6.0, func(): return host.can_start() and host.members.size() == 3)
	guest.preparing.connect(func(_c): guest.mark_loaded())
	var starts := []
	host.started.connect(func(_c, _at): starts.append("host"))
	watcher.started.connect(func(_c, _at): starts.append("watcher"))
	host.start()
	host.mark_loaded()
	pump(everyone, 2.0, func(): return host.members[guest.local_id].loaded)
	check(host.state == "preparing" and not host.members[watcher.local_id].loaded, "The spectator is the last one loading")
	watcher.link.debug_drop_connection(LocalNetLink.HOST_ID, 1500)
	pump(everyone, 1.0, func(): return host.state == "started")
	check(host.state == "started" and not host.members[watcher.local_id].connected, "Its connection dropping lets the match start without it")
	pump(everyone, 5.0, func(): return watcher.link.is_peer_connected(LocalNetLink.HOST_ID) and host.members[watcher.local_id].connected)
	pump(everyone, 0.3)
	check(not starts.has("watcher") and watcher.state == "preparing", "Back while the match runs, it hasn't loaded, so it doesn't start yet")
	watcher.mark_loaded()
	check(starts.has("watcher"), "...and joins the match once it has loaded")
	for l in everyone:
		l.leave()
	# Decision 10: a spectator still syncing its clock never blocks the start, connected
	# or not; a player whose connection drops still does.
	host = spectated_lobby()
	guest = join_lobby(host, "Guest")
	pump([host, guest], 5.0, func(): return host.can_start())
	watcher = join_as(host, "Watcher", "spectator")
	pump([host, guest, watcher], 3.0, func(): return host.members.size() == 3)
	var w := watcher.local_id
	check(host.members.has(w) and not host.members[w].synced and host.can_start(), "A spectator still syncing its clock doesn't hold up the start")
	watcher.link.debug_drop_connection(LocalNetLink.HOST_ID, 2500)
	pump([host, guest, watcher], 0.5)
	check(not host.members[w].connected and host.can_start(), "...nor once its connection has dropped")
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 2500)
	pump([host, guest, watcher], 0.5)
	check(not host.can_start(), "A player whose connection drops is still waited for")
	for l in [host, guest, watcher]:
		l.leave()


# A player that calls mark_loaded() while its connection is down tells the host again once
# it's back, so the start doesn't wait on a "loaded" that never arrived.
func loaded_while_dropped() -> void:
	var host := host_lobby()
	host.wait_for_loading = true
	var guest := join_lobby(host, "Guest")
	pump([host, guest], 6.0, func(): return host.can_start())
	host.start()
	host.mark_loaded()
	pump([host, guest], 2.0, func(): return guest.state == "preparing")
	guest.link.debug_drop_connection(LocalNetLink.HOST_ID, 800)
	guest.mark_loaded()
	pump([host, guest], 0.3)
	check(host.state == "preparing" and not host.members[guest.local_id].loaded, "A player's loaded message sent while its connection is down doesn't arrive")
	pump([host, guest], 6.0, func(): return host.state == "started" and guest.state == "started")
	check(host.state == "started" and guest.state == "started", "...but it's sent again on resume, and the match starts")
	for l in [host, guest]:
		l.leave()


# A spectator's content never holds up can_start(false, true), even with wait_for_loading:
# one still downloading just doesn't load in time, and the start goes ahead once
# spectator_load_wait_msec has passed (transfers pause during a match).
func spectator_content_loading() -> void:
	var host := spectated_lobby()
	host.spectator_load_wait_msec = 1000
	var guest := join_lobby(host, "Guest")
	var watcher := join_as(host, "Watcher", "spectator")
	pump([host, guest, watcher], 6.0, func(): return host.can_start() and host.members.size() == 3)
	var hc := content_for(host, "loading-host")
	var gc := content_for(guest, "loading-guest")
	var wc := content_for(watcher, "loading-watcher")
	hc.budget_bytes = LocalNetContent.CHUNK_BYTES
	var bytes := blob(2 * 1024 * 1024)
	var item := LocalNetContent.describe("track", "t", bytes)
	hc.offer(item, bytes)
	hc.require([item])
	guest.preparing.connect(func(_c): guest.mark_loaded())
	watcher.preparing.connect(func(_c): if wc.missing().is_empty(): watcher.mark_loaded())
	var things := [host, hc, guest, gc, watcher, wc]
	var every := [4000, 4000, 4000, 4000, 60_000, 60_000]
	var w := watcher.local_id
	var watcher_missing := func(): return host.members[w].get("content", {}).get("missing", 1) != 0
	pump_frames(things, every, 10.0, func(): return host.can_start(false, true))
	check(watcher_missing.call() and host.can_start(false, true), "With wait_for_loading, a spectator still fetching doesn't hold up can_start(false, true)")
	host.start()
	host.mark_loaded()
	var began := Time.get_ticks_msec()
	pump_frames(things, every, 4.0, func(): return host.state == "started")
	var waited := Time.get_ticks_msec() - began
	check(host.state == "started" and waited >= 900 and waited < 1600, "The start waits spectator_load_wait_msec for it, and no longer (%d ms)" % waited)
	pump_frames(things, every, 1.0)
	check(watcher.state == "preparing" and watcher_missing.call(), "...while it, still without the content, waits to load")
	for c in [hc, gc, wc]:
		c.close()
	for l in [host, guest, watcher]:
		l.leave()


# Channels 4 and 5 are the game's own, and LocalNet's pings only answer to themselves.
func game_channels() -> void:
	check(LocalNetLink.CHANNEL_GAME_RELIABLE == 4 and LocalNetLink.CHANNEL_GAME_REALTIME == 5 and LocalNetLink.CHANNEL_COUNT == 6, "Two channels are kept for games")
	var pair := joined_pair()
	var host: LocalNetLobby = pair[0]
	var guest: LocalNetLobby = pair[1]
	var hc := content_for(host, "channels-host")
	var bytes := blob(50_000)
	var item := LocalNetContent.describe("stage", "reef", bytes)
	hc.offer(item, bytes)
	const MARK := 123_456_789
	var heard := []
	var marked := [0]
	host.link.received.connect(func(_id, channel, b):
		if channel >= LocalNetLink.CHANNEL_GAME_RELIABLE:
			heard.append([channel, b.size()]))
	guest.link.received.connect(func(_id, channel, b):
		if channel >= LocalNetLink.CHANNEL_GAME_RELIABLE:
			heard.append([channel, b.size()])
		elif channel == LocalNetLink.CHANNEL_REALTIME and b.size() == 21 and b[0] == LocalNetLobby.KIND_PONG and b.decode_s64(1) == MARK:
			marked[0] += 1)
	var ping := PackedByteArray([LocalNetLobby.KIND_PING])
	ping.resize(9)
	ping.encode_s64(1, MARK)
	var want := hc._packet(LocalNetContent.KIND_WANT, item.hash.hex_decode(), 0)
	for channel in [LocalNetLink.CHANNEL_GAME_RELIABLE, LocalNetLink.CHANNEL_GAME_REALTIME]:
		guest.link.send(1, channel, ping, channel == LocalNetLink.CHANNEL_GAME_RELIABLE)
		guest.link.send(1, channel, want, channel == LocalNetLink.CHANNEL_GAME_RELIABLE)
		host.link.send(guest.local_id, channel, ping, channel == LocalNetLink.CHANNEL_GAME_RELIABLE)
	var longer := ping.duplicate()
	longer.append(0)
	guest.link.send(1, LocalNetLink.CHANNEL_REALTIME, longer, false)
	guest.link.flush()
	host.link.flush()
	pump(pair + [hc], 1.0, func(): return heard.size() == 6)
	check(heard.size() == 6, "Game packets on channels 4 and 5 go both ways: %s" % [heard])
	check(marked[0] == 0 and hc._sends.is_empty(), "LocalNet reads nothing on them, and a ping with a byte too many isn't one")
	guest.link.send(1, LocalNetLink.CHANNEL_REALTIME, ping, false)
	guest.link.flush()
	pump(pair + [hc], 1.0, func(): return marked[0] > 0)
	check(marked[0] == 1, "...while a real ping is answered")
	# A guest only takes pongs of the right size, from the host.
	var pong := PackedByteArray([LocalNetLobby.KIND_PONG])
	pong.resize(21)
	pong.encode_s64(9, Time.get_ticks_usec())
	var fake := func(from: int, channel: int, size: int) -> bool:
		guest._samples.clear()
		var packet := pong.duplicate()
		packet.encode_s64(1, Time.get_ticks_usec() - 1)
		packet.resize(size)
		guest._on_received(from, channel, packet)
		return not guest._samples.is_empty()
	check(not fake.call(1, LocalNetLink.CHANNEL_REALTIME, 17) and not fake.call(1, LocalNetLink.CHANNEL_REALTIME, 22) and not fake.call(3, LocalNetLink.CHANNEL_REALTIME, 21) and not fake.call(1, LocalNetLink.CHANNEL_GAME_REALTIME, 21), "A guest ignores pongs of the wrong size, from others or on game channels")
	check(fake.call(1, LocalNetLink.CHANNEL_REALTIME, 21), "...and takes a real one")
	hc.close()
	for l in pair:
		l.leave()


# A dropped spectator hears about it, even when it was away at the time and came back.
func spectator_told_dropped() -> void:
	var host_link := AddressedLink.new()
	host_link.is_host = true
	var host := LocalNetInputSync.new(host_link, 2, 0, {2: 1, 3: -1}, 2, 1)
	var guest := LocalNetInputSync.new(AddressedLink.new(), 2, 1, {1: -1}, 2, 1)
	var watcher := LocalNetInputSync.new(AddressedLink.new(), 2, -1, {1: -1}, 2, 1)
	var told := []
	watcher.dropped.connect(func(): told.append("watcher"))
	guest.dropped.connect(func(): told.append("guest"))
	for t in range(2, 300):
		host.add_local_input(t, PackedByteArray([1]))
		guest.add_local_input(t, PackedByteArray([2]))
		if t % 10 == 0:
			host.flush()
			guest.flush()
			for packet in host_link.outbox:
				if packet[0] == 2:
					guest._on_received(1, packet[1], packet[2])
			for packet in guest.link.outbox:
				host._on_received(2, packet[1], packet[2])
			host_link.outbox.clear()
			guest.link.outbox.clear()
	var markers := func() -> Array:
		return host_link.outbox.filter(func(p): return p[1] == LocalNetLink.CHANNEL_EVENTS and p[2] == PackedByteArray([LocalNetInputSync.KIND_DROPPED]))
	host.discard_before(250)
	host.discard_before(260)
	check(host.is_dropped(3) and markers.call().size() == 1 and markers.call()[0][0] == 3, "The host tells a spectator it drops, once")
	# It was away, so that was lost; it comes back within the window.
	host_link.outbox.clear()
	host_link.peer_resumed.emit(2)
	check(markers.call().is_empty(), "...not players who reconnect")
	host_link.peer_resumed.emit(3)
	check(markers.call().size() == 1 and markers.call()[0][0] == 3, "...and again when the spectator reconnects")
	for packet in markers.call() + markers.call():
		watcher._on_received(1, packet[1], packet[2])
		guest._on_received(1, packet[1], packet[2])
	check(told == ["watcher"], "The spectator's own input sync says it was dropped, once, and a player's ignores it: %s" % [told])
	for s in [host, guest, watcher]:
		s.close()


# Sends [param hello] to [param host] over a bare link; returns "welcome" or the reason
# it was turned away, and the link (still open after a welcome).
func say_hello(host: LocalNetLobby, hello: Dictionary) -> Array:
	var bare := LocalNetLink.new()
	bare.join("127.0.0.1", host.link.port)
	var answer := [""]
	bare.peer_connected.connect(func(id):
		bare.send(id, LocalNetLink.CHANNEL_CONTROL, var_to_bytes(hello), true)
		bare.flush())
	bare.received.connect(func(_id, _channel, bytes):
		var message = bytes_to_var(bytes)
		if message is Dictionary and message.get("t") == "reject":
			answer[0] = message.reason
		elif message is Dictionary and message.get("t") == "welcome":
			answer[0] = "welcome")
	pump([host, bare], 3.0, func(): return answer[0] != "")
	return [answer[0], bare]


# Peers connect when their ranges of LocalNet versions overlap.
func wire_range() -> void:
	check(LocalNetLobby.WIRE_VERSION == 3 and LocalNetLobby.WIRE_VERSION_MIN == 3, "LocalNet 0.3 speaks wire version 3, back to 3")
	var host := host_lobby(4)
	var hello := {"t": "hello", "game": GAME, "v": 1, "name": "Next"}
	var cases := [
		[{"ln": 4, "ln_min": 3}, "welcome", "a newer guest that still works with 3"],
		[{"ln": 5, "ln_min": 4}, "Different LocalNet version", "a newer guest that no longer works with 3"],
		[{"ln": 2, "ln_min": 2}, "Different LocalNet version", "an older guest"],
		[{"ln": 4}, "Different LocalNet version", "a newer guest that doesn't say how far back it goes"],
		[{"ln": "3", "ln_min": 3}, "Different LocalNet version", "a version that isn't a number"],
	]
	var open := []
	for case in cases:
		var message := hello.duplicate()
		message.merge(case[0])
		var answer := say_hello(host, message)
		check(answer[0] == case[1], "The host answers %s: %s" % [case[2], answer[0]])
		if answer[0] == "welcome":
			open.append(answer[1])
		else:
			answer[1].close()
	var newer: Array = host.members.values().filter(func(m): return m.name == "Next")
	check(newer.size() == 1 and newer[0].ln == 4, "A member's LocalNet version is kept in its member dictionary")
	var guest := join_lobby(host, "Guest")
	pump([host, guest] + open, 3.0, func(): return guest.members.size() == 3)
	check(host.members.get(guest.local_id, {}).get("ln") == 3 and guest.members.get(1, {}).get("ln") == 3, "Every member has one, the host included, and everyone sees them")
	for link in open:
		link.close()
	guest.leave()
	host.leave()


# Decision 10: the start waits for spectators' loading only spectator_load_wait_msec after
# the players have loaded, and not at all with 0; one that loads in time starts it at once.
func spectator_load_wait() -> void:
	check(LocalNetLobby.new(GAME, 1).spectator_load_wait_msec == 3000, "Spectators' loading is waited for 3 s by default")
	# [wait msec, when the spectator loads (msec after the players, -1 never), expected start]
	for case in [[1000, -1, "after the wait"], [0, -1, "at once"], [3000, 300, "when it loads"]]:
		var host := spectated_lobby()
		host.spectator_load_wait_msec = case[0]
		var guest := join_lobby(host, "Guest")
		var watcher := join_as(host, "Watcher", "spectator")
		var everyone := [host, guest, watcher]
		pump(everyone, 6.0, func(): return host.can_start() and host.members.size() == 3)
		guest.preparing.connect(func(_c): guest.mark_loaded())
		var starts := {}
		host.started.connect(func(_c, at): starts["host"] = at)
		watcher.started.connect(func(_c, at): starts["watcher"] = at)
		host.start()
		host.mark_loaded()
		pump(everyone, 2.0, func(): return host.members[guest.local_id].loaded)
		var players_loaded := Time.get_ticks_msec()
		var loaded := [false]
		pump(everyone, 5.0, func():
			if case[1] >= 0 and not loaded[0] and Time.get_ticks_msec() - players_loaded >= case[1]:
				loaded[0] = true
				watcher.mark_loaded()
			return host.state == "started")
		var waited := Time.get_ticks_msec() - players_loaded
		var expected: int = case[1] if case[1] >= 0 else case[0]
		check(host.state == "started" and waited >= expected - 50 and waited < expected + 300, "Waiting %d ms for spectators, the start comes %s (%d ms)" % [case[0], case[2], waited])
		if case[1] < 0:
			pump(everyone, 0.5)
			check(watcher.state == "preparing" and not starts.has("watcher"), "...a spectator still loading doesn't start yet")
			watcher.mark_loaded()
		pump(everyone, 1.0, func(): return starts.has("watcher"))
		check(starts.has("watcher") and absi(starts.watcher - starts.get("host", 0)) < 5000, "...and once loaded it starts on the match's own clock")
		for l in everyone:
			l.leave()


# A spectator that loads after the match has begun joins on the shared clock and catches
# up, or is dropped once keep_ticks behind; either way the players never stall.
func late_spectator(late_msec: int, label: String) -> Dictionary:
	var host := spectated_lobby()
	host.spectator_load_wait_msec = 100
	var guest := join_lobby(host, "Guest")
	var watcher := join_as(host, "Watcher", "spectator")
	var lobbies := [host, guest, watcher]
	pump(lobbies, 6.0, func(): return host.can_start() and host.members.size() == 3)
	guest.preparing.connect(func(_c): guest.mark_loaded())
	var runners := {}
	var told := []
	var dropped := []
	var ticks := 480
	for lobby in lobbies:
		lobby.started.connect(func(_config, at):
			var sync := LocalNetInputSync.new(lobby.link, 2, lobby.local_slot(), lobby.peer_slots(), 3, 2)
			sync.dropped.connect(func(): told.append(lobby.local_id))
			sync.spectator_dropped.connect(func(id): dropped.append(id))
			var rng := RandomNumberGenerator.new()
			rng.seed = lobby.local_slot() + 11
			var history := PackedInt64Array()
			var runner := LocalNetLockstep.new(sync, at, 120,
				func(_t): return PackedByteArray([rng.randi() % 256, rng.randi() % 256]),
				func(_t, inputs): history.append(hash(inputs)))
			runners[lobby] = {"runner": runner, "history": history, "at": at})
	host.start()
	host.mark_loaded()
	var since := [0]
	var step := func():
		if since[0] == 0 and runners.has(host):
			since[0] = Time.get_ticks_msec()
		if since[0] > 0 and watcher.state == "preparing" and Time.get_ticks_msec() - since[0] >= late_msec:
			watcher.mark_loaded()
		for lobby in runners:
			var r: Dictionary = runners[lobby]
			if r.runner.tick < ticks and not told.has(lobby.local_id):
				r.runner.max_ticks_per_frame = mini(8, ticks - r.runner.tick)
				r.runner.advance()
			else:
				r.runner.sync.flush()
		return runners.size() == 3 and runners.keys().all(func(l): return runners[l].runner.tick >= ticks or told.has(l.local_id))
	var finished := pump(lobbies, 25.0, step)
	pump(lobbies, 0.3)
	var players: Array = [runners.get(host, {}), runners.get(guest, {})]
	var spectator: Dictionary = runners.get(watcher, {})
	check(finished and players.all(func(r): return not r.is_empty() and r.runner.tick >= ticks), "%s: the players finish the match" % label)
	check(players.all(func(r): return not r.is_empty() and r.runner.stalled_frames == 0), "%s: the players never stall (%s frames)" % [label, players.map(func(r): return r.runner.stalled_frames if r else -1)])
	check(not spectator.is_empty() and absi(spectator.at - players[0].get("at", 0)) < 5000, "%s: the spectator starts on the match's own clock" % label)
	var result := {"spectator": spectator, "players": players, "told": told, "dropped": dropped, "id": watcher.local_id}
	for r in runners.values():
		r.runner.sync.close()
	for l in lobbies:
		l.leave()
	return result


func late_spectators() -> void:
	var late := late_spectator(1300, "Spectator loading 1.3 s late")
	var spectator: Dictionary = late.spectator
	if not spectator.is_empty():
		check(spectator.runner.tick >= 480 and spectator.history == late.players[0].history, "Spectator loading 1.3 s late: it catches up and follows the whole match (tick %d)" % spectator.runner.tick)
		check(late.told.is_empty() and late.dropped.is_empty(), "...without being dropped")
	var later := late_spectator(4500, "Spectator loading 4.5 s late")
	check(later.dropped == [later.id] and later.told == [later.id], "Spectator loading 4.5 s late: beyond keep_ticks, it's dropped and told so: %s, %s" % [later.dropped, later.told])


# merge_config sets some keys and keeps the rest, and tells members only when something
# changed; set_config still replaces the lot.
func config_merges() -> void:
	var host := host_lobby()
	var guest := join_lobby(host, "Guest")
	pump([host, guest], 3.0, func(): return guest.members.size() == 2)
	var sent := [0]
	host.members_changed.connect(func(): sent[0] += 1)
	host.set_config({"stage": 3, "rounds": 2})
	var car := {"colour": 1}
	host.merge_config({"rounds": 5, "weather": "rain", "car": car})
	check(sent[0] == 2 and host.config == {"stage": 3, "rounds": 5, "weather": "rain", "car": {"colour": 1}}, "Merging config keeps the other keys, and goes out once (%s, %d)" % [host.config, sent[0]])
	car.colour = 2
	check(host.config.car.colour == 1, "...and keeps its own copy of what it was given")
	pump([host, guest], 2.0, func(): return guest.config.get("weather") == "rain")
	check(guest.config == {"stage": 3, "rounds": 5, "weather": "rain", "car": {"colour": 1}}, "The guest sees the merged config (%s)" % [guest.config])
	sent[0] = 0
	host.merge_config({"stage": 3, "car": {"colour": 1}})
	host.merge_config({})
	check(sent[0] == 0, "Merging what's already there sends nothing")
	host.merge_config({"rounds": 5.0})
	check(sent[0] == 1, "A value that changes type is a change")
	pump([host, guest], 2.0, func(): return typeof(guest.config.get("rounds")) == TYPE_FLOAT)
	check(typeof(guest.config.get("rounds")) == TYPE_FLOAT, "...and the guest gets it")
	guest.merge_config({"stage": 9})
	guest.set_config({"stage": 9})
	pump([host, guest], 0.3)
	check(host.config.stage == 3 and guest.config.stage == 3, "Only the host merges config")
	host.set_config({"stage": 4})
	pump([host, guest], 2.0, func(): return guest.config.get("stage") == 4)
	check(host.config == {"stage": 4} and guest.config == {"stage": 4}, "set_config still replaces the whole config")
	guest.leave()
	host.leave()


# One player can start with a spectator, such as a driver with a navigator, once
# min_players allows it. By default it takes two.
func min_players() -> void:
	var host := LocalNetLobby.new(GAME, 1)
	host.max_spectators = 1
	check(host.min_players == 2, "min_players defaults to 2")
	host.host("Driver", 1)
	var navigator := join_as(host, "Navigator", "spectator")
	pump([host, navigator], 4.0, func(): return host.members.get(navigator.local_id, {}).get("synced", false))
	check(host.members.size() == 2 and not host.can_start(), "By default a player and a spectator can't start")
	host.min_players = 1
	check(host.can_start(), "With min_players 1 they can")
	var runners := lockstep_match([host, navigator], 0.0, 0.0, 0.0, "Driver and navigator")
	if runners.size() == 2:
		check(runners[1].sync.is_spectating() and runners[1].tick >= 480, "Driver and navigator: the navigator follows the whole match")
	var screen := LocalNetLobby.new(GAME, 1)
	screen.min_players = 0
	screen.host("Screen", 2, "", 0, false)
	check(screen.players().is_empty() and not screen.can_start(), "Even with min_players 0, a start needs a player")
	screen.leave()


# A member is gone from members by the time member_left fires, but is_spectator() still
# knows its role there, for the rest of the session.
func left_roles() -> void:
	var host := LocalNetLobby.new(GAME, 1)
	host.max_spectators = 1
	host.host("Host", 2)
	var player := join_lobby(host, "Player")
	var watcher := join_as(host, "Watcher", "spectator")
	var everyone := [host, player, watcher]
	pump(everyone, 3.0, func(): return host.members.size() == 3)
	var seen := {}
	host.member_left.connect(func(id, _reason): seen[id] = [host.members.has(id), host.is_spectator(id)])
	var p := player.local_id
	var w := watcher.local_id
	watcher.leave()
	player.leave()
	pump([host], 3.0, func(): return seen.size() == 2)
	check(seen.get(w) == [false, true] and seen.get(p) == [false, false], "In member_left, a member that left is gone, and is_spectator() still knows its role (%s)" % [seen])
	check(host.is_spectator(w) and not host.is_spectator(p), "...afterwards too")
	host.leave()
	host.host("Host", 2)
	check(not host.is_spectator(w), "A new session forgets who left the last one")
	host.leave()
