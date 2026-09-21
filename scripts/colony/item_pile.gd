class_name ItemPile
extends Node3D

## A heap of loose items sitting in the world where a block was mined.
## Spawned by [Colony.drop_block]; a haul job will eventually carry these
## to the stockpile.

## Emitted when a visual fall ends and the pile reaches the floor of
## [member voxel_position].
signal landed(pile: ItemPile)

## Downward acceleration of a falling pile, m/s².
const FALL_GRAVITY := 30.0
## Terminal speed of a falling pile, m/s.
const FALL_SPEED_MAX := 25.0
## Freshly dropped items fall in from about this far above their slot.
const DROP_IN_HEIGHT := 1.2
## Fill within this of a full cubic metre counts as packed solid.
const FULL_EPSILON := 0.001

var voxel_position: Vector3i
var items: Array[DropItem] = []

var _material: StandardMaterial3D
var _fill_shape: CollisionShape3D
var _fall_target_y := NAN
var _fall_speed := 0.0


static func create(position: Vector3i) -> ItemPile:
	var pile := ItemPile.new()
	pile.voxel_position = position
	pile.position = Vector3(position) + Vector3(0.5, 0.0, 0.5)
	pile.set_process(false)

	# The pile's fill is its floor: a box as tall as the piled volume, so
	# units stand on the pile top and a packed voxel blocks like a block.
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 0.05
	shape.shape = box
	body.add_child(shape)
	pile.add_child(body)
	pile._fill_shape = shape
	return pile


## Adds [param new_items] onto the pile and rebuilds its mesh. Unless
## [param animate] is false, the new items drop in from above the pile.
func add_items(new_items: Array[DropItem], animate := true) -> void:
	items.append_array(new_items)
	if not is_inside_tree():
		return
	var dropped: Array[DropItem] = []
	if animate:
		dropped.append_array(new_items)
	_rebuild_mesh(dropped)


## Adds a single [param item] onto the pile and rebuilds its mesh.
func add_item(item: DropItem, animate := true) -> void:
	items.append(item)
	if not is_inside_tree():
		return
	var dropped: Array[DropItem] = []
	if animate:
		dropped.append(item)
	_rebuild_mesh(dropped)


## Starts or retargets a visual fall toward [param target_y], the floor of the
## voxel the pile is settling into. The logical voxel has already moved; this
## only animates the node, which emits [signal landed] on arrival.
func fall_to(target_y: float) -> void:
	_fall_target_y = target_y
	set_process(true)


func _process(delta: float) -> void:
	if is_nan(_fall_target_y):
		set_process(false)
		return
	_fall_speed = minf(_fall_speed + FALL_GRAVITY * delta, FALL_SPEED_MAX)
	position.y -= _fall_speed * delta
	if position.y <= _fall_target_y:
		position.y = _fall_target_y
		_fall_target_y = NAN
		_fall_speed = 0.0
		set_process(false)
		landed.emit(self)


## True when the pile fills the whole voxel — it renders as a solid block
## and the voxel is impassible.
func is_full() -> bool:
	return total_volume() >= 1.0 - FULL_EPSILON


## The material class of the pile's contents, or NONE when empty.
func material_class() -> BlockRegistry.Resource_:
	return items[0].material if not items.is_empty() else BlockRegistry.Resource_.NONE


func total_volume() -> float:
	var total := 0.0
	for item in items:
		total += item.volume
	return total


## Removes and returns the smallest item in the pile, or null when empty.
func take_smallest() -> DropItem:
	if items.is_empty():
		return null
	var smallest := 0
	for i in items.size():
		if items[i].volume < items[smallest].volume:
			smallest = i
	var item := items[smallest]
	items.remove_at(smallest)
	if is_inside_tree():
		_rebuild_mesh()
	return item


