class_name WaterView
extends Node3D

## The water level datum made visible — a skin over every submerged
## voxel column. Built once at site install; when a basin level moves
## — flood event, player cut or dam — install() again re-lays the
## surface without touching terrain.
##
## The skin tiles at voxel granularity, not field cells: a flagged
## cell's datum comes from its centre sample, but the voxel surface
## inside it still rolls ±a few metres, and a 4 m quad hovers over
## whichever columns poke through the level. Drawing only submerged
## columns keeps the water sheet inside real dips. Wetland cells draw
## nothing: saturated ground is a soil look, not open water.

var _mm: MultiMeshInstance3D


func _init() -> void:
	_mm = MultiMeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2.ONE
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.16, 0.34, 0.52, 0.6)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_mm.multimesh = multimesh
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)


func install(field: SiteField, gen: WorldGenerator) -> void:
	var spots := PackedVector3Array()
	for cz in field.side:
		for cx in field.side:
			var i := cz * field.side + cx
			if field.flags[i] & SiteField.FLAG_WATER == 0:
				continue
			var base_x: int = field.origin.x + cx * field.cell_m
			var base_z: int = field.origin.y + cz * field.cell_m
			# A hair under the level's top face so a dry neighbour's
			# top face at the same plane doesn't z-fight the skin.
			var py := float(field.water[i]) + 0.97
			for dz in field.cell_m:
				for dx in field.cell_m:
					var vx := base_x + dx
					var vz := base_z + dz
					if gen.water_depth_at(vx, vz) > 0:
						spots.append(Vector3(vx + 0.5, py, vz + 0.5))
	var multimesh := _mm.multimesh
	multimesh.instance_count = spots.size()
	for k in spots.size():
		multimesh.set_instance_transform(k, Transform3D(Basis(), spots[k]))
