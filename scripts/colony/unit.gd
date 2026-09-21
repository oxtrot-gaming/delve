class_name Unit
extends CharacterBody3D

## A worker: claims jobs from the [Colony], walks to them over the voxel grid
## and mines. Deliberately small — it is the hook where real AI (needs, skills,
## hauling, sleep schedules) gets added later.

enum State { IDLE, MOVING, WORKING, YIELDING }

## Skin-tone ramp anchors: pale to dark. Each unit draws a random point
## along the ramp at spawn.
const SKIN_TONE_PALE := Color(0.96, 0.80, 0.66)
const SKIN_TONE_MID := Color(0.55, 0.36, 0.24)
const SKIN_TONE_DARK := Color(0.20, 0.11, 0.07)

@export var move_speed: float = 4.0
## Enough to clear a 1 m step: apex is jump_speed² / (2 × gravity).
@export var jump_speed: float = 7.5
@export var gravity: float = 22.0
## Distance in metres from the unit's centre to a block's nearest face.
@export var mine_reach: float = 1.5
## Hardness points worked through per second.
@export var mining_speed: float = 2.0
## Cubic metres of items shovelled per second — clearing and gathering alike.
@export var clearing_speed: float = 2.0
## Cubic metres of material a unit can carry on one hauling trip.
@export var carry_capacity: float = 0.5
## Seconds without getting closer to the job site before the unit drops the
## assignment as unreachable.
@export var stuck_timeout: float = 5.0
## How much closer to the job site, in metres, counts as making progress.
const STUCK_PROGRESS := 0.25

var state: State = State.IDLE
var job: ColonyJob = null
## This unit's skin tone: a random point along the pale-to-dark ramp,
## rolled in [method _ready] and applied to the body material.
var skin_tone: Color = SKIN_TONE_MID

var _world: VoxelWorld
var _colony: Colony
var _path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _repath_cooldown: float = 0.0
var _job_search_cooldown: float = 0.0
var _stuck_elapsed: float = 0.0
var _best_goal_distance: float = INF
var _clear_budget: float = 0.0
## What the unit is pathing toward — the job voxel, or for a build fetch the
## dirt pile it's collecting from.
var _goal_voxel: Vector3i = Vector3i.ZERO
## Build/haul phase: true while fetching items, false while delivering.
var _fetching: bool = false
## Items physically carried — loose soil for a build job, pile contents for
## a haul. Dropped where the unit stands if the job is abandoned.
var _carried: Array[DropItem] = []
## Haul targets (source piles or stockpile tiles) that recently failed —
## the unit leaves them alone for a while instead of retrying in a loop.
var _haul_blacklist: Dictionary = {}
## Seconds spent sidestepping for another unit — yields give up quickly if
## the step-aside spot can't be reached.
var _yield_elapsed: float = 0.0


## Cubic metres currently carried.
func _carried_volume() -> float:
	var total := 0.0
	for item in _carried:
		total += item.volume
	return total


@onready var _body: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	skin_tone = _random_skin_tone()
	# The capsule material is a shared scene resource — duplicate before
	# tinting or every unit would share one color.
	var material := _body.get_surface_override_material(0).duplicate() as StandardMaterial3D
	material.albedo_color = skin_tone
	_body.set_surface_override_material(0, material)


func setup(world: VoxelWorld, colony: Colony) -> void:
	_world = world
	_colony = colony


## A random point along the pale → mid → dark skin-tone ramp.
static func _random_skin_tone() -> Color:
	var t := randf()
	if t < 0.5:
		return SKIN_TONE_PALE.lerp(SKIN_TONE_MID, t * 2.0)
	return SKIN_TONE_MID.lerp(SKIN_TONE_DARK, t * 2.0 - 1.0)


func _physics_process(delta: float) -> void:
	if _world == null:
		return

	_job_search_cooldown = maxf(_job_search_cooldown - delta, 0.0)
	_repath_cooldown = maxf(_repath_cooldown - delta, 0.0)

	match state:
		State.IDLE:
			_tick_idle()
		State.MOVING:
			_tick_moving(delta)
		State.WORKING:
			_tick_working(delta)
		State.YIELDING:
			_tick_yielding(delta)

	_apply_motion(delta)


