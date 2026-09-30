class_name Overseer
extends Node3D

## The player: a Timberborn-style strategy camera — a boom orbiting a
## focus point that rides the terrain — that designates work with a free
## cursor rather than mining itself. Carries the [VoxelViewer] that
## streams terrain around the view.
##
## Controls: WASD/arrows or the screen edges pan, Q/E rotate (Z/C snap
## 90°), the wheel zooms, MMB-drag pans, RMB-drag orbits, Shift boosts.
## LMB applies the selected tool — drag for a box — RMB-click or Esc
## aborts/deselects. While a drag box is up the wheel extrudes it instead
## of zooming.

signal targeted_voxel_changed(voxel_position: Vector3i, block_id: int)
## Emitted when the action key is held long enough — the HUD shows the list.
## A cursor hit: the voxel struck and the empty voxel in front of the hit
## face. Real hits come from `VoxelRaycastResult` (read-only), so plan
## cells and the terrain share this writable pair — a pending-build ghost
## synthesizes the same fields so every tool treats it alike.
class AimHit:
	var position: Vector3i
	var previous_position: Vector3i

	func _init(hit: Vector3i, before_hit: Vector3i = Vector3i.MAX) -> void:
		position = hit
		previous_position = before_hit if before_hit != Vector3i.MAX else hit


signal action_menu_requested
## Emitted when the action key is pressed again while the list is up.
signal action_menu_dismissed
## Emitted when the inspected building changes — Vector3i.MAX means
## nothing is selected.
signal selection_changed(voxel_position: Vector3i)

## Actions the overseer can perform on the targeted voxel, in cycle order.
## "cancel" is a tool like the others: it paints cancel over a dragged box.
const ACTIONS: Array[StringName] = [
	&"mine",
	&"chop_tree",
	&"forage",
	&"clear_pile",
	&"cancel",
	&"build_dirt_wall",
	&"build_stone_wall",
	&"build_log_wall",
	&"deconstruct",
	&"designate_stockpile",
	&"undesignate_stockpile",
	&"designate_farm",
	&"undesignate_farm",
	&"designate_craft_spot",
	&"designate_bed",
	&"build_ladder",
	&"spawn_unit",
]
const ACTION_NAMES := {
	&"mine": "Mine",
	&"chop_tree": "Chop tree",
	&"forage": "Forage",
	&"clear_pile": "Clear pile",
	&"cancel": "Cancel",
	&"build_dirt_wall": "Build dirt wall",
	&"build_stone_wall": "Build stone wall",
	&"build_log_wall": "Build log wall",
	&"deconstruct": "Deconstruct",
	&"designate_stockpile": "Designate stockpile",
	&"undesignate_stockpile": "Undesignate stockpile",
	&"designate_farm": "Farm field",
	&"undesignate_farm": "Remove farm field",
	&"designate_craft_spot": "Designate crafting spot",
	&"designate_bed": "Place bed",
	&"build_ladder": "Build ladder",
	&"spawn_unit": "Spawn unit",
}
## The build actions and the wall material each one orders — a wall job
## commits to the player's pick at designation, never to whatever's handy.
const BUILD_MATERIALS := {
	&"build_dirt_wall": BlockRegistry.Resource_.SOIL,
	&"build_stone_wall": BlockRegistry.Resource_.STONE,
	&"build_log_wall": BlockRegistry.Resource_.WOOD,
}
## Seconds the action key must be held before the list pops instead of cycling.
const ACTION_MENU_HOLD := 0.4
## Largest span, in voxels, a designation drag can cover on each axis of its
## plane, including wheel extrusion.
const DRAG_MAX_AXIS := 64
## Seconds a held designation button must stay on its voxel before the box
## "sticks" — a sticky drag survives the release until LMB commits or
## Esc/RMB aborts it.
const DRAG_HOLD := 0.25
## Pixels an RMB press can travel before it becomes a camera orbit instead
## of a deselect click.
const RMB_CLICK_SLOP := 5.0

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var colony_path: NodePath = NodePath("../Colony")
## Base pan speed, zoom-scaled — a pulled-out camera crosses ground faster.
@export var pan_speed: float = 16.0
## Q/E rotation speed, radians per second.
@export var rotate_speed: float = 1.9
## Shift multiplies pan and rotation speed, not zoom.
@export var boost_multiplier: float = 3.0
## Orbit sensitivity for RMB-drags.
@export var rotate_sensitivity: float = 0.008
## Middle-drag pan factor, scaled by zoom distance.
@export var drag_pan_factor: float = 0.0022
## Wheel zoom: a per-notch multiplicative step on the boom length.
@export var zoom_step: float = 1.14
@export var min_distance: float = 6.0
@export var max_distance: float = 140.0
## Boom pitch limits, radians — the camera stays overhead, never level.
@export var pitch_min: float = 0.45
@export var pitch_max: float = 1.45
@export var designation_reach: float = 96.0
## Timberborn's edge scrolling: the camera pans when the cursor nears a
## screen edge.
@export var edge_scroll := true
@export var edge_margin: float = 6.0
## Seconds for the focus height to settle onto a terrain change — eases
## the ride across voxel steps and ridge lines instead of snapping.
@export var height_settle: float = 0.12

