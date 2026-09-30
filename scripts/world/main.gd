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

@export var colony_site := Vector3i(0, 0, 0)

@onready var world: VoxelWorld = $VoxelWorld
@onready var colony: Colony = $Colony
@onready var day_cycle: DayCycle = $DayCycle

## The world-map tile the colony site embeds in — what saves serialize.
var region: Region
## This playthrough's site inside the region.
var site: Site

var _units_spawned: bool = false
## A staged load's colony payload for [member site] — consumed once the
## site's terrain has meshed.
var _site_state: Dictionary = {}


func _ready() -> void:
	DLog.open()
	if pending_load != "":
		_site_state = _read_save(pending_load)
		pending_load = ""
	if region == null:
		region = Region.containing(colony_site)
		region.generate(world.generator_script)
	world.region = region
	# A loaded region already knows its sites — reattach the live sim to
	# the one under the colony anchor; a fresh region registers it new.
	site = _site_at(colony_site)
	if site == null:
		site = region.add_site(colony_site, colony)
	else:
		site.colony = colony
	DLog.log("main ready: region %s, %d site(s)" % [region.coordinate, region.sites.size()])


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
	world.generator_script.world_seed = int(world_data["world_seed"])
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
	for s: Site in region.sites:
		if not s.state.is_empty():
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
