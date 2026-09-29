# LocalNet

Offline local multiplayer for Godot 4: devices on the same Wi-Fi or phone hotspot find each other, gather in a lobby and play in lockstep. It needs no internet, no router, no WebRTC and no native code. Everything lives in [`addons/localnet`](addons/localnet) so it can be dropped into Snoek'em, a Godot rewrite of Coldshift Racing or anything else.

The design follows Coldshift Racing's Flutter `net_core` (unicast subnet sweep for discovery, a host-owned lobby, clock sync, UDP for real-time traffic), rebuilt on Godot's built-in ENet.

## Using it in a game

Games take the addon as a plain folder, pulled from the `addon` branch with git subtree, so they build with no extra steps:

```sh
# Once, in the game's repo:
git subtree add --prefix=addons/localnet https://github.com/stained/godotlocalnet addon --squash
# For each update:
git subtree pull --prefix=addons/localnet https://github.com/stained/godotlocalnet addon --squash
```

Change LocalNet here, never in a game's copy. After the tests pass, bump `addons/localnet/VERSION`, commit, and run `tools/publish_addon.sh` to update the `addon` branch.

## The addon

| Class | Job |
|---|---|
| `LocalNetDiscovery` | Hosts answer UDP probes on port 47650, or the first free of 47651–47653 when another host on the same device has it. Scanners probe every address in each local IPv4 /24, plus broadcast where allowed, and list the hosts that reply. A scan can also target one typed address, which finds its game port. |
| `LocalNetLink` | A thin ENet wrapper with one host, any number of clients and three channels: reliable control, unreliable real-time and reliable events. The game port is chosen by the system or by the host. Dropped connections reconnect under the same id (see below). It can simulate loss, latency, jitter, hiccups and dropped connections for tests. |
| `LocalNetLobby` | Join, reject (wrong game, version or code, or a full lobby), the member list, per-player data, shared settings, ready flags, clock sync, link quality and `suggested_delay()`. It can wait until everyone has loaded before a synchronized start, and returns to the lobby for rematches. |
| `LocalNetInputSync` | Lockstep input exchange with input delay. Packets resend everything that hasn't been acknowledged, so losses cost nothing. The host relays when there are more than two players. It also offers checksum desync detection, and `predicted_inputs()` as the first building block for rollback. |
| `LocalNetLockstep` | The per-frame loop: which ticks are due, sampling input ahead, stepping, checksums and freeing old inputs. After a stall it moves its schedule back instead of racing through the backlog, and it reports who it's waiting on. Time sync keeps devices' schedules together after hiccups or a misjudged clock offset (see below). |
| `LocalNetLatencyStats` | Measures how late remote inputs arrive, how often a given input delay would stall, and how deep rollback would need to go. |

Everything is poll-driven `RefCounted` objects, with no autoloads, RPCs or scene-tree multiplayer. Call `poll()` on the discovery and lobby at the start of each frame.

```gdscript
var discovery := LocalNetDiscovery.new("snoekem", 1)
var lobby := LocalNetLobby.new("snoekem", 1)
lobby.wait_for_loading = true
lobby.host("Kaap", 2)                        # guests: discovery.scan(), discovery.sessions(), lobby.join(address, port, "Blaas")
discovery.advertise(lobby.advert())

# Host, when everyone is in: pick the delay from the pings, then start.
lobby.set_config({"stage": 2, "delay": lobby.suggested_delay(120)})
lobby.start()

lobby.preparing.connect(func(config): load_fight(config); lobby.mark_loaded())
lobby.started.connect(func(config, start_usec):
	var sync := LocalNetInputSync.new(lobby.link, lobby.members.size(), lobby.local_slot(), lobby.peer_slots(), config.delay, 2)
	lockstep = LocalNetLockstep.new(sync, start_usec, 120, read_pad, step_fight, hash_fight))
# Every frame: lockstep.advance(). After the match the host calls lobby.return_to_lobby().
```

## Wire protocol

Discovery is JSON over UDP, so it stays readable and language-neutral:

```
probe: {"localnet":"probe","game":"snoekem","v":1,"sent":<usec>}
reply: {"localnet":"host","game":…,"v":…,"sent":<echoed>,"id":…,"name":…,"port":<game port>,"players":…,"max":…,"state":…,"code":<bool>}
```

Lobby messages travel on ENet channel 0 (reliable) as Godot variants: `var_to_bytes` of a Dictionary, decoded without objects. Integers, floats and vectors keep their types.

| Message | Direction |
|---|---|
| `hello` | guest → host |
| `welcome` / `reject` | host → guest |
| `member` | guest → host |
| `lobby`, `prepare`, `start`, `return` | host → everyone |

Match traffic is binary and little-endian. The first byte of every packet is a kind code, so several listeners can share a channel.

