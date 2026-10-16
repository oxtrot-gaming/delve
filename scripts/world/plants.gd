class_name Plants
extends Node

## Small plants: single-cell decorations like the forest's saplings —
## a bush occupies one air voxel over solid ground, blocks nothing, and
## carries a forageable yield (berries for now). The forest's model is
## the precedent: the cell stays [constant BlockRegistry.Block.AIR], the
## plant exists as a record plus a [MultiMeshInstance3D] box.
##
## Unlike trees, forageables aren't felled — a forage takes the ripe
## yield and the bush regrows on a timer. Plants seeded by the terrain
## generator start at mixed ripeness, the same mixed-age rule trees
## follow.
##
## Growth is environment-gated (item 20): the ripening clock is a
## deadline the growth tick slides forward by the un-grown fraction of
## each interval — night and dead soil stall it, fertilized ground
## pulls it earlier. See plant_growth.gd for the factor math.
##
## Plants take cumulative hit-point damage (item 40) from heat, cold,
## sustained darkness or glare, and any external source that calls
## [method damage] — fire, explosions, storms. At the species'
## `hit_points` the plant dies to a standing corpse that decays into
## compost, and a damaged survivor's harvest scales by its remaining
## health.

const Resource_ := BlockRegistry.Resource_

## Species table — the structure a small plant needs: its colours, what
## a forage yields and how long the bush takes to bear again. `annual`
## crops die to their harvest — the plant itself is pulled up with the
## yield, so a field has to be re-sown; perennials (absent flag) bear
## again on the regrow clock. `yield_volume` is cm³ for a loose yield;
## for a discrete `yield_form` it is the item count instead.
##
## Vitals (item 40): `hit_points` is the cumulative-damage death
## threshold; the three nested °C bands are optimal / grows / dormant
## — outside dormant the plant takes `temp_frac_dps` of its hit points
## per °C per game-second — and the light-stress timers are
## `shade_grace_s`/`glare_grace_s` of sustained out-of-band light before
## `shade_frac_dps`/`glare_frac_dps` damage starts. Dead plants stand
## `decay_seconds` then collapse into `compost_volume` cm³ of compost.
const SPECIES: Dictionary = {
	&"berry_bush": {
		&"name": "Berry Bush",
		&"bush_color": Color(0.20, 0.42, 0.16),
		&"ripe_color": Color(0.66, 0.24, 0.18),
		&"yield_material": Resource_.BERRY,
		# Whole berries — a fruit is discrete (extract-seed's input form).
		# A dozen ~2.5-litre handfuls: about three meals a harvest once
		# cooking exists, under the rescaled food model.
		&"yield_form": DropItem.Form.FRUIT,
		&"yield_volume": 12,
		&"forage_seconds": 3.0,
		&"annual": false,
		# Game seconds — 0.675 days. A harvest restores ~1.35
		# colonist-days of hunger, so one bush sustainably feeds ~2.
		&"regrow_seconds": 162.0,
		# The normal daytime light band (plant_growth.gd): grows from
		# first light, full speed mid-morning through noon.
		&"light_min": 0.05,
		&"light_low": 0.66,
		&"light_high": 0.94,
		&"light_max": 1.17,
		&"fertility_sensitivity": 0.5,
		# A hardy wild perennial — dormant through ordinary winters,
		# killed only by a real cold snap or heat wave. Its moisture
		# band is the widest of the crops: a wild bush feeds itself off
		# ambient damp where a crop would stall.
		&"hit_points": 120.0,
		&"temp_opt_min": 8.0,
		&"temp_opt_max": 26.0,
		&"temp_grow_min": 2.0,
		&"temp_grow_max": 34.0,
		&"temp_dorm_min": -10.0,
		&"temp_dorm_max": 46.0,
		&"moist_opt_min": 0.15,
		&"moist_opt_max": 0.75,
		&"moist_grow_min": 0.06,
		&"moist_grow_max": 0.98,
		&"shade_grace_s": 360.0,
		&"compost_volume": 30_000,
	},
	# The first annual: a staple grain that dies to its harvest. The
	# yield is a handful of grain heads — edible like any grain, and
	# seed-bearing: the extract-seed craft threshes one head into two
	# wheat seed packets, which is how a wheat field re-sows itself.
	&"wheat": {
		&"name": "Wheat",
		&"bush_color": Color(0.55, 0.55, 0.25),
		&"ripe_color": Color(0.85, 0.70, 0.28),
		&"yield_material": Resource_.GRAIN,
		&"yield_form": DropItem.Form.FRUIT,
		# Six heads — the plant itself is consumed with the harvest.
		&"yield_volume": 6,
		&"forage_seconds": 3.0,
		&"annual": true,
		# Game seconds to mature from sowing — four days.
		&"regrow_seconds": 960.0,
		&"light_min": 0.05,
		&"light_low": 0.66,
		&"light_high": 0.94,
		&"light_max": 1.17,
		&"fertility_sensitivity": 0.5,
		# A tender annual — a hard frost or serious heat wave kills it.
		# Temperate grain: ambient damp keeps it barely alive, rain or
		# a channel is what a real harvest wants.
		&"hit_points": 60.0,
		&"temp_opt_min": 12.0,
		&"temp_opt_max": 30.0,
		&"temp_grow_min": 5.0,
		&"temp_grow_max": 38.0,
		&"temp_dorm_min": -4.0,
		&"temp_dorm_max": 48.0,
		&"moist_opt_min": 0.35,
		&"moist_opt_max": 0.70,
		&"moist_grow_min": 0.18,
		&"moist_grow_max": 0.92,
		&"shade_grace_s": 240.0,
		&"compost_volume": 20_000,
	},
	# The second annual: a fibre crop. The yield is raw cotton as loose
	# fill — bolls pour like gravel — and the plant dies to the harvest.
	# Unlike wheat, nothing edible comes off it and no seed is dropped:
	# the tailor's bench combs the seed back out when it weaves the
	# fibre into cloth, which is how the field re-sows itself.
	&"cotton": {
		&"name": "Cotton",
		&"bush_color": Color(0.35, 0.50, 0.30),
		&"ripe_color": Color(0.92, 0.90, 0.80),
		&"yield_material": Resource_.COTTON,
		# Raw cotton is loose fill — one armload of bolls, sized so a
		# couple of plants' yield weaves a garment's worth of cloth.
		&"yield_form": DropItem.Form.LOOSE,
		&"yield_volume": 40_000,
		&"forage_seconds": 3.0,
		&"annual": true,
		# Same four-day maturity as wheat — the annual cycle.
		&"regrow_seconds": 960.0,
		&"light_min": 0.05,
		&"light_low": 0.66,
		&"light_high": 0.94,
		&"light_max": 1.17,
		&"fertility_sensitivity": 0.5,
		# A warm-weather crop — the most cold-tender species here, and
		# the thirstiest: dryland cotton barely crawls — it wants a
		# rainy season or a ditch.
		&"hit_points": 60.0,
		&"temp_opt_min": 16.0,
		&"temp_opt_max": 32.0,
		&"temp_grow_min": 8.0,
		&"temp_grow_max": 40.0,
		&"temp_dorm_min": 0.0,
		&"temp_dorm_max": 50.0,
		&"moist_opt_min": 0.45,
		&"moist_opt_max": 0.80,
		&"moist_grow_min": 0.20,
		&"moist_grow_max": 0.92,
		&"shade_grace_s": 240.0,
		&"compost_volume": 20_000,
	},
	# Heal-all (Prunella vulgaris — real-world selfheal): the first
	# medicinal plant. A perennial whose forage yields herb bundles a
	# doctor burns one per medical-bed tend; field care doesn't use it
	# (first aid is hands, not herbs). The herbal-compounding model —
	# several plants into proper remedies — is deliberately not here
	# yet; this is the phase-28 placeholder for it.
	&"heal_all": {
		&"name": "Heal-all",
		&"bush_color": Color(0.30, 0.45, 0.28),
		&"ripe_color": Color(0.48, 0.36, 0.62),
		&"yield_material": Resource_.MEDICINE,
		&"yield_form": DropItem.Form.FRUIT,
		# Four dried bundles a forage — four medical tends' worth.
		&"yield_volume": 4,
		&"forage_seconds": 4.0,
		&"annual": false,
		# Slow regrow — scarcer than food; a colony farms it to be sure.
		&"regrow_seconds": 960.0,
		&"light_min": 0.05,
		&"light_low": 0.66,
		&"light_high": 0.94,
		&"light_max": 1.17,
		&"fertility_sensitivity": 0.5,
		# A shade-tolerant herb — the longest darkness grace of the
		# crops, ordinary temperatures otherwise. A damp-meadow plant:
		# it would rather sit soaked than dry, so its optimum rides
		# the top of the scale while dry soil still supports it.
		&"hit_points": 80.0,
		&"temp_opt_min": 10.0,
		&"temp_opt_max": 24.0,
		&"temp_grow_min": 4.0,
		&"temp_grow_max": 32.0,
		&"temp_dorm_min": -8.0,
		&"temp_dorm_max": 44.0,
		&"moist_opt_min": 0.45,
		&"moist_opt_max": 0.92,
		&"moist_grow_min": 0.12,
		&"moist_grow_max": 1.0,
		&"shade_grace_s": 480.0,
		&"compost_volume": 20_000,
	},
	# The cave mushroom — the dark-farming crop. Its light band is
	# inverted off the same trapezoid: full growth in near-darkness,
	# glare past a fraction of daylight, so it wants a cave, a cellar,
	# or a forest floor and dies in open sun. Yield is a few caps the
	# kitchen treats like any raw food.
	&"cave_mushroom": {
		&"name": "Cave mushroom",
		&"bush_color": Color(0.60, 0.55, 0.45),
		&"ripe_color": Color(0.78, 0.70, 0.55),
		&"yield_material": Resource_.MUSHROOM,
		&"yield_form": DropItem.Form.FRUIT,
		# Three caps a flush — a modest but steady dark harvest.
		&"yield_volume": 3,
		&"forage_seconds": 2.0,
		&"annual": false,
		# Fungus flushes fast — half a food crop's regrow.
		&"regrow_seconds": 480.0,
		# The inverted band: darkness IS the optimum, and ordinary
		# daylight is already glare — noon sun kills in half a day.
		&"light_min": -0.05,
		&"light_low": 0.0,
		&"light_high": 0.15,
		&"light_max": 0.60,
		&"fertility_sensitivity": 0.3,
		# Cave-stable temperatures — cooler and narrower than field
		# crops, and it wants damp soil.
		&"hit_points": 80.0,
		&"temp_opt_min": 5.0,
		&"temp_opt_max": 18.0,
		&"temp_grow_min": 0.0,
		&"temp_grow_max": 25.0,
		&"temp_dorm_min": -5.0,
		&"temp_dorm_max": 35.0,
		&"moist_opt_min": 0.40,
		&"moist_opt_max": 1.0,
		&"moist_grow_min": 0.20,
		&"moist_grow_max": 1.0,
		# Shade never hurts it — the damage axis runs the other way:
		# glare grace is short, and sunlight past the band eats it.
		&"shade_grace_s": 10_000.0,
		&"glare_grace_s": 60.0,
		&"compost_volume": 15_000,
	},
}

