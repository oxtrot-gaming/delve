class_name Hud
extends CanvasLayer

## RimWorld-style shell around the colony readouts: a resources list
## top-left, a settler bar across the top,
## the inspect card slot bottom-left, a chromeless column of toggles,
## time controls, calendar and weather above the bar's right end, and a
## menu bar stretched along the bottom — the Architect menu and tabs.
## Tabs and menu entries that need systems the colony doesn't have yet
## stay visible but disabled.

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
			{"action": &"cut_plant"},
			{"action": &"clear_pile"}, {"action": &"cancel"}, {"action": &"deconstruct"},
			{"action": &"uninstall"}, {"action": &"unpack"},
			{"action": &"hunt"}, {"action": &"tame"},
			{"action": &"forbid"}, {"action": &"unforbid"},
		],
	},
	{
		"label": "Zones",
		"items": [
			{"action": &"designate_stockpile"},
			{"action": &"designate_dump_stockpile"},
			{"action": &"designate_warehouse"},
			{"action": &"undesignate_stockpile"},
			{"action": &"designate_farm"},
			{"action": &"undesignate_farm"},
			{"action": &"fertilize"},
			{"action": &"expand_area"},
			{"action": &"erase_area"},
			{"action": &"expand_home"},
			{"action": &"erase_home"},
		],
	},
	{
		"label": "Structure",
		"items": [
			{"action": &"build_dirt_wall"},
			{"action": &"build_stone_wall", "variants": &"rock"},
			{"action": &"build_log_wall"},
			{"action": &"build_plank_wall"},
			{"action": &"build_stone_door", "variants": &"rock"},
			{"action": &"build_log_door"},
			{"action": &"build_plank_door"},
			{"action": &"build_ladder"},
		],
	},
	{
		"label": "Floors",
		"items": [
			{"action": &"pave_packed_dirt"},
			{"action": &"pave_flagstone"},
			{"action": &"pave_plank_floor"},
			{"action": &"strip_floor"},
		],
	},
	{
		"label": "Production",
		# A worksite's tasks live on its inspect panel, not here — the
		# menu only places the site itself.
		"items": [
			{"action": &"designate_craft_spot"},
			{"action": &"designate_campfire"},
			{"action": &"designate_butcher_spot"},
			{"action": &"designate_grave"},
			{"action": &"build_charcoal_mound"},
			{"action": &"build_pit_smelter"},
			{"action": &"build_bloomery"},
			{"action": &"build_research_bench"},
			{"action": &"build_metalwork_bench"},
			{"action": &"build_fabricator"},
			{"action": &"build_tailor_bench"},
			{"action": &"build_toolmaker"},
			{"action": &"build_stonecutter"},
			{"action": &"build_kiln"},
			{"action": &"build_refractory"},
			{"action": &"build_stone_crusher"},
			{"action": &"build_stove"},
		],
	},
	{
		"label": "Furniture",
		"items": [
			{"action": &"furnish_sleeping_spot"},
			{"action": &"furnish_double_sleeping_spot"},
			{"action": &"furnish_bedroll"},
			{"action": &"furnish_double_bedroll"},
			{"action": &"furnish_bed"},
			{"action": &"furnish_double_bed"},
			{"action": &"furnish_royal_bed"},
			{"action": &"furnish_hospital_bed"},
			{"action": &"furnish_animal_bed"},
			{"action": &"furnish_stool"},
			{"action": &"furnish_dining_chair"},
			{"action": &"furnish_armchair"},
			{"action": &"furnish_couch"},
			{"action": &"furnish_table_1x2"},
			{"action": &"furnish_table_2x2"},
			{"action": &"furnish_table_2x4"},
			{"action": &"furnish_table_3x3"},
			{"action": &"furnish_shelf"},
			{"action": &"furnish_small_shelf"},
			{"action": &"furnish_end_table"},
			{"action": &"furnish_dresser"},
			{"action": &"furnish_small_bookcase"},
			{"action": &"furnish_bookcase"},
			{"action": &"furnish_plant_pot"},
			{"action": &"furnish_small_sculpture"},
			{"action": &"furnish_sculpture"},
			{"action": &"furnish_grand_sculpture"},
			{"action": &"furnish_torch_lamp"},
			{"action": &"furnish_standing_lamp"},
			{"action": &"furnish_floodlight"},
			{"action": &"furnish_sun_lamp"},
			{"action": &"build_shelf"},
			{"action": &"build_compost_bin"},
		],
	},
	{
		"label": "Recreation",
		"items": [
			{"action": &"build_horseshoe_pin"},
			{"action": &"build_hoopstone_ring"},
			{"action": &"build_ur_board"},
			{"action": &"build_tafl_table"},
			{"action": &"build_billiards_table"},
			{"action": &"build_poker_table"},
			{"action": &"build_telescope"},
			{"action": &"build_harp"},
			{"action": &"build_harpsichord"},
			{"action": &"build_piano"},
			{"action": &"build_television"},
		],
	},
	{
		"label": "Power",
		"items": [
			{"action": &"build_generator"},
			{"action": &"install_conduit"},
			{"action": &"build_pylon"},
			{"action": &"build_heater"},
			{"action": &"build_cooler"},
			{"action": &"build_water_wheel"},
			{"action": &"build_pump"},
		],
	},
	{
		"label": "Security",
		"items": [
			{"action": &"build_dirt_mound"},
			{"action": &"build_wood_barricade"},
			{"action": &"build_stone_barricade"},
			{"action": &"build_wood_fence"},
			{"action": &"build_floodgate"},
			{"action": &"designate_spike_trap"},
			{"stub": "Turret"},
		],
	},
	{"label": "Dev", "items": [{"action": &"spawn_unit"}]},
]
## Bottom-bar tabs between Architect and Menu — stubs until work
## priorities, assignments, taming, research and the rest exist.
const MENU_TABS: Array[String] = [
	"Work", "Assign", "Animals", "Research", "Factions", "World", "History",
]
## The settler card's tabs, in row order — the page vboxes index into
## this same order.
const UNIT_TAB_NAMES: Array[String] = [
	"Bio", "Skills", "Needs", "Health", "Gear",
]
const UNIT_TAB_BIO := 0
const UNIT_TAB_SKILLS := 1
const UNIT_TAB_NEEDS := 2
const UNIT_TAB_HEALTH := 3
const UNIT_TAB_GEAR := 4
## Bottom-right display toggles. "live" ones switch real behavior; the
## rest are stubs for display modes that don't exist yet.
const TOGGLES: Array[Dictionary] = [
	{"label": "Zones", "live": true},
	# Timberborn's plans view: pending builds and deconstruct marks. A
	# wall or deconstruct tool also shows them while it's selected.
	{"label": "Plans", "live": true},
	# The per-cell sight-line read the units make — a heatmap over the
	# standing surface near the focus, budgeted a few cells a frame.
	{"label": "Beauty", "live": true, "default": false},
	# Cover classes: bounded rooms and unbounded overhead cover; sky
	# cells get no tile.
	{"label": "Roofs", "live": true, "default": false},
	# Flow arrows over the live waterline — DelveSim's per-step flux.
	{"label": "Flow", "live": true, "default": false},
	{"label": "Home area", "live": true},
	{"label": "Settler bar", "live": true},
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
var _settler_bar: HBoxContainer
var _inspect_panel: PanelContainer
var _inspect_label: Label
var _menu_bar: PanelContainer
var _perf_label: Label
var _architect_button: Button
var _menu_button: Button
var _menu_popup: PopupMenu
var _options_panel: PanelContainer
## The right-edge column — notification stack, weather, calendar,
## speed controls and display toggles, bottom-up.
var _right_col: VBoxContainer
var _alerts_col: VBoxContainer
var _weather_label: Label
## The inspected pile's card — fill, contents and condition — plus the
## right-of-card action strip every card shares.
var _pile_panel: PanelContainer
var _pile_title: Label
var _pile_detail: Label
var _inspected_pile: ItemPile = null
## The inspected blueprint's card — a pending construction's name,
## the materials it still wants, and its board status.
var _plan_panel: PanelContainer
var _plan_title: Label
var _plan_detail: Label
var _inspected_plan: ColonyJob = null
var _inspect_actions: VBoxContainer
var _inspect_actions_subject: Variant = null
## The mouseover tooltip — RimWorld's hover readout over world things.
var _tooltip_panel: PanelContainer
var _tooltip_label: Label
var _hover_key: Variant = null
var _hover_dwell := 0.0
## The Menu → Save/Load card: the slot list the title screen reads,
## plus the name field a manual save writes to.
var _saves_panel: PanelContainer
var _save_name: LineEdit
var _save_list: VBoxContainer
var _speed_buttons: Array[Button] = []
## The sleep-boost toggle — pressed while armed, tinted while engaged.
var _sleep_boost_button: Button
## The inspected building's panel — its name, what it's made of, and the
## task controls a worksite offers (craft orders and their cancellation,
## plus deconstruction).
var _worksite_panel: PanelContainer
var _worksite_title: Label
var _worksite_detail: Label
## The worksite's bill picker — one MenuButton whose popup rebuilds on
## open: craft bills grouped by category, plus the bench-specific
## groups (studies, garment work, tool repairs) when they apply.
var _bills_button: MenuButton
## The order rows under the recipe buttons — one per queued bill, each
## with its repeat condition, count and a remove button. Rows are
## rebuilt only when the queue's membership changes; their labels and
## spinners refresh every frame.
var _worksite_orders_box: VBoxContainer
var _order_rows: Array[Dictionary] = []
## Per-order details expander state, keyed on the order record —
## survives the row rebuilds that swap one order for another.
var _order_expanded: Dictionary = {}
var _worksite_cancel: Button
var _worksite_deconstruct: Button
## The campfire-only controls on the worksite panel.
var _campfire_box: HBoxContainer
var _campfire_auto: CheckBox
var _campfire_threshold: SpinBox
var _campfire_stoke: Button
## The bed's medical-facility toggle on the worksite panel.
var _bed_medical: CheckBox
## The floodgate's open-fraction row on the worksite panel.
var _gate_box: HBoxContainer
var _gate_slider: HSlider
var _gate_value: Label
## The inspected stockpile tile's panel — its fill and a per-material
## checkbox for what the tile admits. The entries are built once from the
## material table; a category layer is for when the list outgrows it.
var _stockpile_panel: PanelContainer
var _stockpile_title: Label
var _stockpile_detail: Label
var _stockpile_checks: Array[CheckBox] = []
var _stockpile_priority: OptionButton
## The inspected farm field's panel — the crop assignment (one toggle
## button per plantable species) and, for tree fields, the auto-chop
## switch.
var _farm_panel: PanelContainer
var _farm_title: Label
var _farm_detail: Label
var _farm_crops: Dictionary = {}
var _farm_auto_chop: CheckBox
var _farm_auto_fertilize: CheckBox
var _farm_fert_slider: HSlider
var _farm_fert_label: Label
var _date_label: Label
## The clicked settler's panel — name and activity, skill levels with
## progress bars, and the specialize/generalize stance toggle.
var _unit_panel: PanelContainer
var _unit_title: Label
var _unit_health: Label
var _unit_needs: Label
var _unit_prefs: Label
var _unit_skill_rows: Dictionary = {}
var _unit_specialize: CheckBox
## The settler card's tab row and the page vboxes it swaps between —
## index order matches `UNIT_TAB_NAMES` below.
var _unit_tab_buttons: Array[Button] = []
var _unit_tab_pages: Array[VBoxContainer] = []
var _unit_scroll: ScrollContainer
var _unit_equipment: Label
var _unit_holster_box: VBoxContainer
var _unit_holster_rows: Array[OptionButton] = []
## The inspected unit's allowed-area picker — "Unrestricted" or one of
## the painted areas; rebuilt when the area list changes.
var _unit_area: OptionButton
var _unit_area_count := -1
## The inspected unit's role picker — the designated work bias whose
## favoured job types argue louder in claim scoring.
var _unit_role: OptionButton
## The inspected unit's medicine policy picker — the per-patient say
## in how much of the herb stock a doctor may spend on them.
var _unit_meds: OptionButton
## The surgery-bill row — treat-infection and amputate buttons, with a
## line naming the operations already queued on the patient.
var _unit_surgery_box: HBoxContainer
var _unit_surgery_label: Label
var _unit_surgery_treat: Button
var _unit_surgery_amputate: Button
var _inspected_unit: Unit = null
## The clicked animal's panel — species, activity, and its own allowed-
## area picker.
var _animal_panel: PanelContainer
var _animal_title: Label
var _animal_area: OptionButton
var _animal_area_count := -1
## The Animals tab's roster panel — one row per creature on the map:
## wild marks carry their tame progress, the herd reads domestic.
var _animals_panel: PanelContainer
## The Research tab's roster × skills grid — one row per settler,
## a column per skill, passions marked on their levels.
var _research_panel: PanelContainer
var _research_grid: GridContainer
var _research_elapsed := 0.0
## The World tab — the meso heightmap, every known site across the
## session's region cache, the in-flight party ledger, and the marked
## cell point-travel buttons (PLAN item 65).
var _world_panel: PanelContainer
var _world_map: TextureRect
var _world_sites_box: VBoxContainer
var _world_map_drawn := false
## Site count the map was drawn against — arrivals and surveys force
## a redraw so new boxes show.
var _world_map_sites := -1
## The meso cell the player last clicked — the travel buttons' target.
var _world_mark := Vector2i(-1, -1)
var _send_mark: Button
var _found_mark: Button
var _animals_box: VBoxContainer
var _animals_count := -1
var _inspected_animal: Animal = null
## The allowed-area manager — opened by the Assign tab: one row per
## painted area with paint/remove buttons.
var _areas_panel: PanelContainer
var _areas_box: VBoxContainer
var _areas_count := -1
## The areas panel's home-area row — its cell count refreshes with the
## rest of the panel.
var _home_label: Label
var _home_auto: CheckButton
var _assign_button: Button
## The job board — opened by the Work tab: one row per live job with its
## board status, and a per-unit breakdown of who can claim the picked
## job and who can't (with the reason).
var _jobs_panel: PanelContainer
var _jobs_box: VBoxContainer
var _jobs_detail: Label
var _jobs_selected: ColonyJob = null
var _jobs_signature := 0
## The picked job's fetch-override toggle — "fetch anywhere" lets a
## job skip the in-home preference for a deliberate far haul.
var _jobs_fetch_anywhere: CheckBox
## The crew roster — one row per settler carrying role and live
## activity; the surveil half of the Work tab.
var _crew_box: VBoxContainer
var _crew_signature := 0
## The stockpile filter clipboard + preset picker.
var _filter_clipboard: Dictionary = {}
var _preset_name: LineEdit
var _preset_picker: OptionButton
var _preset_count := -1


func _ready() -> void:
	# The HUD keeps working while the tree is paused so the pause button
	# can be pressed again and designations still land while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	colony = get_node(colony_path)
	overseer = get_node(overseer_path)
	day_cycle = get_node(day_cycle_path)
	GameOptions.ensure_loaded()
	overseer.action_menu_requested.connect(_show_action_menu)
	overseer.action_menu_dismissed.connect(action_menu.hide)
	action_menu.popup_hide.connect(overseer.menu_closed)
	colony.unit_spawned.connect(func(_unit: Unit) -> void: _rebuild_settler_bar())
	colony.unit_died.connect(func(_unit: Unit) -> void: _rebuild_settler_bar())
	colony.unit_departed.connect(func(_unit: Unit) -> void: _rebuild_settler_bar())
	overseer.selection_changed.connect(_on_selection_changed)
	overseer.unit_picked.connect(_on_unit_picked)
	overseer.animal_picked.connect(_on_animal_picked)
	overseer.pile_picked.connect(_on_pile_picked)
	overseer.plan_picked.connect(_on_plan_picked)
	_build_ui()


func _process(delta: float) -> void:
	var _hud_pt := Time.get_ticks_usec()
	_update_resources()
	_update_inspect()
	_update_selection()
	_update_settler_bar()
	_update_settler_panel()
	_update_animal_panel()
	_update_pile()
	_update_plan()
	_update_inspect_actions()
	_update_animals_panel()
	_update_areas_panel()
	_update_jobs_panel()
	_update_date()
	_update_perf(delta)
	_update_tooltip(delta)
	_sync_inspect_visibility()
	_sync_speed_buttons()
	_update_research_panel()
	colony.push_overlay_focus(overseer.global_position)
	Perf.sample(&"hud", Time.get_ticks_usec() - _hud_pt)


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
	_build_settler_bar(root)
	_build_inspect(root)
	_build_worksite(root)
	_build_stockpile(root)
	_build_farm(root)
	_build_settler_panel(root)
	_build_animal_panel(root)
	_build_animals_panel(root)
	_build_research_panel(root)
	_build_world_panel(root)
	_build_areas_panel(root)
	_build_jobs_panel(root)
	_build_options_panel(root)
	_build_saves_panel(root)
	_build_pile_panel(root)
	_build_plan_panel(root)
	_build_inspect_actions(root)
	_build_tooltip(root)
	_build_menu_bar(root)
	# Everything anchored to a screen bottom must clear the bar: the
	# left stack (inspect and the card-slot panels it trades with)
	# rises together, and the right column sits on the same ledge.
	var clear := int(ceil(_menu_bar.get_combined_minimum_size().y)) + 6
	_build_right_column(root, clear)
	var left_lift := mini(0, -clear - _inspect_panel.offset_bottom)
	for panel: Control in [
		_inspect_panel, _worksite_panel, _stockpile_panel, _farm_panel,
		_unit_panel, _animal_panel, _pile_panel, _plan_panel, _inspect_actions,
		_areas_panel, _jobs_panel, _animals_panel,
		_research_panel, _world_panel
	]:
		panel.offset_top += left_lift
		panel.offset_bottom += left_lift
	_build_menus()
	# The hover card draws over everything else built here.
	_tooltip_panel.move_to_front()


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


## Top-center settler bar — one button per unit; clicking jumps the
## camera to it. RimWorld's bar also shows portraits; names for now.
func _build_settler_bar(parent: Control) -> void:
	_settler_bar = HBoxContainer.new()
	_settler_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_settler_bar.offset_top = 6
	_settler_bar.add_theme_constant_override("separation", 2)
	parent.add_child(_settler_bar)
	_rebuild_settler_bar()


func _rebuild_settler_bar() -> void:
	for child in _settler_bar.get_children():
		child.queue_free()
	for unit in colony.units:
		var button := _hud_button()
		button.text = unit.name
		button.set_meta(&"unit", unit)
		button.pressed.connect(_on_settler_pressed.bind(unit))
		_settler_bar.add_child(button)


## Per-frame: each settler button's tooltip carries its unit's live
## activity and energy.
func _update_settler_bar() -> void:
	for button: Button in _settler_bar.get_children():
		# The meta holds a live Unit reference — a dead unit is freed
		# while its button still exists, and casting the freed object
		# errors, so validate before the cast.
		var meta: Variant = button.get_meta(&"unit")
		if meta == null or not is_instance_valid(meta):
			continue
		var unit := meta as Unit
		if unit == null:
			continue
		button.text = (
			("[D] " if unit.drafted else "")
			+ ("+ " if overseer.squad().has(unit) else "")
			+ unit.name
		)
		button.tooltip_text = (
			"%s — %s, %d%% rested, %d%% recreation, %d%% mood" % [
				unit.name, unit.current_activity(),
				int(unit.energy * 100.0),
				int(unit.recreation * 100.0),
				int(unit.mood * 100.0),
			]
		)


func _on_settler_pressed(unit: Unit) -> void:
	if not is_instance_valid(unit):
		return
	if _inspected_unit == unit:
		_inspected_unit = null
		overseer._squad.clear()
	else:
		_inspected_unit = unit
		# A bar pick is a selection too — keep the overseer's squad in
		# step so the draft toggle's fan-out doesn't hit stale members.
		overseer._squad = [unit]
	overseer._inspected_unit = _inspected_unit
	overseer.jump_to(unit.global_position)


## Bottom-right settler panel — the picked unit's card, split into
## tabs the way RimWorld's inspect pane is: the skills list alone is
## eighteen rows, so one flat panel outgrew the screen. The tab row
## sits on top, the name line and the role/area pickers stay up for
## every tab, and the tab bodies share one scroll.
func _build_settler_panel(parent: Control) -> void:
	_unit_panel = PanelContainer.new()
	_unit_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_unit_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_unit_panel.offset_left = 8
	_unit_panel.offset_top = -380
	_unit_panel.offset_bottom = -42
	_unit_panel.offset_right = 470
	_unit_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_unit_panel.add_child(vbox)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 2)
	var tab_group := ButtonGroup.new()
	for i in UNIT_TAB_NAMES.size():
		var tab := _hud_button()
		tab.text = UNIT_TAB_NAMES[i]
		tab.toggle_mode = true
		tab.button_group = tab_group
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var index := i
		tab.toggled.connect(
			func(on: bool) -> void:
				if on:
					_select_unit_tab(index)
		)
		tab_row.add_child(tab)
		_unit_tab_buttons.append(tab)
	vbox.add_child(tab_row)
	_unit_title = Label.new()
	_unit_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_unit_title)
	# The persistent strip — like RimWorld's Anything/Unrestricted
	# dropdowns, the work restrictions stay up whichever tab is open.
	var strip_row := HBoxContainer.new()
	strip_row.add_theme_constant_override("separation", 6)
	var role_label := Label.new()
	role_label.text = "Role"
	role_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	strip_row.add_child(role_label)
	_unit_role = OptionButton.new()
	_unit_role.focus_mode = Control.FOCUS_NONE
	_unit_role.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_role.tooltip_text = (
		"Designated work bias — the role's job types earn a flat claim "
		+ "bonus, so the unit takes its lane over closer generic work. "
		+ "A nudge, never a gate; pairs with Specialize."
	)
	for role_id: StringName in Colony.ROLES:
		_unit_role.add_item(String(Colony.ROLE_NAMES.get(role_id, role_id)))
		_unit_role.set_item_metadata(_unit_role.item_count - 1, role_id)
	_unit_role.item_selected.connect(
		func(index: int) -> void:
			if _inspected_unit != null and is_instance_valid(_inspected_unit):
				_inspected_unit.role = _unit_role.get_item_metadata(index)
	)
	strip_row.add_child(_unit_role)
	var area_label := Label.new()
	area_label.text = "Area"
	area_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	strip_row.add_child(area_label)
	_unit_area = OptionButton.new()
	_unit_area.focus_mode = Control.FOCUS_NONE
	_unit_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_area.tooltip_text = (
		"Restrict the unit's work to the cells of one allowed area"
	)
	_unit_area.item_selected.connect(
		func(index: int) -> void:
			if _inspected_unit != null and is_instance_valid(_inspected_unit):
				colony.set_unit_area(
					_inspected_unit,
					null if index == 0 else colony.areas[index - 1]
				)
	)
	strip_row.add_child(_unit_area)
	vbox.add_child(strip_row)
	# One scroll hosts every tab body — the scroll container doesn't
	# propagate its content's minimum size, so the card keeps its
	# bounded height and long pages (skills most of all) scroll.
	_unit_scroll = ScrollContainer.new()
	_unit_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_unit_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_unit_scroll)
	var pages := VBoxContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_scroll.add_child(pages)
	for i in UNIT_TAB_NAMES.size():
		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_theme_constant_override("separation", 4)
		page.visible = i == 0
		pages.add_child(page)
		_unit_tab_pages.append(page)
	var bio := _unit_tab_pages[UNIT_TAB_BIO]
	_unit_prefs = Label.new()
	_unit_prefs.add_theme_color_override("font_color", Color(0.9, 0.8, 0.6))
	_unit_prefs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bio.add_child(_unit_prefs)
	var skills := _unit_tab_pages[UNIT_TAB_SKILLS]
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
	skills.add_child(_unit_specialize)
	for skill in ColonyJob.Skill.values():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		label.custom_minimum_size.x = 120
		row.add_child(label)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(80, 10)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.min_value = 0
		bar.max_value = 1
		bar.step = 0.01
		bar.show_percentage = false
		row.add_child(bar)
		skills.add_child(row)
		_unit_skill_rows[skill] = {"label": label, "bar": bar}
	var needs := _unit_tab_pages[UNIT_TAB_NEEDS]
	_unit_needs = Label.new()
	_unit_needs.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	_unit_needs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	needs.add_child(_unit_needs)
	var health := _unit_tab_pages[UNIT_TAB_HEALTH]
	_unit_health = Label.new()
	_unit_health.add_theme_color_override("font_color", Color(1, 0.75, 0.7))
	_unit_health.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	health.add_child(_unit_health)
	var med_row := HBoxContainer.new()
	med_row.add_theme_constant_override("separation", 6)
	var med_label := Label.new()
	med_label.text = "Meds"
	med_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	med_row.add_child(med_label)
	_unit_meds = OptionButton.new()
	_unit_meds.focus_mode = Control.FOCUS_NONE
	_unit_meds.tooltip_text = (
		"How much medicine a doctor may spend on this patient — "
		+ "none: field dressing only; stocked: a bundle on medical-bed "
		+ "tends; always: a bundle on every tend"
	)
	_unit_meds.add_item("None")
	_unit_meds.add_item("Stocked")
	_unit_meds.add_item("Always")
	_unit_meds.item_selected.connect(
		func(index: int) -> void:
			if _inspected_unit != null and is_instance_valid(_inspected_unit):
				_inspected_unit.med_policy = index
	)
	med_row.add_child(_unit_meds)
	health.add_child(med_row)
	_unit_surgery_box = HBoxContainer.new()
	_unit_surgery_box.add_theme_constant_override("separation", 6)
	_unit_surgery_label = Label.new()
	_unit_surgery_label.add_theme_color_override(
		"font_color", Color(1, 0.85, 0.75)
	)
	_unit_surgery_box.add_child(_unit_surgery_label)
	_unit_surgery_treat = Button.new()
	_unit_surgery_treat.text = "Treat infection"
	_unit_surgery_treat.tooltip_text = (
		"Bill an operation — a surgeon with a herb bundle drives the "
		+ "patient's infections to zero on a medical bed"
	)
	_unit_surgery_treat.focus_mode = Control.FOCUS_NONE
	_unit_surgery_treat.pressed.connect(
		func() -> void:
			if _inspected_unit != null and is_instance_valid(_inspected_unit):
				colony.post_surgery_bill(_inspected_unit, &"treat_infection")
	)
	_unit_surgery_box.add_child(_unit_surgery_treat)
	_unit_surgery_amputate = Button.new()
	_unit_surgery_amputate.text = "Amputate"
	_unit_surgery_amputate.tooltip_text = (
		"Bill an operation — a surgeon with a herb bundle takes a "
		+ "ruined part off on a medical bed"
	)
	_unit_surgery_amputate.focus_mode = Control.FOCUS_NONE
	_unit_surgery_amputate.pressed.connect(
		func() -> void:
			if _inspected_unit != null and is_instance_valid(_inspected_unit):
				colony.post_surgery_bill(_inspected_unit, &"amputate")
	)
	_unit_surgery_box.add_child(_unit_surgery_amputate)
	health.add_child(_unit_surgery_box)
	var gear := _unit_tab_pages[UNIT_TAB_GEAR]
	_unit_equipment = Label.new()
	_unit_equipment.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	_unit_equipment.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gear.add_child(_unit_equipment)
	# Holster slots — one reservation picker per slot the worn kit
	# lends, appearing and vanishing with the garments.
	_unit_holster_box = VBoxContainer.new()
	_unit_holster_box.add_theme_constant_override("separation", 2)
	gear.add_child(_unit_holster_box)
	parent.add_child(_unit_panel)
	_select_unit_tab(0)


