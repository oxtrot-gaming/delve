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
const ACTIONS: Array[StringName] = [
	&"mine",
	&"clear_pile",
	&"build_dirt",
	&"designate_stockpile",
	&"undesignate_stockpile",
	&"spawn_unit",
]
const ACTION_NAMES := {
	&"mine": "Mine",
	&"clear_pile": "Clear pile",
	&"build_dirt": "Build dirt",
	&"designate_stockpile": "Designate stockpile",
	&"undesignate_stockpile": "Undesignate stockpile",
	&"spawn_unit": "Spawn unit",
}
## Seconds the action key must be held before the list pops instead of cycling.
const ACTION_MENU_HOLD := 0.4
## Largest span, in voxels, a designation drag can cover on each axis of its
## plane, including wheel extrusion.
const DRAG_MAX_AXIS := 64
## Seconds a held designation button must stay on its voxel before the box
## "sticks" — a sticky drag survives the release until LMB commits or RMB
## aborts it.
const DRAG_HOLD := 0.25

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
## How far the drag highlight's rendered box overhangs the covered voxels —
## its faces must never sit coplanar with terrain or they z-fight.
const HIGHLIGHT_EXPAND := 0.04

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
## A held designation button, not yet promoted to a drag. `_press_cancel`
## remembers which button is down; `_press_hold` feeds the long-press
## promotion.
var _press_active: bool = false
var _press_cancel: bool = false
var _press_hold: float = 0.0
## Designation drag state: the box lives on the hit face's plane —
## `_drag_axis` is the face normal's axis, the locked one — and extrudes
## along `_drag_normal` by `_drag_extrude` layers (negative digs into the
## face, positive grows toward the camera). A sticky drag survives the
## button release until LMB commits or RMB aborts it.
var _drag_active: bool = false
var _drag_sticky: bool = false
var _drag_cancel: bool = false
var _drag_anchor: Vector3i = Vector3i.ZERO
var _drag_end: Vector3i = Vector3i.ZERO
var _drag_normal: Vector3i = Vector3i.UP
var _drag_axis: int = 1
var _drag_extrude: int = 0
## The highlight mesh's base size; the drag box scales relative to it.
var _highlight_base: Vector3 = Vector3.ONE


func _ready() -> void:
	world = get_node(world_path)
	colony = get_node(colony_path)
	_yaw = rotation.y
	_highlight_material = highlight.material_override as StandardMaterial3D
	var highlight_mesh := highlight.mesh as BoxMesh
	if highlight_mesh != null:
		_highlight_base = highlight_mesh.size
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.5, 1.5)
		return

	# While a drag box is up, the wheel (or PgUp/PgDn) extrudes it along the
	# face normal — scroll down digs into the face, scroll up grows toward
	# the camera.
	if _drag_active:
		if event is InputEventMouseButton and event.pressed:
			var button := (event as InputEventMouseButton).button_index
			if button == MOUSE_BUTTON_WHEEL_DOWN:
				_extrude_drag(-1)
				return
			if button == MOUSE_BUTTON_WHEEL_UP:
				_extrude_drag(1)
				return
		elif event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
			var key := (event as InputEventKey).keycode
			if key == KEY_PAGEDOWN:
				_extrude_drag(-1)
				return
			if key == KEY_PAGEUP:
				_extrude_drag(1)
				return

	if event.is_action_pressed(&"toggle_mouse_capture"):
		_cancel_drag()
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event.is_action_pressed(&"perform_action"):
		if _drag_active:
			# LMB commits whatever box is up.
			_commit_drag()
		elif current_action() == &"spawn_unit":
			# Spawning stays a click — a box of new units makes no sense.
			_perform()
		else:
			_begin_press(false)
	elif event.is_action_released(&"perform_action"):
		_release_press(false)
	elif event.is_action_pressed(&"cancel_designation"):
		if _drag_active:
			# RMB aborts the pending box.
			_cancel_drag()
		else:
			_begin_press(true)
	elif event.is_action_released(&"cancel_designation"):
		_release_press(true)
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
	_tick_press(delta)
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
		# A drag keeps its last extent while the cursor sweeps the sky.
		highlight.visible = _drag_active
		return
	highlight.visible = true
	if _press_active and not _drag_active:
		# Aiming off the anchor voxel while held promotes the press to a drag.
		var current := _targeted.position if _press_cancel else _action_voxel()
		if current != _drag_anchor:
			_promote_drag(false)
	if _drag_active:
		_update_drag()
		_update_drag_highlight()
	else:
		# The highlight marks the voxel the selected action would act on —
		# red when the action can't act there.
		var voxel := _action_voxel()
		highlight.global_position = Vector3(voxel) + Vector3.ONE * 0.5
		highlight.scale = Vector3.ONE
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
		&"build_dirt":
			return (
				not world.is_solid(_targeted.previous_position)
				and not colony.is_packed(_targeted.previous_position)
			)
		&"designate_stockpile":
			# Empty, and resting on a solid block.
			var voxel := _targeted.previous_position
			return (
				colony.voxel_fill(voxel) <= 0.0
				and world.is_solid(voxel + Vector3i.DOWN)
				and not colony.is_stockpile(voxel)
			)
		&"undesignate_stockpile":
			return colony.is_stockpile(_targeted.previous_position)
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
	if current_action() == &"spawn_unit":
		colony.spawn_unit(_targeted.previous_position)
	else:
		_designate_at(_action_voxel())


