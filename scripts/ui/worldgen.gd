class_name Worldgen
extends Node3D

## The entry screen (PLAN item 63's title flow). Stage 0 is the title:
## Continue, New world, the save-slot list, Quit. Stage 1 is the
## options panel —
## seed, the worldgen sliders, and the baseline data package the planet
## is generated under (biome assignment needs its rules) — then the
## planet generates and stage 2 shows it as a rotatable globe: each
## Goldberg cell is drawn in its biome colour over a dark sphere, so
## the grout reads as the cell outlines. Clicking a land tile arms
## Embark; a scenario dropdown beside it picks the starting roster.
## Embarking hands `Main.pending_world` the seed, options, package and
## scenario, and tile, then changes to the colony scene.

const _CELL_SHRINK := 0.045 ## gap between cells — reads as the outline
const _CELL_RADIUS := 1.002 ## biome fill just above the grout sphere
const _RING_RADIUS := 1.006 ## selection ring above everything
const _ZOOM_MIN := 1.45
const _ZOOM_MAX := 4.5

var _camera: Camera3D
var _globe_root: Node3D
var _cells_mesh: MeshInstance3D
var _ring_mesh: MeshInstance3D
var _pin_mesh: MeshInstance3D

var _globe: WorldGlobe
var _selected := -1
var _hover := -1
var _hover_cooldown := 0.0
var _dragging := false
var _press_at := Vector2.ZERO
var _press_moved := 0.0

# Stage 0 widgets — the title.
var _title_panel: PanelContainer
# Stage 1 widgets.
var _options_panel: PanelContainer
var _seed_edit: LineEdit
var _package_select: OptionButton
var _ocean_slider: HSlider
var _temp_slider: HSlider
var _moist_slider: HSlider
var _tilt_slider: HSlider
var _ocean_label: Label
var _temp_label: Label
var _moist_label: Label
var _tilt_label: Label
# Stage 2 widgets.
var _globe_hud: Control
var _status: Label
var _progress: ProgressBar
var _tooltip: Label
var _tile_info: Label
var _scenario_select: OptionButton
var _embark_button: Button


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 0, 2.7)
	_camera.fov = 50.0
	_camera.current = true
	add_child(_camera)

	_globe_root = Node3D.new()
	add_child(_globe_root)
	# The grout: a dark sphere just under the cell fills — the gaps
	# between cells show it as the Goldberg outlines.
	var sphere := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 96
	sm.rings = 48
	var sm_mat := StandardMaterial3D.new()
	sm_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm_mat.albedo_color = Color(0.05, 0.06, 0.08)
	sm.material = sm_mat
	sphere.mesh = sm
	_globe_root.add_child(sphere)
	_cells_mesh = MeshInstance3D.new()
	_globe_root.add_child(_cells_mesh)
	_ring_mesh = MeshInstance3D.new()
	_globe_root.add_child(_ring_mesh)
	_pin_mesh = MeshInstance3D.new()
	_pin_mesh.visible = false
	_globe_root.add_child(_pin_mesh)
	# The globe exists only in stage 2 — hidden until a planet is built.
	_globe_root.visible = false

	var ui := CanvasLayer.new()
	add_child(ui)
	GameOptions.ensure_loaded()
	_build_options_panel(ui)
	_build_globe_hud(ui)
	_build_title(ui)


# --- Stage 0: the title ----------------------------------------------------


