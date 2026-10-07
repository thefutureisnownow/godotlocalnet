extends Control
## The host makes up a stage, and every device fetches it before the match, so they all
## play on the same walls. LocalNetContent moves the file by its hash; the lobby waits
## until everyone holds it, then until everyone has loaded it, then starts.
##
## See player_vs_player for the basics; the comments here are about content.

const Dots := preload("res://examples/shared/dots.gd")
const Menu := preload("res://examples/shared/menu.gd")

const GAME := "localnet-example-content-sharing"
const VERSION := 1
const TICK_RATE := 60
const STAGES := "user://localnet_example_stages"

var scan_targets := PackedStringArray()
## Where downloads go. Content is cached by hash, so a stage fetched once isn't fetched again.
var content_cache := "user://localnet_content"
var player_name := "Player %d" % (randi() % 100)
var discovery := LocalNetDiscovery.new(GAME, VERSION)
var lobby: LocalNetLobby
var content: LocalNetContent
var lockstep: LocalNetLockstep
var dots := Dots.new()
var menu := Menu.new()
var _listed := []
var _start_button: Button
var _walls: Array[Rect2i] = []


func _ready() -> void:
	menu.lay_out(self, dots)
	show_home()


func _process(_delta: float) -> void:
	discovery.poll()
	if lobby:
		lobby.poll()
	if content:
		content.poll()  # Every frame, after the lobby.
	if lobby and lobby.is_host and discovery.advertised_port:
		discovery.update_info(lobby.advert())
	if lobby and _start_button:
		# require_content: every player, and the host, must hold everything required.
		_start_button.disabled = not lobby.can_start(false, true)
	if lockstep:
		lockstep.advance()
	elif lobby == null:
		_list_sessions()


func _exit_tree() -> void:
	leave()


func show_home(message := "") -> void:
	menu.say(message if message else "%s: host with a new stage, or join." % player_name)
	_listed = [null]
	LocalNetWifiRoute.bind()
	discovery.scan(scan_targets)


func _list_sessions() -> void:
	var found := discovery.sessions().filter(func(s): return s.compatible and s.state == "lobby" and s.players < s.max_players)
	if found.map(func(s): return s.id) == _listed:
		return
	_listed = found.map(func(s): return s.id)
	menu.clear()
	menu.button("Host", host_game)
	for session in found:
		menu.button("Join " + session.name, join_game.bind(session))


func host_game() -> void:
	discovery.stop()
	lobby = _new_lobby()
	if lobby.host(player_name, 2) != OK:
		_back_home("Couldn't open a lobby.")
		return
	# Describe the stage (its hash and size), offer it to the others, and require it for
	# the match. Guests start fetching as soon as they hear what's required.
	var path := _make_stage()
	var stage := LocalNetContent.describe("stage", path.get_file(), path)
	content.offer(stage, path)
	content.require([stage])
	lobby.set_config({"stage": stage})  # So everyone knows which item to load.
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
	# With wait_for_loading, start() first sends everyone preparing(config), and the match
	# starts once each device has called mark_loaded(). Set it on the host.
	l.wait_for_loading = true
	l.joined.connect(func(_id): show_lobby())
	l.members_changed.connect(_on_members_changed)
	l.rejected.connect(func(reason): _back_home("Turned away: " + reason))
	l.closed.connect(_back_home)
	l.preparing.connect(_load_stage)
	l.started.connect(begin_match)
	l.returned.connect(_on_returned)
	l.member_left.connect(_on_member_left)
	content = LocalNetContent.new(l)
	content.cache_dir = content_cache
	content.progress.connect(func(_hash, bytes, total): menu.say("Fetching the stage: %d of %d bytes" % [bytes, total]))
	content.received.connect(func(_item, _path): _show_status())
	content.failed.connect(func(item, reason): menu.say("Couldn't get %s: %s" % [item.id, reason]))
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


# Each member reports how many required items it's still missing, under "content".
func _show_status() -> void:
	var names := lobby.players().map(func(id):
		var missing: int = lobby.members[id].get("content", {}).get("missing", 1)
		return lobby.members[id].name + (" (has the stage)" if missing == 0 else " (fetching)"))
	menu.say("Players: " + ", ".join(names))


func start_match() -> void:
	lobby.merge_config({"delay": lobby.suggested_delay(TICK_RATE)})
	lobby.start()


# Everyone, host included, loads the stage, then says so.
func _load_stage(config: Dictionary) -> void:
	menu.say("Loading the stage...")
	# path_for() is the download, or the file the host offered. Read content as data: never
	# load() it, since resources can carry scripts.
	var rects = JSON.parse_string(FileAccess.get_file_as_string(content.path_for(config.stage.hash)))
	_walls.clear()
	for r in rects if rects is Array else []:
		_walls.append(Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])))
	lobby.mark_loaded()


func begin_match(config: Dictionary, start_usec: int) -> void:
	var players := lobby.players().size()
	dots.reset(players, _walls)
	var sync := LocalNetInputSync.new(lobby.link, players, lobby.local_slot(), lobby.peer_slots(), config.delay, 1)
	lockstep = LocalNetLockstep.new(sync, start_usec, TICK_RATE, dots.sample_input, dots.step, dots.checksum)
	_start_button = null
	menu.clear()
	menu.say("Arrow keys to move, around the walls.")
	if lobby.is_host:
		menu.button("Back to lobby", lobby.return_to_lobby)


func end_match() -> void:
	if lockstep:
		lockstep.sync.close()
	lockstep = null


func _on_returned() -> void:
	end_match()
	show_lobby()


func _on_member_left(_id: int, _reason: String) -> void:
	if lobby.is_host and lobby.state == "started":
		lobby.return_to_lobby()
	elif lobby.state == "lobby":
		_show_status()


# A stage is a JSON list of walls, [x, y, width, height], clear of where the dots start.
func _make_stage() -> String:
	DirAccess.make_dir_recursive_absolute(STAGES)
	var walls := []
	for i in 6:
		walls.append([randi_range(140, 540), randi_range(0, Dots.SIZE.y - 60), 20, 60])
	var path := "%s/stage_%d.json" % [STAGES, Time.get_ticks_usec() ^ randi()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(walls))
	file.close()
	return path


func leave() -> void:
	end_match()
	discovery.stop()
	if content:
		content.close()
	content = null
	if lobby:
		lobby.leave()
	lobby = null
	_start_button = null
	LocalNetWifiRoute.release()


func _back_home(message: String) -> void:
	leave()
	show_home(message)
