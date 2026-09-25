class_name Colony
extends Node3D

## Owns the colony state: the job board, the units and the stockpile.
##
## The player never mines directly; they designate work, units claim jobs
## from here and report back when the work is done.

signal job_added(job: ColonyJob)
signal job_finished(job: ColonyJob)
signal stockpile_changed(resource: BlockRegistry.Resource_, amount: int)
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
var stockpile: Dictionary[BlockRegistry.Resource_, int] = {}
## Loose resources lying in the world, keyed by the voxel they sit in or are
## falling toward.
var item_piles: Dictionary[Vector3i, ItemPile] = {}
## Piles falling onto a voxel that already has a pile — they merge into it
## when they land. Not keyed in [member item_piles] while in flight.
var _in_flight: Array[ItemPile] = []

## Voxels designated as stockpile tiles: haul destinations for loose items.
var stockpiles: Dictionary[Vector3i, bool] = {}

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


## Queues a wall build: a unit fetches wall-eligible material from piles —
## loose soil, stone boulders and cobbles, or logs — and raises whichever
## block the material makes (see [constant BlockRegistry.WALL_MATERIALS]).
## The voxel must be free of solid terrain, growing things and not packed
## full of items.
func designate_build(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR or is_packed(voxel_position):
		return null
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# Sapling and leaf cells are air but claimed — a wall would entomb
		# the decoration and block the tree's growth.
		return null

	var job := ColonyJob.new(ColonyJob.Type.BUILD, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material)
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
	stockpiles[voxel_position] = true
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


## The voxel of the nearest pile eligible for hauling — not inside a
## stockpile, not recently failed ([param skip] maps voxel → {at, n}).
## A pile the unit failed before comes last: it is only picked once its
## retry delay has elapsed and no fresh pile is in reach.
func nearest_haulable_pile(from: Vector3i, skip: Dictionary = {}) -> Vector3i:
	var now := Time.get_ticks_msec()
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		if stockpiles.has(voxel) or item_piles[voxel].items.is_empty():
			return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY)


## The nearest stockpile tile that can hold [param load] more cubic
## centimetres, or Vector3i.MAX. [param skip] blacklists recently-failed
## tiles — an expired failure is only picked when no fresh tile is in reach.
func nearest_stockpile_with_room(from: Vector3i, load: int, skip: Dictionary = {}) -> Vector3i:
	var now := Time.get_ticks_msec()
	return _nearest_indexed(from, _stockpile_buckets, func(voxel: Vector3i) -> int:
		if voxel_fill(voxel) + load > DropItem.BLOCK_CM3:
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
func nearest_wall_voxel(from: Vector3i, material: BlockRegistry.Resource_) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		return _Match.FRESH if item_piles[voxel].wall_volume(material) > 0 else _Match.VETO)


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
		if world.sim != null:
			world.sim.job_drop(
				job.get_instance_id(), job.assignee.get_instance_id(), now
			)
		job.state = ColonyJob.State.PENDING
		job.assignee = null


func complete_job(job: ColonyJob, mined_block_id: int) -> void:
	drop_block(mined_block_id, job.voxel_position)
	_finish_job(job)


## A clearing job is done once its voxel holds no pile.
func complete_clear(job: ColonyJob) -> void:
	_finish_job(job)


## A build job is done once the block is in place.
func complete_build(job: ColonyJob) -> void:
	_finish_job(job)


func _finish_job(job: ColonyJob) -> void:
	job.state = ColonyJob.State.DONE
	job.assignee = null
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
		pile = ItemPile.create(voxel_position)
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


## A pile must never hold more than a cubic metre: split the excess off —
## smallest items first, cutting loose items down so only the surplus
## leaves — and move it to the nearest voxel that can accept it. Only when
## nowhere nearby has room does the surplus squeeze in anyway.
func _enforce_capacity(voxel_position: Vector3i) -> void:
	for _i in 64:
		var pile: ItemPile = item_piles.get(voxel_position)
		if pile == null or pile.total_volume() <= DropItem.BLOCK_CM3:
			return
		var excess := pile.total_volume() - DropItem.BLOCK_CM3
		var item := pile.smallest_item()
		if item == null:
			return
		var needed := item.volume
		if item.form == DropItem.Form.LOOSE:
			needed = mini(item.volume, excess)
		# The pile keeps its contents while the excess searches for a landing:
		# an over-full voxel still counts as packed, so the cell above a
		# buried pile reads as resting on it rather than settling back into
		# the hole.
		var target := _accepting_voxel(item, voxel_position, needed)
		if target == Vector3i.MAX:
			return
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


func add_resource(resource: BlockRegistry.Resource_, amount: int) -> void:
	stockpile[resource] = stockpile.get(resource, 0) + amount
	stockpile_changed.emit(resource, stockpile[resource])


func resource_count(resource: BlockRegistry.Resource_) -> int:
	return stockpile.get(resource, 0)


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


func _add_marker(voxel_position: Vector3i, material: StandardMaterial3D, mesh: Mesh = null) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = mesh if mesh != null else _marker_mesh
	marker.material_override = material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	add_child(marker)
	_designation_markers[voxel_position] = marker


func _remove_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _designation_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_designation_markers.erase(voxel_position)


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
