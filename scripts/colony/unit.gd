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
			_tick_moving()
		State.WORKING:
			_tick_working(delta)

	_apply_motion(delta)


func abandon_job() -> void:
	job = null
	_path.clear()
	state = State.IDLE


func current_activity() -> String:
	match state:
		State.MOVING:
			return "walking to %s" % str(job.voxel_position) if job != null else "walking"
		State.WORKING:
			return "mining %s" % BlockRegistry.block_name(_world.get_block(job.voxel_position)) if job != null else "working"
		_:
			return "idle"


func _tick_idle() -> void:
	if _job_search_cooldown > 0.0:
		return
	_job_search_cooldown = 0.5
	job = _colony.claim_job(self)
	if job == null:
		return
	if _repath_to_job():
		state = State.MOVING
	else:
		_give_up_on_job()


func _tick_moving() -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	if _can_mine(job.voxel_position):
		_path.clear()
		state = State.WORKING
		return

	if _path_index >= _path.size():
		if _repath_cooldown > 0.0:
			return
		if not _repath_to_job():
			_give_up_on_job()
		return

	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	if Vector2(to_waypoint.x, to_waypoint.z).length() < 0.35:
		_path_index += 1
		return

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
	var nearest := from.clamp(Vector3(voxel_position), Vector3(voxel_position) + Vector3.ONE)
	var to_face := nearest - from
	var distance := to_face.length()
	if distance > mine_reach:
		return false
	if distance < 0.01:
		return true
	var hit := _world.raycast(from, to_face / distance, distance + 0.5)
	return hit != null and hit.position == voxel_position


func _repath_to_job() -> bool:
	_repath_cooldown = 1.0
	_path.clear()
	_path_index = 0
	if job == null:
		return false

	var start := _standing_voxel()
	for target in _work_spots(job.voxel_position):
		var path := _world.find_path(start, target)
		if not path.is_empty():
			_path = path
			return true
	return false


## Voxel the unit currently stands in.
func _standing_voxel() -> Vector3i:
	return Vector3i(floori(global_position.x), roundi(global_position.y - 0.9), floori(global_position.z))


## Standable voxels a unit could mine [param target] from, nearest first.
## Scans the box of spots whose centre is plausibly in reach — a spot counts
## only if mining the target from it passes the same check the unit uses.
func _work_spots(target: Vector3i) -> Array[Vector3i]:
	var reachable: Array[Vector3i] = []
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var spot := target + Vector3i(dx, dy, dz)
				if not _world.is_standable(spot):
					continue
				if _can_mine_from(Vector3(spot) + Vector3(0.5, 0.9, 0.5), target):
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
