class_name Colony
extends Node3D

## Owns the colony state: the job board, the units and the stockpile.
##
## The player never mines directly; they designate work, units claim jobs
## from here and report back when the work is done.

signal job_added(job: ColonyJob)
signal job_finished(job: ColonyJob)
signal unit_spawned(unit: Unit)
signal item_dropped(pile: ItemPile)

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const DLog := preload("res://scripts/dlog.gd")

## How far an item may wander while spilling before it is forced to settle.
const MAX_SPILL_HOPS := 16
## Loose items smaller than this settle instead of splitting again.
const MIN_LOOSE_CM3 := 10_000
const SPILL_SIDES: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]
## How long a unit that dropped a job waits before claiming it again —
## in game-time milliseconds, so the delay scales with speed controls.
const DROPPED_JOB_RETRY_MSEC := 10000
## Cap on the escalating retry delay for a repeatedly failed target.
const DROPPED_JOB_RETRY_MAX_MSEC := 120000
## Job-claim scoring — lowest score wins, measured in metres-equivalent
## so skill and patience trade directly against distance:
##   score = dist·DIST_WEIGHT − level·SKILL_WEIGHT − age·LANGUISH_RATE
## The skill weight is the per-unit stance: generalists get a mild nudge
## toward what they're good at, specialists let expertise dominate
## proximity. The languish term grows a job's appeal while it waits —
## the anti-starvation pressure that keeps unskilled busywork from
## never happening, capped so the boost stays bounded.
const CLAIM_DIST_WEIGHT := 1.0
const CLAIM_SKILL_GENERALIZE := 2.0
const CLAIM_SKILL_SPECIALIZE := 12.0
const CLAIM_LANGUISH_RATE := 0.25
const CLAIM_LANGUISH_CAP := 300.0

## Craft orders a worksite accepts. Inputs count whole items by form
## (`form → count`); outputs list what drops at the spot. `waste` drops
## whatever volume the inputs had beyond the outputs as loose offcuts —
## a log's sawdust, or the plank volume that doesn't pack into a kit.
const RECIPES: Dictionary = {
	&"planks": {
		"label": "Craft planks",
		"inputs": {DropItem.Form.LOG: 1},
		"outputs": [{DropItem.Form.PLANK: 3}],
		"waste": true,
	},
	&"bed": {
		"label": "Craft bed",
		# Six planks in; one packed bed kit plus offcut sawdust out.
		"inputs": {DropItem.Form.PLANK: 6},
		"outputs": [{DropItem.Form.BED: 1}],
		"waste": true,
	},
	# A seed order: one fruit in, two seed packets out, keeping the
	# fruit's species for what farming will one day plant. The crafting
	# spot does it today; a dedicated building will do it better later.
	&"extract_seed": {
		"label": "Extract seed",
		"inputs": {DropItem.Form.FRUIT: 1},
		"outputs": [{DropItem.Form.SEED: 2}],
		"output_material": BlockRegistry.Resource_.SEED,
	},
	# Constructed in place rather than at a worksite: `builds` names the
	# building the escrowed inputs become, so the order is designated
	# directly onto its cell instead of a craft spot.
	&"ladder": {
		"label": "Build ladder",
		"inputs": {DropItem.Form.PLANK: 3},
		"outputs": [],
		"builds": Building.Kind.LADDER,
	},
}
## Recipe order for the worksite panel's buttons.
const RECIPE_ORDER: Array[StringName] = [&"planks", &"bed", &"extract_seed"]

## Pile capacity in a voxel that shares its cell with a ladder — the
## ladder claims a quarter of the space. Mirrors DelveSim's
## LADDER_PILE_CM3.
const LADDER_PILE_CM3 := DropItem.BLOCK_CM3 * 3 / 4

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var day_cycle_path: NodePath = NodePath("../DayCycle")
@export var initial_units: int = 3
## Radius, in voxels, of the area units spawn in around the colony origin.
@export var spawn_radius: int = 6
## Unit needs — energy drain and rest-seeking. Tests flip it off so units
## stay on task; it is not a difficulty switch.
var needs_enabled := true

var world: VoxelWorld
## The site's planet clock — units pace their rest against its day length.
var day_cycle: DayCycle
var jobs: Array[ColonyJob] = []
## instance_id → ColonyJob: claim results resolve through this, and the
## native job board keys on the same ids.
var _job_index: Dictionary = {}
var units: Array[Unit] = []
## Units currently in [enum Unit.State.SLEEPING] — a set maintained by
## each unit's `state_changed` signal (connected at spawn), never by
## rescanning the roster. `_all_asleep` is an O(1) read of its size.
var _sleeping: Dictionary = {}
## Armed sleep-boost toggle: when every unit at the focused site sleeps,
## the clock runs at the top standard speed. "All" is the focused site's
## roster — once multiple sites are active each focus manages its own
## list, and future domestic animals land in `units` and count the same.
var sleep_boost := false
## The speed the player last picked — what the clock falls back to when
## the boost disengages (or was never armed).
var _selected_speed := 1.0
## The top standard speed the boost engages — the HUD's 6x.
const SLEEP_BOOST_SPEED := 6.0
## Loose resources lying in the world, keyed by the voxel they sit in or are
## falling toward.
var item_piles: Dictionary[Vector3i, ItemPile] = {}
## Piles falling onto a voxel that already has a pile — they merge into it
## when they land. Not keyed in [member item_piles] while in flight.
var _in_flight: Array[ItemPile] = []

## Voxels designated as stockpile tiles: haul destinations for loose items.
## Designated stockpile tiles — voxel → reject-set: a Dictionary of the
## material ints this tile refuses to store. An empty set admits
## everything, which is what a fresh designation means.
var stockpiles: Dictionary[Vector3i, Dictionary] = {}
## Growing zones — farm-field cell → its [FarmField] record. A field is
## a set of cells plus the crop assigned to them; the farm scan turns an
## assigned field into SOW, FORAGE and CHOP jobs.
var farms: Dictionary[Vector3i, FarmField] = {}
## Farm-cell → the pending job the field generated for it (sow, harvest
## or auto-chop). Auto jobs carry no marker — the zone's own marker
## already covers the cell.
var _farm_jobs: Dictionary[Vector3i, ColonyJob] = {}
## Constructed things, keyed by voxel: built wall blocks and worksites
## (the crafting spot — a designated place that needs no materials).
## Each record keeps what the construction was built from so it can be
## deconstructed into exactly those items and later rendered in its
## material. Voxel blocks alone can't carry that.
var buildings: Dictionary[Vector3i, Building] = {}
## Whether designation markers render — the HUD's zones toggle. The
## designations keep working either way.
var markers_visible := true
## Plan markers — pending build walls and deconstruct marks — render on a
## second switch, Timberborn-style: the HUD's Plans toggle, OR whenever a
## planning tool (a wall action or deconstruct) is in hand.
var plans_visible_manual := true
var _plans_tool_active := false
var _plan_voxels: Dictionary[Vector3i, bool] = {}

## Nearest-* searches walk rings of [member SPATIAL_BUCKET_SHIFT]-voxel
## columns outward from the query instead of scanning every entry — the
## colony plays in a bounded area, so a local hit exits after a ring or
## two. Members are kept in sync everywhere item_piles/stockpiles change.
const SPATIAL_BUCKET_SHIFT := 4
enum _Match { VETO, RETRY, FRESH }
var _pile_buckets: Dictionary = {}      # Vector2i -> Array[Vector3i]
var _stockpile_buckets: Dictionary = {} # Vector2i -> Array[Vector3i]

var _designation_markers: Dictionary[Vector3i, Node3D] = {}
var _marker_mesh: BoxMesh
var _outline_mesh: ImmediateMesh
var _marker_material: StandardMaterial3D
var _clear_marker_material: StandardMaterial3D
var _build_marker_material: StandardMaterial3D
var _stockpile_marker_material: StandardMaterial3D
var _craft_spot_marker_material: StandardMaterial3D
var _craft_job_marker_material: StandardMaterial3D
var _deconstruct_marker_material: StandardMaterial3D
var _bed_marker_material: StandardMaterial3D
var _forage_marker_material: StandardMaterial3D
var _farm_marker_material: StandardMaterial3D
var _ladder_marker_material: StandardMaterial3D
## Low slab each bed cell renders as while real furniture meshes don't
## exist.
var _bed_mesh: BoxMesh
## The ladder's stand-in: a pole filling the cell's height at its center
## — attached-versus-freestanding rendering is deferred to real meshes.
var _ladder_mesh: BoxMesh

## The world's growing trees — chop designations resolve through it.
var forest: Forest

## The world's forageable plants — forage designations resolve through
## it. See plants.gd.
var plants: Plants

## Ground cover — grassed cells are ordinary dirt blocks carrying a
## decoration layer; construction and foot traffic wear it away.
## See grass.gd.
var grass: Grass


func _ready() -> void:
	world = get_node(world_path)
	day_cycle = get_node_or_null(day_cycle_path)
	world.block_mined.connect(_on_block_mined)
	world.block_placed.connect(_on_block_placed)
	world.block_collapsed.connect(_on_block_collapsed)
	world.block_loaded.connect(_on_world_block_loaded)
	forest = Forest.new()
	forest.name = "Forest"
	add_child(forest)
	forest.setup(world, self)
	plants = Plants.new()
	plants.name = "Plants"
	add_child(plants)
	plants.setup(world, self)
	grass = Grass.new()
	grass.name = "Grass"
	add_child(grass)
	grass.setup(world, self)
	_marker_mesh = BoxMesh.new()
	_marker_mesh.size = Vector3.ONE * 1.02
	_outline_mesh = _make_outline_mesh()
	_marker_material = _make_marker_material(Color(1.0, 0.85, 0.2, 0.35))
	_clear_marker_material = _make_marker_material(Color(0.35, 0.85, 1.0, 0.35))
	_build_marker_material = _make_marker_material(Color(0.65, 0.4, 0.15, 0.35))
	_stockpile_marker_material = _make_marker_material(Color(0.5, 1.0, 0.55, 0.45))
	_craft_spot_marker_material = _make_marker_material(Color(0.75, 0.5, 0.95, 0.45))
	_craft_job_marker_material = _make_marker_material(Color(0.75, 0.5, 0.95, 0.5))
	_deconstruct_marker_material = _make_marker_material(Color(1.0, 0.35, 0.2, 0.45))
	_forage_marker_material = _make_marker_material(Color(0.95, 0.3, 0.45, 0.4))
	_farm_marker_material = _make_marker_material(Color(0.85, 0.7, 0.25, 0.45))
	# A built bed: a low box per footprint cell — the building's stand-in
	# model until furniture gets real meshes.
	_bed_marker_material = _make_marker_material(Color(0.6, 0.45, 0.25, 0.6))
	_bed_mesh = BoxMesh.new()
	_bed_mesh.size = Vector3(0.94, 0.4, 0.94)
	# A built ladder: a pole running the cell's height — the rendering
	# doesn't yet distinguish wall-hugging from freestanding.
	_ladder_marker_material = _make_marker_material(Color(0.5, 0.32, 0.14, 0.9))
	_ladder_mesh = BoxMesh.new()
	_ladder_mesh.size = Vector3(0.14, 1.02, 0.14)


## The site's sim heartbeat: logical progress that must not depend on
## presentation. Pile-flight timing lives in DelveSim so a falling pile
## lands even when no ItemPile node is processing; node-driven `landed`
## emissions still arrive for rendered piles and are absorbed by the
## idempotency guard in _on_pile_landed.
func _physics_process(delta: float) -> void:
	# Organic decay runs off the game clock — `delta` already carries the
	# pause/speed scaling — and doesn't depend on the native sim.
	_decay_elapsed += delta
	if _decay_elapsed >= DECAY_TICK_SEC:
		var elapsed := _decay_elapsed
		_decay_elapsed = 0.0
		_decay_tick(elapsed)
	if world != null:
		_farm_elapsed += delta
		if _farm_elapsed >= FARM_SCAN_SEC:
			_farm_elapsed = 0.0
			_farm_tick()
		_worksite_elapsed += delta
		if _worksite_elapsed >= WORKSITE_SCAN_SEC:
			_worksite_elapsed = 0.0
			_worksite_tick()
	if world == null or world.sim == null:
		return
	for pile_id in world.sim.tick(delta):
		var pile := instance_from_id(pile_id) as ItemPile
		if pile != null:
			_on_pile_landed(pile)


## Game seconds between organic-decay sweeps — each pass rolls the
## stochastic decay on every landed pile.
const DECAY_TICK_SEC := 4.0
## The decay quantum: bulk stacks rot in chunks of this size — each sweep
## a stack sheds Poisson(V·dt/(life·Q)) quanta — so a large pile streams
## losses smoothly while a tiny one rots in rare whole bites instead of
## dust-shaving. A roll covering nearly the whole stack takes it all.
const DECAY_QUANTUM_CM3 := 8_000
const DECAY_WHOLE_FRAC := 0.9
## A fruit item whose last volume rots away over soil rolls this chance
## to sprout a same-species plant — a sapling for trees, a bush for the
## rest — subject to the neighbourhood spacing rule.
const DECAY_SPROUT_CHANCE := 0.05
## Game seconds between farm-field scans — each pass posts new sow,
## harvest and auto-chop jobs and suspends seed-starved sows.
const FARM_SCAN_SEC := 4.0
## Game seconds between worksite dispatches — each pass gives an idle
## queued worksite its next runnable order.
const WORKSITE_SCAN_SEC := 1.0