## Swaps the visible page of the settler card — Bio, Skills, Needs,
## Health, Gear — and rewinds the shared scroll to the top.
func _select_unit_tab(index: int) -> void:
	for i in _unit_tab_pages.size():
		_unit_tab_pages[i].visible = i == index
	for i in _unit_tab_buttons.size():
		_unit_tab_buttons[i].set_pressed_no_signal(i == index)
	_unit_scroll.scroll_vertical = 0


func _update_settler_panel() -> void:
	if _inspected_unit == null or not is_instance_valid(_inspected_unit):
		_unit_panel.visible = false
		return
	_unit_panel.visible = true
	_unit_title.text = "%s%s — %s" % [
		_inspected_unit.name,
		" (guest)" if _inspected_unit.stranger else "",
		_inspected_unit.current_activity(),
	]
	_unit_health.text = _unit_health_text(_inspected_unit)
	var needs_text := (
		"Needs food %d%% · rest %d%%\nfun %d%% · mood %d%% → %d%%" % [
			int(_inspected_unit.hunger * 100.0),
			int(_inspected_unit.energy * 100.0),
			int(_inspected_unit.recreation * 100.0),
			int(_inspected_unit.mood * 100.0),
			int(_inspected_unit.mood_target() * 100.0),
		]
	)
	if _inspected_unit._decompressing:
		# Mood therapy — recreation for morale's sake, not boredom's.
		needs_text += " — mood therapy"
	_unit_needs.text = needs_text
	_unit_prefs.text = _inspected_unit.preferences_text()
	for skill: int in _unit_skill_rows:
		var row: Dictionary = _unit_skill_rows[skill]
		row["label"].text = "%s  L%d" % [
			ColonyJob.SKILL_NAMES[skill], _inspected_unit.skill_level(skill)
		]
		row["bar"].value = _inspected_unit.skill_progress(skill)
	_unit_specialize.set_pressed_no_signal(_inspected_unit.specialize)
	for role_i in _unit_role.item_count:
		if _unit_role.get_item_metadata(role_i) == _inspected_unit.role:
			_unit_role.select(role_i)
			break
	if _unit_area_count != colony.areas.size():
		_unit_area_count = colony.areas.size()
		_unit_area.clear()
		_unit_area.add_item("Unrestricted")
		for area in colony.areas:
			_unit_area.add_item(area.label)
	_unit_area.select(
		colony.areas.find(_inspected_unit.allowed_area) + 1
	)
	_unit_meds.select(int(_inspected_unit.med_policy))
	# The surgery row only earns its space when an operation could be
	# billed — infection to treat or a ruined part to take off — or
	# one's already queued.
	var billable := (
		_inspected_unit.worst_infection() > 0.0
		or not _inspected_unit.ruined_parts.is_empty()
	)
	_unit_surgery_box.visible = billable or not _inspected_unit.surgery_bills.is_empty()
	_unit_surgery_treat.disabled = (
		_inspected_unit.worst_infection() <= 0.0
		or _inspected_unit.surgery_bills.has(&"treat_infection")
	)
	_unit_surgery_amputate.disabled = (
		_inspected_unit.ruined_parts.is_empty()
		or _inspected_unit.surgery_bills.has(&"amputate")
	)
	_unit_surgery_label.text = (
		"Bills: " + ", ".join(_inspected_unit.surgery_bills.map(
			func(op: StringName) -> String: return String(op).replace("_", " ")
		))
		if not _inspected_unit.surgery_bills.is_empty()
		else "Surgery:"
	)
	var gear: Array[String] = []
	for piece in _inspected_unit.worn:
		gear.append(piece.spec_name())
	for tool in _inspected_unit.hands:
		gear.append("%s in hand" % tool.spec_name())
	for tool in _inspected_unit.holstered:
		if tool != null:
			gear.append("%s holstered" % tool.spec_name())
	_unit_equipment.text = (
		"Kit: none" if gear.is_empty() else "Kit: " + ", ".join(gear)
	)
	# Holster slots — one reservation picker per slot the kit lends.
	var slots := _inspected_unit.holster_count()
	while _unit_holster_rows.size() > slots:
		_unit_holster_rows.pop_back().queue_free()
	while _unit_holster_rows.size() < slots:
		var slot := _unit_holster_rows.size()
		var picker := OptionButton.new()
		picker.focus_mode = Control.FOCUS_NONE
		picker.add_item("Holster: anything")
		for spec_id: StringName in DropItem.TOOL_SPECS:
			var spec: Dictionary = DropItem.tool_spec(spec_id)
			picker.add_item(String(spec.get(&"name", String(spec_id))))
		picker.tooltip_text = (
			"Reserve this holster slot — 'anything' takes whatever tool "
			+ "comes along; a named tool keeps the slot for it alone"
		)
		picker.item_selected.connect(
			func(index: int) -> void:
				if (
					_inspected_unit == null
					or not is_instance_valid(_inspected_unit)
				):
					return
				var prefs := _inspected_unit.holster_prefs
				while prefs.size() <= slot:
					prefs.append(&"")
				var ids := DropItem.TOOL_SPECS.keys()
				prefs[slot] = &"" if index == 0 else ids[index - 1]
		)
		_unit_holster_box.add_child(picker)
		_unit_holster_rows.append(picker)
	var spec_ids := DropItem.TOOL_SPECS.keys()
	for i in _unit_holster_rows.size():
		var pref: StringName = (
			_inspected_unit.holster_prefs[i]
			if i < _inspected_unit.holster_prefs.size()
			else &""
		)
		_unit_holster_rows[i].select(spec_ids.find(pref) + 1)


## The settler panel's health line: overall condition, blood loss, and
## each open wound's part and kind.
func _unit_health_text(unit: Unit) -> String:
	var text := "Health %d%%" % int(unit.health)
	if unit.blood_loss > 0.0:
		text += " · blood -%d%%" % int(unit.blood_loss * 100.0)
	if (
		unit.wounds.is_empty()
		and unit.ruined_parts.is_empty()
		and unit.lost_parts.is_empty()
	):
		return text
	var parts: Array[String] = []
	for wound: Dictionary in unit.wounds:
		var part: String = Unit.PART_NAMES.get(
			wound[&"part"], String(wound[&"part"])
		)
		var mark := ""
		var infection := float(wound.get(&"infection", 0.0))
		if infection >= Unit.INFECTED_LINE:
			mark = " (festering)"
		elif infection >= Unit.INFECT_SURGERY_LINE:
			mark = " (infected %d%%)" % int(infection * 100.0)
		elif float(wound[&"bleed"]) > 0.0:
			mark = " (bleeding)"
		elif int(wound[&"care"]) == 0:
			mark = " (untreated)"
		parts.append("%s %s%s" % [part, String(wound[&"kind"]), mark])
	for part: StringName in unit.ruined_parts:
		parts.append(
			"%s ruined" % Unit.PART_NAMES.get(part, String(part))
		)
	for part: StringName in unit.lost_parts:
		parts.append(
			"%s missing" % Unit.PART_NAMES.get(part, String(part))
		)
	return text + " — " + ", ".join(parts)