## Title card: the game's name over Continue (the newest save), New
## world (stage 1), the save-slot list that replaced stage 1's bare
## Load button, and Quit.
func _build_title(ui: CanvasLayer) -> void:
	_title_panel = PanelContainer.new()
	_title_panel.set_anchors_preset(Control.PRESET_CENTER)
	_title_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_title_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_title_panel.custom_minimum_size = Vector2(380, 0)
	ui.add_child(_title_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 12)
	_title_panel.add_child(box)

	var title := Label.new()
	title.text = "Delve"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 48)
	box.add_child(title)
	var sub := Label.new()
	sub.text = "a colony beneath the world"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.6))
	box.add_child(sub)

	var slots := Main.save_slots()
	var continue_button := Button.new()
	continue_button.text = "Continue"
	continue_button.disabled = slots.is_empty()
	continue_button.tooltip_text = (
		"No saved colonies" if slots.is_empty()
		else "Resume %s" % slots[0]["name"]
	)
	continue_button.pressed.connect(
		func() -> void:
			if not slots.is_empty():
				_load_slot(slots[0]["dir"])
	)
	box.add_child(continue_button)

	var new_button := Button.new()
	new_button.text = "New world"
	new_button.pressed.connect(_on_new_world_pressed)
	box.add_child(new_button)

	if not slots.is_empty():
		var saves_label := Label.new()
		saves_label.text = "Saved colonies"
		saves_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		saves_label.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.6))
		box.add_child(saves_label)
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, 140)
		box.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list)
		for slot in slots:
			var row := Button.new()
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row.text = "%s  —  %s" % [
				slot["name"],
				Time.get_datetime_string_from_unix_time(
					slot["mtime"], true
				).replace("T", " "),
			]
			row.tooltip_text = slot["dir"]
			var dir: String = slot["dir"]
			row.pressed.connect(func() -> void: _load_slot(dir))
			list.add_child(row)

	var quit := Button.new()
	quit.text = "Quit"
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)


func _on_new_world_pressed() -> void:
	_title_panel.hide()
	_options_panel.show()


func _load_slot(dir: String) -> void:
	Main.pending_load = dir
	get_tree().change_scene_to_file("res://scenes/main.tscn")


# --- Stage 1: options ----------------------------------------------------