func abandon_job() -> void:
	# An interrupted haul drops the load where the unit stands.
	for item in _carried:
		_colony._drop_item(item, _standing_voxel())
	_carried.clear()
	job = null
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_clear_budget = 0.0
	_fetching = false
	state = State.IDLE


func current_activity() -> String:
	match state:
		State.MOVING:
			if job == null:
				return "walking"
			if job.type == ColonyJob.Type.HAUL:
				return "fetching items" if _fetching else "hauling to stockpile"
			if job.type == ColonyJob.Type.BUILD and _fetching:
				return "fetching dirt"
			return "walking to %s" % str(job.voxel_position)
		State.YIELDING:
			return "stepping aside"
		State.WORKING:
			if job == null:
				return "working"
			if job.type == ColonyJob.Type.HAUL:
				return "loading items" if _fetching else "stockpiling items"
			if job.type == ColonyJob.Type.CLEAR:
				return "clearing %s" % str(job.voxel_position)
			if job.type == ColonyJob.Type.BUILD:
				return (
					"gathering dirt"
					if _fetching
					else "building %s" % BlockRegistry.block_name(job.block_id)
				)
			return "mining %s" % BlockRegistry.block_name(_world.get_block(job.voxel_position))
		_:
			return "idle"


func _tick_idle() -> void:
	if _job_search_cooldown > 0.0:
		return
	_job_search_cooldown = 0.5
	job = _colony.claim_job(self)
	if job == null:
		_try_start_haul()
		return
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = job.voxel_position
	_fetching = false
	if (
		job.type == ColonyJob.Type.BUILD
		and job.progress < DropItem.DROP_VOLUME
	):
		# Nothing to deliver yet — head for the closest dirt pile instead.
		var next := _colony.nearest_soil_voxel(_standing_voxel())
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	if _repath_to_job():
		state = State.MOVING
	else:
		_give_up_on_job()


