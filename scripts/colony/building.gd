class_name Building
extends RefCounted

## A constructed thing at one or more voxels: a built wall block, a
## worksite — a designated place that needs no materials — or furniture
## like the bed, which claims two adjacent cells but fills none of them
## with terrain. The voxel block is still terrain; this record carries
## what the block alone can't: what the thing was built from. That is
## what lets deconstruction hand back exactly the items that went in,
## and what later lets building models recolor to their material.
enum Kind { WALL, WORKSITE, BED, LADDER, CAMPFIRE, DOOR }

var kind: Kind
## The anchor cell — the first footprint voxel; single-cell buildings
## are just this.
var voxel: Vector3i
## Every cell the building claims — `voxel` plus any extra cells
## alongside it (a bed is two). Each maps to this record in
## [member Colony.buildings].
var footprint: Array[Vector3i] = []
## The unit sleeping here — beds take one sleeper at a time. Any other
## kind ignores it.
var occupant: Unit = null
## The voxel block a wall is built of. AIR for a worksite, which occupies
## an open cell over solid ground.
var block_id: int = BlockRegistry.Block.AIR
## The material class the construction is made of — the wall's committed
## material. Worksites have no material requirements: NONE.
var material: BlockRegistry.Resource_ = BlockRegistry.Resource_.NONE
## The [constant BlockRegistry.BUILD_SPECS] key a wall or door was built
## as — two wood walls can differ (log vs plank), so the material alone
## isn't enough to name what stands here.
var spec: StringName = &""
## The items absorbed into the construction. Deconstruction drops them
## back, whole and unchanged.
var components: Array[DropItem] = []
## False for a packed-dirt wall: tamped soil is indistinguishable from a
## natural dirt block and has to be mined out — there is nothing to take
## apart.
var deconstructable := true
## A worksite's queued bills — first-in is next to run; an order whose
## inputs can't be found rotates to the back rather than blocking the
## line. Unused by walls, beds and ladders.
var orders: Array[WorksiteOrder] = []
## How many times a unit has opened this door — a bookkeeping detail the
## door keeps so the open/close rhythm (and the tests that watch it) can
## see the swing. Unserialized; other kinds ignore it.
var pass_count := 0
## A campfire's remaining fuel in burn-seconds — the fire is lit while
## it's above zero and goes dark when it runs dry. Fuel is consumed
## material: the items that fed it are gone, so teardown returns none.
var fuel := 0.0
## Whether the campfire asks for refuelling when it runs low — toggled
## on its inspect panel, defaulting on.
var auto_refuel := true
## Fraction of the fuel cap below which the "refuel campfire" job posts.
var refuel_fraction := 0.3


func _init(building_kind: Kind, building_voxel: Vector3i) -> void:
	kind = building_kind
	voxel = building_voxel
	footprint = [building_voxel]


## True for kinds that take worksite bills — the open crafting spot and
## the campfire. Anything else answers to no order queue.
func is_worksite() -> bool:
	return kind == Kind.WORKSITE or kind == Kind.CAMPFIRE


## True while a campfire is burning — lit means light (and, once the
## temperature model exists, heat), and it lets worksite bills run.
func lit() -> bool:
	return kind == Kind.CAMPFIRE and fuel > 0.0


## Player-facing name for the inspect panel.
func label() -> String:
	match kind:
		Kind.WALL:
			return BlockRegistry.block_name(block_id)
		Kind.WORKSITE:
			return "Crafting spot"
		Kind.BED:
			return "Bed"
		Kind.LADDER:
			return "Ladder"
		Kind.CAMPFIRE:
			return "Campfire"
		Kind.DOOR:
			var door_label := String(spec).replace("_", " ")
			return door_label if door_label != "" else "Door"
	return "Building"


## The construction described as a material summary — "Stone: 9 boulders,
## 10 cobbles" — for the inspect panel.
func describe_components() -> String:
	if components.is_empty():
		return ""
	var counts := {}
	var loose_volume := 0
	for item in components:
		if item.form == DropItem.Form.LOOSE:
			loose_volume += item.volume
		else:
			counts[item.form] = int(counts.get(item.form, 0)) + 1
	var parts: Array[String] = []
	var forms := counts.keys()
	forms.sort()
	for form in forms:
		var item_name := DropItem.form_name(form)
		parts.append("%d %s%s" % [counts[form], item_name, "s" if counts[form] != 1 else ""])
	if loose_volume > 0:
		parts.append("%.2f m³ loose" % (loose_volume / DropItem.CM3_PER_M3))
	return "%s: %s" % [BlockRegistry.resource_name_of(material), ", ".join(parts)]