```
PING      ch1 unreliable  [01][t0: i64]                        9 bytes
PONG      ch1 unreliable  [02][t0: i64][host_now: i64][host_frame: u32]   21 bytes
CHECKSUM  ch2 reliable    [0B][tick: u32][hash: u32]           9 bytes

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

## Dropped connections

A connection that drops without a goodbye gets a second chance. Each client sends a random token with its connection request (ENet's 32-bit connect data, so no extra messages). The host holds the client's id for the reconnect window while the client keeps retrying with the token. A client that gets back in time has its old id, so the lobby, input sync and lockstep carry on as if nothing happened. The lockstep side simply waits, then eases back in.

Leaving on purpose (`close()`) or being kicked sends a reason with the disconnect, so it ends at once with no waiting. If the system breaks the socket itself, as phones can when an app is backgrounded, the link opens a new one on the same port and treats every connection as dropped.

| Layer | Signals |
|---|---|
| `LocalNetLink` | `peer_interrupted(id)`, `peer_resumed(id)`, `peer_disconnected(id, reason)`, where the reason is "left", "kicked" or "lost". `interrupted_peers()` and `reconnect_seconds_left(id)` support a countdown. |
| `LocalNetLobby`, everyone | `member_interrupted(id)`, `member_resumed(id)`, `member_left(id, reason)`, and each member's `connected` flag. `can_start()` waits for everyone to be connected. |
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

- half the slowest member's typical (75th-percentile) round trip, which already includes the average quarter of each end's frame;
- three quarters of the two slowest members' frame times;
- a 3 ms margin.

Guests ping the host about 60 times a second in the lobby, as often as a match sends inputs. Phones put a quiet Wi-Fi radio into power save, where packets wait for a beacon or three (100–300 ms), and only wake it fully for steady traffic. At four or ten pings a second the radio napped. The first match on the A22 and A25 was judged from slow pings (6 to 12 ticks, where rematches got 4), and it still stalled for about a second in total as the radio woke. At 60 a second, first matches start with no stalls at all. Round trips from the first second after joining are left out while the radio wakes, and the last two seconds' worth are kept. A guest only counts as synced, so the host can only start, once half a second of round trips has been measured after that: about 1.5 s after joining. Round trips that waited on a frame of more than 50 ms at either end are left out too: a host loading its next screen answers pings only between long frames, and on the A22 that made a first match's round trips look like 300–500 ms. Each pong says how long the host's last frame took for this.

ENet's own throttle is switched off. It drops a share of unreliable packets whenever a round trip looks worse than usual, and lockstep inputs already repeat until acknowledged, so dropping them only makes them late: after a host's loading hitch it cost first matches stalls of about 300 ms. Guests report their link quality once a second, since each report has the host send the member list to everyone. Every member times its own frames from how often it polls the lobby, and reports that with its link quality; the host reports its own. Host and guests work the delay out from the same member list, so they agree. On a phone hotspot with a 68 fps and a 120 fps phone it comes to 4 ticks at 120 Hz. The earlier rule, half the 90th-percentile round trip plus a flat 12 ms, gave 3 ticks there, too short for the A22's 15 ms frames, and 5 ticks for a first match whose pings were taken while the lobby was busy.

A 400 ms hiccup over loopback shows the difference:

| | Typical lateness, host / guest | Worst side's stalled frames |
|---|---|---|
| Without time sync | 30.7 / −9.9 ms | 13% |
| With time sync | 14.0 / 7.4 ms | 4% (the hiccup itself) |

## Ports

| Socket | Port |
|---|---|
| Discovery listener (host) | 47650/UDP, falling back to 47651–47653 |
| Game connection (host) | Any free port, or one the host chooses; discovery replies carry it |
| Everything else (scanners, guests) | Any free port |

Scanners probe the fallback ports on their own device every sweep, and across the network every fourth sweep.

## Platform notes

- **Android:** needs the `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` permissions (the last one lets hosts hear broadcast probes).
  - Probes to empty addresses sit in the kernel's ARP queue, charged to the socket that sent them. Once about 200 are queued, the socket's send buffer fills, and Godot's UDP send, which script can't make non-blocking, stalls the main thread for about 2.3 s. The scanner therefore sends 32 probes per short-lived socket, one socket per frame. On the Galaxy A22 the worst frame dropped from 2.3 s to 2.5 ms.
- **iOS:** unicast works with the local network permission. `application/additional_plist_content` supplies `NSLocalNetworkUsageDescription`. Broadcast and multicast would need Apple's multicast entitlement, so iOS relies on the unicast sweep alone.
- **Subnets:** discovery assumes a /24. Home routers and Android hotspots use /24. An iPhone hotspot (172.20.10.0/28) sits inside one. For anything else, type the host's address.
- **Guest Wi-Fi:** networks that block device-to-device traffic (client isolation) stop guests reaching each other. The hotspot phone itself can always host.

## Link test app

`demo/` is a 120 Hz toy game that runs the whole stack and reports the numbers. One device hosts and the others join. Joining can be from the list, by typing `address:port`, or by typing just the address.

- **Lockstep mode** waits for every input. It counts frozen frames and checks that the state stays identical.
- **Free-run mode** never waits: it guesses missing inputs the way rollback would, so it measures the network alone.

The input delay is automatic by default, from the lobby's pings, and the host can override it. After a match, the host can start a rematch. Results appear on screen, go to stdout or logcat as `LOCALNET RESULT`, and are saved under `user://results/`.

Command-line options, after `--`:

| Option | Effect |
|---|---|
| `--host` | Host a session, starting when enough players have joined |
| `--join[=address[:port]]` | Join the first session found, or a given address |
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

## Tests

```sh
godot --headless --path . --script tests/test_localnet.gd   # 180 checks, about 100 s
godot --headless --path . --script tests/test_demo.gd       # 29 checks, about 130 s
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
- **Other:** desync detection, players leaving, and the statistics maths.

`test_demo.gd` launches the link test app as separate host and guest processes and reads the results they save:

- two matches with a rematch, joined by typing only the address;
- the automatic delay;
- a slow link;
- free-run;
- three players;
- a 400 ms hiccup with and without time sync;
- a 1.5 s dropped connection mid-match, and one longer than the host's window;
- every process quitting on its own.

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