func _build_options_panel(ui: CanvasLayer) -> void:
	_options_panel = PanelContainer.new()
	_options_panel.set_anchors_preset(Control.PRESET_CENTER)
	_options_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_options_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_options_panel.custom_minimum_size = Vector2(420, 0)
	# The title (stage 0) shows first — New world reveals this.
	_options_panel.visible = false
	ui.add_child(_options_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 12)
	_options_panel.add_child(box)

	var title := Label.new()
	title.text = "New world"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 24)
	box.add_child(title)

	var seed_row := HBoxContainer.new()
	box.add_child(seed_row)
	var seed_label := Label.new()
	seed_label.text = "Seed"
	seed_label.custom_minimum_size.x = 110
	seed_row.add_child(seed_label)
	_seed_edit = LineEdit.new()
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_row.add_child(_seed_edit)
	var dice := Button.new()
	dice.text = "Reroll"
	dice.tooltip_text = "Random seed"
	dice.pressed.connect(_randomize_seed)
	seed_row.add_child(dice)
	_randomize_seed()

	# The baseline data package — biome rules and species tables the
	# generator draws from, so the pick happens before generation.
	var pack_row := HBoxContainer.new()
	box.add_child(pack_row)
	var pack_label := Label.new()
	pack_label.text = "Data package"
	pack_label.custom_minimum_size.x = 110
	pack_row.add_child(pack_label)
	_package_select = OptionButton.new()
	_package_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id in DataPackage.package_ids():
		_package_select.add_item(DataPackage.package_label(id))
		_package_select.set_item_metadata(
			_package_select.item_count - 1, id
		)
	_package_select.item_selected.connect(
		func(_i: int) -> void: _refresh_scenarios()
	)
	pack_row.add_child(_package_select)

	var ocean_row := _slider_row(
		box, "Ocean coverage", WorldGlobe.OCEAN_PCT_MIN, WorldGlobe.OCEAN_PCT_MAX,
		WorldGlobe.OCEAN_PCT_STEP, WorldGlobe.OCEAN_PCT_DEFAULT
	)
	_ocean_slider = ocean_row[0]
	_ocean_label = ocean_row[1]
	_ocean_slider.value_changed.connect(
		func(v: float) -> void: _ocean_label.text = "%d%%" % int(v)
	)
	_ocean_label.text = "%d%%" % int(_ocean_slider.value)

	var temp_row := _slider_row(
		box, "Temperature", WorldGlobe.TEMP_BIAS_MIN_C,
		WorldGlobe.TEMP_BIAS_MAX_C, 0.5, 0.0
	)
	_temp_slider = temp_row[0]
	_temp_label = temp_row[1]
	_temp_slider.value_changed.connect(
		func(v: float) -> void:
			_temp_label.text = "%+.1f °C" % v
	)
	_temp_label.text = "%+.1f °C" % _temp_slider.value

	var moist_row := _slider_row(
		box, "Rainfall", WorldGlobe.MOIST_BIAS_MIN,
		WorldGlobe.MOIST_BIAS_MAX, 0.05, 0.0
	)
	_moist_slider = moist_row[0]
	_moist_label = moist_row[1]
	_moist_slider.value_changed.connect(
		func(v: float) -> void: _moist_label.text = "%+.0f%%" % (v * 100.0)
	)
	_moist_label.text = "%+.0f%%" % (_moist_slider.value * 100.0)

	var tilt_row := _slider_row(
		box, "Axial tilt", 0.0, 60.0, 1.0, 23.44
	)
	_tilt_slider = tilt_row[0]
	_tilt_label = tilt_row[1]
	_tilt_slider.value_changed.connect(
		func(v: float) -> void: _tilt_label.text = "%.0f°" % v
	)
	_tilt_label.text = "%.0f°" % _tilt_slider.value

	var hint := Label.new()
	hint.text = "Oceans and ice caps can't be settled."
	hint.add_theme_font_size_override(&"font_size", 12)
	box.add_child(hint)

	var generate := Button.new()
	generate.text = "Generate world"
	generate.pressed.connect(_on_generate_pressed)
	box.add_child(generate)

	# Saves load from the title's slot list — this only retreats to it.
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(
		func() -> void:
			_options_panel.hide()
			_title_panel.show()
	)
	box.add_child(back)


## A labelled slider row: label, the slider, and a live value readout.
## Returns [slider, value_label] so the caller can wire formatting.
func _slider_row(
	parent: Control, caption: String, lo: float, hi: float,
	step: float, value: float
) -> Array:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size.x = 110
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 64
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	return [slider, value_label]


func _randomize_seed() -> void:
	_seed_edit.text = str(randi() % 1_000_000_000)


func _worldgen_options() -> Dictionary:
	return {
		&"ocean_pct": int(_ocean_slider.value),
		&"temp_bias_c": float(_temp_slider.value),
		&"moist_bias": float(_moist_slider.value),
		&"axial_tilt_deg": float(_tilt_slider.value),
	}


## The staged selections' package/scenario ids — metadata on each
## OptionButton's rows.
func _package_id() -> StringName:
	if _package_select.selected < 0:
		return &"vanilla"
	return StringName(
		_package_select.get_item_metadata(_package_select.selected)
	)


func _scenario_id() -> StringName:
	if _scenario_select == null or _scenario_select.selected < 0:
		return &"lost_tribe"
	return StringName(
		_scenario_select.get_item_metadata(_scenario_select.selected)
	)


## Repopulates the scenario list for the picked baseline package —
## keeps the current pick if it survives, else defaults to Lost Tribe.
func _refresh_scenarios() -> void:
	if _scenario_select == null:
		return
	var keep := _scenario_id()
	_scenario_select.clear()
	for id in DataPackage.scenario_ids_for(_package_id()):
		_scenario_select.add_item(DataPackage.scenario_label(id))
		_scenario_select.set_item_metadata(
			_scenario_select.item_count - 1, id
		)
	var pick := -1
	var fallback := -1
	for i in _scenario_select.item_count:
		var id: StringName = _scenario_select.get_item_metadata(i)
		if id == keep:
			pick = i
		elif id == &"lost_tribe":
			fallback = i
	if pick < 0:
		pick = fallback if fallback >= 0 else 0
	if _scenario_select.item_count > 0:
		_scenario_select.selected = pick


