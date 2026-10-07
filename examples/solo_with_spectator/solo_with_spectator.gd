extends Control
## One player and one spectator: a driver with a friend watching and calling out the way.
## By default can_start() needs two players, so this lobby sets min_players to 1. The
## host picks settings one at a time with merge_config(), which keeps the others.
##
## See player_vs_player for the basics; the comments here are about what's different.

const Dots := preload("res://examples/shared/dots.gd")
const Menu := preload("res://examples/shared/menu.gd")

const GAME := "localnet-example-solo-with-spectator"
const VERSION := 1
const TICK_RATE := 60
const MAZE: Array[Rect2i] = [Rect2i(150, 0, 20, 220), Rect2i(300, 80, 20, 220), Rect2i(450, 0, 20, 220)]

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
		_start_button.disabled = not lobby.can_start()
	if lockstep:
		lockstep.advance()
	elif lobby == null:
		_list_sessions()


func _exit_tree() -> void:
	leave()


func show_home(message := "") -> void:
	menu.say(message if message else "%s: drive, or navigate for a driver." % player_name)
	_listed = [null]
	LocalNetWifiRoute.bind()
	discovery.scan(scan_targets)


func _list_sessions() -> void:
	var found := discovery.sessions().filter(func(s): return s.compatible and s.state == "lobby" and s.spectators < s.max_spectators)
	if found.map(func(s): return s.id) == _listed:
		return
	_listed = found.map(func(s): return s.id)
	menu.clear()
	menu.button("Drive", host_game)
	for session in found:
		menu.button("Navigate for " + session.name, join_game.bind(session))


func host_game() -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.max_spectators = 1
	if lobby.host(player_name, 1) != OK:  # One player: the host. Nobody else can join to play.
		_back_home("Couldn't open a lobby.")
		return
	lobby.min_players = 1  # can_start() needs one player rather than two.
	lobby.set_config({"speed": 4, "maze": false})  # set_config() replaces the whole config.
	discovery.advertise(lobby.advert())
	show_lobby()


func join_game(session: Dictionary) -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.join(session.address, session.port, player_name, "", LocalNetLobby.SPECTATOR)
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
	return l


func show_lobby() -> void:
	menu.clear()
	_show_status()
	if lobby.is_host:
		# Each button changes one setting. merge_config() keeps the rest, and only tells the
		# others when something actually changed.
		menu.button("Slow", lobby.merge_config.bind({"speed": 2}))
		menu.button("Fast", lobby.merge_config.bind({"speed": 6}))
		menu.button("Maze on/off", func(): lobby.merge_config({"maze": not lobby.config.maze}))
		_start_button = menu.button("Start", start_match)
	menu.button("Leave", _back_home.bind(""))


func _on_members_changed() -> void:
	if lobby and lobby.state == "lobby":
		_show_status()


# Settings reach everyone with the member list, as lobby.config.
func _show_status() -> void:
	var navigator: Array = lobby.spectators().map(func(id): return lobby.members[id].name)
	var settings := "speed %d, maze %s" % [lobby.config.get("speed", 4), "on" if lobby.config.get("maze") else "off"]
	menu.say("Navigator: %s. Settings: %s." % [navigator[0] if navigator else "nobody yet", settings])


func start_match() -> void:
	lobby.merge_config({"delay": lobby.suggested_delay(TICK_RATE)})  # Adds the delay, keeps the settings.
	lobby.start()


func begin_match(config: Dictionary, start_usec: int) -> void:
	var walls: Array[Rect2i] = MAZE if config.maze else []
	dots.reset(1, walls, config.speed)
	var sync := LocalNetInputSync.new(lobby.link, 1, lobby.local_slot(), lobby.peer_slots(), config.delay, 1)
	lockstep = LocalNetLockstep.new(sync, start_usec, TICK_RATE, dots.sample_input, dots.step, dots.checksum)
	_start_button = null
	menu.clear()
	menu.say("Tell the driver the way." if lobby.is_spectator() else "Arrow keys to drive.")
	if lobby.is_host:
		menu.button("Back to lobby", lobby.return_to_lobby)


func end_match() -> void:
	if lockstep:
		lockstep.sync.close()
	lockstep = null


func _on_returned() -> void:
	end_match()
	show_lobby()


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
