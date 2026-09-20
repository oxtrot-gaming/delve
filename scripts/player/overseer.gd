class_name Overseer
extends Node3D

## The player: a free-flying camera that designates work rather than mining
## itself. Carries the [VoxelViewer] that streams terrain around the view.

signal targeted_voxel_changed(voxel_position: Vector3i, block_id: int)

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var colony_path: NodePath = NodePath("../Colony")
@export var move_speed: float = 14.0
@export var boost_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.0025
@export var designation_reach: float = 96.0
## Clearance kept between the camera and solid voxels, so the near plane
## never clips into terrain.
@export var camera_margin: float = 0.3

@onready var camera: Camera3D = $Camera3D
@onready var highlight: MeshInstance3D = $Highlight

var world: VoxelWorld
var colony: Colony

var _yaw: float = 0.0
var _pitch: float = -0.35
var _targeted: VoxelRaycastResult = null


func _ready() -> void:
	world = get_node(world_path)
	colony = get_node(colony_path)
	_yaw = rotation.y
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.5, 1.5)
		return

	if event.is_action_pressed(&"toggle_mouse_capture"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event.is_action_pressed(&"designate"):
		_designate()
	elif event.is_action_pressed(&"designate_clear"):
		_designate_clear()
	elif event.is_action_pressed(&"cancel_designation"):
		_cancel()
	elif event.is_action_pressed(&"spawn_unit"):
		_spawn_unit_at_target()


func _process(delta: float) -> void:
	rotation = Vector3(0.0, _yaw, 0.0)
	camera.rotation = Vector3(_pitch, 0.0, 0.0)
	_move(delta)
	_update_target()


func targeted_voxel() -> VoxelRaycastResult:
	return _targeted


func _move(delta: float) -> void:
	var input := Vector3(
		Input.get_axis(&"move_left", &"move_right"),
		Input.get_axis(&"move_down", &"move_up"),
		Input.get_axis(&"move_forward", &"move_back")
	)
	if input == Vector3.ZERO:
		return
	var speed := move_speed * (boost_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var basis := camera.global_transform.basis
	var direction := (basis.x * input.x + Vector3.UP * input.y + basis.z * input.z).normalized()
	_slide(direction * speed * delta)


## Moves the camera by [param step] one axis at a time, in sub-voxel
## increments, stopping before any move that would put it inside solid
## terrain. Sliding along a blocked axis is preserved. If the camera is
## already inside terrain (a chunk generating around it, say) it moves
## freely so it can always fly back out.
func _slide(step: Vector3) -> void:
	if _overlaps_terrain(global_position):
		global_position += step
		return
	for axis in 3:
		var remaining: float = step[axis]
		while absf(remaining) > 0.001:
			var amount := clampf(remaining, -0.45, 0.45)
			var candidate := global_position
			candidate[axis] += amount
			if _overlaps_terrain(candidate):
				break
			global_position = candidate
			remaining -= amount


## True when a box of half-extent [member camera_margin] around
## [param position] touches a solid voxel.
func _overlaps_terrain(position: Vector3) -> bool:
	var margin := Vector3.ONE * camera_margin
	var from := Vector3i((position - margin).floor())
	var to := Vector3i((position + margin).floor())
	for x in range(from.x, to.x + 1):
		for y in range(from.y, to.y + 1):
			for z in range(from.z, to.z + 1):
				if world.is_solid(Vector3i(x, y, z)):
					return true
	return false


func _update_target() -> void:
	_targeted = world.raycast(camera.global_position, -camera.global_transform.basis.z, designation_reach)
	if _targeted == null:
		highlight.visible = false
		return
	highlight.visible = true
	highlight.global_position = Vector3(_targeted.position) + Vector3.ONE * 0.5
	targeted_voxel_changed.emit(_targeted.position, world.get_block(_targeted.position))


func _designate() -> void:
	if _targeted != null:
		colony.designate_mine(_targeted.position)


## The raycast lands on solid terrain; a pile resting on the hit face sits in
## the air voxel just before it.
func _designate_clear() -> void:
	if _targeted != null:
		colony.designate_clear(_targeted.previous_position)


func _cancel() -> void:
	if _targeted != null:
		colony.cancel_designation(_targeted.position)


func _spawn_unit_at_target() -> void:
	if _targeted != null:
		colony.spawn_unit(_targeted.previous_position)
