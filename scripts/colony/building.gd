class_name Building
extends RefCounted

## A constructed thing at a voxel: a built wall block, or a worksite — a
## designated place that needs no materials (the crafting spot, and later
## furniture and real workshops). The voxel block is still terrain; this
## record carries what the block alone can't: what the thing was built
## from. That is what lets deconstruction hand back exactly the items that
## went in, and what later lets building models recolor to their material.
enum Kind { WALL, WORKSITE }

var kind: Kind
var voxel: Vector3i
## The voxel block a wall is built of. AIR for a worksite, which occupies
## an open cell over solid ground.
var block_id: int = BlockRegistry.Block.AIR
## The material class the construction is made of — the wall's committed
## material. Worksites have no material requirements: NONE.
var material: BlockRegistry.Resource_ = BlockRegistry.Resource_.NONE
## The items absorbed into the construction. Deconstruction drops them
## back, whole and unchanged.
var components: Array[DropItem] = []
## False for a packed-dirt wall: tamped soil is indistinguishable from a
## natural dirt block and has to be mined out — there is nothing to take
## apart.
var deconstructable := true


func _init(building_kind: Kind, building_voxel: Vector3i) -> void:
	kind = building_kind
	voxel = building_voxel


## Player-facing name for the inspect panel.
func label() -> String:
	match kind:
		Kind.WALL:
			return BlockRegistry.block_name(block_id)
		Kind.WORKSITE:
			return "Crafting spot"
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
