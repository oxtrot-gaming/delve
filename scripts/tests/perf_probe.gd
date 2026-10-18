extends SceneTree

## Perf probe: boots the default save, lets the colony settle, then
## pans the viewer across the site to trigger block streaming and
## prints each window's worst frame with its top instrumented
## sections — names which system owns the hitches.
##
##     godot --path . --script res://scripts/tests/perf_probe.gd
## (headless is fine — the accounting is all script-side)

func _initialize() -> void:
	_run()


func _run() -> void:
	Main.pending_load = "user://saves/default"
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main._units_spawned:
		await process_frame
	paused = false
	for i in 60:
		await process_frame
	var overseer: Overseer = main.get_node("Overseer")
	var hud: CanvasLayer = main.get_node("Hud")
	var home: Vector3 = overseer.global_position

	print("=== baseline 10s ===")
	await _sample(hud, 10)

	print("=== pan sweep ===")
	for step in range(10):
		overseer.global_position = (
			home + Vector3((step - 5) * 24.0, 0.0, step * 10.0)
		)
		for i in 12:
			await process_frame
	overseer.global_position = home
	for i in 30:
		await process_frame

	print("=== settle 10s ===")
	await _sample(hud, 10)
	quit(0)


## Prints the real worst-frame ms (the HUD's number) plus the worst
## instrumented frame's accounted ms and its top sections, once per
## Perf window.
func _sample(hud: CanvasLayer, seconds: int) -> void:
	var windows := int(seconds / Perf.WINDOW_SEC)
	for w in windows:
		for i in int(Perf.WINDOW_SEC * 60.0):
			await process_frame
		print(
			(
				"  worst %.1f ms | accounted %.1f ms | top: %s"
				% [hud._perf_shown_worst_ms, Perf.worst_ms, Perf.top_text()]
			)
		)
