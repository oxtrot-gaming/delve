class_name Hud
extends CanvasLayer

## RimWorld-style shell around the colony readouts: a resources list
## top-left, a colonist bar across the top, an alerts region top-right,
## cell info bottom-left, and a menu bar along the bottom — the Architect
## menu, stubbed tabs, display toggles, and time controls. Tabs and menu
## entries that need systems the colony doesn't have yet stay visible but
## disabled.

@export var colony_path: NodePath = NodePath("../Colony")
@export var overseer_path: NodePath = NodePath("../Overseer")
@export var day_cycle_path: NodePath = NodePath("../DayCycle")

@onready var action_menu: PopupMenu = $ActionMenu

## Seconds over which the worst frame time is tracked, then reported.
const PERF_WINDOW := 2.0

## The Architect menu's categories. "action" entries map onto the
## overseer's existing actions; "stub" entries stand in for systems the
## colony doesn't have yet and are shown disabled.
const ARCHITECT_MENU: Array[Dictionary] = [
	{
		"label": "Orders",
		"items": [
			{"action": &"mine"}, {"action": &"chop_tree"}, {"action": &"forage"},
			{"action": &"clear_pile"}, {"action": &"cancel"}, {"action": &"deconstruct"},
			{"stub": "Haul"},
		],
	},
	{
		"label": "Zones",
		"items": [
			{"action": &"designate_stockpile"},
			{"action": &"undesignate_stockpile"},
			{"action": &"designate_farm"},
			{"action": &"undesignate_farm"},
			{"stub": "Dumping zone"}, {"stub": "Allowed area"},
		],
	},
	{
		"label": "Structure",
		"items": [
			{"action": &"build_dirt_wall"},
			{"action": &"build_stone_wall"},
			{"action": &"build_log_wall"},
			{"action": &"build_ladder"},
			{"stub": "Door"}, {"stub": "Floor"},
		],
	},
	{
		"label": "Production",
		# A worksite's tasks live on its inspect panel, not here — the
		# menu only places the site itself.
		"items": [
			{"action": &"designate_craft_spot"}, {"stub": "Furnace"},
		],
	},
	{
		"label": "Furniture",
		"items": [{"action": &"designate_bed"}, {"stub": "Table"}],
	},
	{"label": "Power", "items": [{"stub": "Generator"}]},
	{"label": "Security", "items": [{"stub": "Turret"}]},
	{"label": "Dev", "items": [{"action": &"spawn_unit"}]},
]
## Bottom-bar tabs between Architect and Menu — stubs until work
## priorities, assignments, taming, research and the rest exist.
const MENU_TABS: Array[String] = [
	"Work", "Assign", "Animals", "Research", "Factions", "World", "History",
]
## Bottom-right display toggles. "live" ones switch real behavior; the
## rest are stubs for display modes that don't exist yet.
const TOGGLES: Array[Dictionary] = [
	{"label": "Zones", "live": true},
	# Timberborn's plans view: pending builds and deconstruct marks. A
	# wall or deconstruct tool also shows them while it's selected.
	{"label": "Plans", "live": true},
	{"label": "Beauty", "live": false},
	{"label": "Roofs", "live": false},
	{"label": "Home area", "live": false},
	{"label": "Colonist bar", "live": true},
]
## Speed controls: pause plus the multipliers the 1/2/3 keys select.
## The readout beside them is the calendar — the DayCycle's local date
## and time at this site.
const SPEEDS: Array[Dictionary] = [
	{"label": "II", "scale": 0.0},
	{"label": "1x", "scale": 1.0},
	{"label": "3x", "scale": 3.0},
	{"label": "6x", "scale": 6.0},
]

var colony: Colony
var overseer: Overseer
var day_cycle: DayCycle
var _perf_worst_ms := 0.0
var _perf_shown_worst_ms := 0.0
var _perf_window_left := PERF_WINDOW