var world: VoxelWorld
var colony: Colony

## The installed pack's plant table — [constant SPECIES] is the vanilla
## default until [class DataPackage] installs a pack's `plants` section.
static var _installed: Dictionary = {}


static func species_table() -> Dictionary:
	if _installed.is_empty():
		return DataPackage.plants_table()
	return _installed


static func install(table: Dictionary) -> void:
	_installed = table


## root voxel → {species, ripe, next, damage, dark, glare, dead,
## dead_next}: the bush's record — whether it currently bears its yield,
## when an empty bush bears again, its accumulated hit points of damage
## and sustained out-of-band light (game-seconds; stress bookkeeping for
## PlantGrowth.stress_tick), and once dead, when the corpse collapses
## into compost.
var bushes: Dictionary = {}
## Bush cells → their root. One cell per bush today; the index is the
## O(1) answer to [method bush_at].
var _index: Dictionary = {}
## Generated bush slots whose plant was destroyed — the generator's
## lattice is deterministic, so without this a mined-out bush would
## respawn the moment its data block streams back in.
var _destroyed: Dictionary = {}
## Spatial buckets over bush roots — the same 16-voxel column scheme
## `Colony` keeps for piles, so `nearest_ripe_bush` walks rings out
## from the forager instead of scanning every bush on the map.
## Synced in `_register`/`_forget`/`deserialize`.
var bush_buckets: Dictionary = {}

