class_name Main
extends Node3D

## Boots the prototype: creates the region the colony site embeds in,
## waits for the terrain around it to stream in, then drops the starting
## units — or, for a staged load, restores the saved site state.
##
## The save unit is the [Region]: a save directory holds world.json
## (seed + planet clock) plus one region_<x>_<z>.json per region tile —
## the layout already fits the future where several regions exist and a
## region holds several sites.

const DLog := preload("res://scripts/dlog.gd")

const SAVE_DIR := "user://saves"
const DEFAULT_SLOT := "default"

## The save-slot directory a load staged before the scene reloaded —
## [method load_game] sets it, `reload_current_scene` re-runs _ready
## and _read_save consumes it.
static var pending_load := ""

## A new-world request staged by the worldgen screen — seed, the
## worldgen sliders and the tile the player embarked on. Consumed by
## _ready like pending_load is.
static var pending_world: Dictionary = {}

@export var colony_site := Vector3i(0, 0, 0)

## Worldgen sliders (PLAN item 39) — what a new-game screen will write
## before the globe builds; today they're inspector exports. They feed
## the macroscale planet, so the save round-trips them to regenerate
## the identical world on load.
## Ocean coverage as a tile percentage — 100% is unreachable on purpose
## (an all-water world has no land to settle).
@export_range(0, 95, 5) var ocean_pct := WorldGlobe.OCEAN_PCT_DEFAULT
## Planet-wide temperature shift in °C — the hot/cold slider.
@export_range(-20, 20, 0.5) var temp_bias_c := 0.0
## Planet-wide moisture shift — the wet/dry slider.
@export_range(-0.35, 0.35, 0.05) var moist_bias := 0.0
## Axial tilt in degrees — 0 kills the seasons entirely, past ~45 the
## day/night extremes turn Uranian.
@export_range(0, 60, 1) var axial_tilt_deg := 23.44

@onready var world: VoxelWorld = $VoxelWorld
@onready var colony: Colony = $Colony
@onready var day_cycle: DayCycle = $DayCycle

## The world-map tile the colony site embeds in — what saves serialize.
var region: Region
## This playthrough's site inside the region.
var site: Site

## The macroscale planet — deterministic from the world seed and the
## worldgen options, so it's rebuilt (or reused across scene reloads)
## rather than serialized.
static var _globe_key := ""
static var _globe: WorldGlobe

## The active site's mesoscale map — the flat heightfield its region
## was generated against. Kept for off-site travel and incident sites.
var meso: MesoMap

var _units_spawned: bool = false
## A staged load's colony payload for [member site] — consumed once the
## site's terrain has meshed.
var _site_state: Dictionary = {}


func _ready() -> void:
	DLog.open()
	if pending_load != "":
		_site_state = _read_save(pending_load)
		pending_load = ""
	elif not pending_world.is_empty():
		# The worldgen screen staged a fresh world: apply its seed and
		# sliders before the first globe build, and settle the tile the
		# player picked instead of the default direction.
		var pw := pending_world
		pending_world = {}
		world.generator_script.world_seed = int(
			pw.get(&"seed", world.generator_script.world_seed)
		)
		ocean_pct = int(pw.get(&"ocean_pct", ocean_pct))
		temp_bias_c = float(pw.get(&"temp_bias_c", temp_bias_c))
		moist_bias = float(pw.get(&"moist_bias", moist_bias))
		axial_tilt_deg = float(pw.get(&"axial_tilt_deg", axial_tilt_deg))
		_pending_world_tile = int(pw.get(&"world_tile", -1))
		# The staged content pair installs before the first globe build —
		# biome assignment and the generator's species picks read it.
		DataPackage.install(
			StringName(pw.get(&"package", &"vanilla")),
			StringName(pw.get(&"scenario", &"lost_tribe"))
		)
		colony.scenario_id = StringName(
			pw.get(&"scenario", &"lost_tribe")
		)
	if region == null:
		# Fresh world: settle the picked (or default) tile and pin its
		# terrain to that tile's mesoscale map before the region samples
		# the generator.
		var tile := _install_site_meso(_pending_world_tile, colony_site)
		_pending_world_tile = -1
		region = Region.containing(colony_site)
		region.generate(world.generator_script)
		_fresh_site_tile = tile
	world.region = region
	# A loaded region already knows its sites — reattach the live sim to
	# the one under the colony anchor; a fresh region registers it new.
	site = _site_at(colony_site)
	if site == null:
		site = region.add_site(colony_site, colony)
		site.world_tile = _fresh_site_tile
	else:
		site.colony = colony
	if site.world_tile < 0:
		# A site with no tile on record — a fresh site in a loaded
		# region, or a save predating the planetary layer.
		site.world_tile = _install_site_meso(-1, site.anchor)
	# The colony needs its bounds for periphery arrivals — the site's
	# record is the source of truth.
	colony.site_bounds = site.bounds
	if colony.scenario_id == &"":
		colony.scenario_id = DataPackage.scenario_id()
	DLog.log("main ready: region %s, %d site(s), tile %d" % [
		region.coordinate, region.sites.size(), site.world_tile
	])