# --- Stage 2: the globe ---------------------------------------------------


func _build_globe_hud(ui: CanvasLayer) -> void:
	_globe_hud = Control.new()
	_globe_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_globe_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_globe_hud.visible = false
	ui.add_child(_globe_hud)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.set_anchors_preset(Control.PRESET_CENTER)
	_status.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_status.grow_vertical = Control.GROW_DIRECTION_BOTH
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.add_theme_font_size_override(&"font_size", 20)
	_globe_hud.add_child(_status)

	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(360, 14)
	_progress.set_anchors_preset(Control.PRESET_CENTER)
	_progress.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_progress.grow_vertical = Control.GROW_DIRECTION_BOTH
	# Point anchors pin the control's top-left corner — back off half
	# the width so the bar's centre lands mid-screen, below the label.
	_progress.position = Vector2(-180.0, 30)
	_progress.show_percentage = false
	_progress.visible = false
	_globe_hud.add_child(_progress)

	_tooltip = Label.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_color_override(
		&"font_color", Color(1, 1, 1, 0.85)
	)
	_globe_hud.add_child(_tooltip)

	var side := PanelContainer.new()
	side.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	side.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	side.grow_vertical = Control.GROW_DIRECTION_BOTH
	side.custom_minimum_size = Vector2(240, 0)
	side.position.x -= 16
	_globe_hud.add_child(side)
	var side_box := VBoxContainer.new()
	side_box.add_theme_constant_override(&"separation", 8)
	side.add_child(side_box)
	var side_title := Label.new()
	side_title.text = "Choose your landing"
	side_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_title.add_theme_font_size_override(&"font_size", 18)
	side_box.add_child(side_title)
	var side_hint := Label.new()
	side_hint.text = "Drag to spin the world.\nClick a tile to inspect it."
	side_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_box.add_child(side_hint)
	_tile_info = Label.new()
	_tile_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_box.add_child(_tile_info)
	# The starting scenario — the embark choice, so it sits with the
	# button that commits it.
	var scn_label := Label.new()
	scn_label.text = "Starting scenario"
	scn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_box.add_child(scn_label)
	_scenario_select = OptionButton.new()
	_refresh_scenarios()
	side_box.add_child(_scenario_select)
	_embark_button = Button.new()
	_embark_button.text = "Embark here"
	_embark_button.disabled = true
	_embark_button.pressed.connect(_on_embark_pressed)
	side_box.add_child(_embark_button)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_on_back_pressed)
	side_box.add_child(back)


func _on_generate_pressed() -> void:
	var seed := _seed_edit.text.to_int()
	if not _seed_edit.text.is_valid_int():
		_randomize_seed()
		seed = _seed_edit.text.to_int()
	# The planet generates under the chosen package — biome rules and
	# species tables are the pack's, so install before the globe builds.
	DataPackage.install(_package_id(), _scenario_id())
	_options_panel.hide()
	_title_panel.hide()
	_globe_hud.visible = true
	_status.text = "Generating planet…"
	_progress.visible = true
	_progress.value = 0
	await get_tree().process_frame
	_globe = WorldGlobe.new(seed, _worldgen_options())
	# Pumped so the status bar above keeps painting during the ~10 s
	# tiling/field build instead of freezing the window.
	await _globe.generate(true)
	_progress.value = 45
	_status.text = "Raising continents…"
	await get_tree().process_frame
	await _build_cells_mesh()
	_status.hide()
	_progress.hide()
	_globe_root.visible = true
	_selected = -1
	_tile_info.text = ""
	_embark_button.disabled = true