var _resources_label: Label
var _colonist_bar: HBoxContainer
var _inspect_label: Label
var _perf_label: Label
var _architect_button: Button
var _menu_button: Button
var _menu_popup: PopupMenu
var _speed_buttons: Array[Button] = []
## The sleep-boost toggle — pressed while armed, tinted while engaged.
var _sleep_boost_button: Button
## The inspected building's panel — its name, what it's made of, and the
## task controls a worksite offers (craft orders and their cancellation,
## plus deconstruction).
var _worksite_panel: PanelContainer
var _worksite_title: Label
var _worksite_detail: Label
## One button per recipe in Colony.RECIPE_ORDER — the worksite's orders.
var _worksite_recipes: Dictionary = {}
var _worksite_cancel: Button
var _worksite_deconstruct: Button
## The inspected stockpile tile's panel — its fill and a per-material
## checkbox for what the tile admits. The entries are built once from the
## material table; a category layer is for when the list outgrows it.
var _stockpile_panel: PanelContainer
var _stockpile_title: Label
var _stockpile_detail: Label
var _stockpile_checks: Array[CheckBox] = []
## The inspected farm field's panel — the crop assignment (one toggle
## button per plantable species) and, for tree fields, the auto-chop
## switch.
var _farm_panel: PanelContainer
var _farm_title: Label
var _farm_detail: Label
var _farm_crops: Dictionary = {}
var _farm_auto_chop: CheckBox
var _date_label: Label
## The clicked colonist's panel — name and activity, skill levels with
## progress bars, and the specialize/generalize stance toggle.
var _unit_panel: PanelContainer
var _unit_title: Label
var _unit_skill_rows: Dictionary = {}
var _unit_specialize: CheckBox
var _inspected_unit: Unit = null


func _ready() -> void:
	# The HUD keeps working while the tree is paused so the pause button
	# can be pressed again and designations still land while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	colony = get_node(colony_path)
	overseer = get_node(overseer_path)
	day_cycle = get_node(day_cycle_path)
	overseer.action_menu_requested.connect(_show_action_menu)
	overseer.action_menu_dismissed.connect(action_menu.hide)
	action_menu.popup_hide.connect(overseer.menu_closed)
	colony.unit_spawned.connect(func(_unit: Unit) -> void: _rebuild_colonist_bar())
	overseer.selection_changed.connect(_on_selection_changed)
	_build_ui()


func _process(delta: float) -> void:
	_update_resources()
	_update_inspect()
	_update_selection()
	_update_colonist_bar()
	_update_colonist_panel()
	_update_date()
	_update_perf(delta)
	_sync_speed_buttons()


## A HUD button that never takes keyboard focus — Godot's default
## `ui_accept` (Space/Enter) presses whatever control is focused, and a
## focused button would turn Space into "re-click the Architect button"
## instead of pause.
func _hud_button() -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	return button


func _build_ui() -> void:
	# Full-rect root that lets clicks fall through wherever it isn't a
	# button or panel — the map stays interactable behind the chrome.
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_resources(root)
	_build_colonist_bar(root)
	_build_alerts(root)
	_build_inspect(root)
	_build_worksite(root)
	_build_stockpile(root)
	_build_farm(root)
	_build_colonist_panel(root)
	_build_menu_bar(root)
	_build_menus()


## Top-left resources list — a transparent tally of everything on
## stockpile tiles, like RimWorld's resource readout.
func _build_resources(parent: Control) -> void:
	_resources_label = Label.new()
	_resources_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_resources_label.offset_left = 8
	_resources_label.offset_top = 8
	_resources_label.offset_right = 320
	_resources_label.offset_bottom = 200
	_resources_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_resources_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	parent.add_child(_resources_label)


## Top-center colonist bar — one button per unit; clicking jumps the
## camera to it. RimWorld's bar also shows portraits; names for now.
func _build_colonist_bar(parent: Control) -> void:
	_colonist_bar = HBoxContainer.new()
	_colonist_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_colonist_bar.offset_top = 6
	_colonist_bar.add_theme_constant_override("separation", 2)
	parent.add_child(_colonist_bar)
	_rebuild_colonist_bar()