## Highlight tints: a solid block, an item pile (matching the cyan clearing
## marker), or red when the selected action can't act on the target.
const HIGHLIGHT_BLOCK := Color(1.0, 1.0, 1.0, 0.25)
const HIGHLIGHT_PILE := Color(0.35, 0.85, 1.0, 0.4)
const HIGHLIGHT_INVALID := Color(1.0, 0.25, 0.2, 0.4)
## How far the drag highlight's rendered box overhangs the covered voxels —
## its faces must never sit coplanar with voxel faces or they z-fight.
const HIGHLIGHT_EXPAND := 0.04

@onready var camera: Camera3D = $Camera3D
@onready var highlight: MeshInstance3D = $Highlight

var world: VoxelWorld
var colony: Colony
var _highlight_material: StandardMaterial3D

var _yaw: float = 0.0
## Boom pitch, radians — positive is overhead, ~57° by default.
var _pitch: float = 1.0
## Boom length — the zoom level.
var _distance: float = 28.0
var _targeted: AimHit = null
## The selected tool; -1 is "no tool" — LMB then inspects instead:
## a click on a building selects it for the worksite panel.
var _action_index: int = -1
## The voxel of the building the player has selected for inspection —
## Vector3i.MAX when nothing is selected.
var _selected: Vector3i = Vector3i.MAX
var _action_hold: float = 0.0
var _action_menu_open: bool = false
## A held LMB, not yet promoted to a drag; `_press_hold` feeds the
## long-press promotion.
var _press_active: bool = false
var _press_hold: float = 0.0
## RMB click-vs-orbit and MMB pan state.
var _rmb_pressed: bool = false
var _rmb_moved: float = 0.0
var _mmb_pressed: bool = false
## Designation drag state: the box lives on the hit face's plane —
## `_drag_axis` is the face normal's axis, the locked one — and extrudes
## along `_drag_normal` by `_drag_extrude` layers (negative digs into the
## face, positive grows toward the camera). A sticky drag survives the
## button release until LMB commits or Esc/RMB aborts it.
var _drag_active: bool = false
var _drag_sticky: bool = false
## The zone-override key's state at the first click — zone designations
## resolve their target at commit, keyed on the anchor and this flag.
var _zone_override := false
var _drag_anchor: Vector3i = Vector3i.ZERO
var _drag_end: Vector3i = Vector3i.ZERO
var _drag_normal: Vector3i = Vector3i.UP
var _drag_axis: int = 1
var _drag_extrude: int = 0
## The highlight mesh's base size; the drag box scales relative to it.
var _highlight_base: Vector3 = Vector3.ONE
## Whether the focus height has been placed once — the first terrain ride
## snaps, later changes ease.
var _height_settled: bool = false


