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
	desync()
	departures()
	stats()
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
	pump([quick, guest], 4.0, func(): return quick.can_start())
	pump([quick, guest], 2.5)
	check(quick.suggested_delay() == 2 and guest.suggested_delay() == 2, "A quick link gets the minimum delay (%d, %d)" % [quick.suggested_delay(), guest.suggested_delay()])
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


# Two runners on their own frame rates, packets taking [param latency] to arrive and the
# host's packets held back for [param blackout] after one second, as in a Wi-Fi hiccup.
# Returns how many ticks the guest's schedule ended up behind the host's (the host's lead).
func pair_sim(enabled: bool, host_fps: float, guest_fps: float, latency: int, blackout: int, seconds: float) -> Dictionary:
	var pair := memory_pair(3)
	var runners := []
	for side in 2:
		var runner := LocalNetLockstep.new(pair[side], 0, 120, func(_t): return PackedByteArray([1]), func(_t, _inputs): pass)
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
	while minf(next_frame[0], next_frame[1]) < seconds * 1_000_000:
		var side := 0 if next_frame[0] <= next_frame[1] else 1
		var now := int(next_frame[side])
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
	return {"drift": (runners[1].schedule_usec - runners[0].schedule_usec) / runners[0].tick_usec, "stalls": runners.all(func(r): return r.stalled_frames > 0), "eased": runners[0].eased_usec + runners[1].eased_usec, "most_eased": most_eased}


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
	check(host.suggested_delay() == 12, "A very slow link is capped at 12 ticks (%d)" % host.suggested_delay())
	check(host.suggested_delay(120, 12.0, 2, 20) > 12 and host.suggested_delay(60) < host.suggested_delay(120), "The cap and tick rate can be changed")
	guest.leave()
	host.leave()


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
	host.member_left.connect(func(id): left.append(id))
	client.leave()
	pump([host], 3.0, func(): return not left.is_empty())
	check(left.size() == 1 and host.members.size() == 1, "Host notices a guest leaving")
	var again := join_lobby(host, "Again")
	pump([host, again], 3.0, func(): return host.members.size() == 2)
	var reason := [""]
	again.closed.connect(func(r): reason[0] = r)
	host.leave()
	pump([again], 3.0, func(): return reason[0] != "")
	check(reason[0] == "The host left", "Guest notices the host leaving")
	again.leave()


func stats() -> void:
	var s := LocalNetLatencyStats.new(120)
	for lateness in [1000, 2000, 3000, 9000, 30000]:
		s.add(lateness)
	check(is_equal_approx(s.percentile_msec(50), 3.0), "Median lateness is 3 ms")
	check(is_equal_approx(s.stall_share(0), 1.0), "With no delay every input is late")
	check(is_equal_approx(s.stall_share(1), 0.4), "One tick (8.3 ms) hides three of five")
	check(s.delay_for(0.0) == 4, "Four ticks hide everything")
