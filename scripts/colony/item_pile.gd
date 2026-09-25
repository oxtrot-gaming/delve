class_name ItemPile
extends Node3D

## A heap of loose items sitting in the world where a block was mined.
## Spawned by [Colony.drop_block]; a haul job will eventually carry these
## to the stockpile.

## Emitted when a visual fall ends and the pile reaches the floor of
## [member voxel_position].
signal landed(pile: ItemPile)

## Emitted whenever the pile's contents change — Colony mirrors fill into
## the native sim so packed voxels block its fill-aware pathfinding.
signal fill_changed(pile: ItemPile)

## Downward acceleration of a falling pile, m/s².
const FALL_GRAVITY := 30.0
## Terminal speed of a falling pile, m/s.
const FALL_SPEED_MAX := 25.0
## Freshly dropped items fall in from about this far above their slot.
const DROP_IN_HEIGHT := 1.2
## A pile at or over this volume is packed solid — a full cubic metre.
const FULL_CM3 := DropItem.BLOCK_CM3

var voxel_position: Vector3i
var items: Array[DropItem] = []

var _material: StandardMaterial3D
var _fill_shape: CollisionShape3D
var _fall_target_y := NAN
var _fall_speed := 0.0
## Item-mesh rebuilds are deferred to once per frame: a mined drop deposits
## up to ~40 items, and rebuilding per deposit is quadratic in the pile's
## size. The dirty flag collapses a whole burst into one rebuild.
var _mesh_dirty := false
var _pending_drop_in: Array[DropItem] = []

## The item scatter's one-node-per-pile renderer — a MultiMesh means a
## 40-item pile is a single draw call, not forty MeshInstance3D children.
## Cleared on every flush; packed piles use a plain cube instead.
var _scatter: MultiMeshInstance3D = null
## Resting transform, drop height, elapsed and duration per instance
## index — drop-ins animate by rewriting those instances' transforms.
var _drop_anims: Dictionary = {}  # int -> {t: Transform3D, h: float, e: float, d: float}

## One shared unit-cube mesh for every item box — the instance's scale
## carries the item's size, so deposits never allocate new mesh resources.
static var _box_mesh: BoxMesh = null


static func _box() -> BoxMesh:
	if _box_mesh == null:
		_box_mesh = BoxMesh.new()
	return _box_mesh


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
	fill_changed.emit(self)
	if not is_inside_tree():
		return
	var dropped: Array[DropItem] = []
	if animate:
		dropped.append_array(new_items)
	_rebuild_mesh(dropped)


## Adds a single [param item] onto the pile and rebuilds its mesh.
func add_item(item: DropItem, animate := true) -> void:
	items.append(item)
	fill_changed.emit(self)
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
	var busy := false
	if not is_nan(_fall_target_y):
		_fall_speed = minf(_fall_speed + FALL_GRAVITY * delta, FALL_SPEED_MAX)
		position.y -= _fall_speed * delta
		if position.y <= _fall_target_y:
			position.y = _fall_target_y
			_fall_target_y = NAN
			_fall_speed = 0.0
			landed.emit(self)
		else:
			busy = true
	if not _drop_anims.is_empty():
		_tick_drop_in(delta)
		busy = true
	if not busy:
		set_process(false)


## Advances drop-in animations: each animating instance descends on a
## quadratic ease-in, then snaps to rest.
func _tick_drop_in(delta: float) -> void:
	if _scatter == null or _scatter.multimesh == null:
		_drop_anims.clear()
		return
	var mm := _scatter.multimesh
	var done: Array[int] = []
	for index in _drop_anims:
		var anim: Dictionary = _drop_anims[index]
		anim["e"] += delta
		var k := minf(anim["e"] / anim["d"], 1.0)
		var t: Transform3D = anim["t"]
		t.origin.y += anim["h"] * (1.0 - k) * (1.0 - k)
		mm.set_instance_transform(index, t)
		if k >= 1.0:
			done.append(index)
	for index in done:
		_drop_anims.erase(index)


## True when the pile fills the whole voxel — it renders as a solid block
## and the voxel is impassible.
func is_full() -> bool:
	return total_volume() >= FULL_CM3


## The material class of the pile's contents, or NONE when empty.
func material_class() -> BlockRegistry.Resource_:
	return items[0].material if not items.is_empty() else BlockRegistry.Resource_.NONE


## Total item volume in cubic centimetres.
func total_volume() -> int:
	var total := 0
	for item in items:
		total += item.volume
	return total


## The index of the smallest item in the pile, or -1 when empty.
func _smallest_index() -> int:
	var smallest := -1
	for i in items.size():
		if smallest < 0 or items[i].volume < items[smallest].volume:
			smallest = i
	return smallest


## The smallest item in the pile, or null when empty. The pile is unchanged.
func smallest_item() -> DropItem:
	var i := _smallest_index()
	return items[i] if i >= 0 else null


## Removes and returns the smallest item in the pile, or null when empty.
func take_smallest() -> DropItem:
	var i := _smallest_index()
	if i < 0:
		return null
	var item := items[i]
	items.remove_at(i)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return item


## Removes items totalling up to [param amount] cm³ and returns them —
## whole items that fit, smallest first; when nothing whole fits the
## remainder, a loose item is split down to size.
func take_up_to(amount: int) -> Array[DropItem]:
	var taken: Array[DropItem] = []
	var remaining := amount
	while remaining > 0 and not items.is_empty():
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
		var part := mini(remaining, item.volume)
		item.volume -= part
		if item.volume <= 0:
			items.remove_at(loose)
		taken.append(DropItem.new(item.material, item.form, part))
		break
	if not taken.is_empty():
		fill_changed.emit(self)
	if is_inside_tree() and not taken.is_empty():
		_rebuild_mesh()
	return taken


