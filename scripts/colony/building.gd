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
	MOUND, BARRICADE, CHARCOAL_MOUND, SMELTER, BLOOMERY, RESEARCH,
	METALWORK, FABRICATOR, GENERATOR, HEATER, COOLER, PYLON, TAILOR,
	SHELF, COMPOST_BIN, TOOLMAKER, TABLE, SEAT, LAMP, DECOR, STONECUTTER,
	FLOODGATE, WATER_WHEEL, PUMP, FENCE, GRAVE, SPIKE_TRAP,
	KILN, REFRACTORY, STONE_CRUSHER, STOVE
}

var kind: Kind
## The anchor cell — the first footprint voxel; single-cell buildings
## are just this.
var voxel: Vector3i
## Every cell the building claims — `voxel` plus any extra cells
## alongside it (a bed is two). Each maps to this record in
## [member Colony.buildings].
var footprint: Array[Vector3i] = []
## The unit using the building — recreation seats take one player at a
## time. For beds this is the first of [member occupants]; the single-
## sleeper code paths never needed to know the difference.
var occupant: Unit = null
## Every unit claiming a bed cell — a double bed sleeps two. The first
## claimant is also `occupant`; claims are transient (never serialized —
## a loaded colony re-seeks its rest like a fresh evening).
var occupants: Array = []
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
## A fuelled building's remaining fuel in burn-seconds — the campfire's
## ring is lit while it's above zero, the generator turns while it has
## charge. Fuel is consumed material: the items that fed it are gone,
## so teardown returns none.
var fuel := 0.0
## Whether a fuelled building asks for refuelling when it runs low —
## toggled on its inspect panel, defaulting on.
var auto_refuel := true
## Fraction of the fuel cap below which the "refuel campfire" job posts.
var refuel_fraction := 0.3
## Bed only: an established medical facility marker — patients delivered
## here are tended beyond first aid (wounds actually treated, medicine
## usable). Field care anywhere else only stops bleeding.
var medical := false
## Hit points remaining and the cap they regenerate toward via repair
## jobs — computed once at registration from what the thing is made of,
## not tracked per component (a stone wall is worth its stone, not its
## nineteen individual boulders and cobbles).
var hp := 0.0
var max_hp := 0.0
## Craft quality — 1.0 normal/unrated. Furniture and recreation builds
## carry their maker's roll: a bed's rest and care effects scale with
## it, a game board's recreation fill does. Beds take the kit's roll,
## not the furnisher's — the making is where skill lives.
var quality := 1.0
## The object's face-value beauty for room scoring and sight lines —
## 0 for plain structure; doors a token, furnishings scaled by the
## maker's roll. Derived at registration, not serialized.
var beauty := 0.0
## A wall block carrying an embedded power line — installed by an
## Electrician-rated conduit job, it turns the block into a net node
## devices and generators can tie into. Freestanding lines hang on a
## PYLON instead, which is a net node by kind.
var conduit := false
## The direction a cooler's cold side faces — the cell it draws heat
## from; the opposite face is the hot side it dumps to. ZERO for
## everything else.
var face_dir: Vector3i = Vector3i.ZERO
## True while the building sits on a power net with generation to
## spare — recomputed by the colony's power tick, never serialized.
var powered := false
## A floodgate's open fraction — [0,1] scales the flux across the
## cell's lateral edges in the water sim; 1.0 is the unregulated
## default. Serialized on the building record.
var open_fraction := 1.0
## A grave's interred dead — the species of the corpse laid in it
## (`&"colonist"` today; the field is species-keyed so a fallen pet
## could rest here later). Empty while the plot waits for a body.
## Serialized on the building record.
var buried: StringName = &""
## What a carved work shows — the species the carver chose at the
## chisel. Empty on everything but art; the unit-taste system reads it
## for the admire/resent thoughts. Serialized on the building record.
var depicts: StringName = &""

## HP per point of hardness — the block stats' work-seconds figure is
## the material truth combat durability builds on. A melee swing of
## ~8 dps wrecks a stone wall (2.0×60 = 120 hp) in about fifteen seconds
## of attention, a dirt mound in five.
const HP_PER_HARDNESS := 60.0
## Construction-style multipliers — partial-height cover and framed
## openings aren't worth the full solidity of a wall block.
const KIND_HP_MULT: Dictionary = {
	Kind.MOUND: 0.5,
	Kind.BARRICADE: 0.9,
	Kind.DOOR: 0.75,
	Kind.CHARCOAL_MOUND: 0.5,
	# Rails, not a wall — a fence reads lighter than its plank bill.
	Kind.FENCE: 0.4,
	# A mound and a marker — a grave weathers like a dirt pile.
	Kind.GRAVE: 0.5,
	# Sharpened stakes in a pit — the trap springs once and it's
	# kindling; the HP barely matters.
	Kind.SPIKE_TRAP: 0.3,
}