var _decay_elapsed := 0.0
var _farm_elapsed := 0.0
var _worksite_elapsed := 0.0


## One decay pass over every landed pile. Bulk items shed quanta at a
## Poisson rate sized so the mean lifetime is the rule's day count;
## discrete items — logs, fruits, seed packets — convert or vanish whole
## at `dt/life` per sweep. Decayed organics leave compost behind in the
## pile, and a fully-rotted fruit may sprout a plant.
func _decay_tick(dt: float) -> void:
	var day_sec := day_length()
	var sprouts: Array = []
	var emptied: Array = []
	for voxel: Vector3i in item_piles:
		var pile := item_piles[voxel]
		var compost := 0
		var rotted := false
		var kept: Array[DropItem] = []
		for item in pile.items:
			var rule := DropItem.decay_rule(item)
			if rule.is_empty():
				kept.append(item)
				continue
			var life := float(rule[&"days"]) * day_sec
			if item.form != DropItem.Form.LOOSE:
				if randf() >= dt / life:
					kept.append(item)
					continue
				rotted = true
				compost += int(
					item.volume * float(rule.get(&"compost", 0.0))
				)
				if rule.get(&"spawn", false):
					sprouts.append([voxel, item.material])
				continue
			var quanta := _poisson(
				float(item.volume) * dt / (life * DECAY_QUANTUM_CM3)
			)
			if quanta <= 0:
				kept.append(item)
				continue
			rotted = true
			var loss := mini(quanta * DECAY_QUANTUM_CM3, item.volume)
			if loss >= item.volume * DECAY_WHOLE_FRAC:
				loss = item.volume
			item.volume -= loss
			compost += int(loss * float(rule.get(&"compost", 0.0)))
			if item.volume > 0:
				kept.append(item)
			elif rule.get(&"spawn", false):
				sprouts.append([voxel, item.material])
		if not rotted:
			continue
		pile.items = kept
		if compost > 0:
			pile.items.append(
				DropItem.new(
					BlockRegistry.Resource_.COMPOST,
					DropItem.Form.LOOSE, compost
				)
			)
		pile._rebuild_mesh()
		# Resync packed state — a shrunken pile may have opened its cell
		# or pulled the floor out from under a pile resting on top.
		pile.fill_changed.emit(pile)
		if pile.items.is_empty():
			emptied.append(voxel)
	for voxel: Vector3i in emptied:
		remove_pile_if_empty(voxel)
	for sprout: Array in sprouts:
		_sprout_from_decay(sprout[0], sprout[1])


## Knuth's Poisson sampler — counts decay quanta per sweep. The loads it
## sees are small: a full voxel of fast-rotting fruit expects ~0.2.
func _poisson(mu: float) -> int:
	var limit := exp(-mu)
	var count := 0
	var p := 1.0
	while p > limit:
		count += 1
		p *= randf()
	return count - 1


## A fruit item rotted away at [param voxel]: over soil it may sprout its
## species' plant — a sapling for trees (no plant in the cell or the
## eight around it) or an immature bush (no plant in the cell itself).
func _sprout_from_decay(
	voxel: Vector3i, material: BlockRegistry.Resource_
) -> void:
	if world == null or forest == null or plants == null:
		return
	if not world.is_editable(voxel):
		return
	var below := world.get_block(voxel + Vector3i.DOWN)
	if below != BlockRegistry.Block.DIRT:
		return
	if randf() >= DECAY_SPROUT_CHANCE:
		return
	_sprout_plant(voxel, material)


## Try to plant [param material]'s species at [param voxel]: a sapling
## for trees (which demands the cell plus its eight neighbours free of
## trees and bushes), an immature bush otherwise (only its own cell).
## True when something planted — the soil check lives on the caller.
func _sprout_plant(voxel: Vector3i, material: BlockRegistry.Resource_) -> bool:
	var species: StringName = DropItem.FRUIT_SPECIES.get(material, &"")
	if species == &"":
		return false
	if Forest.SPECIES.has(species):
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell := voxel + Vector3i(dx, 0, dz)
				if (
					forest.tree_root_at(cell) != Vector3i.MAX
					or plants.bush_at(cell) != Vector3i.MAX
				):
					return false
		return forest.plant_sapling(voxel, species)
	if not Plants.SPECIES.has(species):
		return false
	if (
		forest.tree_root_at(voxel) != Vector3i.MAX
		or plants.bush_at(voxel) != Vector3i.MAX
	):
		return false
	return plants.plant(voxel, species)


## The length of this site's day in game seconds — the unit rest cycle's
## pacing reference. Falls back to the DayCycle default when no clock is
## wired (headless harnesses).
func day_length() -> float:
	return day_cycle.day_length_seconds if day_cycle != null else 240.0


## The game clock in milliseconds — job retry records, claim languish,
## plant regrow timers and blacklist cool-offs all compare against it, so
## pausing freezes them and speed multipliers accelerate them like every
## other in-game duration. Falls back to wall time without a day cycle.
func game_msec() -> int:
	return (
		day_cycle.game_msec() if day_cycle != null
		else Time.get_ticks_msec()
	)


## The single speed authority — the HUD's buttons and the overseer's hotkeys
## all come through here so the sleep boost can't fight a manual setting:
## pausing always wins, otherwise the clock runs at the boost speed while
## engaged and at the player's pick otherwise.
func set_speed(scale: float) -> void:
	if scale > 0.0:
		_selected_speed = scale
	get_tree().paused = scale <= 0.0
	_apply_speed()


func set_paused(on: bool) -> void:
	get_tree().paused = on
	_apply_speed()


## Arms or disarms the sleep-boost toggle — the HUD's Zz button.
func set_sleep_boost(on: bool) -> void:
	sleep_boost = on
	_apply_speed()


## True while the boost is actually driving the clock — armed, unpaused,
## and everyone asleep. The HUD reads this to show the engaged state.
func sleep_boost_engaged() -> bool:
	return sleep_boost and not get_tree().paused and _all_asleep()


## Every unit at the focused site is asleep — the roster is the site's
## unit list; the empty roster never counts as "everyone asleep".
func _all_asleep() -> bool:
	return not units.is_empty() and _sleeping.size() == units.size()


func _apply_speed() -> void:
	if get_tree().paused:
		return
	Engine.time_scale = (
		SLEEP_BOOST_SPEED if sleep_boost_engaged() else _selected_speed
	)


## The sleep counter's observer — one state_changed hook per unit (the
## bound unit argument trails the emitted from/to pair).
func _on_unit_state_changed(
	from_state: Unit.State, to_state: Unit.State, unit: Unit
) -> void:
	if to_state == Unit.State.SLEEPING:
		_sleeping[unit] = true
	elif from_state == Unit.State.SLEEPING:
		_sleeping.erase(unit)
	_apply_speed()


func _make_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


## A wireframe unit cube, centred at the origin — stockpile tiles get a
## faint outline rather than a filled box.
func _make_outline_mesh() -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var corners: Array[Vector3] = []
	for x in [-0.51, 0.51]:
		for y in [-0.51, 0.51]:
			for z in [-0.51, 0.51]:
				corners.append(Vector3(x, y, z))
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in corners.size():
		for j in range(i + 1, corners.size()):
			var d := (corners[i] - corners[j]).abs()
			if int(d.x > 0.0) + int(d.y > 0.0) + int(d.z > 0.0) == 1:
				mesh.surface_add_vertex(corners[i])
				mesh.surface_add_vertex(corners[j])
	mesh.surface_end()
	return mesh