## Side length of the bush box — smaller than a voxel.
const BUSH_SIZE := 0.65

var _bush_instances: MultiMeshInstance3D
var _decorations_dirty := false
## Staleness sweep clock — dug-out or built-over cells are noticed here
## too, not only when something asks [method bush_at] about them.
var _validate_elapsed := 0.0
## Environment clock — growth-rate evaluations batch to this cadence
## rather than pricing a column light scan per bush per frame.
var _growth_elapsed := 0.0

## Game seconds between growth-rate evaluations — each tick slides every
## growing bush's ripening deadline by the interval's un-grown fraction.
const GROWTH_TICK_SEC := 1.0


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony
	world.water_columns_changed.connect(_on_water_changed)
	_bush_instances = _make_decoration(_box(BUSH_SIZE))
	world.block_loaded.connect(_on_block_loaded)


func _process(delta: float) -> void:
	var now := (
		colony.game_msec() if colony != null else Time.get_ticks_msec()
	)
	_growth_elapsed += delta
	if _growth_elapsed >= GROWTH_TICK_SEC:
		var elapsed := _growth_elapsed
		_growth_elapsed = 0.0
		_growth_tick(elapsed)
	_validate_elapsed += delta
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		if (
			not rec.get(&"dead", false)
			and not rec[&"ripe"] and now >= int(rec[&"next"])
		):
			rec[&"ripe"] = true
			_decorations_dirty = true
	if _validate_elapsed >= 1.0:
		_validate_elapsed = 0.0
		var stale: Array[Vector3i] = []
		var drowned: Array[Vector3i] = []
		for root: Vector3i in bushes:
			if (
				world.get_block(root) != BlockRegistry.Block.AIR
				or not world.is_solid(root + Vector3i.DOWN)
			):
				stale.append(root)
			elif (
				not bushes[root].get(&"dead", false)
				and world.water_level_at(root.x, root.z) >= root.y
			):
				drowned.append(root)
		for root in stale:
			bush_at(root)  # forgets the record and tombstones the slot
		for root in drowned:
			_kill(root)
	if _decorations_dirty:
		_refresh_decorations()


