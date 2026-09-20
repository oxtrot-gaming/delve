class_name Overseer
extends Node3D

## The player: a free-flying camera that designates work rather than mining
## itself. Carries the [VoxelViewer] that streams terrain around the view.

signal targeted_voxel_changed(voxel_position: Vector3i, block_id: int)
## Emitted when the action key is held long enough — the HUD shows the list.
signal action_menu_requested
## Emitted when the action key is pressed again while the list is up.
signal action_menu_dismissed

## Actions the overseer can perform on the targeted voxel, in cycle order.
const ACTIONS: Array[StringName] = [&"mine", &"clear_pile", &"spawn_unit"]
const ACTION_NAMES := {
	&"mine": "Mine",
	&"clear_pile": "Clear pile",
	&"spawn_unit": "Spawn unit",
}
## Seconds the action key must be held before the list pops instead of cycling.
const ACTION_MENU_HOLD := 0.4

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var colony_path: NodePath = NodePath("../Colony")
@export var move_speed: float = 14.0
@export var boost_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.0025
@export var designation_reach: float = 96.0
## Clearance kept between the camera and solid voxels, so the near plane
## never clips into terrain.
@export var camera_margin: float = 0.3

## Highlight tints: a solid block, an item pile (matching the cyan clearing
## marker), or red when the selected action can't act on the target.
const HIGHLIGHT_BLOCK := Color(1.0, 1.0, 1.0, 0.25)
const HIGHLIGHT_PILE := Color(0.35, 0.85, 1.0, 0.4)
const HIGHLIGHT_INVALID := Color(1.0, 0.25, 0.2, 0.4)

@onready var camera: Camera3D = $Camera3D
@onready var highlight: MeshInstance3D = $Highlight

var world: VoxelWorld
var colony: Colony
var _highlight_material: StandardMaterial3D

var _yaw: float = 0.0
var _pitch: float = -0.35
var _targeted: VoxelRaycastResult = null
var _action_index: int = 0
var _action_hold: float = 0.0
var _action_menu_open: bool = false


func _ready() -> void:
	world = get_node(world_path)
	colony = get_node(colony_path)
	_yaw = rotation.y
	_highlight_material = highlight.material_override as StandardMaterial3D
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
	elif event.is_action_pressed(&"perform_action"):
		_perform()
	elif event.is_action_pressed(&"cancel_designation"):
		_cancel()
	elif event.is_action_pressed(&"cycle_action"):
		if _action_menu_open:
			action_menu_dismissed.emit()
		else:
			_action_hold = 0.001
	elif event.is_action_released(&"cycle_action"):
		if _action_hold > 0.0 and not _action_menu_open:
			_cycle_action()
		_action_hold = 0.0


func _process(delta: float) -> void:
	rotation = Vector3(0.0, _yaw, 0.0)
	camera.rotation = Vector3(_pitch, 0.0, 0.0)
	_move(delta)
	_update_target()
	_tick_action_input(delta)


## Held past ACTION_MENU_HOLD, the action key opens the list instead of
## cycling; a shorter press cycles on release.
func _tick_action_input(delta: float) -> void:
	if _action_hold <= 0.0:
		return
	_action_hold += delta
	if _action_hold >= ACTION_MENU_HOLD and not _action_menu_open:
		_open_action_menu()


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
	# The highlight marks the voxel the selected action would act on — red
	# when the action can't act there.
	var voxel := _action_voxel()
	highlight.global_position = Vector3(voxel) + Vector3.ONE * 0.5
	if not _action_valid():
		_highlight_material.albedo_color = HIGHLIGHT_INVALID
	elif colony.item_pile_at(voxel) != null:
		_highlight_material.albedo_color = HIGHLIGHT_PILE
	else:
		_highlight_material.albedo_color = HIGHLIGHT_BLOCK
	targeted_voxel_changed.emit(_targeted.position, world.get_block(_targeted.position))


## The voxel the current action acts on: mining hits the block itself; the
## others act on the air voxel in front of the face.
func _action_voxel() -> Vector3i:
	if current_action() == &"mine":
		return _targeted.position
	return _targeted.previous_position


## Whether the current action can act on its target voxel.
func _action_valid() -> bool:
	match current_action():
		&"mine":
			return world.is_solid(_targeted.position)
		&"clear_pile":
			return colony.item_pile_at(_targeted.previous_position) != null
		&"spawn_unit":
			return not colony.is_packed(_targeted.previous_position)
	return false


func current_action() -> StringName:
	return ACTIONS[_action_index]


func current_action_label() -> String:
	return ACTION_NAMES[current_action()]


func action_count() -> int:
	return ACTIONS.size()


func action_label(index: int) -> String:
	return ACTION_NAMES[ACTIONS[index]]


func select_action(index: int) -> void:
	if index >= 0 and index < ACTIONS.size():
		_action_index = index


func _cycle_action() -> void:
	_action_index = (_action_index + 1) % ACTIONS.size()


func _perform() -> void:
	if _targeted == null or not _action_valid():
		return
	match current_action():
		&"mine":
			colony.designate_mine(_targeted.position)
		&"clear_pile":
			# A pile rests in the air voxel in front of the hit face.
			colony.designate_clear(_targeted.previous_position)
		&"spawn_unit":
			colony.spawn_unit(_targeted.previous_position)


## The list is up: free the cursor so the player can pick from it, and let
## the HUD show it.
func _open_action_menu() -> void:
	_action_menu_open = true
	_action_hold = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	action_menu_requested.emit()


## Called by the HUD when the popup closes, by selection or dismissal.
func menu_closed() -> void:
	if _action_menu_open:
		_action_menu_open = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Cancels whatever is designated at the hit voxel or the voxel in front of
## it — mine markers sit on the block, clear markers on the pile voxel.
func _cancel() -> void:
	if _targeted == null:
		return
	colony.cancel_designation(_targeted.position)
	colony.cancel_designation(_targeted.previous_position)