func _ready() -> void:
	# The overseer keeps working while the tree is paused: pause is for
	# planning, and the camera/designation tools stay live.
	process_mode = Node.PROCESS_MODE_ALWAYS
	world = get_node(world_path)
	colony = get_node(colony_path)
	_yaw = rotation.y
	_highlight_material = highlight.material_override as StandardMaterial3D
	var highlight_mesh := highlight.mesh as BoxMesh
	if highlight_mesh != null:
		_highlight_base = highlight_mesh.size


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.echo:
		# A held key repeats as echo events — every keybind here is a
		# press-once verb (pause would flicker-toggle off a held Space).
		return

	# Mouse motion: RMB-drag orbits the boom, MMB-drag pans the focus.
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _rmb_pressed:
			_rmb_moved += motion.relative.length()
			if _rmb_moved > RMB_CLICK_SLOP:
				_yaw -= motion.relative.x * rotate_sensitivity
				_pitch = clampf(
					_pitch - motion.relative.y * rotate_sensitivity,
					pitch_min, pitch_max
				)
		elif _mmb_pressed:
			_pan_screen(motion.relative)
		return

	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		match mouse_button.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if not mouse_button.pressed:
					return
				var direction := (
					1 if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP else -1
				)
				# A pending drag takes the wheel for extrusion; otherwise it
				# zooms the boom.
				if _drag_active:
					_extrude_drag(direction)
				else:
					_zoom(direction)
				return
			MOUSE_BUTTON_MIDDLE:
				_mmb_pressed = mouse_button.pressed
				return
			MOUSE_BUTTON_RIGHT:
				if mouse_button.pressed:
					_rmb_pressed = true
					_rmb_moved = 0.0
				else:
					_rmb_pressed = false
					if _rmb_moved <= RMB_CLICK_SLOP:
						_deselect()
				return

	if event.is_action_pressed(&"perform_action"):
		if _drag_active:
			# LMB commits whatever box is up.
			_commit_drag()
		elif _action_index < 0:
			# No tool — the click inspects the building under the cursor.
			_select_at_cursor()
		elif current_action() == &"spawn_unit":
			# Spawning stays a click — a box of new units makes no sense.
			_perform()
		else:
			_begin_press()
	elif event.is_action_released(&"perform_action"):
		_release_press()
	elif event.is_action_pressed(&"pause"):
		colony.set_paused(not get_tree().paused)
	elif event.is_action_pressed(&"deselect"):
		_deselect()
	elif event.is_action_pressed(&"delete_object"):
		# Timberborn's Del: cancel whatever is designated under the cursor.
		if _targeted != null:
			colony.cancel_designation(_targeted.position)
			colony.cancel_designation(_targeted.previous_position)
	elif event.is_action_pressed(&"snap_left"):
		_snap_yaw(1)
	elif event.is_action_pressed(&"snap_right"):
		_snap_yaw(-1)
	elif event.is_action_pressed(&"speed_1"):
		_set_speed(1.0)
	elif event.is_action_pressed(&"speed_2"):
		_set_speed(3.0)
	elif event.is_action_pressed(&"speed_3"):
		_set_speed(6.0)
	elif event.is_action_pressed(&"tick_once"):
		tick_once()
	elif event.is_action_pressed(&"debug_dump"):
		_dump_diagnostics()
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
	# `delta` is game-speed scaled (Engine.time_scale); camera motion and
	# the press/action hold timers are player-facing and want real seconds,
	# or panning triples at 3x and flies during the sleep boost.
	var real_delta := delta / maxf(Engine.time_scale, 0.0001)
	_tick_camera(real_delta)
	_update_target()
	_tick_press(real_delta)
	_tick_action_input(real_delta)


## Camera movement: the focus pans on the ground plane (keys or screen
## edges) and follows the terrain's height; Q/E rotate the boom; then the
## boom repositions the camera.
func _tick_camera(delta: float) -> void:
	var boost := boost_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0
	var turn := 0.0
	var input := Vector2.ZERO
	# A focused text field owns the keyboard: polled axes fire regardless
	# of GUI focus, so without this guard a "w" typed into an order
	# target both edits the field and pans the camera.
	if not _keyboard_claimed():
		turn = Input.get_axis(&"rotate_left", &"rotate_right")
		input = Vector2(
			Input.get_axis(&"move_left", &"move_right"),
			Input.get_axis(&"move_forward", &"move_back")
		)
	_yaw += turn * rotate_speed * boost * delta
	input += _edge_scroll()
	if input != Vector2.ZERO:
		var zoom_scale := 0.3 + _distance * 0.03
		global_position += (
			basis * Vector3(input.x, 0.0, input.y)
			* pan_speed * zoom_scale * boost * delta
		).limit_length(pan_speed * zoom_scale * boost * delta)
	_ride_terrain(delta)
	_apply_boom()


## True while a text-entry control holds keyboard focus — the claim that
## keeps typed keys out of the polled camera axes above. Event-driven
## keys reach `_unhandled_input` only when no control consumed them, so
## only polled state (`get_axis`, `is_key_pressed`) needs the guard.
func _keyboard_claimed() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