## Queues a mining job, unless that voxel is already designated.
func designate_mine(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	if not world.is_solid(voxel_position):
		return null
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# Tree parts are felled whole — designate_chop instead.
		return null

	var job := ColonyJob.new(ColonyJob.Type.MINE, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _marker_material)
	DLog.log("designated mine %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a clearing job for a voxel holding items: a unit moves the whole
## pile into adjoining voxels. Only piles can be designated.
func designate_clear(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	var pile := item_pile_at(voxel_position)
	if pile == null or pile.items.is_empty():
		return null

	var job := ColonyJob.new(ColonyJob.Type.CLEAR, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _clear_marker_material)
	DLog.log("designated clear %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a wall build of the player's chosen [param material]: a unit
## fetches what that material's recipe needs from piles — loose soil, stone
## boulders and cobbles, or logs — and raises the block it makes (see
## [constant BlockRegistry.WALL_MATERIALS]). The voxel must be free of
## solid terrain, growing things and not packed full of items.
func designate_build(voxel_position: Vector3i, material: BlockRegistry.Resource_) -> ColonyJob:
	if not BlockRegistry.WALL_MATERIALS.has(material):
		return null
	if _designation_markers.has(voxel_position):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR or is_packed(voxel_position):
		return null
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# Sapling and leaf cells are air but claimed — a wall would entomb
		# the decoration and block the tree's growth.
		return null

	var job := ColonyJob.new(ColonyJob.Type.BUILD, voxel_position)
	job.material = material
	job.block_id = BlockRegistry.wall_block_for(material)
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated build %s" % voxel_position)
	job_added.emit(job)
	return job


## Marks a voxel as a stockpile tile — a haul destination for idle units.
## The voxel must be empty and rest on a solid block.
func designate_stockpile(voxel_position: Vector3i) -> bool:
	if _designation_markers.has(voxel_position):
		return false
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(voxel_position) > 0:
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	stockpiles[voxel_position] = {}
	_index_add(_stockpile_buckets, voxel_position)
	_add_marker(voxel_position, _stockpile_marker_material, _outline_mesh)
	return true


## Removes a stockpile designation; any items piled there stay put.
func undesignate_stockpile(voxel_position: Vector3i) -> bool:
	if not stockpiles.has(voxel_position):
		return false
	stockpiles.erase(voxel_position)
	_index_remove(_stockpile_buckets, voxel_position)
	_remove_marker(voxel_position)
	return true


func is_stockpile(voxel_position: Vector3i) -> bool:
	return stockpiles.has(voxel_position)


## The tile's admission filter: whether [param material] may be stored on
## the stockpile at [param voxel_position].
func stockpile_admits(voxel_position: Vector3i, material: BlockRegistry.Resource_) -> bool:
	return (
		stockpiles.has(voxel_position)
		and not stockpiles[voxel_position].get(int(material), false)
	)


## Sets the tile's admission for [param material]. Rejected materials that
## are already piled on the tile become haul-out candidates, so the filter
## cleans up existing contents instead of only gating new deposits.
func set_stockpile_admission(
	voxel_position: Vector3i, material: BlockRegistry.Resource_, admitted: bool
) -> void:
	var rejected: Dictionary = stockpiles.get(voxel_position, null)
	if rejected == null:
		return
	if admitted:
		rejected.erase(int(material))
	else:
		rejected[int(material)] = true


## Whether anything piled on the voxel offends its own tile's filter —
## those piles want hauling elsewhere.
func _pile_rejected_here(voxel_position: Vector3i) -> bool:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return false
	for item in pile.items:
		if not stockpile_admits(voxel_position, item.material):
			return true
	return false


## Marks a voxel as a farm-field cell — the growing zone. The cell must
## be empty, unclaimed and resting on a solid block (like a stockpile
## tile); whether it can actually grow the assigned crop is the sow
## gate's question, not the zone's. A cell touching an existing field
## joins it — a dragged rect ends up one field.
func designate_farm(voxel_position: Vector3i) -> bool:
	if _designation_markers.has(voxel_position):
		return false
	if farms.has(voxel_position):
		return false
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(voxel_position) > 0:
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	if building_at(voxel_position) != null:
		return false
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		return false
	if plants.bush_at(voxel_position) != Vector3i.MAX:
		return false
	var field := _farm_field_for(voxel_position)
	field.cells[voxel_position] = true
	farms[voxel_position] = field
	_add_marker(voxel_position, _farm_marker_material, _outline_mesh)
	DLog.log("designated farm cell %s" % voxel_position)
	return true


## Removes the voxel from its farm field; the field record lives on in
## the remaining cells. A pending farm-generated job at the cell dies
## with the designation.
func undesignate_farm(voxel_position: Vector3i) -> bool:
	var field := farm_at(voxel_position)
	if field == null:
		return false
	field.cells.erase(voxel_position)
	farms.erase(voxel_position)
	var job: ColonyJob = _farm_jobs.get(voxel_position)
	if job != null:
		if job.is_active():
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
		_farm_jobs.erase(voxel_position)
		_prune_jobs()
	_remove_marker(voxel_position)
	return true


## The field covering [param voxel_position], or null.
func farm_at(voxel_position: Vector3i) -> FarmField:
	return farms.get(voxel_position)


## The neighbour's field when [param voxel_position] borders one, else a
## fresh record — contiguous drags share a crop assignment.
func _farm_field_for(voxel_position: Vector3i) -> FarmField:
	for dir in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		var field: FarmField = farms.get(voxel_position + dir)
		if field != null:
			return field
	return FarmField.new()


## Assigns the crop the field under [param voxel_position] grows — a
## Plants or Forest species key, or empty to idle the zone.
func set_farm_crop(voxel_position: Vector3i, species: StringName) -> void:
	var field := farm_at(voxel_position)
	if field == null:
		return
	if species != &"" and not farmable_species_ids().has(species):
		return
	field.species = species


## Tree fields only have a use for this: fell each tree the moment it
## matures. Off leaves them standing — and fruiting.
func set_farm_auto_chop(voxel_position: Vector3i, on: bool) -> void:
	var field := farm_at(voxel_position)
	if field != null:
		field.auto_chop = on


## The picker's species list: every shrub and tree species, tagged for
## the farm panel. Returns {id, name, tree} per entry.
func farmable_species() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: StringName in Plants.SPECIES:
		out.append({
			&"id": id, &"name": Plants.SPECIES[id][&"name"], &"tree": false,
		})
	for id: StringName in Forest.SPECIES:
		out.append({
			&"id": id, &"name": Forest.SPECIES[id][&"name"], &"tree": true,
		})
	return out


## The bare species-key set — the crop setter's validation.
func farmable_species_ids() -> Array:
	var ids := Plants.SPECIES.keys()
	ids.append_array(Forest.SPECIES.keys())
	return ids


## Places a crafting spot — a worksite, the simplest building: no
## materials, nothing to construct, just a designated place a craft job
## can be ordered at. The voxel must be empty, unclaimed by a tree and
## rest on a solid block.
func designate_craft_spot(voxel_position: Vector3i) -> bool:
	if _designation_markers.has(voxel_position):
		return false
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(voxel_position) > 0:
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		# A growing tree would raise its trunk into the spot.
		return false
	var building := Building.new(Building.Kind.WORKSITE, voxel_position)
	register_building(building)
	_add_marker(voxel_position, _craft_spot_marker_material, _outline_mesh)
	DLog.log("designated crafting spot %s" % voxel_position)
	return true


## The building record at [param voxel_position], or null — the lookup the
## deconstruct tool and the inspect panel share.
func building_at(voxel_position: Vector3i) -> Building:
	return buildings.get(voxel_position)


func register_building(building: Building) -> void:
	for cell in building.footprint:
		buildings[cell] = building
		if grass != null:
			# Anything built on a grassed block buries its cover.
			grass.bare(cell + Vector3i.DOWN)
		if building.kind == Building.Kind.LADDER and world.sim != null:
			# Mirror the climb edge into the native sim — ladders are
			# walkability, not occupancy, so there's nothing to render
			# in the voxel itself.
			world.sim.set_ladder(cell, true)


func is_craft_spot(voxel_position: Vector3i) -> bool:
	var building := building_at(voxel_position)
	return building != null and building.kind == Building.Kind.WORKSITE


## Queues a deconstruction job on the building at [param voxel_position]:
## a unit takes it apart and it drops exactly the items it was built of.
## Packed-dirt walls aren't buildings from the tool's point of view —
## tamped soil reads as natural ground and has to be mined out.
func designate_deconstruct(voxel_position: Vector3i) -> ColonyJob:
	var building := building_at(voxel_position)
	if building == null:
		# Timberborn: the deconstruct tool also cancels a planned build —
		# there's nothing standing there to take apart.
		if plan_job_at(voxel_position) != null:
			cancel_designation(voxel_position)
		return null
	if not building.deconstructable:
		return null
	# Multi-cell buildings anchor their job at the record's own voxel so
	# either cell designates (and finds) the same teardown.
	var anchor := building.voxel
	if deconstruct_job_at(anchor) != null:
		return null
	if building.kind == Building.Kind.WALL and _designation_markers.has(anchor):
		# Walls share the marker map with designations — a marker there
		# means another job (e.g. a mine) already owns the cell.
		return null
	var job := ColonyJob.new(ColonyJob.Type.DECONSTRUCT, anchor)
	for cell in building.footprint:
		if cell != anchor:
			job.extra_voxels.append(cell)
	_register_job(job)
	if building.kind == Building.Kind.WALL:
		_add_marker(anchor, _deconstruct_marker_material, null, true)
	else:
		for cell in building.footprint:
			_set_marker_appearance(cell, _deconstruct_marker_material, _marker_mesh)
	DLog.log("designated deconstruct %s" % anchor)
	job_added.emit(job)
	return job


## The active build job at [param voxel_position], or null — pending walls
## are aimable plan cells, so the designator tools query this per voxel
## the cursor's ray crosses.
func build_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BUILD
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## The active construction job claiming [param voxel_position] — a pending
## wall or furnish plan at its anchor *or* any of its extra cells. This is
## the lookup the aim ray and the deconstruct-as-cancel tool share.
func plan_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			(
				job.type == ColonyJob.Type.BUILD
				or job.type == ColonyJob.Type.FURNISH
				or (
					job.type == ColonyJob.Type.CRAFT
					and RECIPES.get(job.recipe, {}).has("builds")
				)
			)
			and job.is_active()
			and (
				job.voxel_position == voxel_position
				or job.extra_voxels.has(voxel_position)
			)
		):
			return job
	return null


## The active deconstruction job at [param voxel_position], or null —
## matches any cell of a multi-cell building's footprint.
func deconstruct_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.DECONSTRUCT
			and job.is_active()
			and (
				job.voxel_position == voxel_position
				or job.extra_voxels.has(voxel_position)
			)
		):
			return job
	return null


## Deconstruction done: the block comes out, the construction's exact
## input items drop where it stood, and its record dies. Any task the
## worksite was running dies with it.
func complete_deconstruct(job: ColonyJob) -> void:
	var voxel := job.voxel_position
	var building: Building = buildings.get(voxel)
	for j in jobs:
		if j != job and j.voxel_position == voxel and j.is_active():
			_return_escrow(j)
			j.state = ColonyJob.State.CANCELLED
			if j.assignee != null and j.assignee.has_method(&"abandon_job"):
				j.assignee.abandon_job()
	if building != null:
		if building.occupant != null and is_instance_valid(building.occupant):
			# The sleeper's bed just went away — it wakes and finds the
			# ground like anyone whose rest was cut short.
			building.occupant.abandon_job()
		if (
			building.block_id != BlockRegistry.Block.AIR
			and world.get_block(voxel) == building.block_id
		):
			world.remove_voxel(voxel)
			# Whatever rested on the block lost its floor.
			_settle_pile_at(voxel + Vector3i.UP)
		for item in building.components:
			_drop_item(item, voxel)
		for cell in building.footprint:
			buildings.erase(cell)
			if building.kind == Building.Kind.LADDER and world.sim != null:
				world.sim.set_ladder(cell, false)
	_finish_job(job)


## Returns a job's escrowed items to the world — material already
## absorbed into a pending build, or inputs a craft job collected — so a
## cancellation conserves everything that went in.
func _return_escrow(job: ColonyJob) -> void:
	for item in job.components:
		_drop_item(item, job.voxel_position)
	job.components.clear()


## Bucket a voxel belongs to for the spatial index.
func _bucket_of(voxel: Vector3i) -> Vector2i:
	return Vector2i(voxel.x >> SPATIAL_BUCKET_SHIFT, voxel.z >> SPATIAL_BUCKET_SHIFT)


func _index_add(buckets: Dictionary, voxel: Vector3i) -> void:
	var key := _bucket_of(voxel)
	var list: Array = buckets.get(key, [])
	if list.is_empty():
		buckets[key] = list
	list.append(voxel)


func _index_remove(buckets: Dictionary, voxel: Vector3i) -> void:
	var key := _bucket_of(voxel)
	var list: Array = buckets.get(key, [])
	if list.is_empty():
		return
	list.erase(voxel)
	if list.is_empty():
		buckets.erase(key)


## The voxel of the nearest index member satisfying [param classify],
## which returns [enum _Match] per candidate: VETO skips it, FRESH is a
## normal hit and RETRY a deprioritised one — a retry only wins when no
## fresh hit exists at any distance. Rings expand outward from [param
## from]'s column and stop as soon as no member of the next ring could be
## closer than the best fresh hit; with no fresh hit the whole index is
## walked (unavoidable — every entry must be ruled out).
func _nearest_indexed(from: Vector3i, buckets: Dictionary, classify: Callable) -> Vector3i:
	var centre := _bucket_of(from)
	var best := Vector3i.MAX
	var best_sq := INF
	var retry := Vector3i.MAX
	var retry_sq := INF

	var extent := 0
	for key in buckets:
		extent = maxi(extent, maxi(absi(key.x - centre.x), absi(key.y - centre.y)))

	var radius := 0
	while radius <= extent:
		# The nearest voxel in ring [param radius] sits at least this far
		# out — past that, nothing can beat a hit already found.
		var ring_min := float(maxi(radius - 1, 0) << SPATIAL_BUCKET_SHIFT)
		if best != Vector3i.MAX and ring_min * ring_min > best_sq:
			break
		for bx in range(centre.x - radius, centre.x + radius + 1):
			for bz in range(centre.y - radius, centre.y + radius + 1):
				if maxi(absi(bx - centre.x), absi(bz - centre.y)) != radius:
					continue
				var list: Array = buckets.get(Vector2i(bx, bz), [])
				if list.is_empty():
					continue
				for voxel in list:
					var tier: int = classify.call(voxel)
					if tier == _Match.VETO:
						continue
					var sq := (Vector3(voxel) - Vector3(from)).length_squared()
					if tier == _Match.FRESH:
						if sq < best_sq:
							best_sq = sq
							best = voxel
					elif sq < retry_sq:
						retry_sq = sq
						retry = voxel
		radius += 1
	return best if best != Vector3i.MAX else retry


## The active craft job queued at [param voxel_position], or null.
func craft_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.CRAFT
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## Queues a bill on the worksite at [param voxel_position] and returns
## it; the queue's scan turns runnable bills into craft jobs in order.
## A unit fetches the recipe's inputs — as many trips as the carry load
## needs — saws at the spot and drops the products there. Inputs are
## escrowed into the *running job* as they arrive, so a cancelled order
## hands them back rather than eating them; a still-queued bill owns
## nothing. A spot coming down takes no new bills.
func queue_order(
	voxel_position: Vector3i,
	recipe: StringName,
	condition: WorksiteOrder.Condition = WorksiteOrder.Condition.TIMES,
	target: int = 1
) -> WorksiteOrder:
	if not RECIPES.has(recipe) or RECIPES[recipe].has("builds"):
		return null
	var building: Building = buildings.get(voxel_position)
	if building == null or building.kind != Building.Kind.WORKSITE:
		return null
	if deconstruct_job_at(voxel_position) != null:
		return null
	var order := WorksiteOrder.new()
	order.recipe = recipe
	order.condition = condition
	order.target = target
	building.orders.append(order)
	DLog.log("queued craft order %s at %s" % [recipe, voxel_position])
	_dispatch_worksite(building)
	return order


## Back-compat shortcut: enqueue a one-shot bill and return the craft
## job it became, or null if it can't dispatch yet (queued and waiting)
## or the order itself was refused.
func designate_craft(voxel_position: Vector3i, recipe: StringName = &"planks") -> ColonyJob:
	if queue_order(voxel_position, recipe) == null:
		return null
	return craft_job_at(voxel_position)


## Drops [param order] from the worksite at [param voxel_position]. If
## it's the order currently running, its job is cancelled too — the
## escrowed inputs drop back at the spot. Returns false if the order
## isn't on this worksite's queue.
func remove_order(voxel_position: Vector3i, order: WorksiteOrder) -> bool:
	var building: Building = buildings.get(voxel_position)
	if building == null or not building.orders.has(order):
		return false
	building.orders.erase(order)
	var job := craft_job_at(voxel_position)
	if job != null and job.order == order:
		_cancel_job(job)
	return true


## Cancels a job mid-flight: escrow returns, the assignee lets go, the
## worksite marker comes back, and the corpse is pruned.
func _cancel_job(job: ColonyJob) -> void:
	_return_escrow(job)
	job.state = ColonyJob.State.CANCELLED
	if job.assignee != null and job.assignee.has_method(&"abandon_job"):
		job.assignee.abandon_job()
	_restore_worksite_marker(job.voxel_position)
	_prune_jobs()


## One dispatch pass over every worksite: the site that has queued bills
## and no live craft job takes its next runnable one.
func _worksite_tick() -> void:
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building):
			continue
		seen[building] = true
		if building.kind == Building.Kind.WORKSITE and not building.orders.is_empty():
			_dispatch_worksite(building)


## Gives [param building] its next runnable bill, if any. The queue is
## walked head-first: a finished TIMES order drops out, a stocked
## UNTIL_HAVE order parks in place (it keeps priority and resumes when
## the count dips), and an order whose inputs don't exist anywhere
## rotates to the back of the line rather than blocking it. At most one
## job posts per call.
func _dispatch_worksite(building: Building) -> void:
	if (
		craft_job_at(building.voxel) != null
		or deconstruct_job_at(building.voxel) != null
	):
		return
	var deferred: Array[WorksiteOrder] = []
	var i := 0
	while i < building.orders.size():
		var order := building.orders[i]
		if (
			order.condition == WorksiteOrder.Condition.TIMES
			and order.done >= order.target
		):
			building.orders.remove_at(i)
			continue
		if not order.wants_work(_have_count(order.recipe)):
			# Parked, not broken — it holds its place in line.
			i += 1
			continue
		if _order_dispatchable(order):
			var job := ColonyJob.new(ColonyJob.Type.CRAFT, building.voxel)
			job.recipe = order.recipe
			job.order = order
			_register_job(job)
			# The spot marker stays — it just switches to the running look.
			_set_marker_appearance(
				building.voxel, _craft_job_marker_material, _marker_mesh
			)
			job_added.emit(job)
			break
		deferred.append(order)
		building.orders.remove_at(i)
	for order in deferred:
		building.orders.append(order)


## True when every input the order's recipe calls for exists in some
## landed pile, counted by the cm³ the recipe wants. In-flight items and
## escrowed components don't count — availability is what a fetch could
## actually reach.
func _order_dispatchable(order: WorksiteOrder) -> bool:
	var inputs: Dictionary = RECIPES[order.recipe]["inputs"]
	for form: int in inputs:
		var need := int(inputs[form]) * DropItem.form_volume(form)
		var have := 0
		for voxel in item_piles:
			have += item_piles[voxel].form_volume(form)
		if have < need:
			return false
	return true


## How many of [param recipe]'s output items the colony holds — every
## landed pile counts, not just stockpiles; items in flight, escrowed
## in a job or carried by a unit don't. The count is by the recipe's
## first output form, material-agnostic: "until you have 10 planks".
func _have_count(recipe: StringName) -> int:
	var outputs: Array = RECIPES.get(recipe, {}).get("outputs", [])
	if outputs.is_empty():
		return 0
	var form: int = outputs[0].keys()[0]
	var count := 0
	for voxel in item_piles:
		for item in item_piles[voxel].items:
			if item.form == form:
				count += 1
	return count


## A craft job is done once its products hit the ground at the spot —
## or, for a construct-in-place recipe like the ladder, once the
## escrowed inputs have become the building. A worksite bill counts the
## run against its condition; a finished TIMES order leaves the queue.
func complete_craft(job: ColonyJob) -> void:
	if RECIPES[job.recipe].has("builds"):
		complete_construct(job)
		return
	if job.order != null:
		job.order.done += 1
		if (
			job.order.condition == WorksiteOrder.Condition.TIMES
			and job.order.done >= job.order.target
		):
			var building: Building = buildings.get(job.voxel_position)
			if building != null:
				building.orders.erase(job.order)
	_finish_job(job)


## The cells a bed built at [param anchor] would claim: [param anchor]
## plus the first valid horizontal neighbor. A bed needs open air over
## solid floor on both cells; the second picks from +X, −X, +Z, −Z in
## order until a real orientation control exists. Empty when the anchor
## can't host a bed at all.
func bed_cells(anchor: Vector3i) -> Array[Vector3i]:
	if not _bed_cell_free(anchor):
		return []
	for side in SPILL_SIDES:
		var second := anchor + side
		if _bed_cell_free(second):
			return [anchor, second]
	return []


## True when [param voxel] can host part of a bed: open air over solid
## ground, not packed with items, not already designated or built on.
func _bed_cell_free(voxel: Vector3i) -> bool:
	return (
		world.is_editable(voxel)
		and world.get_block(voxel) == BlockRegistry.Block.AIR
		and voxel_fill(voxel) <= 0
		and world.is_solid(voxel + Vector3i.DOWN)
		and not _designation_markers.has(voxel)
		and not buildings.has(voxel)
		and forest.tree_root_at(voxel) == Vector3i.MAX
	)


## Queues a furnish job for a bed anchored at [param voxel_position]: a
## unit fetches a crafted bed kit and unpacks it across the anchor and
## its second cell. Both cells carry plan markers, so they show under
## the Plans toggle and can't host another designation meanwhile.
func designate_bed(voxel_position: Vector3i) -> ColonyJob:
	var cells := bed_cells(voxel_position)
	if cells.size() != 2:
		return null
	var job := ColonyJob.new(ColonyJob.Type.FURNISH, voxel_position)
	job.furniture_kind = Building.Kind.BED
	job.extra_voxels = [cells[1]]
	_register_job(job)
	for cell in cells:
		_add_marker(cell, _build_marker_material, null, true)
	DLog.log("designated bed %s" % [cells])
	job_added.emit(job)
	return job


## A furnish job is done once its kit is delivered to the anchor: the
## building registers across its footprint and the delivered items are
## what deconstruction later hands back.
func complete_furnish(job: ColonyJob) -> void:
	var building := Building.new(job.furniture_kind, job.voxel_position)
	building.footprint.append_array(job.extra_voxels)
	building.components = job.components
	for cell in building.footprint:
		buildings[cell] = building
	_finish_job(job)


## True when a ladder occupies [param voxel_position] — the query the
## no-sim standability fallback and pile-capacity rule share.
func ladder_at(voxel_position: Vector3i) -> bool:
	var building := building_at(voxel_position)
	return building != null and building.kind == Building.Kind.LADDER


## Item capacity of a voxel: a cubic metre, or three quarters when a
## ladder shares the cell — it claims the rest of the space.
func voxel_capacity(voxel_position: Vector3i) -> int:
	return LADDER_PILE_CM3 if ladder_at(voxel_position) else DropItem.BLOCK_CM3


## Queues a ladder build at [param voxel_position]: a unit fetches three
## planks and assembles them in place. The cell is open air — a ladder
## shares its voxel with whatever already hangs or piles there, so a
## pile is allowed; the pile's capacity shrinks once the ladder stands.
func designate_ladder(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position) or buildings.has(voxel_position):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if forest.tree_root_at(voxel_position) != Vector3i.MAX:
		return null

	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = &"ladder"
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated ladder %s" % voxel_position)
	job_added.emit(job)
	return job


## A construct order's finish: the escrowed inputs become the building —
## the ladder records itself and claims the voxel's pathing edge in the
## sim. A pile sharing the cell just lost a quarter of its capacity.
func complete_construct(job: ColonyJob) -> void:
	var building := Building.new(RECIPES[job.recipe]["builds"], job.voxel_position)
	building.material = job.material
	building.components = job.components
	register_building(building)
	_enforce_capacity(job.voxel_position)
	_finish_job(job)


## The closest bed with no sleeper and no pending teardown, or null —
## a unit about to rest claims it by setting its `occupant`.
func nearest_free_bed(from: Vector3i) -> Building:
	var best: Building = null
	var best_sq := INF
	var seen := {}
	for cell in buildings:
		var bed: Building = buildings[cell]
		if (
			bed.kind != Building.Kind.BED
			or bed.occupant != null
			or seen.has(bed)
			or deconstruct_job_at(bed.voxel) != null
		):
			continue
		seen[bed] = true
		var sq := Vector3(cell - from).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = bed
	return best


## Queues a felling job for the tree containing [param voxel_position] —
## any part of it resolves to the root, which is what the unit chops.
func designate_chop(voxel_position: Vector3i) -> ColonyJob:
	var root := forest.tree_root_at(voxel_position)
	if root == Vector3i.MAX or _designation_markers.has(root):
		return null

	var job := ColonyJob.new(ColonyJob.Type.CHOP, root)
	_register_job(job)
	_add_marker(root, _marker_material)
	DLog.log("designated chop %s" % root)
	job_added.emit(job)
	return job


## A chop job's finish: the whole tree comes down — every part voxel is
## removed and its contents spilled as items where they stood.
func fell_tree(job: ColonyJob) -> void:
	forest.fell(job.voxel_position)
	_finish_job(job)


## A chop job whose tree vanished under the unit is simply done.
func complete_chop(job: ColonyJob) -> void:
	_finish_job(job)


## Queues a foraging job for the bush at [param voxel_position] — a unit
## strips its ripe yield and drops the food where it stands for hauling.
## Only a ripe bush can be designated; an unripe one bears again on its
## own clock (see plants.gd).
func designate_forage(voxel_position: Vector3i) -> ColonyJob:
	var root := plants.bush_at(voxel_position)
	if root == Vector3i.MAX or _designation_markers.has(root):
		return null
	if not plants.can_forage(root):
		return null

	var job := ColonyJob.new(ColonyJob.Type.FORAGE, root)
	_register_job(job)
	_add_marker(root, _forage_marker_material)
	DLog.log("designated forage %s" % root)
	job_added.emit(job)
	return job


## A forage job's finish: the bush's yield becomes physical food items at
## its cell — haulable like anything else.
func complete_forage(job: ColonyJob) -> void:
	for item in plants.forage(job.voxel_position):
		_drop_item(item, job.voxel_position)
	_finish_job(job)


## A sow job's finish: the fetched seed packet becomes an immature plant
## — a sapling for tree species, a bush otherwise. Planting turns the
## sod, so the grass under the cell dies. A cell that filled up in the
## meantime hands the packet back rather than eating it.
func complete_sow(job: ColonyJob, seed: DropItem) -> void:
	var cell := job.voxel_position
	var planted := false
	if Forest.SPECIES.has(job.species):
		planted = forest.plant_sapling(cell, job.species)
	else:
		planted = plants.plant(cell, job.species)
	if planted:
		if grass != null:
			grass.bare(cell + Vector3i.DOWN)
	elif seed != null:
		_drop_item(seed, cell)
	_finish_job(job)


## The voxel of the nearest pile holding a seed packet of
## [param species] — the sow job's fetch query. Seeds are species-tagged
## discrete items; an untagged or foreign packet doesn't count.
func nearest_seed_voxel(from: Vector3i, species: StringName) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in item_piles[voxel].items:
			if item.form == DropItem.Form.SEED and item.species == species:
				return _Match.FRESH
		return _Match.VETO)