func _on_back_pressed() -> void:
	_globe = null
	_globe_root.visible = false
	_globe_hud.visible = false
	_options_panel.show()


## The biome-fill mesh: one shrunk polygon fan per cell over the grout
## sphere. ~180k fans ≈ 3M indices — built once per generation with a
## progress yield so the UI stays alive.
func _build_cells_mesh() -> void:
	var n := WorldGlobe.TILE_COUNT
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	verts.resize(n * 7)
	colors.resize(n * 7)
	idx.resize(n * 6 * 3)
	var vi := 0
	var ii := 0
	var rock := Color(0.45, 0.42, 0.38)
	for t in n:
		var c := _globe.centers[t]
		var color := _globe.biome_color(t)
		# High ground fades toward rock so ranges read at a glance.
		var h := _globe.height_m[t]
		if h > 2200.0:
			color = color.lerp(rock, clampf((h - 2200.0) / 2200.0, 0.0, 0.85))
		var corners := _globe.cell_corners(t)
		verts[vi] = c * _CELL_RADIUS
		colors[vi] = color
		var deg := corners.size()
		for k in deg:
			verts[vi + 1 + k] = (
				(corners[k] + (c - corners[k]) * _CELL_SHRINK)
				.normalized() * _CELL_RADIUS
			)
			colors[vi + 1 + k] = color
		for k in deg:
			# Clockwise from outside — Godot's front-face winding; the
			# corners are CCW in the cell's tangent frame.
			idx[ii] = vi
			idx[ii + 1] = vi + 1 + (k + 1) % deg
			idx[ii + 2] = vi + 1 + k
			ii += 3
		vi += 7
		if t % 15000 == 0:
			_progress.value = 45.0 + 55.0 * t / n
			await get_tree().process_frame
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mesh.surface_set_material(0, mat)
	_cells_mesh.mesh = mesh


