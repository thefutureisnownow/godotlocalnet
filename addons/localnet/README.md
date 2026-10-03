# LocalNet addon

Offline local multiplayer for Godot 4: discovery, a lobby with clock sync, automatic input delay, rematches and reconnects, and lockstep with time sync. It needs no internet, router, WebRTC or native code.

This folder is published from [stained/godotlocalnet](https://github.com/stained/godotlocalnet), which holds the full documentation, the wire protocol, the test suites and a link test app.

**Don't edit this folder inside a game.** Change LocalNet in its own repo, run its tests, publish with `tools/publish_addon.sh`, then pull the update into the game (in Snoek'em, `tools/update_localnet.sh`). `VERSION` says which release this copy is.

The scripts register their class names (`LocalNetDiscovery`, `LocalNetLobby`, `LocalNetLink`, `LocalNetInputSync`, `LocalNetLockstep`, `LocalNetLatencyStats`, `LocalNetWifiRoute`), so there's no plugin to enable. On Android, call `LocalNetWifiRoute.bind()` before hosting, scanning or joining (and `release()` on leaving), or a phone on a hotspot with mobile data on can send the link over mobile data. Android exports need the `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` permissions. On iOS, add `NSLocalNetworkUsageDescription` through `application/additional_plist_content`.