## Volume of items in the pile usable as wall material [param material]
## — or of every wall material combined when NONE.
func wall_volume(material: BlockRegistry.Resource_) -> int:
	var total := 0
	for item in items:
		if BlockRegistry.item_fits_wall(item, material):
			total += item.volume
	return total


## Removes items serving as wall material [param material]: loose
## material splits down to the exact volume; solid items leave whole,
## biggest fitting [param cap] first, for as long as the take stays under
## [param need] — the last item may overshoot it, since a wall consumes
## "at least" its required volume.
func take_wall(material: BlockRegistry.Resource_, need: int, cap: int) -> Array[DropItem]:
	var taken: Array[DropItem] = []
	if cap <= 0:
		return taken
	if material == BlockRegistry.Resource_.SOIL:
		var got := take_loose(material, mini(need, cap))
		if got > 0:
			taken.append(DropItem.new(material, DropItem.Form.LOOSE, got))
		return taken
	var got := 0
	while got < need:
		var best := -1
		for i in items.size():
			var item := items[i]
			if not BlockRegistry.item_fits_wall(item, material):
				continue
			if got + item.volume > cap:
				continue
			if best < 0 or item.volume > items[best].volume:
				best = i
		if best < 0:
			break
		taken.append(items[best])
		got += items[best].volume
		items.remove_at(best)
	if not taken.is_empty():
		fill_changed.emit(self)
	if is_inside_tree() and not taken.is_empty():
		_rebuild_mesh()
	return taken


## True when the pile holds at least one loose item of [param material].
func has_loose(material: BlockRegistry.Resource_) -> bool:
	for item in items:
		if item.material == material and item.form == DropItem.Form.LOOSE:
			return true
	return false


## Removes up to [param amount] cm³ of loose [param material] — splitting the
## smallest matching item so only what's needed leaves — and returns the
## volume actually taken.
func take_loose(material: BlockRegistry.Resource_, amount: int) -> int:
	var best := -1
	for i in items.size():
		var item := items[i]
		if item.material != material or item.form != DropItem.Form.LOOSE:
			continue
		if best < 0 or item.volume < items[best].volume:
			best = i
	if best < 0:
		return 0
	var item := items[best]
	var taken := mini(amount, item.volume)
	item.volume -= taken
	if item.volume <= 0:
		items.remove_at(best)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return taken


## Schedules the item scatter to be rebuilt — batched to once per frame,
## so a burst of deposits costs one rebuild instead of one per item. The
## collision box still updates immediately: logic reads fill, not meshes.
func _rebuild_mesh(animate_in: Array[DropItem] = []) -> void:
	_pending_drop_in.append_array(animate_in)
	_update_fill_collision()
	if _mesh_dirty:
		return
	_mesh_dirty = true
	_flush_mesh.call_deferred()


## Rebuilds the item scatter — runs at most once per frame.
func _flush_mesh() -> void:
	_mesh_dirty = false
	var animate_in := _pending_drop_in
	_pending_drop_in = []
	for child in get_children():
		if child is MeshInstance3D or child is MultiMeshInstance3D:
			child.queue_free()
	_scatter = null
	_drop_anims.clear()
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
		var cube := MeshInstance3D.new()
		cube.mesh = _box()
		cube.scale = Vector3.ONE * 0.98
		cube.material_override = _material
		cube.position = Vector3(0.0, 0.5, 0.0)
		add_child(cube)
		return

	var sorted := items.duplicate()
	sorted.sort_custom(func(a: DropItem, b: DropItem) -> bool: return a.volume > b.volume)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _box()
	mm.instance_count = sorted.size()
	_scatter = MultiMeshInstance3D.new()
	_scatter.multimesh = mm
	_scatter.material_override = _material
	add_child(_scatter)
	var golden_angle := PI * (3.0 - sqrt(5.0))
	for i in sorted.size():
		var item: DropItem = sorted[i]
		var side := clampf(pow(float(item.volume) / DropItem.CM3_PER_M3, 1.0 / 3.0) * 0.85, 0.08, 0.9)
		var dims := Vector3.ONE * side
		if item.form == DropItem.Form.LOOSE:
			dims = Vector3(side * 1.35, side * 0.6, side * 1.35)
		elif item.form == DropItem.Form.LOG:
			dims = Vector3(side * 1.9, side * 0.55, side * 0.55)
		var radius := 0.42 * sqrt((i + 0.5) / sorted.size())
		var angle := i * golden_angle
		var transform := Transform3D(
			Basis(Vector3.UP, angle).scaled(dims),
			Vector3(radius * cos(angle), dims.y * 0.5, radius * sin(angle))
		)
		mm.set_instance_transform(i, transform)
		if animate_in.has(item):
			_drop_anims[i] = {
				"t": transform,
				"h": randf_range(0.8, 1.4) * DROP_IN_HEIGHT,
				"e": 0.0,
				"d": randf_range(0.25, 0.45),
			}
	if not _drop_anims.is_empty():
		set_process(true)


## Resizes the pile's collision box to its fill: a flat surface across the
## whole voxel rising to the piled height (a full cubic metre fills the
## voxel). Empty piles keep a token 5 cm slab.
func _update_fill_collision() -> void:
	if _fill_shape == null:
		return
	var fill := clampf(float(total_volume()) / DropItem.CM3_PER_M3, 0.05, 1.0)
	(_fill_shape.shape as BoxShape3D).size = Vector3(1.0, fill, 1.0)
	_fill_shape.position = Vector3(0.0, fill * 0.5, 0.0)