## Site tile chosen on the fresh-boot path, waiting for the Site record.
var _fresh_site_tile := -1

## The tile a worldgen embark picked, staged until the fresh-boot path
## installs its meso map.
var _pending_world_tile := -1


## The worldgen options as the globe consumes them — also what the
## save serializes so a load rebuilds the identical planet.
func worldgen_options() -> Dictionary:
	return {
		&"ocean_pct": ocean_pct,
		&"temp_bias_c": temp_bias_c,
		&"moist_bias": moist_bias,
		&"axial_tilt_deg": axial_tilt_deg,
	}


## The planet for the generator's current seed and options — built
## once and kept across scene reloads (the tiling alone is ~180k
## cells).
func _ensure_globe() -> WorldGlobe:
	var seed: int = world.generator_script.world_seed
	var key := "%d:%d:%.3f:%.3f:%s" % [
		seed, ocean_pct, temp_bias_c, moist_bias, DataPackage.package_id()
	]
	if _globe == null or _globe_key != key:
		_globe = WorldGlobe.new(seed, worldgen_options())
		_globe.generate()
		_globe_key = key
		DLog.log("globe: %d tiles for seed %d" % [_globe.centers.size(), seed])
	return _globe


## Resolve the site's world tile ([param wanted] = a saved tile id, or
## -1 to pick the default settle tile), generate its MesoMap and pin the
## generator's regional layer to it. [param anchor] is the site voxel
## the meso plane's centre maps onto. Returns the tile id.
func _install_site_meso(wanted: int, anchor: Vector3i) -> int:
	var globe := _ensure_globe()
	var tile := wanted
	if tile < 0 or tile >= globe.centers.size() or globe.ocean[tile] != 0:
		# No tile on record, an id off the planet, or water — colonies
		# can't settle ocean or ice cap: fall back to the nearest land
		# to the reference direction.
		tile = globe.nearest_land_tile(WorldGlobe.default_settle_dir())
	meso = MesoMap.generate(globe, tile)
	var vg: Dictionary = meso.voxel_grid(
		Vector2i(anchor.x, anchor.z), world.generator_script.base_height
	)
	world.generator_script.install_regional_grid(
		vg["grid"], vg["origin"], vg["step"], vg["size"]
	)
	_apply_site_climate(globe, tile)
	return tile


## Point the site's clock and weather at its world tile — the
## macro→micro climate link. Latitude and longitude come straight off
## the tile centre's direction; the weather's annual mean and wet
## share come off the mesoscale fields under the anchor (map centre),
## and the seasonal swing follows latitude × tilt. Recomputed on every
## install rather than serialized.
func _apply_site_climate(globe: WorldGlobe, tile: int) -> void:
	var c: Vector3 = globe.centers[tile]
	var lat := rad_to_deg(asin(clampf(c.y, -1.0, 1.0)))
	day_cycle.site_latitude_deg = lat
	# Longitude 0 sits on +Z — arbitrary but consistent: it only shifts
	# local time against the shared planet clock.
	day_cycle.site_longitude_deg = rad_to_deg(atan2(c.x, c.z))
	colony.weather.set_climate(
		Weather.site_climate(
			lat, meso.temp_at(0.0, 0.0), meso.precip_at(0.0, 0.0),
			axial_tilt_deg
		)
	)
	DLog.log(
		(
			"site climate: lat %.1f° lon %.1f° mean %.1f °C "
			+ "swing %+.1f °C precip %.0f cm/yr"
		) % [lat, day_cycle.site_longitude_deg,
			meso.temp_at(0.0, 0.0),
			colony.weather.seasonal_amplitude_c,
			meso.precip_at(0.0, 0.0)]
	)


func _process(_delta: float) -> void:
	if _units_spawned:
		return
	var surface_y := world.predicted_surface_height(colony_site.x, colony_site.z)
	var site_voxel := Vector3i(colony_site.x, surface_y, colony_site.z)
	if not world.is_area_meshed(AABB(Vector3(site_voxel) - Vector3.ONE * 16.0, Vector3.ONE * 32.0)):
		return
	if _site_state.is_empty():
		colony.spawn_initial_units(site_voxel)
	else:
		colony.deserialize(_site_state)
		_site_state = {}
	_units_spawned = true
	DLog.log("site ready at %s" % site_voxel)