## Applies the selected action to one voxel. Validity is per-voxel in the
## Colony designate functions, so a drag rect simply skips whatever the
## action can't touch.
func _designate_at(voxel_position: Vector3i) -> void:
	match current_action():
		&"mine":
			colony.designate_mine(voxel_position)
		&"clear_pile":
			colony.designate_clear(voxel_position)
		&"build_dirt":
			colony.designate_build(voxel_position, BlockRegistry.Block.DIRT)
		&"designate_stockpile":
			colony.designate_stockpile(voxel_position)
		&"undesignate_stockpile":
			colony.undesignate_stockpile(voxel_position)


## Records a pressed designation button. The voxel it would act on anchors
## the box, and the hit face's normal picks the plane the box lives in —
## aiming along the ground paints a horizontal layer, aiming along a wall
## face paints a vertical section. [param cancel] marks the RMB sweep.
func _begin_press(cancel: bool) -> void:
	if _targeted == null:
		return
	_press_active = true
	_press_cancel = cancel
	_press_hold = 0.0
	_drag_cancel = cancel
	# previous_position is the voxel in front of the hit face, so the
	# difference is the face's outward normal — its axis is the locked one.
	_drag_normal = _targeted.previous_position - _targeted.position
	_drag_axis = _drag_normal.abs().max_axis_index()
	_drag_anchor = _targeted.position if cancel else _action_voxel()
	_drag_end = _drag_anchor
	_drag_extrude = 0


## A press becomes a drag: [param sticky] (long press) boxes survive the
## button release so they can be wheel-extruded and committed with a click;
## plain drags (aim moved while held) commit on release.
func _promote_drag(sticky: bool) -> void:
	_drag_active = true
	_drag_sticky = sticky
	if _targeted != null:
		_update_drag()
	_update_drag_highlight()


## A designation button held on its voxel past [constant DRAG_HOLD] promotes
## to a sticky drag.
func _tick_press(delta: float) -> void:
	if not _press_active or _drag_active:
		return
	_press_hold += delta
	if _press_hold >= DRAG_HOLD:
		_promote_drag(true)


## The designation button came up: a quick click applies the single anchor
## voxel, a plain drag commits its box, and a sticky drag just keeps going.
func _release_press(cancel: bool) -> void:
	if not _press_active or _press_cancel != cancel:
		return
	_press_active = false
	if not _drag_active:
		_apply_press()
	elif not _drag_sticky:
		_commit_drag()


## A click without a drag: the action on the anchor voxel, or a cancel sweep
## on the hit voxel and the air cell in front of it.
func _apply_press() -> void:
	if _press_cancel:
		colony.cancel_designation(_drag_anchor)
		colony.cancel_designation(_drag_anchor + _drag_normal)
	else:
		_designate_at(_drag_anchor)