func _rebuild_colonist_bar() -> void:
	for child in _colonist_bar.get_children():
		child.queue_free()
	for unit in colony.units:
		var button := _hud_button()
		button.text = unit.name
		button.set_meta(&"unit", unit)
		button.pressed.connect(_on_colonist_pressed.bind(unit))
		_colonist_bar.add_child(button)


## Per-frame: each colonist button's tooltip carries its unit's live
## activity and energy.
func _update_colonist_bar() -> void:
	for button: Button in _colonist_bar.get_children():
		var unit := button.get_meta(&"unit") as Unit
		if unit == null or not is_instance_valid(unit):
			continue
		button.tooltip_text = "%s — %s, %d%% rested" % [
			unit.name, unit.current_activity(), int(unit.energy * 100.0)
		]


func _on_colonist_pressed(unit: Unit) -> void:
	if not is_instance_valid(unit):
		return
	if _inspected_unit == unit:
		_inspected_unit = null
	else:
		_inspected_unit = unit
	overseer.jump_to(unit.global_position)


## Bottom-right colonist panel — the picked unit's skills and its
## specialize/generalize stance. Opened by clicking a colonist bar
## button; clicking the same button again closes it.
func _build_colonist_panel(parent: Control) -> void:
	_unit_panel = PanelContainer.new()
	_unit_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_unit_panel.offset_left = -240
	_unit_panel.offset_top = -190
	_unit_panel.offset_bottom = -8
	_unit_panel.offset_right = -8
	_unit_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_unit_panel.add_child(vbox)
	_unit_title = Label.new()
	_unit_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_unit_title)
	for skill in ColonyJob.Skill.values():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		label.custom_minimum_size.x = 120
		row.add_child(label)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(80, 10)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.min_value = 0
		bar.max_value = 1
		bar.step = 0.01
		bar.show_percentage = false
		row.add_child(bar)
		vbox.add_child(row)
		_unit_skill_rows[skill] = {"label": label, "bar": bar}
	_unit_specialize = CheckBox.new()
	_unit_specialize.text = "Specialize"
	_unit_specialize.tooltip_text = (
		"Favour jobs this unit is skilled at, even over nearer work. "
		+ "Off: take the closest job."
	)
	_unit_specialize.focus_mode = Control.FOCUS_NONE
	_unit_specialize.toggled.connect(
		func(on: bool) -> void:
			if _inspected_unit != null and is_instance_valid(_inspected_unit):
				_inspected_unit.specialize = on
	)
	vbox.add_child(_unit_specialize)
	parent.add_child(_unit_panel)


func _update_colonist_panel() -> void:
	if _inspected_unit == null or not is_instance_valid(_inspected_unit):
		_unit_panel.visible = false
		return
	_unit_panel.visible = true
	_unit_title.text = "%s — %s" % [
		_inspected_unit.name, _inspected_unit.current_activity()
	]
	for skill: int in _unit_skill_rows:
		var row: Dictionary = _unit_skill_rows[skill]
		row["label"].text = "%s  L%d" % [
			ColonyJob.SKILL_NAMES[skill], _inspected_unit.skill_level(skill)
		]
		row["bar"].value = _inspected_unit.skill_progress(skill)
	_unit_specialize.set_pressed_no_signal(_inspected_unit.specialize)


## Top-right alerts region — empty until something produces alerts.
func _build_alerts(parent: Control) -> void:
	var alerts := VBoxContainer.new()
	alerts.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	alerts.offset_left = -320
	alerts.offset_top = 6
	parent.add_child(alerts)


## Bottom-left inspect pane — the cell info under the cursor plus the
## selected action, controls hints, and the perf readout.
func _build_inspect(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 8
	panel.offset_top = -140
	panel.offset_bottom = -42
	panel.offset_right = 470
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)
	_inspect_label = Label.new()
	vbox.add_child(_inspect_label)
	var hints := Label.new()
	hints.text = (
		"[LMB] tool · drag: box · wheel: zoom (drag: extrude) · [Q/E][Z/C] rotate"
		+ " · [MMB] pan · [RMB] deselect · [Space] pause · [1-3] speed · [.] tick"
	)
	hints.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	vbox.add_child(hints)
	_perf_label = Label.new()
	_perf_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	vbox.add_child(_perf_label)
	parent.add_child(panel)