## The growth-rate pass: every unripe bush's deadline slides by the
## un-grown fraction of [param elapsed] — darkness and dead soil (factor
## 0) slide it in lockstep with the clock so growth pauses, and a
## boosted factor (> 1, fertilized ground) pulls it earlier. A bush that
## crosses its deadline anyway has genuinely accrued its growth — the
## ripening check in _process fires regardless of current light.
##
## The same tick runs item 40's stress: living bushes accrue
## thermal/light damage toward their hit-point death (ripe plants are
## still alive — they hurt too), and corpses pass their decay deadline
## collapse into compost.
func _growth_tick(elapsed: float) -> void:
	if colony == null:
		return
	var now := colony.game_msec()
	var dt_ms := int(elapsed * 1000.0)
	var deaths: Array[Vector3i] = []
	var decayed: Array[Vector3i] = []
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		var sp: Dictionary = species_table()[rec[&"species"]]
		if rec.get(&"dead", false):
			if now >= int(rec[&"dead_next"]):
				decayed.append(root)
			continue
		var light := colony.grow_light_at(root)
		var temp := colony.temperature_at(root)
		rec[&"damage"] = (
			float(rec.get(&"damage", 0.0))
			+ PlantGrowth.stress_tick(sp, rec, light, temp, elapsed)
		)
		if float(rec[&"damage"]) >= PlantGrowth.hit_points(sp):
			deaths.append(root)
			continue
		if rec[&"ripe"] or now >= int(rec[&"next"]):
			continue
		var f := _growth_factor(root, rec, light, temp)
		rec[&"next"] = int(rec[&"next"]) + int(dt_ms * (1.0 - f))
		if f > 0.0:
			colony._deplete_fertility(
				root + Vector3i.DOWN, elapsed * f
			)
	for root in deaths:
		_kill(root)
	for root in decayed:
		_decay(root)