## True when a seed packet of [param species] exists anywhere in the
## colony's piles — the farm's sow gate.
func _seed_exists(species: StringName) -> bool:
	for voxel: Vector3i in item_piles:
		for item in item_piles[voxel].items:
			if item.form == DropItem.Form.SEED and item.species == species:
				return true
	return false


## The periodic farm-field pass: for every field, post a sow job per
## cell that could take the assigned crop (gated on a seed packet
## existing anywhere), a forage job per ripe shrub, and — tree fields
## with auto-chop on — a chop job per mature in-field tree. Cells with
## a live farm job are left alone; finished ones drop out of the index.
func _farm_tick() -> void:
	var seen := {}
	for cell: Vector3i in farms:
		var field: FarmField = farms[cell]
		if seen.has(field):
			continue
		seen[field] = true
		_tick_field(field)


func _tick_field(field: FarmField) -> void:
	if field.species == &"":
		return
	var is_tree := Forest.SPECIES.has(field.species)
	var seeded := _seed_exists(field.species)
	for cell: Vector3i in field.cells:
		var job: ColonyJob = _farm_jobs.get(cell)
		if job != null:
			if job.is_active():
				# A sow waiting on a seed that vanished goes quiet
				# instead of churning through give-ups — the next
				# seeded scan wakes it.
				if job.type == ColonyJob.Type.SOW and job.suspended != not seeded:
					job.suspended = not seeded
					if world.sim != null:
						world.sim.job_suspend(
							job.get_instance_id(), job.suspended
						)
				continue
			_farm_jobs.erase(cell)
		if is_tree:
			# Only a tree rooted inside the field chops — canopy cells
			# belonging to a neighbour's tree are just occupied. An
			# occupied cell never sows; an empty one falls through to
			# the sow gate (which enforces the 3×3 spacing rule).
			var root := forest.tree_root_at(cell)
			if root != Vector3i.MAX:
				if (
					field.auto_chop and root == cell
					and forest.mature(root)
				):
					_farm_jobs[cell] = _post_farm_job(
						ColonyJob.Type.CHOP, root, field
					)
				continue
		else:
			var bush := plants.bush_at(cell)
			if bush != Vector3i.MAX:
				var rec: Dictionary = plants.bushes.get(bush, {})
				if (
					rec.get(&"species") == field.species
					and plants.can_forage(bush)
				):
					_farm_jobs[cell] = _post_farm_job(
						ColonyJob.Type.FORAGE, bush, field
					)
				continue
		if not seeded or not _sowable(cell, is_tree):
			continue
		_farm_jobs[cell] = _post_farm_job(ColonyJob.Type.SOW, cell, field)


## A farm-generated job: posted on the board like any other, but the
## zone's own marker stays — the job borrows the cell, it doesn't
## redesignate it.
func _post_farm_job(type: ColonyJob.Type, voxel: Vector3i, field: FarmField) -> ColonyJob:
	var job := ColonyJob.new(type, voxel)
	job.species = field.species
	_register_job(job)
	job_added.emit(job)
	return job


