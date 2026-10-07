extends Control
## Two players on two devices: find or host a session, both say they're ready, play in
## lockstep, and come back for a rematch. A dropped connection gets a reconnect window.
##
## Run it on two devices on the same Wi-Fi or phone hotspot, or twice on one machine
## (Debug > Customize Run Instances). One hosts; the other joins from the list.

const Dots := preload("res://examples/shared/dots.gd")
const Menu := preload("res://examples/shared/menu.gd")

# Scanners only list sessions of the same game, and the lobby only lets in the same
# version: bump it whenever the game's messages or rules change.
const GAME := "localnet-example-player-vs-player"
const VERSION := 1
const TICK_RATE := 60

## Where discovery looks. Empty sweeps every local /24; a typed address goes here too.
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


# Everything is polled once a frame: LocalNet has no threads, autoloads or RPCs.
func _process(_delta: float) -> void:
	discovery.poll()
	if lobby:
		lobby.poll()  # Lobby signals fire from here, and one may close the lobby.
	if lobby and lobby.is_host and discovery.advertised_port:
		discovery.update_info(lobby.advert())  # Keeps what scanners see current.
	if lobby and _start_button:
		_start_button.disabled = not lobby.can_start(true)  # true: everyone must be ready.
	if lockstep:
		lockstep.advance()  # Runs every tick that's due and whose inputs have all arrived.
	elif lobby == null:
		_list_sessions()


# Leaving says goodbye, so the others hear at once instead of waiting out the reconnect window.
func _exit_tree() -> void:
	leave()


# --- Finding a session ----------------------------------------------------------------

func show_home(message := "") -> void:
	menu.say(message if message else "%s: host a game, or join one on this network." % player_name)
	_listed = [null]
	LocalNetWifiRoute.bind()  # Android: keep sockets on Wi-Fi when mobile data is the default.
	discovery.scan(scan_targets)


# Each session is a Dictionary with name, address, port, players, max_players, state,
# compatible (same version), code_required, ping_ms and more.
func _list_sessions() -> void:
	var found := discovery.sessions().filter(func(s): return s.compatible and s.state == "lobby" and s.players < s.max_players)
	if found.map(func(s): return s.id) == _listed:
		return
	_listed = found.map(func(s): return s.id)
	menu.clear()
	menu.button("Host", host_game)
	for session in found:
		menu.button("Join %s (%d ms)" % [session.name, session.ping_ms], join_game.bind(session))


func host_game() -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.reconnect_window_msec = 20_000  # How long a dropped player may take to come back.
	if lobby.host(player_name, 2) != OK:
		_back_home("Couldn't open a lobby.")
		return
	discovery.advertise(lobby.advert())  # Answers scanners until discovery.stop().
	show_lobby()


func join_game(session: Dictionary) -> void:
	discovery.stop()
	lobby = _new_lobby()
	lobby.join(session.address, session.port, player_name)
	menu.say("Joining %s..." % session.name)
	menu.clear()


# --- The lobby ------------------------------------------------------------------------

func _new_lobby() -> LocalNetLobby:
	var l := LocalNetLobby.new(GAME, VERSION)
	l.joined.connect(func(_id): show_lobby())
	l.members_changed.connect(_on_members_changed)
	l.rejected.connect(func(reason): _back_home("Turned away: " + reason))
	l.closed.connect(_back_home)
	l.started.connect(begin_match)
	l.returned.connect(_on_returned)
	l.member_left.connect(_on_member_left)
	# Dropped connections: the host keeps a dropped player's place while it reconnects.
	l.member_interrupted.connect(func(id): menu.say("%s lost connection, waiting..." % l.members[id].name))
	l.member_resumed.connect(func(_id): _show_status())
	l.connection_interrupted.connect(func(): menu.say("Lost the host, reconnecting..."))
	l.connection_resumed.connect(_show_status)
	return l


func show_lobby() -> void:
	menu.clear()
	_show_status()
	menu.button("Ready", func(): lobby.set_ready(not lobby.members[lobby.local_id].ready))
	if lobby.is_host:
		_start_button = menu.button("Start", start_match)
	menu.button("Leave", _back_home.bind(""))


func _on_members_changed() -> void:
	if lobby and lobby.state == "lobby":
		_show_status()


# Each member is a Dictionary: name, slot, role, ready, connected and the game's own data.
func _show_status() -> void:
	if lockstep:
		menu.say("Arrow keys to move.")
		return
	var names := lobby.players().map(func(id):
		var m: Dictionary = lobby.members[id]
		return m.name + (" (ready)" if m.ready else "") + ("" if m.connected else " (reconnecting)"))
	menu.say("Players: " + ", ".join(names))


func start_match() -> void:
	# The host picks an input delay from the measured links and shares it in the config;
	# start() then gives every device the same wall-clock start time.
	lobby.set_config({"delay": lobby.suggested_delay(TICK_RATE)})
	lobby.start()


# --- The match ------------------------------------------------------------------------

func begin_match(config: Dictionary, start_usec: int) -> void:
	var players := lobby.players().size()
	dots.reset(players)
	var sync := LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), config.delay, 1)
	sync.desynced.connect(func(tick, _peer): menu.say("Desync at tick %d: the game isn't deterministic." % tick))
	lockstep = LocalNetLockstep.new(sync, start_usec, TICK_RATE, dots.sample_input, dots.step, dots.checksum)
	_start_button = null
	menu.clear()
	_show_status()
	if lobby.is_host:
		menu.button("Back to lobby", lobby.return_to_lobby)


func end_match() -> void:
	if lockstep:
		lockstep.sync.close()
	lockstep = null


func _on_returned() -> void:
	end_match()
	show_lobby()


# A player whose connection drops gets the reconnect window first, and only comes here
# if it runs out. A match can't go on without them, so the host brings everyone back.
func _on_member_left(_id: int, _reason: String) -> void:
	if lobby.is_host and lobby.state == "started":
		lobby.return_to_lobby()
	elif lobby.state == "lobby":
		_show_status()


# --- Leaving --------------------------------------------------------------------------

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
