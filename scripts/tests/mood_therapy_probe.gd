extends SceneTree

## Exercises the mood-therapy latch state machine directly: arm,
## fun-full release + spent, refill-line re-arm while mood stays
## critical (gated on real headroom), boredom-floor release when it
## isn't, mood-margin release, and the thought-ceiling release that
## ends therapy once mood reaches all it can reach.
##
##     godot --headless --path . --script res://scripts/tests/mood_therapy_probe.gd

var checks := 0
var fails := 0


func check(cond: bool, label: String) -> void:
	checks += 1
	if cond:
		print("  PASS  " + label)
	else:
		fails += 1
		print("  FAIL  " + label)


## Put the unit back to a neutral IDLE footing between assertions —
## needs full so no eat/rest branch preempts the mood block, cooldown
## cleared so every _tick_idle call evaluates, and thoughts stripped
## so mood_target() is a bare baseline the test then pins itself.
func _reset(u: Unit) -> void:
	if u.job != null and u.job.type == ColonyJob.Type.RECREATE:
		u._end_recreation("probe reset")
	u.job = null
	u.state = Unit.State.IDLE
	u._release_recreation()
	u.drafted = false
	u.relieved = false
	u._combat_target = null
	u._in_break = false
	u.hunger = 1.0
	u.energy = 1.0
	u.recreation = 1.0
	u._thoughts.clear()
	u._decompressing = false
	u._decompress_spent = false
	# Surroundings samples too — a dark cell or a small room would
	# otherwise light a state thought under the baseline math.
	u.beauty = 0.0
	u.light_level = 1.0
	u._light_cell = u._standing_voxel()
	u.room_cells = 0


func _tick(u: Unit) -> void:
	u._job_search_cooldown = 0.0
	u._tick_idle()


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
	assert(colony.needs_enabled, "needs disabled — probe is meaningless")

	# Any unit works — the latch logic is facet-scaled but uniform.
	var u: Unit = colony.units[0]
	var day_ms := int(colony.day_length() * 1000.0)
	var therapy := u._mood_therapy_line()
	var release := u._mood_release_line()
	var seek := u._recreation_seek()
	print(
		"unit %s — therapy %.2f release %.2f seek %.2f refill %.2f" % [
			u.name, therapy, release, seek, Unit.REC_THERAPY_REFILL,
		]
	)

	print("-- expectations grace --")
	# The save's planet is younger than the window, so the curve is
	# driven with explicit instants rather than real colony age.
	colony.founded_msec = 0
	check(
		is_equal_approx(
			colony.expectations_bonus(0), Colony.EXPECTATIONS_MAX
		),
		"a fresh colony rides the full cushion"
	)
	var mid := colony.expectations_bonus(8 * day_ms)
	check(
		mid > 0.0 and mid < Colony.EXPECTATIONS_MAX,
		"the cushion decays with colony age"
	)
	check(
		colony.expectations_bonus(100 * day_ms) == 0.0,
		"the cushion expires past the window"
	)
	colony.founded_msec = colony.game_msec()
	_reset(u)
	check(
		u.mood_target() > Unit.MOOD_BASE + 0.25,
		"the cushion lifts the bare thought math"
	)
	# Keep the latch tests on bare thought math — the cushion would
	# otherwise put headroom into every ceiling check below.
	colony.founded_msec = -1

	print("-- latch arms under the therapy line --")
	_reset(u)
	u.mood = therapy - 0.05
	u.recreation = 0.5
	_tick(u)
	check(u._decompressing, "decompressing arms")

	print("-- latch holds while headroom remains --")
	_reset(u)
	u._decompressing = true
	u.mood = therapy + 0.10
	for i in 5:
		u.add_thought(&"had_fun")
		u.add_thought(&"socialized")
	u.recreation = 0.5
	_tick(u)
	check(u._decompressing, "mood below a high ceiling keeps the latch")

	print("-- spent holds above the refill line --")
	_reset(u)
	u._decompress_spent = true
	u.mood = therapy - 0.05
	u.recreation = Unit.REC_THERAPY_REFILL + 0.05
	_tick(u)
	check(u._decompress_spent, "spent holds at rec > refill")
	check(not u._decompressing, "latch stays off while spent")

	print("-- spent clears at refill only with headroom --")
	_reset(u)
	u._decompress_spent = true
	u.mood = therapy - 0.05
	u.recreation = Unit.REC_THERAPY_REFILL - 0.05
	_tick(u)
	check(
		u._decompress_spent,
		"no headroom: spent holds past the refill line"
	)
	for i in 5:
		u.add_thought(&"had_fun")
	_tick(u)
	check(not u._decompress_spent, "headroom: spent clears at refill")
	_tick(u)
	check(u._decompressing, "re-arms on the next idle tick")

	print("-- non-critical mood waits for the boredom floor --")
	_reset(u)
	u._decompress_spent = true
	u.mood = therapy + 0.10
	u.recreation = seek + 0.20
	_tick(u)
	check(u._decompress_spent, "spent holds mid-bar when mood is fine")
	u.recreation = seek - 0.05
	_tick(u)
	check(not u._decompress_spent, "spent clears at the boredom floor")

	print("-- release paths --")
	_reset(u)
	u._decompressing = true
	u.mood = release + 0.02
	u.recreation = 0.5
	_tick(u)
	check(not u._decompressing, "mood release unlatches")
	check(not u._decompress_spent, "mood release leaves no spent")

	_reset(u)
	u._decompressing = true
	u.mood = therapy - 0.05
	u.recreation = 1.0
	_tick(u)
	check(not u._decompressing, "fun-full unlatches")
	check(u._decompress_spent, "fun-full sets spent")

	# The reported stuck case: latched with mood above the arm line
	# while the thought ceiling sits under it — the binge can't lift
	# mood further, so therapy ends and the unit goes back to work.
	_reset(u)
	u._decompressing = true
	u.mood = therapy + 0.10
	u.recreation = 0.5
	_tick(u)
	check(
		not u._decompressing,
		"mood above its thought ceiling unlatches"
	)
	check(
		not u._decompress_spent,
		"ceiling release above the arm line leaves no spent"
	)

	# Same ceiling release but still under the arm line: therapy gave
	# what it could and the latch spends rather than instantly re-arm.
	_reset(u)
	u._decompressing = true
	u.mood = therapy - 0.05
	u.recreation = 0.5
	_tick(u)
	check(not u._decompressing, "low-ceiling binge still releases")
	check(u._decompress_spent, "a sub-line release spends the latch")

	print(
		"\n%d checks, %d failed" % [checks, fails]
	)
	print("MOOD THERAPY PROBE %s" % ("PASSED" if fails == 0 else "FAILED"))
	quit(1 if fails > 0 else 0)
