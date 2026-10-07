# LocalNet

Offline local multiplayer for Godot 4: devices on the same Wi-Fi or phone hotspot find each other, gather in a lobby and play in lockstep. It needs no internet, no router, no WebRTC and no native code. Everything lives in [`addons/localnet`](addons/localnet) so it can be dropped into Snoek'em, a Godot rewrite of Coldshift Racing or anything else.

The design follows Coldshift Racing's Flutter `net_core` (unicast subnet sweep for discovery, a host-owned lobby, clock sync, UDP for real-time traffic), rebuilt on Godot's built-in ENet.

## Getting started

### Install

LocalNet is a folder of scripts. Copy [`addons/localnet`](addons/localnet) into your project, or pull it with git subtree from the `addon` branch, which holds that folder alone:

```sh
# Once, in the game's repo:
git subtree add --prefix=addons/localnet https://github.com/stained/godotlocalnet addon --squash
# For each update:
git subtree pull --prefix=addons/localnet https://github.com/stained/godotlocalnet addon --squash
```

The scripts register their class names, so there's no plugin to enable. LocalNet is developed and tested with Godot 4.7. Android exports need the `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` permissions, and iOS exports need `NSLocalNetworkUsageDescription` (see [Platform notes](#platform-notes)).

### How a session goes

