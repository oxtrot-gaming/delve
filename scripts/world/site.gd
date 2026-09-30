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


func _init(site_id: int, site_anchor: Vector3i) -> void:
	id = site_id
	anchor = site_anchor
	bounds = Rect2i(
		anchor.x - DEFAULT_SIZE / 2, anchor.z - DEFAULT_SIZE / 2,
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
	return site
