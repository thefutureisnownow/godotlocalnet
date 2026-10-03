class_name LocalNetWifiRoute
extends RefCounted
## Keeps a link's traffic on Wi-Fi on Android.
##
## A phone that joins another's hotspot (or any Wi-Fi without internet) while mobile data is
## on keeps mobile data as its default network, and Android routes an app's sockets by the
## default network: packets for the host's local address go out over mobile data and never
## arrive. [method bind] binds this process to the Wi-Fi network
## (ConnectivityManager.bindProcessToNetwork), so sockets opened after it use Wi-Fi;
## [method release] undoes it. Elsewhere, or with no Wi-Fi network (the phone is the hotspot
## itself, whose clients are reached directly), both do nothing.
##
## Bind before opening the link's sockets (discovery, lobby); calling it again is harmless and
## picks up a Wi-Fi network that has come up since.

const TRANSPORT_WIFI := 1 # NetworkCapabilities.TRANSPORT_WIFI

static var _bound := false


## Binds to the Wi-Fi network if there is one. Returns "wifi" when bound, "none" with no Wi-Fi
## network, "n/a" off Android, or "error: ..." when Android's API couldn't be reached.
static func bind() -> String:
	if OS.get_name() != "Android":
		return "n/a"
	var manager = _manager()
	if manager == null:
		return _note("error: no ConnectivityManager")
	var networks = manager.getAllNetworks()
	if networks == null:
		return _note("error: no networks")
	for network in networks:
		var caps = manager.getNetworkCapabilities(network)
		if caps != null and caps.hasTransport(TRANSPORT_WIFI):
			if not manager.bindProcessToNetwork(network):
				return _note("error: bind refused")
			_bound = true
			return _note("wifi")
	# No Wi-Fi now: anything bound before is gone, so fall back to the default network.
	if _bound:
		release()
	return _note("none")


## Back to the default network (mobile data or Wi-Fi, as Android decides).
static func release() -> void:
	if not _bound or OS.get_name() != "Android":
		return
	var manager = _manager()
	if manager != null:
		manager.bindProcessToNetwork(null)
	_bound = false
	_note("released")


static func is_bound() -> bool:
	return _bound


static func _manager():
	if not Engine.has_singleton("AndroidRuntime"):
		return null
	var context = Engine.get_singleton("AndroidRuntime").getApplicationContext()
	return context.getSystemService("connectivity") if context != null else null


static func _note(status: String) -> String:
	print("LocalNet Wi-Fi route: ", status)
	return status
