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
## Autosaves go to their own slot — a bad stretch can't clobber the
## player's manual save, and the title's slot list shows both.
const AUTOSAVE_SLOT := "autosave"

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
@onready var world_viewer: VoxelViewer = $Overseer/VoxelViewer

## The active site's region — `world.region` for the edit log, the
## region file written at save. Other regions visited this session sit
## in `_regions`, dormant but remembered.
var region: Region
## This playthrough's site inside the region — the ACTIVE one, whose
## site.colony is the live sim. `focus_site` moves the marker.
var site: Site
## Every region tile loaded or created this session, coord → Region —
## the region-streaming cache (PLAN item 65). Region files absent from
## it are read on demand from `_save_dir` or created empty.
var _regions: Dictionary = {}
## The save slot directory the running game loaded from ("" on a fresh
## world) — `_region_at` reads unvisited region files and
## `stream_for` builds voxel-store paths under it. Set via
## `_set_save_dir`: a new slot repoints every open store after its
## file is flushed and copied across.
var _save_dir := ""
## Working dir for voxel stores before a world has a slot — a fresh
## world binds its tile's store here at boot so the stream swap only
## ever runs before the viewer wakes (a mid-session `set_stream`
## drops every loaded block). Kept outside `saves/` so slot listings
## never see it; wiped on each fresh boot.
const SCRATCH_ROOT := "user://_voxels_live"
## Off-site travel parties in flight (PLAN item 65) — unit payloads
## plus their globe-tile route and metres walked. Lives on world.json:
## a party is precisely the state that's *between* regions.
var travel_parties: Array[Dictionary] = []
## A traveller's sustained pace over the meso layer — walking speed,
## on the same clock the units' 4 m/s `move_speed` runs.
const TRAVEL_SPEED_MPS := 4.0
## Durable voxel streams, world tile → VoxelStreamSQLite (PLAN item
## 66): one backing store per tile's 16 km voxel patch. The patch
## dwarfs the ~160 m streaming radius, so a tile-scoped file can
## never absorb a neighbour's blocks the way 256 m region files
## could. Sites on different tiles keep different stores; same-tile
## sites correctly share contiguous space. The cache holds every
## instance the session opens — the multi-store shape concurrent
## site ticking wants.
var _streams: Dictionary = {}
## Voxel columns each world tile's sites occupy — a tile gets its own
## 16 km patch of the flat voxel space so sites on different tiles can
## never collide, however their meso cells line up.
const TILE_VOXEL_SPAN := 16384

## The macroscale planet — deterministic from the world seed and the
## worldgen options, so it's rebuilt (or reused across scene reloads)
## rather than serialized.
static var _globe_key := ""
static var _globe: WorldGlobe

## The active site's mesoscale map — the flat heightfield its region
## was generated against. Kept for off-site travel and incident sites.
var meso: MesoMap
## The site's soil/water field — carved terrain drops, water levels,
## soil specs and the basin/flow records that floods and player-made
## outlets will later mutate (DESIGN: Soils and hydrology).
var site_field: SiteField
## The water level datum's surface layer — rebuilt when the field
## (re)installs.
var water_view: WaterView
var flow_view: FlowView
## The layer-view clip plane + cut cross-section — installed with the
## field so its cap tiles know the site bounds.
var slice_view: SliceView

var _units_spawned: bool = false
## A staged load's colony payload for [member site] — consumed once the
## site's terrain has meshed.
var _site_state: Dictionary = {}
## True while [method _ready] is suspended between loading stages —
## generation pumps frames now, so [_method _process] must not run the
## mesh-wait/spawn path until boot finishes.
var _booting := false
## The viewer's real range, captured while boot holds it at zero.
var _boot_view_distance := 160

## True when _read_save resolved a staged site — tells _process to take
## the deserialize branch even when the site's payload is empty (a
## surveyed-but-uninhabited site restores as an empty colony, not a
## fresh embark with spawned settlers and ruins).
var _restoring := false

## The embark/load progress display: a dim full-screen layer with a
## stage label — enough that a 20+ second planet build reads as
## "getting ready" instead of a hung window.
var _loading_layer: CanvasLayer = null
var _loading_label: Label = null
var _stage_text := ""
var _spin_frame := 0


## Builds the loading overlay. Exists only while [_member _loading_layer]
## is set — generator code checks that flag to decide whether its loops
## should pump frames.
func _loading_begin() -> void:
	_loading_layer = CanvasLayer.new()
	_loading_layer.layer = 100
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.07, 0.92)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_loading_layer.add_child(dim)
	# A full-rect centred label, not a shrink-wrapped one — the spinner
	# dots append and trim without the text sliding sideways each tick.
	_loading_label = Label.new()
	_loading_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 20)
	_loading_layer.add_child(_loading_label)
	add_child(_loading_layer)
	_stage_text = "Getting ready"
	_loading_label.text = _stage_text