## Light × temperature × moisture × fertility for the bush at [param
## root] — the probes already read by the stress tick are passed in so
## the column scans price once per bush per tick.
func _growth_factor(
	root: Vector3i, rec: Dictionary, light: float, temp: float
) -> float:
	if colony == null:
		return 1.0
	var sp: Dictionary = species_table()[rec[&"species"]]
	return PlantGrowth.growth_factor(
		sp, light, temp,
		colony.effective_fertility(root + Vector3i.DOWN),
		colony.soil_moisture_at(root + Vector3i.DOWN)
	)


## Damage the bush at [param root] by [param amount] hit points — the
## generic entry point every harm source shares (fire, explosions,
## storms, combat, and the environmental stress above). Kills at the
## species' hit-point threshold; harmless on a dead or absent plant.
func damage(root: Vector3i, amount: float) -> void:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty() or rec.get(&"dead", false):
		return
	rec[&"damage"] = float(rec.get(&"damage", 0.0)) + amount
	var sp: Dictionary = species_table().get(rec[&"species"], {})
	if float(rec[&"damage"]) >= PlantGrowth.hit_points(sp):
		_kill(root)


## True when the plant at [param root] is dead — still standing, not
## yet decayed.
func is_dead(root: Vector3i) -> bool:
	var rec: Dictionary = bushes.get(root, {})
	return not rec.is_empty() and rec.get(&"dead", false)


## Damage hit points the plant at [param root] has accrued — 0 for a
## healthy or absent plant.
func damage_at(root: Vector3i) -> float:
	return float(bushes.get(root, {}).get(&"damage", 0.0))


## The bush dies: the corpse keeps the cell (it still has to be cleared
## or decayed) but stops ripening and foraging, browns out, and is
## marked for collapse into compost. A generated slot is tombstoned so
## the streamer never regrows a dead plant.
func _kill(root: Vector3i) -> void:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty() or rec.get(&"dead", false):
		return
	var sp: Dictionary = species_table()[rec[&"species"]]
	rec[&"dead"] = true
	rec[&"ripe"] = false
	rec[&"dead_next"] = colony.game_msec() + int(
		float(sp.get(&"decay_seconds", PlantGrowth.DECAY_SECONDS)) * 1000.0
	)
	_destroyed[root] = true
	_decorations_dirty = true


## The corpse's time is up — it collapses into compost where it stood.
func _decay(root: Vector3i) -> void:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty():
		return
	var sp: Dictionary = species_table()[rec[&"species"]]
	var volume := int(sp.get(&"compost_volume", PlantGrowth.COMPOST_VOLUME))
	_forget(root)
	if volume > 0:
		colony._drop_item(
			DropItem.new(Resource_.COMPOST, DropItem.Form.LOOSE, volume), root
		)

## The root voxel of the bush at [param voxel_position], or
## [constant Vector3i.MAX]. Stale records — a cell built into or dug out
## from under — are noticed and dropped here.
func bush_at(voxel_position: Vector3i) -> Vector3i:
	var root: Vector3i = _index.get(voxel_position, Vector3i.MAX)
	if root == Vector3i.MAX or not bushes.has(root):
		return Vector3i.MAX
	if (
		world.get_block(root) != BlockRegistry.Block.AIR
		or not world.is_solid(root + Vector3i.DOWN)
	):
		_forget(root)
		_destroyed[root] = true
		return Vector3i.MAX
	return root