## The clicked animal's panel — species, state, and the allowed-area
## picker a penned creature reads. Same bottom-right slot as the
## settler panel; an inspect picks one or the other.
func _build_animal_panel(parent: Control) -> void:
	_animal_panel = PanelContainer.new()
	_animal_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_animal_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_animal_panel.offset_left = 8
	_animal_panel.offset_top = -160
	_animal_panel.offset_bottom = -42
	_animal_panel.offset_right = 470
	_animal_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_animal_panel.add_child(vbox)
	_animal_title = Label.new()
	_animal_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_animal_title)
	var area_row := HBoxContainer.new()
	area_row.add_theme_constant_override("separation", 6)
	var area_label := Label.new()
	area_label.text = "Area"
	area_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	area_row.add_child(area_label)
	_animal_area = OptionButton.new()
	_animal_area.focus_mode = Control.FOCUS_NONE
	_animal_area.tooltip_text = (
		"Pen the animal inside one allowed area — it wanders, grazes "
		+ "and hunts only within its bounds"
	)
	_animal_area.item_selected.connect(
		func(index: int) -> void:
			if _inspected_animal != null and is_instance_valid(_inspected_animal):
				colony.set_animal_area(
					_inspected_animal,
					null if index == 0 else colony.areas[index - 1]
				)
	)
	area_row.add_child(_animal_area)
	vbox.add_child(area_row)
	parent.add_child(_animal_panel)


func _on_animal_picked(animal: Animal) -> void:
	_inspected_animal = animal
	_rebuild_inspect_actions()


func _update_animal_panel() -> void:
	if _inspected_animal == null or not is_instance_valid(_inspected_animal):
		_animal_panel.visible = false
		return
	_animal_panel.visible = true
	_animal_title.text = "%s — %s" % [
		_inspected_animal.label(), _inspected_animal.current_activity()
	]
	if _animal_area_count != colony.areas.size():
		_animal_area_count = colony.areas.size()
		_animal_area.clear()
		_animal_area.add_item("Unrestricted")
		for area in colony.areas:
			_animal_area.add_item(area.label)
	_animal_area.select(
		colony.areas.find(_inspected_animal.allowed_area) + 1
	)


## The Animals tab's roster — opened by the Animals button: one row
## per creature carrying its species, wild-or-domestic state, what
## it's doing and how fed it is. Wild, bait-taking rows get a Tame
## button that posts the designation; a marked row reports its banked
## session progress. Assignments (pens) still live on the inspect
## panel — this is the herd's census.
func _build_animals_panel(parent: Control) -> void:
	_animals_panel = PanelContainer.new()
	_animals_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_animals_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_animals_panel.offset_left = 8
	_animals_panel.offset_top = -560
	_animals_panel.offset_bottom = -146
	_animals_panel.offset_right = 540
	_animals_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_animals_panel.add_child(vbox)
	var title := Label.new()
	title.text = "Animals"
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(title)
	var hint := Label.new()
	hint.text = (
		"Wild marks take Tame — sessions of bait and handling until "
		+ "the herd flag lands. Penned livestock graze, take feed and "
		+ "breed under the herd cap; assign pens on the inspect panel."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	vbox.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_animals_box = VBoxContainer.new()
	_animals_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_animals_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_animals_box)
	vbox.add_child(scroll)
	parent.add_child(_animals_panel)


func _update_animals_panel() -> void:
	if not _animals_panel.visible:
		return
	# Rebuild on roster change — a walk-in or a death changes the
	# census; labels refresh live inside the stable membership.
	if colony.animals.size() != _animals_count:
		_animals_count = colony.animals.size()
		for child in _animals_box.get_children():
			child.queue_free()
		if colony.animals.is_empty():
			var empty := Label.new()
			empty.text = "No animals on the map."
			empty.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			_animals_box.add_child(empty)
		for animal in colony.animals:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			var label := Label.new()
			label.custom_minimum_size.x = 330
			label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
			row.add_child(label)
			var tame := _hud_button()
			tame.text = "Tame"
			tame.tooltip_text = (
				"Post a tame order — a handler baits and works the "
				+ "animal in sessions until it turns domestic"
			)
			tame.pressed.connect(
				func() -> void:
					colony.designate_tame_animal(animal)
			)
			row.add_child(tame)
			row.set_meta(&"animal", animal)
			_animals_box.add_child(row)
	# Refresh rows in place — activity, hunger, the herd flag and the
	# Tame button's state all move under a stable roster.
	for child in _animals_box.get_children():
		if not child.has_meta(&"animal"):
			continue
		var animal: Animal = child.get_meta(&"animal")
		var label: Label = child.get_child(0)
		var tame: Button = child.get_child(1)
		if animal == null or not is_instance_valid(animal) or animal.dead:
			label.text = "(gone)"
			tame.visible = false
			continue
		var status := "domestic" if animal.domestic else "wild"
		var area_label := (
			animal.allowed_area.label
			if animal.allowed_area != null
			else "unrestricted"
		)
		label.text = "%s — %s, %s — %s — fed %d%%" % [
			animal.label(),
			status,
			area_label,
			animal.current_activity(),
			int(animal.hunger * 100.0),
		]
		var wild_mark := animal.tameable() and not animal.domestic
		tame.visible = wild_mark or animal.tame_progress > 0.0
		tame.disabled = (
			not wild_mark or colony.tame_marked(animal)
		)
		if not wild_mark and animal.tame_progress > 0.0:
			tame.text = "Tamed"
		elif colony.tame_marked(animal):
			tame.text = "Marked %d%%" % int(animal.tame_progress * 100.0)
		else:
			tame.text = "Tame"


## The Research tab (PLAN item 64): no tech tree — knowledge lives in
## people, so the panel is a roster × skills grid. A row per settler,
## a column per skill, the level in the cell with the passion marked:
## ▲ burning, △ minor, ✕ won't learn.
func _build_research_panel(parent: Control) -> void:
	_research_panel = PanelContainer.new()
	_research_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_research_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_research_panel.offset_left = 8
	_research_panel.offset_top = -560
	_research_panel.offset_bottom = -146
	_research_panel.offset_right = 720
	_research_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_research_panel.add_child(vbox)
	var title := Label.new()
	title.text = "Research — what the colony knows"
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(title)
	var hint := Label.new()
	hint.text = (
		"Knowledge lives in people: a recipe's gate is the worker's "
		+ "skill level. Passions — ▲ burning, △ minor, ✕ won't learn."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	vbox.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_research_grid = GridContainer.new()
	_research_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_research_grid)
	vbox.add_child(scroll)
	parent.add_child(_research_panel)


## Rebuild the grid on roster changes; refresh cell text on a slow tick
## while the panel is up — levels rise as units work.
func _update_research_panel() -> void:
	if _research_panel == null or not _research_panel.visible:
		return
	_research_elapsed += get_process_delta_time()
	var skills := ColonyJob.SKILL_NAMES.keys()
	_research_grid.columns = skills.size() + 1
	var want_rows := colony.units.size() + 1
	if _research_grid.get_child_count() != want_rows * (skills.size() + 1):
		_rebuild_research_grid(skills)
		return
	if _research_elapsed < 0.5:
		return
	_research_elapsed = 0.0
	# Cell order is row-major: header, then name + one label per skill.
	var idx := skills.size() + 1
	for unit in colony.units:
		(_research_grid.get_child(idx) as Label).text = unit.name
		idx += 1
		for skill in skills:
			var cell := _research_grid.get_child(idx) as Label
			cell.text = _research_cell_text(unit, skill)
			idx += 1


func _rebuild_research_grid(skills: Array) -> void:
	for child in _research_grid.get_children():
		child.queue_free()
	_research_grid.columns = skills.size() + 1
	var head := Label.new()
	head.text = "Settler"
	_research_grid.add_child(head)
	for skill in skills:
		var label := Label.new()
		var full := String(ColonyJob.SKILL_NAMES[skill])
		label.text = full.left(4)
		label.tooltip_text = full
		label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		_research_grid.add_child(label)
	for unit in colony.units:
		var name_label := Label.new()
		name_label.text = unit.name
		_research_grid.add_child(name_label)
		for skill in skills:
			var cell := Label.new()
			cell.text = _research_cell_text(unit, skill)
			_research_grid.add_child(cell)


func _research_cell_text(unit: Unit, skill: int) -> String:
	var level := unit.skill_level(skill)
	var passion := float(unit.passions.get(skill, 1.0))
	var mark := ""
	if passion <= 0.0:
		mark = " ✕"
	elif passion >= 2.0:
		mark = " ▲"
	elif passion > 1.0:
		mark = " △"
	return "%d%s" % [level, mark]


## The World tab (PLAN item 64): the site's mesoscale heightmap — the
## 16 km patch the colony's tile resolves to — with every region site
## boxed on it, and the site list beneath. Travel lands here in 65.
func _build_world_panel(parent: Control) -> void:
	_world_panel = PanelContainer.new()
	_world_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_world_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_world_panel.offset_left = 8
	_world_panel.offset_top = -560
	_world_panel.offset_bottom = -146
	_world_panel.offset_right = 420
	_world_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_world_panel.add_child(vbox)
	var title := Label.new()
	title.text = "World"
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(title)
	_world_map = TextureRect.new()
	_world_map.custom_minimum_size = Vector2(280, 280)
	_world_map.stretch_mode = TextureRect.STRETCH_SCALE
	_world_map.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# LMB on the meso marks a destination cell — the send/found buttons
	# below aim travel orders at it.
	_world_map.mouse_filter = Control.MOUSE_FILTER_STOP
	_world_map.gui_input.connect(_on_world_map_input)
	vbox.add_child(_world_map)
	var mark_row := HBoxContainer.new()
	mark_row.add_theme_constant_override("separation", 6)
	_send_mark = _hud_button()
	_send_mark.text = "Send unit to mark"
	_send_mark.disabled = true
	_send_mark.tooltip_text = (
		"March the inspected unit to the marked cell — bare ground "
		+ "becomes a camp site on arrival"
	)
	_send_mark.pressed.connect(_on_send_to_mark)
	mark_row.add_child(_send_mark)
	_found_mark = _hud_button()
	_found_mark.text = "Survey site at mark"
	_found_mark.disabled = true
	_found_mark.tooltip_text = (
		"Register a dormant site record at the marked cell — no "
		+ "settlers until someone travels there"
	)
	_found_mark.pressed.connect(_on_found_at_mark)
	mark_row.add_child(_found_mark)
	vbox.add_child(mark_row)
	_world_sites_box = VBoxContainer.new()
	vbox.add_child(_world_sites_box)
	parent.add_child(_world_panel)


## The map is static once the meso exists — draw it on first open and
## whenever the site count or the destination mark moves. The site
## list and the party ledger refresh on every open: both live across
## region boundaries, so the rows iterate the session's whole cache.
func _refresh_world_panel() -> void:
	var main := get_parent() as Main
	if main == null:
		return
	var site_count := 0
	for reg: Region in main._regions.values():
		site_count += reg.sites.size()
	if (
		main.meso != null
		and (not _world_map_drawn or _world_map_sites != site_count)
	):
		_world_map.texture = ImageTexture.create_from_image(
			_meso_image(main)
		)
		_world_map_drawn = true
		_world_map_sites = site_count
	for child in _world_sites_box.get_children():
		child.queue_free()
	if main.region == null:
		return
	var can_send := (
		_inspected_unit != null
		and is_instance_valid(_inspected_unit)
		and not _inspected_unit.dead
	)
	for reg: Region in main._regions.values():
		for s: Site in reg.sites:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			var label := Label.new()
			var here := (
				" — here" if s == main.site else ""
			)
			var dormant := (
				"" if s.colony != null
				else (" (%d in camp)" % s.state.get("units", []).size()
					if not s.state.is_empty() else " (surveyed)")
			)
			label.text = "Site %d%s: tile %d%s" % [
				s.id, here, s.world_tile, dormant,
			]
			label.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
			row.add_child(label)
			if s != main.site:
				var focus_btn := _hud_button()
				focus_btn.text = "Focus"
				focus_btn.tooltip_text = "Move the colony view to this site"
				focus_btn.pressed.connect(
					func() -> void: main.focus_site(s)
				)
				row.add_child(focus_btn)
				if can_send:
					var send_btn := _hud_button()
					send_btn.text = "Send"
					send_btn.tooltip_text = (
						"March %s here over the world map"
						% _inspected_unit.name
					)
					send_btn.pressed.connect(
						func() -> void:
							main.send_unit_to(
								_inspected_unit, main.site_target(s)
							)
					)
					row.add_child(send_btn)
			_world_sites_box.add_child(row)
	# In-flight parties under the site list — each one a marching
	# column with its remaining kilometres.
	for p: Dictionary in main.travel_parties:
		var pl := Label.new()
		pl.text = "→ %s: %.1f / %.1f km (%d travellers)" % [
			p.get("label", "?"),
			float(p.get("progress_m", 0.0)) / 1000.0,
			float(p.get("total_m", 0.0)) / 1000.0,
			(p.get("units", []) as Array).size(),
		]
		pl.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0, 0.85))
		_world_sites_box.add_child(pl)
	# The marked map cell drives the point-travel buttons.
	var can_mark := _world_mark != Vector2i(-1, -1) and main.site != null
	_send_mark.disabled = not (can_mark and can_send)
	_found_mark.disabled = not can_mark


## LMB on the map marks the meso cell under the cursor — the send and
## survey buttons target it. The panel texture only repaints on the
## next refresh.
func _on_world_map_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var rect := _world_map.get_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	_world_mark = Vector2i(
		clampi(
			int(mb.position.x / rect.size.x * MesoMap.SIDE),
			0, MesoMap.SIDE - 1
		),
		clampi(
			int(mb.position.y / rect.size.y * MesoMap.SIDE),
			0, MesoMap.SIDE - 1
		)
	)
	_world_map_drawn = false
	_refresh_world_panel()


## March the inspected unit to the marked cell — bare ground becomes
## an incident site when the party arrives.
func _on_send_to_mark() -> void:
	var main := get_parent() as Main
	if main == null or main.site == null or _inspected_unit == null:
		return
	if _world_mark == Vector2i(-1, -1):
		return
	main.send_unit_to(
		_inspected_unit,
		main.point_target(main.site.world_tile, _world_mark)
	)
	_refresh_world_panel()


## Register a dormant site record at the marked cell — a surveyed camp
## with no settlers until travellers land or the player focuses it.
func _on_found_at_mark() -> void:
	var main := get_parent() as Main
	if main == null or main.site == null:
		return
	if _world_mark == Vector2i(-1, -1):
		return
	main.found_site(main.site.world_tile, _world_mark)
	_refresh_world_panel()


## The meso heightfield as a map image: sea below the datum, land
## shading sand→green→rock→snow with height. Sites on this tile draw
## as red boxes at their meso cell; the destination mark is yellow.
func _meso_image(main: Main) -> Image:
	var meso: MesoMap = main.meso
	var side := MesoMap.SIDE
	var img := Image.create(side, side, false, Image.FORMAT_RGB8)
	for cz in side:
		for cx in side:
			var h: float = meso.heights[cz * side + cx]
			var color: Color
			if h <= 0.0:
				var d := clampf(-h / 800.0, 0.0, 1.0)
				color = Color(0.12, 0.22, 0.45).lerp(Color(0.02, 0.05, 0.18), d)
			else:
				var t := clampf(h / 2400.0, 0.0, 1.0)
				color = (
					Color(0.55, 0.48, 0.30)
					.lerp(Color(0.25, 0.48, 0.22), mini(t * 3.0, 1.0))
					.lerp(Color(0.45, 0.38, 0.32), clampf(t * 3.0 - 1.0, 0.0, 1.0))
					.lerp(Color(0.9, 0.9, 0.95), clampf(t * 3.0 - 2.0, 0.0, 1.0))
				)
			img.set_pixel(cx, cz, color)
	# Sites carry their own meso cell — the image IS the tile's meso,
	# so a same-tile site's box lands exactly on its surveyed spot.
	if main.site == null:
		return img
	var red := Color(0.9, 0.2, 0.15)
	var here := Color(0.2, 0.75, 0.9)
	for reg: Region in main._regions.values():
		for site: Site in reg.sites:
			if site.world_tile != main.site.world_tile:
				continue
			var half := Vector2i(
				maxi(1, site.bounds.size.x / MesoMap.CELL_M / 2),
				maxi(1, site.bounds.size.y / MesoMap.CELL_M / 2)
			)
			var c := (
				here if site == main.site else red
			)
			for x in range(site.meso_cell.x - half.x, site.meso_cell.x + half.x + 1):
				for z in [site.meso_cell.y - half.y, site.meso_cell.y + half.y]:
					if img.get_rect().has_point(Vector2i(x, z)):
						img.set_pixel(x, z, c)
			for z in range(site.meso_cell.y - half.y, site.meso_cell.y + half.y + 1):
				for x in [site.meso_cell.x - half.x, site.meso_cell.x + half.x]:
					if img.get_rect().has_point(Vector2i(x, z)):
						img.set_pixel(x, z, c)
	if _world_mark != Vector2i(-1, -1):
		var yellow := Color(0.95, 0.85, 0.2)
		for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var mp: Vector2i = _world_mark + d
			if img.get_rect().has_point(mp):
				img.set_pixel(mp.x, mp.y, yellow)
	return img


