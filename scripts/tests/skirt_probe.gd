extends SceneTree

## Verifies the skirt quad basis: a vertical quad facing the outward
## direction, spanning the edge between a water column and its
## lower/dry neighbour.
func _initialize() -> void:
	for d in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
		var theta := atan2(float(d.x), float(d.z))
		var basis := Basis(Vector3.UP, theta).scaled(Vector3(1.0, 3.0, 1.0))
		var normal := basis * Vector3(0, 0, 1)
		var width_axis := basis * Vector3(1, 0, 0)
		var height_axis := basis * Vector3(0, 1, 0)
		print(
			"dir %s → normal %s, width %s, height %s" % [
				d, normal, width_axis, height_axis
			]
		)
	quit(0)
