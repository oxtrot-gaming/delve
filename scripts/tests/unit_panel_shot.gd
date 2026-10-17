extends SceneTree

## Unit-panel probe: boots the default save, opens the settler panel
## on whichever unit is furthest into mood therapy (the needs row and
## the "mood therapy" tag both show at their longest there), and shoots.
##
##     godot --path . --script res://scripts/tests/unit_panel_shot.gd
## (windowed — the screenshot needs a real viewport)

func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_load = "user://saves/default"
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	for i in 60:
		await process_frame
	# The bug report was at ~1024px — shoot at the narrow width.
	root.get_window().size = Vector2i(1024, 640)
	for i in 3:
		await process_frame
	var colony: Colony = main.colony
	var hud: CanvasLayer = main.get_node("Hud")

	# Prefer a unit mid-therapy so the tag renders; fall back to the
	# lowest mood if nobody's latched right now.
	var pick: Unit = null
	for u in colony.units:
		if u._decompressing:
			pick = u
			break
	if pick == null:
		for u in colony.units:
			if pick == null or u.mood < pick.mood:
				pick = u
	hud._inspected_unit = pick
	print(
		"inspecting %s — rec=%.2f mood=%.2f therapy=%s" % [
			pick.name, pick.recreation, pick.mood, pick._decompressing,
		]
	)
	# The Skills tab is the one that made the card too tall — shoot it
	# too so the scrollable list is on record.
	for i in 10:
		await process_frame
	print(
		"right col rect=%s win=%s" % [
			hud._right_col.get_global_rect(),
			root.get_viewport().get_visible_rect().size,
		]
	)
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://unit_panel.png")
	print("saved unit_panel.png")
	hud._unit_tab_buttons[1].button_pressed = true
	for i in 10:
		await process_frame
	img = root.get_viewport().get_texture().get_image()
	img.save_png("user://unit_panel_skills.png")
	print("saved unit_panel_skills.png")
	print(
		"panel=%s scroll=%s page=%s win=%s" % [
			hud._unit_panel.size,
			hud._unit_scroll.size,
			hud._unit_tab_pages[1].size,
			root.get_viewport().get_visible_rect().size,
		]
	)
	quit(0)