## The durability the record computes for itself once `kind`, `block_id`,
## `material` and `footprint` are settled. Walls rate their block's
## hardness (a stone wall is stone, whatever its pieces were); the rest
## rate their material class, defaulting to dirt-soft when unmaterial.
func compute_max_hp() -> float:
	var base := 1.0
	if block_id != BlockRegistry.Block.AIR:
		base = BlockRegistry.hardness(block_id)
	elif material != BlockRegistry.Resource_.NONE:
		base = BlockRegistry.material_hardness(int(material))
	var mult := float(KIND_HP_MULT.get(kind, 1.0))
	return base * mult * HP_PER_HARDNESS * footprint.size()


## 1.0 pristine down to 0 — the inspect line's integrity readout.
func integrity() -> float:
	return 1.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)


func _init(building_kind: Kind, building_voxel: Vector3i) -> void:
	kind = building_kind
	voxel = building_voxel
	footprint = [building_voxel]


## How many units the bed sleeps — the furniture spec's `sleeps` for a
## spec'd piece (double bed → 2), 1 for anything else. Only meaningful
## on BED kinds.
func bed_capacity() -> int:
	var spec_data := BlockRegistry.furniture_spec(spec)
	return int(spec_data.get(&"sleeps", 1))


## Claim the bed for [param unit], or return false when it's full.
## `occupant` stays the first claimant so medical-rescue and save code
## that predates multi-occupant beds keeps reading the right unit.
func claim_bed(unit: Unit) -> bool:
	if occupants.size() >= bed_capacity() or occupants.has(unit):
		return occupants.has(unit)
	occupants.append(unit)
	occupant = occupants[0]
	return true


## Release [param unit]'s claim — the first slot vacating hands
## `occupant` to the next sleeper in line.
func release_bed(unit: Unit) -> void:
	occupants.erase(unit)
	occupant = occupants[0] if not occupants.is_empty() else null


## True when the bed has room for another sleeper.
func bed_vacancy() -> bool:
	return occupants.size() < bed_capacity()


## True for kinds that take worksite bills — the open crafting spot,
## the campfire, the furnaces, the research bench, the metalworking
## benches, and the ceramics/metallurgy line's kiln, refractory,
## crusher and stove. The charcoal mound takes none: it isn't a
## worksite, it's a single burn in progress.
func is_worksite() -> bool:
	return (
		kind == Kind.WORKSITE or kind == Kind.CAMPFIRE
		or kind == Kind.SMELTER or kind == Kind.BLOOMERY
		or kind == Kind.RESEARCH or kind == Kind.METALWORK
		or kind == Kind.FABRICATOR or kind == Kind.TAILOR
		or kind == Kind.TOOLMAKER or kind == Kind.STONECUTTER
		or kind == Kind.KILN or kind == Kind.REFRACTORY
		or kind == Kind.STONE_CRUSHER or kind == Kind.STOVE
	)


## True for kinds that burn a fuel reserve — the campfire for light
## and cooking, the generator for current, the toolmaker's forge for
## working metal. They share the fuel, auto-refuel and threshold
## machinery; [method burns_passively] separates the kinds that
## consume the reserve just by standing from the ones that only burn
## while a bill runs.
func uses_fuel() -> bool:
	if kind == Kind.LAMP:
		# The torch lamp burns; the wired lamps draw from the net.
		return bool(
			BlockRegistry.furniture_spec(spec).get(&"burns", false)
		)
	return (
		kind == Kind.CAMPFIRE or kind == Kind.GENERATOR
		or kind == Kind.TOOLMAKER or kind == Kind.STOVE
	)


## True for fuelled kinds whose fire burns around the clock — the
## campfire and generator drain their reserve whether or not anyone
## works them. The toolmaker's forge burns only per job: a cold bench
## costs nothing to keep.
func burns_passively() -> bool:
	return (
		kind == Kind.CAMPFIRE or kind == Kind.GENERATOR
		or (kind == Kind.LAMP and uses_fuel())
	)


## True while a fuelled building is burning — the campfire's flame,
## the generator's firebox. Lit means light for the campfire and
## current for the generator, and it lets the campfire's bills run.
func lit() -> bool:
	return uses_fuel() and fuel > 0.0