## The allowed-area manager — the Assign tab's panel: one row per area
## with its cell count, a Paint button that arms the expand tool on that
## area, and a Remove. The "New area" row mints one and opens it for
## painting immediately.
func _build_areas_panel(parent: Control) -> void:
	_areas_panel = PanelContainer.new()
	_areas_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_areas_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_areas_panel.offset_left = 8
	_areas_panel.offset_top = -260
	_areas_panel.offset_bottom = -146
	_areas_panel.offset_right = 470
	_areas_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_areas_panel.add_child(vbox)
	var title := Label.new()
	title.text = "Allowed areas"
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(title)
	var hint := Label.new()
	hint.text = (
		"Units and animals assigned to an area only work and wander "
		+ "inside it. Paint expands the open area."
	)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	vbox.add_child(hint)
	# The home area — the colony's lived-in footprint. Firefight,
	# repair and future clean bills only spawn inside it; fetch queries
	# prefer it. Painted like an area, or grown by construction while
	# the auto-expand box holds.
	var home_row := HBoxContainer.new()
	home_row.add_theme_constant_override("separation", 6)
	_home_label = Label.new()
	_home_label.custom_minimum_size.x = 160
	_home_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	home_row.add_child(_home_label)
	var home_paint := _hud_button()
	home_paint.text = "Paint"
	home_paint.tooltip_text = "Arm the expand tool on the home area"
	home_paint.pressed.connect(
		func() -> void:
			overseer.select_action(overseer.ACTIONS.find(&"expand_home"))
	)
	home_row.add_child(home_paint)
	_home_auto = CheckButton.new()
	_home_auto.focus_mode = Control.FOCUS_NONE
	_home_auto.text = "Auto-expand"
	_home_auto.tooltip_text = (
		"Buildings, conduits and new zone cells pull their "
		+ "surroundings into the home area"
	)
	_home_auto.button_pressed = colony.auto_home
	_home_auto.toggled.connect(
		func(pressed_on: bool) -> void: colony.auto_home = pressed_on
	)
	home_row.add_child(_home_auto)
	vbox.add_child(home_row)
	_areas_box = VBoxContainer.new()
	_areas_box.add_theme_constant_override("separation", 2)
	vbox.add_child(_areas_box)
	var new_button := _hud_button()
	new_button.text = "New area"
	new_button.tooltip_text = "Create an area and open it for painting"
	new_button.pressed.connect(
		func() -> void:
			colony.paint_area = colony.add_area()
			_areas_count = -1
			overseer.select_action(overseer.ACTIONS.find(&"expand_area"))
	)
	vbox.add_child(new_button)
	parent.add_child(_areas_panel)


func _update_areas_panel() -> void:
	if not _areas_panel.visible:
		return
	_home_label.text = "Home area — %d cells" % colony.home_cells.size()
	_home_auto.set_pressed_no_signal(colony.auto_home)
	if (
		_areas_count == colony.areas.size()
		and _areas_box.get_child_count() == colony.areas.size()
	):
		# Same membership — refresh the live counters in place.
		for i in colony.areas.size():
			var row: HBoxContainer = _areas_box.get_child(i)
			var area: AllowedArea = colony.areas[i]
			(row.get_child(0) as Label).text = "%s — %d cells" % [
				area.label, area.cells.size()
			]
			(row.get_child(1) as Button).text = (
				"Painting" if colony.paint_area == area else "Paint"
			)
		return
	_areas_count = colony.areas.size()
	for child in _areas_box.get_children():
		child.queue_free()
	for area in colony.areas:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		label.custom_minimum_size.x = 160
		label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		row.add_child(label)
		var paint := _hud_button()
		paint.tooltip_text = "Arm the expand tool on this area"
		paint.pressed.connect(
			func() -> void:
				colony.paint_area = area
				overseer.select_action(
					overseer.ACTIONS.find(&"expand_area")
				)
		)
		row.add_child(paint)
		var remove := _hud_button()
		remove.text = "Remove"
		remove.tooltip_text = "Delete the area — assigned units go unrestricted"
		remove.pressed.connect(
			func() -> void:
				colony.remove_area(area)
				_areas_count = -1
		)
		row.add_child(remove)
		_areas_box.add_child(row)


## The job board panel — opened by the Work tab. A scrollable row per
## live job carrying its board status (open / assigned / suspended /
## cooling off), and a per-unit breakdown under it for the picked job:
## who could claim it, who's gated off it and why. Built for "why is
## nobody doing this" debugging.
func _build_jobs_panel(parent: Control) -> void:
	_jobs_panel = PanelContainer.new()
	_jobs_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_jobs_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_jobs_panel.offset_left = 8
	_jobs_panel.offset_top = -560
	_jobs_panel.offset_bottom = -146
	_jobs_panel.offset_right = 540
	_jobs_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_jobs_panel.add_child(vbox)
	var title := Label.new()
	title.text = "Job board"
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(title)
	var hint := Label.new()
	hint.text = "Queued work. Click a row for who can take it and why not."
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	vbox.add_child(hint)
	var crew_label := Label.new()
	crew_label.text = "Crew"
	crew_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	vbox.add_child(crew_label)
	var crew_scroll := ScrollContainer.new()
	crew_scroll.custom_minimum_size = Vector2(0, 92)
	crew_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_crew_box = VBoxContainer.new()
	_crew_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_crew_box.add_theme_constant_override("separation", 2)
	crew_scroll.add_child(_crew_box)
	vbox.add_child(crew_scroll)
	var board_label := Label.new()
	board_label.text = "Job board"
	board_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	vbox.add_child(board_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_jobs_box = VBoxContainer.new()
	_jobs_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_jobs_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_jobs_box)
	vbox.add_child(scroll)
	_jobs_detail = Label.new()
	_jobs_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_jobs_detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	vbox.add_child(_jobs_detail)
	_jobs_fetch_anywhere = CheckBox.new()
	_jobs_fetch_anywhere.text = "Fetch anywhere"
	_jobs_fetch_anywhere.tooltip_text = (
		"Override the home-area fetch preference for this job — the "
		+ "worker takes the genuinely nearest goods, in home or out. "
		+ "For deliberate far hauls."
	)
	_jobs_fetch_anywhere.focus_mode = Control.FOCUS_NONE
	_jobs_fetch_anywhere.visible = false
	_jobs_fetch_anywhere.toggled.connect(
		func(on: bool) -> void:
			if _jobs_selected != null:
				_jobs_selected.home_override = on
	)
	vbox.add_child(_jobs_fetch_anywhere)
	parent.add_child(_jobs_panel)


## Refresh the board while it's open. Rows rebuild only when job
## membership or state changes; the status text and the picked job's
## per-unit breakdown update every pass — cooldowns count down live.
func _update_jobs_panel() -> void:
	if not _jobs_panel.visible:
		return
	var live: Array[ColonyJob] = []
	var signature := 0
	for job in colony.jobs:
		if not job.is_active():
			continue
		live.append(job)
		signature = signature * 31 + int(job.get_instance_id())
		signature = signature * 7 + int(job.state) * 2 + int(job.suspended)
	var rebuilt := false
	if signature != _jobs_signature:
		rebuilt = true
		_jobs_signature = signature
		live.sort_custom(
			func(a: ColonyJob, b: ColonyJob) -> bool:
				return a.posted_msec < b.posted_msec
		)
		for child in _jobs_box.get_children():
			child.queue_free()
		if live.is_empty():
			var empty := Label.new()
			empty.text = "No jobs on the board."
			empty.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
			_jobs_box.add_child(empty)
		for job in live:
			var row := _hud_button()
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row.toggle_mode = true
			row.pressed.connect(_on_job_row_pressed.bind(job))
			row.set_meta(&"job", job)
			_jobs_box.add_child(row)
	elif Engine.get_process_frames() % 15 != 0:
		# Statuses and the unit breakdown refresh at ~4 Hz — cooldown
		# countdowns are live, but the per-unit scan allocates.
		return
	# The crew roster — rows rebuild on membership change; the role and
	# activity text re-read on every pass the job rows take.
	var crew_signature := 0
	for unit in colony.units:
		crew_signature = crew_signature * 31 + int(unit.get_instance_id())
	if crew_signature != _crew_signature:
		_crew_signature = crew_signature
		for child in _crew_box.get_children():
			child.queue_free()
		for unit in colony.units:
			var crew_row := _hud_button()
			crew_row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			crew_row.set_meta(&"unit", unit)
			crew_row.pressed.connect(_on_crew_row_pressed.bind(unit))
			_crew_box.add_child(crew_row)
	for crew_row: Button in _crew_box.get_children():
		var unit: Unit = crew_row.get_meta(&"unit")
		if not is_instance_valid(unit):
			continue
		crew_row.text = "%s — %s — %s" % [
			unit.name,
			String(Colony.ROLE_NAMES.get(unit.role, unit.role)),
			unit.current_activity(),
		]
	for row: Button in _jobs_box.get_children():
		if not row.has_meta(&"job"):
			continue
		var job: ColonyJob = row.get_meta(&"job")
		row.text = "%s %s — %s" % [
			ColonyJob.Type.keys()[job.type], job.voxel_position,
			colony.job_board_status(job),
		]
		row.set_pressed_no_signal(job == _jobs_selected)
	_update_jobs_detail()


func _on_job_row_pressed(job: ColonyJob) -> void:
	_jobs_selected = job if _jobs_selected != job else null
	if _jobs_selected != null:
		# The camera answers half of "why" on its own — a job behind a
		# wall or across water explains itself.
		overseer.jump_to(Vector3(job.voxel_position))
	_update_jobs_detail()


## A crew row's click selects and inspects the unit — the same pick the
## map click makes, plus a jump so the roster answers "where" too.
func _on_crew_row_pressed(unit: Unit) -> void:
	overseer._inspected_unit = unit
	overseer._squad = [unit]
	overseer.unit_picked.emit(unit)
	overseer.jump_to(unit.global_position)


## The picked job's per-unit claim readout: the eligibility reason for
## each gated unit, the drop cooldown for one that failed it, or the
## claim score it would take at for a clear unit.
func _update_jobs_detail() -> void:
	var job := _jobs_selected
	if job == null or not job.is_active():
		_jobs_selected = null
		_jobs_detail.text = ""
		_jobs_fetch_anywhere.visible = false
		return
	_jobs_fetch_anywhere.visible = true
	_jobs_fetch_anywhere.set_pressed_no_signal(job.home_override)
	var now := colony.game_msec()
	var lines := PackedStringArray()
	lines.append(
		"%s %s — %s, posted %ds ago" % [
			ColonyJob.Type.keys()[job.type], job.voxel_position,
			colony.job_board_status(job),
			maxi(0, now - job.posted_msec) / 1000,
		]
	)
	for unit in colony.units:
		var who := "%s (%s)" % [
			unit.name,
			String(Colony.ROLE_NAMES.get(unit.role, unit.role)),
		]
		var reason := colony.job_block_reason(unit, job)
		if not reason.is_empty():
			lines.append("%s — %s" % [who, reason])
			continue
		var record: Dictionary = job.dropped_by.get(unit, {})
		if not record.is_empty():
			var drops := int(record.get("n", 1))
			var why := String(record.get("why", ""))
			var why_text := "" if why.is_empty() else ": %s" % why
			var left := colony.retry_delay_msec(record) - (
				now - int(record.get("at", 0))
			)
			if left > 0:
				lines.append(
					"%s — gave up %dx%s, retry in %ds"
					% [who, drops, why_text, (left + 999) / 1000]
				)
				continue
			lines.append(
				"%s — gave up %dx%s, retried only as last resort"
				% [who, drops, why_text]
			)
			continue
		var scores := colony._claim_type_scores(unit)
		var score := (
			Vector3(job.voxel_position).distance_to(unit.global_position)
			* Colony.CLAIM_DIST_WEIGHT
			- scores[job.type]
			- colony._languish_bonus(job, now)
		)
		var activity := unit.current_activity()
		if unit._decompressing:
			# Recreation for morale, not boredom — mood is below the
			# therapy line so the fun bar's level doesn't matter.
			activity += " — mood therapy"
		lines.append(
			"%s — eligible, score %.1f (%s)"
			% [who, score, activity]
		)
	_jobs_detail.text = "\n".join(lines)


## Bottom-left inspect pane — the cell info under the cursor plus the
## selected action, controls hints, and the perf readout.
func _build_inspect(parent: Control) -> void:
	_inspect_panel = PanelContainer.new()
	_inspect_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	# Content taller than the offsets grows the panel upward — the
	# rect never lets a label spill past its bottom edge.
	_inspect_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_inspect_panel.offset_left = 8
	_inspect_panel.offset_top = -140
	_inspect_panel.offset_bottom = -42
	_inspect_panel.offset_right = 470
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	_inspect_panel.add_child(vbox)
	_inspect_label = Label.new()
	vbox.add_child(_inspect_label)
	var hints := Label.new()
	hints.text = (
		"[LMB] tool · drag: box · wheel: zoom (drag: extrude) · [Q/E][Z/C] rotate"
		+ " · [MMB] pan · [RMB] deselect · [PgUp/PgDn] slice"
		+ " · [Space] pause · [1-3] speed · [.] tick"
	)
	hints.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	vbox.add_child(hints)
	_perf_label = Label.new()
	_perf_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_perf_label.visible = GameOptions.perf_overlay
	vbox.add_child(_perf_label)
	parent.add_child(_inspect_panel)


## The inspected pile's card — same slot the other cards take: fill,
## the contents digest, and the condition the weather matters for.
func _build_pile_panel(parent: Control) -> void:
	_pile_panel = PanelContainer.new()
	_pile_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_pile_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_pile_panel.offset_left = 8
	_pile_panel.offset_top = -160
	_pile_panel.offset_bottom = -42
	_pile_panel.offset_right = 470
	_pile_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_pile_panel.add_child(vbox)
	_pile_title = Label.new()
	_pile_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_pile_title)
	_pile_detail = Label.new()
	_pile_detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	_pile_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_pile_detail)
	parent.add_child(_pile_panel)


## The blueprint card — same slot: what the pending construction will
## be, which materials it's still waiting on, and its board status.
func _build_plan_panel(parent: Control) -> void:
	_plan_panel = PanelContainer.new()
	_plan_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_plan_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_plan_panel.offset_left = 8
	_plan_panel.offset_top = -160
	_plan_panel.offset_bottom = -42
	_plan_panel.offset_right = 470
	_plan_panel.visible = false
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_plan_panel.add_child(vbox)
	_plan_title = Label.new()
	_plan_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	vbox.add_child(_plan_title)
	_plan_detail = Label.new()
	_plan_detail.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	_plan_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_plan_detail)
	parent.add_child(_plan_panel)


## The action strip to the right of whichever card is up — RimWorld's
## card-side buttons: Draft on a settler, Tame on a wild animal,
## Forbid/Allow on a pile, Deconstruct on a construction. Rebuilt on
## selection change; each button's live state syncs per frame.
func _build_inspect_actions(parent: Control) -> void:
	_inspect_actions = VBoxContainer.new()
	_inspect_actions.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_inspect_actions.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_inspect_actions.offset_left = 478
	_inspect_actions.offset_top = -160
	_inspect_actions.offset_bottom = -50
	_inspect_actions.offset_right = 620
	_inspect_actions.add_theme_constant_override("separation", 4)
	_inspect_actions.visible = false
	parent.add_child(_inspect_actions)


func _action_button(label: String) -> Button:
	var button := _hud_button()
	button.text = label
	button.custom_minimum_size.x = 110
	return button


## Rebuilds the card-side buttons for the current inspection. Called
## whenever the inspected thing changes; live state (drafted, marked,
## forbidden) is re-synced in `_update_inspect_actions`.
func _rebuild_inspect_actions() -> void:
	for child in _inspect_actions.get_children():
		child.queue_free()
	if _inspected_unit != null and is_instance_valid(_inspected_unit):
		var draft := _action_button("Draft")
		draft.set_meta(&"action", &"draft")
		draft.toggle_mode = true
		draft.tooltip_text = "Hold position and fight (whole squad)"
		draft.toggled.connect(
			func(on: bool) -> void: overseer.set_squad_drafted(on)
		)
		_inspect_actions.add_child(draft)
		var relieved := _action_button("Relieved")
		relieved.set_meta(&"action", &"relieved")
		relieved.toggle_mode = true
		relieved.tooltip_text = (
			"Stand the unit down — takes no jobs but still rests, eats "
			+ "and recreates on its own"
		)
		relieved.toggled.connect(
			func(on: bool) -> void:
				if (
					_inspected_unit != null
					and is_instance_valid(_inspected_unit)
				):
					_inspected_unit.relieved = on
		)
		_inspect_actions.add_child(relieved)
		var teach := _action_button("Teach")
		teach.tooltip_text = (
			"Post a lesson on this unit — a settler who out-levels them "
			+ "in some skill will come and pass it on"
		)
		teach.pressed.connect(
			func() -> void:
				if (
					_inspected_unit != null
					and is_instance_valid(_inspected_unit)
				):
					colony.post_teach(_inspected_unit)
		)
		_inspect_actions.add_child(teach)
		var strip := _action_button("Strip gear")
		strip.tooltip_text = (
			"Order the unit out of everything it's wearing — the "
			+ "garments drop at its feet for hauling"
		)
		strip.pressed.connect(
			func() -> void:
				if (
					_inspected_unit != null
					and is_instance_valid(_inspected_unit)
				):
					_inspected_unit.strip_gear()
		)
		_inspect_actions.add_child(strip)
	elif _inspected_animal != null and is_instance_valid(_inspected_animal):
		if _inspected_animal.tameable() and not _inspected_animal.domestic:
			var tame := _action_button("Tame")
			tame.set_meta(&"action", &"tame")
			tame.tooltip_text = "Designate a handler to tame this animal"
			tame.pressed.connect(
				func() -> void: colony.designate_tame_animal(_inspected_animal)
			)
			_inspect_actions.add_child(tame)
	elif _inspected_pile != null and is_instance_valid(_inspected_pile):
		var forbid := _action_button("Forbid")
		forbid.set_meta(&"action", &"forbid")
		forbid.toggle_mode = true
		forbid.tooltip_text = "Forbid the pile's goods so nobody touches them"
		forbid.toggled.connect(
			func(on: bool) -> void:
				colony.set_pile_forbidden(
					Vector3i(_inspected_pile.voxel_position), on
				)
		)
		_inspect_actions.add_child(forbid)
	elif _inspected_plan != null and is_instance_valid(_inspected_plan):
		var cancel := _action_button("Cancel")
		cancel.tooltip_text = "Cancel this construction order"
		cancel.pressed.connect(
			func() -> void:
				colony.cancel_designation(_inspected_plan.voxel_position)
		)
		_inspect_actions.add_child(cancel)
	elif overseer._selected != Vector3i.MAX:
		var building := colony.building_at(overseer._selected)
		if building != null:
			var wreck := _action_button("Deconstruct")
			wreck.tooltip_text = "Tear it down and take the materials back"
			wreck.pressed.connect(
				func() -> void:
					colony.designate_deconstruct(overseer._selected)
			)
			_inspect_actions.add_child(wreck)
	_inspect_actions.visible = _inspect_actions.get_child_count() > 0


