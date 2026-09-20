class_name Hud
extends CanvasLayer

## Debug-grade readout of colony state. Enough to see the simulation working.

@export var colony_path: NodePath = NodePath("../Colony")
@export var overseer_path: NodePath = NodePath("../Overseer")

@onready var stockpile_label: Label = $Panel/VBox/Stockpile
@onready var units_label: Label = $Panel/VBox/Units
@onready var target_label: Label = $Panel/VBox/Target
@onready var action_menu: PopupMenu = $ActionMenu

var colony: Colony
var overseer: Overseer


func _ready() -> void:
	colony = get_node(colony_path)
	overseer = get_node(overseer_path)
	overseer.action_menu_requested.connect(_show_action_menu)
	overseer.action_menu_dismissed.connect(action_menu.hide)
	action_menu.id_pressed.connect(_on_action_menu_id)
	action_menu.popup_hide.connect(overseer.menu_closed)


func _process(_delta: float) -> void:
	stockpile_label.text = "Stockpile: %s    Jobs queued: %d" % [_stockpile_text(), colony.open_job_count()]
	units_label.text = "Units (%d): %s" % [colony.units.size(), _units_text()]
	target_label.text = _target_text()


func _stockpile_text() -> String:
	if colony.stockpile.is_empty():
		return "empty"
	var parts: PackedStringArray = PackedStringArray()
	for resource in colony.stockpile:
		parts.append("%s %d" % [BlockRegistry.resource_name_of(resource), colony.stockpile[resource]])
	return ", ".join(parts)


func _units_text() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for unit in colony.units:
		parts.append("%s %s" % [unit.name, unit.current_activity()])
	return " | ".join(parts)


## The action picker: pops at screen centre with the current action checked.
func _show_action_menu() -> void:
	action_menu.clear()
	for i in overseer.action_count():
		action_menu.add_check_item(overseer.action_label(i), i)
		action_menu.set_item_checked(i, overseer.ACTIONS[i] == overseer.current_action())
	var centre := Vector2i(get_viewport().get_visible_rect().size) / 2
	action_menu.popup(Rect2i(centre - Vector2i(60, 40), Vector2i(120, 80)))


func _on_action_menu_id(id: int) -> void:
	overseer.select_action(id)
	action_menu.hide()


func _target_text() -> String:
	var hints := (
		"    [LMB] %s  [E] action (hold: list)  [RMB] cancel  [Esc] free cursor"
		% overseer.current_action_label()
	)
	var hit := overseer.targeted_voxel()
	if hit == null:
		return "Looking at: nothing" + hints
	var block_id := colony.world.get_block(hit.position)
	var pile := colony.item_pile_at(hit.previous_position)
	var pile_text := "" if pile == null else "  pile %.2f m³" % pile.total_volume()
	return (
		"Looking at: %s %s%s%s"
		% [BlockRegistry.block_name(block_id), str(hit.position), pile_text, hints]
	)
