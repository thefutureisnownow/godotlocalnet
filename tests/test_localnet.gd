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
	lockstep(2, 0.0, 0.0, 0.0, "clean")
	lockstep(2, 0.25, 12.0, 10.0, "lossy")
	lockstep(3, 0.15, 5.0, 5.0, "relayed")
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


# Every player free-runs lockstep; afterwards every device must have seen the same inputs.
func lockstep(players: int, drop: float, latency: float, jitter: float, label: String) -> void:
	var host := host_lobby(players)
	var lobbies: Array[LocalNetLobby] = [host]
	for i in range(1, players):
		lobbies.append(join_lobby(host, "Guest %d" % i))
	pump(lobbies, 5.0, func(): return host.can_start() and lobbies.all(func(l): return l.members.size() == players))
	check(host.can_start(), "%s: everyone joins" % label)
	host.start()
	pump(lobbies, 2.0, func(): return lobbies.all(func(l): return l.state == "started"))
	for lobby in lobbies:
		lobby.link.debug_drop = drop
		lobby.link.debug_latency_msec = latency
		lobby.link.debug_jitter_msec = jitter
	var ticks := 480
	var runners := []
	var desyncs := []
	for lobby in lobbies:
		var sync := LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), 3, 2)
		sync.desynced.connect(func(t, id): desyncs.append(t))
		var rng := RandomNumberGenerator.new()
		rng.seed = lobby.local_slot() + 11
		runners.append({"sync": sync, "tick": 0, "history": PackedInt64Array(), "rng": rng})
	var step := func():
		for runner in runners:
			var sync: LocalNetInputSync = runner.sync
			while sync.next_local_tick() <= runner.tick + sync.delay:
				sync.add_local_input(sync.next_local_tick(), PackedByteArray([runner.rng.randi() % 256, runner.rng.randi() % 256]))
			while runner.tick < ticks and sync.is_ready(runner.tick):
				runner.history.append(hash(sync.inputs(runner.tick)))
				runner.tick += 1
				if runner.tick % 60 == 0:
					sync.report_checksum(runner.tick, runner.history[-1])
					sync.discard_before(runner.tick - 120)
			sync.flush()
		return runners.all(func(r): return r.tick >= ticks)
	var finished := pump(lobbies, 20.0, step)
	pump(lobbies, 0.3)
	check(finished, "%s: all %d players reach tick %d" % [label, players, ticks])
	var same := runners.all(func(r): return r.history == runners[0].history)
	check(same, "%s: every device saw identical inputs" % label)
	check(desyncs.is_empty(), "%s: checksums agree" % label)
	for runner in runners:
		runner.sync.close()
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