## Moves the drag's far corner to the voxel under the cursor, locked to the
## anchor's plane and clamped to [constant DRAG_MAX_AXIS] on each side.
func _update_drag() -> void:
	var corner := _targeted.position if _drag_cancel else _action_voxel()
	for axis in 3:
		if axis == _drag_axis:
			corner[axis] = _drag_anchor[axis]
		else:
			corner[axis] = clampi(
				corner[axis],
				_drag_anchor[axis] - DRAG_MAX_AXIS + 1,
				_drag_anchor[axis] + DRAG_MAX_AXIS - 1
			)
	_drag_end = corner


## Extrudes the box along the face normal into a volume: positive
## [param direction] grows out of the face toward the camera, negative digs
## into it. Both directions are allowed — cells the action can't touch are
## simply skipped on commit.
func _extrude_drag(direction: int) -> void:
	if not _drag_active:
		return
	_drag_extrude = clampi(_drag_extrude + direction, 1 - DRAG_MAX_AXIS, DRAG_MAX_AXIS - 1)
	_update_drag_highlight()


## The voxel bounds of the current drag: the anchor↔cursor rect plus any
## wheel-set extrusion along the face normal.
func _drag_bounds() -> Array[Vector3i]:
	var ext_lo := _drag_anchor + _drag_normal * mini(_drag_extrude, 0)
	var ext_hi := _drag_anchor + _drag_normal * maxi(_drag_extrude, 0)
	return [
		_drag_anchor.min(_drag_end).min(ext_lo),
		_drag_anchor.max(_drag_end).max(ext_hi),
	]


## Stretches the highlight over the whole drag box. The tint shows coverage
## rather than validity — per-voxel checks happen on release.
func _update_drag_highlight() -> void:
	var bounds := _drag_bounds()
	var size := Vector3(bounds[1] - bounds[0]) + Vector3.ONE
	highlight.global_position = Vector3(bounds[0]) + size * 0.5
	# Inflated past the covered voxels: faces rendered exactly on voxel
	# boundaries sit coplanar with terrain faces and z-fight.
	highlight.scale = (size + Vector3.ONE * HIGHLIGHT_EXPAND) / _highlight_base
	_highlight_material.albedo_color = (
		HIGHLIGHT_PILE if colony.item_pile_at(_drag_end) != null else HIGHLIGHT_BLOCK
	)


## Drops the drag without applying it — RMB aborts a pending box, and the
## action menu or a mouse-mode toggle interrupts the gesture.
func _cancel_drag() -> void:
	_drag_active = false
	_drag_sticky = false
	_press_active = false
	highlight.scale = Vector3.ONE


## Applies the box: every voxel in it gets the action, or a cancel. A cancel
## sweep also clears the air layer in front of each hit cell — clear and
## stockpile markers live one voxel out from the face.
func _commit_drag() -> void:
	if not _drag_active:
		return
	var cancel := _drag_cancel
	var bounds := _drag_bounds()
	_cancel_drag()
	for x in range(bounds[0].x, bounds[1].x + 1):
		for y in range(bounds[0].y, bounds[1].y + 1):
			for z in range(bounds[0].z, bounds[1].z + 1):
				var voxel := Vector3i(x, y, z)
				if cancel:
					colony.cancel_designation(voxel)
					colony.cancel_designation(voxel + _drag_normal)
				else:
					_designate_at(voxel)


## The list is up: free the cursor so the player can pick from it, and let
## the HUD show it.
func _open_action_menu() -> void:
	# A pending press or mid-drag is dropped; a sticky box survives so the
	# action can be swapped before committing it.
	if not _drag_sticky:
		_cancel_drag()
	_action_menu_open = true
	_action_hold = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	action_menu_requested.emit()


## Called by the HUD when the popup closes, by selection or dismissal.
func menu_closed() -> void:
	if _action_menu_open:
		_action_menu_open = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