## Above the inspect pane: the selected building's panel — its name and
## composition, and the controls a worksite offers: order a craft, cancel
## the running order, or mark the thing for deconstruction.
func _build_worksite(parent: Control) -> void:
	_worksite_panel = PanelContainer.new()
	_worksite_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_worksite_panel.offset_left = 8
	_worksite_panel.offset_top = -260
	_worksite_panel.offset_bottom = -146
	_worksite_panel.offset_right = 470
	_worksite_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_worksite_panel.add_child(vbox)
	_worksite_title = Label.new()
	_worksite_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_worksite_title)
	_worksite_detail = Label.new()
	_worksite_detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	vbox.add_child(_worksite_detail)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vbox.add_child(row)
	for recipe_id in Colony.RECIPE_ORDER:
		var recipe := _hud_button()
		recipe.text = Colony.RECIPES[recipe_id]["label"]
		recipe.tooltip_text = "Order this craft at the spot"
		recipe.pressed.connect(
			func() -> void: colony.designate_craft(overseer._selected, recipe_id)
		)
		row.add_child(recipe)
		_worksite_recipes[recipe_id] = recipe
	_worksite_cancel = _hud_button()
	_worksite_cancel.text = "Cancel order"
	_worksite_cancel.tooltip_text = "Drop the craft order queued here"
	_worksite_cancel.pressed.connect(
		func() -> void: colony.cancel_craft_order(overseer._selected)
	)
	row.add_child(_worksite_cancel)
	_worksite_deconstruct = _hud_button()
	_worksite_deconstruct.text = "Deconstruct"
	_worksite_deconstruct.tooltip_text = "Have a unit take this apart"
	_worksite_deconstruct.pressed.connect(
		func() -> void: colony.designate_deconstruct(overseer._selected)
	)
	row.add_child(_worksite_deconstruct)
	parent.add_child(_worksite_panel)


## The stockpile tile's panel: what the tile admits, as a checkbox per
## material class. Flipping one updates the tile's filter — rejected
## contents become haul-out candidates on the next idle haul pass.
func _build_stockpile(parent: Control) -> void:
	_stockpile_panel = PanelContainer.new()
	_stockpile_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_stockpile_panel.offset_left = 8
	_stockpile_panel.offset_top = -260
	_stockpile_panel.offset_bottom = -146
	_stockpile_panel.offset_right = 470
	_stockpile_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_stockpile_panel.add_child(vbox)
	_stockpile_title = Label.new()
	_stockpile_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_stockpile_title)
	_stockpile_detail = Label.new()
	_stockpile_detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	vbox.add_child(_stockpile_detail)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	vbox.add_child(grid)
	for material in BlockRegistry.Resource_.values():
		if material == BlockRegistry.Resource_.NONE:
			continue
		var box := CheckBox.new()
		box.text = BlockRegistry.RESOURCE_NAMES[material]
		box.focus_mode = Control.FOCUS_NONE
		box.set_meta(&"material", material)
		box.toggled.connect(
			func(on: bool) -> void:
				if overseer._selected != Vector3i.MAX:
					colony.set_stockpile_admission(
						overseer._selected, material, on
					)
		)
		grid.add_child(box)
		_stockpile_checks.append(box)
	parent.add_child(_stockpile_panel)