## Removes items totalling up to [param amount] m³ and returns them —
## whole items that fit, smallest first; when nothing whole fits the
## remainder, a loose item is split down to size.
func take_up_to(amount: float) -> Array[DropItem]:
	var taken: Array[DropItem] = []
	var remaining := amount
	while remaining > 0.0001 and not items.is_empty():
		var best := -1
		for i in items.size():
			if items[i].volume <= remaining and (best < 0 or items[i].volume < items[best].volume):
				best = i
		if best >= 0:
			var item := items[best]
			items.remove_at(best)
			remaining -= item.volume
			taken.append(item)
			continue
		# Nothing whole fits — shave a loose item down to the remainder.
		var loose := -1
		for i in items.size():
			if items[i].form == DropItem.Form.LOOSE and (loose < 0 or items[i].volume < items[loose].volume):
				loose = i
		if loose < 0:
			break
		var item := items[loose]
		var part := minf(remaining, item.volume)
		item.volume -= part
		if item.volume < 0.0001:
			items.remove_at(loose)
		taken.append(DropItem.new(item.material, item.form, part))
		break
	if is_inside_tree() and not taken.is_empty():
		_rebuild_mesh()
	return taken


## True when the pile holds at least one loose item of [param material].
func has_loose(material: BlockRegistry.Resource_) -> bool:
	for item in items:
		if item.material == material and item.form == DropItem.Form.LOOSE:
			return true
	return false


## Removes up to [param amount] m³ of loose [param material] — splitting the
## smallest matching item so only what's needed leaves — and returns the
## volume actually taken.
func take_loose(material: BlockRegistry.Resource_, amount: float) -> float:
	var best := -1
	for i in items.size():
		var item := items[i]
		if item.material != material or item.form != DropItem.Form.LOOSE:
			continue
		if best < 0 or item.volume < items[best].volume:
			best = i
	if best < 0:
		return 0.0
	var item := items[best]
	var taken := minf(amount, item.volume)
	item.volume -= taken
	if item.volume < 0.0001:
		items.remove_at(best)
	if is_inside_tree():
		_rebuild_mesh()
	return taken


## Lays every item out as a small box scattered across the voxel floor,
## biggest first. Loose items are wide flat mounds; boulders and cobbles
## are chunky cubes. Items listed in [param animate_in] fall in from above
## their slot instead of appearing in place.
func _rebuild_mesh(animate_in: Array[DropItem] = []) -> void:
	for child in get_children():
		if child is MeshInstance3D:
			child.queue_free()
	_update_fill_collision()
	if items.is_empty():
		return

	if _material == null:
		_material = StandardMaterial3D.new()
		_material.roughness = 0.9
		_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_material.albedo_color = BlockRegistry.resource_color(material_class())

	if is_full():
		# Packed: the voxel is effectively solid, so draw it as a block —
		# slightly inset to avoid z-fighting with neighbouring voxel faces.
		var box := BoxMesh.new()
		box.size = Vector3.ONE * 0.98
		var cube := MeshInstance3D.new()
		cube.mesh = box
		cube.material_override = _material
		cube.position = Vector3(0.0, 0.5, 0.0)
		add_child(cube)
		return

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
		if animate_in.has(item):
			_drop_in(instance)


## Resizes the pile's collision box to its fill: a flat surface across the
## whole voxel rising to the piled height (a full cubic metre fills the
## voxel). Empty piles keep a token 5 cm slab.
func _update_fill_collision() -> void:
	if _fill_shape == null:
		return
	var fill := clampf(total_volume(), 0.05, 1.0)
	(_fill_shape.shape as BoxShape3D).size = Vector3(1.0, fill, 1.0)
	_fill_shape.position = Vector3(0.0, fill * 0.5, 0.0)


## Animates a freshly dropped item's mesh falling from above into its slot.
func _drop_in(instance: MeshInstance3D) -> void:
	var rest := instance.position
	instance.position = rest + Vector3(0.0, randf_range(0.8, 1.4) * DROP_IN_HEIGHT, 0.0)
	var tween := instance.create_tween()
	tween.tween_property(instance, "position:y", rest.y, randf_range(0.25, 0.45)) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
