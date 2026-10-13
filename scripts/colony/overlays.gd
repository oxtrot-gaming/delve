class_name ColonyOverlays
extends Node3D

## The display overlays (PLAN item 64). Each is a MultiMesh heatmap of
## flat tiles over the standing surface near the camera focus —
## "standing surface" means the topmost standable cell per column,
## capped at the slice plane when the player is cutting through the
## ground, so the paint lands where the player is looking.
##
## Beauty paints `Colony.unit_beauty` — the same room-score /
## sight-line read the units use — so the overlay is honest about what
## a colonist standing there would feel. That read costs raycasts, so
## cells compute on a budget: a queue sorted focus-outward, a few per
## frame, re-swept forever so edits drift the paint behind play.
##
## Roofs paints cover class per cell: bounded room, unbounded cover
## (a ledge or cavern ceiling overhead), or open sky — sky cells get
## no tile at all.

## Half the square the overlay enumerates around the focus.
const VIEW_RADIUS := 44
## Focus movement (metres) that re-enumerates the cell set.
const REENUM_DIST := 12.0
## Columns of the rect scanned per frame while enumerating.
const ENUM_COLUMNS := 220
## Beauty cells scored per frame — each costs a sight-line sample.
const BEAUTY_BUDGET := 3
## Roof cells classified per frame — a column probe each, cheap.
const ROOFS_BUDGET := 240
## How far above the generated surface the column scan looks for
## standable ground — a player tower taller than this reads as roof.
const TOP_MARGIN := 24
## Beauty ramp ends: below LO reads squalid, past HI impressive — the
## thresholds the units' thoughts trip on bracket the middle.
const BEAUTY_LO := -0.15
const BEAUTY_HI := 0.30

## Roof classes: 0 open sky (no tile), 1 unbounded cover, 2 room.
enum Cover { SKY, SHADE, ROOM }

var colony: Colony

var _beauty_on := false
var _roofs_on := false
## The focus the cell set was enumerated for — a stale one re-enumerates.
var _focus := Vector3.INF
var _rect := Rect2i()
## Standing cells the overlays paint, in enumeration order.
var _cells: Array[Vector3i] = []
## Column-scan cursors for the in-flight enumeration.
var _enum_x := 0
var _enum_z := 0
var _enumerating := false
## Indices into _cells awaiting a (re)score — focus-outward order.
var _queue: PackedInt32Array = []
var _queue_pos := 0
## Per-cell scores/classes and which instance slot holds each cell —
## a refreshed cell updates its tile in place.
var _beauty_scores: Dictionary = {}
var _cover_classes: Dictionary = {}
var _beauty_slots: Dictionary = {}
var _roof_slots: Dictionary = {}

var _beauty_mm: MultiMeshInstance3D
var _roof_mm: MultiMeshInstance3D


func _ready() -> void:
	_beauty_mm = _make_layer()
	add_child(_beauty_mm)
	_roof_mm = _make_layer()
	add_child(_roof_mm)


## One MultiMesh of translucent floor tiles — instance colour carries
## the score, so a recolour is a buffer poke, not a material swap.
func _make_layer() -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.96, 0.96)
	var mm := MultiMesh.new()
	mm.mesh = quad
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = 0
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.42)
	inst.material_override = mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst


func set_beauty(on: bool) -> void:
	_beauty_on = on
	_beauty_mm.visible = on
	_refresh_state()


func set_roofs(on: bool) -> void:
	_roofs_on = on
	_roof_mm.visible = on
	_refresh_state()


func any_active() -> bool:
	return _beauty_on or _roofs_on


## Per-frame drive from the HUD: the camera focus the region centres
## on. Cheap while nothing is enabled.
func tick(focus: Vector3) -> void:
	if not any_active():
		return
	if _focus == Vector3.INF or _focus.distance_to(focus) > REENUM_DIST:
		_focus = focus
		_begin_enumeration()
	if _enumerating:
		_enumerate_tick()
	else:
		_score_tick()