func _tick_moving(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	if _goal_in_reach():
		_path.clear()
		state = State.WORKING
		return

	# Watchdog: no meaningful progress toward the site for too long means
	# the path is physically blocked — drop the assignment for someone else.
	var goal_distance := global_position.distance_to(
		Vector3(_goal_voxel) + Vector3(0.5, 0.5, 0.5)
	)
	if goal_distance < _best_goal_distance - STUCK_PROGRESS:
		_best_goal_distance = goal_distance
		_stuck_elapsed = 0.0
	else:
		_stuck_elapsed += delta
		if _stuck_elapsed > stuck_timeout:
			_give_up_on_job()
			return

	if _path_index >= _path.size():
		if _repath_cooldown > 0.0:
			return
		if not _repath_to_job():
			_give_up_on_job()
		return

	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	if flat_distance < 0.35:
		_path_index += 1
		return

	# A packed item pile in the way (the astar can't see those): once close
	# enough to reach it, shove its contents into neighbouring voxels.
	if flat_distance < 1.6:
		var waypoint_cell := Vector3i(waypoint.floor())
		for cell in [waypoint_cell, waypoint_cell + Vector3i.UP]:
			if not _world.is_solid(cell) and _colony.is_packed(cell):
				_colony.shove_pile(cell)

	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if is_on_floor() and (to_waypoint.y > 0.6 or is_on_wall()):
		velocity.y = jump_speed


func _tick_working(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	velocity.x = 0.0
	velocity.z = 0.0

	if job.type == ColonyJob.Type.CLEAR:
		_tick_clearing(delta)
		return
	if job.type == ColonyJob.Type.BUILD:
		_tick_building(delta)
		return
	if job.type == ColonyJob.Type.HAUL:
		_tick_hauling(delta)
		return

	if not _can_mine(job.voxel_position):
		state = State.MOVING
		return

	var block_id := _world.get_block(job.voxel_position)
	if not BlockRegistry.is_solid(block_id):
		_colony.complete_job(job, block_id)
		abandon_job()
		return

	job.progress += mining_speed * delta
	if job.progress < BlockRegistry.hardness(block_id):
		return

	var mined := _world.mine(job.voxel_position)
	if mined == BlockRegistry.Block.AIR:
		# Area unloaded under us: put the job back on the board.
		_colony.release_job(job)
		abandon_job()
		return
	_colony.complete_job(job, mined)
	job = null
	state = State.IDLE


## Clearing work: shovel items out of the job voxel into adjoining voxels a
## little at a time, until the pile is gone.
func _tick_clearing(delta: float) -> void:
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var pile := _colony.item_pile_at(job.voxel_position)
	if pile == null or pile.items.is_empty():
		_colony.complete_clear(job)
		job = null
		state = State.IDLE
		return
	_clear_budget += clearing_speed * delta
	while _clear_budget > 0.0:
		var item := _colony.move_pile_item(job.voxel_position)
		if item == null:
			if _colony.item_pile_at(job.voxel_position) == null:
				_colony.complete_clear(job)
				job = null
				state = State.IDLE
			else:
				# Every adjoining voxel is packed — the pile can't shrink.
				_give_up_on_job()
			return
		_clear_budget -= item.volume


## Build work is a hauling loop: fetch loose soil from the closest dirt
## pile (no distance limit — the unit walks to wherever the dirt is),
## carry a load back to the site, repeat until the block has its full
## volume — `job.progress` is the cubic metres delivered. Then displace
## whatever sits in the voxel and place the block.
func _tick_building(delta: float) -> void:
	if _world.is_solid(job.voxel_position):
		# The block is already there — the job is moot.
		_colony.complete_build(job)
		job = null
		state = State.IDLE
		return
	if _fetching:
		_tick_fetching(delta)
	else:
		_tick_delivering()


## Fetching: at the dirt pile, shovel loose soil into the carried load
## until the load or the remaining need is covered — then head back.
func _tick_fetching(delta: float) -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta
	var need := minf(
		DropItem.DROP_VOLUME - job.progress - _carried_volume(),
		carry_capacity - _carried_volume()
	)
	while need > 0.0 and _clear_budget > 0.0:
		var pulled := _colony.pull_loose_soil(_goal_voxel, minf(need, _clear_budget))
		if pulled <= 0.0:
			break
		_carried.append(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, pulled)
		)
		_clear_budget -= pulled
		need = minf(
			DropItem.DROP_VOLUME - job.progress - _carried_volume(),
			carry_capacity - _carried_volume()
		)
	var pile := _colony.item_pile_at(_goal_voxel)
	if need <= 0.0 or pile == null or not pile.has_loose(BlockRegistry.Resource_.SOIL):
		# Loaded, or this pile is drained — pick the next goal.
		_advance_build_goal()


## Delivering: at the site, the carried load is absorbed into the growing
## block (the voxel can't hold 1.25 m³ as a pile — capacity is 1.0). Fetch
## again until the block's full volume has arrived, then place it.
func _tick_delivering() -> void:
	if (
		_standing_voxel() == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	if _carried_volume() > 0.0:
		job.progress += _carried_volume()
		_carried.clear()
	if job.progress < DropItem.DROP_VOLUME:
		_advance_build_goal()
		return
	# Push whatever piled up in the voxel while hauling into the neighbours.
	while _colony.item_pile_at(job.voxel_position) != null:
		if _colony.move_pile_item(job.voxel_position) == null:
			_give_up_on_job()
			return
	if not _world.place(job.voxel_position, job.block_id):
		_colony.release_job(job)
		abandon_job()
		return
	_colony.complete_build(job)
	job = null
	state = State.IDLE


## Picks the next build-job goal: carry the load to the site if the unit
## holds any, else fetch from the next-closest dirt pile. With a full
## block and no load the delivery tick takes it from there.
func _advance_build_goal() -> void:
	if _carried_volume() > 0.0:
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_soil_voxel(_standing_voxel())
		if next == Vector3i.MAX:
			# No dirt anywhere — put the job back on the board.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## Idle fallback: with no designated job to claim, haul loose items to a
## stockpile — the nearest pile that isn't already in one, to the nearest
## stockpile tile with room. The haul is an off-board job so pathing and
## the stuck watchdog work on it unchanged.
func _try_start_haul() -> void:
	var source := _colony.nearest_haulable_pile(_standing_voxel(), _haul_blacklist)
	if source == Vector3i.MAX:
		return
	if (
		_colony.nearest_stockpile_with_room(
			_standing_voxel(), Colony.MIN_LOOSE_VOLUME, _haul_blacklist
		) == Vector3i.MAX
	):
		return
	job = ColonyJob.new(ColonyJob.Type.HAUL, source)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_fetching = true
	_goal_voxel = source
	if not _repath_to_job():
		_give_up_on_job()
	else:
		state = State.MOVING


## Hauling work: load items off the source pile, carry them to a stockpile.
func _tick_hauling(delta: float) -> void:
	if _fetching:
		_tick_haul_fetch(delta)
	else:
		_tick_haul_deliver()


## At the source pile: load items until the load reaches what fits in the
## destination stockpile (capacity-limited — big piles take several trips).
func _tick_haul_fetch(delta: float) -> void:
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null or pile.items.is_empty():
		if _carried_volume() > 0.0:
			_set_haul_destination()
			return
		# The pile was emptied before we arrived — find another one.
		var next := _colony.nearest_haulable_pile(_standing_voxel(), _haul_blacklist)
		if next == Vector3i.MAX:
			job = null
			state = State.IDLE
		else:
			_goal_voxel = next
			_path.clear()
			state = State.MOVING
		return
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), Colony.MIN_LOOSE_VOLUME, _haul_blacklist
	)
	if sp == Vector3i.MAX:
		# No stockpile has any room — the haul is impossible for now.
		_give_up_on_job()
		return
	var room := 1.0 + ItemPile.FULL_EPSILON - _colony.voxel_fill(sp)
	var want := minf(carry_capacity, room) - _carried_volume()
	_clear_budget += clearing_speed * delta
	while want > 0.0 and _clear_budget > 0.0:
		var got := pile.take_up_to(minf(want, _clear_budget))
		if got.is_empty():
			break
		var volume := 0.0
		for item in got:
			volume += item.volume
		_carried.append_array(got)
		_clear_budget -= volume
		want = minf(carry_capacity, room) - _carried_volume()
	_colony.remove_pile_if_empty(_goal_voxel)
	if _carried_volume() >= minf(carry_capacity, room) - 0.0001 or pile.items.is_empty():
		_set_haul_destination()


