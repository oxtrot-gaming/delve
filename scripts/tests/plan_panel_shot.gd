extends SceneTree

## Blueprint-card probe: boots the default save, designates a stone
## wall on open ground, aims at the plan cell, clicks, and shoots the
## card the HUD opens.
##
##     godot --path . --script res://scripts/tests/plan_panel_shot.gd
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
	var colony: Colony = main.colony
	var overseer: Overseer = main.get_node("Overseer")
	var hud: CanvasLayer = main.get_node("Hud")

	# An open-air cell near the first unit, over solid ground.
	var spot := Vector3i.MAX
	var anchor := Vector3i(colony.units[0].global_position.floor())
	for dx in 8:
		for dz in 8:
			var v := anchor + Vector3i(dx, 0, dz)
			while colony.world.get_block(v) == BlockRegistry.Block.AIR:
				v.y -= 1
			v.y += 1
			if (
				colony.world.get_block(v) == BlockRegistry.Block.AIR
				and colony.designate_build(v, &"stone_wall") != null
			):
				spot = v
				break
		if spot != Vector3i.MAX:
			break
	assert(spot != Vector3i.MAX, "no open spot for the wall plan")

	# Aim at the plan cell and click — the card should open.
	overseer.global_position = Vector3(spot) + Vector3(0.5, 0.0, 0.5)
	overseer._distance = 12.0
	overseer.select_action(-1)
	for i in 3:
		await process_frame
	var hit_pos := overseer.camera.unproject_position(
		Vector3(spot) + Vector3.ONE * 0.5
	)
	Input.warp_mouse(hit_pos)
	await process_frame
	overseer._update_target()
	# Repeated clicks on the same spot rotate through every inspectable
	# there — keep clicking until the plan comes up.
	for i in 6:
		overseer._select_at_cursor()
		if overseer._inspected_plan != null:
			break
	for i in 10:
		await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("user://plan_panel.png")
	print(
		"saved plan_panel.png — plan visible: %s, picked: %s" % [
			hud._plan_panel.visible, overseer._inspected_plan
		]
	)
	# Press the card's Cancel action — the order should die and the
	# card should close behind it.
	var cancel: Button = null
	for child in hud._inspect_actions.get_children():
		if child is Button and child.text == "Cancel":
			cancel = child
	assert(cancel != null, "no Cancel action on the plan card")
	cancel.pressed.emit()
	for i in 10:
		await process_frame
	assert(
		colony.plan_job_at(spot) == null,
		"Cancel did not remove the build order"
	)
	assert(
		not hud._plan_panel.visible,
		"plan card stayed open after its order was cancelled"
	)
	print("cancel removed the order and closed the card")
	quit(0)