func _refresh_state() -> void:
	if any_active():
		# Enabling (or toggling between) needs a fresh sweep — a stale
		# rect from an old focus would paint the wrong ground.
		_focus = Vector3.INF
	else:
		_clear_all()


func _clear_all() -> void:
	_cells = []
	_queue = PackedInt32Array()
	_queue_pos = 0
	_enumerating = false
	_beauty_scores.clear()
	_cover_classes.clear()
	_beauty_slots.clear()
	_roof_slots.clear()
	_beauty_mm.multimesh.instance_count = 0
	_roof_mm.multimesh.instance_count = 0


# --- Cell enumeration -----------------------------------------------------


## Starts the column scan: the rect around the focus clipped to the
## site, walked one x-column per ENUM_COLUMNS chunk. Slice mode caps
## the scan so interior floors win over surface ground.
func _begin_enumeration() -> void:
	_clear_all()
	_rect = Rect2i(
		Vector2i(int(_focus.x) - VIEW_RADIUS, int(_focus.z) - VIEW_RADIUS),
		Vector2i(VIEW_RADIUS * 2, VIEW_RADIUS * 2)
	)
	if colony != null and colony.site_bounds.has_area():
		_rect = _rect.intersection(colony.site_bounds)
	_enum_x = _rect.position.x
	_enum_z = _rect.position.y
	_enumerating = true


func _enumerate_tick() -> void:
	var done := 0
	while done < ENUM_COLUMNS and _enum_x < _rect.end.x:
		_enumerate_column(_enum_x, _enum_z)
		_enum_z += 1
		if _enum_z >= _rect.end.y:
			_enum_z = _rect.position.y
			_enum_x += 1
		done += 1
	if _enum_x >= _rect.end.x:
		_enumerating = false
		_begin_queue()


## The topmost standable cell of a column — from just above the
## generated surface (or the slice cap) down to a bounded floor.
func _enumerate_column(x: int, z: int) -> void:
	var world := colony.world
	var top := mini(
		world.predicted_surface_height(x, z) + TOP_MARGIN,
		_slice_cap()
	)
	var bottom := top - 96
	for y in range(top, bottom, -1):
		var cell := Vector3i(x, y, z)
		if world.is_standable(cell):
			_cells.append(cell)
			return


## The slice cut's highest visible cell, or a ceiling that never binds.
func _slice_cap() -> int:
	var cut: Variant = RenderingServer.global_shader_parameter_get(
		"delve_slice_y"
	)
	if cut == null or float(cut) >= SliceView.SLICE_OFF:
		return 1_000_000
	return floori(float(cut)) - 1


## The rescore order: indices sorted by distance to the focus so the
## paint lands centre-out — the patch the player is watching fills first.
func _begin_queue() -> void:
	var order: Array[int] = []
	order.resize(_cells.size())
	for i in _cells.size():
		order[i] = i
	var focus := _focus
	var cells := _cells
	order.sort_custom(
		func(a: int, b: int) -> bool:
			return Vector3(cells[a]).distance_squared_to(focus) \
				< Vector3(cells[b]).distance_squared_to(focus)
	)
	_queue = PackedInt32Array(order)
	_queue_pos = 0


# --- Scoring --------------------------------------------------------------


## Pops budgeted cells off the queue; an emptied queue re-sweeps — the
## overlay trails edits without tracking them. Only queues the active
## overlays need: beauty work skips when only roofs shows.
func _score_tick() -> void:
	if _cells.is_empty():
		return
	if _queue_pos >= _queue.size():
		_begin_queue()
		return
	var beauty_left := BEAUTY_BUDGET if _beauty_on else 0
	var roofs_left := ROOFS_BUDGET if _roofs_on else 0
	while _queue_pos < _queue.size() and (beauty_left > 0 or roofs_left > 0):
		var cell := _cells[_queue[_queue_pos]]
		_queue_pos += 1
		if _beauty_on:
			_paint_beauty(cell, colony.unit_beauty(_eye(cell), cell))
			beauty_left -= 1
		if _roofs_on:
			_paint_roof(cell, _cover_class(cell))
			roofs_left -= 1


