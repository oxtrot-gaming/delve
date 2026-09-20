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

## How far an item may wander while spilling before it is forced to settle.
const MAX_SPILL_HOPS := 16
## Loose items smaller than this settle instead of splitting again.
const MIN_LOOSE_VOLUME := 0.01
const SPILL_SIDES: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var initial_units: int = 3
## Radius, in voxels, of the area units spawn in around the colony origin.
@export var spawn_radius: int = 6

var world: VoxelWorld
var jobs: Array[ColonyJob] = []
var units: Array[Unit] = []
var stockpile: Dictionary[BlockRegistry.Resource_, int] = {}
## Loose resources lying in the world, keyed by the voxel they sit in or are
## falling toward.
var item_piles: Dictionary[Vector3i, ItemPile] = {}
## Piles falling onto a voxel that already has a pile — they merge into it
## when they land. Not keyed in [member item_piles] while in flight.
var _in_flight: Array[ItemPile] = []

var _designation_markers: Dictionary[Vector3i, Node3D] = {}
var _marker_mesh: BoxMesh
var _marker_material: StandardMaterial3D


func _ready() -> void:
	world = get_node(world_path)
	world.block_mined.connect(_on_block_mined)
	_marker_mesh = BoxMesh.new()
	_marker_mesh.size = Vector3.ONE * 1.02
	_marker_material = StandardMaterial3D.new()
	_marker_material.albedo_color = Color(1.0, 0.85, 0.2, 0.35)
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


## Queues a mining job, unless that voxel is already designated.
func designate_mine(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	if not world.is_solid(voxel_position):
		return null

	var job := ColonyJob.new(ColonyJob.Type.MINE, voxel_position)
	jobs.append(job)
	_add_marker(voxel_position)
	job_added.emit(job)
	return job


func cancel_designation(voxel_position: Vector3i) -> void:
	for job in jobs:
		if job.voxel_position == voxel_position and job.is_active():
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
	_remove_marker(voxel_position)
	_prune_jobs()


## Closest open job to [param from_position], claimed for [param unit].
func claim_job(unit: Unit) -> ColonyJob:
	var best: ColonyJob = null
	var best_distance := INF
	for job in jobs:
		if not job.is_open():
			continue
		var distance := Vector3(job.voxel_position).distance_squared_to(unit.global_position)
		if distance < best_distance:
			best_distance = distance
			best = job
	if best != null:
		best.state = ColonyJob.State.ASSIGNED
		best.assignee = unit
	return best


func release_job(job: ColonyJob) -> void:
	if job.state == ColonyJob.State.ASSIGNED:
		job.state = ColonyJob.State.PENDING
		job.assignee = null


func complete_job(job: ColonyJob, mined_block_id: int) -> void:
	job.state = ColonyJob.State.DONE
	job.assignee = null
	_remove_marker(job.voxel_position)
	drop_block(mined_block_id, job.voxel_position)
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
	if item.form == DropItem.Form.LOOSE and item.volume < MIN_LOOSE_VOLUME:
		_deposit_item(item, voxel_position)
		return

	var spill := _voxel_occupancy(voxel_position) + 0.5 * item.volume
	var target := _spill_target(voxel_position)
	if item.form == DropItem.Form.LOOSE:
		var moved := 0.0 if target == voxel_position else minf(spill, 1.0) * item.volume
		var kept := item.volume - moved
		if kept > 0.0:
			_deposit_item(DropItem.new(item.material, item.form, kept), voxel_position)
		if moved > 0.0:
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
	var below := voxel_position + Vector3i.DOWN
	if _voxel_occupancy(below) < 1.0:
		return below
	var sides := SPILL_SIDES.duplicate()
	sides.shuffle()
	for side in sides:
		var neighbor: Vector3i = voxel_position + side
		if _voxel_occupancy(neighbor) < 1.0:
			return neighbor
	return voxel_position


## Portion of [param voxel_position]'s space already occupied: 1.0 when the
## voxel holds a solid block, otherwise the volume of the items piled in it.
func _voxel_occupancy(voxel_position: Vector3i) -> float:
	if world.is_solid(voxel_position):
		return 1.0
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile.total_volume() if pile != null else 0.0


func _deposit_item(item: DropItem, voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		pile = ItemPile.create(voxel_position)
		add_child(pile)
		pile.landed.connect(_on_pile_landed)
		item_piles[voxel_position] = pile
		item_dropped.emit(pile)
	pile.add_item(item)
	_settle_pile_at(voxel_position)


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
	var landing := voxel_position
	var below := landing + Vector3i.DOWN
	while not world.is_solid(below) and world.is_editable(below):
		landing = below
		below = landing + Vector3i.DOWN
	if landing == voxel_position:
		return
	item_piles.erase(voxel_position)
	pile.voxel_position = landing
	if item_piles.has(landing):
		# The landing voxel is claimed: keep this pile unkeyed until it
		# arrives, then merge it in.
		_in_flight.append(pile)
	else:
		item_piles[landing] = pile
	pile.fall_to(float(landing.y))


## A falling pile reached its voxel: fold it into the pile already there,
## or claim the voxel if it is empty — re-settling in case the floor gave
## out while it fell.
func _on_pile_landed(pile: ItemPile) -> void:
	_in_flight.erase(pile)
	var resident: ItemPile = item_piles.get(pile.voxel_position)
	if resident == pile:
		return
	if resident != null:
		resident.add_items(pile.items, false)
		pile.queue_free()
		return
	item_piles[pile.voxel_position] = pile
	_settle_pile_at(pile.voxel_position)


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
	unit_spawned.emit(unit)
	return unit


func _add_marker(voxel_position: Vector3i) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = _marker_mesh
	marker.material_override = _marker_material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	add_child(marker)
	_designation_markers[voxel_position] = marker


func _remove_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _designation_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_designation_markers.erase(voxel_position)


func _prune_jobs() -> void:
	jobs = jobs.filter(func(job: ColonyJob) -> bool: return job.is_active())