## The site whose bounds cover [param voxel], or null.
func _site_at(voxel: Vector3i) -> Site:
	for s: Site in region.sites:
		if s.bounds.has_point(Vector2i(voxel.x, voxel.z)):
			return s
	return null


## Saves the world: world.json (seed + planet clock + the region list)
## plus one region file per tile — a region, not a site, is the save
## unit so multi-site regions need no format change later.
func save_game(slot := DEFAULT_SLOT) -> String:
	var dir := SAVE_DIR.path_join(slot)
	DirAccess.make_dir_recursive_absolute(dir)
	var world_data := {
		"version": Region.SAVE_VERSION,
		"world_seed": world.generator_script.world_seed,
		# Worldgen options ride the save: the planet is regenerated, not
		# serialized, so a load must rebuild it from identical settings.
		"world_options": worldgen_options(),
		# The content pair the world runs under — biomes feed the
		# regenerated globe, the scenario feeds later arrivals.
		"package": String(DataPackage.package_id()),
		"scenario": String(
			colony.scenario_id if colony != null else DataPackage.scenario_id()
		),
		"planet_time": day_cycle.planet_time if day_cycle != null else 0.0,
		"regions": [],
	}
	for c in [region.coordinate]:
		world_data["regions"].append([c.x, c.y])
		_write_json(
			dir.path_join("region_%d_%d.json" % [c.x, c.y]), region.serialize()
		)
	_write_json(dir.path_join("world.json"), world_data)
	DLog.log("saved to %s" % dir)
	return dir


## Stages a save slot and reloads the scene — _ready reads it back:
## the generator re-seeds, the region deserializes (edit log included,
## replayed as chunks stream), and _process restores the site's colony
## once its terrain has meshed.
func load_game(slot := DEFAULT_SLOT) -> void:
	pending_load = SAVE_DIR.path_join(slot)
	get_tree().reload_current_scene()


## Reads the staged save: reseeds the generator, restores the planet
## clock and deserializes the region. Returns the focused site's colony
## payload for _process to apply — empty if the save is missing.
func _read_save(dir: String) -> Dictionary:
	var world_data: Variant = _read_json(dir.path_join("world.json"))
	if world_data == null:
		push_error("no save at %s" % dir)
		return {}
	var world_version := int(world_data.get("version", 0))
	if world_version != Region.SAVE_VERSION:
		# Compatibility break at v2 — block ids, the drop model and job
		# serialization all changed with ore intrusions (PLAN item 42);
		# loading a v1 save would silently corrupt the world.
		push_error(
			"Refusing save at version %d (need %d)"
			% [world_version, Region.SAVE_VERSION]
		)
		return {}
	world.generator_script.world_seed = int(world_data["world_seed"])
	# Restore the worldgen sliders *before* the first globe build —
	# saves written before the options existed just keep the defaults.
	var opts: Dictionary = world_data.get("world_options", {})
	ocean_pct = int(opts.get("ocean_pct", ocean_pct))
	temp_bias_c = float(opts.get("temp_bias_c", temp_bias_c))
	moist_bias = float(opts.get("moist_bias", moist_bias))
	axial_tilt_deg = float(opts.get("axial_tilt_deg", axial_tilt_deg))
	# Install the saved content pair before the first globe build —
	# saves predating packages keep the vanilla default.
	DataPackage.install(
		StringName(world_data.get("package", &"vanilla")),
		StringName(world_data.get("scenario", &"dev"))
	)
	if colony != null:
		colony.scenario_id = StringName(
			world_data.get("scenario", &"dev")
		)
	if day_cycle != null:
		day_cycle.planet_time = float(world_data.get("planet_time", 0.0))
	var region_coord := Region.coord_of(colony_site)
	var region_data: Variant = _read_json(
		dir.path_join(
			"region_%d_%d.json" % [region_coord.x, region_coord.y]
		)
	)
	if region_data == null:
		push_error("save has no region file for %s" % region_coord)
		return {}
	region = Region.deserialize(region_data)
	if region == null:
		return {}
	for s: Site in region.sites:
		if not s.state.is_empty():
			s.world_tile = _install_site_meso(s.world_tile, s.anchor)
			return s.state
	return {}


static func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(JSON.stringify(data))


static func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("malformed save file %s" % path)
	return null
