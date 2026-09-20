extends Control

## Screen-centre crosshair — the overseer's aim point for designations.

const HALF := 8.0
const GAP := 2.0
const COLOR := Color(1.0, 1.0, 1.0, 0.8)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _draw() -> void:
	var c := size * 0.5
	draw_line(c + Vector2(-HALF, 0.0), c + Vector2(-GAP, 0.0), COLOR, 1.5)
	draw_line(c + Vector2(GAP, 0.0), c + Vector2(HALF, 0.0), COLOR, 1.5)
	draw_line(c + Vector2(0.0, -HALF), c + Vector2(0.0, -GAP), COLOR, 1.5)
	draw_line(c + Vector2(0.0, GAP), c + Vector2(0.0, HALF), COLOR, 1.5)
