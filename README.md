# LocalNet

Offline local multiplayer for Godot 4: devices on the same Wi-Fi or phone hotspot find each other, gather in a lobby and play in lockstep. It needs no internet, no router, no WebRTC and no native code. Everything lives in [`addons/localnet`](addons/localnet) so it can be dropped into Snoek'em, a Godot rewrite of Coldshift Racing or anything else.

The design follows Coldshift Racing's Flutter `net_core` (unicast subnet sweep for discovery, a host-owned lobby, clock sync, UDP for real-time traffic), rebuilt on Godot's built-in ENet.

## The addon

| Class | Job |
|---|---|
| `LocalNetDiscovery` | Hosts answer UDP probes on port 47650, or the first free of 47651–47653 when another host on the same device has it. Scanners probe every address in each local IPv4 /24, plus broadcast where allowed, and list the hosts that reply. A scan can also target one typed address, which finds its game port. |
| `LocalNetLink` | A thin ENet wrapper with one host, any number of clients and three channels: reliable control, unreliable real-time and reliable events. The game port is chosen by the system or by the host. It can simulate loss, latency and jitter for tests. |
| `LocalNetLobby` | Join, reject (wrong game, version or code, or a full lobby), the member list, per-player data, shared settings, ready flags, clock sync, link quality and `suggested_delay()`. It can wait until everyone has loaded before a synchronized start, and returns to the lobby for rematches. |
| `LocalNetInputSync` | Lockstep input exchange with input delay. Packets resend everything that hasn't been acknowledged, so losses cost nothing. The host relays when there are more than two players. It also offers checksum desync detection, and `predicted_inputs()` as the first building block for rollback. |
| `LocalNetLockstep` | The per-frame loop: which ticks are due, sampling input ahead, stepping, checksums and freeing old inputs. After a stall it moves its schedule back instead of racing through the backlog, and it reports who it's waiting on. |
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
PONG      ch1 unreliable  [02][t0: i64][host_now: i64]        17 bytes
CHECKSUM  ch2 reliable    [0B][tick: u32][hash: u32]           9 bytes

INPUTS    ch1 unreliable
  [0A][slot_count: u8]
  [latest: i32] × slot_count        ← acks: the highest complete tick held for each slot
  [run_count: u8]
  per run: [slot: u8][first_tick: i32][count: u8][input bytes × count]
```

Each INPUTS packet repeats every tick the receiver hasn't acknowledged, up to 32 per slot. For two players with 2-byte inputs, a typical packet is 20–25 bytes, plus about 45 bytes of ENet, UDP and IP headers.

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
| `--quit` | Quit when done |

```sh
godot --headless --path . -- --host --seconds=10 --matches=2 --quit &
godot --headless --path . -- --join=127.0.0.1 --quit
```

## Tests

```sh
godot --headless --path . --script tests/test_localnet.gd   # 135 checks, about 60 s
godot --headless --path . --script tests/test_demo.gd       # 17 checks, about 50 s
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
  - link reports, and suggested delays for quick, slow and very slow links (capped).
- **Lockstep:**
  - identical inputs on every device over a clean link, a lossy link (25% loss, 12 ms latency with 10 ms jitter) and a three-player relay;
  - a link far slower than the input delay, where both sides wait and ease back in;
  - stalls counted only when nothing could run, with waiting and resumed signals naming the missing player;
  - free-run guesses;
  - inputs kept until every peer that needs them has confirmed them.
- **Other:** desync detection, players leaving, and the statistics maths.

`test_demo.gd` launches the link test app as separate host and guest processes and reads the results they save:

- two matches with a rematch, joined by typing only the address;
- the automatic delay;
- a slow link;
- free-run;
- three players;
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