## Updates the stage text and — while the overlay is up — yields one
## frame so the new text actually paints before the next blocking
## stretch. With no overlay (tests, headless paths) it is a cheap sync
## call that never suspends.
func _load_stage(text: String) -> void:
	_stage_text = text
	if _loading_label == null:
		return
	_loading_label.text = text
	await get_tree().process_frame


func _loading_end() -> void:
	if _loading_layer != null:
		_loading_layer.queue_free()
		_loading_layer = null
	_loading_label = null


## Animated dots so a long stage still shows life between label updates.
func _tick_loading() -> void:
	if _loading_label == null:
		return
	_spin_frame += 1
	# Constant-width tail: three dot slots, filled or blank, so the
	# centred line doesn't drift as the animation ticks.
	var dots := _spin_frame / 30 % 4
	_loading_label.text = (
		_stage_text + ".".repeat(dots) + " ".repeat(3 - dots)
	)


func _ready() -> void:
	DLog.open()
	GameOptions.ensure_loaded()
	# SceneTree.paused survives reload_current_scene: a save taken
	# while paused re-pauses the tree at deserialize, and the next
	# load would freeze _process's mesh wait forever. Boot unpaused —
	# the colony payload re-applies the saved pause state after.
	get_tree().paused = false
	_loading_begin()
	_booting = true
	# Hold the streamer through generation: pumped frames would let the
	# viewer pull chunks built against a half-installed generator — no
	# site field means uncarved, unclamped terrain under what the water
	# skin later floods, and grass seeding runs before the water gate
	# exists. Zero-distance viewers still request their own block, so
	# the hold suppresses the viewer's request flags outright — no
	# block loads, no notifications, nothing for block_loaded handlers
	# to act on — then restoring them re-issues a clean detection pass.
	_boot_view_distance = world_viewer.view_distance
	world_viewer.view_distance = 0
	world_viewer.requires_visuals = false
	world_viewer.requires_collisions = false
	world_viewer.requires_data_block_notifications = false
	if pending_load == "":
		# A world with no staged load can't inherit scratch stores —
		# wipe them or a crashed session's edits would bleed into this
		# world's terrain. Loads keep them: `_read_save` binds the
		# slot's files and unslotted tiles still ride scratch.
		_wipe_scratch_stores()
	if pending_load != "":
		await _load_stage("Reading the save")
		_site_state = await _read_save(pending_load)
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
		var tile := await _install_site_meso(
			_pending_world_tile, colony_site
		)
		_pending_world_tile = -1
		await _load_stage("Settling the site")
		region = Region.containing(colony_site)
		region.generate(world.generator_script)
		_fresh_site_tile = tile
	_regions[region.coordinate] = region
	world.region = region
	# A loaded region already knows its sites — reattach the live sim to
	# the one under the colony anchor; a fresh region registers it new.
	site = _site_at(colony_site)
	if site == null:
		site = region.add_site(colony_site, colony)
		site.world_tile = _fresh_site_tile
	else:
		site.colony = colony
	# The active site's anchor drives the mesh-wait and the camera —
	# a focus switch may have moved it far from the embark spot. The
	# scene's camera offset above the origin is preserved: at the
	# embark anchor this lands exactly where the scene placed it.
	colony_site = site.anchor
	$Overseer.global_position = (
		Vector3(site.anchor) + Vector3(0.0, 56.0, 24.0)
	)
	colony.unit_travelled.connect(_on_unit_travelled)
	if site.world_tile < 0:
		# A site with no tile on record — a fresh site in a loaded
		# region, or a save predating the planetary layer.
		site.world_tile = await _install_site_meso(-1, site.anchor)
	# The durable store binds at boot, while the viewer is still held
	# — `set_stream` on a live terrain reloads every loaded block, so
	# this is the one point the swap is free. `_read_save` may already
	# have bound it on a load; the guard in save_game keeps the same
	# instance for the session.
	if world.stream == null:
		world.stream = stream_for(site.world_tile)
	# The colony needs its bounds for periphery arrivals — the site's
	# record is the source of truth.
	colony.site_bounds = site.bounds
	# The slice shaders veil out-of-bounds fragments — the same rect,
	# declared in [shader_globals] like delve_slice_y.
	RenderingServer.global_shader_parameter_set(
		&"delve_bounds",
		Vector4(
			site.bounds.position.x, site.bounds.position.y,
			site.bounds.end.x, site.bounds.end.y
		)
	)
	if colony.scenario_id == &"":
		colony.scenario_id = DataPackage.scenario_id()
	_booting = false
	world_viewer.requires_data_block_notifications = true
	world_viewer.requires_collisions = true
	world_viewer.requires_visuals = true
	world_viewer.view_distance = _boot_view_distance
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


## The built globe once boot installed a meso — null before; travel
## routing and the World tab read it.
func globe() -> WorldGlobe:
	return _globe


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
		await _globe.generate(_loading_layer != null)
		_globe_key = key
		DLog.log("globe: %d tiles for seed %d" % [_globe.centers.size(), seed])
	return _globe