## Whether the farm cell can take a sowing right now: open air, no pile,
## no building, dirt underfoot — the sprout rules' soil requirement —
## and, for trees, the spacing rule: no plant in the cell or the eight
## around it, same as a fruit sprouting in the wild. Sowing is also
## gated on weather, light and soil fertility once those exist.
func _sowable(cell: Vector3i, is_tree: bool) -> bool:
	if not world.is_editable(cell):
		return false
	if world.get_block(cell) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(cell) > 0:
		return false
	if world.get_block(cell + Vector3i.DOWN) != BlockRegistry.Block.DIRT:
		return false
	if building_at(cell) != null:
		return false
	if is_tree:
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var n := cell + Vector3i(dx, 0, dz)
				if (
					forest.tree_root_at(n) != Vector3i.MAX
					or plants.bush_at(n) != Vector3i.MAX
				):
					return false
		return true
	return (
		forest.tree_root_at(cell) == Vector3i.MAX
		and plants.bush_at(cell) == Vector3i.MAX
	)


## The voxel of the nearest pile holding anything edible — where a hungry
## unit goes to eat. [param skip] blacklists recently-failed piles — an
## expired failure is only picked when no fresh pile is in reach.
func nearest_food_pile(from: Vector3i, skip: Dictionary = {}) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in item_piles[voxel].items:
			if not DropItem.is_food(item.material):
				continue
			var record: Dictionary = skip.get(voxel, {})
			if record.is_empty():
				return _Match.FRESH
			if now - int(record.get("at", 0)) < retry_delay_msec(record):
				return _Match.VETO
			return _Match.RETRY
		return _Match.VETO)


## The voxel of the nearest ripe bush with no job on it — where a
## starving unit goes when no edible pile exists. Player-designated
## bushes (marked) are left to their orders; desperation doesn't compete
## with designations. [param skip] blacklists recently-failed bushes the
## same way [member nearest_food_pile] skips piles. Linear over
## `plants.bushes` — desperation is rare, and the scaling note in
## PLAN.md already flags per-cell scans for a spatial index later.
func nearest_ripe_bush(from: Vector3i, skip: Dictionary = {}) -> Vector3i:
	var now := game_msec()
	var best := Vector3i.MAX
	var best_sq := INF
	var retry := Vector3i.MAX
	var retry_sq := INF
	for root: Vector3i in plants.bushes:
		if _designation_markers.has(root) or not plants.can_forage(root):
			continue
		var sq := (Vector3(root) - Vector3(from)).length_squared()
		var record: Dictionary = skip.get(root, {})
		if record.is_empty():
			if sq < best_sq:
				best = root
				best_sq = sq
		elif now - int(record.get("at", 0)) < retry_delay_msec(record):
			continue
		elif sq < retry_sq:
			retry = root
			retry_sq = sq
	return best if best != Vector3i.MAX else retry


## How long a dropped target stays off-limits: doubles with each
## consecutive failure ([param record] is {at: msec, n: drops}), capped —
## a permanently impossible target goes quiet instead of being hammered.
func retry_delay_msec(record: Dictionary) -> int:
	var attempts := int(record.get("n", 1))
	return mini(
		DROPPED_JOB_RETRY_MSEC * (1 << (attempts - 1)),
		DROPPED_JOB_RETRY_MAX_MSEC
	)


## The voxel of the nearest pile eligible for hauling — not fully admitted
## by its stockpile tile (a pile holding rejected items wants hauling
## away), not recently failed ([param skip] maps voxel → {at, n}).
## A pile the unit failed before comes last: it is only picked once its
## retry delay has elapsed and no fresh pile is in reach.
func nearest_haulable_pile(from: Vector3i, skip: Dictionary = {}) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		if item_piles[voxel].items.is_empty():
			return _Match.VETO
		if stockpiles.has(voxel) and not _pile_rejected_here(voxel):
			return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY)


## The nearest stockpile tile that can hold [param load] more cubic
## centimetres, or Vector3i.MAX. When [param materials] is given, a tile
## must admit at least one of them. [param skip] blacklists recently-failed
## tiles — an expired failure is only picked when no fresh tile is in reach.
func nearest_stockpile_with_room(
	from: Vector3i, load: int, skip: Dictionary = {}, materials: Array = []
) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(from, _stockpile_buckets, func(voxel: Vector3i) -> int:
		if voxel_fill(voxel) + load > voxel_capacity(voxel):
			return _Match.VETO
		if not materials.is_empty():
			var admits_any := false
			for material in materials:
				if stockpile_admits(voxel, material):
					admits_any = true
					break
			if not admits_any:
				return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY)


## Frees the pile at [param voxel_position] when it's been emptied, settling
## whatever may be piled on top.
func remove_pile_if_empty(voxel_position: Vector3i) -> void:
	var pile := item_pile_at(voxel_position)
	if pile != null and pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
		_settle_pile_at(voxel_position + Vector3i.UP)


## Mirrors the voxel's pile fill into the native sim so its fill-aware
## pathing and spill searches see the same occupancy — packed derives
## from fill >= a full cubic metre, no separate flag.
func _sync_sim_packed(voxel_position: Vector3i) -> void:
	if world.sim == null:
		return
	var pile: ItemPile = item_piles.get(voxel_position)
	world.sim.set_pile_fill(voxel_position, pile.total_volume() if pile != null else 0)


func _on_pile_fill_changed(pile: ItemPile) -> void:
	# An in-flight pile isn't keyed under its voxel yet; the resident pile
	# (if any) owns the packed state until it lands.
	if item_piles.get(pile.voxel_position) == pile:
		_sync_sim_packed(pile.voxel_position)
		# A shrinking pile can pull the floor out from under the pile
		# resting on it — re-settle the voxel above. No-op while the
		# floor still holds.
		_settle_pile_at(pile.voxel_position + Vector3i.UP)


## The voxel of the nearest pile holding material a wall can use —
## [param material] specifically, or any wall material when NONE.
## [param need] is the recipe still missing (form → cm³): only piles
## holding items the wall can still absorb qualify.
func nearest_wall_voxel(from: Vector3i, material: BlockRegistry.Resource_, need: Dictionary = {}) -> Vector3i:
	var want := need
	if want.is_empty() and material != BlockRegistry.Resource_.NONE:
		# No remaining-need passed: the wall wants its whole recipe.
		want = BlockRegistry.wall_recipe(material)
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		return _Match.FRESH if item_piles[voxel].wall_need_volume(material, want) > 0 else _Match.VETO)


## The voxel of the nearest pile holding an item of [param form] — the
## fetch query for a craft job's input.
func nearest_form_voxel(from: Vector3i, form: DropItem.Form) -> Vector3i:
	return nearest_forms_voxel(from, [form])


## The voxel of the nearest pile holding an item of any of [param forms]
## — the fetch query when a recipe still wants more than one kind of
## input.
func nearest_forms_voxel(from: Vector3i, forms: Array) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for form in forms:
			if item_piles[voxel].form_volume(form) > 0:
				return _Match.FRESH
		return _Match.VETO)


## True when anything is designated at [param voxel_position] — the cancel
## tool's validity check.
func is_designated(voxel_position: Vector3i) -> bool:
	return _designation_markers.has(voxel_position)


## Cancels the order queued at a worksite — the site itself stays.
## The panel's task-level cancel; the site goes away via deconstruct.
## Inputs the order already escrowed drop back at the spot.
func cancel_craft_order(voxel_position: Vector3i) -> void:
	var job := craft_job_at(voxel_position)
	if job == null:
		return
	# The running order leaves the queue too — cancelling just the job
	# would re-dispatch the same bill on the next scan.
	if job.order != null:
		var building: Building = buildings.get(voxel_position)
		if building != null:
			building.orders.erase(job.order)
	_cancel_job(job)


func cancel_designation(voxel_position: Vector3i) -> void:
	# Clicking any part of a designated tree cancels the chop job at its
	# root.
	var root := forest.tree_root_at(voxel_position)
	var target := root if root != Vector3i.MAX else voxel_position
	for job in jobs:
		if (
			job.is_active()
			and (
				job.voxel_position == target
				or job.extra_voxels.has(target)
			)
		):
			# Escrowed items — wall material, craft inputs — drop back
			# into the world rather than vanishing with the job.
			_return_escrow(job)
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
			for cell in job.extra_voxels:
				_remove_marker(cell)
			if job.voxel_position != target:
				# Clicked an extra cell — the anchor's marker goes too.
				_remove_marker(job.voxel_position)
	if stockpiles.erase(voxel_position):
		_index_remove(_stockpile_buckets, voxel_position)
	var field := farm_at(voxel_position)
	if field != null:
		field.cells.erase(voxel_position)
		farms.erase(voxel_position)
	var building: Building = buildings.get(target)
	if building != null:
		# A building is a construction, not a designation — the cancel
		# sweep only lifts its pending tasks (a craft order, a deconstruct
		# marking). The site itself comes down via deconstruct. Every
		# footprint cell's marker goes back — a deconstruct tint had
		# recolored them all.
		building.orders.clear()
		for cell in building.footprint:
			_restore_worksite_marker(cell)
	else:
		_remove_marker(target)
	_prune_jobs()


## Best-scoring open job for [param unit], claimed for it. A job the unit
## dropped before comes last: it is only claimable once its retry delay
## has elapsed and no other open job exists — a unit always tries a
## different job before retrying one it failed.
func claim_job(unit: Unit) -> ColonyJob:
	var now := game_msec()
	var type_scores := _claim_type_scores(unit)
	if world.sim != null:
		var job_id: int = world.sim.job_claim(
			unit.get_instance_id(), unit.global_position, now,
			DROPPED_JOB_RETRY_MSEC, DROPPED_JOB_RETRY_MAX_MSEC,
			type_scores, CLAIM_DIST_WEIGHT,
			CLAIM_LANGUISH_RATE, CLAIM_LANGUISH_CAP
		)
		var claimed: ColonyJob = _job_index.get(job_id)
		if claimed != null:
			claimed.state = ColonyJob.State.ASSIGNED
			claimed.assignee = unit
		return claimed
	var best: ColonyJob = null
	var best_score := INF
	var retry: ColonyJob = null
	var retry_score := INF
	for job in jobs:
		if not job.is_open():
			continue
		# Cooling off colony-wide: a job that keeps getting dropped backs
		# off for everyone, not just the unit that failed it.
		var global: Dictionary = job.dropped_by.get(0, {})
		if not global.is_empty() and now - int(global.get("at", 0)) < retry_delay_msec(global):
			continue
		var score := (
			Vector3(job.voxel_position).distance_to(unit.global_position)
			* CLAIM_DIST_WEIGHT
			- type_scores[job.type]
			- _languish_bonus(job, now)
		)
		var record: Dictionary = job.dropped_by.get(unit, {})
		if record.is_empty():
			if score < best_score:
				best_score = score
				best = job
			continue
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			continue
		if score < retry_score:
			retry_score = score
			retry = job
	var chosen := best if best != null else retry
	if chosen != null:
		chosen.state = ColonyJob.State.ASSIGNED
		chosen.assignee = unit
	return chosen


## Per-type skill bonus for [param unit] — metres-equivalent of distance
## each job type is worth to it, indexed by [constant ColonyJob.Type].
## Unskilled types score zero, and a specialist's weight dwarfs a
## generalist's.
func _claim_type_scores(unit: Unit) -> PackedFloat64Array:
	var weight := (
		CLAIM_SKILL_SPECIALIZE if unit.specialize else CLAIM_SKILL_GENERALIZE
	)
	var scores := PackedFloat64Array()
	scores.resize(ColonyJob.Type.size())
	var skill_types: Array = ColonyJob.SKILL_FOR.keys()
	for skill_type: ColonyJob.Type in skill_types:
		var skill: ColonyJob.Skill = ColonyJob.SKILL_FOR[skill_type]
		scores[skill_type] = weight * unit.skill_level(skill)
	return scores


## Metres-equivalent the job's age is worth — capped so a long-waiting
## job gets attractive but not infinitely so.
func _languish_bonus(job: ColonyJob, now: int) -> float:
	var age := maxf(now - job.posted_msec, 0.0) / 1000.0
	return minf(age, CLAIM_LANGUISH_CAP) * CLAIM_LANGUISH_RATE


func release_job(job: ColonyJob) -> void:
	if job.state == ColonyJob.State.ASSIGNED:
		var now := game_msec()
		var record: Dictionary = job.dropped_by.get(job.assignee, {})
		record["at"] = now
		record["n"] = int(record.get("n", 0)) + 1
		job.dropped_by[job.assignee] = record
		# A colony-wide drop record too: a job nobody can finish shouldn't
		# carousel between units — each failure backs it off for everyone.
		var global: Dictionary = job.dropped_by.get(0, {})
		global["at"] = now
		global["n"] = int(global.get("n", 0)) + 1
		job.dropped_by[0] = global
		if world.sim != null:
			world.sim.job_drop(
				job.get_instance_id(), job.assignee.get_instance_id(), now
			)
		job.state = ColonyJob.State.PENDING
		job.assignee = null


func complete_job(job: ColonyJob, mined_block_id: int) -> void:
	# A wall that gets dug out stops being a building — its recorded
	# components go to the generic shatter like everything else mined.
	var building: Building = buildings.get(job.voxel_position)
	if building != null:
		for cell in building.footprint:
			buildings.erase(cell)
			if building.kind == Building.Kind.LADDER and world.sim != null:
				world.sim.set_ladder(cell, false)
	else:
		buildings.erase(job.voxel_position)
	drop_block(mined_block_id, job.voxel_position)
	_finish_job(job)


