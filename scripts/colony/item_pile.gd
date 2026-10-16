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
## Set when the pile's items merged into another pile on landing — guards
## the double-report between DelveSim.tick's logical landing and this
## node's visual fall emitting `landed` on the same arrival.
var merged := false

var _material: ShaderMaterial
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


## The forbidden mark's shared resources — one thin bar, instanced twice
## at ±45° into an X hovering just over the pile's surface.
static var _mark_bar: BoxMesh = null
static var _mark_all: StandardMaterial3D = null
static var _mark_part: StandardMaterial3D = null


static func _forbidden_bar() -> BoxMesh:
	if _mark_bar == null:
		_mark_bar = BoxMesh.new()
		_mark_bar.size = Vector3(0.55, 0.045, 0.15)
	return _mark_bar


## Solid red for an all-locked pile, amber for a mixed flag — unshaded
## and translucent like the colony's other markers.
static func _forbidden_material(all: bool) -> StandardMaterial3D:
	if all:
		if _mark_all == null:
			_mark_all = StandardMaterial3D.new()
			_mark_all.albedo_color = Color(0.9, 0.12, 0.08, 0.9)
			_mark_all.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_mark_all.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		return _mark_all
	if _mark_part == null:
		_mark_part = StandardMaterial3D.new()
		_mark_part.albedo_color = Color(0.95, 0.55, 0.1, 0.8)
		_mark_part.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mark_part.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _mark_part


## Re-draws the forbidden X over the pile — called from _flush_mesh so
## every content change re-reads the flags, and by set_pile_forbidden
## where only the flags moved. Red when nothing inside is claimable,
## amber when only part is forbidden.
func _refresh_forbidden_mark() -> void:
	var locked := 0
	var open := 0
	for item in items:
		if item.forbidden:
			locked += item.volume
		else:
			open += item.volume
	var mark: Node3D = get_node_or_null("ForbiddenMark")
	if locked == 0:
		if mark != null:
			mark.queue_free()
		return
	if mark == null:
		mark = Node3D.new()
		mark.name = "ForbiddenMark"
		for side in [-1.0, 1.0]:
			var bar := MeshInstance3D.new()
			bar.mesh = _forbidden_bar()
			bar.rotation.y = side * PI / 4.0
			mark.add_child(bar)
		add_child(mark)
	var fill := minf(float(total_volume()) / FULL_CM3, 1.0)
	mark.position = Vector3(0.0, fill + 0.07, 0.0)
	var material := _forbidden_material(open == 0)
	for child in mark.get_children():
		(child as MeshInstance3D).material_override = material


static func create(position: Vector3i, physics := true) -> ItemPile:
	var pile := ItemPile.new()
	pile.voxel_position = position
	pile.position = Vector3(position) + Vector3(0.5, 0.0, 0.5)
	pile.set_process(false)

	# The pile's fill is its floor: a box as tall as the piled volume, so
	# units stand on the pile top and a packed voxel blocks like a block.
	# Only the move_and_slide fallback needs it — under DelveSim, unit
	# support comes from pile_fill and a live body just adds broadphase
	# pairs for every moving unit to test against.
	if physics:
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


func _exit_tree() -> void:
	# Drop any registered fall — a pile freed mid-flight never lands.
	var colony := get_parent() as Colony
	if colony != null and colony.world != null and colony.world.sim != null:
		colony.world.sim.pile_fall_cancel(get_instance_id())


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


## True when the pile fills its voxel — it renders as a solid block and
## the voxel is impassible. [param capacity] is the voxel's capacity, one
## cubic metre normally — a cell shared with a ladder tops out lower.
func is_full(capacity: int = FULL_CM3) -> bool:
	return total_volume() >= capacity


## True when at least one item in the pile isn't forbidden — the
## haul-eligibility check: an all-forbidden pile is un-touchable.
func has_takeable() -> bool:
	for item in items:
		if not item.forbidden:
			return true
	return false


## The material class of the pile's contents, or NONE when empty.
func material_class() -> BlockRegistry.Resource_:
	return items[0].material if not items.is_empty() else BlockRegistry.Resource_.NONE


## Total item volume in cubic centimetres.
func total_volume() -> int:
	var total := 0
	for item in items:
		total += item.volume
	return total


## Volume of loose-form items — the pourable fraction that compacts into
## a floor underfoot (soil, gravel, sawdust, tailings). Only this fill
## raises footing.
func loose_volume() -> int:
	var total := 0
	for item in items:
		if item.form == DropItem.Form.LOOSE:
			total += item.volume
	return total


