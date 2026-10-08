class_name WaterView
extends Node3D

## The water level datum made visible — a skin over every submerged
## voxel column plus a skirt wall wherever a neighbouring column has no
## water at the same level. Built once at site install; when a basin
## level moves — flood event, player cut or dam — install() again
## re-lays the surface without touching terrain.
##
## The skin tiles at voxel granularity, not field cells: a flagged
## cell's datum comes from its centre sample, but the voxel surface
## inside it still rolls ±a few metres, and a 4 m quad hovers over
## whichever columns poke through the level. Drawing only submerged
## columns keeps the water sheet inside real dips; the skirts close the
## air gap you'd otherwise see under the translucent sheet at grazing
## angles. Wetland cells draw nothing: saturated ground is a soil look,
## not open water.

var _tops: MultiMeshInstance3D
var _sides: MultiMeshInstance3D

const _DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func _init() -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.16, 0.34, 0.52, 0.6)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var top_mesh := PlaneMesh.new()
	top_mesh.size = Vector2.ONE
	top_mesh.material = mat
	_tops = _make_multimesh(top_mesh)
	add_child(_tops)

	var side_mesh := QuadMesh.new()
	side_mesh.size = Vector2.ONE
	side_mesh.material = mat
	_sides = _make_multimesh(side_mesh)
	add_child(_sides)


func _make_multimesh(mesh: Mesh) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


func install(field: SiteField, gen: WorldGenerator) -> void:
	var tops := PackedVector3Array()
	var sides: Array[Transform3D] = []
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
					if gen.water_depth_at(vx, vz) <= 0:
						continue
					tops.append(Vector3(vx + 0.5, py, vz + 0.5))
					_skirt(sides, gen, vx, vz, py)
	_fill(_tops.multimesh, tops)
	_fill_sides(_sides.multimesh, sides)


## Emits a side quad on each edge whose neighbour has no water at this
## level — down to the lower of this column's bed or the neighbour's
## floor, so basins and rivers read as water volumes, not floating
## sheets. A dry bank above the surface swallows its own skirt.
func _skirt(
	sides: Array[Transform3D], gen: WorldGenerator,
	vx: int, vz: int, surface: float
) -> void:
	var bed := float(gen.terrain_height(vx, vz) + 1)
	var w := gen.water_level_at(vx, vz)
	for d in _DIRS:
		var nx: int = vx + d.x
		var nz: int = vz + d.z
		var nl: int = gen.water_level_at(nx, nz)
		if nl >= w:
			continue # same or higher water — shared body, no wall
		var bottom := bed
		if nl > SiteField.DRY:
			bottom = mini(bed, int(nl) + 1)
		else:
			var ntop := float(gen.terrain_height(nx, nz) + 1)
			if ntop >= surface:
				continue # buried inside the bank
			bottom = mini(bottom, ntop)
		var h := surface - bottom
		if h < 0.05:
			continue
		# QuadMesh faces +Z with width along X; rotate so the normal
		# points outward across the shared edge.
		var theta := atan2(float(d.x), float(d.z))
		var basis := Basis(Vector3.UP, theta).scaled(Vector3(1.0, h, 1.0))
		var centre := Vector3(
			vx + 0.5 + d.x * 0.5, bottom + h * 0.5, vz + 0.5 + d.z * 0.5
		)
		sides.append(Transform3D(basis, centre))


func _fill(multimesh: MultiMesh, spots: PackedVector3Array) -> void:
	multimesh.instance_count = spots.size()
	for k in spots.size():
		multimesh.set_instance_transform(
			k, Transform3D(Basis(), spots[k])
		)


func _fill_sides(multimesh: MultiMesh, sides: Array[Transform3D]) -> void:
	multimesh.instance_count = sides.size()
	for k in sides.size():
		multimesh.set_instance_transform(k, sides[k])