Everything is poll-driven `RefCounted` objects, with no autoloads, RPCs or scene-tree multiplayer. How a game keeps its devices' state the same is up to the game. Discovery, the lobby, the link and content get everyone into a match together, and work the same whatever happens in it. `LocalNetInputSync` and `LocalNetLockstep` are optional helpers for games that choose lockstep; a game that sends its own state snapshots uses neither, and sends them over `lobby.link` on the game's own channels (see [Channels and kind bytes](#channels-and-kind-bytes)).

**1. Create discovery and a lobby, and poll them every frame.** Both take the game's id and its protocol version. Scanners only list sessions of the same game and mark other versions incompatible, and the lobby turns other versions away. Bump the version whenever the game's messages or rules change.

```gdscript
var discovery := LocalNetDiscovery.new("mygame", 1)
var lobby := LocalNetLobby.new("mygame", 1)
var lockstep: LocalNetLockstep

func _process(_delta):
	discovery.poll()
	lobby.poll()            # The lobby's signals fire from here.
	if lockstep:
		lockstep.advance()
```

**2. Host, and advertise the session.**

```gdscript
LocalNetWifiRoute.bind()                   # Android: keep sockets on Wi-Fi. Does nothing elsewhere.
lobby.host("Kaap", 2)                      # Name and players; optionally a join code, a port, and host_plays.
discovery.advertise(lobby.advert())
# Every frame while hosting, so scanners see the current player count:
discovery.update_info(lobby.advert())
```

**3. Or find a session and join it.** Each session is a Dictionary: `name`, `address`, `port`, `players`, `max_players`, `spectators`, `max_spectators`, `state`, `compatible` (the same version), `code_required` and `ping_ms`.

```gdscript
LocalNetWifiRoute.bind()
discovery.scan()                           # Sweeps every local /24 once a second. scan(["192.168.1.20"]) probes a typed address.
# Later, from discovery.sessions():
if session.compatible and session.state == "lobby" and session.players < session.max_players:
	discovery.stop()
	lobby.join(session.address, session.port, "Blaas")   # Then joined(id), or rejected(reason).
```

**4. Gather.** `lobby.members` maps each member's id to a Dictionary (`name`, `slot`, `role`, `ready`, `connected`, `data` and more), and `members_changed` fires whenever it changes. Each device can `set_ready(true)` and `set_data({...})` for its own choices. The host shares settings as `lobby.config`: `set_config()` replaces them all and `merge_config()` changes some keys.

**5. Start.** The host waits for `can_start()`: enough players (`min_players`, 2 by default), every one connected and with its clock synced. `can_start(true)` also wants them ready, and `can_start(false, true)` wants them holding the match's content. The host picks an input delay from the measured links and starts:

```gdscript
if lobby.can_start():
	lobby.set_config({"delay": lobby.suggested_delay(60)})   # 60 ticks a second.
	lobby.start()
```

Every device then gets `started(config, start_usec)`, at the same wall-clock moment on every device. With `wait_for_loading` on, everyone gets `preparing(config)` first, loads the match, and calls `mark_loaded()`.

**6. Play.** With the lockstep helpers, the game gives three functions: this device's input for a tick, a step of the whole game with every player's input, and a hash of its state. The step must give the same result on every device: integers only, no randomness that isn't seeded and shared, and nothing that depends on frame times.

```gdscript
lobby.started.connect(func(config, start_usec):
	var sync := LocalNetInputSync.new(lobby.link, lobby.players().size(), lobby.local_slot(), lobby.peer_slots(), config.delay, 1)
	sync.desynced.connect(func(tick, peer_id): push_error("Desync at tick %d" % tick))
	lockstep = LocalNetLockstep.new(sync, start_usec, 60, sample_input, step, checksum))

func sample_input(tick: int) -> PackedByteArray: ...                  # 1 byte here, the last argument above.
func step(tick: int, inputs: Array[PackedByteArray]) -> void: ...     # One input per player, in slot order.
func checksum() -> int: ...
```

**7. Rematch, or leave.** The host calls `return_to_lobby()`, and everyone gets `returned`: close the sync (`lockstep.sync.close()`) and drop the lockstep. Call `leave()` (and `discovery.stop()`, `LocalNetWifiRoute.release()`) when the player leaves or the game quits, so the others hear at once. Guests get `closed(reason)` when the host goes.

Along the way, a game should handle `rejected` and `closed`, and `member_left`. If a dropped connection comes back within the reconnect window, everything carries on (see [Dropped connections](#dropped-connections)); `member_interrupted` and `member_resumed` let the game show that. `member_left` fires for spectators too, so check `is_spectator(id)` before ending a match over it: it still answers for a member that has just left.

### Examples

[`examples/`](examples) holds five small games. They all play the same lockstep game, in which each player steers a dot with the arrow keys ([`examples/shared/dots.gd`](examples/shared/dots.gd)), but each sets up its sessions differently. Each example's script holds all of its LocalNet code, from discovery to leaving. Start with `player_vs_player`: it has the most comments, and the others only comment on what's different.

| Example | Shows |
|---|---|
| [`player_vs_player`](examples/player_vs_player/player_vs_player.gd) | Discovery, hosting and joining, ready flags, the suggested delay, a lockstep match, rematches, and messages while a dropped connection reconnects. |
| [`spectators`](examples/spectators/spectators.gd) | `max_spectators`, joining to play or to watch, spectators following the players' relayed inputs, and a spectator that falls too far behind being dropped. |
| [`solo_with_spectator`](examples/solo_with_spectator/solo_with_spectator.gd) | One player with a spectator watching, like a driver with a friend navigating: `min_players = 1`, and settings changed one at a time with `merge_config()`. |
| [`big_screen`](examples/big_screen/big_screen.gd) | A host that doesn't play (`host_plays` false), such as a PC on a TV showing the match while two phones play. |
| [`content_sharing`](examples/content_sharing/content_sharing.gd) | A stage the host makes up and every device fetches with `LocalNetContent` before the match: `can_start(false, true)`, and `wait_for_loading` with `preparing` and `mark_loaded()`. |

To try one, run its scene on two devices on the same network, or twice on one machine: in the editor with Debug > Customize Run Instances, or from a shell, once per window:

```sh
godot --path . examples/player_vs_player/player_vs_player.tscn
```

One window hosts and the other joins from its list. `tests/test_examples.gd` plays every example through, host and guests in one process, so they keep working as LocalNet changes.

## API at a glance

Every class and member is documented in its script, and Godot's built-in help shows it: press F1 (Search Help) and type `LocalNetLobby`, say.

| Class | Job |
|---|---|
| `LocalNetDiscovery` | Hosts answer UDP probes on port 47650, or the first free of 47651–47653 when another host on the same device has it. Scanners probe every address in each local IPv4 /24, plus broadcast where allowed, and list the hosts that reply. A scan can also target one typed address, which finds its game port. |
| `LocalNetLink` | A thin ENet wrapper with one host, any number of clients and six channels: reliable control, unreliable real-time, reliable events and reliable content, plus a reliable and an unreliable channel of the game's own. The game port is chosen by the system or by the host. Dropped connections reconnect under the same id (see below). It can simulate loss, latency, jitter, hiccups and dropped connections for tests. |
| `LocalNetLobby` | Join, reject (wrong game, version or code, or a full lobby), the member list, players and spectators, per-player data, shared settings (`set_config()` replaces them, `merge_config()` changes some keys), ready flags, clock sync, link quality and `suggested_delay()`. It can wait until everyone has loaded before a synchronized start, and returns to the lobby for rematches. The host can also stay out of the match and only relay (see below). |
| `LocalNetInputSync` | Lockstep input exchange with input delay. Packets resend everything that hasn't been acknowledged, so losses cost nothing. The host relays when there are more than two players, and to spectators. It also offers checksum desync detection, and `predicted_inputs()` as the first building block for rollback. |
| `LocalNetLockstep` | The per-frame loop: which ticks are due, sampling input ahead, stepping, checksums and freeing old inputs. After a stall it moves its schedule back instead of racing through the backlog, and it reports who it's waiting on. Time sync keeps devices' schedules together after hiccups or a misjudged clock offset (see below). |
| `LocalNetContent` | Moves content (stages, skins, mods) between lobby members by hash before a match, so everyone holds the same bytes (see below). |
| `LocalNetWifiRoute` | On Android, binds the game's sockets to Wi-Fi (see Platform notes); elsewhere it does nothing. Call `bind()` before hosting, scanning or joining, and `release()` on leaving. |
| `LocalNetLatencyStats` | Measures how late remote inputs arrive, how often a given input delay would stall, and how deep rollback would need to go. |

### LocalNetLobby

| Settings | |
|---|---|
| `max_spectators` | How many guests may join to watch; 0 (the default) turns them away. Set it before `host()`. |
| `min_players` | How many players `can_start()` needs. 2 by default. |
| `max_players` | How many players may join. `host()` sets it. |
| `wait_for_loading` | `start()` sends `preparing` first and waits for everyone's `mark_loaded()`. |
| `spectator_load_wait_msec` | With `wait_for_loading`, how long the start waits for spectators still loading. |
| `reconnect_window_msec` | How long a dropped member may take to come back. Set on the host; guests follow. |

| Calls | |
|---|---|
| `host(name, players, code, port, host_plays)`, `join(address, port, name, code, role)`, `leave()`, `poll()` | Open, join or leave a session; poll every frame. |
| `members`, `config`, `state`, `is_host`, `local_id` | The member list, the shared settings, and `"idle"`, `"joining"`, `"lobby"`, `"preparing"`, `"started"` or `"closed"`. |
| `players()`, `spectators()`, `is_spectator(id)`, `local_slot()`, `peer_slots()` | Who plays and who watches, and the slots lockstep needs. |
| `set_ready(ready)`, `set_data(data)` | This device's ready flag and choices, seen by everyone. |
| `set_config(values)`, `merge_config(values)` | Host: replace the shared settings, or change some keys. |
| `can_start(require_ready, require_content)`, `suggested_delay(tick_rate)`, `start()` | Host: whether everyone's there, an input delay from the measured links, and the synchronized start. |
| `mark_loaded()`, `return_to_lobby()`, `give_up(id)` | This device has loaded; host: end the match; stop waiting for a dropped connection. |
| `advert()` | What discovery should tell scanners. |

| Signals | |
|---|---|
| `joined(id)`, `rejected(reason)`, `closed(reason)` | This device got in, was turned away, or the session ended for it. |
| `members_changed` | The member list or settings changed. |
| `member_left(id, reason)` | Host: a member left, was kicked or was lost for good. It's gone from `members` by then, but `is_spectator(id)` still answers. Guests see the member list change. |
| `member_interrupted(id)`, `member_resumed(id)`, `connection_interrupted`, `connection_resumed` | Dropped connections and their return. |
| `preparing(config)`, `started(config, start_usec)`, `returned` | Load the match; play it; back in the lobby. |

### LocalNetDiscovery

`advertise(info, port)`, `update_info(info)` and `stop_advertising()` on the host; `scan(targets)`, `sessions()`, `stop_scanning()` and `session_found(session)` on scanners; `stop()` for both.

### LocalNetInputSync and LocalNetLockstep

`LocalNetInputSync.new(link, players, own_slot, peer_slots, delay, bytes_per_input)` exchanges inputs; `close()` it after the match. Its signals are `desynced(tick, peer_id)`, `spectator_dropped(peer_id)` on the host, and `dropped` on a spectator that fell too far behind. `LocalNetLockstep.new(sync, start_usec, ticks_per_second, sample_input, step, checksum)` runs the game: call `advance()` every frame. Its `waiting(slots)` and `resumed(stalled_usec)` signals report stalls, and `predict`, `time_sync` and `keep_ticks` tune it.

## Wire protocol

### Channels and kind bytes

The link has six ENet channels. LocalNet's binary packets start with a kind byte, so a game can share channels 1 and 2 with its own packets, using kinds 0x40 to 0xFF. LocalNet keeps everything below 0x40 on its channels for itself, and never sends or reads anything on channels 4 and 5, which are the game's own.

| Channel | Mode | LocalNet sends | A game may send |
|---|---|---|---|
| 0 `CHANNEL_CONTROL` | reliable | Lobby messages only: `var_to_bytes` dictionaries, no kind byte | Nothing |
| 1 `CHANNEL_REALTIME` | unreliable | PING `01`, PONG `02`, INPUTS `0A` | Kinds `40`–`FF` |
| 2 `CHANNEL_EVENTS` | reliable | CHECKSUM `0B`, DROPPED `0C` | Kinds `40`–`FF` |
| 3 `CHANNEL_CONTENT` | reliable | WANT `14`, CHUNK `15`, ACK `16`, NOPE `17`, CANCEL `18`; `19`–`3F` kept for later | Nothing |
| 4 `CHANNEL_GAME_RELIABLE` | reliable | Nothing | Anything |
| 5 `CHANNEL_GAME_REALTIME` | unreliable | Nothing | Anything |

Separate channels keep ordering and kind bytes apart, but not bandwidth. ENet's reliable window is per peer, shared by all its channels, so a game sending bulky reliable data on `CHANNEL_GAME_RELIABLE` should limit how much it has in flight, the way `LocalNetContent` does, or it delays LocalNet's lobby messages and checksums behind it. Unreliable packets use ENet's default sequenced mode: on any one channel, an older packet that arrives after a newer one is dropped. A game's own real-time traffic interleaved with inputs on channel 1 would get inputs dropped that way, and inputs dropped by it, so it belongs on `CHANNEL_GAME_REALTIME`.

The lobby only takes a PING of exactly 9 bytes from a member, and a PONG of exactly 21 bytes from the host, so a game packet on channel 1 can't be mistaken for one even if it reuses a kind.

### Messages

Discovery is JSON over UDP, so it stays readable and language-neutral:

```
probe: {"localnet":"probe","game":"snoekem","v":1,"sent":<usec>}
reply: {"localnet":"host","game":…,"v":…,"sent":<echoed>,"id":…,"name":…,"port":<game port>,"players":…,"max":…,"spectators":…,"max_spectators":…,"state":…,"code":<bool>}
```

Lobby messages travel on ENet channel 0 (reliable) as Godot variants: `var_to_bytes` of a Dictionary, decoded without objects. Integers, floats and vectors keep their types.

| Message | Direction |
|---|---|
| `hello` | guest → host: game, version, `"ln"` and `"ln_min"` (LocalNet's wire version, 3, and the oldest it works with, 3), `"role"` (`"player"` or `"spectator"`), name, code |
| `welcome` / `reject` | host → guest |
| `member` | guest → host: ready, synced, loaded, data, net, `"content"` (`{"need", "missing"}`) |
| `lobby`, `prepare`, `start`, `return` | host → everyone. `lobby` carries the members (each with a `"role"` and its `"ln"`), and `"content"` once the host has required some. |

Match traffic is binary and little-endian. The first byte of every packet is a kind code, so several listeners can share a channel.

```
PING      ch1 unreliable  [01][t0: i64]                        9 bytes
PONG      ch1 unreliable  [02][t0: i64][host_now: i64][host_frame: u32]   21 bytes
CHECKSUM  ch2 reliable    [0B][tick: u32][hash: u32]           9 bytes
DROPPED   ch2 reliable    [0C]                                 1 byte    host → a spectator it stopped sending inputs to

INPUTS    ch1 unreliable
  [0A][slot_count: u8]
  [position: i32]                   ← where the sender's schedule has reached, in 1/16 ticks
  [reading: i16]                    ← the sender's reading of how far ahead of the receiver
                                      it runs, in 1/16 ticks (−32768: none yet), for time sync
  [latest: i32] × slot_count        ← acks: the highest complete tick held for each slot
  [run_count: u8]
  per run: [slot: u8][first_tick: i32][count: u8][input bytes × count]
```

Each INPUTS packet repeats every tick the receiver hasn't acknowledged, up to 32 per slot. For two players with 2-byte inputs, a typical packet is 27–32 bytes, plus about 45 bytes of ENet, UDP and IP headers.

Content travels on its own reliable channel, with the item's sha256 as 32 raw bytes:

```
WANT   ch3 reliable  [14][hash: 32 bytes][offset: u32]         37 bytes
CHUNK  ch3 reliable  [15][hash: 32 bytes][offset: u32][bytes]  up to 37 + 16,384 bytes
ACK    ch3 reliable  [16][hash: 32 bytes][offset: u32]         37 bytes
NOPE   ch3 reliable  [17][hash: 32 bytes][reason: u8]          34 bytes   1: don't have it, 2: nobody has it, 3: can't read it
CANCEL ch3 reliable  [18][hash: 32 bytes]                      33 bytes   don't send it any more
```

Every chunk from the device a fetch asked is acknowledged, whether it's kept or not, so the sender always knows what's still in flight. A sender closes a transfer when it hears CANCEL or NOPE for that item, and when the chunks it has in flight go unacknowledged for 5 s.

## Dropped connections

A connection that drops without a goodbye gets a second chance. Each client sends a random token with its connection request (ENet's 32-bit connect data, so no extra messages). The host holds the client's id for the reconnect window while the client keeps retrying with the token. A client that gets back in time has its old id, so the lobby, input sync and lockstep carry on as if nothing happened. The lockstep side simply waits, then eases back in.

Leaving on purpose (`close()`) or being kicked sends a reason with the disconnect, so it ends at once with no waiting. If the system breaks the socket itself, as phones can when an app is backgrounded, the link opens a new one on the same port and treats every connection as dropped.

| Layer | Signals |
|---|---|
| `LocalNetLink` | `peer_interrupted(id)`, `peer_resumed(id)`, `peer_disconnected(id, reason)`, where the reason is "left", "kicked" or "lost". `interrupted_peers()` and `reconnect_seconds_left(id)` support a countdown. |
| `LocalNetLobby`, everyone | `member_interrupted(id)`, `member_resumed(id)`, and each member's `connected` flag. `can_start()` waits for every player to be connected. These fire for spectators too: check `is_spectator(id)` before acting on them (see Players and spectators). |
| `LocalNetLobby`, host | `member_left(id, reason)`, for spectators too; `is_spectator(id)` still answers for a member that has left. Guests see the member list change. |
| `LocalNetLobby`, guest | `connection_interrupted`, `connection_resumed`. When the window runs out: `closed("Lost connection to the host")`. |

Anything the host sent while a guest was away is lost, so on resume it resends the member list and settings, and whether a match started, is loading or has ended. A guest that missed the start joins the match on the same clock as everyone else. A guest that comes back after the host has let it go is told so, rather than being let in as a stranger.

The game decides how long to wait, and the library only reports what happens:

| Setting or call | Effect |
|---|---|
| `lobby.reconnect_window_msec` | Set on the host; guests follow it. 30 s by default. |
| `0` | Turns reconnecting off: a drop is final at once. |
| `LocalNetLink.WAIT_FOREVER` | No time limit: waiting lasts until the game gives up. |
| `lobby.give_up(id)` (host) | Stops waiting for a member, for example from a "stop waiting" button. `member_left(id, "lost")` follows at once. |
| `lobby.give_up()` (guest) | Stops waiting for the host. `closed(...)` follows at once. |

The app has to still be running to reconnect: the token lives in memory, so a restarted app joins as a new player.

## Time sync

During a hiccup every device stalls, but not for the same length of time. Without correction, the one that waited less runs ahead for the rest of the match. That eats into its input delay, so it keeps stuttering. On the A22 and iPhone after a 400 ms hiccup, the iPhone ran 3 ticks ahead, and 93% of the A22's inputs reached it late.

The same happens without a hiccup when the clock offset measured at the start is a few milliseconds out. In the phone soak's third match the A25's clock ran about 25 ms ahead of the A22's. It waited on the A22's inputs on 40% of its frames and ran ticks in bursts, which shows as judder.

Each input packet carries where the sender's schedule has reached, in sixteenths of a tick. That's where its clock says it should be, not the tick it has managed to run: waiting holds the tick back, and would hide exactly the lead that causes the waiting. The receiver compares that with its own schedule when the packet arrives, and keeps the median of the last few readings. Each packet also carries the sender's own reading of the receiver, so both halves meet: half the difference between the two readings is how far one schedule runs ahead of the other, and the time the packets spent in flight cancels out. Half of ENet's round trip, the estimate used before, includes both ends' polling and made a two-tick lead look like half a tick. A device more than half a tick ahead of any peer eases back, taking at most 10% of each frame, until they line up.

In a simulation of that third match (a 68 fps host, a 120 fps guest 25 ms ahead, 14.5 ms each way, 4 ticks of delay), the guest waits on 43% of its frames without time sync and 1% with it.

## Input delay

`suggested_delay()` picks an input delay long enough for an input to reach the other device before it's due there. An input can be sampled up to a frame late, since devices only sample on frames, and noticed up to a frame late at the other end. So the delay is:

- half the slowest player's typical (75th-percentile) round trip, which already includes the average quarter of each end's frame;
- three quarters of the two slowest players' frame times;
- a 3 ms margin.

Spectators' round trips and frames are left out. When the host doesn't play, every input crosses two links (guest → host → guest), so the first term becomes half of each of the two slowest players' round trips, plus the host's whole frame, since it relays once a frame. With three or more players and a host that plays, guests' inputs to each other are relayed too, and the formula, which counts one link, probably comes out short; it is left as it is for now, since Snoek'em plays two.

Guests ping the host about 60 times a second in the lobby, as often as a match sends inputs. Phones put a quiet Wi-Fi radio into power save, where packets wait for a beacon or three (100–300 ms), and only wake it fully for steady traffic. At four or ten pings a second the radio napped. The first match on the A22 and A25 was judged from slow pings (6 to 12 ticks, where rematches got 4), and it still stalled for about a second in total as the radio woke. At 60 a second, first matches start with no stalls at all. Round trips from the first second after joining are left out while the radio wakes, and the last two seconds' worth are kept. A guest only counts as synced, so the host can only start, once half a second of round trips has been measured after that: about 1.5 s after joining. Round trips that waited on a frame of more than 50 ms at either end are left out too: a host loading its next screen answers pings only between long frames, and on the A22 that made a first match's round trips look like 300–500 ms. Each pong says how long the host's last frame took for this.

ENet's own throttle is switched off. It drops a share of unreliable packets whenever a round trip looks worse than usual, and lockstep inputs already repeat until acknowledged, so dropping them only makes them late: after a host's loading hitch it cost first matches stalls of about 300 ms. Guests report their link quality once a second, since each report has the host send the member list to everyone. Every member times its own frames from how often it polls the lobby, and reports that with its link quality; the host reports its own. Host and guests work the delay out from the same member list, so they agree. On a phone hotspot with a 68 fps and a 120 fps phone it comes to 4 ticks at 120 Hz. The earlier rule, half the 90th-percentile round trip plus a flat 12 ms, gave 3 ticks there, too short for the A22's 15 ms frames, and 5 ticks for a first match whose pings were taken while the lobby was busy.

A 400 ms hiccup over loopback shows the difference:

| | Typical lateness, host / guest | Worst side's stalled frames |
|---|---|---|
| Without time sync | 30.7 / −9.9 ms | 13% |
| With time sync | 14.0 / 7.4 ms | 4% (the hiccup itself) |

## Players and spectators

Every member has a role in the lobby, `"player"` or `"spectator"`. Roles are a lobby matter only: they don't depend on how the game syncs its state.

| Setting or call | Effect |
|---|---|
| `lobby.max_spectators` | How many guests may join to watch. 0 by default, which turns them away ("Spectators aren't allowed"); past the limit it's "No room for spectators". Set it before `host()`, since the link makes room for them then. |
| `lobby.join(address, port, name, code, "spectator")` | Joins to watch. Spectators must join before the match starts. |
| `lobby.min_players` | How many players `can_start()` needs, 2 by default. Spectators don't count, so 1 lets a single player start while others watch, such as a driver with a friend navigating. A start always needs at least one player. |
| `lobby.host(name, players, code, port, false)` | The host doesn't play: its member is a spectator and `players` guests play. For a PC driving a big screen or Tilt Five glasses while phones play. |
| `lobby.spectator_load_wait_msec` | With `wait_for_loading`: how long the start waits for spectators still loading, counted from when every player has loaded. 3000 by default; 0 doesn't wait for them at all. |
| `players()`, `spectators()`, `is_spectator(id)` | Member ids by role, and whether a member watches. A host that doesn't play is among the spectators. |
| `advert()` | `players` counts players only; `spectators` and `max_spectators` are new, and discovery's sessions carry them. |

Spectators have slot −1, and a spectator falling off or lagging never stops the game. They don't count towards `max_players`, the `min_players` `can_start()` needs, `start()`'s slot numbering or `suggested_delay()`, and `can_start()` doesn't wait for anything of theirs: not a ready flag, not their content, not even their clock sync. A spectator whose clock isn't synced yet still gets the start; its lag behind the schedule absorbs a rough clock reading, and one too far off is dropped like any spectator that falls `keep_ticks` behind, and watches the next match.

With `wait_for_loading`, the start waits for every player (and the host) to load, then for spectators still loading only up to `spectator_load_wait_msec` more, and not at all for one whose connection has dropped. A spectator that loads in time starts the match at once. One that loads later gets `started` when it calls `mark_loaded()`, with the match's own start time, as a guest that missed the start does, and catches up within `keep_ticks` or is dropped. Since transfers pause once a match is preparing, a spectator still fetching content simply doesn't load in time; it carries on fetching back in the lobby and watches the next match.

`member_interrupted`, `member_resumed` and `member_left` fire for spectators as well as players, so a game should check `is_spectator(id)` before acting on them: one that ends a match whenever a member leaves would end it when a spectator leaves. A member is gone from `members` by the time `member_left` fires, but the host remembers its role for the rest of the session, so `is_spectator(id)` still answers. The exception is a host that doesn't play. It's a spectator by role, but it's the hub every device connects through and there's no host migration, so it's waited for like a player (its loading and, with `can_start(..., true)`, its content), and when it goes, the session ends for everyone, as with any host (`closed` on the guests).

A navigator or co-driver isn't a role. Anything that changes the game has to reach every device, so in lockstep a co-driver is just another player slot whose input means something else; the game says so in member data.

**In the lockstep helpers**, a spectator follows the match from relayed inputs:

- The host's `peer_slots()` maps spectators to −1, and `LocalNetInputSync` relays every slot to them the way it relays to players. A device with no slot (a spectator, or a host that doesn't play) passes `own_slot = -1` and never samples input.
- Spectators never slow players. The host leaves them out of time sync (`timing_peers()`), and `waiting_on()` only names slots, which spectators don't have.
- A spectating guest hears every input second-hand, so its runner stays `spectator_lag_ticks` (4) behind the shared schedule to ride out the extra hop. After a stall it eases back in like everyone else, then catches up, running at most `catch_up_rate` (25%) faster and only as far as the inputs it holds allow. A host that doesn't play hears every input first-hand and runs on the schedule.
- The host keeps inputs until every peer has confirmed them. A spectator that falls more than `keep_ticks` (240) behind would keep them forever, so the host stops sending to it and emits `spectator_dropped(id)`. It tells the spectator too, with one DROPPED packet, sent again if the spectator reconnects within the window, so the spectator's own `LocalNetInputSync` emits `dropped` instead of waiting for inputs that will never come. What happens next is the game's choice: the spectator can leave, or stay in the lobby and watch the next match.
- Spectators report checksums like anyone else, and a mismatch emits `desynced(tick, peer_id)` as before; the game decides what a spectator's desync means. The link test app reports it and the players carry on.

In the link test app, a spectator with a 40 ms, 20 ms-jitter link to the host followed a match 23.5 ms behind the schedule on average (35.5 ms at most), with no stalls, while the two players stalled on no frames at all.

## Content

`LocalNetContent` moves blobs between lobby members before a match, so everyone has the same stage, skin or mod. It carries bytes only: the game packs its content (with `ZIPPacker`, say) and loads what arrives itself. It needs only the lobby and its link, whatever kind of match follows.

```gdscript
var content := LocalNetContent.new(lobby)
var reef := LocalNetContent.describe("stage", "reef", "user://stages/reef.zip")   # {type, id, hash, size}
content.offer(reef, "user://stages/reef.zip")   # a path, bytes, or (offset, length) -> bytes
content.require([reef])                          # host: what the match needs
content.received.connect(func(item, path): install(item, path))
# Every frame, after lobby.poll(): content.poll(). The host starts once lobby.can_start(false, true).
```

`describe()` hashes the whole item before it returns, at about 400 MB/s on a laptop and a few times slower on a phone: a 32 MB item takes about 80 ms on a laptop and a few hundred on a phone. A game describes its own content once, when it's made or installed, and can keep the item with it. For big items, call `describe()` from a thread (`WorkerThreadPool.add_task()`): it touches nothing shared. That keeps one simple call rather than adding a second, poll-driven way to describe items.

Items are matched by their sha256, never their id: a different version under the same id counts as missing, since devices running different content would drift apart. Every member hears what's required with the member list, fetches what it lacks and reports how many items are still missing under its member's `"content"` key, and `can_start(require_ready, require_content)` can wait for that. Guests fetch from the host. When only a guest has an item, the host fetches it from that guest, keeps it and passes it on, so content travels in a star like everything else.

| Setting, call or signal | Effect |
|---|---|
| `offer(item, source)`, `require(items)` | What this device can serve; what the match needs (host). |
| `has(hash)`, `path_for(hash)`, `missing()` | What this device holds, and where. |
| `cache_dir` | `user://localnet_content/` by default. Downloads are `<hash>`, partial ones `<hash>.part`. |
| `max_item_bytes` | 32 MB by default; bigger items are never asked for. Raise it for large mods. |
| `budget_bytes` | Bytes of chunks sent per frame, 128 KB by default. |
| `hash_budget_bytes` | Bytes of a partial download hashed per frame when it resumes, 1 MB by default (about 2 ms on a laptop). |
| `progress(hash, bytes, total)`, `received(item, path)`, `failed(item, reason)`, `all_present` | Reasons for failing are "Nobody has it", "Too big", "Didn't match its hash" and "Couldn't be read". Each is reported once per item. On the host, "Nobody has it" and "Didn't match its hash" mean nobody is left to ask for now; it keeps trying, and asks members who join later. |

Transfers have their own reliable channel. ENet's reliable window (64 KB) is shared by all of a peer's channels, so a big backlog of chunks would hold up lobby messages and checksums behind it. Each peer therefore gets at most 4 unacknowledged 16 KB chunks, and the sender keeps to `budget_bytes` a frame. When the host changes what's needed mid-transfer, the fetch that's no longer wanted is called off (CANCEL), so the sender's window frees up at once for the next item; chunks of it still arriving are answered with another cancel. A transfer that goes quiet for 5 s (`STALL_USEC`) while it should be moving is let go by the sender, and asked for again by the fetcher (the host asks the next member), so nothing lost along the way can hold up a peer for good. A lobby that leaves and opens a new session starts its transfers afresh. Transfers only run in the lobby: they pause when a match is preparing or playing and carry on when everyone returns. A partial download carries on from its `.part` file after a dropped connection, a rematch or a restart of the app. A finished one is checked against its hash before it's renamed into place; one that doesn't match is thrown away. A guest then gives up on the item. The host, which passes content on, asks the next member instead, never asks the member whose copy was bad again, and only reports `failed` once nobody is left to ask, so one bad copy can't stop it serving everyone else. Resuming from a `.part` file hashes what's already there a little each frame (`hash_budget_bytes`), so a big partial download doesn't hold up a frame. A device only accepts chunks of items it asked for, from the device it asked, and only serves items it offered (the host also serves required items it has fetched).

**Never load downloaded content through `ResourceLoader`** (`load()`, `ResourceLoader.load()` or a scene that references it). `.tres`, `.res` and `.tscn` files can embed scripts, which would run with the game's permissions. Read downloads as data: `GLTFDocument` for models, `Image.load_from_buffer()` for images, `JSON` for settings, and `ZIPReader` to unpack.

Over loopback, with both ends polling every 8.3 ms (120 fps), a 16 MB item moved at 6.2 MB/s and checksums sent meanwhile arrived 4.9 ms late typically (10 ms at worst), as they do with no transfer. Throughput is about four chunks per frame:

| Chunk, chunks in flight | 120 fps | 60 fps | Checksums late, 60 fps (typical / worst) |
|---|---|---|---|
| 8 KB, 4 | 3.6 MB/s | 1.8 MB/s | 13.7 / 17.3 ms |
| 16 KB, 4 (chosen) | 6.2 MB/s | 3.2 MB/s | 15.8 / 18.5 ms |
| 16 KB, 16 | 7.0 MB/s | 3.6 MB/s | 50 / 68 ms |
| 16 KB, no limit | 7.0 MB/s | 3.6 MB/s | 1,158 / 2,286 ms |

In the link test app, 100 MB in a single item went across loopback in 12.8 s (7.8 MB/s), and in 13 items of up to 8 MB in 14.0 s (7.2 MB/s).

## Ports

| Socket | Port |
|---|---|
| Discovery listener (host) | 47650/UDP, falling back to 47651–47653 |
| Game connection (host) | Any free port, or one the host chooses; discovery replies carry it |
| Everything else (scanners, guests) | Any free port |

Scanners probe the fallback ports on their own device every sweep, and across the network every fourth sweep.

## Platform notes

- **Android:** needs the `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` permissions (the last one lets hosts hear broadcast probes).
  - A phone that joins a hotspot without internet while its mobile data is on can make mobile data its default network, and Android routes an app's sockets by the default network: discovery and the link go out over mobile data and never arrive ("Couldn't reach the host"). This happens on Samsungs with "Switch to mobile data" on while the "Internet may not be available" prompt is unanswered. `LocalNetWifiRoute.bind()` binds the process to the Wi-Fi network (`ConnectivityManager.bindProcessToNetwork`) so sockets opened after it use Wi-Fi; a hotspot phone has no Wi-Fi network to bind and reaches its guests directly. Tested on the Galaxy A25 joining the A22's hotspot with mobile data as its default: without binding it couldn't reach the host; with it, a full match at 13 ms round trips.
  - Probes to empty addresses sit in the kernel's ARP queue, charged to the socket that sent them. Once about 200 are queued, the socket's send buffer fills, and Godot's UDP send, which script can't make non-blocking, stalls the main thread for about 2.3 s. The scanner therefore sends 32 probes per short-lived socket, one socket per frame. On the Galaxy A22 the worst frame dropped from 2.3 s to 2.5 ms.
- **iOS:** unicast works with the local network permission. `application/additional_plist_content` supplies `NSLocalNetworkUsageDescription`. Broadcast and multicast would need Apple's multicast entitlement, so iOS relies on the unicast sweep alone.
- **Subnets:** discovery assumes a /24. Home routers and Android hotspots use /24. An iPhone hotspot (172.20.10.0/28) sits inside one. For anything else, type the host's address.
- **Guest Wi-Fi:** networks that block device-to-device traffic (client isolation) stop guests reaching each other. The hotspot phone itself can always host.

## Link test app

`demo/` is a 120 Hz toy game that runs the whole stack and reports the numbers: a tool for measuring links, where the [examples](#examples) are for reading. One device hosts and the others join. Joining can be from the list, by typing `address:port`, or by typing just the address.

- **Lockstep mode** waits for every input. It counts frozen frames and checks that the state stays identical.
- **Free-run mode** never waits: it guesses missing inputs the way rollback would, so it measures the network alone.

The input delay is automatic by default, from the lobby's pings, and the host can override it. After a match, the host can start a rematch. Results appear on screen, go to stdout or logcat as `LOCALNET RESULT`, and are saved under `user://results/`.

Command-line options, after `--`:

| Option | Effect |
|---|---|
| `--host` | Host a session, starting when enough players have joined |
| `--join[=address[:port]]` | Join the first session found, or a given address |
| `--spectate[=address[:port]]` | Join to watch. The results show how far behind the schedule it ran. |
| `--spectators=N` | The host waits for N spectators before starting |
| `--organiser` | The host doesn't play; `--players` guests do |
| `--content=MB`, `--content-item=MB` | The host makes up MB of random content, in items of up to 8 MB (or the given size), and starts once every player has fetched it. Guests report the throughput. |
| `--desync=TICK` | This device's game goes wrong at TICK, to show what a desync does |
| `--name=` | Player name |
| `--port=N` | Host on a fixed game port |
| `--delay=N` | Fixed input delay in ticks (default: automatic) |
| `--seconds=N` | Match length |
| `--players=N` | Number of players |
| `--matches=N` | Matches in a row, with automatic rematches |
| `--free` | Free-run mode |
| `--loopback` | Scan only this machine |
| `--drop=0.2`, `--latency=20`, `--jitter=25` | Simulate a bad network |
| `--hiccup=MS` | Hold this device's packets for MS, three seconds into the match |
| `--drop-connection=MS` | Drop this device's connection three seconds into the match, and reconnect after MS |
| `--reconnect=SECONDS`, `forever` or `off` | The host's reconnect window (default 30 s). The host screen can also cycle it, and a "Stop waiting" button appears mid-match while someone is reconnecting. |
| `--no-time-sync` | Turn time sync off, for comparison |
| `--results=DIR` | Where to save results |
| `--quit` | Quit when done |

```sh
godot --headless --path . -- --host --seconds=10 --matches=2 --quit &
godot --headless --path . -- --join=127.0.0.1 --quit
```

## Versions

Each game has its own protocol version, the one it gives `LocalNetDiscovery` and `LocalNetLobby`. LocalNet has a wire version of its own, and `addons/localnet/VERSION` says which release a copy of the addon is.

**Updating a game to 0.3:** bump the game's own protocol version (the `version` it gives `LocalNetDiscovery` and `LocalNetLobby`, such as Snoek'em's `PROTOCOL`), even if no game code changes. 0.3 adds three ENet channels (content, and two for the game's own use), and its lobby `hello` carries LocalNet's own wire version (`"ln": 3`) and the oldest one it still works with (`"ln_min": 3`). A 0.3 host turns away a guest without them (a 0.2 build), or one whose range doesn't overlap its own, as "Different LocalNet version", but a 0.2 host ignores them and would let a 0.3 guest in. Bumping the game's version keeps old and new builds apart on both sides, and discovery lists the other build as incompatible.

**LocalNet's wire version** (`LocalNetLobby.WIRE_VERSION` and `WIRE_VERSION_MIN`) is kept apart from the game's. A host lets a guest in when their ranges overlap: the guest's `ln` is at least the host's `ln_min`, and the host's `ln` at least the guest's `ln_min`. A change that older peers can do without, such as a new message they'd ignore, raises `ln` only, so old and new builds still meet. A change that breaks older peers raises `ln_min` too. Each member's `ln` is kept in its member dictionary (`members[id].ln`), so a feature added later can check which members have it.

## Working on LocalNet

Change LocalNet in this repo, never in a game's copy. After the tests pass, bump `addons/localnet/VERSION`, commit, and run `tools/publish_addon.sh` to update the `addon` branch, which games pull.

## Tests

```sh
godot --headless --path . --script tests/test_localnet.gd   # 452 checks, about 3 minutes
godot --headless --path . --script tests/test_demo.gd       # 41 checks, about 2½ minutes
godot --headless --path . --script tests/test_examples.gd   # 64 checks, about 35 seconds
```

`test_localnet.gd` runs hosts and clients side by side over loopback. A pair of input syncs wired together in memory lets the lockstep rules be checked tick by tick. It covers:

- **Discovery:**
  - version and game filtering;
  - fallback ports for two hosts on one device;
  - which ports each sweep probes;
  - hosts dropping off the list when they go quiet.
- **Lobby:**
  - a host-chosen game port, and refusal of a taken one;
  - joining, and rejections for a wrong code, the wrong version, a full lobby or a match in progress;
  - settings and per-player data keeping their types;
  - `merge_config()` keeping the other settings, copying what it's given, and sending only when a value (or its type) changes, while `set_config()` still replaces them all;
  - clock sync and a synchronized start;
  - waiting for everyone to load, including a player leaving mid-load;
  - rematches;
  - calls made at the wrong time being ignored;
  - link reports and frame times, and suggested delays for quick, slow and very slow links (capped) and for a guest with slow frames, agreed by host and guest.
- **Lockstep:**
  - identical inputs on every device over a clean link, a lossy link (25% loss, 12 ms latency with 10 ms jitter) and a three-player relay;
  - a link far slower than the input delay, where both sides wait and ease back in;
  - stalls counted only when nothing could run, with waiting and resumed signals naming the missing player;
  - time sync, in an event-driven simulation of a 90 fps host and a 60 fps guest: after a hiccup the schedules drift 2 ticks apart without it and stay within a tick with it. It also checks that easing is gentle and that nothing is eased when there's no hiccup. A second simulation replays the phone soak's clock offset (a 68 fps host and a 120 fps guest 25 ms ahead): the guest waits on most frames without time sync and under 3% with it, with both sides' readings reaching each other;
  - free-run guesses;
  - inputs kept until every peer that needs them has confirmed them.
- **Dropped connections:**
  - the guest's drop and the host's;
  - leaving on purpose, and coming back too late;
  - the host becoming unreachable;
  - broken sockets on either side;
  - a guest catching up on settings and a start it missed;
  - the host's window reaching guests, waiting forever, giving up from either side, and a window of 0;
  - a lockstep match surviving an 800 ms drop with identical inputs on both sides.
- **Spectators and roles:**
  - spectators turned away by default and past the limit, and not taking players' places;
  - a spectator that drops while it's the last one loading, or hasn't synced its clock, never holding up the start;
  - with `wait_for_loading`, a spectator still fetching content not holding up `can_start(false, true)`, and the start waiting `spectator_load_wait_msec` for spectators' loading, not at all with 0, and no longer than a spectator takes to load;
  - a spectator that loads after the match has begun joining on the match's clock and following it, or dropped and told so once more than `keep_ticks` behind, while the players never stall;
  - players and spectators counted apart in `can_start()`, the advert, slot numbering and the suggested delay;
  - `is_spectator()` still knowing a member's role in `member_left`, after it has left, until a new session;
  - a host that doesn't play starting two guests' lockstep match, identical inputs and checksums on all three devices, over a clean and a lossy link;
  - a spectator following a lockstep match;
  - a player and a spectator held back by the default `min_players` of 2, then starting and playing a lockstep match with it at 1, and a start always needing a player;
  - a slow spectator (20 fps, 120 ms away) never stalling the players or easing their schedules, and a late one catching up;
  - a spectator that stops confirming being dropped once `keep_ticks` behind, and told so, again if it was away and reconnects;
  - a guest of another LocalNet version turned away, and one whose range of versions overlaps let in, with its version kept in its member dictionary.
- **Content:**
  - offer and require, `can_start(false, true)`, and cached content not fetched again;
  - an item only a guest has, passed on through the host;
  - bytes that don't match their hash thrown away, and a host given a bad copy asking the next member, then members who join later;
  - hashes that must be exactly 64 lowercase hex digits, and `describe()` on a worker thread;
  - a transfer carrying on after a dropped connection, pausing for a match, and resuming from its partial file in a new session, hashed a little each frame;
  - the size limit, chunks nobody asked for, and items nobody offered;
  - a 16 MB transfer with at most 4 chunks in flight, while lobby messages and checksums arrive at once;
  - the host changing what's needed mid-transfer, in both directions, with the old transfer called off and the window kept;
  - repeated WANTs, WANTs past the end, and transfers that go quiet at either end;
  - a new session starting with no transfers left from the last.
- **Channels:** the game's own channels 4 and 5 carrying packets both ways while LocalNet ignores them, and pings and pongs of the wrong size or from the wrong peer ignored.
- **Other:** desync detection, players leaving, and the statistics maths.

`test_demo.gd` launches the link test app as separate host and guest processes and reads the results they save:

- two matches with a rematch, joined by typing only the address;
- the automatic delay;
- a slow link;
- free-run;
- three players;
- a 400 ms hiccup with and without time sync;
- a 1.5 s dropped connection mid-match, and one longer than the host's window;
- a spectator on a slow link whose own desync doesn't end the players' match, and who doesn't stall them;
- a host that doesn't play, with two guests;
- 8 MB of content fetched before a match;
- every process quitting on its own.

`test_examples.gd` plays each of the [examples](#examples) with a host and its guests in one process, through the examples' own functions: finding the host by discovery, joining, starting, playing with keys held until every device shows the same dots and checksums, coming back to the lobby, and the guests going home when the host leaves. Along the way it checks ready flags and a rematch, a spectator with no slot leaving mid-match without ending it, the solo lobby able to start alone and keeping both settings merged one at a time, a host that doesn't play, and a stage fetched, cached by its hash and loaded the same everywhere.

## Measurements (2026-09-28)

All runs are 120 Hz with an input delay of 3 ticks (25 ms). Lateness is how long after the sender was due to sample an input it arrived.

| Link | Mode | Result |
|---|---|---|
| A22 ↔ MacBook, home router | Lockstep | No desync. 5.5% of frames stalled, the longest by 55 ms. |
| A22 ↔ MacBook, home router | Free-run | Lateness p50 8–14 ms, p99 57–60 ms, max about 110 ms. |
| A22 hotspot ↔ iPhone XS Max, both directions | Lockstep | No desync. At most 1 stalled frame (13 ms) in 60 s. Lateness p99 28–29 ms, max 38–45 ms. |
| A22 hotspot ↔ iPhone XS Max | Free-run | 4 of 7,200 ticks ran on a guess. Lateness p99 26–32 ms, max 33–42 ms. |
| A22 hotspot, iPad 9th gen as a third player | Free-run | The iPad's link alone had p99 190–250 ms and max 515–600 ms, in both directions. The A22 ↔ iPhone link stayed clean, and relaying through the host added about 10 ms. |

On a phone hotspot, plain lockstep at 3–4 ticks is responsive and smooth. A home router, or a device with a poor Wi-Fi link, has a long tail. That is where the automatic delay and, later, rollback matter.
