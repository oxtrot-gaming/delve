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
			{"action": &"mine"}, {"action": &"chop_tree"}, {"action": &"clear_pile"},
			{"action": &"cancel"}, {"action": &"deconstruct"},
			{"stub": "Haul"},
		],
	},
	{
		"label": "Zones",
		"items": [
			{"action": &"designate_stockpile"},
			{"action": &"undesignate_stockpile"},
			{"stub": "Growing zone"}, {"stub": "Dumping zone"}, {"stub": "Allowed area"},
		],
	},
	{
		"label": "Structure",
		"items": [{"action": &"build_wall"}, {"stub": "Door"}, {"stub": "Floor"}],
	},
	{
		"label": "Production",
		# A worksite's tasks live on its inspect panel, not here — the
		# menu only places the site itself.
		"items": [
			{"action": &"designate_craft_spot"}, {"stub": "Furnace"},
		],
	},
	{"label": "Furniture", "items": [{"stub": "Bed"}, {"stub": "Table"}]},
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
	{"label": "Beauty", "live": false},
	{"label": "Roofs", "live": false},
	{"label": "Home area", "live": false},
	{"label": "Colonist bar", "live": true},
]
## Speed controls: pause plus the multipliers the 1/2/3 keys select.
## "Day 1" beside them is a stub — there's no calendar until day/night
## exists.
const SPEEDS: Array[Dictionary] = [
	{"label": "II", "scale": 0.0},
	{"label": "1x", "scale": 1.0},
	{"label": "3x", "scale": 3.0},
	{"label": "6x", "scale": 6.0},
]

var colony: Colony
var overseer: Overseer
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
## The inspected building's panel — its name, what it's made of, and the
## task controls a worksite offers (craft orders and their cancellation,
## plus deconstruction).
var _worksite_panel: PanelContainer
var _worksite_title: Label
var _worksite_detail: Label
var _worksite_craft: Button
var _worksite_cancel: Button
var _worksite_deconstruct: Button


func _ready() -> void:
	# The HUD keeps working while the tree is paused so the pause button
	# can be pressed again and designations still land while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	colony = get_node(colony_path)
	overseer = get_node(overseer_path)
	overseer.action_menu_requested.connect(_show_action_menu)
	overseer.action_menu_dismissed.connect(action_menu.hide)
	action_menu.popup_hide.connect(overseer.menu_closed)
	colony.unit_spawned.connect(func(_unit: Unit) -> void: _rebuild_colonist_bar())
	overseer.selection_changed.connect(_on_selection_changed)
	_build_ui()


func _process(delta: float) -> void:
	_update_resources()
	_update_inspect()
	_update_worksite()
	_update_perf(delta)
	_sync_speed_buttons()


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
		var button := Button.new()
		button.text = unit.name
		button.tooltip_text = "Jump camera to %s" % unit.name
		button.pressed.connect(_on_colonist_pressed.bind(unit))
		_colonist_bar.add_child(button)


func _on_colonist_pressed(unit: Unit) -> void:
	if is_instance_valid(unit):
		overseer.jump_to(unit.global_position)


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
	_worksite_craft = Button.new()
	_worksite_craft.text = "Craft planks"
	_worksite_craft.tooltip_text = "Order a log cut into planks at this spot"
	_worksite_craft.pressed.connect(
		func() -> void: colony.designate_craft(overseer._selected)
	)
	row.add_child(_worksite_craft)
	_worksite_cancel = Button.new()
	_worksite_cancel.text = "Cancel order"
	_worksite_cancel.tooltip_text = "Drop the craft order queued here"
	_worksite_cancel.pressed.connect(
		func() -> void: colony.cancel_craft_order(overseer._selected)
	)
	row.add_child(_worksite_cancel)
	_worksite_deconstruct = Button.new()
	_worksite_deconstruct.text = "Deconstruct"
	_worksite_deconstruct.tooltip_text = "Have a unit take this apart"
	_worksite_deconstruct.pressed.connect(
		func() -> void: colony.designate_deconstruct(overseer._selected)
	)
	row.add_child(_worksite_deconstruct)
	parent.add_child(_worksite_panel)


func _on_selection_changed(_voxel: Vector3i) -> void:
	_update_worksite()


## The worksite panel follows the overseer's selection: hidden when
## nothing is selected or the building under it is gone (deconstructed),
## filled with the building's name, composition and live task controls.
func _update_worksite() -> void:
	var voxel := overseer._selected
	var building := colony.building_at(voxel) if voxel != Vector3i.MAX else null
	if building == null:
		_worksite_panel.visible = false
		if voxel != Vector3i.MAX:
			# Selected building was removed underneath us.
			overseer._selected = Vector3i.MAX
		return
	_worksite_panel.visible = true
	_worksite_title.text = building.label()
	_worksite_detail.text = building.describe_components()
	var worksite := building.kind == Building.Kind.WORKSITE
	var order := colony.craft_job_at(voxel)
	_worksite_craft.visible = worksite
	_worksite_cancel.visible = worksite
	_worksite_craft.disabled = (
		order != null or colony.deconstruct_job_at(voxel) != null
	)
	_worksite_cancel.disabled = order == null
	_worksite_deconstruct.disabled = (
		not building.deconstructable
		or colony.deconstruct_job_at(voxel) != null
	)


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

	_architect_button = Button.new()
	_architect_button.text = "Architect"
	_architect_button.pressed.connect(_on_architect_pressed)
	row.add_child(_architect_button)
	for tab in MENU_TABS:
		var button := Button.new()
		button.text = tab
		button.disabled = true
		row.add_child(button)
	_menu_button = Button.new()
	_menu_button.text = "Menu"
	_menu_button.pressed.connect(_on_menu_pressed)
	row.add_child(_menu_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	for toggle in TOGGLES:
		var button := Button.new()
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
		var button := Button.new()
		button.text = String(speed["label"])
		button.toggle_mode = true
		button.button_group = speed_group
		button.button_pressed = speed["scale"] == 1.0
		button.pressed.connect(_set_speed.bind(float(speed["scale"])))
		_speed_buttons.append(button)
		row.add_child(button)
	# Timberborn's "tick once": pause and advance a single step.
	var tick := Button.new()
	tick.text = ">|"
	tick.tooltip_text = "Pause and advance one tick"
	tick.pressed.connect(overseer.tick_once)
	row.add_child(tick)
	var date := Label.new()
	date.text = "Day 1"
	date.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	date.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	row.add_child(date)


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
		"Colonist bar":
			_colonist_bar.visible = pressed_on


func _set_speed(scale: float) -> void:
	get_tree().paused = scale <= 0.0
	if scale > 0.0:
		Engine.time_scale = scale


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