## Resolve the site's world tile ([param wanted] = a saved tile id, or
## -1 to pick the default settle tile), generate its MesoMap and pin the
## generator's regional layer to it. [param anchor] is the site voxel
## the meso plane's centre maps onto. Returns the tile id.
func _install_site_meso(
	wanted: int, anchor: Vector3i, site_bounds := Rect2i()
) -> int:
	await _load_stage("Generating planet")
	var globe: WorldGlobe = await _ensure_globe()
	var tile := wanted
	if tile < 0 or tile >= globe.centers.size() or globe.ocean[tile] != 0:
		# No tile on record, an id off the planet, or water — colonies
		# can't settle ocean or ice cap: fall back to the nearest land
		# to the reference direction.
		tile = globe.nearest_land_tile(WorldGlobe.default_settle_dir())
	await _load_stage("Surveying the region")
	meso = MesoMap.generate(globe, tile)
	var vg: Dictionary = meso.voxel_grid(
		Vector2i(anchor.x, anchor.z), world.generator_script.base_height
	)
	world.generator_script.install_regional_grid(
		vg["grid"], vg["origin"], vg["step"], vg["size"]
	)
	# The soil/hydrology pass samples the generator's raw surface —
	# it must run after the regional grid installs.
	await _load_stage("Shaping soils and water")
	site_field = await SiteField.generate(
		meso, world.generator_script, Vector2i(anchor.x, anchor.z),
		_loading_layer != null
	)
	world.generator_script.install_site_field(site_field)
	# Seed the live water store from the field's voxel-resolution
	# waterline — from here on the sim evolves it (gravity pour,
	# head-driven exchange, sources and drains) and every water query
	# on VoxelWorld answers from the live surface, not the datum.
	if world.sim != null:
		world.sim.water_seed_flood(
			site_field.flood, site_field.origin,
			site_field.side * site_field.cell_m,
			site_field.flags, site_field.cell_m
		)
		_install_river_boundaries(anchor, site_bounds)
	if water_view == null:
		water_view = WaterView.new()
		add_child(water_view)
	water_view.install(site_field, world)
	if flow_view == null:
		flow_view = FlowView.new()
		add_child(flow_view)
	flow_view.install(world)
	if slice_view == null:
		slice_view = SliceView.new()
		add_child(slice_view)
		$Overseer.slice_view = slice_view
		slice_view.focus = $Overseer
	slice_view.install(site_field, world)
	_apply_site_climate(globe, tile)
	return tile


## Wire the field's river reaches to live boundary conditions — PLAN
## item 51. Upstream-edge river cells take sources, exit-edge cells
## take drains, paired per wet component inside SiteField itself. The
## pairs re-derive from the field on every install — after a save-load
## the same call restores them, so nothing serializes.
func _install_river_boundaries(anchor: Vector3i, site_bounds: Rect2i) -> void:
	var bounds := (
		site_bounds if site_bounds.has_area() else Site.default_bounds(anchor)
	)
	var pairs := site_field.river_boundaries(
		bounds, world.generator_script, meso.precip_at(0.0, 0.0)
	)
	for s in pairs[&"sources"]:
		world.sim.water_set_source(s[&"pos"], s[&"rate"])
	for d in pairs[&"drains"]:
		world.sim.water_set_drain(d[&"pos"], d[&"rate"])
	DLog.log(
		"river boundaries: %d source cols, %d drain cols"
		% [pairs[&"sources"].size(), pairs[&"drains"].size()]
	)


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


func _process(delta: float) -> void:
	_tick_loading()
	_autosave_check()
	if _booting:
		return
	if _units_spawned:
		_tick_parties(delta)
		return
	_stage_text = "Loading terrain"
	var surface_y := world.predicted_surface_height(colony_site.x, colony_site.z)
	var site_voxel := Vector3i(colony_site.x, surface_y, colony_site.z)
	if not world.is_area_meshed(AABB(Vector3(site_voxel) - Vector3.ONE * 16.0, Vector3.ONE * 32.0)):
		return
	if _site_state.is_empty() and not _restoring:
		# A freshly settled site gets its ruins — wall edits into the
		# region log, building records and debris into the sim — before
		# the settlers land. Fresh settles only: a loaded site already
		# knows its ground, flag or no.
		Ruins.place(
			site, colony, world, region,
			world.generator_script, world.generator_script.world_seed
		)
		# Land in daylight: the site's longitude shifts its local time
		# off the planet clock — walk the clock forward to the next
		# local mid-morning so the embark isn't a night scramble.
		day_cycle.arrive_morning()
		_stage_text = "Settling settlers"
		_tick_loading()
		colony.spawn_initial_units(site_voxel)
	else:
		_stage_text = "Restoring the colony"
		_tick_loading()
		colony.deserialize(_site_state)
		_site_state = {}
	_units_spawned = true
	_autosave_last_msec = Time.get_ticks_msec()
	_loading_end()
	DLog.log("site ready at %s" % site_voxel)


