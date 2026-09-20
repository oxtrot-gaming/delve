class_name Hud
extends CanvasLayer

## Debug-grade readout of colony state. Enough to see the simulation working.

@export var colony_path: NodePath = NodePath("../Colony")
@export var overseer_path: NodePath = NodePath("../Overseer")

@onready var stockpile_label: Label = $Panel/VBox/Stockpile
@onready var units_label: Label = $Panel/VBox/Units
@onready var target_label: Label = $Panel/VBox/Target

var colony: Colony
var overseer: Overseer


func _ready() -> void:
	colony = get_node(colony_path)
	overseer = get_node(overseer_path)


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


func _target_text() -> String:
	var hit := overseer.targeted_voxel()
	if hit == null:
		return "Looking at: nothing    [LMB] designate  [RMB] cancel  [C] spawn unit  [Esc] free cursor"
	var block_id := colony.world.get_block(hit.position)
	return (
		"Looking at: %s %s    [LMB] designate  [RMB] cancel  [C] spawn unit  [Esc] free cursor"
		% [BlockRegistry.block_name(block_id), str(hit.position)]
	)
