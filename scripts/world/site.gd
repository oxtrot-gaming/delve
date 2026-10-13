class_name Site
extends RefCounted

## A colony-resolution play area embedded in a [Region] — the embed that
## makes the region the persistence unit rather than the site itself.
## A site owns its founding anchor, its bounds and the local sim while
## it's active; a region can hold several, dormant or live.

## Default extent of a fresh site, in voxel columns on a side — a
## little over the design's ~100×100 colony boundary so the record
## covers the margin the sim already generates. Descriptive today; it
## becomes the edit gate when the boundary work lands.
const DEFAULT_SIZE := 128

## Stable id within the region — sites serialize by id.
var id: int
## The founding voxel — spawn centre and the boundary's anchor.
var anchor: Vector3i
## The site's footprint on the region, in voxel columns (x/z).
var bounds: Rect2i
## The local sim while the site is instantiated — null for a dormant
## site whose state lives only in [member state].
var colony: Colony = null
## The serialized colony payload a dormant site carries — filled on
## region load, consumed when the site is instantiated, cleared once
## the live colony serializes over it on the next save.
var state: Dictionary = {}
## World tile (WorldGlobe hex/pent id) this site embeds in. The site's
## voxel columns map onto that tile's MesoMap tangent plane, anchored at
## the tile centre — approximate by design, never exact hex coincidence.
## -1 predates the planetary layer; the loader resolves it to the
## default settle tile.
var world_tile := -1
## The site's position on its tile's 160×160 meso map, in cells — where
## the map's centre lands in world voxel space is `anchor - meso_cell *
## CELL_M`. Sites on the same tile share the frame, so a settlement a
## kilometre east of embark reads as ten cells east on the World tab.
## Centred by default — a site's own meso installs centred on its
## anchor, so the embark site's record starts at the middle.
var meso_cell := Vector2i(MesoMap.SIDE / 2, MesoMap.SIDE / 2)
## True once the site's ruins have been laid — the pass runs when a
## site first gains a live colony, never again after.
var ruins_placed := false


func _init(site_id: int, site_anchor: Vector3i) -> void:
	id = site_id
	anchor = site_anchor
	bounds = default_bounds(site_anchor)


## The footprint a fresh site claims around its anchor — also what
## callers use to derive bounds before the Site record exists (river
## boundary wiring runs during meso install, ahead of site resolution).
static func default_bounds(site_anchor: Vector3i) -> Rect2i:
	return Rect2i(
		site_anchor.x - DEFAULT_SIZE / 2, site_anchor.z - DEFAULT_SIZE / 2,
		DEFAULT_SIZE, DEFAULT_SIZE
	)


func serialize() -> Dictionary:
	return {
		"id": id,
		"anchor": [anchor.x, anchor.y, anchor.z],
		"bounds": [
			bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y
		],
		"colony": colony.serialize() if colony != null else state.duplicate(),
		"tile": world_tile,
		"meso_cell": [meso_cell.x, meso_cell.y],
		"ruins_placed": ruins_placed,
	}


static func deserialize(data: Dictionary) -> Site:
	var site := Site.new(
		int(data["id"]),
		Vector3i(
			int(data["anchor"][0]), int(data["anchor"][1]), int(data["anchor"][2])
		)
	)
	var b: Array = data.get("bounds", [])
	if b.size() == 4:
		site.bounds = Rect2i(int(b[0]), int(b[1]), int(b[2]), int(b[3]))
	site.state = data.get("colony", {})
	site.world_tile = int(data.get("tile", -1))
	var cell: Array = data.get("meso_cell", [])
	if cell.size() == 2:
		site.meso_cell = Vector2i(int(cell[0]), int(cell[1]))
	site.ruins_placed = bool(data.get("ruins_placed", false))
	return site