## Wall-clock of the last autosave — real minutes, so a 6x game speed
## doesn't multiply the cadence.
var _autosave_last_msec := 0


## Fires save_game into the autosave slot on the configured cadence —
## wall clock, so game speed doesn't change how often it hits. Silent
## and synchronous: the write hitches the one frame every N minutes.
func _autosave_check() -> void:
	if _booting or not _units_spawned or region == null:
		return
	var minutes: int = GameOptions.autosave_minutes
	if minutes <= 0:
		return
	var now := Time.get_ticks_msec()
	if _autosave_last_msec == 0:
		_autosave_last_msec = now
		return
	if now - _autosave_last_msec < minutes * 60_000:
		return
	_autosave_last_msec = now
	save_game(AUTOSAVE_SLOT)


## The save slots under SAVE_DIR that hold a world.json, newest first —
## the title screen's Continue and slot list read this.
static func save_slots() -> Array:
	var slots: Array = []
	var top := DirAccess.open(SAVE_DIR)
	if top == null:
		return slots
	for slot_name in top.get_directories():
		var dir := SAVE_DIR.path_join(slot_name)
		var world_file := dir.path_join("world.json")
		if not FileAccess.file_exists(world_file):
			continue
		slots.append({
			"name": slot_name,
			"dir": dir,
			"mtime": FileAccess.get_modified_time(world_file),
		})
	slots.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return a["mtime"] > b["mtime"]
	)
	return slots


## The site whose bounds cover [param voxel], or null.
func _site_at(voxel: Vector3i) -> Site:
	for s: Site in region.sites:
		if s.bounds.has_point(Vector2i(voxel.x, voxel.z)):
			return s
	return null