## Volume of discrete items — the clutter fraction: boxes, rocks and
## bodies are walked through slowly when sparse and block the cell when
## dense, but never raise its floor.
func clutter_volume() -> int:
	return total_volume() - loose_volume()


## True when the heap is dense enough to stand in the way — most of the
## voxel choked with discrete goods. A dense heap is walked around, not
## through, and soaks melee stray-blows as flimsy cover.
func is_dense() -> bool:
	return clutter_volume() >= DropItem.CLUTTER_BLOCK_CM3


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


## Removes and returns the smallest non-forbidden item — the clear
## job's shovel pick: forbidden items stay put.
func take_smallest_allowed() -> DropItem:
	var best := -1
	for i in items.size():
		if items[i].forbidden:
			continue
		if best < 0 or items[i].volume < items[best].volume:
			best = i
	if best < 0:
		return null
	var item := items[best]
	items.remove_at(best)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return item


## Removes items totalling up to [param amount] cm³ and returns them —
## whole items that fit, smallest first; when nothing whole fits the
## remainder, a loose item is split down to size. [param admit], when
## given, filters which items may be taken — stockpile hauls use it to
## carry only what the destination tile stores. Forbidden items refuse
## unless [param include_forbidden] — the flag binds settlers, not the
## animals that ignore it.
##
## [param lift_kg] is the mass-bound take path: a discrete item too big
## for the volume budget still leaves when its mass fits the remaining
## lift kilograms (a log is dragged, not carried). Dragged items spend
## lift, not volume.
func take_up_to(
	amount: int, admit: Callable = Callable(), include_forbidden := false,
	lift_kg := 0.0
) -> Array[DropItem]:
	var taken: Array[DropItem] = []
	var remaining := amount
	var lift := lift_kg
	while remaining > 0 and not items.is_empty():
		var best := -1
		for i in items.size():
			if (
				(items[i].forbidden and not include_forbidden)
				or (admit.is_valid() and not admit.call(items[i]))
			):
				continue
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
			if (
				(items[i].forbidden and not include_forbidden)
				or (admit.is_valid() and not admit.call(items[i]))
			):
				continue
			if items[i].form == DropItem.Form.LOOSE and (loose < 0 or items[i].volume < items[loose].volume):
				loose = i
		if loose >= 0:
			var item := items[loose]
			var part := mini(remaining, item.volume)
			item.volume -= part
			if item.volume <= 0:
				items.remove_at(loose)
			var split := DropItem.new(item.material, item.form, part)
			split.species = item.species
			split.forbidden = item.forbidden
			# A sliver of a mixed pile keeps the whole record —
			# nutrition, craft and provenance — same fields the
			# container split preserves.
			split.made_of = item.made_of.duplicate()
			split.made_by = item.made_by
			split.nutrition = item.nutrition
			split.quality = item.quality
			taken.append(split)
			break
		# Nor a loose sliver — the last resort is a drag take: a discrete
		# item over the volume budget goes home anyway while its mass
		# fits what the unit can move.
		var drag := -1
		if lift > 0.0:
			for i in items.size():
				var item := items[i]
				if (
					item.form == DropItem.Form.LOOSE
					or (item.forbidden and not include_forbidden)
					or (admit.is_valid() and not admit.call(item))
				):
					continue
				if item.mass_kg() <= lift and (drag < 0 or item.mass_kg() < items[drag].mass_kg()):
					drag = i
		if drag < 0:
			break
		var dragged := items[drag]
		items.remove_at(drag)
		lift -= dragged.mass_kg()
		taken.append(dragged)
	if not taken.is_empty():
		fill_changed.emit(self)
	if is_inside_tree() and not taken.is_empty():
		_rebuild_mesh()
	return taken


## The distinct material classes the pile holds — the queries that pick a
## stockpile for it filter on this set.
func materials() -> Array:
	var found: Array = []
	for item in items:
		if not found.has(item.material):
			found.append(item.material)
	return found


## The material classes of the pile's non-forbidden items — the
## destination pick for a haul: a pile holding only forbidden goods
## wants no destination at all. A filled container offers its freight's
## classes — a sack of stone wants a stone tile, not a cloth one.
func takeable_materials() -> Array:
	var found: Array = []
	for item in items:
		if item.forbidden:
			continue
		if item.is_container() and not item.stored.is_empty():
			for material in item.content_materials():
				if not found.has(material):
					found.append(material)
		elif not found.has(item.material):
			found.append(item.material)
	return found