## The farm field's panel: a toggle button per plantable species assigns
## the crop — shrubs and trees alike — and a tree field gets the
## auto-chop switch. Same slot as the stockpile panel; the selection is
## one or the other.
func _build_farm(parent: Control) -> void:
	_farm_panel = PanelContainer.new()
	_farm_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_farm_panel.offset_left = 8
	_farm_panel.offset_top = -260
	_farm_panel.offset_bottom = -146
	_farm_panel.offset_right = 470
	_farm_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_farm_panel.add_child(vbox)
	_farm_title = Label.new()
	_farm_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_farm_title)
	_farm_detail = Label.new()
	_farm_detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	vbox.add_child(_farm_detail)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	vbox.add_child(grid)
	for entry in colony.farmable_species():
		var button := _hud_button()
		button.text = entry[&"name"]
		button.toggle_mode = true
		button.tooltip_text = "Grow %s here" % String(entry[&"name"]).to_lower()
		var species: StringName = entry[&"id"]
		button.pressed.connect(
			func() -> void: colony.set_farm_crop(overseer._selected, species)
		)
		grid.add_child(button)
		_farm_crops[species] = button
	_farm_auto_chop = CheckBox.new()
	_farm_auto_chop.text = "Chop mature trees"
	_farm_auto_chop.tooltip_text = (
		"Fell each tree the moment it finishes growing — the field "
		+ "re-sows the freed cell on its own"
	)
	_farm_auto_chop.focus_mode = Control.FOCUS_NONE
	_farm_auto_chop.toggled.connect(
		func(on: bool) -> void:
			if overseer._selected != Vector3i.MAX:
				colony.set_farm_auto_chop(overseer._selected, on)
	)
	vbox.add_child(_farm_auto_chop)
	parent.add_child(_farm_panel)


func _on_selection_changed(_voxel: Vector3i) -> void:
	_update_selection()


## The selection panels follow the overseer's selection: hidden when
## nothing is selected or the thing under it is gone (deconstructed,
## undesignated). A building fills the worksite panel; a stockpile tile
## fills its admission checkboxes from the live filter.
func _update_selection() -> void:
	_update_worksite()
	_update_stockpile()
	_update_farm()


func _update_worksite() -> void:
	var voxel := overseer._selected
	var building := colony.building_at(voxel) if voxel != Vector3i.MAX else null
	if building == null:
		_worksite_panel.visible = false
		if (
			voxel != Vector3i.MAX
			and not colony.is_stockpile(voxel)
			and colony.farm_at(voxel) == null
		):
			# Selected thing was removed underneath us.
			overseer._selected = Vector3i.MAX
		return
	_worksite_panel.visible = true
	_worksite_title.text = building.label()
	_worksite_detail.text = building.describe_components()
	var worksite := building.kind == Building.Kind.WORKSITE
	var order := colony.craft_job_at(voxel)
	for recipe in _worksite_recipes.values():
		recipe.visible = worksite
		recipe.disabled = (
			order != null or colony.deconstruct_job_at(voxel) != null
		)
	_worksite_cancel.visible = worksite
	_worksite_cancel.disabled = order == null
	_worksite_deconstruct.disabled = (
		not building.deconstructable
		or colony.deconstruct_job_at(voxel) != null
	)


func _update_stockpile() -> void:
	var voxel := overseer._selected
	var live := voxel != Vector3i.MAX and colony.is_stockpile(voxel)
	_stockpile_panel.visible = live
	if not live:
		return
	_stockpile_title.text = "Stockpile"
	_stockpile_detail.text = "%.2f / 1.00 m³ piled" % (
		colony.voxel_fill(voxel) / float(DropItem.CM3_PER_M3)
	)
	for box in _stockpile_checks:
		box.set_pressed_no_signal(
			colony.stockpile_admits(voxel, box.get_meta(&"material"))
		)


func _update_farm() -> void:
	var voxel := overseer._selected
	var field := colony.farm_at(voxel) if voxel != Vector3i.MAX else null
	_farm_panel.visible = field != null
	if field == null:
		return
	_farm_title.text = "Farm field"
	var crop := "nothing assigned"
	var is_tree := false
	for entry in colony.farmable_species():
		if entry[&"id"] == field.species:
			crop = entry[&"name"]
			is_tree = entry[&"tree"]
	_farm_detail.text = "%d cells — %s" % [field.cells.size(), crop]
	for id: StringName in _farm_crops:
		_farm_crops[id].set_pressed_no_signal(field.species == id)
	_farm_auto_chop.visible = is_tree
	_farm_auto_chop.set_pressed_no_signal(field.auto_chop)


