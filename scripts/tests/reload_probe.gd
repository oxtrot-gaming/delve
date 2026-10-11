extends SceneTree

## Double-load repro: boots from the user's save, then calls
## load_game() again and watches the second _ready for a stall —
## reports the stage text every second so the hang point shows.

func _initialize() -> void:
	_run()


func _run() -> void:
	var slot := "user://saves/default"
	Main.pending_load = slot
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	# reload_current_scene needs current_scene set — the worldgen
	# screen normally owns that; the probe stands in for it.
	current_scene = main
	var frames := 0
	while not main._units_spawned and frames < 7200:
		frames += 1
		await process_frame
		if frames % 300 == 0:
			print("boot1 %ds stage=%s" % [frames / 60, main._stage_text])
	print("boot1 done: spawned=%s frames=%d" % [main._units_spawned, frames])
	for i in 60:
		await process_frame
	print("calling load_game")
	main.load_game()
	# After reload the old reference is freed — find the new main.
	for i in 5:
		await process_frame
	main = current_scene
	print("new main: %s" % main)
	var last := ""
	for i in 300:
		await process_frame
		if i % 60 == 0 or main._stage_text != last:
			last = main._stage_text
			var viewer: VoxelViewer = main.world_viewer
			var stats: Dictionary = main.world.get_statistics()
			var sy: int = main.world.predicted_surface_height(
				main.colony_site.x, main.colony_site.z)
			var sv := Vector3i(
				main.colony_site.x, sy, main.colony_site.z)
			var box := AABB(Vector3(sv) - Vector3.ONE * 16.0,
				Vector3.ONE * 32.0)
			print(("boot2 %ds stage=%s booting=%s meshed=%s "
				+ "viewer_pos=%s vd=%s rv=%s editable=%s stats=%s") % [
				i / 60, last, main._booting,
				main.world.is_area_meshed(box),
				viewer.global_position, viewer.view_distance,
				viewer.requires_visuals,
				main.world.is_editable(sv), stats])
		if main._units_spawned:
			print("boot2 done at %ds" % (i / 60))
			break
	quit(0)