## The terrain height under the focus — the topmost solid voxel, skipping
## trees — or NAN while that column isn't loaded. Solid *above* the focus
## only counts when the focus is inside it (a hill face to climb); a
## ceiling over an open focus cell is an overhang, and the camera rides
## the floor beneath it instead of popping to the roof.
func _terrain_height() -> float:
	var x := floori(global_position.x)
	var z := floori(global_position.z)
	var cell := floori(global_position.y)
	var top := world.ground_height(x, z, 96, -32, true)
	if top <= -32:
		return NAN
	if top >= cell and not world.is_solid(Vector3i(x, cell, z)):
		top = world.ground_height(x, z, cell - 1, -32, true)
		if top <= -32:
			return NAN
	return float(top) + 1.0


## The focus point rides the terrain: it eases toward the ground height
## under it instead of snapping, so voxel steps, ridges and freshly dug
## pits pull the camera smoothly rather than jolting it. The first
## placement snaps — the camera should start on the ground, not glide in.
func _ride_terrain(delta: float) -> void:
	var target_y := _terrain_height()
	if is_nan(target_y):
		return
	if not _height_settled:
		_height_settled = true
		global_position.y = target_y
	else:
		global_position.y = lerpf(
			global_position.y, target_y, 1.0 - exp(-delta / height_settle)
		)


## Positions the camera on the boom: [member _distance] out along the
## orbit, pitched down onto the focus.
func _apply_boom() -> void:
	rotation = Vector3(0.0, _yaw, 0.0)
	camera.position = Vector3(
		0.0, _distance * sin(_pitch), _distance * cos(_pitch)
	)
	camera.rotation = Vector3(-_pitch, 0.0, 0.0)


## Grab-the-ground pan for MMB drags: the world follows the cursor.
func _pan_screen(relative: Vector2) -> void:
	global_position += (
		basis * Vector3(-relative.x, 0.0, -relative.y) * (_distance * drag_pan_factor)
	)


## Timberborn's edge scrolling: cursor near a screen edge pans the camera.
func _edge_scroll() -> Vector2:
	if (
		not edge_scroll
		or DisplayServer.get_name() == "headless"
		or not DisplayServer.window_is_focused()
		or _rmb_pressed
		or _mmb_pressed
	):
		return Vector2.ZERO
	var viewport := get_viewport()
	var position := viewport.get_mouse_position()
	var size := viewport.get_visible_rect().size
	var pan := Vector2.ZERO
	if position.x < edge_margin:
		pan.x -= 1.0
	elif position.x > size.x - edge_margin:
		pan.x += 1.0
	if position.y < edge_margin:
		pan.y -= 1.0
	elif position.y > size.y - edge_margin:
		pan.y += 1.0
	return pan


func _zoom(direction: int) -> void:
	_distance = clampf(
		_distance * (zoom_step if direction < 0 else 1.0 / zoom_step),
		min_distance, max_distance
	)


## Z/C snap the camera to the next 90° heading in [param direction].
func _snap_yaw(direction: int) -> void:
	var step := PI / 2.0
	_yaw = snappedf(_yaw + direction * step * 0.5, step)


func _set_speed(scale: float) -> void:
	# The colony is the single speed authority — routing through it keeps
	# the sleep boost from fighting a manual setting.
	colony.set_speed(scale)


## Timberborn's "tick once": pauses the game and advances a single physics
## step — useful to watch a job resolve frame by frame. `physics_frame`
## emits *before* the nodes' physics callbacks run, so the pause can't
## come back until one more frame has been awaited — otherwise the same
## step gets gated off and the tick does nothing.
func tick_once() -> void:
	if not get_tree().paused:
		return
	get_tree().paused = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	get_tree().paused = true


## Held past ACTION_MENU_HOLD, the action key opens the list instead of
## cycling; a shorter press cycles on release.
func _tick_action_input(delta: float) -> void:
	if _action_hold <= 0.0:
		return
	_action_hold += delta
	if _action_hold >= ACTION_MENU_HOLD and not _action_menu_open:
		_open_action_menu()


func targeted_voxel() -> AimHit:
	return _targeted


## Centres the focus on [param target_position] — the colonist bar's
## jump-to-unit. A jump snaps to the ground immediately rather than easing.
func jump_to(target_position: Vector3) -> void:
	global_position = target_position
	var target_y := _terrain_height()
	if not is_nan(target_y):
		global_position.y = target_y