## True when the bush at [param root] is ripe and can be foraged —
## dead plants are never forageable; their value is the compost they
## decay into.
func can_forage(root: Vector3i) -> bool:
	var rec: Dictionary = bushes.get(root, {})
	return (
		not rec.is_empty() and not rec.get(&"dead", false)
		and bool(rec[&"ripe"])
	)


## Seconds of unit labour a forage on [param root]'s bush takes.
func forage_work(root: Vector3i) -> float:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty():
		return 0.0
	return float(species_table()[rec[&"species"]][&"forage_seconds"])


## Takes the bush's yield: returns the items a forage drops (the caller
## spills them into the world) and starts the regrow timer. An annual
## comes up whole — the harvest destroys the plant. Empty for a bush
## that isn't ripe.
func forage(root: Vector3i) -> Array[DropItem]:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty() or rec.get(&"dead", false) or not bool(rec[&"ripe"]):
		return []
	var sp: Dictionary = species_table()[rec[&"species"]]
	# A damaged plant harvests light — the yield scales with its
	# remaining health fraction.
	var yield_f := PlantGrowth.yield_factor(sp, float(rec.get(&"damage", 0.0)))
	if sp.get(&"annual", false):
		# The plant comes up whole — and if it stood on a generated
		# slot, the tombstone keeps a stream-in from regrowing it.
		_forget(root)
		_destroyed[root] = true
	else:
		rec[&"ripe"] = false
		rec[&"next"] = colony.game_msec() + int(
			float(sp[&"regrow_seconds"]) * 1000.0
		)
	_decorations_dirty = true
	var form: DropItem.Form = sp.get(&"yield_form", DropItem.Form.LOOSE)
	var drops: Array[DropItem] = []
	if yield_f <= 0.0:
		return drops
	if form == DropItem.Form.LOOSE:
		drops.append(
			DropItem.new(
				sp[&"yield_material"], form,
				maxi(1, roundi(int(sp[&"yield_volume"]) * yield_f))
			)
		)
	else:
		# Discrete yields count items — wheat drops whole grain heads.
		for i in maxi(1, roundi(int(sp[&"yield_volume"]) * yield_f)):
			drops.append(
				DropItem.new(sp[&"yield_material"], form, DropItem.form_volume(form))
			)
	return drops


## Cuts the bush at [param root] down — the manual removal order. The
## plant dies on the spot (tombstoned like a foraged annual, so a
## generated slot never regrows) and pays its yield scaled by growth:
## a ripe bush harvests like a forage, an unripe one in proportion to
## how far through its regrow it was, a dead one nothing at all.
func cut(root: Vector3i) -> Array[DropItem]:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty():
		return []
	var sp: Dictionary = species_table()[rec[&"species"]]
	var growth := 0.0
	if not rec.get(&"dead", false):
		if bool(rec[&"ripe"]):
			growth = 1.0
		else:
			var regrow_ms := float(sp[&"regrow_seconds"]) * 1000.0
			growth = clampf(
				1.0
					- float(rec[&"next"] - colony.game_msec()) / regrow_ms,
				0.0, 1.0
			)
	var yield_f := growth * PlantGrowth.yield_factor(
		sp, float(rec.get(&"damage", 0.0))
	)
	_forget(root)
	_destroyed[root] = true
	var drops: Array[DropItem] = []
	if yield_f <= 0.0:
		return drops
	var form: DropItem.Form = sp.get(&"yield_form", DropItem.Form.LOOSE)
	if form == DropItem.Form.LOOSE:
		var vol := roundi(int(sp[&"yield_volume"]) * yield_f)
		if vol > 0:
			drops.append(DropItem.new(sp[&"yield_material"], form, vol))
	else:
		for i in roundi(int(sp[&"yield_volume"]) * yield_f):
			drops.append(
				DropItem.new(
					sp[&"yield_material"], form, DropItem.form_volume(form)
				)
			)
	return drops


## Whether a generated slot starts ripe — deterministic off the root, so
## a reloaded slot reseeds identically. Two thirds bear immediately: a
## fresh world has food to forage without waiting out a regrow.
func seeded_ripe(root: Vector3i) -> bool:
	return _hash(root, 491) % 3 != 0