## The selected tile redrawn as a solid gold cap over the cell — a
## 15 km hex is ~2 px at full zoom, so a mere outline would vanish;
## the fill reads as a bright speck far out and a highlighted cell
## zoomed in.
func _show_ring(tile: int) -> void:
	var c := _globe.centers[tile]
	var corners := _globe.cell_corners(tile)
	var deg := corners.size()
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	verts.resize(deg + 1)
	verts[0] = c * _RING_RADIUS
	for k in deg:
		verts[k + 1] = corners[k] * _RING_RADIUS
	for k in deg:
		# Clockwise from outside — Godot's front-face winding.
		idx.append_array([0, (k + 1) % deg + 1, k + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.82, 0.25)
	mesh.surface_set_material(0, mat)
	# A gold pin orbiting just over the cell — the cell fill is a
	# ~2 px speck at full zoom, so the pin carries the read-back.
	var pin := SphereMesh.new()
	pin.radius = 0.012
	pin.height = 0.024
	pin.radial_segments = 24
	pin.rings = 12
	pin.material = mat
	_pin_mesh.mesh = pin
	_pin_mesh.position = c * _RING_RADIUS
	_pin_mesh.visible = true
	_ring_mesh.mesh = mesh


func _hide_ring() -> void:
	_ring_mesh.mesh = null
	_pin_mesh.visible = false


## Tile the screen point sits over, or -1 off the planet. The pick ray
## is analytic — a unit sphere at the globe root — then resolved to a
## cell. [param exact] uses the O(n) [method WorldGlobe.tile_at] for
## clicks; hover takes the fast [method WorldGlobe.pick_tile].
func _tile_at_screen(screen_pos: Vector2, exact := false) -> int:
	if _globe == null:
		return -1
	var ro := _camera.project_ray_origin(screen_pos)
	var rd := _camera.project_ray_normal(screen_pos)
	var inv := _globe_root.global_transform.affine_inverse()
	var o: Vector3 = inv * ro
	var d := (inv.basis * rd).normalized()
	var b := o.dot(d)
	var disc := b * b - (o.dot(o) - 1.0)
	if disc < 0.0:
		return -1
	var t := -b - sqrt(disc)
	if t < 0.0:
		return -1
	var hit := (o + d * t).normalized()
	return _globe.tile_at(hit) if exact else _globe.pick_tile(hit)


static func _tile_settleable(globe: WorldGlobe, tile: int) -> bool:
	return globe.settleable(tile)


func _tile_caption(tile: int) -> String:
	var s := _globe.biome_name(tile)
	if not _tile_settleable(_globe, tile):
		return "%s · %.0f °C" % [s, _globe.temp_c[tile]]
	return "%s · %s\n%.0f °C · %.0f cm/yr · %d m" % [
		s,
		"settleable" if _tile_settleable(_globe, tile) else "no landing",
		_globe.temp_c[tile], _globe.precip[tile],
		roundi(_globe.height_m[tile]),
	]


func _on_tile_clicked(tile: int) -> void:
	if tile < 0:
		return
	if not _tile_settleable(_globe, tile):
		_tile_info.text = "%s — cannot settle here." % _globe.biome_name(tile)
		return
	_selected = tile
	_tile_info.text = _tile_caption(tile)
	_embark_button.disabled = false
	_show_ring(tile)


## Stage the world for Main's fresh-boot path — kept apart from the
## scene change so tests can drive it without tearing the suite down.
func _stage_world() -> void:
	if _selected < 0 or _globe == null:
		return
	var opts := _worldgen_options()
	Main.pending_world = {
		&"seed": _seed_edit.text.to_int(),
		&"ocean_pct": opts[&"ocean_pct"],
		&"temp_bias_c": opts[&"temp_bias_c"],
		&"moist_bias": opts[&"moist_bias"],
		&"axial_tilt_deg": opts[&"axial_tilt_deg"],
		&"world_tile": _selected,
		&"package": _package_id(),
		&"scenario": _scenario_id(),
	}


func _on_embark_pressed() -> void:
	_stage_world()
	if not Main.pending_world.is_empty():
		get_tree().change_scene_to_file("res://scenes/main.tscn")


# --- Input ----------------------------------------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if _globe == null or not _globe_root.visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.position.z = clampf(
				_camera.position.z - 0.2, _ZOOM_MIN, _ZOOM_MAX
			)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.position.z = clampf(
				_camera.position.z + 0.2, _ZOOM_MIN, _ZOOM_MAX
			)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_press_at = mb.position
				_press_moved = 0.0
			else:
				if _dragging and _press_moved < 6.0:
					# Clicks are worth the exact brute-force pick —
					# pick_tile's neighbour descent can land one cell
					# off on rare irregular tiles, which is fine for a
					# tooltip but not for a settlement choice.
					_on_tile_clicked(_tile_at_screen(mb.position, true))
				_dragging = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			_press_moved += mm.relative.length()
			if _press_moved >= 6.0:
				# Trackball-ish: yaw free, pitch clamped off the poles.
				_globe_root.rotation.y -= mm.relative.x * 0.005
				_globe_root.rotation.x = clampf(
					_globe_root.rotation.x - mm.relative.y * 0.005,
					-1.45, 1.45
				)


func _process(delta: float) -> void:
	# Hover tooltip — throttled; picking is cheap (pick_tile) but not
	# free every motion event.
	if _globe == null or not _globe_root.visible or _status.visible:
		return
	_hover_cooldown -= delta
	if _hover_cooldown > 0.0:
		return
	_hover_cooldown = 0.05
	var pos := get_viewport().get_mouse_position()
	var tile := _tile_at_screen(pos)
	if tile != _hover:
		_hover = tile
		if tile < 0:
			_tooltip.text = ""
		else:
			_tooltip.text = _tile_caption(tile)
	_tooltip.visible = tile >= 0
	_tooltip.position = pos + Vector2(16, 20)
