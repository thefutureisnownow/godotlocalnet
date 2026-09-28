# LocalNet

Offline local multiplayer for Godot 4: devices on the same Wi-Fi or phone hotspot find each other, gather in a lobby and play in lockstep. It needs no internet, no router, no WebRTC and no native code. Everything lives in [`addons/localnet`](addons/localnet) so it can be dropped into Snoek'em, a Godot rewrite of Coldshift Racing or anything else.

The design follows Coldshift Racing's Flutter `net_core` (unicast subnet sweep for discovery, a host-owned lobby, clock sync, UDP for real-time traffic), rebuilt on Godot's built-in ENet.

## The addon

| Class | Job |
|---|---|
| `LocalNetDiscovery` | Hosts answer UDP probes on port 47650. Scanners probe every address in each local IPv4 /24, plus broadcast where allowed, and list the hosts that reply. |
| `LocalNetLink` | A thin ENet wrapper with one host, any number of clients and three channels: reliable control, unreliable real-time and reliable events. It can simulate loss, latency and jitter for tests. |
| `LocalNetLobby` | Join, reject (wrong game, version or code, or a full lobby), the member list, per-player data, shared settings, ready flags, clock sync and a synchronized start. |
| `LocalNetInputSync` | Lockstep input exchange with input delay. Packets resend everything that hasn't been acknowledged, so losses cost nothing. The host relays when there are more than two players. It also offers checksum desync detection, and `predicted_inputs()` as the first building block for rollback. |
| `LocalNetLatencyStats` | Measures how late remote inputs arrive, how often a given input delay would stall, and how deep rollback would need to go. |

Everything is poll-driven `RefCounted` objects, with no autoloads, RPCs or scene-tree multiplayer. Call `poll()` at the start of a frame; `LocalNetInputSync.flush()` sends that frame's inputs and flushes them at once.

```gdscript
var lobby := LocalNetLobby.new("snoekem", 1)
lobby.host("Kaap", 2)                       # or lobby.join(address, port, "Blaas")
discovery.advertise(lobby.advert())         # guests: discovery.scan(), then discovery.sessions()
lobby.started.connect(func(config, start_usec):
	sync = LocalNetInputSync.new(lobby.link, lobby.members.size(), lobby.local_slot(), lobby.peer_slots(), 3, 2))
# Each tick: sync.add_local_input(), then sync.is_ready(tick) and sync.inputs(tick); sync.flush() once a frame.
```

## Platform notes

- **Android:** needs the `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` permissions (the last one lets hosts hear broadcast probes).
  - Probes to empty addresses sit in the kernel's ARP queue, charged to the socket that sent them. Once about 200 are queued, the socket's send buffer fills, and Godot's UDP send, which script can't make non-blocking, stalls the main thread for about 2.3 s. The scanner therefore sends 32 probes per short-lived socket, one socket per frame. On the Galaxy A22 the worst frame dropped from 2.3 s to 2.5 ms.
- **iOS:** unicast works with the local network permission. `application/additional_plist_content` supplies `NSLocalNetworkUsageDescription`. Broadcast and multicast would need Apple's multicast entitlement, so iOS relies on the unicast sweep alone.
- **Subnets:** discovery assumes a /24. Home routers and Android hotspots use /24. An iPhone hotspot (172.20.10.0/28) sits inside one. For anything else, the demo can join by typing the host's address and port.

## Link test app

`demo/` is a 120 Hz toy game that runs the whole stack and reports the numbers. One device hosts and the others join.

- **Lockstep mode** waits for every input. It counts stalls and checks that the state stays identical.
- **Free-run mode** never waits: it guesses missing inputs the way rollback would, so it measures the network alone.

Results appear on screen, go to stdout or logcat as `LOCALNET RESULT`, and are saved under `user://results/`.

Command-line options, after `--`:

| Option | Effect |
|---|---|
| `--host` | Host a session |
| `--join[=address]` | Join a session, by address if given |
| `--name=` | Player name |
| `--delay=N` | Input delay in ticks |
| `--seconds=N` | Test length |
| `--players=N` | Number of players |
| `--free` | Free-run mode |
| `--loopback` | Scan only this machine |
| `--drop=0.2`, `--latency=20`, `--jitter=25` | Simulate a bad network |
| `--quit` | Quit when the test ends |

```sh
godot --headless --path . -- --host --seconds=10 --quit &
godot --headless --path . -- --join --loopback --quit
```

## Tests

```sh
godot --headless --path . --script tests/test_localnet.gd
```

The suite has 64 checks over loopback:

- discovery, including version and game filtering;
- joining, and rejections for a wrong code, the wrong version or a full lobby;
- settings and per-player data;
- clock sync and a synchronized start;
- lockstep on a clean link, a lossy link (25% loss, 12 ms latency with 10 ms jitter) and a three-player relay, with identical input histories on every device;
- desync detection;
- players leaving;
- the statistics maths.

## First measurements (2026-09-28)

Galaxy A22 on Wi-Fi to a MacBook through a home router. 30 s at 120 Hz, input delay 3 ticks (25 ms).

| Mode | Result |
|---|---|
| Lockstep | No desync over 3,600 ticks. About 5.5% of frames stalled, the longest by 55 ms. |
| Free-run (network only) | Input lateness p50 8–14 ms, p90 24–26 ms, p99 57–60 ms, max about 110 ms. |

Lockstep would need 7–12 ticks (58–100 ms) of input delay to stop stalling, which is too sluggish for a fighter. With rollback and 3 ticks of delay, 5–7% of ticks ran on a guess. In 99% of cases a correction would rewrite 4 ticks or fewer, and about 10 at worst. Phone-to-phone over a hotspot still needs measuring.