## The cheapest thing a grab from this pile could yield — the smallest
## takeable non-loose item's volume, or 0 when nothing but loose goods
## qualifies (loose material pours into whatever room exists, so it
## never raises a stockpile's floor). [param mats] scopes "takeable" to
## the materials a destination query advertises — the same container
## rule as [method takeable_materials]: a filled sack offers its
## freight's materials, not its cloth.
func smallest_takeable_volume(mats: Array) -> int:
	var floor := 0
	for item in items:
		if item.forbidden or item.form == DropItem.Form.LOOSE:
			continue
		if not mats.is_empty():
			var offered: Array = (
				item.content_materials()
				if item.is_container() and not item.stored.is_empty()
				else [item.material]
			)
			var listed := false
			for material in offered:
				if mats.has(material):
					listed = true
					break
			if not listed:
				continue
		if floor == 0 or item.volume < floor:
			floor = item.volume
	return floor


## Volume of items of [param form] in the pile — the craft-input query.
func form_volume(form: DropItem.Form) -> int:
	var total := 0
	for item in items:
		if item.form == form:
			total += item.volume
	return total


## Removes and returns the smallest item of [param form], or null when the
## pile holds none or the smallest exceeds [param cap] cm³ — an item the
## unit can't lift stays in the pile unless its mass comes under
## [param lift_kg], in which case it leaves as a drag.
func take_form(form: DropItem.Form, cap: int, lift_kg := 0.0) -> DropItem:
	var best := -1
	for i in items.size():
		if items[i].form != form or items[i].forbidden:
			continue
		if items[i].volume <= cap and (best < 0 or items[i].volume < items[best].volume):
			best = i
	if best >= 0:
		var item := items[best]
		items.remove_at(best)
		fill_changed.emit(self)
		if is_inside_tree():
			_rebuild_mesh()
		return item
	if lift_kg <= 0.0:
		return null
	best = -1
	for i in items.size():
		var item := items[i]
		if item.form != form or item.forbidden:
			continue
		if item.mass_kg() <= lift_kg and (best < 0 or item.mass_kg() < items[best].mass_kg()):
			best = i
	if best < 0:
		return null
	var item := items[best]
	items.remove_at(best)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return item


## Removes and returns the first non-forbidden container whose stored
## goods [param want] accepts — the fetch path's pick: a sack holding
## what the job needs leaves whole, contents and all. With no
## [param want] the first container answers — the hauler's grab.
func take_container(want: Callable = Callable()) -> DropItem:
	for i in items.size():
		var item := items[i]
		if item.forbidden or not item.is_container():
			continue
		if want.is_valid() and not item.container_has(want):
			continue
		items.remove_at(i)
		fill_changed.emit(self)
		if is_inside_tree():
			_rebuild_mesh()
		return item
	return null


## Removes [param item] from the pile and returns it — the bag-grab's
## take: the caller already picked which container leaves.
func take_item(item: DropItem) -> DropItem:
	if not items.has(item):
		return null
	items.erase(item)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return item


## True when a non-forbidden container in the pile holds something
## [param want] accepts — the fetch-voxel queries' peek, so a sack of
## cobbles advertises its stone rather than sitting invisible.
func has_container_with(want: Callable) -> bool:
	for item in items:
		if (
			not item.forbidden
			and item.is_container()
			and item.container_has(want)
		):
			return true
	return false