## A clearing job is done once its voxel holds no pile.
func complete_clear(job: ColonyJob) -> void:
	_finish_job(job)


## A build job is done once the block is in place — it registers as a
## building, carrying the material class and the exact items that went
## in for deconstruction and material-tinted rendering.
func complete_build(job: ColonyJob) -> void:
	var building := Building.new(Building.Kind.WALL, job.voxel_position)
	building.block_id = job.block_id
	building.material = job.material
	building.components = job.components
	# A packed-dirt wall is indistinguishable from natural ground — it
	# has to be mined out like terrain, not taken apart.
	building.deconstructable = job.material != BlockRegistry.Resource_.SOIL
	register_building(building)
	_finish_job(job)


func _finish_job(job: ColonyJob) -> void:
	job.state = ColonyJob.State.DONE
	# Completing a job trains its discipline — the assignee is still
	# attached here (released on the next line). Unskilled types map to
	# -1 and earn nothing.
	var skill: int = ColonyJob.SKILL_FOR.get(job.type, -1)
	if skill >= 0 and job.assignee != null:
		job.assignee.gain_skill_xp(skill, ColonyJob.XP_FOR.get(job.type, 0.0))
	job.assignee = null
	# Every cell the job covered — a furnish plan's second cell included —
	# restores its building's standing look or drops its marker outright.
	for cell in [job.voxel_position] + job.extra_voxels:
		var building: Building = buildings.get(cell)
		if building != null:
			# The job is done but the construction stands — its marker
			# goes back to showing the building rather than the task.
			_restore_worksite_marker(cell)
		elif farms.has(cell):
			# Farm cells keep their zone marker — an auto job only
			# borrowed the cell, the field still owns it.
			pass
		else:
			_remove_marker(cell)
	job_finished.emit(job)
	_prune_jobs()


## Drops the loot of [param block_id] into the world as [ItemPile]s, letting
## each item spill into neighboring voxels that still have room.
func drop_block(block_id: int, voxel_position: Vector3i) -> void:
	for item in DropItem.for_block(block_id):
		_drop_item(item, voxel_position)


## Drops [param item] into [param voxel_position]. Part or all of it may spill
## into an adjacent voxel: the spill probability is the voxel's occupancy plus
## half the item's own volume. Loose items split proportionally — the spill
## fraction moves on — while solid items move whole. Moved items re-roll the
## same check at their new voxel, so drops settle downward and sideways.
func _drop_item(item: DropItem, voxel_position: Vector3i, hops: int = 0) -> void:
	if hops >= MAX_SPILL_HOPS:
		_deposit_item(item, voxel_position)
		return
	if item.form == DropItem.Form.LOOSE and item.volume < MIN_LOOSE_CM3:
		_deposit_item(item, voxel_position)
		return

	# The spill probability — a fraction of a voxel — while the moved
	# amount stays integer cm³.
	var spill := (voxel_fill(voxel_position) + item.volume / 2.0) / DropItem.CM3_PER_M3
	var target := _spill_target(voxel_position)
	if item.form == DropItem.Form.LOOSE:
		var moved := 0 if target == voxel_position else int(minf(spill, 1.0) * item.volume)
		var kept := item.volume - moved
		if kept > 0:
			var kept_item := DropItem.new(item.material, item.form, kept)
			kept_item.species = item.species
			_deposit_item(kept_item, voxel_position)
		if moved > 0:
			item.volume = moved
			_drop_item(item, target, hops + 1)
	elif randf() < spill and target != voxel_position:
		_drop_item(item, target, hops + 1)
	else:
		_deposit_item(item, voxel_position)


## The voxel an item spills into: straight down if it has room, otherwise any
## of the four orthogonal sides. Returns the voxel itself when every neighbor
## is fully occupied, in which case the item just squeezes in where it is.
func _spill_target(voxel_position: Vector3i) -> Vector3i:
	if world.sim != null:
		return world.sim.spill_target(voxel_position)
	var below := voxel_position + Vector3i.DOWN
	if not is_packed(below):
		return below
	var sides := SPILL_SIDES.duplicate()
	sides.shuffle()
	for side in sides:
		var neighbor: Vector3i = voxel_position + side
		if not is_packed(neighbor):
			return neighbor
	return voxel_position


## Portion of [param voxel_position]'s space occupied in cubic centimetres:
## a full cubic metre when the voxel holds a solid block, otherwise the
## volume of the items piled in it.
func voxel_fill(voxel_position: Vector3i) -> int:
	if world.sim != null:
		return int(world.sim.fill_of(voxel_position))
	if world.is_solid(voxel_position):
		return DropItem.BLOCK_CM3
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile.total_volume() if pile != null else 0


## True when the voxel is effectively solid — a real block or packed with a
## full cubic metre of items. Packed voxels are impassible to units and act
## as a floor for anything falling or standing above them.
func is_packed(voxel_position: Vector3i) -> bool:
	if world.sim != null:
		return world.sim.is_blocked(voxel_position)
	if world.is_solid(voxel_position):
		return true
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile != null and pile.is_full(voxel_capacity(voxel_position))