## Raycast from the screen position — the mouse cursor in play, an
## explicit position in tests — to the voxel under it.
func _update_target(screen_pos := Vector2(-1.0, -1.0)) -> void:
	if screen_pos.x < 0.0:
		screen_pos = get_viewport().get_mouse_position()
	if get_viewport().gui_get_hovered_control() != null:
		# The cursor is over a panel — nothing is being aimed at.
		_targeted = null
		highlight.visible = false
		return
	var reach := maxf(designation_reach, _distance * 1.6)
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var real := world.raycast(origin, direction, reach)
	_targeted = AimHit.new(real.position, real.previous_position) if real != null else null
	# Pending constructions are aimable ghosts while plans are visible: a
	# plan cell stops the ray so a wall can be painted on the face of one
	# that isn't built yet (and deconstruct can cancel it).
	var ghost := _raycast_plans(origin, direction, reach)
	if ghost != null:
		_targeted = ghost
	if _targeted == null:
		# A drag keeps its last extent while the cursor sweeps the sky.
		highlight.visible = _drag_active
		return
	highlight.visible = _action_index >= 0 or _drag_active
	if _press_active and not _drag_active:
		# Aiming off the anchor voxel while held promotes the press to a drag.
		if _action_voxel() != _drag_anchor:
			_promote_drag(false)
	if _drag_active:
		_update_drag()
		_update_drag_highlight()
	elif _action_index >= 0:
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


## Walks the ray voxel-by-voxel (Amanatides–Woo) looking for a pending
## build — a plan cell in front of the real hit counts as the hit, so its
## faces can host the next designation. Hidden plans don't block the ray.
## The walk stops at the real hit voxel: terrain closer than the plan
## always wins.
func _raycast_plans(origin: Vector3, direction: Vector3, max_distance: float) -> AimHit:
	if not colony.plans_visible():
		return null
	var stop := _targeted.position if _targeted != null else Vector3i.MAX
	var cell := Vector3i(
		floori(origin.x), floori(origin.y), floori(origin.z)
	)
	var step := Vector3i(
		1 if direction.x > 0.0 else -1,
		1 if direction.y > 0.0 else -1,
		1 if direction.z > 0.0 else -1
	)
	# Distance the ray travels to cross one voxel on each axis, and the
	# distance to the first crossing on each.
	var t_delta := Vector3(
		absf(1.0 / direction.x) if direction.x != 0.0 else INF,
		absf(1.0 / direction.y) if direction.y != 0.0 else INF,
		absf(1.0 / direction.z) if direction.z != 0.0 else INF
	)
	var boundary := Vector3(
		float(cell.x + (1 if step.x > 0 else 0)),
		float(cell.y + (1 if step.y > 0 else 0)),
		float(cell.z + (1 if step.z > 0 else 0))
	)
	var t_max := Vector3(
		(boundary.x - origin.x) / direction.x if direction.x != 0.0 else INF,
		(boundary.y - origin.y) / direction.y if direction.y != 0.0 else INF,
		(boundary.z - origin.z) / direction.z if direction.z != 0.0 else INF
	)
	var travelled := 0.0
	var previous := cell
	for i in 512:
		if t_max.x < t_max.y and t_max.x < t_max.z:
			cell.x += step.x
			travelled = t_max.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			cell.y += step.y
			travelled = t_max.y
			t_max.y += t_delta.y
		else:
			cell.z += step.z
			travelled = t_max.z
			t_max.z += t_delta.z
		if travelled > max_distance or cell == stop:
			return null
		if colony.plan_job_at(cell) != null:
			return AimHit.new(cell, previous)
		previous = cell
	return null


## The voxel the current action acts on: mining and chopping hit the block
## itself; the others act on the air voxel in front of the face. Chopping
## also resolves the air cell — saplings and leaves are decorations in it,
## so the ray passes through them to whatever's behind.
func _action_voxel() -> Vector3i:
	if current_action() == &"mine":
		return _targeted.position
	if current_action() == &"chop_tree":
		if colony.forest.tree_root_at(_targeted.position) != Vector3i.MAX:
			return _targeted.position
		return _targeted.previous_position
	if current_action() == &"cancel":
		return _targeted.position
	if current_action() == &"deconstruct":
		# Walls are solid — the hit block. A pending plan is an aimable
		# air cell the ray stopped on. A worksite sits in previous_position.
		if (
			colony.building_at(_targeted.position) != null
			or colony.plan_job_at(_targeted.position) != null
		):
			return _targeted.position
		return _targeted.previous_position
	return _targeted.previous_position


