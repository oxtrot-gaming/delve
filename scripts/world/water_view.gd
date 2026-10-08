class_name WaterView
extends Node3D

## The water level datum made visible — one translucent quad per
## open-water field cell at its surface level (SiteField.water). Built
## once at site install; when a basin level moves — flood event, player
## cut or dam — install() again re-lays the surface without touching
## terrain. Wetland cells draw nothing: saturated ground is a soil
## look, not open water.

var _mm: MultiMeshInstance3D


func _init() -> void:
	_mm = MultiMeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(SiteField.FIELD_M, SiteField.FIELD_M)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.16, 0.34, 0.52, 0.55)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_mm.multimesh = multimesh
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)


func install(field: SiteField) -> void:
	var multimesh := _mm.multimesh
	var count := 0
	for i in field.flags.size():
		if field.flags[i] & SiteField.FLAG_WATER:
			count += 1
	multimesh.instance_count = count
	var k := 0
	for cz in field.side:
		for cx in field.side:
			var i := cz * field.side + cx
			if field.flags[i] & SiteField.FLAG_WATER == 0:
				continue
			var px := float(field.origin.x) + cx * field.cell_m + field.cell_m * 0.5
			var pz := float(field.origin.y) + cz * field.cell_m + field.cell_m * 0.5
			# A hair under the level face so a dry neighbour's top face
			# at the same plane doesn't z-fight the water skin.
			var py := float(field.water[i]) + 0.97
			multimesh.set_instance_transform(
				k, Transform3D(Basis(), Vector3(px, py, pz))
			)
			k += 1
