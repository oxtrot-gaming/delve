class_name Region
extends RefCounted

## A tile of the world map — the persistence unit (PLAN item 18).
## A region covers [constant SIZE]² voxel columns of world space, holds
## the sites embedded in it, and owns what persists at region scope:
## the terrain edit log (every voxel that differs from generator output)
## and the coarse heightfield summary.
##
## Terrain outside the edit log regenerates deterministically from the
## world seed, so a region file is small: coordinate, seeded summary,
## edits, and per-site state. Multiple sites can share one region —
## each [Site] serializes its own colony blob, and sites whose colony
## is dormant keep their last-saved payload.

## Voxel columns per region side. Big enough that a single site and its
## streaming margin sit comfortably inside one region; small enough that
## an edit log covering a colony's whole lifetime stays compact.
const SIZE := 256
## Side count of the coarse summary grid — one sample per 8 columns.
const CELLS := 32
## VoxelTerrain streams 16³ data blocks; edits index by that chunk so a
## loading block finds its deltas without scanning the whole log.
const CHUNK_SHIFT := 4
const SAVE_VERSION := 1

## The region's tile coordinate on the world map.
var coordinate: Vector2i
## Sites embedded here — live or dormant. Order is the stable id.
var sites: Array[Site] = []
## Terrain deltas from generator output: voxel → block id. Written by
## [method record_edit] (driven by the world's `block_edited` signal) on
## every mine, place, collapse removal and felling; replayed onto each
## streaming block as it loads — which is both save/load restore and the
## fix for chunk-unload amnesia.
var edits: Dictionary = {}
## chunk coord → set of edited voxels, for per-block replay.
var _edit_chunks: Dictionary = {}
## Coarse surface summary: CELLS² heights sampled from the local
## generator at creation. Derived data today — the detailed generator
## still owns terrain. When the two-layer split lands (DESIGN:
## surface = regional_base + local detail) this grid becomes an input.
var heights: PackedInt32Array


## The region tile containing [param voxel].
static func coord_of(voxel: Vector3i) -> Vector2i:
	return Vector2i(
		floori(float(voxel.x) / SIZE), floori(float(voxel.z) / SIZE)
	)


## A fresh region covering [param voxel]'s tile.
static func containing(voxel: Vector3i) -> Region:
	var region := Region.new()
	region.coordinate = coord_of(voxel)
	return region


## World-space voxel-column corner this region starts at.
func origin() -> Vector2i:
	return coordinate * SIZE


func contains_voxel(voxel: Vector3i) -> bool:
	return coord_of(voxel) == coordinate


func add_site(anchor: Vector3i, colony: Colony = null) -> Site:
	var site := Site.new(sites.size(), anchor)
	site.colony = colony
	sites.append(site)
	return site


## Fills the coarse summary: one surface_height sample at each cell's
## centre. Cheap at creation — CELLS² oracle calls, no streaming.
func generate(generator: WorldGenerator) -> void:
	heights.resize(CELLS * CELLS)
	var org := origin()
	var step := SIZE / CELLS
	for cz in CELLS:
		for cx in CELLS:
			heights[cz * CELLS + cx] = generator.surface_height(
				org.x + cx * step + step / 2, org.y + cz * step + step / 2
			)


## Records that [param voxel] now holds [param block_id] — the world's
## `block_edited` signal feeds this for every terrain write.
func record_edit(voxel: Vector3i, block_id: int) -> void:
	edits[voxel] = block_id
	var chunk := Vector3i(
		voxel.x >> CHUNK_SHIFT, voxel.y >> CHUNK_SHIFT, voxel.z >> CHUNK_SHIFT
	)
	_edit_chunks.get_or_add(chunk, {})[voxel] = true


## The edits landing in one streaming block — [param chunk] is the block
## coord [signal VoxelTerrain.block_loaded] reports, not a voxel.
func edits_in_chunk(chunk: Vector3i) -> Dictionary:
	var out := {}
	for voxel: Vector3i in _edit_chunks.get(chunk, {}):
		out[voxel] = edits[voxel]
	return out


func serialize() -> Dictionary:
	var edit_list: Array = []
	for voxel: Vector3i in edits:
		edit_list.append([voxel.x, voxel.y, voxel.z, int(edits[voxel])])
	var site_list: Array = []
	for site: Site in sites:
		site_list.append(site.serialize())
	return {
		"version": SAVE_VERSION,
		"coordinate": [coordinate.x, coordinate.y],
		"heights": Array(heights),
		"edits": edit_list,
		"sites": site_list,
	}


static func deserialize(data: Dictionary) -> Region:
	var region := Region.new()
	var coord: Array = data.get("coordinate", [0, 0])
	region.coordinate = Vector2i(int(coord[0]), int(coord[1]))
	region.heights = PackedInt32Array(data.get("heights", []))
	for e: Array in data.get("edits", []):
		region.record_edit(
			Vector3i(int(e[0]), int(e[1]), int(e[2])), int(e[3])
		)
	for s: Dictionary in data.get("sites", []):
		region.sites.append(Site.deserialize(s))
	return region