## Moves pile items into [param container] until it's full — the haul
## fetch's pack-at-source: a sack in hand scoops whatever the pile has
## that the container accepts and the destination [param admit] filter
## allows. Whole items go in under both the container's room and the
## remaining [param lift_kg]; loose material shaves down to fit both.
## Returns the cm³ moved.
func fill_container(
	container: DropItem, admit: Callable = Callable(), lift_kg := 0.0
) -> int:
	var moved := 0
	var lift := lift_kg
	var room := container.container_room()
	while room > 0 and not items.is_empty():
		var best := -1
		for i in items.size():
			var item := items[i]
			if (
				item.forbidden
				or item.form == DropItem.Form.LOOSE
				or item.volume > room
				or item.mass_kg() > lift
				or not container.container_accepts(item)
				or (admit.is_valid() and not admit.call(item))
			):
				continue
			if best < 0 or item.volume > items[best].volume:
				best = i
		if best >= 0:
			var item := items[best]
			items.remove_at(best)
			container.container_insert(item)
			room -= item.volume
			lift -= item.mass_kg()
			moved += item.volume
			continue
		# Nothing whole fits — a loose item shaves down to whatever the
		# container's room and the lift allowance both leave.
		var loose := -1
		for i in items.size():
			var item := items[i]
			if (
				item.form != DropItem.Form.LOOSE
				or item.forbidden
				or not container.container_accepts(item)
				or (admit.is_valid() and not admit.call(item))
			):
				continue
			if loose < 0 or item.volume < items[loose].volume:
				loose = i
		if loose < 0:
			break
		var src := items[loose]
		var fit := mini(
			room,
			int(lift * 1000.0 / BlockRegistry.density_of(src.material))
		)
		var part := mini(fit, src.volume)
		if part <= 0:
			break
		var split := DropItem.new(src.material, src.form, part)
		split.species = src.species
		# Packed goods keep their provenance — the maker and recipe
		# inputs ride the split into the crate.
		split.made_of = src.made_of.duplicate()
		split.made_by = src.made_by
		src.volume -= part
		if src.volume <= 0:
			items.remove_at(loose)
		container.container_insert(split)
		moved += part
		break
	if moved > 0:
		fill_changed.emit(self)
		if is_inside_tree():
			_rebuild_mesh()
	return moved


## Removes and returns the first item of [param form] matching
## [param spec], or null — the crate fetch's query. Crates are
## drag-hauled: no volume cap applies, the unit's mass limit decides.
func take_spec_item(form: DropItem.Form, spec: StringName) -> DropItem:
	for i in items.size():
		var item := items[i]
		if item.form == form and item.spec == spec and not item.forbidden:
			items.remove_at(i)
			fill_changed.emit(self)
			if is_inside_tree():
				_rebuild_mesh()
			return item
	return null


## True when the pile holds a non-forbidden item of [param form] with
## [param spec] — the crate-fetch index query.
func has_spec_item(form: DropItem.Form, spec: StringName) -> bool:
	for item in items:
		if item.form == form and item.spec == spec and not item.forbidden:
			return true
	return false


## Removes and returns the smallest seed packet of [param species], or
## null — the sow job's fetch query. Seeds are discrete items and never
## split: the unit plants the packet whole.
func take_seed(species: StringName) -> DropItem:
	var best := -1
	for i in items.size():
		var item := items[i]
		if (
			item.form != DropItem.Form.SEED
			or item.species != species
			or item.forbidden
		):
			continue
		if best < 0 or item.volume < items[best].volume:
			best = i
	if best < 0:
		return null
	var seed := items[best]
	items.remove_at(best)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return seed


## Removes and returns the least-worn tool whose class is in
## [param classes], or null — the fetch query for a job that wants an
## axe, a pick, or either digging tool. Worn-out shells stay: a 0-wear
## stone head is litter, not equipment.
func take_tool(classes: Array) -> DropItem:
	var best := -1
	for i in items.size():
		var item := items[i]
		if (
			item.form != DropItem.Form.TOOL
			or item.forbidden
			or not classes.has(DropItem.tool_class(item))
			or item.wear <= 0.0
		):
			continue
		if best < 0 or item.wear > items[best].wear:
			best = i
	if best < 0:
		return null
	var tool := items[best]
	items.remove_at(best)
	fill_changed.emit(self)
	if is_inside_tree():
		_rebuild_mesh()
	return tool


## Volume of pile items that can serve as [param material]'s wall recipe —
## only forms still missing ([param need] is form → cm³ wanted). With no
## material committed (NONE) every wall-eligible item counts. Solid items
## larger than their form's missing volume don't count: they can't go in.
## [param include_forbidden] counts forbidden goods too — diagnostics only,
## the fetch itself never touches them.
func wall_need_volume(
	material: BlockRegistry.Resource_, need: Dictionary,
	include_forbidden := false
) -> int:
	var total := 0
	for item in items:
		if item.forbidden and not include_forbidden:
			continue
		total += _wall_want_volume(item, material, need)
		if item.is_container():
			# Goods inside a bag count — the fetch can carry the whole
			# sack. A furniture crate's `packed` never counts: that's
			# the piece itself, not wall stock.
			for inner in item.stored:
				total += _wall_want_volume(inner, material, need)
	return total