func _update_inspect_actions() -> void:
	# Rebuild whenever the strip's subject changed — a fresh pick, a
	# death or haul-away under the card, or a ref set without going
	# through the pick signals. Priority matches the builder.
	var subject: Variant = null
	if _inspected_unit != null and is_instance_valid(_inspected_unit):
		subject = _inspected_unit
	elif _inspected_animal != null and is_instance_valid(_inspected_animal):
		subject = _inspected_animal
	elif _inspected_pile != null and is_instance_valid(_inspected_pile):
		subject = _inspected_pile
	elif (
		_inspected_plan != null
		and is_instance_valid(_inspected_plan)
		and _inspected_plan.is_active()
	):
		subject = _inspected_plan
	elif overseer._selected != Vector3i.MAX:
		subject = overseer._selected
	# A Vector3i selection and a RefCounted plan can't be compared
	# directly — the type check leads the equality test.
	if (
		typeof(subject) != typeof(_inspect_actions_subject)
		or subject != _inspect_actions_subject
	):
		_inspect_actions_subject = subject
		_rebuild_inspect_actions()
	for child in _inspect_actions.get_children():
		match child.get_meta(&"action", &""):
			&"draft":
				child.set_pressed_no_signal(
					_inspected_unit != null
					and is_instance_valid(_inspected_unit)
					and _inspected_unit.drafted
				)
			&"relieved":
				child.set_pressed_no_signal(
					_inspected_unit != null
					and is_instance_valid(_inspected_unit)
					and _inspected_unit.relieved
				)
			&"tame":
				child.disabled = (
					_inspected_animal == null
					or not is_instance_valid(_inspected_animal)
					or colony.tame_marked(_inspected_animal)
				)
			&"forbid":
				if (
					_inspected_pile != null
					and is_instance_valid(_inspected_pile)
				):
					var voxel := Vector3i(_inspected_pile.voxel_position)
					var all := colony.pile_all_forbidden(voxel)
					child.set_pressed_no_signal(all)
					child.text = "Allow" if all else "Forbid"


func _on_pile_picked(pile: ItemPile) -> void:
	_inspected_pile = pile
	_rebuild_inspect_actions()


## The pile card — title off the biggest share, then fill, contents
## and the condition line weathering and decay write.
func _update_pile() -> void:
	if _inspected_pile == null or not is_instance_valid(_inspected_pile):
		_inspected_pile = null
		_pile_panel.visible = false
		return
	_pile_panel.visible = true
	var voxel := Vector3i(_inspected_pile.voxel_position)
	var top: DropItem = null
	for item in _inspected_pile.items:
		if top == null or item.volume > top.volume:
			top = item
	var title := "Pile"
	if top != null:
		var item_name := (
			String(top.species).capitalize()
			if top.species != &""
			else BlockRegistry.resource_name_of(top.material)
		)
		title = (
			"%s %s" % [item_name, DropItem.form_name(top.form)]
			if top.form != DropItem.Form.LOOSE
			else item_name
		)
		if top.quality != 1.0:
			title = "%s (%s)" % [title, DropItem.quality_tier(top.quality)]
	_pile_title.text = title
	var lines := "%.2f / 1.00 m³" % [_pile_fill_display(_inspected_pile)]
	var contents := _pile_contents_text(_inspected_pile)
	if contents != "":
		lines += "\n%s" % contents
	if top != null:
		if top.wear < 0.999:
			lines += "\nCondition %d%%" % int(top.wear * 100.0)
		elif top.quality != 1.0:
			lines += "\nQuality: %s" % DropItem.quality_tier(top.quality)
	if colony.sees_sky(voxel):
		var weathering := false
		var decaying := false
		for item in _inspected_pile.items:
			if not DropItem.weather_rule(item).is_empty():
				weathering = true
			if not DropItem.decay_rule(item).is_empty():
				decaying = true
		var notes := PackedStringArray()
		if weathering:
			notes.append(
				"weathering"
				+ (
					" ×%d in rain" % roundi(colony.WEATHER_RAIN_MULT)
					if colony.weather.precipitating()
					else ""
				)
			)
		if decaying:
			notes.append("decaying")
		if not notes.is_empty():
			lines += "\nDeteriorating: outdoors — %s" % ", ".join(notes)
	if colony.pile_all_forbidden(voxel):
		lines += "\nAll forbidden"
	elif colony.pile_any_forbidden(voxel):
		lines += "\nPartly forbidden"
	_pile_detail.text = lines


func _on_plan_picked(job: ColonyJob) -> void:
	_inspected_plan = job
	_rebuild_inspect_actions()


## The blueprint card — RimWorld's frame inspection: the pending
## construction's name, the materials still owed to it, and what the
## board says about the job.
func _update_plan() -> void:
	if (
		_inspected_plan == null
		or not is_instance_valid(_inspected_plan)
		or not _inspected_plan.is_active()
		or not colony.jobs.has(_inspected_plan)
	):
		_inspected_plan = null
		_plan_panel.visible = false
		return
	_plan_panel.visible = true
	_plan_title.text = "%s (blueprint)" % _plan_label(_inspected_plan)
	var lines := PackedStringArray()
	for want_line in _plan_material_lines(_inspected_plan):
		lines.append(want_line)
	var status := colony.job_board_status(_inspected_plan)
	if status != "":
		lines.append(status.capitalize())
	_plan_detail.text = "\n".join(lines)


## What the pending construction is called — the spec or recipe names
## the thing rather than the work of making it.
func _plan_label(job: ColonyJob) -> String:
	if job.type == ColonyJob.Type.BUILD:
		if job.build_spec == &"conduit":
			return "Conduit"
		if job.face_dir != Vector3i.ZERO:
			var spec: Dictionary = BlockRegistry.FLOOR_SPECS.get(
				job.build_spec, {}
			)
			var floor_name := String(spec.get(&"label", "Floor"))
			return (
				floor_name
				if "floor" in floor_name.to_lower()
				else "%s floor" % floor_name
			)
		if not BlockRegistry.spec_is_door(job.build_spec):
			var wall_name := BlockRegistry.block_name(job.block_id)
			if (
				BlockRegistry.is_rock_material(job.material)
				and job.material != BlockRegistry.Resource_.STONE
			):
				wall_name = "%s wall" % (
					BlockRegistry.resource_name_of(job.material)
				)
			return wall_name
		var door_name := String(job.build_spec).replace("_", " ")
		return door_name[0].to_upper() + door_name.substr(1)
	# Furniture and other in-place builds run the craft machinery —
	# recipe labels are imperative ("Build royal bed", "Set spike
	# trap"); the blueprint names the thing.
	var label := String(
		Colony.recipe_of(job.recipe).get(&"label", "")
	)
	if label == "":
		label = String(job.recipe).replace("_", " ")
	for verb in [
		"build ", "make ", "lay ", "mark ", "set ", "carve ", "stack ",
		"shape ", "rivet ", "prepare ", "pour ", "beat ", "draw ",
	]:
		if label.to_lower().begins_with(verb):
			label = label.substr(verb.length())
			break
	if label == "":
		return "Construction"
	return label[0].to_upper() + label.substr(1)


## One "have/want" line per material the pending construction still
## absorbs — discrete items count off (`Planks 3/5`), loose fills
## measure in m³.
func _plan_material_lines(job: ColonyJob) -> PackedStringArray:
	var lines := PackedStringArray()
	if job.type == ColonyJob.Type.BUILD:
		var recipe := Colony.build_recipe_of(job)
		for form: int in recipe:
			var want := int(recipe[form])
			var got := int(job.delivered.get(form, 0))
			if form == DropItem.Form.LOOSE:
				lines.append(
					"Loose material: %.2f / %.2f m³"
					% [got / 1e6, want / 1e6]
				)
			else:
				var each := DropItem.form_volume(form)
				lines.append(
					"%s: %d/%d" % [
						DropItem.form_name(form).capitalize(),
						mini(got, want) / each, want / each,
					]
				)
		return lines
	var recipe := Colony.recipe_of(job.recipe)
	var inputs: Dictionary = recipe.get("inputs", {})
	for form: int in inputs:
		var want := int(inputs[form])
		var each := DropItem.form_volume(form)
		var got := int(job.delivered.get(form, 0)) / each
		lines.append(
			"%s: %d/%d" % [
				DropItem.form_name(form).capitalize(), got, want,
			]
		)
	var loose: Dictionary = recipe.get(&"input_loose", {})
	for material: int in loose:
		var want := int(loose[material])
		var got := int(
			job.delivered.get(Unit.DELIVERED_MATERIAL_OFF + material, 0)
		)
		lines.append(
			"%s: %.2f / %.2f m³" % [
				BlockRegistry.resource_name_of(material),
				got / 1e6, want / 1e6,
			]
		)
	var need_spec := StringName(recipe.get(&"needs_spec", &""))
	if need_spec != &"":
		lines.append("Needs a %s in the stores" % need_spec)
	var requires := int(recipe.get("requires", -1))
	if requires >= 0:
		lines.append(
			"Requires: %s" % (
				String(ColonyJob.Skill.keys()[requires]).capitalize()
			)
		)
	return lines


## The hover readout cedes its slot to whichever card is up — the
## inspect pane hides while any selection panel is showing.
func _sync_inspect_visibility() -> void:
	_inspect_panel.visible = not (
		_worksite_panel.visible
		or _stockpile_panel.visible
		or _farm_panel.visible
		or _unit_panel.visible
		or _animal_panel.visible
		or _plan_panel.visible
		or _pile_panel.visible
	)


## Above the inspect pane: the selected building's panel — its name and
## composition, and the controls a worksite offers: order a craft, cancel
## the running order, or mark the thing for deconstruction.
func _build_worksite(parent: Control) -> void:
	_worksite_panel = PanelContainer.new()
	_worksite_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_worksite_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_worksite_panel.offset_left = 8
	_worksite_panel.offset_top = -300
	_worksite_panel.offset_bottom = -42
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
	# The bill picker — one categorized menu instead of a flat button
	# row: the craft list alone runs fifty recipes wide. The popup
	# rebuilds on every open so site-gated and specimen-gated bills
	# always list what the bench could actually run.
	_bills_button = MenuButton.new()
	_bills_button.text = "Bills…"
	_bills_button.flat = false
	_bills_button.focus_mode = Control.FOCUS_NONE
	_bills_button.tooltip_text = "Queue a work order on this site"
	_bills_button.get_popup().about_to_popup.connect(_rebuild_bill_menu)
	# Flat picks land on the popup itself; category submenus carry
	# their own per-rebuild handler (they're rebuilt with the menu).
	_bills_button.get_popup().index_pressed.connect(
		func(index: int) -> void:
			var recipe_id: Variant = (
				_bills_button.get_popup().get_item_metadata(index)
			)
			if recipe_id != null:
				colony.queue_order(overseer._selected, recipe_id)
	)
	vbox.add_child(_bills_button)
	# The campfire's controls — lit state rides the detail line, and the
	# toggle/threshold/stoke row shows only for its kind.
	_campfire_box = HBoxContainer.new()
	_campfire_box.add_theme_constant_override("separation", 6)
	vbox.add_child(_campfire_box)
	_campfire_auto = CheckBox.new()
	_campfire_auto.text = "Auto-refuel"
	_campfire_auto.focus_mode = Control.FOCUS_NONE
	_campfire_auto.tooltip_text = (
		"Have a unit feed the fire when it burns below the threshold"
	)
	_campfire_auto.toggled.connect(
		func(on: bool) -> void:
			var building := colony.fueled_at(overseer._selected)
			if building != null:
				building.auto_refuel = on
	)
	_campfire_box.add_child(_campfire_auto)
	_campfire_threshold = SpinBox.new()
	_campfire_threshold.min_value = 0.05
	_campfire_threshold.max_value = 0.95
	_campfire_threshold.step = 0.05
	_campfire_threshold.add_theme_constant_override("separation", 2)
	_campfire_threshold.tooltip_text = "Refuel when under this share of the fuel cap"
	_campfire_threshold.value_changed.connect(
		func(value: float) -> void:
			var building := colony.fueled_at(overseer._selected)
			if building != null:
				building.refuel_fraction = value
	)
	_campfire_box.add_child(_campfire_threshold)
	_campfire_stoke = _hud_button()
	_campfire_stoke.text = "Refuel now"
	_campfire_stoke.tooltip_text = "Post a refuel job regardless of the threshold"
	_campfire_stoke.pressed.connect(
		func() -> void: colony.request_refuel(overseer._selected)
	)
	_campfire_box.add_child(_campfire_stoke)
	# The floodgate's control — a continuous open fraction the way
	# Timberborn's gates take one: the slider writes straight through
	# to the water sim's edge scales via Colony.set_floodgate_open.
	_gate_box = HBoxContainer.new()
	_gate_box.add_theme_constant_override("separation", 6)
	vbox.add_child(_gate_box)
	var gate_label := Label.new()
	gate_label.text = "Open"
	_gate_box.add_child(gate_label)
	_gate_slider = HSlider.new()
	_gate_slider.min_value = 0.0
	_gate_slider.max_value = 1.0
	_gate_slider.step = 0.05
	_gate_slider.custom_minimum_size.x = 110
	_gate_slider.focus_mode = Control.FOCUS_NONE
	_gate_slider.tooltip_text = (
		"How far the sluice opens — 0 seals the cell's lateral "
		+ "water edges, 1 lets them run unregulated"
	)
	_gate_slider.value_changed.connect(
		func(value: float) -> void:
			if overseer._selected != Vector3i.MAX:
				colony.set_floodgate_open(overseer._selected, value)
				_gate_value.text = "%d%%" % int(round(value * 100.0))
	)
	_gate_box.add_child(_gate_slider)
	_gate_value = Label.new()
	_gate_box.add_child(_gate_value)
	# The bed's medical toggle — a flagged bed is the established
	# facility a real tend needs; anywhere else first aid only stops
	# bleeding.
	_bed_medical = CheckBox.new()
	_bed_medical.text = "Medical bed"
	_bed_medical.focus_mode = Control.FOCUS_NONE
	_bed_medical.tooltip_text = (
		"Patients delivered here get real treatment (wounds heal 3x, "
		+ "doctors can spend herb bundles). Care anywhere else only "
		+ "stops bleeding."
	)
	_bed_medical.toggled.connect(
		func(on: bool) -> void:
			if overseer._selected != Vector3i.MAX:
				var building := colony.building_at(overseer._selected)
				if building != null and building.kind == Building.Kind.BED:
					building.medical = on
					_update_worksite()
	)
	vbox.add_child(_bed_medical)
	_worksite_orders_box = VBoxContainer.new()
	_worksite_orders_box.add_theme_constant_override("separation", 2)
	vbox.add_child(_worksite_orders_box)
	_worksite_cancel = _hud_button()
	_worksite_cancel.text = "Cancel order"
	_worksite_cancel.tooltip_text = "Drop the craft order queued here"
	_worksite_cancel.pressed.connect(
		func() -> void: colony.cancel_craft_order(overseer._selected)
	)
	vbox.add_child(_worksite_cancel)
	_worksite_deconstruct = _hud_button()
	_worksite_deconstruct.text = "Deconstruct"
	_worksite_deconstruct.tooltip_text = "Have a unit take this apart"
	_worksite_deconstruct.pressed.connect(
		func() -> void: colony.designate_deconstruct(overseer._selected)
	)
	vbox.add_child(_worksite_deconstruct)
	parent.add_child(_worksite_panel)


