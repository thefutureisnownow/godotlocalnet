extends Control
## A big screen hosts and shows the match while phones play: the host takes no slot.
## Run it on a PC or TV box as the host ("Be the screen"), and on two more devices to play.
##
## The host is a spectator by role, but it's still the hub every input passes through:
## it's waited for like a player, and when it leaves the session ends.
##
## See player_vs_player for the basics; the comments here are about what's different.

const Dots := preload("res://examples/shared/dots.gd")
const Menu := preload("res://examples/shared/menu.gd")

const GAME := "localnet-example-big-screen"
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
var _playing := []


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
		_start_button.disabled = not lobby.can_start()  # Two players, not counting the screen.
	if lockstep:
		lockstep.advance()
	elif lobby == null:
		_list_sessions()


func _exit_tree() -> void:
	leave()


func show_home(message := "") -> void:
	menu.say(message if message else "%s: be the screen, or play on one." % player_name)
	_listed = [null]
	LocalNetWifiRoute.bind()
	discovery.scan(scan_targets)


func _list_sessions() -> void:
	var found := discovery.sessions().filter(func(s): return s.compatible and s.state == "lobby" and s.players < s.max_players)
	if found.map(func(s): return s.id) == _listed:
		return
	_listed = found.map(func(s): return s.id)
	menu.clear()
	menu.button("Be the screen", host_game)
	for session in found:
		menu.button("Play on " + session.name, join_game.bind(session))


func host_game() -> void:
	discovery.stop()
	lobby = _new_lobby()
	# host_plays false: the host's member is a spectator, and 2 guests play.
	if lobby.host(player_name, 2, "", 0, false) != OK:
		_back_home("Couldn't open a lobby.")
		return
	discovery.advertise(lobby.advert())
	show_lobby()


func join_game(session: Dictionary) -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.join(session.address, session.port, player_name)
	menu.say("Joining %s..." % session.name)
	menu.clear()


func _new_lobby() -> LocalNetLobby:
	var l := LocalNetLobby.new(GAME, VERSION)
	l.joined.connect(func(_id): show_lobby())
	l.members_changed.connect(_on_members_changed)
	l.rejected.connect(func(reason): _back_home("Turned away: " + reason))
	l.closed.connect(_back_home)  # The screen left: without the hub, the session is over.
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


# players() leaves the screen out: it's among spectators().
func _show_status() -> void:
	var names: Array = lobby.players().map(func(id): return lobby.members[id].name)
	menu.say("Players: %s (%d of %d)." % [", ".join(names) if names else "none yet", names.size(), lobby.max_players])


func start_match() -> void:
	# Every input now crosses two links, phone to screen to phone, and suggested_delay()
	# allows for that.
	lobby.set_config({"delay": lobby.suggested_delay(TICK_RATE)})
	lobby.start()


# The screen's local_slot() is -1, so it samples nothing. Unlike a spectating guest, it
# hears every input first-hand and shows the match on time.
func begin_match(config: Dictionary, start_usec: int) -> void:
	_playing = lobby.players()
	dots.reset(_playing.size())
	var sync := LocalNetInputSync.new(lobby.link, _playing.size(), lobby.local_slot(), lobby.peer_slots(), config.delay, 1)
	lockstep = LocalNetLockstep.new(sync, start_usec, TICK_RATE, dots.sample_input, dots.step, dots.checksum)
	_start_button = null
	menu.clear()
	menu.say("On the big screen." if lobby.is_host else "You're the %s dot: arrow keys to move." % ["red", "blue"][lobby.local_slot()])
	if lobby.is_host:
		menu.button("Back to lobby", lobby.return_to_lobby)


func end_match() -> void:
	if lockstep:
		lockstep.sync.close()
	lockstep = null


func _on_returned() -> void:
	end_match()
	show_lobby()


func _on_member_left(id: int, _reason: String) -> void:
	if lobby.is_host and lobby.state == "started" and id in _playing:
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
