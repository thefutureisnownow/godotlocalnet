extends SceneTree
func _initialize():call_deferred("run")
func run():
	var t=load("res://tests/test_localnet.gd").new()
	for delay in [3,4,5]:
		for lead in [0,25_000,-25_000]:
			for sync in [false,true]:
				var r=t.pair_sim(sync,68,120,14_500,0,10.0,lead,delay)
				print("delay %d lead %3d sync %-5s: host stalled %4.1f%%  guest stalled %4.1f%%  drift %.2f" % [delay,lead/1000,sync,100.0*r.runners[0].stalled_frames/r.runners[0].frames,100.0*r.runners[1].stalled_frames/r.runners[1].frames,r.drift])
	quit()
