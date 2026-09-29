extends SceneTree
func _initialize():call_deferred("run")
func run():
	var t=load("res://tests/test_localnet.gd").new()
	for c in [[true,0],[false,25_000],[true,25_000],[true,-25_000],[true,0,14_500,0,90,60],[true,0,3000,400_000,90,60]]:
		var lat=c[2] if c.size()>2 else 14_500
		var r=t.pair_sim(c[0],c[4] if c.size()>4 else 68,c[5] if c.size()>5 else 120,lat,c[3] if c.size()>3 else 0,20.0,c[1])
		var parts=[]
		for side in 2:
			var run:LocalNetLockstep=r.runners[side]
			parts.append("side %d stalled %.0f%% shifted %.1f eased %.1f" % [side,100.0*run.stalled_frames/run.frames,run.shifted_usec/1000.0,run.eased_usec/1000.0])
		print("sync %s lead %d lat %d blackout %s: drift %.2f | %s" % [c[0],c[1]/1000,lat/1000,c[3] if c.size()>3 else 0,r.drift," | ".join(parts)])
	quit()