## Whether the current action can act on its target voxel.
func _action_valid() -> bool:
	if BUILD_MATERIALS.has(current_action()):
		return (
			world.get_block(_targeted.previous_position) == BlockRegistry.Block.AIR
			and not colony.is_packed(_targeted.previous_position)
			and colony.forest.tree_root_at(_targeted.previous_position) == Vector3i.MAX
		)
	match current_action():
		&"mine":
			# Tree parts are felled whole — chop instead of mining them.
			return (
				world.is_solid(_targeted.position)
				and colony.forest.tree_root_at(_targeted.position) == Vector3i.MAX
			)
		&"chop_tree":
			# Trunk and branch voxels hit directly; a sapling or leaf cell
			# is air the ray passed through, so it sits in previous_position.
			return (
				colony.forest.tree_root_at(_targeted.position) != Vector3i.MAX
				or colony.forest.tree_root_at(_targeted.previous_position) != Vector3i.MAX
			)
		&"forage":
			# A bush's cell is air the ray passed through — the same
			# resolution a pile gets; only a ripe bush can be designated.
			var bush := colony.plants.bush_at(_targeted.previous_position)
			return (
				bush != Vector3i.MAX
				and colony.plants.can_forage(bush)
				and not colony.is_designated(bush)
			)
		&"clear_pile":
			return colony.item_pile_at(_targeted.previous_position) != null
		&"cancel":
			return (
				colony.is_designated(_targeted.position)
				or colony.is_designated(_targeted.previous_position)
				or colony.forest.tree_root_at(_targeted.position) != Vector3i.MAX
			)
		&"designate_stockpile":
			# Empty, and resting on a solid block.
			var voxel := _targeted.previous_position
			return (
				world.get_block(voxel) == BlockRegistry.Block.AIR
				and colony.voxel_fill(voxel) <= 0.0
				and world.is_solid(voxel + Vector3i.DOWN)
				and not colony.is_stockpile(voxel)
			)
		&"undesignate_stockpile":
			return colony.is_stockpile(_targeted.previous_position)
		&"designate_farm":
			# Empty, unclaimed, and resting on a solid block — the zone is
			# permissive; the sow gate decides which cells actually grow.
			var voxel := _targeted.previous_position
			return (
				world.get_block(voxel) == BlockRegistry.Block.AIR
				and colony.voxel_fill(voxel) <= 0.0
				and world.is_solid(voxel + Vector3i.DOWN)
				and colony.building_at(voxel) == null
				and colony.farm_at(voxel) == null
				and colony.forest.tree_root_at(voxel) == Vector3i.MAX
				and colony.plants.bush_at(voxel) == Vector3i.MAX
				and not colony.is_stockpile(voxel)
			)
		&"undesignate_farm":
			return colony.farm_at(_targeted.previous_position) != null
		&"designate_craft_spot":
			# Empty, unclaimed by a tree, and resting on a solid block.
			var voxel := _targeted.previous_position
			return (
				world.get_block(voxel) == BlockRegistry.Block.AIR
				and colony.voxel_fill(voxel) <= 0.0
				and world.is_solid(voxel + Vector3i.DOWN)
				and colony.forest.tree_root_at(voxel) == Vector3i.MAX
				and not colony.is_stockpile(voxel)
				and not colony.is_craft_spot(voxel)
			)
		&"designate_bed":
			# A bed claims the hit cell plus a free neighbor — validity is
			# that a second cell exists.
			return colony.bed_cells(_targeted.previous_position).size() == 2
		&"build_ladder":
			# Any open air cell — a ladder hangs without a floor, which is
			# what lets a shaft be dug top-down or climbed bottom-up. A
			# pile already in the cell shares it once built.
			var cell := _targeted.previous_position
			return (
				world.get_block(cell) == BlockRegistry.Block.AIR
				and world.is_editable(cell)
				and not colony.is_designated(cell)
				and colony.building_at(cell) == null
				and colony.forest.tree_root_at(cell) == Vector3i.MAX
			)
		&"deconstruct":
			var building := colony.building_at(_action_voxel())
			return (
				(building != null and building.deconstructable)
				# The tool also cancels a planned build.
				or colony.plan_job_at(_action_voxel()) != null
			)
		&"spawn_unit":
			return (
				world.get_block(_targeted.previous_position) == BlockRegistry.Block.AIR
				and not colony.is_packed(_targeted.previous_position)
			)
	return false