## At the stockpile: unload the carried items into its voxel.
func _tick_haul_deliver() -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	if _colony.voxel_fill(_goal_voxel) + _carried_volume() > 1.0 + ItemPile.FULL_EPSILON:
		# It filled up while we walked — find another tile.
		_set_haul_destination()
		return
	for item in _carried:
		_colony._deposit_item(item, _goal_voxel)
	_carried.clear()
	job = null
	state = State.IDLE


## Picks the stockpile tile this haul's load goes to — the nearest with
## room for it. With nowhere that fits, the job is dropped (and the load
## with it).
func _set_haul_destination() -> void:
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), _carried_volume(), _haul_blacklist
	)
	if sp == Vector3i.MAX:
		_give_up_on_job()
		return
	_fetching = false
	_goal_voxel = sp
	_path.clear()
	state = State.MOVING


## Asks this unit to step aside for [param pusher] — only idle units can be
## shoved; a busy unit is already going somewhere. The unit walks to a
## standable neighbour that's off the pusher's path and unoccupied, then
## returns to idle. If no such spot exists it simply stays put and the
## pusher's stuck watchdog deals with the blockage.
func yield_to(pusher: Unit) -> void:
	if state != State.IDLE:
		return
	var pusher_cells := {
		pusher._standing_voxel(): true,
		pusher._goal_voxel: true,
	}
	for i in range(pusher._path_index, pusher._path.size()):
		pusher_cells[Vector3i(pusher._path[i].floor())] = true
	var occupied := {}
	for unit in _colony.units:
		occupied[unit._standing_voxel()] = true
	var here := _standing_voxel()
	var candidates: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var spot := here + Vector3i(dx, dy, dz)
				if _is_standable(spot) and not occupied.has(spot):
					candidates.append(spot)
	# Prefer spots off the pusher's path, then farthest from the pusher.
	var from := pusher.global_position
	candidates.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			var sa := Vector3(a).distance_squared_to(from) - (1000.0 if pusher_cells.has(a) else 0.0)
			var sb := Vector3(b).distance_squared_to(from) - (1000.0 if pusher_cells.has(b) else 0.0)
			return sa > sb
	)
	for spot in candidates:
		var path := _world.find_path(here, spot)
		if path.is_empty():
			continue
		_path = path
		_path_index = 0
		_yield_elapsed = 0.0
		state = State.YIELDING
		return