## One item's contribution to [method wall_need_volume] — its volume
## when it can serve the remaining wall recipe, else 0.
func _wall_want_volume(
	item: DropItem, material: BlockRegistry.Resource_, need: Dictionary
) -> int:
	if material == BlockRegistry.Resource_.NONE:
		return (
			item.volume
			if BlockRegistry.item_fits_wall(item, material)
			else 0
		)
	if item.form == DropItem.Form.LOOSE:
		if item.material != material:
			return 0
	elif not BlockRegistry.material_fits(int(item.material), int(material)):
		return 0
	var want := int(need.get(item.form, 0))
	if want <= 0 or (item.form != DropItem.Form.LOOSE and item.volume > want):
		return 0
	return item.volume


## Removes items serving as [param material]'s wall recipe, capped at
## [param cap] cm³ and [param need] — the forms and volumes still missing.
## Loose material splits down to the exact missing volume; solid items
## leave whole and only when they fit a form's missing volume — a wall
## absorbs exactly its recipe, so there is no overshoot to return.
func take_wall(
	material: BlockRegistry.Resource_, need: Dictionary, cap: int, lift_kg := 0.0
) -> Array[DropItem]:
	var taken: Array[DropItem] = []
	if cap <= 0:
		return taken
	var loose_need := int(need.get(DropItem.Form.LOOSE, 0))
	if loose_need > 0:
		var got := take_loose(material, mini(loose_need, cap))
		if got > 0:
			taken.append(DropItem.new(material, DropItem.Form.LOOSE, got))
			cap -= got
			need[DropItem.Form.LOOSE] = loose_need - got
	var got_volume := 0
	var lift := lift_kg
	while true:
		var best := -1
		for i in items.size():
			var item := items[i]
			if (
				not BlockRegistry.material_fits(int(item.material), int(material))
				or item.form == DropItem.Form.LOOSE
				or item.forbidden
			):
				continue
			var want := int(need.get(item.form, 0))
			# A whole item over the trip's volume budget still goes when
			# its mass fits the lift allowance — dragged, not carried —
			# and spends lift kilograms rather than cap.
			var mass := item.mass_kg()
			if item.volume > want or (got_volume + item.volume > cap and mass > lift):
				continue
			if best < 0 or item.volume > items[best].volume:
				best = i
		if best < 0:
			break
		var item := items[best]
		taken.append(item)
		if got_volume + item.volume > cap:
			lift -= item.mass_kg()
		else:
			got_volume += item.volume
		need[item.form] = int(need[item.form]) - item.volume
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
		if (
			item.material != material
			or item.form != DropItem.Form.LOOSE
			or item.forbidden
		):
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
	# The mark's bars are grandchildren, not touched by the purge above —
	# it stays a named Node3D child and re-reads the flags each flush.
	_refresh_forbidden_mark()
	if items.is_empty():
		return

	if _material == null:
		_material = SliceView.opaque(Color.WHITE)
	_material.set_shader_parameter(
		&"albedo", BlockRegistry.resource_color(material_class())
	)

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

	# The pile is a floor for the sim at its loose-fill height — draw the
	# mound slab up to it so a unit standing on the pile isn't floating
	# over a scatter that only reaches the bottom of the voxel. Clutter
	# raises no footing: discrete items draw loose on top of the slab.
	var fill_frac := clampf(float(loose_volume()) / DropItem.CM3_PER_M3, 0.0, 0.99)
	var mound_h := fill_frac * 0.94
	var mound := MeshInstance3D.new()
	mound.mesh = _box()
	mound.scale = Vector3(0.94, mound_h, 0.94)
	mound.material_override = _material
	mound.position = Vector3(0.0, mound_h * 0.5, 0.0)
	add_child(mound)

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
		elif item.form == DropItem.Form.PLANK:
			dims = Vector3(side * 1.9, side * 0.3, side * 0.45)
		var radius := 0.42 * sqrt((i + 0.5) / sorted.size())
		var angle := i * golden_angle
		# Items sit on the mound — heaped material reaching its surface.
		var transform := Transform3D(
			Basis(Vector3.UP, angle).scaled(dims),
			Vector3(radius * cos(angle), mound_h + dims.y * 0.5, radius * sin(angle))
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


## Resizes the pile's collision box to its loose fill: the pourable
## fraction is the floor a fallback-physics unit stands on — clutter
## never raises footing. Empty piles keep a token 5 cm slab.
func _update_fill_collision() -> void:
	if _fill_shape == null:
		return
	var fill := clampf(float(loose_volume()) / DropItem.CM3_PER_M3, 0.05, 1.0)
	(_fill_shape.shape as BoxShape3D).size = Vector3(1.0, fill, 1.0)
	_fill_shape.position = Vector3(0.0, fill * 0.5, 0.0)