func current_action() -> StringName:
	return ACTIONS[_action_index] if _action_index >= 0 else &"none"


func current_action_label() -> String:
	return ACTION_NAMES[current_action()] if _action_index >= 0 else "Inspect"


func action_count() -> int:
	return ACTIONS.size()


func action_label(index: int) -> String:
	return ACTION_NAMES[ACTIONS[index]]


## -1 deselects to the inspect tool — an LMB click then selects the
## building under the cursor for the worksite panel.
func select_action(index: int) -> void:
	if index >= -1 and index < ACTIONS.size():
		_action_index = index
	if index >= 0:
		_clear_selection()
	# Timberborn: holding a building designator or the deconstruct tool
	# auto-shows the plans view.
	colony.set_plans_tool_active(
		BUILD_MATERIALS.has(current_action())
		or current_action() == &"deconstruct"
		or current_action() == &"designate_bed"
	)


## Selects the building or stockpile tile under the cursor — the
## inspect-tool click.
func _select_at_cursor() -> void:
	var next := Vector3i.MAX
	if _targeted != null:
		if colony.building_at(_targeted.position) != null:
			next = _targeted.position
		elif colony.is_stockpile(_targeted.position):
			next = _targeted.position
		elif colony.farm_at(_targeted.position) != null:
			next = _targeted.position
		elif colony.building_at(_targeted.previous_position) != null:
			next = _targeted.previous_position
		elif colony.is_stockpile(_targeted.previous_position):
			next = _targeted.previous_position
		elif colony.farm_at(_targeted.previous_position) != null:
			next = _targeted.previous_position
	if next != _selected:
		_selected = next
		selection_changed.emit(_selected)


func _clear_selection() -> void:
	if _selected != Vector3i.MAX:
		_selected = Vector3i.MAX
		selection_changed.emit(_selected)


func _cycle_action() -> void:
	select_action((_action_index + 1) % ACTIONS.size())


func _perform() -> void:
	if _targeted == null or not _action_valid():
		return
	if current_action() == &"spawn_unit":
		colony.spawn_unit(_targeted.previous_position)
	else:
		_designate_at(_action_voxel())


## Applies the selected action to one voxel. Validity is per-voxel in the
## Colony designate functions, so a drag rect simply skips whatever the
## action can't touch. Cancel sweeps the air cell in front too — clear and
## stockpile markers live a voxel out from the face.
func _designate_at(voxel_position: Vector3i) -> void:
	if BUILD_MATERIALS.has(current_action()):
		colony.designate_build(voxel_position, BUILD_MATERIALS[current_action()])
		return
	match current_action():
		&"mine":
			colony.designate_mine(voxel_position)
		&"chop_tree":
			colony.designate_chop(voxel_position)
		&"forage":
			colony.designate_forage(voxel_position)
		&"clear_pile":
			colony.designate_clear(voxel_position)
		&"cancel":
			colony.cancel_designation(voxel_position)
			colony.cancel_designation(voxel_position + _drag_normal)
		&"deconstruct":
			colony.designate_deconstruct(voxel_position)
		&"designate_stockpile":
			var sp_cells: Array[Vector3i] = [voxel_position]
			colony.designate_stockpile_cells(
				sp_cells, voxel_position, _zone_override
			)
		&"undesignate_stockpile":
			colony.undesignate_stockpile(voxel_position)
		&"designate_farm":
			var farm_cells: Array[Vector3i] = [voxel_position]
			colony.designate_farm_cells(
				farm_cells, voxel_position, _zone_override
			)
		&"undesignate_farm":
			colony.undesignate_farm(voxel_position)
		&"designate_craft_spot":
			colony.designate_craft_spot(voxel_position)
		&"designate_bed":
			colony.designate_bed(voxel_position)
		&"build_ladder":
			colony.designate_ladder(voxel_position)


## Records a pressed LMB. The voxel the action would act on anchors the
## box, and the hit face's normal picks the plane the box lives in —
## aiming along the ground paints a horizontal layer, aiming along a wall
## face paints a vertical section.
func _begin_press() -> void:
	if _targeted == null or _action_index < 0:
		return
	_press_active = true
	_press_hold = 0.0
	# previous_position is the voxel in front of the hit face, so the
	# difference is the face's outward normal — its axis is the locked one.
	_drag_normal = _targeted.previous_position - _targeted.position
	_drag_axis = _drag_normal.abs().max_axis_index()
	_zone_override = Input.is_action_pressed(&"zone_override")
	_drag_anchor = _action_voxel()
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