## The stockpile tile's panel: what the tile admits, as a checkbox per
## material class. Flipping one updates the tile's filter — rejected
## contents become haul-out candidates on the next idle haul pass.
func _build_stockpile(parent: Control) -> void:
	_stockpile_panel = PanelContainer.new()
	_stockpile_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_stockpile_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stockpile_panel.offset_left = 8
	_stockpile_panel.offset_top = -260
	_stockpile_panel.offset_bottom = -42
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
	# The zone's storage priority — the deliver-to-best query picks the
	# highest rank admitting the load before any distance comparison.
	var pri_row := HBoxContainer.new()
	pri_row.add_theme_constant_override("separation", 6)
	var pri_label := Label.new()
	pri_label.text = "Priority"
	pri_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	pri_row.add_child(pri_label)
	_stockpile_priority = OptionButton.new()
	_stockpile_priority.focus_mode = Control.FOCUS_NONE
	for text in StockpileZone.PRIORITY_NAMES:
		_stockpile_priority.add_item(text)
	_stockpile_priority.item_selected.connect(
		func(index: int) -> void:
			if overseer._selected != Vector3i.MAX:
				colony.set_stockpile_priority(
					overseer._selected,
					StockpileZone.Priority.values()[index]
				)
	)
	pri_row.add_child(_stockpile_priority)
	vbox.add_child(pri_row)
	# Filter clipboard + presets — copy lifts the zone's reject set,
	# paste stamps it onto this zone; a named preset persists to
	# user://filter_presets.json across saves and sessions.
	var clip_row := HBoxContainer.new()
	clip_row.add_theme_constant_override("separation", 4)
	var copy := _hud_button()
	copy.text = "Copy filter"
	copy.tooltip_text = "Copy this zone's material filter"
	copy.pressed.connect(
		func() -> void:
			var zone := colony.stockpile_at(overseer._selected)
			if zone != null:
				_filter_clipboard = zone.rejected.duplicate()
	)
	clip_row.add_child(copy)
	var paste := _hud_button()
	paste.text = "Paste filter"
	paste.tooltip_text = "Apply the copied filter to this zone"
	paste.pressed.connect(
		func() -> void:
			if not _filter_clipboard.is_empty():
				colony.set_stockpile_filter(
					overseer._selected, _filter_clipboard
				)
	)
	clip_row.add_child(paste)
	vbox.add_child(clip_row)
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 4)
	_preset_name = LineEdit.new()
	_preset_name.custom_minimum_size.x = 120
	_preset_name.placeholder_text = "Preset name"
	preset_row.add_child(_preset_name)
	var save := _hud_button()
	save.text = "Save"
	save.tooltip_text = "Save this zone's filter as a named preset"
	save.pressed.connect(
		func() -> void:
			var zone := colony.stockpile_at(overseer._selected)
			if zone == null:
				return
			FilterPresets.save(_preset_name.text, zone.rejected)
			_preset_count = -1
	)
	preset_row.add_child(save)
	_preset_picker = OptionButton.new()
	_preset_picker.focus_mode = Control.FOCUS_NONE
	_preset_picker.tooltip_text = "Saved filter presets"
	_preset_picker.item_selected.connect(
		func(index: int) -> void:
			var name := _preset_picker.get_item_text(index)
			colony.set_stockpile_filter(
				overseer._selected, FilterPresets.preset(name)
			)
			_preset_name.text = name
	)
	preset_row.add_child(_preset_picker)
	vbox.add_child(preset_row)
	parent.add_child(_stockpile_panel)


## The farm field's panel: a toggle button per plantable species assigns
## the crop — shrubs and trees alike — and a tree field gets the
## auto-chop switch. Same slot as the stockpile panel; the selection is
## one or the other.
func _build_farm(parent: Control) -> void:
	_farm_panel = PanelContainer.new()
	_farm_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_farm_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_farm_panel.offset_left = 8
	_farm_panel.offset_top = -260
	_farm_panel.offset_bottom = -42
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
	_farm_auto_fertilize = CheckBox.new()
	_farm_auto_fertilize.text = "Fertilize soil"
	_farm_auto_fertilize.tooltip_text = (
		"Spread compost on every cell below the target fertility — "
		+ "the field tops itself up as long as compost exists"
	)
	_farm_auto_fertilize.focus_mode = Control.FOCUS_NONE
	_farm_auto_fertilize.toggled.connect(
		func(on: bool) -> void:
			if overseer._selected != Vector3i.MAX:
				colony.set_farm_auto_fertilize(overseer._selected, on)
	)
	vbox.add_child(_farm_auto_fertilize)
	var fert_row := HBoxContainer.new()
	fert_row.add_theme_constant_override("separation", 6)
	vbox.add_child(fert_row)
	_farm_fert_label = Label.new()
	_farm_fert_label.add_theme_color_override(
		"font_color", Color(1, 1, 1, 0.7)
	)
	fert_row.add_child(_farm_fert_label)
	_farm_fert_slider = HSlider.new()
	_farm_fert_slider.min_value = 0.5
	_farm_fert_slider.max_value = 5.0
	_farm_fert_slider.step = 0.1
	_farm_fert_slider.tooltip_text = (
		"Target soil fertility — dirt starts at 1.0; the auto-fertilizer "
		+ "keeps cells at or above this"
	)
	_farm_fert_slider.custom_minimum_size.x = 110
	_farm_fert_slider.value_changed.connect(
		func(value: float) -> void:
			_farm_fert_label.text = "Fertility ≥ %.1f" % value
			if overseer._selected != Vector3i.MAX:
				colony.set_farm_fertilize_target(overseer._selected, value)
	)
	fert_row.add_child(_farm_fert_slider)
	parent.add_child(_farm_panel)


func _on_selection_changed(_voxel: Vector3i) -> void:
	_update_selection()
	_rebuild_inspect_actions()


## An inspect-click on a unit — open the settler panel for it; null
## (the Esc/RMB fallthrough) closes whichever unit was up.
func _on_unit_picked(unit: Unit) -> void:
	_inspected_unit = unit
	_rebuild_inspect_actions()


## The selection panels follow the overseer's selection: hidden when
## nothing is selected or the thing under it is gone (deconstructed,
## undesignated). A building fills the worksite panel; a stockpile tile
## fills its admission checkboxes from the live filter.
func _update_selection() -> void:
	_update_worksite()
	_update_stockpile()
	_update_farm()


## The world-hover tooltip — RimWorld's mouseover readout: a short
## dwell on a settler, animal, pile or construction floats a card at
## the cursor. Suppressed over UI, while a tool is armed, or mid-drag.
func _build_tooltip(parent: Control) -> void:
	_tooltip_panel = PanelContainer.new()
	_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_panel.visible = false
	_tooltip_label = Label.new()
	_tooltip_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_tooltip_panel.add_child(_tooltip_label)
	parent.add_child(_tooltip_panel)


## Seconds of steady hover before the tooltip arms — fast enough to
## feel immediate, slow enough that panning the camera doesn't flash it.
const TOOLTIP_DWELL := 0.4


func _update_tooltip(delta: float) -> void:
	var suppressed := (
		get_viewport().gui_get_hovered_control() != null
		or overseer._action_index >= 0
		or overseer._action_menu_open
		or overseer._drag_active
		or overseer._press_active
	)
	var critter := overseer.targeted_critter()
	var hit := overseer.targeted_voxel()
	var key: Variant = null
	if not suppressed:
		if critter != null and is_instance_valid(critter):
			key = critter
		elif hit != null:
			key = hit.position
	# A cell key and a critter key have different types — comparing them
	# directly is an invalid-operand error, so the type check leads.
	if typeof(key) != typeof(_hover_key) or key != _hover_key:
		_hover_key = key
		_hover_dwell = 0.0
	elif _hover_dwell < TOOLTIP_DWELL:
		_hover_dwell += delta
	var text := (
		""
		if _hover_dwell < TOOLTIP_DWELL
		else _tooltip_text(critter, hit)
	)
	if text.is_empty():
		_tooltip_panel.visible = false
		return
	_tooltip_label.text = text
	_tooltip_panel.visible = true
	# Follow the cursor, clamped inside the window so a bottom-right
	# hover flips the card up and left instead of clipping.
	var pos := get_viewport().get_mouse_position() + Vector2(16, 14)
	var vp := get_viewport().get_visible_rect().size
	var sz := _tooltip_panel.get_combined_minimum_size()
	pos.x = minf(pos.x, vp.x - sz.x - 4)
	pos.y = minf(pos.y, vp.y - sz.y - 4)
	_tooltip_panel.position = pos


## One or two lines for the hover card: the critter's who-and-what,
## or the aimed cell's what-and-how-much.
func _tooltip_text(critter: Node3D, hit: Overseer.AimHit) -> String:
	if critter != null and is_instance_valid(critter):
		var line: String = (
			String(critter.name) if critter is Unit else critter.label()
		) + " — " + critter.current_activity()
		if critter is Unit:
			var unit := critter as Unit
			if unit.dead:
				return "%s — dead" % unit.name
			if unit.is_downed():
				line += " (downed)"
			elif unit.drafted:
				line += " (drafted)"
		elif critter is Animal:
			var animal := critter as Animal
			if animal.domestic:
				line += " (domestic)"
			elif animal.tame_progress > 0.0:
				line += " (%d%% tamed)" % int(animal.tame_progress * 100.0)
		return line
	if hit == null:
		return ""
	var line := ""
	var building := (
		colony.building_at(hit.position)
		if colony.building_at(hit.position) != null
		else colony.building_at(hit.previous_position)
	)
	if building != null:
		line = building.label()
		if building.hp < building.max_hp:
			line += " (integrity %d%%)" % int(building.integrity() * 100.0)
	else:
		var plan := (
			colony.plan_job_at(hit.previous_position)
			if colony.plan_job_at(hit.previous_position) != null
			else colony.plan_job_at(hit.position)
		)
		if plan != null:
			line = "%s (blueprint)" % _plan_label(plan)
		else:
			line = BlockRegistry.block_name(
				colony.world.get_block(hit.position)
			)
	if colony.is_stockpile(hit.previous_position):
		line += " — stockpile"
	var pile := colony.item_pile_at(hit.previous_position)
	if pile != null and not pile.items.is_empty():
		line += "\n%s" % _pile_contents_text(pile)
	var water_depth := _water_depth_at(hit.position.x, hit.position.z)
	if water_depth > 0.0:
		line += "\nWater: %.2f m" % water_depth
	return line


## Standing-water depth in metres for a column, or -1 when dry — the
## surface fill measured over the first solid bed below the waterline,
## so a rain film reads in millimetres, not whole voxels.
func _water_depth_at(x: int, z: int) -> float:
	var level := colony.world.water_level_at(x, z)
	if level == SiteField.DRY:
		return -1.0
	var surface := colony.world.water_surface_at(x, z)
	var bed := level - 1
	while (
		bed > level - 17
		and not colony.world.is_solid(Vector3i(x, bed, z))
	):
		bed -= 1
	return surface - float(bed + 1)


## Rebuilds the bills popup for the selected building — craft recipes
## the site's rate table admits, grouped under recipe_category, then
## the bench-specific groups (studies, garment work, tool repairs).
## Built on open so specimen- and kind-gated bills always list what
## the bench could actually run; a lone group reads flat.
func _rebuild_bill_menu() -> void:
	var pop := _bills_button.get_popup()
	# Nested submenus are children — free them with the stale items.
	for child in pop.get_children():
		child.queue_free()
	pop.clear()
	var building := colony.building_at(overseer._selected)
	if building == null:
		return
	var locked := colony.deconstruct_job_at(overseer._selected) != null
	# Category label → recipe ids, first-seen order preserved.
	var groups: Array[String] = []
	var ids_in: Dictionary = {}
	var file := func(cat: String, recipe_id: StringName) -> void:
		if not ids_in.has(cat):
			ids_in[cat] = []
			groups.append(cat)
		ids_in[cat].append(recipe_id)
	if building.is_worksite():
		for recipe_id in Colony.RECIPE_ORDER:
			if (
				Colony.recipe_site_rate(
					Colony.recipe_of(recipe_id), building.kind
				)
				> 0.0
			):
				file.call(Colony.recipe_category(recipe_id), recipe_id)
	if building.kind == Building.Kind.RESEARCH:
		for recipe_id in colony.study_options():
			file.call("Studies", recipe_id)
	if building.kind == Building.Kind.TAILOR:
		for recipe_id in colony.garment_work_options():
			file.call("Garment work", recipe_id)
	if building.kind == Building.Kind.TOOLMAKER:
		for recipe_id in colony.tool_work_options():
			file.call("Tool repair", recipe_id)
	var queue := func(menu: PopupMenu, ids: Array) -> void:
		for recipe_id: StringName in ids:
			menu.add_item(
				Colony.recipe_of(recipe_id).get(&"label", recipe_id)
			)
			var index := menu.item_count - 1
			menu.set_item_metadata(index, recipe_id)
			menu.set_item_disabled(index, locked)
	for cat in groups:
		var ids: Array = ids_in[cat]
		if groups.size() == 1:
			# A lone category reads flat — no submenu for its own sake.
			queue.call(pop, ids)
		else:
			var sub := PopupMenu.new()
			sub.name = "bills_%s" % cat
			queue.call(sub, ids)
			sub.index_pressed.connect(
				func(index: int) -> void:
					colony.queue_order(
						overseer._selected, sub.get_item_metadata(index)
					)
			)
			pop.add_child(sub)
			pop.add_submenu_item(cat, sub.name)


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
	var detail := building.describe_components()
	if building.uses_fuel():
		var burn := "%d s" % int(building.fuel)
		if building.fuel >= 60.0:
			burn = "%.1f min" % (building.fuel / 60.0)
		detail += (
			("\n" if not detail.is_empty() else "")
			+ "Fuel: %s (%s)" % [
				burn, "lit" if building.lit() else "out",
			]
		)
	if (
		building.kind == Building.Kind.HEATER
		or building.kind == Building.Kind.COOLER
		or building.kind == Building.Kind.PUMP
	):
		detail += (
			("\n" if not detail.is_empty() else "")
			+ "Power: %s" % ["on" if building.powered else "off"]
		)
	if building.kind == Building.Kind.WATER_WHEEL:
		detail += (
			("\n" if not detail.is_empty() else "")
			+ "Output: %d W" % int(colony._wheel_watts(building))
		)
	if building.hp < building.max_hp:
		detail += (
			("\n" if not detail.is_empty() else "")
			+ "Integrity: %d%%" % int(building.integrity() * 100.0)
		)
	_worksite_detail.text = detail
	var worksite := building.is_worksite()
	var order := colony.craft_job_at(voxel)
	# The bill menu shows on anything that can take a bill — craftable
	# worksites plus the research/tailor/toolmaker benches' own groups.
	# Ordering never locks — picks enqueue behind the running job.
	_bills_button.visible = (
		worksite
		or building.kind == Building.Kind.RESEARCH
		or building.kind == Building.Kind.TAILOR
		or building.kind == Building.Kind.TOOLMAKER
	)
	_bills_button.disabled = colony.deconstruct_job_at(voxel) != null
	var campfire := building.uses_fuel()
	_campfire_box.visible = campfire
	if campfire:
		_campfire_auto.set_pressed_no_signal(building.auto_refuel)
		_campfire_threshold.set_value_no_signal(building.refuel_fraction)
		_campfire_stoke.disabled = (
			colony.deconstruct_job_at(voxel) != null
			or colony.refuel_job_at(voxel) != null
		)
	_bed_medical.visible = building.kind == Building.Kind.BED
	if building.kind == Building.Kind.BED:
		_bed_medical.set_pressed_no_signal(building.medical)
	var gate := building.kind == Building.Kind.FLOODGATE
	_gate_box.visible = gate
	if gate:
		_gate_slider.set_value_no_signal(building.open_fraction)
		_gate_value.text = "%d%%" % int(round(building.open_fraction * 100.0))
	_worksite_cancel.visible = worksite
	_worksite_cancel.disabled = order == null
	_update_worksite_orders(building if worksite else null)
	_worksite_deconstruct.disabled = (
		not building.deconstructable
		or colony.deconstruct_job_at(voxel) != null
	)


## Syncs the order rows with the building's bill queue — one row per
## order: recipe and progress, the repeat-condition picker, its count,
## and a button that drops the bill (cancelling the run if it's live).
func _update_worksite_orders(building: Building) -> void:
	var orders: Array = [] if building == null else building.orders
	var stale := _order_rows.size() != orders.size()
	# A rebuild drops the hovered row — take its radius ring with it.
	if stale or building == null:
		colony.hide_fetch_radius()
	if not stale:
		for i in orders.size():
			if _order_rows[i][&"order"] != orders[i]:
				stale = true
				break
	if stale:
		for row in _order_rows:
			row[&"row"].queue_free()
		_order_rows.clear()
		# Dead orders drop out of the expanded-state map with them.
		for key in _order_expanded.keys():
			if not orders.has(key):
				_order_expanded.erase(key)
		for order in orders:
			_order_rows.append(_build_order_row(order, building))
	if _order_rows.is_empty():
		return
	for i in orders.size():
		var order: WorksiteOrder = orders[i]
		var row: Dictionary = _order_rows[i]
		row[&"label"].text = "%s — %s" % [
			Colony.recipe_of(order.recipe).get("label", order.recipe),
			order.summary(colony._have_count(order.recipe, order)),
		]
		row[&"condition"].select(int(order.condition))
		row[&"target"].set_value_no_signal(order.target)
		row[&"target"].editable = order.condition != WorksiteOrder.Condition.FOREVER
		row[&"pause"].set_pressed_no_signal(order.paused)
		var is_until := order.condition == WorksiteOrder.Condition.UNTIL_HAVE
		row[&"unpause"].visible = is_until
		if is_until:
			row[&"unpause"].set_value_no_signal(order.unpause_level())
		row[&"deliver"].select(int(order.deliver_mode))
		row[&"zone"].visible = order.deliver_mode == WorksiteOrder.Deliver.ZONE
		row[&"radius"].set_value_no_signal(order.ingredient_radius)
		row[&"skill_min"].set_value_no_signal(order.skill_min)
		row[&"skill_max"].set_value_no_signal(order.skill_max)
		row[&"stored_only"].set_pressed_no_signal(order.count_stored_only)
		row[&"wear_min"].set_value_no_signal(order.wear_min * 100.0)
		row[&"wear_max"].set_value_no_signal(order.wear_max * 100.0)
		for box: CheckBox in row[&"mat_boxes"]:
			box.set_pressed_no_signal(
				not order.rejected_materials.has(int(box.get_meta(&"material")))
			)
		_sync_order_picker(row, order)