## True while a lamp shines — the torch lamp while it has fuel, the
## wired lamps while the net powers them.
func lamp_lit() -> bool:
	return kind == Kind.LAMP and (lit() or powered)


## What the lamp radiates at zero distance — the spec's `light` for a
## lit lamp, 0 dark. [member Colony.light_at] applies the falloff.
func lamp_strength() -> float:
	if not lamp_lit():
		return 0.0
	return float(BlockRegistry.furniture_spec(spec).get(&"light", 0.0))


## Partial-height fortifications — a mound or barricade fills enough of
## its cell to break a line of fire, but a unit can still scramble over
## it (slowly). Walls answer the same question with a solid block.
func provides_cover() -> bool:
	return kind == Kind.MOUND or kind == Kind.BARRICADE


## Player-facing name for the inspect panel.
func label() -> String:
	match kind:
		Kind.WALL:
			# A typed rock names the wall — a granite ruin or a
			# granite-laid wall reads "Granite Wall", not the block's
			# generic name. Plain stone and wood keep their block's.
			var wall_name := BlockRegistry.block_name(block_id)
			if (
				BlockRegistry.is_rock_material(material)
				and material != BlockRegistry.Resource_.STONE
			):
				wall_name = "%s Wall" % (
					BlockRegistry.resource_name_of(material)
				)
			return (
				"%s (wired)" % wall_name
				if conduit
				else wall_name
			)
		Kind.WORKSITE:
			return "Crafting spot"
		Kind.BED:
			var bed_label := String(
				BlockRegistry.furniture_spec(spec).get(&"label", "bed")
			)
			if medical:
				bed_label = "medical %s" % bed_label
			return "%s %s" % [DropItem.quality_tier(quality), bed_label]
		Kind.LADDER:
			return "Ladder"
		Kind.CAMPFIRE:
			return "Campfire"
		Kind.DOOR:
			var door_label := String(spec).replace("_", " ")
			return door_label if door_label != "" else "Door"
		Kind.RECREATION:
			return "%s %s" % [
				DropItem.quality_tier(quality),
				BlockRegistry.rec_label(spec).to_lower(),
			]
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
		Kind.FENCE:
			var rail := BlockRegistry.resource_name_of(material)
			return (
				"%s fence" % rail.to_lower()
				if rail != "None" else "Fence"
			)
		Kind.FLOODGATE:
			return "Floodgate"
		Kind.WATER_WHEEL:
			return "Water wheel"
		Kind.PUMP:
			return "Pump"
		Kind.GRAVE:
			return (
				"Grave" if buried == &""
				else "Grave of a %s" % String(buried).replace("_", " ")
			)
		Kind.SPIKE_TRAP:
			return "Spike trap"
		Kind.CHARCOAL_MOUND:
			return "Charcoal mound"
		Kind.SMELTER:
			return "Pit smelter"
		Kind.BLOOMERY:
			return "Bloomery"
		Kind.RESEARCH:
			return "Research bench"
		Kind.METALWORK:
			return "Metalworker's bench"
		Kind.FABRICATOR:
			return "Fabrication bench"
		Kind.GENERATOR:
			return "Fuel-fired generator"
		Kind.HEATER:
			return "Electric heater"
		Kind.COOLER:
			return "Cooler"
		Kind.PYLON:
			return "Conduit pylon"
		Kind.TAILOR:
			return "Tailor's bench"
		Kind.SHELF:
			return "Shelf"
		Kind.COMPOST_BIN:
			return "Compost bin"
		Kind.TOOLMAKER:
			return "Toolmaker's bench"
		Kind.STONECUTTER:
			return "Stonecutter's bench"
		Kind.KILN:
			return "Kiln"
		Kind.REFRACTORY:
			return "Firebrick refractory"
		Kind.STONE_CRUSHER:
			return "Stone crusher"
		Kind.STOVE:
			return "Stove"
		Kind.TABLE, Kind.SEAT, Kind.LAMP, Kind.DECOR:
			var piece := String(
				BlockRegistry.furniture_spec(spec).get(&"label", "")
			)
			if piece == "":
				piece = "furniture"
			var named := "%s %s" % [DropItem.quality_tier(quality), piece]
			if depicts != &"":
				named += " of a %s" % Species.label(depicts)
			return named
	return "Building"


## The construction described as a material summary — "Stone: 120 blocks,
## Wood: 2 logs" — for the inspect panel.
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