## Sidestepping: follow the yield path, then go back to idle. A short
## timeout covers the case where the spot can't actually be reached.
func _tick_yielding(delta: float) -> void:
	_yield_elapsed += delta
	if _path_index >= _path.size() or _yield_elapsed > 2.0:
		state = State.IDLE
		return
	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	if flat_distance < 0.35:
		_path_index += 1
		return
	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if is_on_floor() and (to_waypoint.y > 0.6 or is_on_wall()):
		velocity.y = jump_speed


## True when the current goal voxel's face is reachable from where the
## unit stands — mining requires a solid target, everything else a
## non-solid one; a unit can't build the block it's standing in.
func _goal_in_reach() -> bool:
	if job.type == ColonyJob.Type.MINE:
		return _can_mine(job.voxel_position)
	if (
		job.type == ColonyJob.Type.BUILD
		and not _fetching
		and _standing_voxel() == job.voxel_position
	):
		return false
	return _can_clear_from(global_position, _goal_voxel)


func _apply_motion(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	if state != State.MOVING:
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	# The intended heading — move_and_slide rewrites velocity, so capture it
	# before the collision pass.
	var heading := Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	# A unit with somewhere to be shoves idle units out of its way — the
	# astar doesn't know about bodies, so corridors clog without this. Only
	# head-on contact counts; brushing past a shoulder doesn't shove.
	if state == State.MOVING and job != null and heading.length_squared() > 0.01:
		heading = heading.normalized()
		for i in get_slide_collision_count():
			var hit := get_slide_collision(i)
			var blocker := hit.get_collider()
			if (
				blocker is Unit
				and blocker.state == State.IDLE
				and hit.get_normal().dot(heading) < -0.3
			):
				blocker.yield_to(self)


## True when the unit can mine [param voxel_position] from where it stands.
func _can_mine(voxel_position: Vector3i) -> bool:
	return _can_mine_from(global_position, voxel_position)


## The mining rule: the unit's centre must be within [member mine_reach] of
## the block's nearest face, and no other solid voxel may sit between them —
## blocks behind, above or below another block relative to the unit are out.
func _can_mine_from(from: Vector3, voxel_position: Vector3i) -> bool:
	return _can_reach_from(from, voxel_position, true)


## Same reach rule for a non-solid target — a voxel holding an item pile.
## The ray passes through it, so the packed-cell march alone checks that no
## solid or packed voxel sits between the unit and the pile.
func _can_clear_from(from: Vector3, voxel_position: Vector3i) -> bool:
	return _can_reach_from(from, voxel_position, false)


## Shared reach rule: within [member mine_reach] of the voxel's nearest face,
## with no solid or packed voxel in between. For a solid target the face ray
## must also land on the target itself.
func _can_reach_from(from: Vector3, voxel_position: Vector3i, solid_target: bool) -> bool:
	var nearest := from.clamp(Vector3(voxel_position), Vector3(voxel_position) + Vector3.ONE)
	var to_face := nearest - from
	var distance := to_face.length()
	if distance > mine_reach:
		return false
	if distance < 0.01:
		return true
	var direction := to_face / distance
	if solid_target:
		var hit := _world.raycast(from, direction, distance + 0.5)
		if hit == null or hit.position != voxel_position:
			return false
	# A voxel packed full of items occludes like a solid block — this march
	# also catches solid voxels, since is_packed covers both.
	var travelled := 0.0
	while travelled < distance - 0.2:
		var cell := Vector3i((from + direction * travelled).floor())
		if cell != Vector3i(from.floor()) and _colony.is_packed(cell):
			return false
		travelled += 0.25
	return true


func _repath_to_job() -> bool:
	_repath_cooldown = 1.0
	_path.clear()
	_path_index = 0
	if job == null:
		return false

	var start := _standing_voxel()
	var blocked_path := PackedVector3Array()
	var solid_target := job.type == ColonyJob.Type.MINE
	# A unit can't deliver from inside the block it's building.
	var exclude_self := (
		job.type == ColonyJob.Type.BUILD
		and _goal_voxel == job.voxel_position
	)
	for target in _work_spots(_goal_voxel, solid_target, exclude_self):
		var path := _world.find_path(start, target)
		if path.is_empty():
			continue
		if _path_is_clear(path):
			_path = path
			return true
		if blocked_path.is_empty():
			blocked_path = path
	# No clear route: take a pile-crossing one and shove obstructions aside
	# as they come within reach.
	if not blocked_path.is_empty():
		_path = blocked_path
		return true
	return false


## Voxel the unit currently stands in.
func _standing_voxel() -> Vector3i:
	return Vector3i(floori(global_position.x), roundi(global_position.y - 0.9), floori(global_position.z))


## True when a voxel blocks a unit: solid terrain, or packed full of items.
func _is_blocked(voxel_position: Vector3i) -> bool:
	return _world.is_solid(voxel_position) or _colony.is_packed(voxel_position)


## Standable for a unit: a solid or packed floor below, two free voxels.
## A partially filled voxel is enterable — its pile's collision lifts the
## unit to the fill level, and a unit can stand on top of a packed one.
func _is_standable(voxel_position: Vector3i) -> bool:
	return (
		_is_blocked(voxel_position + Vector3i.DOWN)
		and not _is_blocked(voxel_position)
		and not _is_blocked(voxel_position + Vector3i.UP)
	)


## True when no path cell runs through a blocked voxel. The voxel astar does
## not know about item fill, so a path can nominally pass through a packed
## pile — the unit shoves those aside on approach, but a clear path is
## preferred when one exists.
func _path_is_clear(path: PackedVector3Array) -> bool:
	for i in range(1, path.size()):
		if _is_blocked(Vector3i(path[i].floor())):
			return false
	return true


## Standable voxels a unit could work [param target] from, nearest first.
## Scans the box of spots whose centre is plausibly in reach — a spot counts
## only if reaching the target from it passes the same check the unit uses.
## [param exclude_self] keeps a unit from working from inside the target
## voxel — a unit can't build the block it stands in.
func _work_spots(target: Vector3i, solid_target: bool = true, exclude_self: bool = false) -> Array[Vector3i]:
	var reachable: Array[Vector3i] = []
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var spot := target + Vector3i(dx, dy, dz)
				if exclude_self and spot == target:
					continue
				if not _is_standable(spot):
					continue
				if _can_reach_from(Vector3(spot) + Vector3(0.5, 0.9, 0.5), target, solid_target):
					reachable.append(spot)
	var here := global_position
	reachable.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return Vector3(a).distance_squared_to(here) < Vector3(b).distance_squared_to(here)
	)
	return reachable


func _give_up_on_job() -> void:
	if job != null:
		if job.type == ColonyJob.Type.HAUL:
			# Whatever we failed to reach goes quiet for a while.
			_haul_blacklist[_goal_voxel] = Time.get_ticks_msec()
		_colony.release_job(job)
	_job_search_cooldown = 1.5
	abandon_job()