## The unit's eye standing at [param cell] — same height Unit feeds
## unit_beauty so the overlay and the thought read one score.
func _eye(cell: Vector3i) -> Vector3:
	return Vector3(cell) + Vector3(0.5, 1.8, 0.5)


func _cover_class(cell: Vector3i) -> int:
	if colony.rooms != null and colony.rooms.room_at(cell) != null:
		return Cover.ROOM
	if colony.sees_sky(cell):
		return Cover.SKY
	return Cover.SHADE


# --- Paint ----------------------------------------------------------------


func _paint_beauty(cell: Vector3i, score: float) -> void:
	_beauty_scores[cell] = score
	var slot: int = _beauty_slots.get(cell, -1)
	if slot < 0:
		slot = _append_tile(_beauty_mm, cell)
		_beauty_slots[cell] = slot
	_beauty_mm.multimesh.set_instance_color(slot, _beauty_color(score))


func _paint_roof(cell: Vector3i, cover: int) -> void:
	_cover_classes[cell] = cover
	var slot: int = _roof_slots.get(cell, -1)
	if cover == Cover.SKY:
		# Sky cells show nothing — a stale tile must clear, and a stale
		# slot stays reserved (shrinking the buffer just for it isn't
		# worth re-packing).
		if slot >= 0:
			_roof_mm.multimesh.set_instance_color(slot, Color(0, 0, 0, 0))
		return
	if slot < 0:
		slot = _append_tile(_roof_mm, cell)
		_roof_slots[cell] = slot
	_roof_mm.multimesh.set_instance_color(slot, _cover_color(cover))


## A floor tile for [param cell] appended to the layer — returns its
## instance index. Tiles sit a hair above the standing cell's floor.
func _append_tile(layer: MultiMeshInstance3D, cell: Vector3i) -> int:
	var mm := layer.multimesh
	var slot := mm.instance_count
	mm.instance_count = slot + 1
	var basis := Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0))
	mm.set_instance_transform(
		slot,
		Transform3D(basis, Vector3(cell) + Vector3(0.5, 0.04, 0.5))
	)
	return slot


## Squalid red through drab tan to lush green — the cell's read of
## where the score lands between the LO/HI ramp ends.
func _beauty_color(score: float) -> Color:
	var t := clampf(
		(score - BEAUTY_LO) / (BEAUTY_HI - BEAUTY_LO), 0.0, 1.0
	)
	var ugly := Color(0.72, 0.14, 0.10)
	var drab := Color(0.50, 0.44, 0.32)
	var lush := Color(0.18, 0.72, 0.28)
	if t < 0.5:
		return ugly.lerp(drab, t * 2.0)
	return drab.lerp(lush, t * 2.0 - 1.0)


func _cover_color(cover: int) -> Color:
	if cover == Cover.ROOM:
		return Color(0.16, 0.62, 0.55)
	return Color(0.42, 0.40, 0.38)


# --- Test reads -----------------------------------------------------------


## The last beauty score computed for [param cell], or NAN before the
## queue reaches it.
func beauty_score_at(cell: Vector3i) -> float:
	return float(_beauty_scores.get(cell, NAN))


func cover_at(cell: Vector3i) -> int:
	return int(_cover_classes.get(cell, Cover.SKY))


## The standing cell the overlay would paint in a column — what the
## tests poke without running a whole enumeration.
func surface_cell(x: int, z: int) -> Vector3i:
	var world := colony.world
	var top := mini(
		world.predicted_surface_height(x, z) + TOP_MARGIN,
		_slice_cap()
	)
	for y in range(top, top - 96, -1):
		var cell := Vector3i(x, y, z)
		if world.is_standable(cell):
			return cell
	return Vector3i(0, -1, 0)