## Saves the world: world.json (seed + planet clock + the region list +
## the active site + in-flight parties) plus one region file per touched
## tile — a region, not a site, is the save unit, so every site a
## session visited persists dormant beside the live one.
func save_game(slot := DEFAULT_SLOT) -> String:
	var dir := SAVE_DIR.path_join(slot)
	DirAccess.make_dir_recursive_absolute(dir)
	_set_save_dir(dir)
	# Item 66's durable stream: the store bound at boot follows the
	# slot via `_set_save_dir` above, so a save only flushes. The bind
	# is guarded — reassigning `set_stream` on a live terrain would
	# drop every loaded block and stall the save on a re-stream.
	if site != null and world.stream == null:
		world.stream = stream_for(site.world_tile)
	if world.stream != null:
		world.save_modified_blocks()
		if world.stream.has_method(&"flush"):
			world.stream.flush()
		# Logged edits living in loaded blocks just flushed into the
		# store — shed them. Entries for never-streamed cells keep
		# their log: nothing else records those cells.
		for voxel: Vector3i in (
			region.edits.keys() if region != null else []
		):
			var chunk := Vector3i(
				voxel.x >> Region.CHUNK_SHIFT,
				voxel.y >> Region.CHUNK_SHIFT,
				voxel.z >> Region.CHUNK_SHIFT
			)
			if world.has_data_block(chunk):
				region.discard_edit(voxel)
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
		# Which site the camera sits over — the load resolves it instead
		# of guessing at the first site carrying a payload.
		"active_site": (
			{
				"region": [
					Region.coord_of(site.anchor).x,
					Region.coord_of(site.anchor).y,
				],
				"site": site.id,
			}
			if site != null else {}
		),
		"parties": travel_parties.duplicate(true),
		"regions": [],
	}
	# Every region touched this session gets its file — dormant sites
	# and arrived parties live in whichever one owns their anchor.
	var coords := _regions.keys()
	coords.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x or (a.x == b.x and a.y < b.y)
	)
	for c: Vector2i in coords:
		var reg: Region = _regions[c]
		reg.planet_time = day_cycle.planet_time if day_cycle != null else 0.0
		world_data["regions"].append([c.x, c.y])
		_write_json(
			dir.path_join("region_%d_%d.json" % [c.x, c.y]), reg.serialize()
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
	_set_save_dir(dir)
	# Every region file in the save loads into the cache — dormant
	# sites and in-flight parties need their records live even while
	# the camera sits on the active one.
	var active_coord := Region.coord_of(colony_site)
	var active_id := -1
	var ad: Dictionary = world_data.get("active_site", {})
	if not ad.is_empty():
		var rc: Array = ad.get("region", [])
		if rc.size() == 2:
			active_coord = Vector2i(int(rc[0]), int(rc[1]))
		active_id = int(ad.get("site", -1))
	var coords: Array = world_data.get("regions", [[active_coord.x, active_coord.y]])
	for c: Array in coords:
		var coord := Vector2i(int(c[0]), int(c[1]))
		var data: Variant = _read_json(
			dir.path_join("region_%d_%d.json" % [coord.x, coord.y])
		)
		if data == null:
			push_error("save has no region file for %s" % coord)
			continue
		var reg := Region.deserialize(data)
		if reg != null:
			_regions[coord] = reg
	# Travellers resume mid-route on the same clock.
	travel_parties.clear()
	for pd: Dictionary in world_data.get("parties", []):
		travel_parties.append(pd)
	# The site the save staged — by id from active_site, or the
	# pre-item-65 rule: the first site still carrying a payload.
	var focus: Site = null
	var focus_region: Region = _regions.get(active_coord)
	if focus_region != null and active_id >= 0:
		for s: Site in focus_region.sites:
			if s.id == active_id:
				focus = s
	if focus == null:
		for reg2: Region in _regions.values():
			for s2: Site in reg2.sites:
				if focus == null and not s2.state.is_empty():
					focus = s2
					focus_region = reg2
	if focus == null:
		push_error("save has no site to settle")
		return {}
	# Seed the dead-plant guards before any block can stream — the
	# mesh wait fires block_loaded while colony.deserialize is still
	# pending, and an unseeded felled slot would re-register its
	# sapling and regrow under the load. deserialize wipes the fresh
	# record but not the voxels it painted, leaving a recordless snag.
	if colony != null and colony.forest != null:
		colony.forest.seed_destroyed(
			focus.state.get("forest", {}).get("destroyed", [])
		)
		colony.plants.seed_destroyed(
			focus.state.get("plants", {}).get("destroyed", [])
		)
	region = focus_region
	colony_site = focus.anchor
	_restoring = true
	await _load_stage("Restoring the site")
	focus.world_tile = await _install_site_meso(
		focus.world_tile, focus.anchor, focus.bounds
	)
	# The store binds before the boot hold releases the viewer — no
	# block may stream in ahead of it or a pristine generation would
	# read as current. A region still carrying a JSON log replays it
	# per chunk and sheds entries into the DB as it goes.
	var bound := stream_for(focus.world_tile)
	if bound != null and world.stream != bound:
		world.stream = bound
	return focus.state


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


# --- Multi-site travel (PLAN item 65) --------------------------------
#
# Sites live on different world tiles; the flat voxel space is
# partitioned so each tile owns a TILE_VOXEL_SPAN² patch, and a site's
# voxel anchor is `tile_origin + meso_cell * CELL_M` — which makes a
# site's position on its tile's meso recoverable from its anchor alone.
# Travellers leave as Colony payloads, ride a globe-tile route in
# `travel_parties` at TRAVEL_SPEED_MPS, and land at the destination
# site's rim — live sites spawn them walking in, dormant ones keep the
# payloads until activation.


## The world-space voxel origin of [param tile]'s meso patch — the
## anchor that puts the map's own centre at world (0,0). Tiles already
## hosting a site derive it from that site's record (anchor minus its
## meso offset); unsettled tiles get a deterministic slot.
func _tile_voxel_origin(tile: int) -> Vector2i:
	for reg: Region in _regions.values():
		for s: Site in reg.sites:
			if s.world_tile == tile:
				return (
					Vector2i(s.anchor.x, s.anchor.z)
					- s.meso_cell * MesoMap.CELL_M
				)
	return Vector2i(tile % 256, tile / 256) * TILE_VOXEL_SPAN


## The voxel anchor a site on [param tile] at meso [param cell] claims.
func _anchor_for(tile: int, cell: Vector2i) -> Vector3i:
	var o := _tile_voxel_origin(tile)
	return Vector3i(
		o.x + cell.x * MesoMap.CELL_M, 0, o.y + cell.y * MesoMap.CELL_M
	)


## The region tile covering [param coord] — from the session cache, or
## its file in the save dir this game loaded from, or fresh-empty.
func _region_at(coord: Vector2i) -> Region:
	var reg: Region = _regions.get(coord)
	if reg != null:
		return reg
	if _save_dir != "":
		var data: Variant = _read_json(
			_save_dir.path_join("region_%d_%d.json" % [coord.x, coord.y])
		)
		if data != null:
			reg = Region.deserialize(data)
			if reg != null:
				_regions[coord] = reg
				return reg
	reg = Region.containing(
		Vector3i(coord.x * Region.SIZE, 0, coord.y * Region.SIZE)
	)
	_regions[coord] = reg
	return reg


## Founds a dormant site record on [param tile] at meso [param cell] —
## a surveyed camp with no colony until travellers land or the player
## focuses it. Returns an existing site if the cell already sits in
## one's bounds.
func found_site(tile: int, cell: Vector2i) -> Site:
	var anchor := _anchor_for(tile, cell)
	var reg := _region_at(Region.coord_of(anchor))
	for s: Site in reg.sites:
		if s.bounds.has_point(Vector2i(anchor.x, anchor.z)):
			return s
	var s := reg.add_site(anchor)
	s.world_tile = tile
	s.meso_cell = cell
	DLog.log("site %d surveyed: tile %d, cell %s, anchor %s" % [
		s.id, tile, cell, anchor
	])
	return s


## The travel target record for an existing site — pure data so a
## unit's mid-walk save and a party's world.json entry both serialize.
func site_target(s: Site) -> Dictionary:
	var rc := Region.coord_of(s.anchor)
	return {
		&"site": s.id,
		&"region": [rc.x, rc.y],
		&"tile": s.world_tile,
		&"cell": [s.meso_cell.x, s.meso_cell.y],
		&"anchor": [s.anchor.x, s.anchor.y, s.anchor.z],
		&"label": "Site %d" % s.id,
	}


## The target record for a bare meso point — [param tile] and
## [param cell] — where arrival will found an incident site.
func point_target(tile: int, cell: Vector2i) -> Dictionary:
	var a := _anchor_for(tile, cell)
	return {
		&"site": -1,
		&"tile": tile,
		&"cell": [cell.x, cell.y],
		&"anchor": [a.x, a.y, a.z],
		&"label": "the wilds",
	}


## The dir the session's voxel stores live under — the save slot when
## one exists, otherwise the scratch root a never-saved world binds
## against.
func _stream_root() -> String:
	return _save_dir if _save_dir != "" else SCRATCH_ROOT


## Drop the scratch dir outright — only ever called on a fresh boot,
## when no stream can still hold one of its files open.
static func _wipe_scratch_stores() -> void:
	if not DirAccess.dir_exists_absolute(SCRATCH_ROOT):
		return
	var stack: Array[String] = [SCRATCH_ROOT]
	var dirs: Array[String] = []
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f: String in d.get_files():
			d.remove(f)
		for sub: String in d.get_directories():
			if sub != "." and sub != "..":
				stack.append(dir.path_join(sub))
		dirs.append(dir)
	# Deepest-first so parents empty before their own remove.
	dirs.reverse()
	for dir: String in dirs:
		DirAccess.remove_absolute(dir)


## The voxel-store path for [param tile] under the session's store
## root — one SQLite file per tile, named for it so several stores
## can sit side by side and a session can hold them all open.
func _voxels_db_path(tile: int) -> String:
	return _stream_root().path_join("voxels_tile_%d.sqlite" % tile)


## Point session reads at [param dir] — the slot the game loaded from
## or just saved into — and move every open store's file across: flush
## pending writes into the old path, copy it (with any SQLite
## sidecars), then repoint the stream's database_path. The stream
## instances survive a slot change; `world.stream` never needs
## rebinding, which matters because a mid-session `set_stream`
## reloads every loaded block.
func _set_save_dir(dir: String) -> void:
	if dir == _save_dir:
		return
	var old_root := _stream_root()
	_save_dir = dir
	for tile: int in _streams:
		var s: RefCounted = _streams[tile]
		if s.has_method(&"flush"):
			s.flush()
		var old_path := old_root.path_join("voxels_tile_%d.sqlite" % tile)
		var new_path := dir.path_join("voxels_tile_%d.sqlite" % tile)
		for suffix: StringName in [&"", &"-wal", &"-journal", &"-shm"]:
			if FileAccess.file_exists(old_path + suffix):
				DirAccess.copy_absolute(old_path + suffix, new_path + suffix)
		s.set_database_path(new_path)


## The durable stream for [param tile]'s voxel patch — one instance
## per store, created on first touch and cached so a focus hop back
## finds the same handle. Only the terrain's bound instance receives
## writes; the others idle, which is how a second live site would
## hold its own store open later. Unsaved worlds bind against
## `SCRATCH_ROOT`; the first save moves the file into the slot.
func stream_for(tile: int) -> RefCounted:
	var s: RefCounted = _streams.get(tile)
	if s != null:
		return s
	if not ClassDB.class_exists(&"VoxelStreamSQLite"):
		return null
	DirAccess.make_dir_recursive_absolute(_stream_root())
	s = ClassDB.instantiate(&"VoxelStreamSQLite")
	s.set_database_path(_voxels_db_path(tile))
	# Unmodified blocks regenerate deterministically — the store only
	# needs what the session changed.
	s.set_save_generator_output(false)
	s.set_key_cache_enabled(true)
	_streams[tile] = s
	return s


## Orders [param unit] to leave this site for [param target] (a
## site_target or point_target record). The unit walks to the rim on
## ordinary orders; `_travellers_tick` packs them once they arrive.
func send_unit_to(unit: Unit, target: Dictionary) -> bool:
	if unit == null or unit.dead or unit.travelling:
		return false
	if int(target.get(&"site", -1)) >= 0 and site != null:
		if (
			int(target[&"site"]) == site.id
			and target.get(&"region", []) == [
				Region.coord_of(site.anchor).x, Region.coord_of(site.anchor).y
			]
		):
			return false
	var a: Array = target.get(&"anchor", [])
	if a.size() != 3:
		return false
	var dest := Vector3i(int(a[0]), int(a[1]), int(a[2]))
	var bearing := Vector2(dest.x - site.anchor.x, dest.z - site.anchor.z)
	if bearing.length() < 0.01:
		bearing = Vector2.RIGHT
	target[&"bearing"] = [
		bearing.normalized().x, bearing.normalized().y
	]
	colony.send_traveller(unit, target)
	return true


## A unit reached the rim under travel orders — its payload joins a
## party bound for the target. Parties to the same destination merge:
## one column marches, not a convoy of singletons.
func _on_unit_travelled(payload: Dictionary, target: Dictionary) -> void:
	var dest_tile := int(target.get(&"tile", -1))
	var cell: Array = target.get(&"cell", [])
	var dest_cell := (
		Vector2i(int(cell[0]), int(cell[1])) if cell.size() == 2
		else Vector2i(MesoMap.SIDE / 2, MesoMap.SIDE / 2)
	)
	var from_tile := site.world_tile if site != null else -1
	var route := _route_tiles(from_tile, dest_tile)
	if route.is_empty():
		# No land route between the tiles — the party can't march an
		# ocean. The unit turns around and walks back in.
		DLog.log("travel refused: no land route to tile %d" % dest_tile)
		_restore_traveller(payload)
		return
	var dist := _route_distance(route, dest_cell)
	var dest_region: Array = target.get(&"region", [])
	if dest_region.size() != 2:
		var rc := Region.coord_of(_anchor_for(dest_tile, dest_cell))
		dest_region = [rc.x, rc.y]
	var dest_site := int(target.get(&"site", -1))
	for p: Dictionary in travel_parties:
		if (
			int(p.get("dest_site", -2)) == dest_site
			and p.get("dest_region", []) == dest_region
		):
			p["units"].append(payload)
			return
	travel_parties.append({
		"units": [payload],
		"route": Array(route),
		"progress_m": 0.0,
		"total_m": dist,
		"dest_tile": dest_tile,
		"dest_cell": [dest_cell.x, dest_cell.y],
		"dest_site": dest_site,
		"dest_region": dest_region,
		"bearing": target.get(&"bearing", [1.0, 0.0]),
		"label": String(target.get(&"label", "a site")),
	})


## A traveller whose route failed walks back in from the rim — the
## ordinary spawn + deserialize + arrive path a live arrival uses.
func _restore_traveller(payload: Dictionary) -> void:
	payload["travelling"] = false
	payload["departing"] = false
	payload["relieved"] = false
	payload["travel_target"] = {}
	var entry := colony.periphery_entry()
	payload["position"] = [entry.x + 0.5, entry.y + 4.0, entry.z + 0.5]
	# No walk-in order — a move ORDER holds its post forever, and the
	# restored unit's flags are already cleared: they stand at the rim
	# a moment, then the idle tick folds them back into the colony.
	colony._load_unit(payload)


## Land route between world tiles over the globe's hex adjacency —
## breadth-first, ocean tiles impassable on foot. [param from] ==
## [param to] yields the singleton route. Empty when unreachable.
func _route_tiles(from: int, to: int) -> PackedInt32Array:
	if from == to:
		return PackedInt32Array([from])
	if from < 0 or to < 0 or _globe == null:
		return PackedInt32Array()
	var came := PackedInt32Array()
	came.resize(WorldGlobe.TILE_COUNT)
	came.fill(-2)
	came[from] = -1
	var queue: Array[int] = [from]
	var head := 0
	while head < queue.size():
		var t: int = queue[head]
		head += 1
		if t == to:
			break
		for k in _globe.degree(t):
			var n := _globe.neighbour_of(t, k)
			if n < 0 or came[n] != -2 or _globe.ocean[n] != 0:
				continue
			came[n] = t
			queue.append(n)
	if came[to] == -2:
		return PackedInt32Array()
	var route := PackedInt32Array()
	var t := to
	while t != -1:
		route.push_back(t)
		t = came[t]
	route.reverse()
	return route


## Metres a route covers: same-tile legs measure on the meso (cells ×
## 100 m), inter-tile legs as tile-centre arcs on the planet's radius —
## the meso patch each hop crosses is ~15.6 km across either way.
func _route_distance(route: PackedInt32Array, dest_cell: Vector2i) -> float:
	if route.size() <= 1:
		var from_cell := (
			site.meso_cell if site != null
			else Vector2i(MesoMap.SIDE / 2, MesoMap.SIDE / 2)
		)
		return maxf(
			Vector2(from_cell - dest_cell).length() * MesoMap.CELL_M,
			float(MesoMap.CELL_M)
		)
	var d := 0.0
	for i in route.size() - 1:
		var a: Vector3 = _globe.centers[route[i]]
		var b: Vector3 = _globe.centers[route[i + 1]]
		d += WorldGlobe.RADIUS_M * acos(clampf(a.dot(b), -1.0, 1.0))
	return d


## Parties in flight gain ground on game-scaled time; arrival hands
## each one to _arrive_party.
func _tick_parties(delta: float) -> void:
	if travel_parties.is_empty():
		return
	var arrived: Array[Dictionary] = []
	for p: Dictionary in travel_parties:
		p["progress_m"] = float(p["progress_m"]) + TRAVEL_SPEED_MPS * delta
		if float(p["progress_m"]) >= float(p["total_m"]):
			arrived.append(p)
	for p: Dictionary in arrived:
		travel_parties.erase(p)
		_arrive_party(p)


## A party's route is done — resolve the destination site (founding an
## incident site when the target was bare ground), then: live site →
## each unit walks in from the rim on ordinary orders; dormant site →
## the payloads wait in its state until activation.
func _arrive_party(p: Dictionary) -> void:
	var dest_tile := int(p["dest_tile"])
	var c: Array = p["dest_cell"]
	var dest_cell := Vector2i(int(c[0]), int(c[1]))
	var b: Array = p.get("bearing", [1.0, 0.0])
	var bearing := Vector2(float(b[0]), float(b[1]))
	var rc: Array = p.get("dest_region", [])
	var reg := _region_at(
		Vector2i(int(rc[0]), int(rc[1])) if rc.size() == 2
		else Region.coord_of(_anchor_for(dest_tile, dest_cell))
	)
	var dest: Site = null
	var site_id := int(p.get("dest_site", -1))
	if site_id >= 0:
		for s: Site in reg.sites:
			if s.id == site_id:
				dest = s
	if dest == null:
		var anchor := _anchor_for(dest_tile, dest_cell)
		for s: Site in reg.sites:
			if s.bounds.has_point(Vector2i(anchor.x, anchor.z)):
				dest = s
	if dest == null:
		# Bare ground becomes a camp — the incident site the design's
		# off-site layer instantiates.
		dest = reg.add_site(_anchor_for(dest_tile, dest_cell))
		dest.world_tile = dest_tile
		dest.meso_cell = dest_cell
		DLog.log("party founded site %d at %s" % [dest.id, dest.anchor])
	var units: Array = p["units"]
	if dest.colony != null:
		# The live site — rim-spawn each traveller exactly like a fresh
		# settler: no walk-in order (a move ORDER holds its post as a
		# statue); they stand at the entry a moment, then idle into
		# colony work on their own.
		for ud: Dictionary in units:
			ud["travelling"] = false
			ud["departing"] = false
			ud["relieved"] = false
			ud["travel_target"] = {}
			var entry := colony.periphery_entry(bearing)
			ud["position"] = [entry.x + 0.5, entry.y + 4.0, entry.z + 0.5]
			colony._load_unit(ud)
	else:
		# Dormant — the payload joins the site record, staged at the rim
		# it would have entered from so activation lands them sensibly.
		var rim := _rim_cell(dest.bounds, bearing)
		var list: Array = dest.state.get("units", [])
		for ud: Dictionary in units:
			ud["travelling"] = false
			ud["departing"] = false
			ud["relieved"] = false
			ud["travel_target"] = {}
			ud["position"] = [rim.x + 0.5, 160.0, rim.y + 0.5]
			list.append(ud)
		dest.state["units"] = list
	DLog.log(
		"party arrived at site %d (%d travellers)"
		% [dest.id, units.size()]
	)


## The bounds edge cell a traveller on [param bearing] steps onto —
## the same "centre ray backwards along the bearing" as Colony's
## periphery_entry, in XZ so dormant sites need no live colony.
func _rim_cell(b: Rect2i, bearing: Vector2) -> Vector2i:
	var centre := Vector2(b.position) + Vector2(b.size) * 0.5
	var dir := bearing
	if dir.length() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var best := INF
	if dir.x > 0.001:
		best = minf(best, (b.end.x - centre.x) / dir.x)
	elif dir.x < -0.001:
		best = minf(best, (b.position.x - centre.x) / dir.x)
	if dir.y > 0.001:
		best = minf(best, (b.end.y - centre.y) / dir.y)
	elif dir.y < -0.001:
		best = minf(best, (b.position.y - centre.y) / dir.y)
	var p := centre - dir * best
	return Vector2i(
		clampi(int(p.x), b.position.x, b.end.x - 1),
		clampi(int(p.y), b.position.y, b.end.y - 1)
	)


## Move the camera to another site — deactivation/activation is the
## save/load machinery itself: the current colony serializes dormant
## into its record, the destination's payload (if any) is what the
## reload restores. Round-trips through the autosave slot so the
## player's manual save keeps pointing at wherever it was taken.
func focus_site(target: Site) -> bool:
	if target == null or target == site:
		return false
	site.state = colony.serialize()
	site.colony = null
	site = target
	region = _region_at(Region.coord_of(target.anchor))
	world.region = region
	save_game(AUTOSAVE_SLOT)
	load_game(AUTOSAVE_SLOT)
	return true
