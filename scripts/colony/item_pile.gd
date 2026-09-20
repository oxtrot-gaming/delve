class_name ItemPile
extends Node3D

## A heap of loose items sitting in the world where a block was mined.
## Spawned by [Colony.drop_block]; a haul job will eventually carry these
## to the stockpile.

var voxel_position: Vector3i
var items: Array[DropItem] = []

var _material: StandardMaterial3D


static func create(position: Vector3i) -> ItemPile:
	var pile := ItemPile.new()
	pile.voxel_position = position
	pile.position = Vector3(position) + Vector3(0.5, 0.0, 0.5)
	return pile


## Adds [param new_items] onto the pile and rebuilds its mesh.
func add_items(new_items: Array[DropItem]) -> void:
	items.append_array(new_items)
	if is_inside_tree():
		_rebuild_mesh()


## Adds a single [param item] onto the pile and rebuilds its mesh.
func add_item(item: DropItem) -> void:
	items.append(item)
	if is_inside_tree():
		_rebuild_mesh()


func _ready() -> void:
	_rebuild_mesh()


## The material class of the pile's contents, or NONE when empty.
func material_class() -> BlockRegistry.Resource_:
	return items[0].material if not items.is_empty() else BlockRegistry.Resource_.NONE


func total_volume() -> float:
	var total := 0.0
	for item in items:
		total += item.volume
	return total


## Lays every item out as a small box scattered across the voxel floor,
## biggest first. Loose items are wide flat mounds; boulders and cobbles
## are chunky cubes.
func _rebuild_mesh() -> void:
	for child in get_children():
		child.queue_free()
	if items.is_empty():
		return

	if _material == null:
		_material = StandardMaterial3D.new()
		_material.roughness = 0.9
		_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_material.albedo_color = BlockRegistry.resource_color(material_class())

	var sorted := items.duplicate()
	sorted.sort_custom(func(a: DropItem, b: DropItem) -> bool: return a.volume > b.volume)
	var golden_angle := PI * (3.0 - sqrt(5.0))
	for i in sorted.size():
		var item: DropItem = sorted[i]
		var side := clampf(pow(item.volume, 1.0 / 3.0) * 0.85, 0.08, 0.9)
		var box := BoxMesh.new()
		if item.form == DropItem.Form.LOOSE:
			box.size = Vector3(side * 1.35, side * 0.6, side * 1.35)
		else:
			box.size = Vector3.ONE * side
		var instance := MeshInstance3D.new()
		instance.mesh = box
		instance.material_override = _material
		var radius := 0.42 * sqrt((i + 0.5) / sorted.size())
		var angle := i * golden_angle
		instance.position = Vector3(radius * cos(angle), box.size.y * 0.5, radius * sin(angle))
		instance.rotation.y = angle
		add_child(instance)