## Repopulates an order row's zone and worker pickers only when their
## lists change — rebuilding mid-frame would yank an open dropdown.
func _sync_order_picker(row: Dictionary, order: WorksiteOrder) -> void:
	var zones := colony.stockpile_zones()
	if row[&"zone_count"] != zones.size():
		row[&"zone_count"] = zones.size()
		var picker: OptionButton = row[&"zone"]
		picker.clear()
		for z in zones.size():
			var zone := zones[z]
			var first: Vector3i = zone.cells.keys()[0]
			picker.add_item("Zone %d (%d cells)" % [z + 1, zone.cells.size()])
			picker.set_item_metadata(z, first)
		row[&"zones"] = zones
	if order.deliver_mode == WorksiteOrder.Deliver.ZONE:
		var zone := colony.stockpile_at(order.deliver_target)
		var picked := -1
		for z in (row[&"zones"] as Array).size():
			if row[&"zones"][z] == zone:
				picked = z
		if picked >= 0:
			row[&"zone"].select(picked)
	if row[&"worker_count"] != colony.units.size():
		row[&"worker_count"] = colony.units.size()
		var picker: OptionButton = row[&"worker"]
		picker.clear()
		picker.add_item("Anyone")
		for u in colony.units.size():
			picker.add_item("Worker %d" % (u + 1))
	row[&"worker"].select(mini(order.worker_index + 1, row[&"worker_count"]))


## One queued-bill row for the worksite panel — a main row of queue
## controls and a collapsible details block: product destination,
## ingredient radius and materials, worker and skill limits, and the
## until-bill's unpause threshold. Controls write straight into the
## order record.
func _build_order_row(
	order: WorksiteOrder, building: Building
) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	var label := Label.new()
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var condition := OptionButton.new()
	condition.focus_mode = Control.FOCUS_NONE
	for text in ["Do X times", "Until you have X", "Forever"]:
		condition.add_item(text)
	condition.item_selected.connect(
		func(index: int) -> void:
			order.condition = WorksiteOrder.Condition.values()[index]
			order.satisfied = false
	)
	row.add_child(condition)
	var target := SpinBox.new()
	target.min_value = 1
	target.max_value = 9999
	target.step = 1
	target.custom_minimum_size.x = 72
	target.value_changed.connect(
		func(value: float) -> void: order.target = int(value)
	)
	row.add_child(target)
	var up := _hud_button()
	up.text = "▲"
	up.tooltip_text = "Move this bill earlier in the queue"
	up.pressed.connect(
		func() -> void: colony.move_order(overseer._selected, order, -1)
	)
	row.add_child(up)
	var down := _hud_button()
	down.text = "▼"
	down.tooltip_text = "Move this bill later in the queue"
	down.pressed.connect(
		func() -> void: colony.move_order(overseer._selected, order, 1)
	)
	row.add_child(down)
	var pause := _hud_button()
	pause.text = "‖"
	pause.toggle_mode = true
	pause.tooltip_text = "Suspend or resume this bill"
	pause.toggled.connect(
		func(on: bool) -> void:
			colony.set_order_paused(overseer._selected, order, on)
	)
	row.add_child(pause)
	var copy := _hud_button()
	copy.text = "⧉"
	copy.tooltip_text = "Queue a copy of this bill"
	copy.pressed.connect(
		func() -> void: colony.duplicate_order(overseer._selected, order)
	)
	row.add_child(copy)
	var details := _hud_button()
	details.text = "⚙"
	details.tooltip_text = "Bill details"
	var detail_box := VBoxContainer.new()
	detail_box.add_theme_constant_override("separation", 2)
	detail_box.visible = _order_expanded.get(order, false)
	details.pressed.connect(
		func() -> void:
			_order_expanded[order] = not _order_expanded.get(order, false)
			detail_box.visible = _order_expanded[order]
	)
	row.add_child(details)
	var drop := _hud_button()
	drop.text = "×"
	drop.tooltip_text = "Remove this order from the queue"
	drop.pressed.connect(
		func() -> void: colony.remove_order(overseer._selected, order)
	)
	row.add_child(drop)
	box.add_child(detail_box)

	# --- Details line 1: product destination + ingredient radius ---
	var line1 := HBoxContainer.new()
	line1.add_theme_constant_override("separation", 4)
	detail_box.add_child(line1)
	var deliver := OptionButton.new()
	deliver.focus_mode = Control.FOCUS_NONE
	for text in ["Drop at spot", "Best stockpile", "Take to zone"]:
		deliver.add_item(text)
	deliver.tooltip_text = "Where finished products go"
	deliver.item_selected.connect(
		func(index: int) -> void:
			order.deliver_mode = WorksiteOrder.Deliver.values()[index]
	)
	line1.add_child(deliver)
	var zone := OptionButton.new()
	zone.focus_mode = Control.FOCUS_NONE
	zone.tooltip_text = "The stockpile zone to deliver to"
	zone.item_selected.connect(
		func(index: int) -> void:
			order.deliver_target = zone.get_item_metadata(index)
	)
	line1.add_child(zone)
	var radius_label := Label.new()
	radius_label.text = "Radius"
	radius_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	line1.add_child(radius_label)
	var radius := SpinBox.new()
	radius.min_value = 0
	radius.max_value = 256
	radius.step = 1
	radius.custom_minimum_size.x = 56
	radius.tooltip_text = "Fetch ingredients only this far from the site (0 = anywhere)"
	radius.value_changed.connect(
		func(value: float) -> void:
			order.ingredient_radius = value
			# Retarget the outline live while it's showing.
			if radius.has_focus() and building != null:
				colony.show_fetch_radius(
					building.voxel, order.ingredient_radius
				)
	)
	radius.mouse_entered.connect(
		func() -> void:
			if building != null:
				colony.show_fetch_radius(
					building.voxel, order.ingredient_radius
				)
	)
	radius.mouse_exited.connect(
		func() -> void: colony.hide_fetch_radius()
	)
	line1.add_child(radius)

	# --- Details line 2: worker, skill band, until extras ---
	var line2 := HBoxContainer.new()
	line2.add_theme_constant_override("separation", 4)
	detail_box.add_child(line2)
	var worker := OptionButton.new()
	worker.focus_mode = Control.FOCUS_NONE
	worker.tooltip_text = "The only worker allowed on this bill"
	worker.item_selected.connect(
		func(index: int) -> void: order.worker_index = index - 1
	)
	line2.add_child(worker)
	var skill_label := Label.new()
	skill_label.text = "Skill"
	skill_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	line2.add_child(skill_label)
	var skill_min := SpinBox.new()
	skill_min.min_value = 0
	skill_min.max_value = 20
	skill_min.step = 1
	skill_min.custom_minimum_size.x = 44
	skill_min.tooltip_text = "Minimum skill level"
	skill_min.value_changed.connect(
		func(value: float) -> void: order.skill_min = int(value)
	)
	line2.add_child(skill_min)
	var skill_max := SpinBox.new()
	skill_max.min_value = 0
	skill_max.max_value = 20
	skill_max.step = 1
	skill_max.custom_minimum_size.x = 44
	skill_max.tooltip_text = "Maximum skill level"
	skill_max.value_changed.connect(
		func(value: float) -> void: order.skill_max = int(value)
	)
	line2.add_child(skill_max)
	var unpause := SpinBox.new()
	unpause.min_value = 0
	unpause.max_value = 9999
	unpause.step = 1
	unpause.custom_minimum_size.x = 56
	unpause.tooltip_text = "Until-bill: resume when stock drops to this"
	unpause.value_changed.connect(
		func(value: float) -> void: order.unpause_at = int(value)
	)
	line2.add_child(unpause)
	var stored_only := CheckBox.new()
	stored_only.text = "Count stored only"
	stored_only.focus_mode = Control.FOCUS_NONE
	stored_only.tooltip_text = "Until-bill: count only items on stockpile tiles"
	stored_only.toggled.connect(
		func(on: bool) -> void: order.count_stored_only = on
	)
	line2.add_child(stored_only)

	# --- Details line 3: ingredient wear band ---
	var wear_line := HBoxContainer.new()
	wear_line.add_theme_constant_override("separation", 4)
	detail_box.add_child(wear_line)
	var wear_label := Label.new()
	wear_label.text = "Wear"
	wear_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	wear_line.add_child(wear_label)
	var wear_min := SpinBox.new()
	wear_min.min_value = 0
	wear_min.max_value = 100
	wear_min.step = 5
	wear_min.custom_minimum_size.x = 52
	wear_min.tooltip_text = (
		"Ingredients must be at least this intact (%)"
	)
	wear_min.value_changed.connect(
		func(value: float) -> void:
			order.wear_min = clampf(value / 100.0, 0.0, order.wear_max)
	)
	wear_line.add_child(wear_min)
	var wear_dash := Label.new()
	wear_dash.text = "–"
	wear_dash.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	wear_line.add_child(wear_dash)
	var wear_max := SpinBox.new()
	wear_max.min_value = 0
	wear_max.max_value = 100
	wear_max.step = 5
	wear_max.custom_minimum_size.x = 52
	wear_max.tooltip_text = (
		"Ingredients must be at most this intact (%) — "
		+ "lower it to take only worn goods"
	)
	wear_max.value_changed.connect(
		func(value: float) -> void:
			order.wear_max = clampf(value / 100.0, order.wear_min, 1.0)
	)
	wear_line.add_child(wear_max)

	# --- Details line 4: input material filter ---
	var mats := GridContainer.new()
	mats.columns = 5
	mats.add_theme_constant_override("h_separation", 6)
	detail_box.add_child(mats)
	var mat_boxes: Array[CheckBox] = []
	for material in BlockRegistry.Resource_.values():
		if material == BlockRegistry.Resource_.NONE:
			continue
		var mbox := CheckBox.new()
		mbox.text = BlockRegistry.RESOURCE_NAMES[material]
		mbox.focus_mode = Control.FOCUS_NONE
		mbox.set_meta(&"material", material)
		mbox.tooltip_text = "Allow this material as an ingredient"
		mbox.toggled.connect(
			func(on: bool) -> void:
				if on:
					order.rejected_materials.erase(int(material))
				else:
					order.rejected_materials[int(material)] = true
		)
		mbox.set_pressed_no_signal(
			not order.rejected_materials.has(int(material))
		)
		mats.add_child(mbox)
		mat_boxes.append(mbox)

	_worksite_orders_box.add_child(box)
	return {
		&"order": order, &"row": box, &"label": label,
		&"condition": condition, &"target": target,
		&"pause": pause, &"details": details, &"detail_box": detail_box,
		&"deliver": deliver, &"zone": zone, &"radius": radius,
		&"worker": worker, &"skill_min": skill_min, &"skill_max": skill_max,
		&"unpause": unpause, &"stored_only": stored_only,
		&"wear_min": wear_min, &"wear_max": wear_max,
		&"mat_boxes": mat_boxes,
		&"zone_count": -1, &"worker_count": -1, &"zones": [],
	}


func _update_stockpile() -> void:
	var voxel := overseer._selected
	var live := voxel != Vector3i.MAX and colony.is_stockpile(voxel)
	_stockpile_panel.visible = live
	if not live:
		return
	var shelf := colony.shelf_at(voxel) != null
	var bin := colony.compost_bin_at(voxel) != null
	_stockpile_title.text = (
		"Shelf" if shelf else "Compost bin" if bin else "Stockpile"
	)
	var zone := colony.stockpile_at(voxel)
	_stockpile_detail.text = "%d cells — %.2f / %.2f m³ piled" % [
		zone.cells.size() if zone != null else 0,
		colony.voxel_fill(voxel) / float(DropItem.CM3_PER_M3),
		colony.voxel_capacity(voxel) / float(DropItem.CM3_PER_M3),
	]
	for box in _stockpile_checks:
		box.set_pressed_no_signal(
			colony.stockpile_admits(voxel, box.get_meta(&"material"))
		)
	if zone != null:
		_stockpile_priority.select(int(zone.priority))
	if _preset_count != FilterPresets.names().size():
		var saved := FilterPresets.names()
		_preset_count = saved.size()
		_preset_picker.clear()
		for preset_name in saved:
			_preset_picker.add_item(preset_name)


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
	_farm_auto_fertilize.set_pressed_no_signal(field.auto_fertilize)
	_farm_fert_slider.set_value_no_signal(field.fertilize_target)
	_farm_fert_label.text = "Fertility ≥ %.1f" % field.fertilize_target


## The bottom bar: Architect and Menu are live; the other tabs are stubs
## for systems that don't exist yet. Right side holds the display toggles
## and the time controls.
func _build_menu_bar(parent: Control) -> void:
	_menu_bar = PanelContainer.new()
	var bar := _menu_bar
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	bar.add_child(row)
	parent.add_child(bar)

	_architect_button = _hud_button()
	_architect_button.text = "Architect"
	_architect_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_architect_button.pressed.connect(_on_architect_pressed)
	row.add_child(_architect_button)
	for tab in MENU_TABS:
		var button := _hud_button()
		button.text = tab
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if tab == "Assign":
			# The allowed-area manager lives here — assignments ride
			# the unit and animal panels.
			_assign_button = button
			button.pressed.connect(
				func() -> void:
					_areas_panel.visible = not _areas_panel.visible
			)
		elif tab == "Work":
			# The job board lives here — work priorities join it when
			# they land.
			button.pressed.connect(
				func() -> void:
					_jobs_panel.visible = not _jobs_panel.visible
			)
		elif tab == "Animals":
			# The livestock roster — wild marks, tamed herds and what
			# each is up to, with the tame button on the wild rows.
			button.pressed.connect(
				func() -> void:
					_animals_panel.visible = not _animals_panel.visible
			)
		elif tab == "Research":
			# No tech tree — the model lives in people, so the tab is a
			# roster × skills-and-knowledge grid.
			button.pressed.connect(
				func() -> void:
					_research_panel.visible = not _research_panel.visible
			)
		elif tab == "World":
			# The meso map, the region cache's site list, and the
			# travel/party controls (item 65).
			button.pressed.connect(
				func() -> void:
					_world_panel.visible = not _world_panel.visible
					if _world_panel.visible:
						_refresh_world_panel()
			)
		else:
			button.disabled = true
		row.add_child(button)
	_menu_button = _hud_button()
	_menu_button.text = "Menu"
	_menu_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_button.pressed.connect(_on_menu_pressed)
	row.add_child(_menu_button)


## The right-edge column above the bar (PLAN item 64 shell): from the
## bottom up, the display toggles, then the speed controls, the
## calendar line, and the weather readout; notifications stack on top
## once anything produces them.
func _build_right_column(parent: Control, clear: int) -> void:
	_right_col = VBoxContainer.new()
	_right_col.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# Content wider than the strip — a long date line, the full speed
	# row — must push the column's left edge inward, never the right
	# edge off the window.
	_right_col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_right_col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right_col.offset_left = -176
	_right_col.offset_right = -8
	_right_col.offset_top = -400
	_right_col.offset_bottom = -clear - 6
	_right_col.add_theme_constant_override("separation", 6)
	var col := _right_col
	parent.add_child(col)

	# Everything in the column shrinks to its own width against the
	# right edge — an over-wide child (a long date line, the full
	# speed row) overflows LEFT into the world view instead of off
	# the window's right edge.
	_alerts_col = VBoxContainer.new()
	_alerts_col.size_flags_horizontal = Control.SIZE_SHRINK_END
	col.add_child(_alerts_col)

	_weather_label = Label.new()
	_weather_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_weather_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_weather_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	col.add_child(_weather_label)

	_date_label = Label.new()
	_date_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_date_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_date_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	col.add_child(_date_label)

	var speeds := HBoxContainer.new()
	speeds.alignment = BoxContainer.ALIGNMENT_END
	speeds.size_flags_horizontal = Control.SIZE_SHRINK_END
	speeds.add_theme_constant_override("separation", 2)
	col.add_child(speeds)
	var speed_group := ButtonGroup.new()
	for speed in SPEEDS:
		var button := _hud_button()
		button.text = String(speed["label"])
		button.toggle_mode = true
		button.button_group = speed_group
		button.button_pressed = speed["scale"] == 1.0
		button.pressed.connect(_set_speed.bind(float(speed["scale"])))
		_speed_buttons.append(button)
		speeds.add_child(button)
	# Timberborn's "tick once": pause and advance a single step.
	var tick := _hud_button()
	tick.text = ">|"
	tick.tooltip_text = "Pause and advance one tick"
	tick.pressed.connect(overseer.tick_once)
	speeds.add_child(tick)
	# RimWorld's fast-forward: while armed, the clock runs at the top
	# speed whenever every unit at the site is asleep.
	_sleep_boost_button = _hud_button()
	_sleep_boost_button.text = "Zz"
	_sleep_boost_button.toggle_mode = true
	_sleep_boost_button.tooltip_text = (
		"Fast-forward while every settler is asleep"
	)
	_sleep_boost_button.toggled.connect(colony.set_sleep_boost)
	speeds.add_child(_sleep_boost_button)

	for toggle in TOGGLES:
		var button := _hud_button()
		button.text = String(toggle["label"])
		if not toggle["live"]:
			button.disabled = true
			col.add_child(button)
			continue
		button.toggle_mode = true
		button.button_pressed = toggle.get("default", true)
		button.toggled.connect(_on_display_toggle.bind(button.text))
		col.add_child(button)