func _hash(root: Vector3i, salt: int = 0) -> int:
	return hash(Vector4i(root.x, root.y, root.z, salt)) & 0x7fffffff


## Plants an immature bush at [param root] — the decay-sprout path.
## False when the cell can't host one (claimed, non-air, no ground).
func plant(root: Vector3i, species: StringName) -> bool:
	if not species_table().has(species) or _index.has(root):
		return false
	if world.get_block(root) != BlockRegistry.Block.AIR:
		return false
	if not world.is_solid(root + Vector3i.DOWN):
		return false
	# Water isn't a voxel — under the column's live waterline is drowned.
	if world.water_level_at(root.x, root.z) >= root.y:
		return false
	_register(root, species, false)
	return true


## Registers a bush record for the plant at [param root].
func _register(root: Vector3i, species: StringName, ripe: bool) -> void:
	var sp: Dictionary = species_table()[species]
	var jitter := _hash(root, 223) % 1000
	var delay := int(
		float(sp[&"regrow_seconds"]) * 1000.0 * (0.5 + jitter / 1000.0)
	)
	bushes[root] = {
		&"species": species,
		&"ripe": ripe,
		# Unripe seeded bushes bear soon rather than on a full regrow.
		&"next": colony.game_msec() + delay,
	}
	_index[root] = root
	var bucket := Vector2i(
		root.x >> Colony.SPATIAL_BUCKET_SHIFT,
		root.z >> Colony.SPATIAL_BUCKET_SHIFT
	)
	var list: Array = bush_buckets.get(bucket, [])
	if list.is_empty():
		bush_buckets[bucket] = list
	list.append(root)
	_decorations_dirty = true


## Drops a bush's record without touching the world.
func _forget(root: Vector3i) -> void:
	_index.erase(root)
	bushes.erase(root)
	var bucket := Vector2i(
		root.x >> Colony.SPATIAL_BUCKET_SHIFT,
		root.z >> Colony.SPATIAL_BUCKET_SHIFT
	)
	var list: Array = bush_buckets.get(bucket, [])
	list.erase(root)
	if list.is_empty():
		bush_buckets.erase(bucket)
	_decorations_dirty = true


## Columns whose live waterline moved — a bush under the new surface
## drowns on the spot rather than waiting for the staleness sweep.
## Killed, not forgotten: the corpse browns and decays to compost like
## any death, and the slot stays tombstoned against reseeding.
func _on_water_changed(columns: PackedVector3Array) -> void:
	if bushes.is_empty():
		return
	var cols := {}
	for c in columns:
		cols[Vector2i(int(c.x), int(c.z))] = true
	var drowned: Array[Vector3i] = []
	for root: Vector3i in bushes:
		if not cols.has(Vector2i(root.x, root.z)):
			continue
		if world.water_level_at(root.x, root.z) >= root.y:
			drowned.append(root)
	for root in drowned:
		_kill(root)


## Bush slots seeded by the terrain generator are discovered as their
## data blocks stream in — the bush cell is air over grass at
## surface_height + 1. [member _destroyed] keeps a mined-out slot from
## reseeding on reload.
func _on_block_loaded(block_origin: Vector3i) -> void:
	var base := block_origin * 16
	var generator := world.generator_script
	# Bushes sit one voxel above the surface — a block outside that band
	# holds none, so the lattice scan is skipped outright.
	if (
		base.y > generator.max_surface_height() + 1
		or base.y + 16 <= generator.min_surface_height() + 1
	):
		return
	var slots: Dictionary = generator.bushes_in(base, 16)
	for pos: Vector2i in slots:
		var voxel := Vector3i(
			pos.x, generator.surface_height(pos.x, pos.y) + 1, pos.y
		)
		if _destroyed.has(voxel) or _index.has(voxel):
			continue
		if world.get_block(voxel) != BlockRegistry.Block.AIR:
			continue  # somebody dug or built here since generation
		_register(voxel, slots[pos], seeded_ripe(voxel))


