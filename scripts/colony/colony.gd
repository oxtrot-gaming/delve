class_name Colony
extends Node3D

## Owns the colony state: the job board, the units and the stockpile.
##
## The player never mines directly; they designate work, units claim jobs
## from here and report back when the work is done.

signal job_added(job: ColonyJob)
signal job_finished(job: ColonyJob)
signal unit_spawned(unit: Unit)
signal item_dropped(pile: ItemPile)

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const DLog := preload("res://scripts/dlog.gd")

## How far an item may wander while spilling before it is forced to settle.
const MAX_SPILL_HOPS := 16
## Loose items smaller than this settle instead of splitting again.
const MIN_LOOSE_CM3 := 10_000
const SPILL_SIDES: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]
## How long a unit that dropped a job waits before claiming it again.
const DROPPED_JOB_RETRY_MSEC := 10000
## Cap on the escalating retry delay for a repeatedly failed target.
const DROPPED_JOB_RETRY_MAX_MSEC := 120000

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var initial_units: int = 3
## Radius, in voxels, of the area units spawn in around the colony origin.
@export var spawn_radius: int = 6

var world: VoxelWorld
var jobs: Array[ColonyJob] = []
## instance_id → ColonyJob: claim results resolve through this, and the
## native job board keys on the same ids.
var _job_index: Dictionary = {}
var units: Array[Unit] = []
## Loose resources lying in the world, keyed by the voxel they sit in or are
## falling toward.
var item_piles: Dictionary[Vector3i, ItemPile] = {}
## Piles falling onto a voxel that already has a pile — they merge into it
## when they land. Not keyed in [member item_piles] while in flight.
var _in_flight: Array[ItemPile] = []

## Voxels designated as stockpile tiles: haul destinations for loose items.
## Designated stockpile tiles — voxel → reject-set: a Dictionary of the
## material ints this tile refuses to store. An empty set admits
## everything, which is what a fresh designation means.
var stockpiles: Dictionary[Vector3i, Dictionary] = {}
## Constructed things, keyed by voxel: built wall blocks and worksites
## (the crafting spot — a designated place that needs no materials).
## Each record keeps what the construction was built from so it can be
## deconstructed into exactly those items and later rendered in its
## material. Voxel blocks alone can't carry that.
var buildings: Dictionary[Vector3i, Building] = {}
## Whether designation markers render — the HUD's zones toggle. The
## designations keep working either way.
var markers_visible := true
## Plan markers — pending build walls and deconstruct marks — render on a
## second switch, Timberborn-style: the HUD's Plans toggle, OR whenever a
## planning tool (a wall action or deconstruct) is in hand.
var plans_visible_manual := true
var _plans_tool_active := false
var _plan_voxels: Dictionary[Vector3i, bool] = {}

## Nearest-* searches walk rings of [member SPATIAL_BUCKET_SHIFT]-voxel
## columns outward from the query instead of scanning every entry — the
## colony plays in a bounded area, so a local hit exits after a ring or
## two. Members are kept in sync everywhere item_piles/stockpiles change.
const SPATIAL_BUCKET_SHIFT := 4
enum _Match { VETO, RETRY, FRESH }
var _pile_buckets: Dictionary = {}      # Vector2i -> Array[Vector3i]
var _stockpile_buckets: Dictionary = {} # Vector2i -> Array[Vector3i]

var _designation_markers: Dictionary[Vector3i, Node3D] = {}
var _marker_mesh: BoxMesh
var _outline_mesh: ImmediateMesh
var _marker_material: StandardMaterial3D
var _clear_marker_material: StandardMaterial3D
var _build_marker_material: StandardMaterial3D
var _stockpile_marker_material: StandardMaterial3D
var _craft_spot_marker_material: StandardMaterial3D
var _craft_job_marker_material: StandardMaterial3D
var _deconstruct_marker_material: StandardMaterial3D

## The world's growing trees — chop designations resolve through it.
var forest: Forest


func _ready() -> void:
	world = get_node(world_path)
	world.block_mined.connect(_on_block_mined)
	forest = Forest.new()
	forest.name = "Forest"
	add_child(forest)
	forest.setup(world, self)
	_marker_mesh = BoxMesh.new()
	_marker_mesh.size = Vector3.ONE * 1.02
	_outline_mesh = _make_outline_mesh()
	_marker_material = _make_marker_material(Color(1.0, 0.85, 0.2, 0.35))
	_clear_marker_material = _make_marker_material(Color(0.35, 0.85, 1.0, 0.35))
	_build_marker_material = _make_marker_material(Color(0.65, 0.4, 0.15, 0.35))
	_stockpile_marker_material = _make_marker_material(Color(0.5, 1.0, 0.55, 0.45))
	_craft_spot_marker_material = _make_marker_material(Color(0.75, 0.5, 0.95, 0.45))
	_craft_job_marker_material = _make_marker_material(Color(0.75, 0.5, 0.95, 0.5))
	_deconstruct_marker_material = _make_marker_material(Color(1.0, 0.35, 0.2, 0.45))


## The site's sim heartbeat: logical progress that must not depend on
## presentation. Pile-flight timing lives in DelveSim so a falling pile
## lands even when no ItemPile node is processing; node-driven `landed`
## emissions still arrive for rendered piles and are absorbed by the
## idempotency guard in _on_pile_landed.
func _physics_process(delta: float) -> void:
	if world == null or world.sim == null:
		return
	for pile_id in world.sim.tick(delta):
		var pile := instance_from_id(pile_id) as ItemPile
		if pile != null:
			_on_pile_landed(pile)


func _make_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


## A wireframe unit cube, centred at the origin — stockpile tiles get a
## faint outline rather than a filled box.
func _make_outline_mesh() -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var corners: Array[Vector3] = []
	for x in [-0.51, 0.51]:
		for y in [-0.51, 0.51]:
			for z in [-0.51, 0.51]:
				corners.append(Vector3(x, y, z))
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in corners.size():
		for j in range(i + 1, corners.size()):
			var d := (corners[i] - corners[j]).abs()
			if int(d.x > 0.0) + int(d.y > 0.0) + int(d.z > 0.0) == 1:
				mesh.surface_add_vertex(corners[i])
				mesh.surface_add_vertex(corners[j])
	mesh.surface_end()
	return mesh