## Popups: the action menu is the Architect menu — categories as
## submenus — and the Menu button gets Save/Load/Options stubs plus Quit.
func _build_menus() -> void:
	action_menu.clear()
	for category in ARCHITECT_MENU:
		var submenu := PopupMenu.new()
		submenu.name = String(category["label"])
		for item: Dictionary in category["items"]:
			if item.has("variants"):
				# A nested submenu carries per-material picks — "Stone
				# wall ▸ Granite" arms the action pinned to that rock,
				# "Any" arms it unpinned (the class wildcard).
				var varsub := PopupMenu.new()
				varsub.name = "variants_%s" % String(item["action"])
				varsub.add_item(
					"Any %s" % String(item["variants"]),
					int(BlockRegistry.Resource_.NONE)
				)
				for material: int in _variant_materials(item["variants"]):
					varsub.add_item(
						BlockRegistry.resource_name_of(material), material
					)
				var action_index := overseer.ACTIONS.find(item["action"])
				varsub.id_pressed.connect(
					func(material: int) -> void:
						overseer.select_action_pinned(action_index, material)
						action_menu.hide()
				)
				submenu.add_child(varsub)
				submenu.add_submenu_item(
					overseer.ACTION_NAMES[item["action"]], varsub.name
				)
			elif item.has("action"):
				var action_index := overseer.ACTIONS.find(item["action"])
				submenu.add_item(overseer.ACTION_NAMES[item["action"]], action_index)
			else:
				submenu.add_item("%s (not implemented)" % item["stub"], -1)
				submenu.set_item_disabled(submenu.item_count - 1, true)
		submenu.id_pressed.connect(_on_architect_item)
		action_menu.add_child(submenu)
		action_menu.add_submenu_item(String(category["label"]), submenu.name)

	_menu_popup = PopupMenu.new()
	_menu_popup.add_item("Save / Load…", 0)
	_menu_popup.add_item("Options", 2)
	_menu_popup.add_separator()
	_menu_popup.add_item("Quit to title", 3)
	_menu_popup.add_item("Quit", 4)
	_menu_popup.id_pressed.connect(
		func(id: int) -> void:
			match id:
				0:
					_open_saves_panel()
				2:
					_options_panel.visible = not _options_panel.visible
				3:
					get_tree().change_scene_to_file(
						"res://scenes/worldgen.tscn"
					)
				4:
					get_tree().quit()
	)
	add_child(_menu_popup)


func _on_architect_pressed() -> void:
	action_menu.popup()


func _on_menu_pressed() -> void:
	_menu_popup.popup()


## The Menu → Options panel (PLAN item 63): a centered card with the
## GameOptions knobs — master volume (the bus exists even while no
## sounds ship yet), the autosave cadence, and the perf readout
## toggle. Every change applies live and persists to options.cfg.
func _build_options_panel(parent: Control) -> void:
	_options_panel = PanelContainer.new()
	_options_panel.set_anchors_preset(Control.PRESET_CENTER)
	_options_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_options_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_options_panel.custom_minimum_size = Vector2(360, 0)
	_options_panel.visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_options_panel.add_child(box)
	var title := Label.new()
	title.text = "Options"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	var vol_row := HBoxContainer.new()
	box.add_child(vol_row)
	var vol_label := Label.new()
	vol_label.text = "Master volume"
	vol_label.custom_minimum_size.x = 110
	vol_row.add_child(vol_label)
	var vol_slider := HSlider.new()
	vol_slider.min_value = 0.0
	vol_slider.max_value = 100.0
	vol_slider.step = 1.0
	# -60 dB is the practical mute floor — a straight linear_to_db read
	# would throw -inf at zero.
	vol_slider.value = (
		100.0 * db_to_linear(GameOptions.volume_db) if GameOptions.volume_db > -60.0
		else 0.0
	)
	vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol_slider.focus_mode = Control.FOCUS_NONE
	vol_row.add_child(vol_slider)
	var vol_value := Label.new()
	vol_value.custom_minimum_size.x = 48
	vol_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vol_value.text = "%d%%" % int(vol_slider.value)
	vol_row.add_child(vol_value)
	vol_slider.value_changed.connect(
		func(v: float) -> void:
			vol_value.text = "%d%%" % int(v)
			GameOptions.volume_db = (
				linear_to_db(v / 100.0) if v > 0.0 else -60.0
			)
			GameOptions.apply_volume()
			GameOptions.save_file()
	)

	var auto_row := HBoxContainer.new()
	box.add_child(auto_row)
	var auto_label := Label.new()
	auto_label.text = "Autosave"
	auto_label.custom_minimum_size.x = 110
	auto_row.add_child(auto_label)
	var auto_pick := OptionButton.new()
	auto_pick.focus_mode = Control.FOCUS_NONE
	auto_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for choice in GameOptions.autosave_choices:
		auto_pick.add_item(choice["label"])
		auto_pick.set_item_metadata(
			auto_pick.item_count - 1, choice["minutes"]
		)
		if choice["minutes"] == GameOptions.autosave_minutes:
			auto_pick.select(auto_pick.item_count - 1)
	auto_row.add_child(auto_pick)
	auto_pick.item_selected.connect(
		func(idx: int) -> void:
			GameOptions.autosave_minutes = auto_pick.get_item_metadata(idx)
			GameOptions.save_file()
	)

	var perf_check := CheckBox.new()
	perf_check.text = "Perf readout on the inspect pane"
	perf_check.focus_mode = Control.FOCUS_NONE
	perf_check.button_pressed = GameOptions.perf_overlay
	box.add_child(perf_check)
	perf_check.toggled.connect(
		func(on: bool) -> void:
			GameOptions.perf_overlay = on
			_perf_label.visible = on
			GameOptions.save_file()
	)

	var hint := Label.new()
	hint.text = "Keybinds will live here."
	hint.add_theme_font_size_override("font_size", 12)
	box.add_child(hint)
	var close := _hud_button()
	close.text = "Close"
	close.pressed.connect(func() -> void: _options_panel.hide())
	box.add_child(close)
	parent.add_child(_options_panel)


## The Menu → Save/Load card: the same slot list the title screen
## reads, plus a name field so a manual save can write — or overwrite
## — any slot instead of always landing on the default.
func _build_saves_panel(parent: Control) -> void:
	_saves_panel = PanelContainer.new()
	_saves_panel.set_anchors_preset(Control.PRESET_CENTER)
	_saves_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_saves_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_saves_panel.custom_minimum_size = Vector2(380, 0)
	_saves_panel.visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_saves_panel.add_child(box)
	var title := Label.new()
	title.text = "Saved games"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 6)
	box.add_child(save_row)
	_save_name = LineEdit.new()
	_save_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_name.placeholder_text = "Save name"
	_save_name.text = Main.DEFAULT_SLOT
	save_row.add_child(_save_name)
	var save_button := _hud_button()
	save_button.text = "Save"
	save_button.tooltip_text = (
		"Write the colony into the named slot"
		+ " — an existing name overwrites it"
	)
	save_button.pressed.connect(
		func() -> void:
			var slot := _save_name.text.strip_edges().validate_filename()
			if slot.is_empty():
				slot = Main.DEFAULT_SLOT
			(get_parent() as Main).save_game(slot)
			_save_name.text = slot
			_refresh_save_list()
	)
	save_row.add_child(save_button)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 180)
	box.add_child(scroll)
	_save_list = VBoxContainer.new()
	_save_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_save_list)

	var close := _hud_button()
	close.text = "Close"
	close.pressed.connect(func() -> void: _saves_panel.hide())
	box.add_child(close)
	parent.add_child(_saves_panel)


func _open_saves_panel() -> void:
	_refresh_save_list()
	_saves_panel.visible = true
	_save_name.grab_focus()
	_save_name.caret_column = _save_name.text.length()


## Rebuilds the slot rows — newest first, like the title's list.
## Clicking a slot loads it; the autosave slot is fair game.
func _refresh_save_list() -> void:
	for child in _save_list.get_children():
		child.queue_free()
	var slots := Main.save_slots()
	if slots.is_empty():
		var none := Label.new()
		none.text = "No saved colonies"
		none.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		_save_list.add_child(none)
		return
	for slot in slots:
		var row := Button.new()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.text = "%s  —  %s" % [
			slot["name"],
			Time.get_datetime_string_from_unix_time(
				slot["mtime"], true
			).replace("T", " "),
		]
		row.tooltip_text = "Load %s" % slot["name"]
		var slot_name: String = slot["name"]
		row.pressed.connect(
			func() -> void:
				(get_parent() as Main).load_game(slot_name)
		)
		_save_list.add_child(row)


## The material options a `"variants"` menu tag expands to — rock kinds
## for stone-class specs; the generic class itself is the "Any" entry
## and stays off the list.
func _variant_materials(variant: StringName) -> Array[int]:
	var list: Array[int] = []
	if variant == &"rock":
		for material in BlockRegistry.ROCK_MATERIALS:
			if material != BlockRegistry.Resource_.STONE:
				list.append(int(material))
	return list


func _on_architect_item(id: int) -> void:
	if id >= 0:
		overseer.select_action(id)
	action_menu.hide()


func _on_display_toggle(pressed_on: bool, label: String) -> void:
	match label:
		"Zones":
			colony.set_markers_visible(pressed_on)
		"Home area":
			colony.set_home_visible(pressed_on)
		"Plans":
			colony.set_plans_visible_manual(pressed_on)
		"Flow":
			var main := get_parent() as Main
			if main != null and main.flow_view != null:
				main.flow_view.set_enabled(pressed_on)
		"Settler bar":
			_settler_bar.visible = pressed_on
		"Beauty":
			colony.set_beauty_overlay(pressed_on)
		"Roofs":
			colony.set_roofs_overlay(pressed_on)


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
		var species: StringName = entry.get("species", &"")
		var material_name := (
			String(species).capitalize()
			if species != &""
			else BlockRegistry.resource_name_of(entry["material"])
		)
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
	if overseer._sliced():
		text += "Slice view: cut above y%d — [PgDn] lower · [PgUp] raise/exit\n" % (
			overseer.slice_view.top_layer
		)
	var critter := overseer.targeted_critter()
	if critter != null and is_instance_valid(critter):
		# Whoever's under the cursor — name and activity before the
		# terrain readout; animals name themselves by species.
		var critter_name: String = (
			critter.name if critter is Unit else critter.label()
		)
		text += "%s — %s\n" % [critter_name, critter.current_activity()]
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
		# A wall's building record carries its typed rock — "granite
		# wall", not the voxel's generic block name.
		var block_label := (
			building.label()
			if building != null and building.kind == Building.Kind.WALL
			else BlockRegistry.block_name(block_id)
		)
		text += "%s %s" % [block_label, str(hit.position)]
		var decor := _decoration_label(hit)
		if decor != "":
			text += "  %s" % decor
		if pile != null:
			text += "  pile %.2f m³: %s" % [
				_pile_fill_display(pile), _pile_contents_text(pile)
			]
			# Forbidden goods can't be claimed — the flag reads on the
			# hover so a fetch that ignores the pile doesn't look empty.
			if colony.pile_all_forbidden(hit.previous_position):
				text += " — all forbidden"
			elif colony.pile_any_forbidden(hit.previous_position):
				text += " — partly forbidden"
			# Weathering reads on the hover — an exposed pile holding
			# anything the elements touch says so (and says it faster
			# while rain is doing the work).
			if colony.sees_sky(hit.previous_position):
				for item in pile.items:
					if not DropItem.weather_rule(item).is_empty():
						text += (
							" — weathering"
							+ (
								" ×%d in rain"
								% roundi(colony.WEATHER_RAIN_MULT)
								if colony.weather.precipitating()
								else ""
							)
						)
						break
		if colony.is_stockpile(hit.previous_position):
			text += "  stockpile"
		elif building != null:
			if building.kind != Building.Kind.WALL:
				text += "  %s" % building.label()
			if building.hp < building.max_hp:
				text += " (integrity %d%%)" % int(building.integrity() * 100.0)
		# The air at the cursor: a room's uniform temperature indoors,
		# the weather's ambient out.
		var air := (
			hit.previous_position
			if colony.world.get_block(hit.previous_position)
				== BlockRegistry.Block.AIR
			else hit.position
		)
		text += "  %d°C" % roundi(colony.temperature_at(air))
		var water_depth := _water_depth_at(hit.position.x, hit.position.z)
		if water_depth > 0.0:
			text += "  water %.2f m" % water_depth
		# An indoor cell names its room — the use the contents make of
		# it and the tier the stat block grades ("decent bedroom").
		var room_use := colony.room_use_at(air)
		if room_use != &"":
			text += "  %s %s" % [
				String(colony.room_tier_at(air)).capitalize(),
				String(room_use).replace("_", " "),
			]
	text += "\nUnits: %d   Jobs queued: %d" % [colony.units.size(), colony.open_job_count()]
	_inspect_label.text = text


## The calendar readout — the site's local date and clock, the season
## and sky with the air temperature, and a night marker so the dimmed
## screen reads as evening rather than a bug.
func _update_date() -> void:
	if day_cycle == null:
		return
	_date_label.text = day_cycle.clock_text() + (
		"" if day_cycle.is_daylight() else "  ·night"
	) + (
		"  ·%s" % colony.weather.season_name(day_cycle)
		if colony != null
		else ""
	)
	if colony != null:
		_weather_label.text = "%s, %d°C" % [
			colony.weather.label(),
			roundi(colony.weather.temperature_c(day_cycle)),
		]


## What decoration the aimed cell holds: bushes and leaf/sapling cells
## are AIR voxels the terrain raycast passes through, so check the cell
## in front of the hit face as well as the hit itself (a trunk block is
## solid). Falls back to grass cover — it matters for grazing.
func _decoration_label(hit: Overseer.AimHit) -> String:
	for cell in [hit.previous_position, hit.position]:
		var bush_root := colony.plants.bush_at(cell)
		if bush_root != Vector3i.MAX:
			var rec: Dictionary = colony.plants.bushes[bush_root]
			var sp: Dictionary = Plants.species_table().get(rec[&"species"], {})
			return String(sp.get(&"name", rec[&"species"])) + (
				" (ripe)" if rec[&"ripe"] else ""
			)
		var tree_root := colony.forest.tree_root_at(cell)
		if tree_root != Vector3i.MAX:
			var rec: Dictionary = colony.forest.trees[tree_root]
			var sp: Dictionary = Forest.species_table().get(rec[&"species"], {})
			return String(sp.get(&"name", rec[&"species"])) + (
				" sapling" if int(rec[&"height"]) <= 0 else ""
			)
	if colony.grass.coverage_at(hit.previous_position) > 0.0:
		return "grass"
	return ""


func _pile_fill_display(pile: ItemPile) -> float:
	return float(pile.total_volume()) / DropItem.CM3_PER_M3


## One-line digest of a pile's contents for the cursor readout —
## "stone boulder ×5, loose soil 0.31 m³", biggest share first. Same
## naming as the resources list: species names stand in for tagged
## items (an oak seed packet), loose forms show volume not count.
func _pile_contents_text(pile: ItemPile) -> String:
	var groups := {}
	for item in pile.items:
		var key := "%d:%d:%s:%s:%s" % [
			int(item.material), int(item.form), String(item.species),
			DropItem.quality_tier(item.quality), String(item.made_by),
		]
		var base_name := (
			String(item.species).capitalize()
			if item.species != &""
			else BlockRegistry.resource_name_of(item.material)
		)
		if item.quality != 1.0:
			base_name = "%s %s" % [
				DropItem.quality_tier(item.quality), base_name.to_lower()
			]
		if item.made_by != &"":
			base_name = "%s by %s" % [base_name, item.made_by]
		var g: Dictionary = groups.get_or_add(key, {
			&"name": base_name,
			&"form": item.form,
			&"count": 0,
			&"cm3": 0,
		})
		g[&"count"] += 1
		g[&"cm3"] += item.volume
	var sorted: Array = groups.values()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a[&"cm3"]) > int(b[&"cm3"]))
	var parts := PackedStringArray()
	for g in sorted:
		if g[&"form"] == DropItem.Form.LOOSE:
			parts.append(
				"%s %.2f m³"
				% [g[&"name"], float(g[&"cm3"]) / DropItem.CM3_PER_M3]
			)
		elif g[&"form"] in [DropItem.Form.FRUIT, DropItem.Form.MEAL]:
			parts.append("%s ×%d" % [g[&"name"], g[&"count"]])
		elif g[&"form"] == DropItem.Form.SEED:
			parts.append("%s seed ×%d" % [g[&"name"], g[&"count"]])
		else:
			parts.append(
				"%s %s ×%d"
				% [g[&"name"], DropItem.form_name(g[&"form"]), g[&"count"]]
			)
		if parts.size() >= 6:
			parts.append("…")
			break
	return ", ".join(parts)


func _update_perf(delta: float) -> void:
	var ms := delta * 1000.0
	_perf_worst_ms = maxf(_perf_worst_ms, ms)
	_perf_window_left -= delta
	if _perf_window_left <= 0.0:
		_perf_shown_worst_ms = _perf_worst_ms
		_perf_worst_ms = 0.0
		_perf_window_left = PERF_WINDOW
	var beauty := ""
	if colony != null:
		beauty = "  beauty: %d rays %d cells/s" % [
			int(colony.beauty_rays_per_sec),
			int(colony.beauty_cells_per_sec),
		]
	var top := Perf.top_text()
	if not top.is_empty():
		top = "  top: " + top
	_perf_label.text = (
		"Frame: %.1f ms  worst(2s): %.1f ms  physics: %.1f ms  nodes: %d%s%s"
		% [
			ms,
			_perf_shown_worst_ms,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			beauty,
			top,
		]
	)
