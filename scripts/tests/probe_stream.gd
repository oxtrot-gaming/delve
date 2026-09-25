extends SceneTree


func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var world: VoxelWorld = main.get_node("VoxelWorld")
	if OS.get_cmdline_user_args().has("--script-gen"):
		var sg := WorldGenerator.new()
		sg.world_seed = world.world_seed
		world.generator = sg
	print("generator class: ", world.generator.get_class(), " / ", world.generator.get("world_seed"))

	var site := Vector3i(0, world.predicted_surface_height(0, 0), 0)
	var area := AABB(Vector3(site) - Vector3.ONE * 16.0, Vector3.ONE * 32.0)

	for i in range(60):  # ~10s at idle headless tick
		await physics_frame
		if i % 10 == 0:
			var calls := -1
			if ClassDB.class_exists(&"DelveGenerator"):
				calls = ClassDB.class_call_static(&"DelveGenerator", &"debug_gen_calls")
			print("t+%d  meshed=%s  block@site=%d  gen_calls=%d  stats=%s" % [
				i,
				world.is_area_meshed(area),
				world.get_block(site),
				calls,
				str(world.get_statistics()) if world.has_method("get_statistics") else "n/a"
			])
		if world.is_area_meshed(area):
			break
	print("final block at site: ", world.get_block(site))
	quit()