## LMB held on its voxel past [constant DRAG_HOLD] promotes to a sticky
## drag.
func _tick_press(delta: float) -> void:
	if not _press_active or _drag_active:
		return
	_press_hold += delta
	if _press_hold >= DRAG_HOLD:
		_promote_drag(true)


## The button came up: a quick click applies the single anchor voxel, a
## plain drag commits its box, and a sticky drag just keeps going.
func _release_press() -> void:
	if not _press_active:
		return
	_press_active = false
	if not _drag_active:
		_designate_at(_drag_anchor)
	elif not _drag_sticky:
		_commit_drag()


## Moves the drag's far corner to the voxel under the cursor, locked to the
## anchor's plane and clamped to [constant DRAG_MAX_AXIS] on each side.
func _update_drag() -> void:
	var corner := _action_voxel()
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
## wheel-set extrusion along the face normal. The normal can point along a
## negative axis (a wall face seen from -x/-z, or a ceiling from below), so
## the extruded corners must be sorted rather than assumed low and high.
func _drag_bounds() -> Array[Vector3i]:
	var ext_a := _drag_anchor + _drag_normal * mini(_drag_extrude, 0)
	var ext_b := _drag_anchor + _drag_normal * maxi(_drag_extrude, 0)
	var ext_lo := ext_a.min(ext_b)
	var ext_hi := ext_a.max(ext_b)
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


## Drops the drag without applying it — Esc or an RMB click aborts a
## pending box, and the action menu interrupts the gesture.
func _cancel_drag() -> void:
	_drag_active = false
	_drag_sticky = false
	_press_active = false
	highlight.scale = Vector3.ONE


## Applies the box: every voxel in it gets the action — a cancel sweep
## clears the air layer in front of each hit cell, where clear and
## stockpile markers live.
func _commit_drag() -> void:
	if not _drag_active:
		return
	var bounds := _drag_bounds()
	var action := current_action()
	_cancel_drag()
	if action == &"designate_stockpile" or action == &"designate_farm":
		# Zones resolve once per gesture: the anchor and the box's zone
		# overlaps pick the target together — per-cell designating would
		# merge into whatever the previous cell just joined.
		var cells: Array[Vector3i] = []
		for x in range(bounds[0].x, bounds[1].x + 1):
			for y in range(bounds[0].y, bounds[1].y + 1):
				for z in range(bounds[0].z, bounds[1].z + 1):
					cells.append(Vector3i(x, y, z))
		if action == &"designate_stockpile":
			colony.designate_stockpile_cells(cells, _drag_anchor, _zone_override)
		else:
			colony.designate_farm_cells(cells, _drag_anchor, _zone_override)
		return
	for x in range(bounds[0].x, bounds[1].x + 1):
		for y in range(bounds[0].y, bounds[1].y + 1):
			for z in range(bounds[0].z, bounds[1].z + 1):
				_designate_at(Vector3i(x, y, z))


## Esc or an RMB click: close the popup, abort the pending box, drop the
## inspected building, or drop the selected tool — in that order.
func _deselect() -> void:
	if _action_menu_open:
		action_menu_dismissed.emit()
	elif _drag_active or _press_active:
		_cancel_drag()
	elif _selected != Vector3i.MAX:
		_clear_selection()
	elif _action_index >= 0:
		select_action(-1)


## The list is up: the cursor is already free, so just let the HUD show it.
func _open_action_menu() -> void:
	# A pending press or mid-drag is dropped; a sticky box survives so the
	# action can be swapped before committing it.
	if not _drag_sticky:
		_cancel_drag()
	_action_menu_open = true
	_action_hold = 0.0
	action_menu_requested.emit()


## Called by the HUD when the popup closes, by selection or dismissal.
func menu_closed() -> void:
	_action_menu_open = false


## F9: dump every unit's decision trail — the ring of state changes and
## goal picks each unit keeps — to the clipboard and user:// so a
## flickering or stuck unit can be inspected after the fact.
func _dump_diagnostics() -> void:
	var text := colony.unit_diagnostics()
	var path := "user://unit_diagnostics.txt"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
		path = ProjectSettings.globalize_path(path)
	else:
		path = "(write failed)"
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(text)
	print("unit diagnostics -> %s (also on clipboard)" % path)
