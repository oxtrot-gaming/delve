class_name Unit
extends CharacterBody3D

## A worker: claims jobs from the [Colony], walks to them over the voxel grid
## and mines. Deliberately small — it is the hook where real AI (needs, skills,
## hauling, sleep schedules) gets added later.

enum State { IDLE, MOVING, WORKING }

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
## Cubic metres of items shovelled into adjoining voxels per second.
@export var clearing_speed: float = 2.0
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

	_apply_motion(delta)


func abandon_job() -> void:
	job = null
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_clear_budget = 0.0
	state = State.IDLE


func current_activity() -> String:
	match state:
		State.MOVING:
			return "walking to %s" % str(job.voxel_position) if job != null else "walking"
		State.WORKING:
			if job == null:
				return "working"
			if job.type == ColonyJob.Type.CLEAR:
				return "clearing %s" % str(job.voxel_position)
			return "mining %s" % BlockRegistry.block_name(_world.get_block(job.voxel_position))
		_:
			return "idle"


func _tick_idle() -> void:
	if _job_search_cooldown > 0.0:
		return
	_job_search_cooldown = 0.5
	job = _colony.claim_job(self)
	if job == null:
		return
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if _repath_to_job():
		state = State.MOVING
	else:
		_give_up_on_job()


func _tick_moving(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	if _job_in_reach():
		_path.clear()
		state = State.WORKING
		return

	# Watchdog: no meaningful progress toward the site for too long means
	# the path is physically blocked — drop the assignment for someone else.
	var goal_distance := global_position.distance_to(
		Vector3(job.voxel_position) + Vector3(0.5, 0.5, 0.5)
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


## True when the job voxel's face is reachable from where the unit stands —
## mining requires a solid target, clearing targets a non-solid pile voxel.
func _job_in_reach() -> bool:
	if job.type == ColonyJob.Type.CLEAR:
		return _can_clear_from(global_position, job.voxel_position)
	return _can_mine(job.voxel_position)


func _apply_motion(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	if state != State.MOVING:
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	move_and_slide()


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
	var solid_target := job.type != ColonyJob.Type.CLEAR
	for target in _work_spots(job.voxel_position, solid_target):
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
func _work_spots(target: Vector3i, solid_target: bool = true) -> Array[Vector3i]:
	var reachable: Array[Vector3i] = []
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var spot := target + Vector3i(dx, dy, dz)
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
		_colony.release_job(job)
	_job_search_cooldown = 1.5
	abandon_job()
