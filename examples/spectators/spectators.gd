extends Control
## Two players, and anyone else on the network can join to watch. Spectators have no
## slot, send no input and never hold the players up; one that falls too far behind is
## dropped from the match and watches the next one.
##
## See player_vs_player for the basics; the comments here are about spectators.

const Dots := preload("res://examples/shared/dots.gd")
const Menu := preload("res://examples/shared/menu.gd")

const GAME := "localnet-example-spectators"
const VERSION := 1
const TICK_RATE := 60

var scan_targets := PackedStringArray()
var player_name := "Player %d" % (randi() % 100)
var discovery := LocalNetDiscovery.new(GAME, VERSION)
var lobby: LocalNetLobby
var lockstep: LocalNetLockstep
var dots := Dots.new()
var menu := Menu.new()
var _listed := []
var _start_button: Button


func _ready() -> void:
	menu.lay_out(self, dots)
	show_home()


func _process(_delta: float) -> void:
	discovery.poll()
	if lobby:
		lobby.poll()
	if lobby and lobby.is_host and discovery.advertised_port:
		discovery.update_info(lobby.advert())
	if lobby and _start_button:
		# Spectators don't count towards the two players can_start() needs, and it never
		# waits for them.
		_start_button.disabled = not lobby.can_start()
	if lockstep:
		lockstep.advance()
	elif lobby == null:
		_list_sessions()


func _exit_tree() -> void:
	leave()


func show_home(message := "") -> void:
	menu.say(message if message else "%s: host, play or watch." % player_name)
	_listed = [null]
	LocalNetWifiRoute.bind()
	discovery.scan(scan_targets)


# Sessions count players and spectators apart, so each can be offered separately.
func _list_sessions() -> void:
	var found := discovery.sessions().filter(func(s): return s.compatible and s.state == "lobby")
	var listing := found.map(func(s): return [s.id, s.players, s.spectators])
	if listing == _listed:
		return
	_listed = listing
	menu.clear()
	menu.button("Host", host_game)
	for session in found:
		if session.players < session.max_players:
			menu.button("Play with " + session.name, join_game.bind(session, LocalNetLobby.PLAYER))
		if session.spectators < session.max_spectators:
			menu.button("Watch " + session.name, join_game.bind(session, LocalNetLobby.SPECTATOR))


func host_game() -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.max_spectators = 4  # 0 (the default) turns spectators away. Set it before host().
	if lobby.host(player_name, 2) != OK:
		_back_home("Couldn't open a lobby.")
		return
	discovery.advertise(lobby.advert())
	show_lobby()


func join_game(session: Dictionary, role: String) -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.join(session.address, session.port, player_name, "", role)
	menu.say("Joining %s..." % session.name)
	menu.clear()


func _new_lobby() -> LocalNetLobby:
	var l := LocalNetLobby.new(GAME, VERSION)
	l.joined.connect(func(_id): show_lobby())
	l.members_changed.connect(_on_members_changed)
	l.rejected.connect(func(reason): _back_home("Turned away: " + reason))
	l.closed.connect(_back_home)
	l.started.connect(begin_match)
	l.returned.connect(_on_returned)
	l.member_left.connect(_on_member_left)
	return l


func show_lobby() -> void:
	menu.clear()
	_show_status()
	if lobby.is_host:
		_start_button = menu.button("Start", start_match)
	menu.button("Leave", _back_home.bind(""))


func _on_members_changed() -> void:
	if lobby and lobby.state == "lobby":
		_show_status()


func _show_status() -> void:
	var names := func(ids: Array) -> String:
		return ", ".join(ids.map(func(id): return lobby.members[id].name)) if ids else "nobody"
	var me := "You're watching. " if lobby.is_spectator() else ""
	menu.say("%sPlaying: %s. Watching: %s." % [me, names.call(lobby.players()), names.call(lobby.spectators())])


func start_match() -> void:
	lobby.set_config({"delay": lobby.suggested_delay(TICK_RATE)})  # Spectators' links don't count.
	lobby.start()


# Players and spectators run the same code. A spectator's local_slot() is -1, so it never
# samples input; it follows the inputs the host relays, a few ticks behind the players.
func begin_match(config: Dictionary, start_usec: int) -> void:
	var players := lobby.players().size()
	dots.reset(players)
	var sync := LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), config.delay, 1)
	# On a spectator: it fell too far behind and the host stopped sending it inputs.
	sync.dropped.connect(_on_dropped)
	# On the host: which spectator it gave up on.
	sync.spectator_dropped.connect(func(id): print("Stopped sending inputs to ", lobby.members[id].name))
	lockstep = LocalNetLockstep.new(sync, start_usec, TICK_RATE, dots.sample_input, dots.step, dots.checksum)
	_start_button = null
	menu.clear()
	menu.say("Watching the match." if lobby.is_spectator() else "Arrow keys to move.")
	if lobby.is_host:
		menu.button("Back to lobby", lobby.return_to_lobby)


func _on_dropped() -> void:
	end_match()
	menu.say("You fell too far behind to keep watching. You'll see the next match.")


func end_match() -> void:
	if lockstep:
		lockstep.sync.close()
	lockstep = null


func _on_returned() -> void:
	end_match()
	show_lobby()


# member_left fires for spectators too, and a spectator leaving shouldn't end the match.
# The member has gone from lobby.members by now, but is_spectator() still knows it.
func _on_member_left(id: int, _reason: String) -> void:
	if lobby.is_host and lobby.state == "started" and not lobby.is_spectator(id):
		lobby.return_to_lobby()
	elif lobby.state == "lobby":
		_show_status()


func leave() -> void:
	end_match()
	discovery.stop()
	if lobby:
		lobby.leave()
	lobby = null
	_start_button = null
	LocalNetWifiRoute.release()


func _back_home(message: String) -> void:
	leave()
	show_home(message)