func _deposit_item(item: DropItem, voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		pile = ItemPile.create(voxel_position, world.sim == null)
		add_child(pile)
		pile.landed.connect(_on_pile_landed)
		pile.fill_changed.connect(_on_pile_fill_changed)
		item_piles[voxel_position] = pile
		_index_add(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		item_dropped.emit(pile)
	pile.add_item(item)
	_settle_pile_at(voxel_position)
	_enforce_capacity(pile.voxel_position)


## True when [param voxel_position] acts as a floor for something falling
## onto it: packed solid, or holding a pile the incoming material can't
## merge into. Loose material ([param splittable]) can always pour into a
## pile that has any room left — the surplus overflows back onto it — but
## an unsplittable item that doesn't fit must rest on top, or it would
## fall in, overfill the pile and be pushed straight back out forever.
func _is_floor_for(voxel_position: Vector3i, volume: int, splittable: bool) -> bool:
	if is_packed(voxel_position):
		return true
	var resident: ItemPile = item_piles.get(voxel_position)
	if resident == null:
		return false
	if splittable:
		return false
	return resident.total_volume() + volume > voxel_capacity(voxel_position)


## The voxel an [param item] dropped at [param voxel_position] would
## actually come to rest in: the lowest voxel in its column whose floor
## supports it — the same walk [method _settle_pile_at] performs.
func _settle_floor(voxel_position: Vector3i, item: DropItem) -> Vector3i:
	var splittable := item.form == DropItem.Form.LOOSE
	if world.sim != null:
		return world.sim.settle_floor(voxel_position, item.volume, splittable)
	var landing := voxel_position
	var below := landing + Vector3i.DOWN
	while world.is_editable(below) and not _is_floor_for(below, item.volume, splittable):
		landing = below
		below = landing + Vector3i.DOWN
	return landing


## The nearest voxel that can hold [param item] without overfilling —
## [param needed] is the volume that must fit (the item's whole volume for
## a solid, or the surplus for a loose item). Adjoining voxels are tried
## first in the usual order (below, emptiest side, above); when none can
## take it the search expands outward from the voxel above. A boulder
## that won't fit a 95%-full hole can't just be pushed onto the voxel
## above — it would settle straight back down and bounce forever — so
## every candidate is judged by the voxel it would settle in, and landings
## back in the source voxel don't count. Packed candidates are skipped
## outright — an item can't be dropped into a solid block or full pile —
## and don't expand the outward search, so items can't tunnel under an
## obstacle into a pocket beneath it. Returns [constant Vector3i.MAX]
## when nothing has room (a loose item may return a nearer partial fit).
func _accepting_voxel(item: DropItem, voxel_position: Vector3i, needed := -1) -> Vector3i:
	if world.sim != null:
		return world.sim.accepting_voxel(
			voxel_position, item.volume, item.form == DropItem.Form.LOOSE, needed
		)
	# The volume that has to fit: a solid item needs its whole volume; a
	# loose item only needs what will actually move (the surplus), and can
	# settle for less — a fragment still moves.
	var want := mini(item.volume, needed) if needed >= 0 else mini(item.volume, voxel_capacity(voxel_position))
	var partial := Vector3i.MAX
	# Adjoining voxels first, in preference order — below, emptiest side,
	# then straight up — each judged by where the item would settle.
	var neighbors: Array[Vector3i] = [voxel_position + Vector3i.DOWN]
	var sides := SPILL_SIDES.duplicate()
	sides.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return (
				voxel_fill(voxel_position + a) < voxel_fill(voxel_position + b)
			)
	)
	for side in sides:
		neighbors.append(voxel_position + side)
	neighbors.append(voxel_position + Vector3i.UP)
	for candidate in neighbors:
		# A packed voxel can't be entered at all — an item dropped "into" it
		# would materialise inside the block or full pile, and _settle_floor
		# would happily land it in any open pocket underneath, tunnelling
		# the item through the obstacle.
		if is_packed(candidate):
			continue
		var landing := _settle_floor(candidate, item)
		if landing == voxel_position:
			continue
		var room := voxel_capacity(landing) - voxel_fill(landing)
		if room >= want:
			return landing
		if (
			partial == Vector3i.MAX
			and item.form == DropItem.Form.LOOSE
			and room > MIN_LOOSE_CM3
		):
			partial = landing
	# Nothing adjoining can take it — expand outward from the voxel above.
	var visited := {voxel_position: true}
	var queue: Array[Vector3i] = [voxel_position + Vector3i.UP]
	var head := 0
	while head < queue.size() and head < 4096:
		var candidate := queue[head]
		head += 1
		if visited.has(candidate):
			continue
		visited[candidate] = true
		# Packed voxels are walls to the search too: the item can't enter or
		# pass through one, so the cell doesn't expand the frontier — the
		# voxel on top of the obstacle is reached from the cells above it.
		if is_packed(candidate):
			continue
		var landing := _settle_floor(candidate, item)
		# A candidate that would settle back into the source can't accept the
		# item, but the search still expands through it — the rim of a hole is
		# only reachable past the cell above the hole.
		if landing != voxel_position:
			var room := voxel_capacity(landing) - voxel_fill(landing)
			if room >= want:
				return landing
			if (
				partial == Vector3i.MAX
				and item.form == DropItem.Form.LOOSE
				and room > MIN_LOOSE_CM3
			):
				partial = landing
		for side in SPILL_SIDES:
			queue.append(candidate + side)
		queue.append(candidate + Vector3i.UP)
		queue.append(candidate + Vector3i.DOWN)
	return partial


## Voxels mid-spill (re-entrancy guard) and already-spilled in this
## cascade — a pile may spill at most once per cascade, which is what
## stops a two-pile ping-pong from shuttling the same surplus forever.
var _enforcing := {}
var _enforced := {}


## A pile must never hold more than a cubic metre: split the excess off —
## smallest items first, cutting loose items down so only the surplus
## leaves — and move it to the nearest voxel that can accept it. Only when
## nowhere nearby has room does the surplus squeeze in anyway.
func _enforce_capacity(voxel_position: Vector3i) -> void:
	if _enforced.has(voxel_position):
		return
	_enforced[voxel_position] = true
	_enforcing[voxel_position] = true
	var moved := 0
	var capacity := voxel_capacity(voxel_position)
	for _i in 64:
		var pile: ItemPile = item_piles.get(voxel_position)
		if pile == null or pile.total_volume() <= capacity:
			break
		var excess := pile.total_volume() - capacity
		var item := pile.smallest_item()
		if item == null:
			break
		var needed := item.volume
		if item.form == DropItem.Form.LOOSE:
			needed = mini(item.volume, excess)
		# The pile keeps its contents while the excess searches for a landing:
		# an over-full voxel still counts as packed, so the cell above a
		# buried pile reads as resting on it rather than settling back into
		# the hole.
		var target := _accepting_voxel(item, voxel_position, needed)
		if target == Vector3i.MAX:
			break
		moved += 1
		item = pile.take_smallest()
		if item.form == DropItem.Form.LOOSE:
			var room := voxel_capacity(target) - voxel_fill(target)
			var moving := mini(excess, mini(item.volume, room))
			item.volume -= moving
			if item.volume > 0:
				pile.add_item(item, false)
			_deposit_item(DropItem.new(item.material, item.form, moving), target)
		else:
			_deposit_item(item, target)
	if moved >= 64:
		DLog.log(
			"enforce_capacity at %s capped after %d spills" % [voxel_position, moved]
		)
	_enforcing.erase(voxel_position)
	if _enforcing.is_empty():
		_enforced.clear()


## Mining removes the floor under whatever was piled above it: let it fall.
func _on_block_mined(position: Vector3i, _block_id: int) -> void:
	_settle_pile_at(position + Vector3i.UP)


## Collapse is "deconstruct as if mined": the cell's jobs and building
## record die with the block, the mined rubble drops where it stood, and
## whatever was piled on top falls.
func _on_block_collapsed(cell: Vector3i, block_id: int) -> void:
	var building: Building = buildings.get(cell)
	if building != null:
		# Erase the record first so the cancel pass below clears the
		# cell's markers instead of restoring the construction's.
		for bc in building.footprint:
			buildings.erase(bc)
	cancel_designation(cell)
	drop_block(block_id, cell)
	_settle_pile_at(cell + Vector3i.UP)


## A successful placement may be the support a suspended build was
## waiting on — check the six adjacent cells for held plans and put them
## back on the board.
func _on_block_placed(position: Vector3i, _block_id: int) -> void:
	for side in [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN,
		Vector3i.UP, Vector3i.BACK, Vector3i.FORWARD,
	]:
		var job := plan_job_at(position + side)
		if job != null and job.suspended:
			job.suspended = false
			if world.sim != null:
				world.sim.job_suspend(job.get_instance_id(), false)


## A streamed-in chunk can also be the missing support — a suspended
## plan near the frontier gets re-checked whenever new terrain arrives.
func _on_world_block_loaded(_block_origin: Vector3i) -> void:
	for job in jobs:
		if job.suspended and would_be_supported(job.voxel_position):
			job.suspended = false
			if world.sim != null:
				world.sim.job_suspend(job.get_instance_id(), false)


## Would a block placed at [param voxel_position] stand? A cell at the
## base level anchors itself; otherwise one solid face-neighbour is a
## full proof, since every standing solid is already anchored — the
## collapse rule removes any that aren't. Piles and ladders don't bear
## load; only blocks do.
func would_be_supported(voxel_position: Vector3i) -> bool:
	if voxel_position.y <= world.generator_script.bedrock_height:
		return true
	for side in [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN,
		Vector3i.UP, Vector3i.BACK, Vector3i.FORWARD,
	]:
		if world.is_solid(voxel_position + side):
			return true
	return false


## Suspends a build job on an unsupported cell: the designation marker
## stays up (the plan is still wanted), the escrowed material stays with
## the job, and the job leaves the claimable pool until a neighbouring
## placement lifts the flag.
func suspend_build_job(job: ColonyJob) -> void:
	job.suspended = true
	job.state = ColonyJob.State.PENDING
	job.assignee = null
	if world.sim != null:
		world.sim.job_suspend(job.get_instance_id(), true)
	DLog.log("build at %s suspended — unsupported" % job.voxel_position)


## Lets the pile at [param voxel_position] fall through open space until it
## rests on solid ground. The logical voxel moves at once; the pile node
## falls visually and merges into whatever pile it lands on. Stops at the
## edge of loaded terrain rather than letting items drop into the void.
func _settle_pile_at(voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		return
	var splittable := true
	for item in pile.items:
		if item.form != DropItem.Form.LOOSE:
			splittable = false
			break
	var landing := voxel_position
	if world.sim != null:
		landing = world.sim.settle_floor(voxel_position, pile.total_volume(), splittable)
	else:
		var below := landing + Vector3i.DOWN
		while world.is_editable(below) and not _is_floor_for(
			below, pile.total_volume(), splittable
		):
			landing = below
			below = landing + Vector3i.DOWN
	if landing == voxel_position:
		return
	item_piles.erase(voxel_position)
	_index_remove(_pile_buckets, voxel_position)
	_sync_sim_packed(voxel_position)
	pile.voxel_position = landing
	if item_piles.has(landing):
		# The landing voxel is claimed: keep this pile unkeyed until it
		# arrives, then merge it in.
		_in_flight.append(pile)
	else:
		item_piles[landing] = pile
		_index_add(_pile_buckets, landing)
		_sync_sim_packed(landing)
	pile.fall_to(float(landing.y))
	if world.sim != null:
		world.sim.pile_fall_start(
				pile.get_instance_id(), pile.position.y, float(landing.y),
				pile._fall_speed)
	# This pile just vacated its voxel — whatever rested on that voxel
	# lost its floor and may need to follow it down the column.
	_settle_pile_at(voxel_position + Vector3i.UP)


## A falling pile reached its voxel: fold it into the pile already there,
## or claim the voxel if it is empty — re-settling in case the floor gave
## out while it fell. Landing is reported by DelveSim.tick and (for
## presentation nodes) by the pile's own fall animation — whichever fires
## second is absorbed by the guard.
func _on_pile_landed(pile: ItemPile) -> void:
	if not is_instance_valid(pile) or pile.merged:
		return
	_in_flight.erase(pile)
	var resident: ItemPile = item_piles.get(pile.voxel_position)
	if resident == pile:
		return
	if resident != null:
		resident.add_items(pile.items, false)
		pile.merged = true
		pile.queue_free()
		_enforce_capacity(resident.voxel_position)
		return
	item_piles[pile.voxel_position] = pile
	_index_add(_pile_buckets, pile.voxel_position)
	_sync_sim_packed(pile.voxel_position)
	_settle_pile_at(pile.voxel_position)
	_enforce_capacity(pile.voxel_position)


## Shoves a blocking pile aside: moves items out of a packed voxel into
## neighbouring voxels until it no longer fills the cell — a unit digs through
## a pile that blocks its path. Returns false when the pile stays packed
## because no neighbour has room.
func shove_pile(voxel_position: Vector3i) -> bool:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		return true
	var capacity := voxel_capacity(voxel_position)
	while pile.is_full(capacity):
		var item := pile.take_smallest()
		if item == null:
			break
		if _move_item_to(pile, item, voxel_position) == null:
			break
	if pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
	# Items piled above the cleared voxel may hover now — let them fall in.
	_settle_pile_at(voxel_position + Vector3i.UP)
	return not is_packed(voxel_position)


## Moves one item — the smallest — out of the pile at [param voxel_position]
## to the nearest voxel that can accept it. Returns the moved item, or null
## when the pile is empty or nowhere has room.
func move_pile_item(voxel_position: Vector3i) -> DropItem:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null or pile.items.is_empty():
		return null
	var item := pile.take_smallest()
	var moved := _move_item_to(pile, item, voxel_position)
	if pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
		_settle_pile_at(voxel_position + Vector3i.UP)
	return moved


## Moves [param item] — or the part of it that fits — from [param pile] at
## [param voxel_position] to the nearest voxel with room for it. A loose
## item splits when only a partial fit is available; a solid item moves
## whole or not at all. Returns the moved piece, or null when nowhere has
## room (the item is put back).
func _move_item_to(
	pile: ItemPile, item: DropItem, voxel_position: Vector3i
) -> DropItem:
	var target := _accepting_voxel(item, voxel_position)
	if target == Vector3i.MAX:
		pile.add_item(item, false)
		return null
	var room := voxel_capacity(target) - voxel_fill(target)
	var moved := item
	if item.form == DropItem.Form.LOOSE and item.volume > room:
		moved = DropItem.new(item.material, item.form, room)
		item.volume -= room
		pile.add_item(item, false)
	_deposit_item(moved, target)
	return moved


func item_pile_at(voxel_position: Vector3i) -> ItemPile:
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile


## Everything piled on stockpile tiles, tallied for the resources list —
## one entry per material class and item form: `{"material": r, "form": f,
## "count": n, "cm3": v}`.
func stockpile_contents() -> Array[Dictionary]:
	var tallies := {}
	for voxel in stockpiles:
		var pile := item_pile_at(voxel)
		if pile == null:
			continue
		for item in pile.items:
			# Species matters: oak and berry-bush seed packets are
			# different goods sharing one material+form.
			var key := "%d:%d:%s" % [
				int(item.material), int(item.form), item.species
			]
			var entry: Dictionary = tallies.get(
				key,
				{
					"material": item.material, "form": item.form,
					"species": item.species,
					"count": 0, "cm3": 0,
				}
			)
			entry["count"] += 1
			entry["cm3"] += item.volume
			tallies[key] = entry
	var contents: Array[Dictionary] = []
	for entry in tallies.values():
		contents.append(entry)
	contents.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var ka := int(a["material"]) * 64 + int(a["form"])
			var kb := int(b["material"]) * 64 + int(b["form"])
			if ka != kb:
				return ka < kb
			return String(a["species"]) < String(b["species"])
	)
	return contents


func open_job_count() -> int:
	var count := 0
	for job in jobs:
		if job.is_active():
			count += 1
	return count


## Drops units on solid ground around [param origin].
func spawn_initial_units(origin: Vector3i) -> void:
	for i in initial_units:
		var angle := TAU * float(i) / float(maxi(initial_units, 1))
		var offset := Vector3i(int(cos(angle) * spawn_radius), 0, int(sin(angle) * spawn_radius))
		spawn_unit(origin + offset)


func spawn_unit(near_voxel: Vector3i) -> Unit:
	var ground_y := world.ground_height(near_voxel.x, near_voxel.z, near_voxel.y + 32)
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.name = "Unit%d" % (units.size() + 1)
	add_child(unit)
	unit.global_position = Vector3(near_voxel.x + 0.5, ground_y + 1.5, near_voxel.z + 0.5)
	unit.setup(world, self)
	unit.state_changed.connect(_on_unit_state_changed.bind(unit))
	units.append(unit)
	DLog.log("unit %d spawned at %s" % [unit.get_instance_id(), unit.global_position])
	unit_spawned.emit(unit)
	return unit


func _add_marker(
	voxel_position: Vector3i,
	material: StandardMaterial3D,
	mesh: Mesh = null,
	plan := false
) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = mesh if mesh != null else _marker_mesh
	marker.material_override = material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	marker.visible = _plan_visible() if plan else markers_visible
	add_child(marker)
	_designation_markers[voxel_position] = marker
	if plan:
		_plan_voxels[voxel_position] = true


## Whether plan markers render — the HUD toggle or a planning tool in
## hand both count.
func plans_visible() -> bool:
	return _plan_visible()


## The HUD's Plans toggle.
func set_plans_visible_manual(value: bool) -> void:
	plans_visible_manual = value
	_update_plan_visibility()


## A planning tool (a wall action or deconstruct) auto-shows plans.
func set_plans_tool_active(value: bool) -> void:
	_plans_tool_active = value
	_update_plan_visibility()


func _plan_visible() -> bool:
	return plans_visible_manual or _plans_tool_active


func _update_plan_visibility() -> void:
	for voxel: Vector3i in _plan_voxels:
		_designation_markers[voxel].visible = _plan_visible()


## Shows or hides every designation marker — the zones display toggle.
func set_markers_visible(value: bool) -> void:
	markers_visible = value
	for voxel: Vector3i in _designation_markers:
		if not _plan_voxels.has(voxel):
			_designation_markers[voxel].visible = value


func _remove_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _designation_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_designation_markers.erase(voxel_position)
		_plan_voxels.erase(voxel_position)


## Puts a building's marker back to showing the building itself — the
## worksite outline, a bed's low slab, or filled with the queued-order
## look while an order runs. Walls keep no standing marker at all.
func _restore_worksite_marker(voxel_position: Vector3i) -> void:
	var building: Building = buildings.get(voxel_position)
	if building == null or building.kind == Building.Kind.WALL:
		_remove_marker(voxel_position)
		return
	# The cell's marker now shows the standing building, not a plan —
	# the Plans toggle must stop driving it.
	_plan_voxels.erase(voxel_position)
	if building.kind == Building.Kind.BED:
		_set_marker_appearance(voxel_position, _bed_marker_material, _bed_mesh)
		var marker: MeshInstance3D = _designation_markers.get(voxel_position)
		if marker != null:
			# The slab sits on the cell floor, not the voxel centre.
			marker.position.y = voxel_position.y + _bed_mesh.size.y * 0.5
			marker.visible = true
		return
	if building.kind == Building.Kind.LADDER:
		# A pole filling the cell — freestanding and wall-attached look
		# alike until real rendering exists.
		_set_marker_appearance(voxel_position, _ladder_marker_material, _ladder_mesh)
		var pole: MeshInstance3D = _designation_markers.get(voxel_position)
		if pole != null:
			pole.visible = true
		return
	if craft_job_at(voxel_position) != null:
		_set_marker_appearance(voxel_position, _craft_job_marker_material, _marker_mesh)
	else:
		_set_marker_appearance(voxel_position, _craft_spot_marker_material, _outline_mesh)


## Recolors and reshapes the marker at [param voxel_position] — craft
## spots tint to show a queued order without gaining a second marker.
func _set_marker_appearance(
	voxel_position: Vector3i, material: StandardMaterial3D, mesh: Mesh
) -> void:
	var marker: MeshInstance3D = _designation_markers.get(voxel_position)
	if marker == null:
		return
	marker.material_override = material
	marker.mesh = mesh


func _prune_jobs() -> void:
	for job in jobs:
		if not job.is_active():
			_unregister_job(job)
	jobs = jobs.filter(func(job: ColonyJob) -> bool: return job.is_active())
	for cell: Vector3i in _farm_jobs.keys():
		if not _farm_jobs[cell].is_active():
			_farm_jobs.erase(cell)


## Adds a job to the list, the id index and the native board.
func _register_job(job: ColonyJob) -> void:
	jobs.append(job)
	_job_index[job.get_instance_id()] = job
	job.posted_msec = game_msec()
	if world.sim != null:
		world.sim.job_add(
			job.get_instance_id(), job.voxel_position, job.type,
			job.posted_msec
		)


## Drops a job from the id index and the native board. Pruning keeps the
## list itself; this only tears down the mirrors.
func _unregister_job(job: ColonyJob) -> void:
	_job_index.erase(job.get_instance_id())
	if world.sim != null:
		world.sim.job_remove(job.get_instance_id())


## ---------------------------------------------------------------------------
## Persistence — the colony is a Site's payload inside the Region save.
## Everything serializes to plain JSON-safe data (ints, floats, strings,
## arrays, dictionaries); Vector3i rows are [x, y, z], items come through
## DropItem.serialize.
## ---------------------------------------------------------------------------

static func _v3i_data(voxel: Vector3i) -> Array:
	return [voxel.x, voxel.y, voxel.z]


static func _v3i(data: Array) -> Vector3i:
	return Vector3i(int(data[0]), int(data[1]), int(data[2]))


static func _items_data(items: Array[DropItem]) -> Array:
	var out: Array = []
	for item in items:
		out.append(item.serialize())
	return out


static func _items_from(data: Array) -> Array[DropItem]:
	var out: Array[DropItem] = []
	for e: Array in data:
		out.append(DropItem.deserialize(e))
	return out


## The site's save record — every piece of live state a reload must
## rebuild. Terrain deltas aren't here; they live on the region's edit
## log (the write-side record) which the world replays as blocks stream.
func serialize() -> Dictionary:
	var pile_list: Array = []
	var seen_piles := {}
	for voxel: Vector3i in item_piles:
		var pile: ItemPile = item_piles[voxel]
		seen_piles[pile] = true
		pile_list.append(
			{"voxel": _v3i_data(voxel), "items": _items_data(pile.items)}
		)
	for pile: ItemPile in _in_flight:
		# A falling pile is keyed to its landing voxel already — saved
		# as landed; restoring it there is the same end state.
		if not seen_piles.has(pile):
			pile_list.append(
				{
					"voxel": _v3i_data(pile.voxel_position),
					"items": _items_data(pile.items),
				}
			)
	var building_list: Array = []
	var seen_buildings := {}
	for cell: Vector3i in buildings:
		var building: Building = buildings[cell]
		if seen_buildings.has(building):
			continue
		seen_buildings[building] = true
		building_list.append(_building_data(building))
	var job_list: Array = []
	for job in jobs:
		if job.desperate or not job.is_active():
			# Self-issued work re-derives from the unit's needs; done and
			# cancelled jobs are already out of the flow.
			continue
		job_list.append(_job_data(job))
	var stockpile_list: Array = []
	for voxel: Vector3i in stockpiles:
		stockpile_list.append(
			{"voxel": _v3i_data(voxel), "rejected": stockpiles[voxel].keys()}
		)
	var farm_list: Array = []
	var seen_farms := {}
	for cell: Vector3i in farms:
		var field: FarmField = farms[cell]
		if seen_farms.has(field):
			continue
		seen_farms[field] = true
		var cells: Array = []
		for c: Vector3i in field.cells:
			cells.append(_v3i_data(c))
		farm_list.append(
			{
				"species": String(field.species),
				"auto_chop": field.auto_chop,
				"cells": cells,
			}
		)
	var unit_list: Array = []
	for unit in units:
		unit_list.append(unit.serialize())
	return {
		"needs_enabled": needs_enabled,
		"selected_speed": _selected_speed,
		"sleep_boost": sleep_boost,
		"paused": get_tree().paused,
		"units": unit_list,
		"piles": pile_list,
		"buildings": building_list,
		"jobs": job_list,
		"stockpiles": stockpile_list,
		"farms": farm_list,
		"plants": plants.serialize(),
		"forest": forest.serialize(),
		"grass": grass.serialize(),
	}


## Rebuilds the site from its save record — clears live state, then
## restores in dependency order: buildings (markers, ladders, orders),
## designations, decoration records, piles, jobs, and finally units
## whose bed links resolve into the restored buildings.
func deserialize(data: Dictionary) -> void:
	_clear_colony_state()
	needs_enabled = bool(data.get("needs_enabled", true))
	for bd: Dictionary in data.get("buildings", []):
		_load_building(bd)
	for sd: Dictionary in data.get("stockpiles", []):
		var voxel := _v3i(sd["voxel"])
		var rejected := {}
		for m in sd.get("rejected", []):
			rejected[int(m)] = true
		stockpiles[voxel] = rejected
		_index_add(_stockpile_buckets, voxel)
		_add_marker(voxel, _stockpile_marker_material, _outline_mesh)
	for fd: Dictionary in data.get("farms", []):
		var field := FarmField.new()
		field.species = StringName(fd.get("species", ""))
		field.auto_chop = bool(fd.get("auto_chop", false))
		for c: Array in fd.get("cells", []):
			var cell := _v3i(c)
			field.cells[cell] = true
			farms[cell] = field
			_add_marker(cell, _farm_marker_material, _outline_mesh)
	plants.deserialize(data.get("plants", {}))
	forest.deserialize(data.get("forest", {}))
	grass.deserialize(data.get("grass", {}))
	for pd: Dictionary in data.get("piles", []):
		_load_pile(_v3i(pd["voxel"]), _items_from(pd.get("items", [])))
	for jd: Dictionary in data.get("jobs", []):
		_load_job(jd)
	for ud: Dictionary in data.get("units", []):
		_load_unit(ud)
	_selected_speed = float(data.get("selected_speed", 1.0))
	sleep_boost = bool(data.get("sleep_boost", false))
	set_paused(bool(data.get("paused", false)))


## Wipes live colony state for a deserialize — every job off the board,
## every marker gone, every pile and unit freed, every zone emptied.
## The subsystems' own deserializes clear their records themselves.
func _clear_colony_state() -> void:
	for job in jobs:
		if job.is_active():
			_unregister_job(job)
	jobs.clear()
	_job_index.clear()
	_farm_jobs.clear()
	for voxel: Vector3i in _designation_markers:
		_designation_markers[voxel].queue_free()
	_designation_markers.clear()
	_plan_voxels.clear()
	var pile_voxels: Array = item_piles.keys()
	for pile: ItemPile in item_piles.values():
		pile.queue_free()
	for pile: ItemPile in _in_flight:
		pile.queue_free()
	item_piles.clear()
	_in_flight.clear()
	_pile_buckets.clear()
	if world.sim != null:
		for voxel: Vector3i in pile_voxels:
			world.sim.set_pile_fill(voxel, 0)
	for cell: Vector3i in buildings:
		var building: Building = buildings[cell]
		if building.kind == Building.Kind.LADDER and world.sim != null:
			world.sim.set_ladder(cell, false)
	buildings.clear()
	stockpiles.clear()
	_stockpile_buckets.clear()
	farms.clear()
	for unit in units:
		unit.queue_free()
	units.clear()
	_sleeping.clear()


func _building_data(building: Building) -> Dictionary:
	var orders: Array = []
	for order in building.orders:
		orders.append(
			{
				"recipe": String(order.recipe),
				"condition": int(order.condition),
				"target": order.target,
				"done": order.done,
			}
		)
	var footprint: Array = []
	for cell in building.footprint:
		footprint.append(_v3i_data(cell))
	return {
		"kind": int(building.kind),
		"voxel": _v3i_data(building.voxel),
		"footprint": footprint,
		"block_id": building.block_id,
		"material": int(building.material),
		"deconstructable": building.deconstructable,
		"components": _items_data(building.components),
		"orders": orders,
	}


func _load_building(bd: Dictionary) -> void:
	var building := Building.new(int(bd["kind"]), _v3i(bd["voxel"]))
	building.footprint.clear()
	for c: Array in bd.get("footprint", []):
		building.footprint.append(_v3i(c))
	building.block_id = int(bd.get("block_id", BlockRegistry.Block.AIR))
	building.material = int(bd.get("material", BlockRegistry.Resource_.NONE))
	building.deconstructable = bool(bd.get("deconstructable", true))
	building.components = _items_from(bd.get("components", []))
	for od: Dictionary in bd.get("orders", []):
		var order := WorksiteOrder.new()
		order.recipe = StringName(od.get("recipe", ""))
		order.condition = int(od.get("condition", 0))
		order.target = int(od.get("target", 1))
		order.done = int(od.get("done", 0))
		building.orders.append(order)
	register_building(building)
	if building.kind == Building.Kind.WALL:
		return
	# A marker first, then the kind's standing appearance — the same end
	# state _restore_worksite_marker settles into after a build.
	_add_marker(building.voxel, _craft_spot_marker_material, _outline_mesh)
	_restore_worksite_marker(building.voxel)


func _job_data(job: ColonyJob) -> Dictionary:
	var delivered: Array = []
	for form in job.delivered:
		delivered.append([int(form), int(job.delivered[form])])
	var extra: Array = []
	for cell in job.extra_voxels:
		extra.append(_v3i_data(cell))
	var order_index := -1
	if job.order != null:
		var building: Building = buildings.get(job.voxel_position)
		if building != null:
			order_index = building.orders.find(job.order)
	return {
		"type": int(job.type),
		"voxel": _v3i_data(job.voxel_position),
		"progress": job.progress,
		"block_id": job.block_id,
		"material": int(job.material),
		"delivered": delivered,
		"components": _items_data(job.components),
		"recipe": String(job.recipe),
		"species": String(job.species),
		"furniture_kind": int(job.furniture_kind),
		"extra_voxels": extra,
		"suspended": job.suspended,
		"posted_msec": job.posted_msec,
		"order": order_index,
	}


func _load_job(jd: Dictionary) -> void:
	var job := ColonyJob.new(int(jd["type"]), _v3i(jd["voxel"]))
	job.progress = float(jd.get("progress", 0.0))
	job.block_id = int(jd.get("block_id", BlockRegistry.Block.DIRT))
	job.material = int(jd.get("material", BlockRegistry.Resource_.NONE))
	for pair: Array in jd.get("delivered", []):
		job.delivered[int(pair[0])] = int(pair[1])
	job.components = _items_from(jd.get("components", []))
	job.recipe = StringName(jd.get("recipe", ""))
	job.species = StringName(jd.get("species", ""))
	job.furniture_kind = int(jd.get("furniture_kind", 0))
	for e: Array in jd.get("extra_voxels", []):
		job.extra_voxels.append(_v3i(e))
	var order_index := int(jd.get("order", -1))
	if order_index >= 0:
		var building: Building = buildings.get(job.voxel_position)
		if building != null and order_index < building.orders.size():
			job.order = building.orders[order_index]
	_register_job(job)
	job.posted_msec = int(jd.get("posted_msec", job.posted_msec))
	if bool(jd.get("suspended", false)):
		job.suspended = true
		if world.sim != null:
			world.sim.job_suspend(job.get_instance_id(), true)
	_restore_job_marker(job)


## Rebuilds the designation marker a restored job carries — the same
## look each designate_* puts down, keyed off the job type. Types that
## share a designation (SOW under its farm marker) or wear their marker
## on a building (a worksite's craft tint) handle themselves.
func _restore_job_marker(job: ColonyJob) -> void:
	match job.type:
		ColonyJob.Type.MINE, ColonyJob.Type.CHOP:
			_add_marker(job.voxel_position, _marker_material)
		ColonyJob.Type.CLEAR:
			_add_marker(job.voxel_position, _clear_marker_material)
		ColonyJob.Type.FORAGE:
			_add_marker(job.voxel_position, _forage_marker_material)
		ColonyJob.Type.BUILD:
			_add_marker(
				job.voxel_position, _build_marker_material, null, true
			)
		ColonyJob.Type.FURNISH:
			_add_marker(
				job.voxel_position, _build_marker_material, null, true
			)
			for cell in job.extra_voxels:
				_add_marker(cell, _build_marker_material, null, true)
		ColonyJob.Type.DECONSTRUCT:
			_add_marker(
				job.voxel_position,
				_deconstruct_marker_material,
				null,
				true
			)
		ColonyJob.Type.CRAFT:
			if job.order != null:
				# The worksite's own marker just switches to the
				# running look.
				_set_marker_appearance(
					job.voxel_position,
					_craft_job_marker_material,
					_marker_mesh
				)
			elif not _designation_markers.has(job.voxel_position):
				_add_marker(
					job.voxel_position,
					_build_marker_material,
					null,
					true
				)


## Recreates a landed pile — same registration as a deposit minus the
## fall, since the save's voxel is already the resting place.
func _load_pile(voxel_position: Vector3i, items: Array[DropItem]) -> void:
	if items.is_empty():
		return
	var existing: ItemPile = item_piles.get(voxel_position)
	if existing != null:
		existing.add_items(items, false)
		_sync_sim_packed(voxel_position)
		return
	var pile := ItemPile.create(voxel_position, world.sim == null)
	add_child(pile)
	item_piles[voxel_position] = pile
	_index_add(_pile_buckets, voxel_position)
	# Registration precedes the fill — add_items' fill_changed signal
	# re-syncs the sim through the pile lookup.
	pile.landed.connect(_on_pile_landed)
	pile.fill_changed.connect(_on_pile_fill_changed)
	pile.add_items(items, false)
	_sync_sim_packed(voxel_position)


func _load_unit(ud: Dictionary) -> Unit:
	var pos: Array = ud.get("position", [0, 0, 0])
	var unit := spawn_unit(_v3i(pos))
	unit.deserialize(ud, self)
	return unit
