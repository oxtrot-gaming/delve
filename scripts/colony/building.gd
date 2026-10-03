class_name Building
extends RefCounted

## A constructed thing at one or more voxels: a built wall block, a
## worksite — a designated place that needs no materials — or furniture
## like the bed, which claims two adjacent cells but fills none of them
## with terrain. The voxel block is still terrain; this record carries
## what the block alone can't: what the thing was built from. That is
## what lets deconstruction hand back exactly the items that went in,
## and what later lets building models recolor to their material.
enum Kind {
	WALL, WORKSITE, BED, LADDER, CAMPFIRE, DOOR, RECREATION, BUTCHER,
	MOUND, BARRICADE, CHARCOAL_MOUND, SMELTER, BLOOMERY
}

var kind: Kind
## The anchor cell — the first footprint voxel; single-cell buildings
## are just this.
var voxel: Vector3i
## Every cell the building claims — `voxel` plus any extra cells
## alongside it (a bed is two). Each maps to this record in
## [member Colony.buildings].
var footprint: Array[Vector3i] = []
## The unit using the building — beds take one sleeper at a time, a
## recreation building one player. Any other kind ignores it.
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
## Bed only: an established medical facility marker — patients delivered
## here are tended beyond first aid (wounds actually treated, medicine
## usable). Field care anywhere else only stops bleeding.
var medical := false


func _init(building_kind: Kind, building_voxel: Vector3i) -> void:
	kind = building_kind
	voxel = building_voxel
	footprint = [building_voxel]


## True for kinds that take worksite bills — the open crafting spot,
## the campfire, and the two furnaces. The charcoal mound takes none:
## it isn't a worksite, it's a single burn in progress.
func is_worksite() -> bool:
	return (
		kind == Kind.WORKSITE or kind == Kind.CAMPFIRE
		or kind == Kind.SMELTER or kind == Kind.BLOOMERY
	)


## True while a campfire is burning — lit means light (and, once the
## temperature model exists, heat), and it lets worksite bills run.
func lit() -> bool:
	return kind == Kind.CAMPFIRE and fuel > 0.0


## Partial-height fortifications — a mound or barricade fills enough of
## its cell to break a line of fire, but a unit can still scramble over
## it (slowly). Walls answer the same question with a solid block.
func provides_cover() -> bool:
	return kind == Kind.MOUND or kind == Kind.BARRICADE


## Player-facing name for the inspect panel.
func label() -> String:
	match kind:
		Kind.WALL:
			return BlockRegistry.block_name(block_id)
		Kind.WORKSITE:
			return "Crafting spot"
		Kind.BED:
			return "Medical bed" if medical else "Bed"
		Kind.LADDER:
			return "Ladder"
		Kind.CAMPFIRE:
			return "Campfire"
		Kind.DOOR:
			var door_label := String(spec).replace("_", " ")
			return door_label if door_label != "" else "Door"
		Kind.RECREATION:
			return BlockRegistry.rec_label(spec)
		Kind.BUTCHER:
			return "Butcher spot"
		Kind.MOUND:
			return "Dirt mound"
		Kind.BARRICADE:
			var built := BlockRegistry.resource_name_of(material)
			return (
				"%s barricade" % built.to_lower()
				if built != "None" else "Barricade"
			)
		Kind.CHARCOAL_MOUND:
			return "Charcoal mound"
		Kind.SMELTER:
			return "Pit smelter"
		Kind.BLOOMERY:
			return "Bloomery"
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