## Redraws the bush multimesh from current records — ripe bushes tint
## toward their fruit colour and corpses go dead-plant brown so both
## states read at a glance.
func _refresh_decorations() -> void:
	_decorations_dirty = false
	var mm := _bush_instances.multimesh
	mm.instance_count = bushes.size()
	var i := 0
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		mm.set_instance_transform(
			i,
			Transform3D(Basis(), Vector3(root) + Vector3(0.5, 0.35, 0.5))
		)
		if rec.get(&"dead", false):
			mm.set_instance_color(i, PlantGrowth.DEAD_COLOR)
			i += 1
			continue
		var sp: Dictionary = species_table().get(rec[&"species"], {})
		mm.set_instance_color(
			i,
			Color(
				sp.get(
					&"ripe_color" if rec[&"ripe"] else &"bush_color",
					Color(0.3, 0.5, 0.2)
				)
			)
		)
		i += 1


## One multimesh drawing a decoration mesh once per tracked voxel —
## same construction the forest decorations use.
func _make_decoration(mesh: Mesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.custom_aabb = AABB(
		Vector3(-8192, -512, -8192), Vector3(16384, 1024, 16384)
	)
	var instances := MultiMeshInstance3D.new()
	instances.multimesh = mm
	instances.material_override = SliceView.vcolor()
	instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instances)
	return instances


func _box(size: float) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	return mesh


## Save records: bushes as [root, species, ripe, next, damage, dark,
## glare, dead, dead_next] rows plus the generated-slot tombstones — a
## destroyed slot must stay dead across a reload just like a re-stream.
## The stress fields ride along so a save/load can't launder damage or
## restart a grace period.
func serialize() -> Dictionary:
	var list: Array = []
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		list.append([
			root.x, root.y, root.z,
			String(rec[&"species"]), bool(rec[&"ripe"]), int(rec[&"next"]),
			float(rec.get(&"damage", 0.0)),
			float(rec.get(&"dark", 0.0)), float(rec.get(&"glare", 0.0)),
			bool(rec.get(&"dead", false)), int(rec.get(&"dead_next", 0)),
		])
	var destroyed_list: Array = []
	for root: Vector3i in _destroyed:
		destroyed_list.append([root.x, root.y, root.z])
	return {"bushes": list, "destroyed": destroyed_list}


## Replaces the destroyed-slot set ahead of streaming — a load's
## blocks scan the bush lattice while colony.deserialize is still
## waiting on the site mesh, and an unguarded destroyed slot would
## reseed under the load. The incoming save is authoritative: clearing
## first also drops tombstones a prior session left behind.
## deserialize repopulates the same set wholesale, so seeding early is
## idempotent.
func seed_destroyed(entries: Array) -> void:
	_destroyed.clear()
	for e: Array in entries:
		_destroyed[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = true


## Replaces live state wholesale — the colony clears before loading.
func deserialize(data: Dictionary) -> void:
	bushes.clear()
	_index.clear()
	bush_buckets.clear()
	_destroyed.clear()
	for e: Array in data.get("bushes", []):
		var root := Vector3i(int(e[0]), int(e[1]), int(e[2]))
		bushes[root] = {
			&"species": StringName(e[3]),
			&"ripe": bool(e[4]),
			&"next": int(e[5]),
			&"damage": float(e[6]) if e.size() > 6 else 0.0,
			&"dark": float(e[7]) if e.size() > 7 else 0.0,
			&"glare": float(e[8]) if e.size() > 8 else 0.0,
			&"dead": bool(e[9]) if e.size() > 9 else false,
			&"dead_next": int(e[10]) if e.size() > 10 else 0,
		}
		_index[root] = root
		var bucket := Vector2i(
			root.x >> Colony.SPATIAL_BUCKET_SHIFT,
			root.z >> Colony.SPATIAL_BUCKET_SHIFT
		)
		var list: Array = bush_buckets.get(bucket, [])
		if list.is_empty():
			bush_buckets[bucket] = list
		list.append(root)
	for e: Array in data.get("destroyed", []):
		_destroyed[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = true
	# Paint now rather than flagging for _process — a paused game never
	# ticks, so a flagged load would stay invisible until unpause.
	_refresh_decorations()