## Queues a mining job, unless that voxel is already designated.
func designate_mine(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	if not world.is_solid(voxel_position):
		return null
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# Tree parts are felled whole — designate_chop instead.
		return null

	var job := ColonyJob.new(ColonyJob.Type.MINE, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _marker_material)
	DLog.log("designated mine %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a clearing job for a voxel holding items: a unit moves the whole
## pile into adjoining voxels. Only piles can be designated.
func designate_clear(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	var pile := item_pile_at(voxel_position)
	if pile == null or pile.items.is_empty():
		return null

	var job := ColonyJob.new(ColonyJob.Type.CLEAR, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _clear_marker_material)
	DLog.log("designated clear %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a wall build of the player's chosen [param material]: a unit
## fetches what that material's recipe needs from piles — loose soil, stone
## boulders and cobbles, or logs — and raises the block it makes (see
## [constant BlockRegistry.WALL_MATERIALS]). The voxel must be free of
## solid terrain, growing things and not packed full of items.
func designate_build(voxel_position: Vector3i, material: BlockRegistry.Resource_) -> ColonyJob:
	if not BlockRegistry.WALL_MATERIALS.has(material):
		return null
	if _designation_markers.has(voxel_position):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR or is_packed(voxel_position):
		return null
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# Sapling and leaf cells are air but claimed — a wall would entomb
		# the decoration and block the tree's growth.
		return null

	var job := ColonyJob.new(ColonyJob.Type.BUILD, voxel_position)
	job.material = material
	job.block_id = BlockRegistry.wall_block_for(material)
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated build %s" % voxel_position)
	job_added.emit(job)
	return job


## Marks a voxel as a stockpile tile — a haul destination for idle units.
## The voxel must be empty and rest on a solid block.
func designate_stockpile(voxel_position: Vector3i) -> bool:
	if _designation_markers.has(voxel_position):
		return false
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(voxel_position) > 0:
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	stockpiles[voxel_position] = {}
	_index_add(_stockpile_buckets, voxel_position)
	_add_marker(voxel_position, _stockpile_marker_material, _outline_mesh)
	return true


## Removes a stockpile designation; any items piled there stay put.
func undesignate_stockpile(voxel_position: Vector3i) -> bool:
	if not stockpiles.has(voxel_position):
		return false
	stockpiles.erase(voxel_position)
	_index_remove(_stockpile_buckets, voxel_position)
	_remove_marker(voxel_position)
	return true


func is_stockpile(voxel_position: Vector3i) -> bool:
	return stockpiles.has(voxel_position)


## The tile's admission filter: whether [param material] may be stored on
## the stockpile at [param voxel_position].
func stockpile_admits(voxel_position: Vector3i, material: BlockRegistry.Resource_) -> bool:
	return (
		stockpiles.has(voxel_position)
		and not stockpiles[voxel_position].get(int(material), false)
	)


## Sets the tile's admission for [param material]. Rejected materials that
## are already piled on the tile become haul-out candidates, so the filter
## cleans up existing contents instead of only gating new deposits.
func set_stockpile_admission(
	voxel_position: Vector3i, material: BlockRegistry.Resource_, admitted: bool
) -> void:
	var rejected: Dictionary = stockpiles.get(voxel_position, null)
	if rejected == null:
		return
	if admitted:
		rejected.erase(int(material))
	else:
		rejected[int(material)] = true


## Whether anything piled on the voxel offends its own tile's filter —
## those piles want hauling elsewhere.
func _pile_rejected_here(voxel_position: Vector3i) -> bool:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return false
	for item in pile.items:
		if not stockpile_admits(voxel_position, item.material):
			return true
	return false


## Places a crafting spot — a worksite, the simplest building: no
## materials, nothing to construct, just a designated place a craft job
## can be ordered at. The voxel must be empty, unclaimed by a tree and
## rest on a solid block.
func designate_craft_spot(voxel_position: Vector3i) -> bool:
	if _designation_markers.has(voxel_position):
		return false
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(voxel_position) > 0:
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# A growing tree would raise its trunk into the spot.
		return false
	var building := Building.new(Building.Kind.WORKSITE, voxel_position)
	register_building(building)
	_add_marker(voxel_position, _craft_spot_marker_material, _outline_mesh)
	DLog.log("designated crafting spot %s" % voxel_position)
	return true


## The building record at [param voxel_position], or null — the lookup the
## deconstruct tool and the inspect panel share.
func building_at(voxel_position: Vector3i) -> Building:
	return buildings.get(voxel_position)


func register_building(building: Building) -> void:
	buildings[building.voxel] = building


func is_craft_spot(voxel_position: Vector3i) -> bool:
	var building := building_at(voxel_position)
	return building != null and building.kind == Building.Kind.WORKSITE


## Queues a deconstruction job on the building at [param voxel_position]:
## a unit takes it apart and it drops exactly the items it was built of.
## Packed-dirt walls aren't buildings from the tool's point of view —
## tamped soil reads as natural ground and has to be mined out.
func designate_deconstruct(voxel_position: Vector3i) -> ColonyJob:
	var building := building_at(voxel_position)
	if building == null:
		# Timberborn: the deconstruct tool also cancels a planned build —
		# there's nothing standing there to take apart.
		if build_job_at(voxel_position) != null:
			cancel_designation(voxel_position)
		return null
	if not building.deconstructable:
		return null
	if deconstruct_job_at(voxel_position) != null:
		return null
	if building.kind == Building.Kind.WALL and _designation_markers.has(voxel_position):
		# Walls share the marker map with designations — a marker there
		# means another job (e.g. a mine) already owns the cell.
		return null
	var job := ColonyJob.new(ColonyJob.Type.DECONSTRUCT, voxel_position)
	_register_job(job)
	if building.kind == Building.Kind.WALL:
		_add_marker(voxel_position, _deconstruct_marker_material, null, true)
	else:
		_set_marker_appearance(voxel_position, _deconstruct_marker_material, _marker_mesh)
	DLog.log("designated deconstruct %s" % voxel_position)
	job_added.emit(job)
	return job


## The active build job at [param voxel_position], or null — pending walls
## are aimable plan cells, so the designator tools query this per voxel
## the cursor's ray crosses.
func build_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BUILD
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## The active deconstruction job at [param voxel_position], or null.
func deconstruct_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.DECONSTRUCT
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## Deconstruction done: the block comes out, the construction's exact
## input items drop where it stood, and its record dies. Any task the
## worksite was running dies with it.
func complete_deconstruct(job: ColonyJob) -> void:
	var voxel := job.voxel_position
	var building: Building = buildings.get(voxel)
	for j in jobs:
		if j != job and j.voxel_position == voxel and j.is_active():
			j.state = ColonyJob.State.CANCELLED
			if j.assignee != null and j.assignee.has_method(&"abandon_job"):
				j.assignee.abandon_job()
	if building != null:
		if (
			building.block_id != BlockRegistry.Block.AIR
			and world.get_block(voxel) == building.block_id
		):
			world.remove_voxel(voxel)
			# Whatever rested on the block lost its floor.
			_settle_pile_at(voxel + Vector3i.UP)
		for item in building.components:
			_drop_item(item, voxel)
		buildings.erase(voxel)
	_finish_job(job)


## Bucket a voxel belongs to for the spatial index.
func _bucket_of(voxel: Vector3i) -> Vector2i:
	return Vector2i(voxel.x >> SPATIAL_BUCKET_SHIFT, voxel.z >> SPATIAL_BUCKET_SHIFT)


func _index_add(buckets: Dictionary, voxel: Vector3i) -> void:
	var key := _bucket_of(voxel)
	var list: Array = buckets.get(key, [])
	if list.is_empty():
		buckets[key] = list
	list.append(voxel)


func _index_remove(buckets: Dictionary, voxel: Vector3i) -> void:
	var key := _bucket_of(voxel)
	var list: Array = buckets.get(key, [])
	if list.is_empty():
		return
	list.erase(voxel)
	if list.is_empty():
		buckets.erase(key)


## The voxel of the nearest index member satisfying [param classify],
## which returns [enum _Match] per candidate: VETO skips it, FRESH is a
## normal hit and RETRY a deprioritised one — a retry only wins when no
## fresh hit exists at any distance. Rings expand outward from [param
## from]'s column and stop as soon as no member of the next ring could be
## closer than the best fresh hit; with no fresh hit the whole index is
## walked (unavoidable — every entry must be ruled out).
func _nearest_indexed(from: Vector3i, buckets: Dictionary, classify: Callable) -> Vector3i:
	var centre := _bucket_of(from)
	var best := Vector3i.MAX
	var best_sq := INF
	var retry := Vector3i.MAX
	var retry_sq := INF

	var extent := 0
	for key in buckets:
		extent = maxi(extent, maxi(absi(key.x - centre.x), absi(key.y - centre.y)))

	var radius := 0
	while radius <= extent:
		# The nearest voxel in ring [param radius] sits at least this far
		# out — past that, nothing can beat a hit already found.
		var ring_min := float(maxi(radius - 1, 0) << SPATIAL_BUCKET_SHIFT)
		if best != Vector3i.MAX and ring_min * ring_min > best_sq:
			break
		for bx in range(centre.x - radius, centre.x + radius + 1):
			for bz in range(centre.y - radius, centre.y + radius + 1):
				if maxi(absi(bx - centre.x), absi(bz - centre.y)) != radius:
					continue
				var list: Array = buckets.get(Vector2i(bx, bz), [])
				if list.is_empty():
					continue
				for voxel in list:
					var tier: int = classify.call(voxel)
					if tier == _Match.VETO:
						continue
					var sq := (Vector3(voxel) - Vector3(from)).length_squared()
					if tier == _Match.FRESH:
						if sq < best_sq:
							best_sq = sq
							best = voxel
					elif sq < retry_sq:
						retry_sq = sq
						retry = voxel
		radius += 1
	return best if best != Vector3i.MAX else retry


## The active craft job queued at [param voxel_position], or null.
func craft_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.CRAFT
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## Orders a craft at the spot in [param voxel_position]: a unit fetches the
## recipe's input from the nearest pile, saws it at the spot and drops the
## products there. One order per spot at a time — and none on a spot
## that's coming down.
func designate_craft(voxel_position: Vector3i) -> ColonyJob:
	if not is_craft_spot(voxel_position):
		return null
	if craft_job_at(voxel_position) != null or deconstruct_job_at(voxel_position) != null:
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	_register_job(job)
	# The spot marker stays — it just switches to the queued appearance.
	_set_marker_appearance(voxel_position, _craft_job_marker_material, _marker_mesh)
	DLog.log("designated craft %s" % voxel_position)
	job_added.emit(job)
	return job


## A craft job is done once its products hit the ground at the spot.
func complete_craft(job: ColonyJob) -> void:
	_finish_job(job)


## Queues a felling job for the tree containing [param voxel_position] —
## any part of it resolves to the root, which is what the unit chops.
func designate_chop(voxel_position: Vector3i) -> ColonyJob:
	var root := forest.tree_root_at(voxel_position)
	if root == Vector3i.MAX or _designation_markers.has(root):
		return null

	var job := ColonyJob.new(ColonyJob.Type.CHOP, root)
	_register_job(job)
	_add_marker(root, _marker_material)
	DLog.log("designated chop %s" % root)
	job_added.emit(job)
	return job


## A chop job's finish: the whole tree comes down — every part voxel is
## removed and its contents spilled as items where they stood.
func fell_tree(job: ColonyJob) -> void:
	forest.fell(job.voxel_position)
	_finish_job(job)


## A chop job whose tree vanished under the unit is simply done.
func complete_chop(job: ColonyJob) -> void:
	_finish_job(job)


## How long a dropped target stays off-limits: doubles with each
## consecutive failure ([param record] is {at: msec, n: drops}), capped —
## a permanently impossible target goes quiet instead of being hammered.
func retry_delay_msec(record: Dictionary) -> int:
	var attempts := int(record.get("n", 1))
	return mini(
		DROPPED_JOB_RETRY_MSEC * (1 << (attempts - 1)),
		DROPPED_JOB_RETRY_MAX_MSEC
	)


## The voxel of the nearest pile eligible for hauling — not fully admitted
## by its stockpile tile (a pile holding rejected items wants hauling
## away), not recently failed ([param skip] maps voxel → {at, n}).
## A pile the unit failed before comes last: it is only picked once its
## retry delay has elapsed and no fresh pile is in reach.
func nearest_haulable_pile(from: Vector3i, skip: Dictionary = {}) -> Vector3i:
	var now := Time.get_ticks_msec()
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		if item_piles[voxel].items.is_empty():
			return _Match.VETO
		if stockpiles.has(voxel) and not _pile_rejected_here(voxel):
			return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY)


## The nearest stockpile tile that can hold [param load] more cubic
## centimetres, or Vector3i.MAX. When [param materials] is given, a tile
## must admit at least one of them. [param skip] blacklists recently-failed
## tiles — an expired failure is only picked when no fresh tile is in reach.
func nearest_stockpile_with_room(
	from: Vector3i, load: int, skip: Dictionary = {}, materials: Array = []
) -> Vector3i:
	var now := Time.get_ticks_msec()
	return _nearest_indexed(from, _stockpile_buckets, func(voxel: Vector3i) -> int:
		if voxel_fill(voxel) + load > DropItem.BLOCK_CM3:
			return _Match.VETO
		if not materials.is_empty():
			var admits_any := false
			for material in materials:
				if stockpile_admits(voxel, material):
					admits_any = true
					break
			if not admits_any:
				return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY)


## Frees the pile at [param voxel_position] when it's been emptied, settling
## whatever may be piled on top.
func remove_pile_if_empty(voxel_position: Vector3i) -> void:
	var pile := item_pile_at(voxel_position)
	if pile != null and pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
		_settle_pile_at(voxel_position + Vector3i.UP)


## Mirrors the voxel's pile fill into the native sim so its fill-aware
## pathing and spill searches see the same occupancy — packed derives
## from fill >= a full cubic metre, no separate flag.
func _sync_sim_packed(voxel_position: Vector3i) -> void:
	if world.sim == null:
		return
	var pile: ItemPile = item_piles.get(voxel_position)
	world.sim.set_pile_fill(voxel_position, pile.total_volume() if pile != null else 0)


func _on_pile_fill_changed(pile: ItemPile) -> void:
	# An in-flight pile isn't keyed under its voxel yet; the resident pile
	# (if any) owns the packed state until it lands.
	if item_piles.get(pile.voxel_position) == pile:
		_sync_sim_packed(pile.voxel_position)
		# A shrinking pile can pull the floor out from under the pile
		# resting on it — re-settle the voxel above. No-op while the
		# floor still holds.
		_settle_pile_at(pile.voxel_position + Vector3i.UP)


## The voxel of the nearest pile holding material a wall can use —
## [param material] specifically, or any wall material when NONE.
## [param need] is the recipe still missing (form → cm³): only piles
## holding items the wall can still absorb qualify.
func nearest_wall_voxel(from: Vector3i, material: BlockRegistry.Resource_, need: Dictionary = {}) -> Vector3i:
	var want := need
	if want.is_empty() and material != BlockRegistry.Resource_.NONE:
		# No remaining-need passed: the wall wants its whole recipe.
		want = BlockRegistry.wall_recipe(material)
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		return _Match.FRESH if item_piles[voxel].wall_need_volume(material, want) > 0 else _Match.VETO)


## The voxel of the nearest pile holding an item of [param form] — the
## fetch query for a craft job's input.
func nearest_form_voxel(from: Vector3i, form: DropItem.Form) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		return _Match.FRESH if item_piles[voxel].form_volume(form) > 0 else _Match.VETO)


## True when anything is designated at [param voxel_position] — the cancel
## tool's validity check.
func is_designated(voxel_position: Vector3i) -> bool:
	return _designation_markers.has(voxel_position)


## Cancels the order queued at a worksite — the site itself stays.
## The panel's task-level cancel; the site goes away via deconstruct.
func cancel_craft_order(voxel_position: Vector3i) -> void:
	var job := craft_job_at(voxel_position)
	if job == null:
		return
	job.state = ColonyJob.State.CANCELLED
	if job.assignee != null and job.assignee.has_method(&"abandon_job"):
		job.assignee.abandon_job()
	_restore_worksite_marker(voxel_position)
	_prune_jobs()


func cancel_designation(voxel_position: Vector3i) -> void:
	# Clicking any part of a designated tree cancels the chop job at its
	# root.
	var root := forest.tree_root_at(voxel_position)
	var target := root if root != Vector3i.MAX else voxel_position
	for job in jobs:
		if job.voxel_position == target and job.is_active():
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
	if stockpiles.erase(voxel_position):
		_index_remove(_stockpile_buckets, voxel_position)
	var building: Building = buildings.get(target)
	if building != null:
		# A building is a construction, not a designation — the cancel
		# sweep only lifts its pending tasks (a craft order, a deconstruct
		# marking). The site itself comes down via deconstruct.
		_restore_worksite_marker(target)
	else:
		_remove_marker(target)
	_prune_jobs()


## Closest open job to [param unit], claimed for it. A job the unit dropped
## before comes last: it is only claimable once its retry delay has elapsed
## and no other open job exists — a unit always tries a different job
## before retrying one it failed.
func claim_job(unit: Unit) -> ColonyJob:
	var now := Time.get_ticks_msec()
	if world.sim != null:
		var job_id: int = world.sim.job_claim(
			unit.get_instance_id(), unit.global_position, now,
			DROPPED_JOB_RETRY_MSEC, DROPPED_JOB_RETRY_MAX_MSEC
		)
		var claimed: ColonyJob = _job_index.get(job_id)
		if claimed != null:
			claimed.state = ColonyJob.State.ASSIGNED
			claimed.assignee = unit
		return claimed
	var best: ColonyJob = null
	var best_distance := INF
	var retry: ColonyJob = null
	var retry_distance := INF
	for job in jobs:
		if not job.is_open():
			continue
		# Cooling off colony-wide: a job that keeps getting dropped backs
		# off for everyone, not just the unit that failed it.
		var global: Dictionary = job.dropped_by.get(0, {})
		if not global.is_empty() and now - int(global.get("at", 0)) < retry_delay_msec(global):
			continue
		var distance := Vector3(job.voxel_position).distance_squared_to(unit.global_position)
		var record: Dictionary = job.dropped_by.get(unit, {})
		if record.is_empty():
			if distance < best_distance:
				best_distance = distance
				best = job
			continue
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			continue
		if distance < retry_distance:
			retry_distance = distance
			retry = job
	var chosen := best if best != null else retry
	if chosen != null:
		chosen.state = ColonyJob.State.ASSIGNED
		chosen.assignee = unit
	return chosen


func release_job(job: ColonyJob) -> void:
	if job.state == ColonyJob.State.ASSIGNED:
		var now := Time.get_ticks_msec()
		var record: Dictionary = job.dropped_by.get(job.assignee, {})
		record["at"] = now
		record["n"] = int(record.get("n", 0)) + 1
		job.dropped_by[job.assignee] = record
		# A colony-wide drop record too: a job nobody can finish shouldn't
		# carousel between units — each failure backs it off for everyone.
		var global: Dictionary = job.dropped_by.get(0, {})
		global["at"] = now
		global["n"] = int(global.get("n", 0)) + 1
		job.dropped_by[0] = global
		if world.sim != null:
			world.sim.job_drop(
				job.get_instance_id(), job.assignee.get_instance_id(), now
			)
		job.state = ColonyJob.State.PENDING
		job.assignee = null


func complete_job(job: ColonyJob, mined_block_id: int) -> void:
	# A wall that gets dug out stops being a building — its recorded
	# components go to the generic shatter like everything else mined.
	buildings.erase(job.voxel_position)
	drop_block(mined_block_id, job.voxel_position)
	_finish_job(job)


## A clearing job is done once its voxel holds no pile.
func complete_clear(job: ColonyJob) -> void:
	_finish_job(job)


## A build job is done once the block is in place — it registers as a
## building, carrying the material class and the exact items that went
## in for deconstruction and material-tinted rendering.
func complete_build(job: ColonyJob) -> void:
	var building := Building.new(Building.Kind.WALL, job.voxel_position)
	building.block_id = job.block_id
	building.material = job.material
	building.components = job.components
	# A packed-dirt wall is indistinguishable from natural ground — it
	# has to be mined out like terrain, not taken apart.
	building.deconstructable = job.material != BlockRegistry.Resource_.SOIL
	register_building(building)
	_finish_job(job)


func _finish_job(job: ColonyJob) -> void:
	job.state = ColonyJob.State.DONE
	job.assignee = null
	var building: Building = buildings.get(job.voxel_position)
	if building != null:
		# The job is done but the construction stands — its marker goes
		# back to showing the building rather than the task.
		_restore_worksite_marker(job.voxel_position)
	else:
		_remove_marker(job.voxel_position)
	job_finished.emit(job)
	_prune_jobs()


## Drops the loot of [param block_id] into the world as [ItemPile]s, letting
## each item spill into neighboring voxels that still have room.
func drop_block(block_id: int, voxel_position: Vector3i) -> void:
	for item in DropItem.for_block(block_id):
		_drop_item(item, voxel_position)


## Drops [param item] into [param voxel_position]. Part or all of it may spill
## into an adjacent voxel: the spill probability is the voxel's occupancy plus
## half the item's own volume. Loose items split proportionally — the spill
## fraction moves on — while solid items move whole. Moved items re-roll the
## same check at their new voxel, so drops settle downward and sideways.
func _drop_item(item: DropItem, voxel_position: Vector3i, hops: int = 0) -> void:
	if hops >= MAX_SPILL_HOPS:
		_deposit_item(item, voxel_position)
		return
	if item.form == DropItem.Form.LOOSE and item.volume < MIN_LOOSE_CM3:
		_deposit_item(item, voxel_position)
		return

	# The spill probability — a fraction of a voxel — while the moved
	# amount stays integer cm³.
	var spill := (voxel_fill(voxel_position) + item.volume / 2.0) / DropItem.CM3_PER_M3
	var target := _spill_target(voxel_position)
	if item.form == DropItem.Form.LOOSE:
		var moved := 0 if target == voxel_position else int(minf(spill, 1.0) * item.volume)
		var kept := item.volume - moved
		if kept > 0:
			_deposit_item(DropItem.new(item.material, item.form, kept), voxel_position)
		if moved > 0:
			item.volume = moved
			_drop_item(item, target, hops + 1)
	elif randf() < spill and target != voxel_position:
		_drop_item(item, target, hops + 1)
	else:
		_deposit_item(item, voxel_position)


## The voxel an item spills into: straight down if it has room, otherwise any
## of the four orthogonal sides. Returns the voxel itself when every neighbor
## is fully occupied, in which case the item just squeezes in where it is.
func _spill_target(voxel_position: Vector3i) -> Vector3i:
	if world.sim != null:
		return world.sim.spill_target(voxel_position)
	var below := voxel_position + Vector3i.DOWN
	if not is_packed(below):
		return below
	var sides := SPILL_SIDES.duplicate()
	sides.shuffle()
	for side in sides:
		var neighbor: Vector3i = voxel_position + side
		if not is_packed(neighbor):
			return neighbor
	return voxel_position


## Portion of [param voxel_position]'s space occupied in cubic centimetres:
## a full cubic metre when the voxel holds a solid block, otherwise the
## volume of the items piled in it.
func voxel_fill(voxel_position: Vector3i) -> int:
	if world.sim != null:
		return int(world.sim.fill_of(voxel_position))
	if world.is_solid(voxel_position):
		return DropItem.BLOCK_CM3
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile.total_volume() if pile != null else 0


## True when the voxel is effectively solid — a real block or packed with a
## full cubic metre of items. Packed voxels are impassible to units and act
## as a floor for anything falling or standing above them.
func is_packed(voxel_position: Vector3i) -> bool:
	if world.sim != null:
		return world.sim.is_blocked(voxel_position)
	if world.is_solid(voxel_position):
		return true
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile != null and pile.is_full()


func _deposit_item(item: DropItem, voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		pile = ItemPile.create(voxel_position, world.sim == null)
		add_child(pile)
		pile.landed.connect(_on_pile_landed)
		pile.fill_changed.connect(_on_pile_fill_changed)
		item_piles[voxel_position] = pile
		_index_add(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		item_dropped.emit(pile)
	pile.add_item(item)
	_settle_pile_at(voxel_position)
	_enforce_capacity(pile.voxel_position)


## True when [param voxel_position] acts as a floor for something falling
## onto it: packed solid, or holding a pile the incoming material can't
## merge into. Loose material ([param splittable]) can always pour into a
## pile that has any room left — the surplus overflows back onto it — but
## an unsplittable item that doesn't fit must rest on top, or it would
## fall in, overfill the pile and be pushed straight back out forever.
func _is_floor_for(voxel_position: Vector3i, volume: int, splittable: bool) -> bool:
	if is_packed(voxel_position):
		return true
	var resident: ItemPile = item_piles.get(voxel_position)
	if resident == null:
		return false
	if splittable:
		return false
	return resident.total_volume() + volume > DropItem.BLOCK_CM3


## The voxel an [param item] dropped at [param voxel_position] would
## actually come to rest in: the lowest voxel in its column whose floor
## supports it — the same walk [method _settle_pile_at] performs.
func _settle_floor(voxel_position: Vector3i, item: DropItem) -> Vector3i:
	var splittable := item.form == DropItem.Form.LOOSE
	if world.sim != null:
		return world.sim.settle_floor(voxel_position, item.volume, splittable)
	var landing := voxel_position
	var below := landing + Vector3i.DOWN
	while world.is_editable(below) and not _is_floor_for(below, item.volume, splittable):
		landing = below
		below = landing + Vector3i.DOWN
	return landing


## The nearest voxel that can hold [param item] without overfilling —
## [param needed] is the volume that must fit (the item's whole volume for
## a solid, or the surplus for a loose item). Adjoining voxels are tried
## first in the usual order (below, emptiest side, above); when none can
## take it the search expands outward from the voxel above. A boulder
## that won't fit a 95%-full hole can't just be pushed onto the voxel
## above — it would settle straight back down and bounce forever — so
## every candidate is judged by the voxel it would settle in, and landings
## back in the source voxel don't count. Packed candidates are skipped
## outright — an item can't be dropped into a solid block or full pile —
## and don't expand the outward search, so items can't tunnel under an
## obstacle into a pocket beneath it. Returns [constant Vector3i.MAX]
## when nothing has room (a loose item may return a nearer partial fit).
func _accepting_voxel(item: DropItem, voxel_position: Vector3i, needed := -1) -> Vector3i:
	if world.sim != null:
		return world.sim.accepting_voxel(
			voxel_position, item.volume, item.form == DropItem.Form.LOOSE, needed
		)
	# The volume that has to fit: a solid item needs its whole volume; a
	# loose item only needs what will actually move (the surplus), and can
	# settle for less — a fragment still moves.
	var want := mini(item.volume, needed) if needed >= 0 else mini(item.volume, DropItem.BLOCK_CM3)
	var partial := Vector3i.MAX
	# Adjoining voxels first, in preference order — below, emptiest side,
	# then straight up — each judged by where the item would settle.
	var neighbors: Array[Vector3i] = [voxel_position + Vector3i.DOWN]
	var sides := SPILL_SIDES.duplicate()
	sides.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return (
				voxel_fill(voxel_position + a) < voxel_fill(voxel_position + b)
			)
	)
	for side in sides:
		neighbors.append(voxel_position + side)
	neighbors.append(voxel_position + Vector3i.UP)
	for candidate in neighbors:
		# A packed voxel can't be entered at all — an item dropped "into" it
		# would materialise inside the block or full pile, and _settle_floor
		# would happily land it in any open pocket underneath, tunnelling
		# the item through the obstacle.
		if is_packed(candidate):
			continue
		var landing := _settle_floor(candidate, item)
		if landing == voxel_position:
			continue
		var room := DropItem.BLOCK_CM3 - voxel_fill(landing)
		if room >= want:
			return landing
		if (
			partial == Vector3i.MAX
			and item.form == DropItem.Form.LOOSE
			and room > MIN_LOOSE_CM3
		):
			partial = landing
	# Nothing adjoining can take it — expand outward from the voxel above.
	var visited := {voxel_position: true}
	var queue: Array[Vector3i] = [voxel_position + Vector3i.UP]
	var head := 0
	while head < queue.size() and head < 4096:
		var candidate := queue[head]
		head += 1
		if visited.has(candidate):
			continue
		visited[candidate] = true
		# Packed voxels are walls to the search too: the item can't enter or
		# pass through one, so the cell doesn't expand the frontier — the
		# voxel on top of the obstacle is reached from the cells above it.
		if is_packed(candidate):
			continue
		var landing := _settle_floor(candidate, item)
		# A candidate that would settle back into the source can't accept the
		# item, but the search still expands through it — the rim of a hole is
		# only reachable past the cell above the hole.
		if landing != voxel_position:
			var room := DropItem.BLOCK_CM3 - voxel_fill(landing)
			if room >= want:
				return landing
			if (
				partial == Vector3i.MAX
				and item.form == DropItem.Form.LOOSE
				and room > MIN_LOOSE_CM3
			):
				partial = landing
		for side in SPILL_SIDES:
			queue.append(candidate + side)
		queue.append(candidate + Vector3i.UP)
		queue.append(candidate + Vector3i.DOWN)
	return partial


## Voxels mid-spill (re-entrancy guard) and already-spilled in this
## cascade — a pile may spill at most once per cascade, which is what
## stops a two-pile ping-pong from shuttling the same surplus forever.
var _enforcing := {}
var _enforced := {}


## A pile must never hold more than a cubic metre: split the excess off —
## smallest items first, cutting loose items down so only the surplus
## leaves — and move it to the nearest voxel that can accept it. Only when
## nowhere nearby has room does the surplus squeeze in anyway.
func _enforce_capacity(voxel_position: Vector3i) -> void:
	if _enforced.has(voxel_position):
		return
	_enforced[voxel_position] = true
	_enforcing[voxel_position] = true
	var moved := 0
	for _i in 64:
		var pile: ItemPile = item_piles.get(voxel_position)
		if pile == null or pile.total_volume() <= DropItem.BLOCK_CM3:
			break
		var excess := pile.total_volume() - DropItem.BLOCK_CM3
		var item := pile.smallest_item()
		if item == null:
			break
		var needed := item.volume
		if item.form == DropItem.Form.LOOSE:
			needed = mini(item.volume, excess)
		# The pile keeps its contents while the excess searches for a landing:
		# an over-full voxel still counts as packed, so the cell above a
		# buried pile reads as resting on it rather than settling back into
		# the hole.
		var target := _accepting_voxel(item, voxel_position, needed)
		if target == Vector3i.MAX:
			break
		moved += 1
		item = pile.take_smallest()
		if item.form == DropItem.Form.LOOSE:
			var room := DropItem.BLOCK_CM3 - voxel_fill(target)
			var moving := mini(excess, mini(item.volume, room))
			item.volume -= moving
			if item.volume > 0:
				pile.add_item(item, false)
			_deposit_item(DropItem.new(item.material, item.form, moving), target)
		else:
			_deposit_item(item, target)
	if moved >= 64:
		DLog.log(
			"enforce_capacity at %s capped after %d spills" % [voxel_position, moved]
		)
	_enforcing.erase(voxel_position)
	if _enforcing.is_empty():
		_enforced.clear()


## Mining removes the floor under whatever was piled above it: let it fall.
func _on_block_mined(position: Vector3i, _block_id: int) -> void:
	_settle_pile_at(position + Vector3i.UP)


## Lets the pile at [param voxel_position] fall through open space until it
## rests on solid ground. The logical voxel moves at once; the pile node
## falls visually and merges into whatever pile it lands on. Stops at the
## edge of loaded terrain rather than letting items drop into the void.
func _settle_pile_at(voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		return
	var splittable := true
	for item in pile.items:
		if item.form != DropItem.Form.LOOSE:
			splittable = false
			break
	var landing := voxel_position
	if world.sim != null:
		landing = world.sim.settle_floor(voxel_position, pile.total_volume(), splittable)
	else:
		var below := landing + Vector3i.DOWN
		while world.is_editable(below) and not _is_floor_for(
			below, pile.total_volume(), splittable
		):
			landing = below
			below = landing + Vector3i.DOWN
	if landing == voxel_position:
		return
	item_piles.erase(voxel_position)
	_index_remove(_pile_buckets, voxel_position)
	_sync_sim_packed(voxel_position)
	pile.voxel_position = landing
	if item_piles.has(landing):
		# The landing voxel is claimed: keep this pile unkeyed until it
		# arrives, then merge it in.
		_in_flight.append(pile)
	else:
		item_piles[landing] = pile
		_index_add(_pile_buckets, landing)
		_sync_sim_packed(landing)
	pile.fall_to(float(landing.y))
	if world.sim != null:
		world.sim.pile_fall_start(
				pile.get_instance_id(), pile.position.y, float(landing.y),
				pile._fall_speed)
	# This pile just vacated its voxel — whatever rested on that voxel
	# lost its floor and may need to follow it down the column.
	_settle_pile_at(voxel_position + Vector3i.UP)


## A falling pile reached its voxel: fold it into the pile already there,
## or claim the voxel if it is empty — re-settling in case the floor gave
## out while it fell. Landing is reported by DelveSim.tick and (for
## presentation nodes) by the pile's own fall animation — whichever fires
## second is absorbed by the guard.
func _on_pile_landed(pile: ItemPile) -> void:
	if not is_instance_valid(pile) or pile.merged:
		return
	_in_flight.erase(pile)
	var resident: ItemPile = item_piles.get(pile.voxel_position)
	if resident == pile:
		return
	if resident != null:
		resident.add_items(pile.items, false)
		pile.merged = true
		pile.queue_free()
		_enforce_capacity(resident.voxel_position)
		return
	item_piles[pile.voxel_position] = pile
	_index_add(_pile_buckets, pile.voxel_position)
	_sync_sim_packed(pile.voxel_position)
	_settle_pile_at(pile.voxel_position)
	_enforce_capacity(pile.voxel_position)


## Shoves a blocking pile aside: moves items out of a packed voxel into
## neighbouring voxels until it no longer fills the cell — a unit digs through
## a pile that blocks its path. Returns false when the pile stays packed
## because no neighbour has room.
func shove_pile(voxel_position: Vector3i) -> bool:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		return true
	while pile.is_full():
		var item := pile.take_smallest()
		if item == null:
			break
		if _move_item_to(pile, item, voxel_position) == null:
			break
	if pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
	# Items piled above the cleared voxel may hover now — let them fall in.
	_settle_pile_at(voxel_position + Vector3i.UP)
	return not is_packed(voxel_position)


## Moves one item — the smallest — out of the pile at [param voxel_position]
## to the nearest voxel that can accept it. Returns the moved item, or null
## when the pile is empty or nowhere has room.
func move_pile_item(voxel_position: Vector3i) -> DropItem:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null or pile.items.is_empty():
		return null
	var item := pile.take_smallest()
	var moved := _move_item_to(pile, item, voxel_position)
	if pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
		_settle_pile_at(voxel_position + Vector3i.UP)
	return moved


## Moves [param item] — or the part of it that fits — from [param pile] at
## [param voxel_position] to the nearest voxel with room for it. A loose
## item splits when only a partial fit is available; a solid item moves
## whole or not at all. Returns the moved piece, or null when nowhere has
## room (the item is put back).
func _move_item_to(
	pile: ItemPile, item: DropItem, voxel_position: Vector3i
) -> DropItem:
	var target := _accepting_voxel(item, voxel_position)
	if target == Vector3i.MAX:
		pile.add_item(item, false)
		return null
	var room := DropItem.BLOCK_CM3 - voxel_fill(target)
	var moved := item
	if item.form == DropItem.Form.LOOSE and item.volume > room:
		moved = DropItem.new(item.material, item.form, room)
		item.volume -= room
		pile.add_item(item, false)
	_deposit_item(moved, target)
	return moved


func item_pile_at(voxel_position: Vector3i) -> ItemPile:
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile


## Everything piled on stockpile tiles, tallied for the resources list —
## one entry per material class and item form: `{"material": r, "form": f,
## "count": n, "cm3": v}`.
func stockpile_contents() -> Array[Dictionary]:
	var tallies := {}
	for voxel in stockpiles:
		var pile := item_pile_at(voxel)
		if pile == null:
			continue
		for item in pile.items:
			var key := int(item.material) * 64 + int(item.form)
			var entry: Dictionary = tallies.get(
				key,
				{
					"material": item.material, "form": item.form,
					"count": 0, "cm3": 0,
				}
			)
			entry["count"] += 1
			entry["cm3"] += item.volume
			tallies[key] = entry
	var contents: Array[Dictionary] = []
	for entry in tallies.values():
		contents.append(entry)
	contents.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (
				int(a["material"]) * 64 + int(a["form"])
				< int(b["material"]) * 64 + int(b["form"])
			)
	)
	return contents


func open_job_count() -> int:
	var count := 0
	for job in jobs:
		if job.is_active():
			count += 1
	return count


## Drops units on solid ground around [param origin].
func spawn_initial_units(origin: Vector3i) -> void:
	for i in initial_units:
		var angle := TAU * float(i) / float(maxi(initial_units, 1))
		var offset := Vector3i(int(cos(angle) * spawn_radius), 0, int(sin(angle) * spawn_radius))
		spawn_unit(origin + offset)


func spawn_unit(near_voxel: Vector3i) -> Unit:
	var ground_y := world.ground_height(near_voxel.x, near_voxel.z, near_voxel.y + 32)
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.name = "Unit%d" % (units.size() + 1)
	add_child(unit)
	unit.global_position = Vector3(near_voxel.x + 0.5, ground_y + 1.5, near_voxel.z + 0.5)
	unit.setup(world, self)
	units.append(unit)
	DLog.log("unit %d spawned at %s" % [unit.get_instance_id(), unit.global_position])
	unit_spawned.emit(unit)
	return unit


func _add_marker(
	voxel_position: Vector3i,
	material: StandardMaterial3D,
	mesh: Mesh = null,
	plan := false
) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = mesh if mesh != null else _marker_mesh
	marker.material_override = material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	marker.visible = _plan_visible() if plan else markers_visible
	add_child(marker)
	_designation_markers[voxel_position] = marker
	if plan:
		_plan_voxels[voxel_position] = true


## Whether plan markers render — the HUD toggle or a planning tool in
## hand both count.
func plans_visible() -> bool:
	return _plan_visible()


## The HUD's Plans toggle.
func set_plans_visible_manual(value: bool) -> void:
	plans_visible_manual = value
	_update_plan_visibility()


## A planning tool (a wall action or deconstruct) auto-shows plans.
func set_plans_tool_active(value: bool) -> void:
	_plans_tool_active = value
	_update_plan_visibility()


func _plan_visible() -> bool:
	return plans_visible_manual or _plans_tool_active


func _update_plan_visibility() -> void:
	for voxel: Vector3i in _plan_voxels:
		_designation_markers[voxel].visible = _plan_visible()


## Shows or hides every designation marker — the zones display toggle.
func set_markers_visible(value: bool) -> void:
	markers_visible = value
	for voxel: Vector3i in _designation_markers:
		if not _plan_voxels.has(voxel):
			_designation_markers[voxel].visible = value


func _remove_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _designation_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_designation_markers.erase(voxel_position)
		_plan_voxels.erase(voxel_position)


## Puts a building's marker back to showing the building itself — the
## worksite outline, or filled with the queued-order look while an order
## runs. Walls keep no standing marker at all.
func _restore_worksite_marker(voxel_position: Vector3i) -> void:
	var building: Building = buildings.get(voxel_position)
	if building == null or building.kind == Building.Kind.WALL:
		_remove_marker(voxel_position)
		return
	if craft_job_at(voxel_position) != null:
		_set_marker_appearance(voxel_position, _craft_job_marker_material, _marker_mesh)
	else:
		_set_marker_appearance(voxel_position, _craft_spot_marker_material, _outline_mesh)


## Recolors and reshapes the marker at [param voxel_position] — craft
## spots tint to show a queued order without gaining a second marker.
func _set_marker_appearance(
	voxel_position: Vector3i, material: StandardMaterial3D, mesh: Mesh
) -> void:
	var marker: MeshInstance3D = _designation_markers.get(voxel_position)
	if marker == null:
		return
	marker.material_override = material
	marker.mesh = mesh


func _prune_jobs() -> void:
	for job in jobs:
		if not job.is_active():
			_unregister_job(job)
	jobs = jobs.filter(func(job: ColonyJob) -> bool: return job.is_active())


## Adds a job to the list, the id index and the native board.
func _register_job(job: ColonyJob) -> void:
	jobs.append(job)
	_job_index[job.get_instance_id()] = job
	if world.sim != null:
		world.sim.job_add(job.get_instance_id(), job.voxel_position)


## Drops a job from the id index and the native board. Pruning keeps the
## list itself; this only tears down the mirrors.
func _unregister_job(job: ColonyJob) -> void:
	_job_index.erase(job.get_instance_id())
	if world.sim != null:
		world.sim.job_remove(job.get_instance_id())