## The bottom bar: Architect and Menu are live; the other tabs are stubs
## for systems that don't exist yet. Right side holds the display toggles
## and the time controls.
func _build_menu_bar(parent: Control) -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	bar.add_child(row)
	parent.add_child(bar)

	_architect_button = _hud_button()
	_architect_button.text = "Architect"
	_architect_button.pressed.connect(_on_architect_pressed)
	row.add_child(_architect_button)
	for tab in MENU_TABS:
		var button := _hud_button()
		button.text = tab
		button.disabled = true
		row.add_child(button)
	_menu_button = _hud_button()
	_menu_button.text = "Menu"
	_menu_button.pressed.connect(_on_menu_pressed)
	row.add_child(_menu_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	for toggle in TOGGLES:
		var button := _hud_button()
		button.text = String(toggle["label"])
		if not toggle["live"]:
			button.disabled = true
			row.add_child(button)
			continue
		button.toggle_mode = true
		button.button_pressed = true
		button.toggled.connect(_on_display_toggle.bind(button.text))
		row.add_child(button)

	var speed_group := ButtonGroup.new()
	for speed in SPEEDS:
		var button := _hud_button()
		button.text = String(speed["label"])
		button.toggle_mode = true
		button.button_group = speed_group
		button.button_pressed = speed["scale"] == 1.0
		button.pressed.connect(_set_speed.bind(float(speed["scale"])))
		_speed_buttons.append(button)
		row.add_child(button)
	# Timberborn's "tick once": pause and advance a single step.
	var tick := _hud_button()
	tick.text = ">|"
	tick.tooltip_text = "Pause and advance one tick"
	tick.pressed.connect(overseer.tick_once)
	row.add_child(tick)
	# RimWorld's fast-forward: while armed, the clock runs at the top
	# speed whenever every unit at the site is asleep.
	_sleep_boost_button = _hud_button()
	_sleep_boost_button.text = "Zz"
	_sleep_boost_button.toggle_mode = true
	_sleep_boost_button.tooltip_text = (
		"Fast-forward while every colonist is asleep"
	)
	_sleep_boost_button.toggled.connect(colony.set_sleep_boost)
	row.add_child(_sleep_boost_button)
	_date_label = Label.new()
	_date_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_date_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	row.add_child(_date_label)


## Popups: the action menu is the Architect menu — categories as
## submenus — and the Menu button gets Save/Load/Options stubs plus Quit.
func _build_menus() -> void:
	action_menu.clear()
	for category in ARCHITECT_MENU:
		var submenu := PopupMenu.new()
		submenu.name = String(category["label"])
		for item: Dictionary in category["items"]:
			if item.has("action"):
				var action_index := overseer.ACTIONS.find(item["action"])
				submenu.add_item(overseer.ACTION_NAMES[item["action"]], action_index)
			else:
				submenu.add_item("%s (not implemented)" % item["stub"], -1)
				submenu.set_item_disabled(submenu.item_count - 1, true)
		submenu.id_pressed.connect(_on_architect_item)
		action_menu.add_child(submenu)
		action_menu.add_submenu_item(String(category["label"]), submenu.name)

	_menu_popup = PopupMenu.new()
	_menu_popup.add_item("Save (not implemented)", 0)
	_menu_popup.set_item_disabled(0, true)
	_menu_popup.add_item("Load (not implemented)", 1)
	_menu_popup.set_item_disabled(1, true)
	_menu_popup.add_item("Options (not implemented)", 2)
	_menu_popup.set_item_disabled(2, true)
	_menu_popup.add_separator()
	_menu_popup.add_item("Quit", 3)
	_menu_popup.id_pressed.connect(
		func(id: int) -> void:
			if id == 3:
				get_tree().quit()
	)
	add_child(_menu_popup)


func _on_architect_pressed() -> void:
	action_menu.popup()


func _on_menu_pressed() -> void:
	_menu_popup.popup()


func _on_architect_item(id: int) -> void:
	if id >= 0:
		overseer.select_action(id)
	action_menu.hide()


func _on_display_toggle(pressed_on: bool, label: String) -> void:
	match label:
		"Zones":
			colony.set_markers_visible(pressed_on)
		"Plans":
			colony.set_plans_visible_manual(pressed_on)
		"Colonist bar":
			_colonist_bar.visible = pressed_on


func _set_speed(scale: float) -> void:
	# The colony is the single speed authority — the sleep boost reads
	# the player's pick from there.
	colony.set_speed(scale)


## Keeps the speed buttons reflecting the pause key and the 1/2/3 keys.
func _sync_speed_buttons() -> void:
	if _speed_buttons.size() < SPEEDS.size():
		return
	for i in SPEEDS.size():
		var scale: float = SPEEDS[i]["scale"]
		_speed_buttons[i].set_pressed_no_signal(
			get_tree().paused if scale <= 0.0
			else not get_tree().paused and Engine.time_scale == scale
		)
	# Engaged boost reads as a lit toggle on top of the highlighted 6x.
	_sleep_boost_button.modulate = (
		Color(1.0, 1.0, 0.55) if colony.sleep_boost_engaged()
		else Color.WHITE
	)


func _show_action_menu() -> void:
	action_menu.popup()


func _update_resources() -> void:
	var lines := PackedStringArray()
	for entry in colony.stockpile_contents():
		var material_name: String = BlockRegistry.resource_name_of(entry["material"])
		if entry["form"] == DropItem.Form.LOOSE:
			lines.append(
				"%s %.2f m³" % [material_name, float(entry["cm3"]) / DropItem.CM3_PER_M3]
			)
		else:
			lines.append(
				"%s %s ×%d"
				% [material_name, DropItem.form_name(entry["form"]), entry["count"]]
			)
	_resources_label.text = (
		"\n".join(lines) if lines.size() > 0 else "No stockpiles"
	)


func _update_inspect() -> void:
	var hit := overseer.targeted_voxel()
	var text := "Action: %s\n" % overseer.current_action_label()
	if hit == null:
		text += "Nothing under the cursor"
	else:
		var block_id := colony.world.get_block(hit.position)
		var pile := colony.item_pile_at(hit.previous_position)
		var building := (
			colony.building_at(hit.position)
			if colony.building_at(hit.position) != null
			else colony.building_at(hit.previous_position)
		)
		text += "%s %s" % [BlockRegistry.block_name(block_id), str(hit.position)]
		if pile != null:
			text += "  pile %.2f m³" % _pile_fill_display(pile)
		if colony.is_stockpile(hit.previous_position):
			text += "  stockpile"
		elif building != null:
			text += "  %s" % building.label()
	text += "\nUnits: %d   Jobs queued: %d" % [colony.units.size(), colony.open_job_count()]
	_inspect_label.text = text


## The calendar readout — the site's local date and clock, and a night
## marker so the dimmed screen reads as evening rather than a bug.
func _update_date() -> void:
	if day_cycle == null:
		return
	_date_label.text = day_cycle.clock_text() + (
		"" if day_cycle.is_daylight() else "  ·night"
	)


func _pile_fill_display(pile: ItemPile) -> float:
	return float(pile.total_volume()) / DropItem.CM3_PER_M3


func _update_perf(delta: float) -> void:
	var ms := delta * 1000.0
	_perf_worst_ms = maxf(_perf_worst_ms, ms)
	_perf_window_left -= delta
	if _perf_window_left <= 0.0:
		_perf_shown_worst_ms = _perf_worst_ms
		_perf_worst_ms = 0.0
		_perf_window_left = PERF_WINDOW
	_perf_label.text = "Frame: %.1f ms  worst(2s): %.1f ms  physics: %.1f ms  nodes: %d" % [
		ms,
		_perf_shown_worst_ms,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
	]
