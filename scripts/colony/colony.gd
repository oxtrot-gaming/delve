class_name Colony
extends Node3D

## Owns the colony state: the job board, the units and the stockpile.
##
## The player never mines directly; they designate work, units claim jobs
## from here and report back when the work is done.

signal job_added(job: ColonyJob)
signal job_finished(job: ColonyJob)
signal unit_spawned(unit: Unit)
signal unit_died(unit: Unit)
signal unit_departed(unit: Unit)
## A settler walked off the rim under travel orders — the payload and
## destination record go to Main, which stages the off-site party
## (PLAN item 65). Emitted before the unit frees, unlike unit_departed.
signal unit_travelled(payload: Dictionary, target: Dictionary)
signal item_dropped(pile: ItemPile)

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const ANIMAL_SCENE := preload("res://scenes/animal.tscn")
const DLog := preload("res://scripts/dlog.gd")

## How far an item may wander while spilling before it is forced to settle.
const MAX_SPILL_HOPS := 16
## Loose items smaller than this settle instead of splitting again.
const MIN_LOOSE_CM3 := 10_000
## Loose fill past a fifth of a cell lifts whoever stands in it — the
## native standable rule's 0.2 headroom, mirrored for deposit guards.
const PILE_HEADROOM_CM3 := DropItem.BLOCK_CM3 / 5
const SPILL_SIDES: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]
## How long a unit that dropped a job waits before claiming it again —
## in game-time milliseconds, so the delay scales with speed controls.
const DROPPED_JOB_RETRY_MSEC := 10000
## Cap on the escalating retry delay for a repeatedly failed target.
const DROPPED_JOB_RETRY_MAX_MSEC := 120000
## Job-claim scoring — lowest score wins, measured in metres-equivalent
## so skill and patience trade directly against distance:
##   score = dist·DIST_WEIGHT − level·SKILL_WEIGHT − age·LANGUISH_RATE
## The skill weight is the per-unit stance: generalists get a mild nudge
## toward what they're good at, specialists let expertise dominate
## proximity. The languish term grows a job's appeal while it waits —
## the anti-starvation pressure that keeps unskilled busywork from
## never happening, capped so the boost stays bounded.
const CLAIM_DIST_WEIGHT := 1.0
const CLAIM_SKILL_GENERALIZE := 2.0
const CLAIM_SKILL_SPECIALIZE := 12.0
const CLAIM_LANGUISH_RATE := 0.25
const CLAIM_LANGUISH_CAP := 300.0
## Metres-equivalent a firefighting bill is worth — it outbids any
## ordinary job no matter how far across the site it sits.
const CLAIM_FIREFIGHT_BONUS := 400.0
## Metres-equivalent a designated role's favoured types are worth — a
## flat nudge on top of the skill read, loud enough for the appointee
## to take their lane at a walkable distance without outbidding a true
## specialist standing closer.
const CLAIM_ROLE_BONUS := 10.0

## A designated work bias — a unit's role names a small bundle of job
## types it argues for in claim scoring. Roles never forbid: every
## gate still lives in `job_block_reason` and `specialize` still owns
## how much the unit's skills count. This is the item-62 answer to a
## RimWorld-style work matrix — one pick per unit, additive only.
const ROLES: Dictionary = {
	&"generalist": [],
	&"labourer": [
		ColonyJob.Type.HAUL, ColonyJob.Type.CLEAR, ColonyJob.Type.BURY,
	],
	&"miner": [ColonyJob.Type.MINE],
	&"builder": [
		ColonyJob.Type.BUILD, ColonyJob.Type.DECONSTRUCT,
		ColonyJob.Type.FURNISH, ColonyJob.Type.REPAIR,
		ColonyJob.Type.UNINSTALL,
	],
	&"grower": [
		ColonyJob.Type.CHOP, ColonyJob.Type.FORAGE, ColonyJob.Type.SOW,
		ColonyJob.Type.FERTILIZE,
	],
	&"smith": [ColonyJob.Type.CRAFT, ColonyJob.Type.BURN],
	&"handler": [
		ColonyJob.Type.HUNT, ColonyJob.Type.TAME, ColonyJob.Type.BUTCHER,
	],
	&"medic": [
		ColonyJob.Type.TEND, ColonyJob.Type.SURGERY,
		ColonyJob.Type.RESCUE, ColonyJob.Type.ARREST,
	],
	&"steward": [ColonyJob.Type.CLEAN, ColonyJob.Type.REFUEL],
}
## Display names for the role picker — the Assign tab's row labels.
const ROLE_NAMES: Dictionary = {
	&"generalist": "Generalist",
	&"labourer": "Labourer",
	&"miner": "Miner",
	&"builder": "Builder",
	&"grower": "Grower",
	&"smith": "Smith",
	&"handler": "Handler",
	&"medic": "Medic",
	&"steward": "Steward",
}

## Craft orders a worksite accepts. Inputs count whole items by form
## (`form → count`); outputs list what drops at the spot. `waste` drops
## whatever volume the inputs had beyond the outputs as loose offcuts —
## a log's sawdust, or the plank volume that doesn't pack into a kit.
## Loose-material inputs can't count items — `input_cm3` gives a form's
## requirement in cm³ instead, and `input_material` pins a form to one
## material (a mound is soil, not gravel or meat scraps).
const RECIPES: Dictionary = {
	&"planks": {
		"label": "Craft planks",
		"inputs": {DropItem.Form.LOG: 1},
		"outputs": [{DropItem.Form.PLANK: 3}],
		"waste": true,
	},
	# Furniture — every piece is built in place through the `builds`
	# machinery: the unit hauls the recipe's inputs to the footprint and
	# assembles them there (or delivers a matching crate — reinstall
	# skips the inputs entirely). The use side — footprint, rest values,
	# lamp draw — lives in BlockRegistry.FURNITURE_SPECS under the same
	# key. Sleeping spots and bedrolls are free of the Complex furniture
	# gate; proper joinery is not.
	&"sleeping_spot": {
		"label": "Mark sleeping spot",
		"inputs": {},
		"outputs": [],
		"builds": Building.Kind.BED,
	},
	&"double_sleeping_spot": {
		"label": "Mark double sleeping spot",
		"inputs": {},
		"outputs": [],
		"builds": Building.Kind.BED,
	},
	&"bedroll": {
		"label": "Make bedroll",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEATHER: 200_000},
		"outputs": [],
		"builds": Building.Kind.BED,
	},
	&"double_bedroll": {
		"label": "Make double bedroll",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEATHER: 400_000},
		"outputs": [],
		"builds": Building.Kind.BED,
	},
	&"bed": {
		"label": "Build bed",
		"inputs": {DropItem.Form.PLANK: 5},
		"outputs": [],
		"builds": Building.Kind.BED,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"double_bed": {
		"label": "Build double bed",
		"inputs": {DropItem.Form.PLANK: 8},
		"outputs": [],
		"builds": Building.Kind.BED,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"royal_bed": {
		"label": "Build royal bed",
		# The trim is a sheet of precious metal — gold's the idea, but
		# the recipe can't pick the player's treasury for them.
		"inputs": {DropItem.Form.PLANK: 8, DropItem.Form.SHEET: 1},
		"outputs": [],
		"builds": Building.Kind.BED,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"hospital_bed": {
		"label": "Build hospital bed",
		"inputs": {DropItem.Form.SHEET: 4, DropItem.Form.COMPONENT: 2},
		"outputs": [],
		"builds": Building.Kind.BED,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	&"animal_bed": {
		"label": "Lay animal bed",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEAF: 200_000},
		"outputs": [],
		"builds": Building.Kind.DECOR,
	},
	&"stool": {
		"label": "Build stool",
		"inputs": {DropItem.Form.PLANK: 1},
		"outputs": [],
		"builds": Building.Kind.SEAT,
	},
	&"dining_chair": {
		"label": "Build dining chair",
		"inputs": {DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.SEAT,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"armchair": {
		"label": "Build armchair",
		"inputs": {DropItem.Form.PLANK: 3},
		"outputs": [],
		"builds": Building.Kind.SEAT,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"couch": {
		"label": "Build couch",
		"inputs": {DropItem.Form.PLANK: 5},
		"outputs": [],
		"builds": Building.Kind.SEAT,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"table_1x2": {
		"label": "Build table (1×2)",
		"inputs": {DropItem.Form.PLANK: 3},
		"outputs": [],
		"builds": Building.Kind.TABLE,
	},
	&"table_2x2": {
		"label": "Build table (2×2)",
		"inputs": {DropItem.Form.PLANK: 6},
		"outputs": [],
		"builds": Building.Kind.TABLE,
	},
	&"table_2x4": {
		"label": "Build table (2×4)",
		"inputs": {DropItem.Form.PLANK: 12},
		"outputs": [],
		"builds": Building.Kind.TABLE,
	},
	&"table_3x3": {
		"label": "Build table (3×3)",
		"inputs": {DropItem.Form.PLANK: 14},
		"outputs": [],
		"builds": Building.Kind.TABLE,
	},
	# The storage shelf's recipe lives with the production builds — the
	# furniture catalog's `shelf` spec rides the same `builds` entry, so
	# a furnish_shelf designation and the quick Shelf tool both reach it.
	&"small_shelf": {
		"label": "Build small shelf",
		"inputs": {DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.SHELF,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"end_table": {
		"label": "Build end table",
		"inputs": {DropItem.Form.PLANK: 1},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"dresser": {
		"label": "Build dresser",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"small_bookcase": {
		"label": "Build small bookcase",
		"inputs": {DropItem.Form.PLANK: 3},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"bookcase": {
		"label": "Build bookcase",
		"inputs": {DropItem.Form.PLANK: 6},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"plant_pot": {
		"label": "Build plant pot",
		"inputs": {DropItem.Form.PLANK: 1},
		"input_loose": {BlockRegistry.Resource_.SOIL: 50_000},
		"outputs": [],
		"builds": Building.Kind.DECOR,
	},
	# Art — carved works in dressed stone. Anyone may try a block, but
	# the quality roll rides the Art skill: a novice's statue is a lump
	# with a face, a master's fills a hall with beauty. No `requires`
	# gate — the roll is the gate.
	&"small_sculpture": {
		"label": "Carve small sculpture",
		"inputs": {DropItem.Form.BLOCK: 8},
		"input_material": {
			DropItem.Form.BLOCK: BlockRegistry.ROCK_MATERIALS
		},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"skill": ColonyJob.Skill.ART,
	},
	&"sculpture": {
		"label": "Carve sculpture",
		"inputs": {DropItem.Form.BLOCK: 20},
		"input_material": {
			DropItem.Form.BLOCK: BlockRegistry.ROCK_MATERIALS
		},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"skill": ColonyJob.Skill.ART,
	},
	&"grand_sculpture": {
		"label": "Carve grand sculpture",
		"inputs": {DropItem.Form.BLOCK: 45},
		"input_material": {
			DropItem.Form.BLOCK: BlockRegistry.ROCK_MATERIALS
		},
		"outputs": [],
		"builds": Building.Kind.DECOR,
		"skill": ColonyJob.Skill.ART,
	},
	&"torch_lamp": {
		"label": "Build torch lamp",
		# A split branch wrapped in fuel rag — it burns like the
		# campfire once lit, through the same fuel machinery.
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.BRANCH: 30_000},
		"outputs": [],
		"builds": Building.Kind.LAMP,
	},
	&"standing_lamp": {
		"label": "Build standing lamp",
		"inputs": {DropItem.Form.SHEET: 1, DropItem.Form.COMPONENT: 1},
		"outputs": [],
		"builds": Building.Kind.LAMP,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	&"floodlight": {
		"label": "Build floodlight",
		"inputs": {DropItem.Form.SHEET: 2, DropItem.Form.COMPONENT: 1},
		"outputs": [],
		"builds": Building.Kind.LAMP,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	&"sun_lamp": {
		"label": "Build sun lamp",
		"inputs": {DropItem.Form.SHEET: 4, DropItem.Form.COMPONENT: 3},
		"outputs": [],
		"builds": Building.Kind.LAMP,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	# A seed order: one fruit in, two seed packets out, keeping the
	# fruit's species for what farming will one day plant. The crafting
	# spot does it today; a dedicated building will do it better later.
	&"extract_seed": {
		"label": "Extract seed",
		"inputs": {DropItem.Form.FRUIT: 1},
		"outputs": [{DropItem.Form.SEED: 2}],
		"output_material": BlockRegistry.Resource_.SEED,
	},
	# Constructed in place rather than at a worksite: `builds` names the
	# building the escrowed inputs become, so the order is designated
	# directly onto its cell instead of a craft spot.
	&"ladder": {
		"label": "Build ladder",
		"inputs": {DropItem.Form.PLANK: 3},
		"outputs": [],
		"builds": Building.Kind.LADDER,
	},
	# A ring of cobbles — the bootstrap cookfire and light source before
	# stoves exist. Built in place like the ladder.
	&"campfire": {
		"label": "Build campfire",
		"inputs": {DropItem.Form.COBBLE: 5},
		"outputs": [],
		"builds": Building.Kind.CAMPFIRE,
	},
	# A flat rock to cut on — the butcher spot is nearly free like
	# RimWorld's, it just needs a surface to work over.
	&"butcher_spot": {
		"label": "Build butcher spot",
		"inputs": {DropItem.Form.COBBLE: 3},
		"outputs": [],
		"builds": Building.Kind.BUTCHER,
	},
	# A mound and a cobble marker — the grave is where a settler
	# corpse stops being clutter and starts being the camp's dead.
	&"grave": {
		"label": "Build grave",
		"inputs": {DropItem.Form.COBBLE: 4},
		"outputs": [],
		"builds": Building.Kind.GRAVE,
	},
	# The sharpened-stake pit — item 61's one-shot defense. Springs
	# once on whatever steps in, then it's splinters to lay again.
	&"spike_trap": {
		"label": "Set spike trap",
		"inputs": {DropItem.Form.PLANK: 3},
		"outputs": [],
		"builds": Building.Kind.SPIKE_TRAP,
	},
	# Provisional cover — sandbags want sand and bags, neither of which
	# exists yet, so the colony's first fortification is a mound of loose
	# dirt shovelled into a heap. Waist-high: it breaks a line of fire
	# and slows anyone scrambling over it, but blocks neither.
	&"dirt_mound": {
		"label": "Build dirt mound",
		"inputs": {DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: 400_000},
		"input_material": {DropItem.Form.LOOSE: BlockRegistry.Resource_.SOIL},
		"outputs": [],
		"builds": Building.Kind.MOUND,
	},
	# The carpenter's answer to the mound — a plank palisade waist-high.
	&"wood_barricade": {
		"label": "Build wood barricade",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.BARRICADE,
	},
	# A livestock rail — cheaper than a barricade, thinner than a wall:
	# settlers hop it, animals never path over it. The pen's real
	# boundary is the allowed area painted inside; the fence is what
	# keeps a bolting animal honest.
	&"wood_fence": {
		"label": "Build wooden fence",
		"inputs": {DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.FENCE,
	},
	# And the mason's — a low dry-laid cobble wall.
	&"stone_barricade": {
		"label": "Build stone barricade",
		"inputs": {DropItem.Form.COBBLE: 8},
		"outputs": [],
		"builds": Building.Kind.BARRICADE,
	},
	# A plank sluice dropped into a channel — a regulated edge rather
	# than a wall: closed it dams the cell's four lateral flows, part-
	# open it throttles them, open it passes for air.
	&"floodgate": {
		"label": "Build floodgate",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.FLOODGATE,
	},
	# A plank wheel standing in the flow — the river's motion becomes
	# watts on whatever net it touches, no fuel needed.
	&"water_wheel": {
		"label": "Build water wheel",
		"inputs": {DropItem.Form.PLANK: 6},
		"outputs": [],
		"builds": Building.Kind.WATER_WHEEL,
	},
	# A machine pump: components in a plank housing. Faces a picked
	# side — intake on the face, outflow off the back — and moves
	# water while powered.
	&"pump": {
		"label": "Build pump",
		"inputs": {DropItem.Form.COMPONENT: 2, DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.PUMP,
	},
	# Recreation furniture — all constructed in place like the campfire.
	# The use side (kind, fill rate, session length, sky need) lives in
	# BlockRegistry.REC_SPECS keyed by the same recipe name. Material
	# costs are provisional — revisit as new materials arrive.
	&"horseshoe_pin": {
		"label": "Build horseshoe pin",
		"inputs": {DropItem.Form.LOG: 1, DropItem.Form.COBBLE: 3},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
	},
	&"hoopstone_ring": {
		"label": "Build hoopstone ring",
		"inputs": {DropItem.Form.COBBLE: 5},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
	},
	&"ur_board": {
		"label": "Build game-of-Ur board",
		"inputs": {DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"tafl_table": {
		"label": "Build tafl table",
		"inputs": {DropItem.Form.PLANK: 5},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"billiards_table": {
		"label": "Build billiards table",
		"inputs": {DropItem.Form.PLANK: 7},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"poker_table": {
		"label": "Build poker table",
		"inputs": {DropItem.Form.PLANK: 7},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
		"requires": ColonyJob.Skill.COMPLEX_FURNITURE,
	},
	&"telescope": {
		"label": "Build telescope",
		"inputs": {DropItem.Form.PLANK: 3, DropItem.Form.COBBLE: 3},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
	},
	&"harp": {
		"label": "Build harp",
		"inputs": {DropItem.Form.PLANK: 5},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
	},
	&"harpsichord": {
		"label": "Build harpsichord",
		"inputs": {DropItem.Form.PLANK: 8},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
	},
	&"piano": {
		"label": "Build piano",
		"inputs": {DropItem.Form.PLANK: 10},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
	},
	# The power-era relaxer — a sheet-and-component set that only works
	# while a live net touches it (its watts live in REC_SPECS, where
	# `device_watts` reads the draw).
	&"television": {
		"label": "Build television",
		"inputs": {
			DropItem.Form.SHEET: 2,
			DropItem.Form.WIRE: 2,
			DropItem.Form.COMPONENT: 3,
		},
		"input_material": {DropItem.Form.WIRE: BlockRegistry.Resource_.COPPER},
		"outputs": [],
		"builds": Building.Kind.RECREATION,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	# Raw fruit in, one meal out. `site` pins the bill to the campfire —
	# a bare crafting spot can't cook. `nutrition_mult` is the cook's
	# bonus over the raw inputs; `skill`/`xp` override the job type's
	# defaults so cooking trains Cooking, not Crafting, and ten meals
	# carry a level-0 cook to level 1.
	&"prepare_meal": {
		"label": "Prepare meal",
		"inputs": {DropItem.Form.FRUIT: 4},
		"outputs": [{DropItem.Form.MEAL: 1}],
		"output_material": BlockRegistry.Resource_.MEAL,
		# The campfire boils it; the stove does it faster — a regulated
		# firebox beats an open ring. The real stove tier is the stew.
		"sites": {
			Building.Kind.CAMPFIRE: 1.0, Building.Kind.STOVE: 1.5,
		},
		"nutrition_mult": 1.75,
		"skill": ColonyJob.Skill.COOKING,
		"xp": 1.0,
	},
	# Preservation, not cuisine: meat and fruit dried and pounded into
	# a brick that keeps for seasons. A thinner nutrition bonus than a
	# cooked meal — the trade is shelf life, which is how a colony with
	# no freezer banks a hunt. The tribe's common knowledge.
	&"make_pemmican": {
		"label": "Make pemmican",
		"inputs": {DropItem.Form.FRUIT: 2},
		# Any gathered fruit or grain works for the plant half — but not
		# heal-all, which is a fruit item the medicine chest can't spare.
		"input_material": {
			DropItem.Form.FRUIT: [
				BlockRegistry.Resource_.BERRY,
				BlockRegistry.Resource_.ACORN,
				BlockRegistry.Resource_.GRAIN,
			],
		},
		"input_loose": {BlockRegistry.Resource_.MEAT: 5_000},
		"outputs": [{DropItem.Form.MEAL: 1}],
		"output_material": BlockRegistry.Resource_.PEMMICAN,
		"sites": {
			Building.Kind.CAMPFIRE: 1.0, Building.Kind.STOVE: 1.5,
		},
		"nutrition_mult": 1.4,
		"skill": ColonyJob.Skill.COOKING,
		"xp": 0.75,
	},
	# The stove tier — a pot that actually simmers: meat and produce
	# married into a meal worth more than its parts. An open campfire
	# can't hold the heat a stew wants; only the steel box does.
	&"cook_stew": {
		"label": "Cook stew",
		"inputs": {DropItem.Form.FRUIT: 2},
		"input_loose": {BlockRegistry.Resource_.MEAT: 5_000},
		"outputs": [{DropItem.Form.MEAL: 1}],
		"output_material": BlockRegistry.Resource_.MEAL,
		"site": Building.Kind.STOVE,
		"nutrition_mult": 2.2,
		"skill": ColonyJob.Skill.COOKING,
		"xp": 1.5,
	},
	# A covered wood stack that smoulders into charcoal — one log and a
	# tenth of a cubic metre of branches in, then a long supervised burn
	# (the BURN job posts on completion, gated by Charcoal burning).
	&"charcoal_mound": {
		"label": "Build charcoal mound",
		"inputs": {DropItem.Form.LOG: 1, DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: 100_000},
		"input_material": {DropItem.Form.LOOSE: BlockRegistry.Resource_.BRANCH},
		"outputs": [],
		"builds": Building.Kind.CHARCOAL_MOUND,
	},
	# A plank workbench for the Study action: units reverse-engineer a
	# manufactured item there — the bill's specimen — for XP in the
	# skill that makes it. Built in place like the campfire.
	&"research_bench": {
		"label": "Build research bench",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.RESEARCH,
	},
	# The metalwork chain — beaten sheets and drawn wire from smelted
	# stock, one recipe per metal so the fetch pins the material. A
	# bare crafting spot can do it at half rate (`sites` maps each
	# accepting worksite kind to its speed multiplier); the
	# metalworker's bench is where the work belongs.
	&"sheet_metal_copper": {
		"label": "Beat copper sheet",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.COPPER: DropItem.SHEET_CM3},
		"outputs": [{DropItem.Form.SHEET: 1}],
		"output_material": BlockRegistry.Resource_.COPPER,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	&"sheet_metal_tin": {
		"label": "Beat tin sheet",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.TIN: DropItem.SHEET_CM3},
		"outputs": [{DropItem.Form.SHEET: 1}],
		"output_material": BlockRegistry.Resource_.TIN,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	&"sheet_metal_iron": {
		"label": "Beat iron sheet",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.IRON: DropItem.SHEET_CM3},
		"outputs": [{DropItem.Form.SHEET: 1}],
		"output_material": BlockRegistry.Resource_.IRON,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
	},
	&"sheet_metal_gold": {
		"label": "Beat gold sheet",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.GOLD: DropItem.SHEET_CM3},
		"outputs": [{DropItem.Form.SHEET: 1}],
		"output_material": BlockRegistry.Resource_.GOLD,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	# The alloys beat out like the native metals — bronze is the
	# refractory's low-tier pour, steel the sheet a stove's firebox is
	# riveted from.
	&"sheet_metal_bronze": {
		"label": "Beat bronze sheet",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.BRONZE: DropItem.SHEET_CM3},
		"outputs": [{DropItem.Form.SHEET: 1}],
		"output_material": BlockRegistry.Resource_.BRONZE,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	&"sheet_metal_steel": {
		"label": "Beat steel sheet",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.STEEL: DropItem.SHEET_CM3},
		"outputs": [{DropItem.Form.SHEET: 1}],
		"output_material": BlockRegistry.Resource_.STEEL,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
	},
	&"wire_copper": {
		"label": "Draw copper wire",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.COPPER: 10_000},
		"outputs": [{DropItem.Form.WIRE: 4}],
		"output_material": BlockRegistry.Resource_.COPPER,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	&"wire_tin": {
		"label": "Draw tin wire",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.TIN: 10_000},
		"outputs": [{DropItem.Form.WIRE: 4}],
		"output_material": BlockRegistry.Resource_.TIN,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	&"wire_iron": {
		"label": "Draw iron wire",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.IRON: 10_000},
		"outputs": [{DropItem.Form.WIRE: 4}],
		"output_material": BlockRegistry.Resource_.IRON,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
	},
	&"wire_gold": {
		"label": "Draw gold wire",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.GOLD: 10_000},
		"outputs": [{DropItem.Form.WIRE: 4}],
		"output_material": BlockRegistry.Resource_.GOLD,
		"sites": {Building.Kind.WORKSITE: 0.5, Building.Kind.METALWORK: 1.0},
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	# Gears and cams for powered machinery — loose metal in, discrete
	# components out. "Three raw iron and two raw copper" reads at the
	# 10k cm³ chunk the metal trades in. Fabrication bench only.
	&"machine_components": {
		"label": "Make machine components",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.IRON: 30_000,
			BlockRegistry.Resource_.COPPER: 20_000,
		},
		"outputs": [{DropItem.Form.COMPONENT: 5}],
		"output_material": BlockRegistry.Resource_.IRON,
		"site": Building.Kind.FABRICATOR,
		"skill": ColonyJob.Skill.MANUFACTURING,
	},
	# The power-era construction set. The benches are ungated; the
	# powered machines need an Electrician (the cooler wants HVAC on
	# top), and their housings take plank-or-sheet — the sheet fills
	# the plank slot by substitution. Copper wire is pinned: a tin
	# draw won't carry the current.
	&"metalwork_bench": {
		"label": "Build metalworker's bench",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.METALWORK,
	},
	&"fabricator": {
		"label": "Build fabrication bench",
		"inputs": {DropItem.Form.PLANK: 4, DropItem.Form.COMPONENT: 2},
		"outputs": [],
		"builds": Building.Kind.FABRICATOR,
	},
	&"fuel_generator": {
		"label": "Build fuel generator",
		"inputs": {
			DropItem.Form.SHEET: 2,
			DropItem.Form.WIRE: 2,
			DropItem.Form.COMPONENT: 3,
		},
		"input_material": {DropItem.Form.WIRE: BlockRegistry.Resource_.COPPER},
		"outputs": [],
		"builds": Building.Kind.GENERATOR,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	&"electric_heater": {
		"label": "Build electric heater",
		"inputs": {
			DropItem.Form.PLANK: 1,
			DropItem.Form.WIRE: 1,
			DropItem.Form.COMPONENT: 1,
		},
		"input_material": {DropItem.Form.WIRE: BlockRegistry.Resource_.COPPER},
		"outputs": [],
		"builds": Building.Kind.HEATER,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	&"cooler": {
		"label": "Build cooler",
		"inputs": {
			DropItem.Form.PLANK: 1,
			DropItem.Form.WIRE: 1,
			DropItem.Form.COMPONENT: 3,
		},
		"input_material": {DropItem.Form.WIRE: BlockRegistry.Resource_.COPPER},
		"outputs": [],
		"builds": Building.Kind.COOLER,
		"requires": [ColonyJob.Skill.ELECTRICIAN, ColonyJob.Skill.HVAC],
	},
	# Freestanding conduit: a post of hard material strung with copper.
	# Lines that can hide in a wall instead ride `designate_conduit`,
	# which needs no post.
	&"conduit_pylon": {
		"label": "Build conduit pylon",
		"inputs": {DropItem.Form.BOULDER: 1, DropItem.Form.WIRE: 1},
		"input_material": {DropItem.Form.WIRE: BlockRegistry.Resource_.COPPER},
		"outputs": [],
		"builds": Building.Kind.PYLON,
		"requires": ColonyJob.Skill.ELECTRICIAN,
	},
	# The textile chain — all of it behind the tailor's bench. The
	# bench itself is four planks; weaving raw cotton pours cloth and
	# returns the seed the next sowing needs (the packets' species comes
	# from FRUIT_SPECIES via the input material, like extract-seed's).
	&"tailor_bench": {
		"label": "Build tailor's bench",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.TAILOR,
	},
	# The shelf — a one-cell storage building whose cell is a stockpile
	# tile: the same reject-filter model, twice the floor's capacity.
	&"shelf": {
		"label": "Build shelf",
		"inputs": {DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.SHELF,
	},
	# The compost bin — a one-cell storage building like the shelf, but
	# its filter takes only what rots to compost and its pile rots three
	# times as fast. The finished compost hauls out to a normal zone.
	&"compost_bin": {
		"label": "Build compost bin",
		"inputs": {DropItem.Form.PLANK: 4},
		"outputs": [],
		"builds": Building.Kind.COMPOST_BIN,
	},
	&"cotton_cloth": {
		"label": "Weave cotton cloth",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.COTTON: 20_000},
		"outputs": [{DropItem.Form.SEED: 3}],
		"output_material": BlockRegistry.Resource_.SEED,
		"output_loose": {BlockRegistry.Resource_.CLOTH: 15_000},
		"site": Building.Kind.TAILOR,
	},
	# Garments — `output_spec` names the APPAREL_SPECS record the
	# finished piece wears, and the input material carries over as the
	# garment's own (a leather tribalwear stays leather). One variant
	# per textile, the same way the sheet metals vary by ore.
	&"garb_tribal": {
		"label": "Make tribalwear (cloth)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.CLOTH: 20_000},
		"outputs": [{DropItem.Form.GARMENT: 1}],
		"output_spec": &"tribalwear",
		"site": Building.Kind.TAILOR,
	},
	&"garb_tribal_leather": {
		"label": "Make tribalwear (leather)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEATHER: 20_000},
		"outputs": [{DropItem.Form.GARMENT: 1}],
		"output_spec": &"tribalwear",
		"site": Building.Kind.TAILOR,
	},
	&"tool_belt": {
		"label": "Make tool belt (leather)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEATHER: 8_000},
		"outputs": [{DropItem.Form.GARMENT: 1}],
		"output_spec": &"tool_belt",
		"site": Building.Kind.TAILOR,
	},
	&"tool_belt_cloth": {
		"label": "Make tool belt (cloth)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.CLOTH: 8_000},
		"outputs": [{DropItem.Form.GARMENT: 1}],
		"output_spec": &"tool_belt",
		"site": Building.Kind.TAILOR,
	},
	&"backpack": {
		"label": "Make backpack (cloth)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.CLOTH: 18_000},
		"outputs": [{DropItem.Form.GARMENT: 1}],
		"output_spec": &"backpack",
		"site": Building.Kind.TAILOR,
	},
	&"backpack_leather": {
		"label": "Make backpack (leather)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEATHER: 18_000},
		"outputs": [{DropItem.Form.GARMENT: 1}],
		"output_spec": &"backpack",
		"site": Building.Kind.TAILOR,
	},
	# Containers — bags come off the tailor's frame from textiles,
	# boxes get nailed together anywhere from sheet goods. `output_spec`
	# names the CONTAINER_SPECS record: it carries the tare, capacity
	# and the accept whitelist, so the craft itself stays generic.
	&"sew_sack": {
		"label": "Sew sack (cloth)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.CLOTH: 8_000},
		"outputs": [{DropItem.Form.CRATE: 1}],
		"output_spec": &"sack",
		"site": Building.Kind.TAILOR,
	},
	&"sew_sack_leather": {
		"label": "Sew sack (leather)",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.LEATHER: 8_000},
		"outputs": [{DropItem.Form.CRATE: 1}],
		"output_spec": &"sack",
		"site": Building.Kind.TAILOR,
	},
	&"sew_seed_pouch": {
		"label": "Sew seed pouch",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.CLOTH: 3_000},
		"outputs": [{DropItem.Form.CRATE: 1}],
		"output_spec": &"seed_pouch",
		"site": Building.Kind.TAILOR,
	},
	&"nail_box": {
		"label": "Nail box (plank)",
		"inputs": {DropItem.Form.PLANK: 1},
		"outputs": [{DropItem.Form.CRATE: 1}],
		"output_spec": &"box",
	},
	&"nail_box_metal": {
		"label": "Nail box (sheet)",
		"inputs": {DropItem.Form.SHEET: 2},
		"outputs": [{DropItem.Form.CRATE: 1}],
		"output_spec": &"box",
	},
	# The toolmaker's bench — an anvil-stone and a frame. Its forge
	# burns fuel only while a bill runs, like a kiln lit per firing.
	&"toolmaker": {
		"label": "Build toolmaker's bench",
		"inputs": {DropItem.Form.PLANK: 3, DropItem.Form.COBBLE: 4},
		"outputs": [],
		"builds": Building.Kind.TOOLMAKER,
	},
	# The stonecutter's bench — a plank frame carrying a boulder's
	# worth of cutting bed. It has to stand before its own product
	# exists, so the bed is field stone, not blocks.
	&"stonecutter_bench": {
		"label": "Build stonecutter's bench",
		"inputs": {DropItem.Form.PLANK: 2, DropItem.Form.BOULDER: 1},
		"outputs": [],
		"builds": Building.Kind.STONECUTTER,
	},
	# The primitive tool set — a cobble head lashed to a haft at any
	# crafting spot. The rod slot takes branches or any other rod
	# material (`input_material`'s array pin) and prices by volume;
	# `output_material` gives the item the head's material class, which
	# is what repairability and the repair bill key on.
	&"stone_axe": {
		"label": "Knap stone axe",
		"inputs": {DropItem.Form.LOOSE: 0, DropItem.Form.COBBLE: 2},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"stone_axe",
		"output_material": BlockRegistry.Resource_.STONE,
		"xp": 2.0,
	},
	&"stone_shovel": {
		"label": "Knap stone shovel",
		"inputs": {DropItem.Form.LOOSE: 0, DropItem.Form.COBBLE: 2},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"stone_shovel",
		"output_material": BlockRegistry.Resource_.STONE,
		"xp": 2.0,
	},
	&"stone_pick": {
		"label": "Knap stone pick",
		"inputs": {DropItem.Form.LOOSE: 0, DropItem.Form.COBBLE: 2},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"stone_pick",
		"output_material": BlockRegistry.Resource_.STONE,
		"xp": 2.0,
	},
	# The forged set — the same haft plus two units of raw iron, at the
	# toolmaker's bench. Faster and far longer-lived than knapped
	# stone, and repairable when they wear. Iron work is bloomery
	# knowledge: nobody forges a metal they can't smelt.
	&"iron_axe": {
		"label": "Forge iron axe",
		"inputs": {DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"input_loose": {BlockRegistry.Resource_.IRON: TOOL_METAL_CM3 * 2},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"iron_axe",
		"output_material": BlockRegistry.Resource_.IRON,
		"site": Building.Kind.TOOLMAKER,
		"skill": ColonyJob.Skill.MANUFACTURING,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
		"xp": 4.0,
	},
	&"iron_shovel": {
		"label": "Forge iron shovel",
		"inputs": {DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"input_loose": {BlockRegistry.Resource_.IRON: TOOL_METAL_CM3 * 2},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"iron_shovel",
		"output_material": BlockRegistry.Resource_.IRON,
		"site": Building.Kind.TOOLMAKER,
		"skill": ColonyJob.Skill.MANUFACTURING,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
		"xp": 4.0,
	},
	&"iron_pick": {
		"label": "Forge iron pick",
		"inputs": {DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"input_loose": {BlockRegistry.Resource_.IRON: TOOL_METAL_CM3 * 2},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"iron_pick",
		"output_material": BlockRegistry.Resource_.IRON,
		"site": Building.Kind.TOOLMAKER,
		"skill": ColonyJob.Skill.MANUFACTURING,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
		"xp": 4.0,
	},
	# The weapon bills (item 61) — a hafted point and a sprung stave,
	# both bench work. No forge knowledge needed: these are sharpened
	# stick and cord, not steel.
	&"spear": {
		"label": "Make spear",
		"inputs": {DropItem.Form.LOOSE: 0, DropItem.Form.COBBLE: 1},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"spear",
		"output_material": BlockRegistry.Resource_.STONE,
		"site": Building.Kind.TOOLMAKER,
		"skill": ColonyJob.Skill.MANUFACTURING,
		"xp": 3.0,
	},
	&"bow": {
		"label": "Make hunting bow",
		"inputs": {DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: DropItem.ROD_CM3 * 2},
		"input_material": {DropItem.Form.LOOSE: DropItem.ROD_MATERIALS},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"bow",
		"output_material": BlockRegistry.Resource_.BRANCH,
		"site": Building.Kind.TOOLMAKER,
		"skill": ColonyJob.Skill.MANUFACTURING,
		"xp": 3.0,
	},
	# The furnaces — construct-in-place like the campfire. The pit
	# smelter is dry-laid cobbles; the bloomery is shaped clay.
	&"pit_smelter": {
		"label": "Build pit smelter",
		"inputs": {DropItem.Form.COBBLE: 8},
		"outputs": [],
		"builds": Building.Kind.SMELTER,
	},
	&"bloomery": {
		"label": "Build bloomery",
		"inputs": {DropItem.Form.LOOSE: 0},
		"input_cm3": {DropItem.Form.LOOSE: 500_000},
		"input_material": {DropItem.Form.LOOSE: BlockRegistry.Resource_.CLAY},
		"outputs": [],
		"builds": Building.Kind.BLOOMERY,
	},
	# The kiln — shaped clay like the bloomery, fired to fire clay. It
	# turns green clay into firebrick and ceramics: the refractory's
	# lining and the gold crucible both come off it.
	&"kiln": {
		"label": "Build kiln",
		"inputs": {DropItem.Form.LOOSE: 0, DropItem.Form.COBBLE: 4},
		"input_cm3": {DropItem.Form.LOOSE: 300_000},
		"input_material": {DropItem.Form.LOOSE: BlockRegistry.Resource_.CLAY},
		"outputs": [],
		"builds": Building.Kind.KILN,
	},
	# The stone crusher — a boulder's worth of frame with a plank beam
	# doing the pounding. Every crush bill lives here now.
	&"stone_crusher": {
		"label": "Build stone crusher",
		"inputs": {DropItem.Form.BOULDER: 2, DropItem.Form.PLANK: 2},
		"outputs": [],
		"builds": Building.Kind.STONE_CRUSHER,
	},
	# The firebrick refractory — an alloy furnace that only stands once
	# the kiln has turned out lining brick. Bronze and steel pour here:
	# hot enough for the melt, cheap enough for the early metals age.
	&"refractory": {
		"label": "Build firebrick refractory",
		"inputs": {},
		"input_loose": {BlockRegistry.Resource_.FIREBRICK: 250_000},
		"outputs": [],
		"builds": Building.Kind.REFRACTORY,
	},
	# The stove — a steel firebox on a stone base, the real cooking tier
	# past the campfire ring. The sheet-metal work is the gate: nobody
	# builds a stove before the bloomery line stands.
	&"stove": {
		"label": "Build stove",
		"inputs": {DropItem.Form.SHEET: 2, DropItem.Form.COBBLE: 4},
		"input_material": {
			DropItem.Form.SHEET: BlockRegistry.Resource_.STEEL,
		},
		"outputs": [],
		"builds": Building.Kind.STOVE,
	},
	# Smelting — `input_loose` lists per-material loose inputs the forms
	# alone can't express (ore AND charcoal are both LOOSE); `output_loose`
	# pours the metal as gravel. `requires` is the knowledge gate: only a
	# worker with basic knowledge in the named skill may claim the job.
	# All ratios are per-recipe — later ores take their own numbers.
	# Batch: equal cm³ of ore gravel and charcoal in, half the ore's
	# volume of raw metal out.
	# The ore gravel is half metal, half gangue: the metal pours, the
	# gangue tails out as slag — the ore's `host` rock, useless dross
	# that still has to be hauled somewhere.
	&"smelt_copper": {
		"label": "Smelt copper",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.MALACHITE: SMELT_BATCH_CM3,
			BlockRegistry.Resource_.CHARCOAL: SMELT_BATCH_CM3,
		},
		"output_loose": {
			BlockRegistry.Resource_.COPPER: SMELT_BATCH_CM3 / 2,
		},
		"output_tailings": {
			BlockRegistry.Resource_.STONE: SMELT_BATCH_CM3 / 2,
		},
		"outputs": [],
		"site": Building.Kind.SMELTER,
		"requires": ColonyJob.Skill.PIT_SMELTING,
		"skill": ColonyJob.Skill.PIT_SMELTING,
	},
	&"smelt_tin": {
		"label": "Smelt tin",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.CASSITERITE: SMELT_BATCH_CM3,
			BlockRegistry.Resource_.CHARCOAL: SMELT_BATCH_CM3,
		},
		"output_loose": {
			BlockRegistry.Resource_.TIN: SMELT_BATCH_CM3 / 2,
		},
		"output_tailings": {
			BlockRegistry.Resource_.STONE: SMELT_BATCH_CM3 / 2,
		},
		"outputs": [],
		"site": Building.Kind.SMELTER,
		"requires": ColonyJob.Skill.PIT_SMELTING,
		"skill": ColonyJob.Skill.PIT_SMELTING,
	},
	&"smelt_iron": {
		"label": "Smelt iron",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.HEMATITE: SMELT_BATCH_CM3,
			BlockRegistry.Resource_.CHARCOAL: SMELT_BATCH_CM3,
		},
		"output_loose": {
			BlockRegistry.Resource_.IRON: SMELT_BATCH_CM3 / 2,
		},
		"output_tailings": {
			BlockRegistry.Resource_.STONE: SMELT_BATCH_CM3 / 2,
		},
		"outputs": [],
		"site": Building.Kind.BLOOMERY,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
		"skill": ColonyJob.Skill.BLOOMERY_SMELTING,
	},
	# Native gold — melts low, but a molten metal needs a vessel: the
	# bill wants a fired-clay crucible in the stores (`needs_spec`),
	# presence rather than escrow. The pit smelter holds the heat; the
	# crucible holds the gold.
	&"smelt_gold": {
		"label": "Smelt gold",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.NATIVE_GOLD: SMELT_BATCH_CM3,
			BlockRegistry.Resource_.CHARCOAL: SMELT_BATCH_CM3,
		},
		"output_loose": {
			BlockRegistry.Resource_.GOLD: SMELT_BATCH_CM3 / 2,
		},
		"output_tailings": {
			BlockRegistry.Resource_.STONE: SMELT_BATCH_CM3 / 2,
		},
		"outputs": [],
		"site": Building.Kind.SMELTER,
		"needs_spec": &"crucible",
		"requires": ColonyJob.Skill.PIT_SMELTING,
		"skill": ColonyJob.Skill.PIT_SMELTING,
	},
	# Ceramics — the kiln's two firings. Firebrick is the refractory
	# lining the alloy furnace wants; the crucible is the vessel the
	# gold melt wants. Both take shaped clay and a burn — the kiln's
	# own fuel is priced into the batch like a smelt's charcoal.
	&"fire_brick": {
		"label": "Fire bricks",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.CLAY: 60_000,
			BlockRegistry.Resource_.CHARCOAL: 20_000,
		},
		"output_loose": {BlockRegistry.Resource_.FIREBRICK: 50_000},
		"outputs": [],
		"site": Building.Kind.KILN,
		"skill": ColonyJob.Skill.CHARCOAL_BURNING,
		"xp": 2.0,
	},
	&"fire_crucible": {
		"label": "Fire a crucible",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.CLAY: 30_000,
			BlockRegistry.Resource_.CHARCOAL: 10_000,
		},
		"outputs": [{DropItem.Form.TOOL: 1}],
		"output_spec": &"crucible",
		"output_material": BlockRegistry.Resource_.CERAMIC,
		"site": Building.Kind.KILN,
		"skill": ColonyJob.Skill.CHARCOAL_BURNING,
		"xp": 3.0,
	},
	# The alloys — both pour at the firebrick refractory. Bronze is the
	# low technology: nine parts copper, one tin, charcoal to run the
	# melt. Steel is iron re-carburized — the bloomery man's second
	# trick, worth a real cooking tier and better steel to come.
	&"alloy_bronze": {
		"label": "Alloy bronze",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.COPPER: 90_000,
			BlockRegistry.Resource_.TIN: 10_000,
			BlockRegistry.Resource_.CHARCOAL: SMELT_BATCH_CM3,
		},
		"output_loose": {
			BlockRegistry.Resource_.BRONZE: SMELT_BATCH_CM3,
		},
		"outputs": [],
		"site": Building.Kind.REFRACTORY,
		"requires": ColonyJob.Skill.PIT_SMELTING,
		"skill": ColonyJob.Skill.PIT_SMELTING,
	},
	&"alloy_steel": {
		"label": "Alloy steel",
		"inputs": {},
		"input_loose": {
			BlockRegistry.Resource_.IRON: 95_000,
			BlockRegistry.Resource_.CHARCOAL: SMELT_BATCH_CM3,
		},
		"output_loose": {
			BlockRegistry.Resource_.STEEL: 95_000,
		},
		"outputs": [],
		"site": Building.Kind.REFRACTORY,
		"requires": ColonyJob.Skill.BLOOMERY_SMELTING,
		"skill": ColonyJob.Skill.BLOOMERY_SMELTING,
	},
	# Crushing — one bill per crushable material per form (the list lives
	# in BlockRegistry.CRUSHABLE_MATERIALS) at the stone crusher, the
	# machine the line folds into. A boulder breaks into nine cobbles
	# plus a cobble's worth of gravel; a cobble goes straight to gravel.
	# The country-rock bills pin to every rock kind and pour the
	# input's own gravel (MAT_INHERIT); only ore GRAVEL smelts — this
	# is the road.
	&"crush_stone_boulder": {
		"label": "Crush rock boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.ROCK_MATERIALS},
		"outputs": [{DropItem.Form.COBBLE: 9}],
		"output_loose": {MAT_INHERIT: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_stone_cobble": {
		"label": "Crush rock cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.ROCK_MATERIALS},
		"outputs": [],
		"output_loose": {MAT_INHERIT: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_coal_boulder": {
		"label": "Crush coal boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.Resource_.COAL},
		"outputs": [{DropItem.Form.COBBLE: 9}],
		"output_loose": {BlockRegistry.Resource_.COAL: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_coal_cobble": {
		"label": "Crush coal cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.Resource_.COAL},
		"outputs": [],
		"output_loose": {BlockRegistry.Resource_.COAL: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_hematite_boulder": {
		"label": "Crush hematite boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.Resource_.HEMATITE},
		"outputs": [{DropItem.Form.COBBLE: 9}],
		"output_loose": {BlockRegistry.Resource_.HEMATITE: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_hematite_cobble": {
		"label": "Crush hematite cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.Resource_.HEMATITE},
		"outputs": [],
		"output_loose": {BlockRegistry.Resource_.HEMATITE: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_malachite_boulder": {
		"label": "Crush malachite boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.Resource_.MALACHITE},
		"outputs": [{DropItem.Form.COBBLE: 9}],
		"output_loose": {BlockRegistry.Resource_.MALACHITE: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_malachite_cobble": {
		"label": "Crush malachite cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.Resource_.MALACHITE},
		"outputs": [],
		"output_loose": {BlockRegistry.Resource_.MALACHITE: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_cassiterite_boulder": {
		"label": "Crush cassiterite boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.Resource_.CASSITERITE},
		"outputs": [{DropItem.Form.COBBLE: 9}],
		"output_loose": {BlockRegistry.Resource_.CASSITERITE: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_cassiterite_cobble": {
		"label": "Crush cassiterite cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.Resource_.CASSITERITE},
		"outputs": [],
		"output_loose": {BlockRegistry.Resource_.CASSITERITE: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_native_gold_boulder": {
		"label": "Crush native gold boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.Resource_.NATIVE_GOLD},
		"outputs": [{DropItem.Form.COBBLE: 9}],
		"output_loose": {BlockRegistry.Resource_.NATIVE_GOLD: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	&"crush_native_gold_cobble": {
		"label": "Crush native gold cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.Resource_.NATIVE_GOLD},
		"outputs": [],
		"output_loose": {BlockRegistry.Resource_.NATIVE_GOLD: DropItem.COBBLE_CM3},
		"site": Building.Kind.STONE_CRUSHER,
	},
	# Stonecutting — dressed blocks at the stonecutter's bench, the
	# mason's stock. Cutting is exact: every cm³ lands as a block or
	# pours off as gravel, so nothing is wasted but the bench time.
	# Every country-rock kind dresses — marble and slate blocks carry
	# their stone's class and its beauty — while ore goes through the
	# crush bills. The work asks Crafting's measure-and-strike eye but
	# it's routine enough that the hands don't learn from it (`xp` 0).
	&"cut_blocks_boulder": {
		"label": "Cut blocks from boulder",
		"inputs": {DropItem.Form.BOULDER: 1},
		"input_material": {DropItem.Form.BOULDER: BlockRegistry.ROCK_MATERIALS},
		"outputs": [{DropItem.Form.BLOCK: 12}],
		"output_loose": {MAT_INHERIT: 40_000},
		"site": Building.Kind.STONECUTTER,
		"xp": 0.0,
	},
	&"cut_blocks_cobble": {
		"label": "Cut block from cobble",
		"inputs": {DropItem.Form.COBBLE: 1},
		"input_material": {DropItem.Form.COBBLE: BlockRegistry.ROCK_MATERIALS},
		"outputs": [{DropItem.Form.BLOCK: 1}],
		"output_loose": {MAT_INHERIT: 5_000},
		"site": Building.Kind.STONECUTTER,
		"xp": 0.0,
	},
}
## Recipe order for the worksite panel's buttons — a recipe shows only
## on the building kind its `site` names (absent = the crafting spot).
const RECIPE_ORDER: Array[StringName] = [
	&"planks", &"extract_seed", &"prepare_meal", &"make_pemmican",
	&"smelt_copper", &"smelt_tin", &"smelt_iron",
	&"sheet_metal_copper", &"sheet_metal_tin", &"sheet_metal_iron",
	&"sheet_metal_gold", &"sheet_metal_bronze", &"sheet_metal_steel",
	&"wire_copper", &"wire_tin", &"wire_iron", &"wire_gold",
	&"machine_components",
	&"cotton_cloth",
	&"garb_tribal", &"garb_tribal_leather",
	&"tool_belt", &"tool_belt_cloth",
	&"backpack", &"backpack_leather",
	&"sew_sack", &"sew_sack_leather", &"sew_seed_pouch",
	&"nail_box", &"nail_box_metal",
	&"stone_axe", &"stone_shovel", &"stone_pick",
	&"iron_axe", &"iron_shovel", &"iron_pick",
	&"spear", &"bow",
	&"crush_stone_boulder", &"crush_stone_cobble",
	&"crush_coal_boulder", &"crush_coal_cobble",
	&"crush_hematite_boulder", &"crush_hematite_cobble",
	&"crush_malachite_boulder", &"crush_malachite_cobble",
	&"crush_cassiterite_boulder", &"crush_cassiterite_cobble",
	&"crush_native_gold_boulder", &"crush_native_gold_cobble",
	&"cut_blocks_boulder", &"cut_blocks_cobble",
	&"smelt_gold", &"fire_brick", &"fire_crucible",
	&"alloy_bronze", &"alloy_steel",
	&"cook_stew",
]

## The smelt batch: equal cm³ of ore gravel and charcoal in, raw metal
## out at half the ore's volume. Named once for every smelt recipe.
const SMELT_BATCH_CM3 := 100_000
## The `output_loose`/`output_tailings` key meaning "pour the input's
## own material" — a crush or cut bill pinned to several rock kinds
## can't name one gravel class, so it names this and completion
## substitutes the committed input material (job.material).
const MAT_INHERIT := -1
## One unit of raw metal — what a single smelt pours. The toolmaker's
## recipes and repair bill both price in these: two per forged tool,
## one per 40% of damage a repair puts back.
const TOOL_METAL_CM3 := SMELT_BATCH_CM3 / 2
## The most a repair can restore a metal tool to — a re-forged edge is
## never factory-new; the head thins with every reworking.
const TOOL_REPAIR_CAP := 0.8
## Wear one unit of raw metal buys back at the toolmaker's bench.
const TOOL_REPAIR_STEP := 0.4
## Block hardness at which "mining" stops being digging and wants a
## real pick — dirt, grass and clay yield to a shovel or a pick;
## stone and ore take the pick alone.
const HARD_MINE_HARDNESS := 2.0
## Charcoal mound: seconds of supervised smoulder before the stack
## gives up its charcoal — long enough that lighting one is a decision.
const CHARCOAL_BURN_SECONDS := 400.0
## What the mound yields — 0.3 m³ of charcoal, worth 1.5 logs of burn.
const CHARCOAL_OUT_CM3 := 300_000
## How much heap a point of damage chews up — a dense pile is flimsy
## cover: ~400 hit points' worth of soaking per full cell of goods.
const SPLASH_ERODE_CM3_PER_HP := 2_000
## One teach job's session cap — a lesson runs until the student draws
## level with the teacher in the chosen skill, or this long passes.
const TEACH_SECONDS := 30.0
## Combat collateral: the cell between the fighters soaks this much of
## every blow, and a stray swing lands on a random neighbour this
## often (per hit tick) for the stray share.
const SPLASH_SHARE := 0.5
const SPLASH_STRAY_CHANCE := 0.3
const SPLASH_STRAY_SHARE := 0.75
## Hit points a repair job puts back per work-second — a stone wall
## mends in about eight seconds of hammering.
const REPAIR_HP_PER_S := 15.0

## Pile capacity in a voxel that shares its cell with a ladder — the
## ladder claims a quarter of the space. Mirrors DelveSim's
## LADDER_PILE_CM3.
const LADDER_PILE_CM3 := DropItem.BLOCK_CM3 * 3 / 4
## Walk speed crossing a mound or barricade — a scramble, not a stride.
const COVER_CRAWL := 0.55
## Walk speed hopping a fence rail — a little easier than a barricade:
## it's a climb meant to be taken, by settlers at least. Animals can't
## climb it at all — `traversal_mult` answers 0 for them and the
## pathfinder refuses the cell outright.
const FENCE_CRAWL := 0.6
## Walk speed wading a full item pile — heaped to the brim it's as slow
## as climbing a solid block, never faster.
const PILE_CRAWL := 0.45
## A campfire's fuel store in burn-seconds: two and a half logs fills
## it, and a refuel job tops it off rather than trickle-feeding.
const CAMPFIRE_FUEL_CAP := 1500.0
## The toolmaker forge's fuel store — smaller than the campfire's:
## the bench only burns while a bill runs, so a smaller reserve
## still covers a dozen forgings.
const TOOLMAKER_FUEL_CAP := 1200.0
## Work-light radius of a burning campfire, in metres — enough to work
## by within ~5 m. Today it only lights the scene; work penalties for
## poor light wait for the illumination model.
const CAMPFIRE_LIGHT_RADIUS := 5.0

## Game seconds between fire ticks — burning cells lose fuel, roll
## spread, and burn out on this cadence.
const FIRE_TICK_SEC := 0.5
## Per-second spread roll per flammability point of the neighbour —
## dry grass next to a flame catches inside a few seconds.
const FIRE_SPREAD_RATE := 0.30
## Fuel-seconds a beating unit strips per second — a grass fire dies
## under about a second and a half of stamping.
const FIRE_BEAT_RATE := 4.0
## Damage per second a burning building takes — a wooden door (≈90 hp)
## is gutted in about fifteen seconds of flame.
const FIRE_DPS := 6.0
## Hit points per second a plant takes while its cell burns — a bush
## dies inside the few seconds its own fuel lasts, so a fire beaten out
## early still leaves scorched casualties behind.
const FIRE_PLANT_DPS := 40.0
## Same for a tree — its cells each burn ~14 s, and every burning part
## bleeds the shared pool, so a caught canopy kills the tree even where
## the flames never reach.
const FIRE_TREE_DPS := 20.0
## Fuel budgets per burning cell layer, in seconds.
const FIRE_FUEL_GRASS := 6.0
const FIRE_FUEL_BUSH := 10.0
const FIRE_FUEL_TREE := 14.0
const FIRE_FUEL_BLOCK := 18.0
const FIRE_FUEL_BUILDING := 25.0
const FIRE_FUEL_PILE := 8.0
## Falling precipitation drains fuel this much faster than open flame
## alone — rain puts fires out, and fast.
const FIRE_RAIN_DOUSE := 3.0
## Walk speed through a burning cell — close to a wall: units route
## around flames rather than through them.
const FIRE_TRAVERSAL := 0.12
## How far out from a colony anchor lightning roams looking for
## something tall to hit.
const LIGHTNING_RADIUS := 28

## The share of a wrecked building's components destroyed outright —
## a clean teardown pays back every input; a battered-down one pays
## salvage. Survivors lose a third of loose volume and take wear.
const WRECK_LOSS_CHANCE := 0.35

## How often the mess scan posts cleaning bills for home cells.
const MESS_SCAN_SEC := 4.0
## Total mess at which a home cell earns a clean bill — a light dusting
## rides until something real lands.
const MESS_JOB_THRESHOLD := 0.5
## Mess units a scrubbing unit clears per second — a bloodied cell takes
## a few seconds on hands and knees.
const SCRUB_RATE := 0.4
## Odds a footstep on a home cell tracks dirt in, and the amount it
## leaves — busy corridors soil up over a day or two of traffic.
const TRACKED_DIRT_CHANCE := 0.02
const TRACKED_DIRT := 0.3
## Mess a bleeding wound leaves per point of raw damage — a brawl marks
## the floor where it happened.
const BLOOD_PER_DAMAGE := 0.08
## Ash a cell that burned out leaves behind.
const BURN_ASH := 1.0

## One coil of wire runs one conduit length — a copper wire item per
## wall face the line hides in.
const CONDUIT_WIRE_CM3 := DropItem.WIRE_CM3
## Walk speed through a cell a freestanding pylon and its line share —
## the cable and pole are in the way.
const PYLON_CRAWL := 0.7
## Item-54 — water traversal: a full wade costs ~3× the stride of dry
## land; a submerged cell is swim-only territory, priced like the
## fatigue a crossing costs.
const WADE_TRAVEL := 0.35
const SWIM_TRAVEL := 0.22
## A generator's fuel store in burn-seconds — the campfire cap: it
## drinks the same fuels on the same scale.
const GENERATOR_FUEL_CAP := CAMPFIRE_FUEL_CAP
## Watts a fuelled generator carries: enough for a heater and a cooler
## together, tight enough that a settlement's power budget is real.
const GENERATOR_WATTS := 400.0
## What each device draws while running.
const HEATER_WATTS := 150.0
const COOLER_WATTS := 200.0
## A running heater's per-second fire roll — rare on a metal housing,
## a genuine hazard in a wooden one.
const HEATER_FIRE_CHANCE := 0.001
const HEATER_FIRE_CHANCE_WOOD := 0.005

## Item-53 — a water wheel converts the accumulated flux through its
## cell to watts, capped. The bound that matters is against the pump:
## a wheel fed a pump's own outflow yields less than the pump draws,
## so no pump→wheel→pump loop can perpetuum — 40 W out for 200 W in.
const WHEEL_W_PER_CM3 := 0.0002
const WHEEL_MAX_WATTS := 300.0
## The pump's draw and its per-water-step transfer — 200 L per step
## against a river's ~700 L/step flow, throttled only by the intake
## running dry or the outflow filling.
const PUMP_WATTS := 200.0
const PUMP_CM3_STEP := 200_000

## Item-53 — ground moisture: a fraction of saturation 0..1 on the
## soil column (one value per (x,z), shared top to bottom). Dirt
## without water holds MOIST_AMBIENT — enough for hardy perennials,
## not enough for crops. Rain soaks open-sky columns toward
## MOIST_SOAKED; drying drains back to ambient; snow holds its water
## until melt, matching the sim. Nearby standing water irrigates
## toward MOIST_IRRIGATED, its reach set by the body's size so a pond
## waters a field a puddle can't — DESIGN's abuse note.
const MOIST_AMBIENT := 0.25
const MOIST_SOAKED := 0.85
const MOIST_IRRIGATED := 0.90
## Saturation gain per game-second under rain and storm-wet, and the
## drainage rate in any weather. A steady rain soaks a field in ~40 s;
## drying back to ambient takes a couple of game-days.
const MOIST_RAIN_GAIN := 0.015
const MOIST_STORM_GAIN := 0.05
const MOIST_DRAIN := 0.004
## The farthest a huge body irrigates, in columns. A body's reach is
## 0.75 × √columns: a 100-column pond reaches ~6, a 4-column puddle
## ~1, a lone wet cell nothing but its own.
const MOIST_RADIUS_MAX := 6
const MOIST_BODY_CACHE_S := 60.0
## Sowing refuses cells standing in more than a skim of water — a
## flooded field can't take seeds regardless of moisture.
const SOW_WATER_MAX := 50_000

## Game seconds between room-temperature ticks — heat moves on a slow
## cadence, not every frame.
const TEMP_TICK_SEC := 1.0
## Heat capacity per m³ of room air, in °C⁻¹ device-units — how many
## heater-seconds one degree takes. Rooms are cubic metres, so a
## 27-cell box takes ~27 device-seconds per degree.
const HEAT_PER_CELL := 1.0
## A running heater pours this many degrees-per-second of heat into
## one cubic metre — room volume divides it down.
const HEATER_POWER := 8.0
## A running cooler pumps this many degrees-per-second out of its
## cold side (and pours it, plus a little waste, onto the hot side)
## per cubic metre of cold room.
const COOLER_POWER := 6.0
## Open flame warms the room around it — a lit campfire pours a
## quarter of an electric heater's push, and a wildfire cell burns
## far hotter while it lasts.
const FLAME_HEAT := 2.0
const WILDFIRE_HEAT := 6.0
## Smoke a burning cell pours into its room per second — a wildfire
## cell saturates a small room in tens of seconds; a campfire's
## slower smoke is what makes an unvented hut a health problem over
## a working day.
const SMOKE_PER_FIRE := 0.8
const SMOKE_PER_CAMPFIRE := 0.05
## Fraction of the indoor↔outdoor gap a fully-open boundary equalizes
## per tick-second — an open field breathes.
const TEMP_LEAK_OPEN := 0.25
## The same for a doorway's face — a closed door still breathes
## (RimWorld's airlock lesson), just slowly.
const TEMP_LEAK_DOOR := 0.04
## Per face of solid wall — the two-layer cap halves a thick wall's
## leak, and anything deeper insulates no better (materials never
## matter).
const TEMP_LEAK_WALL := 0.02
const TEMP_LEAK_WALL_DEEP := 0.01
## Per face of unbroken overburden — underground walls pull toward the
## biome mean, and a roof of it does too. It's a *target*, not a leak
## rate: rooms buried in deep ground drift to the mean.
const TEMP_DEEP_PULL := 0.01
## Degrees Celsius under the floor where a unit stands before the cold
## starts biting — the comfort band the needs model reads later.
const TEMP_COLD_FLOOR := 0.0

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var day_cycle_path: NodePath = NodePath("../DayCycle")
@export var initial_units: int = 3
## Radius, in voxels, of the area units spawn in around the colony origin.
@export var spawn_radius: int = 6
## Unit needs — energy drain and rest-seeking. Tests flip it off so units
## stay on task; it is not a difficulty switch.
var needs_enabled := true

var world: VoxelWorld
## The site's planet clock — units pace their rest against its day length.
var day_cycle: DayCycle
var jobs: Array[ColonyJob] = []
## instance_id → ColonyJob: claim results resolve through this, and the
## native job board keys on the same ids.
var _job_index: Dictionary = {}
var units: Array[Unit] = []
## Wild animals roaming the site — spawned with the colony and topped
## up by the wildlife trickle. Each carries its own needs and AI; the
## colony only tracks them for jobs, spawning and saves.
var animals: Array[Animal] = []
## Units currently in [enum Unit.State.SLEEPING] — a set maintained by
## each unit's `state_changed` signal (connected at spawn), never by
## rescanning the roster. `_all_asleep` is an O(1) read of its size.
var _sleeping: Dictionary = {}
## Armed sleep-boost toggle: when every unit at the focused site sleeps,
## the clock runs at the top standard speed. "All" is the focused site's
## roster — once multiple sites are active each focus manages its own
## list, and future domestic animals land in `units` and count the same.
var sleep_boost := false
## The speed the player last picked — what the clock falls back to when
## the boost disengages (or was never armed).
var _selected_speed := 1.0
## The top standard speed the boost engages — the HUD's 6x.
const SLEEP_BOOST_SPEED := 6.0
## Loose resources lying in the world, keyed by the voxel they sit in or are
## falling toward.
var item_piles: Dictionary[Vector3i, ItemPile] = {}
## Piles falling onto a voxel that already has a pile — they merge into it
## when they land. Not keyed in [member item_piles] while in flight.
var _in_flight: Array[ItemPile] = []

## Voxels designated as stockpile cells: haul destinations for items.
## Designated stockpile cells — cell → its [StockpileZone]. Contiguous
## cells share one zone record, so the admission filter is set once for
## the whole zone instead of per tile, like farm cells sharing a crop.
var stockpiles: Dictionary[Vector3i, StockpileZone] = {}
## Allowed areas the player paints — settlers and animals assigned to
## one only work cells belonging to it. A cell lives in at most one
## area: repainting moves it. `_area_cells` is the reverse lookup the
## gates use; `areas` is the ordered list the panels enumerate.
var areas: Array[AllowedArea] = []
var _area_cells: Dictionary[Vector3i, AllowedArea] = {}
## The area the expand-area tool paints — the panel's selected row.
## Null paints nothing: the tool asks for a row first.
var paint_area: AllowedArea = null
## One marker tint per area slot — created lazily so area colours stay
## stable as rows come and go.
var _area_marker_materials: Array[StandardMaterial3D] = []
## The area overlay markers — a separate map from `_designation_markers`
## since an area can cover cells another marker already owns.
var _area_markers: Dictionary[Vector3i, MeshInstance3D] = {}
## Thin floor slab the area overlay wears.
var _area_marker_mesh: BoxMesh
## The home area (PLAN item 44) — the colony's lived-in footprint.
## Firefighting, repair and (future) clean bills only spawn on its
## cells, and the autonomous fetch queries prefer in-home piles over
## anything farther afield. Painted by hand like an allowed area, or
## grown automatically around construction and zone designations while
## [member auto_home] holds.
var home_cells: Dictionary[Vector3i, bool] = {}
## The "automatically expand home area" switch: a built building,
## furniture piece or conduit, and each fresh stockpile or farm cell,
## pulls itself and the 3×3×3 cube around it into the area.
var auto_home := true
## The home cells' bucket index — `nearest_home_cell` walks rings on it
## like the pile and stockpile searches do on theirs.
var _home_buckets: Dictionary = {} # Vector2i -> Array[Vector3i]
## The home overlay markers — another separate map, since a home cell
## can share its voxel with an area, stockpile or plan marker.
var _home_markers: Dictionary[Vector3i, MeshInstance3D] = {}
var _home_marker_material: StandardMaterial3D
## Whether the home overlay renders — the HUD's "Home area" toggle.
var _home_visible := true
## The shelf's stand-in: a tall narrow frame box.
var _shelf_mesh: BoxMesh
var _shelf_marker_material: StandardMaterial3D
var _compost_bin_marker_material: StandardMaterial3D
var _compost_bin_mesh: BoxMesh
var _fertilize_marker_material: StandardMaterial3D
## Growing zones — farm-field cell → its [FarmField] record. A field is
## a set of cells plus the crop assigned to them; the farm scan turns an
## assigned field into SOW, FORAGE and CHOP jobs.
var farms: Dictionary[Vector3i, FarmField] = {}
## Farm-cell → the pending job the field generated for it (sow, harvest
## or auto-chop). Auto jobs carry no marker — the zone's own marker
## already covers the cell.
var _farm_jobs: Dictionary[Vector3i, ColonyJob] = {}
## Per-cell fertilization added on top of the block type's default —
## sparse by design: only fertilizable cells (dirt) that have actually
## been fertilized hold an entry, in fraction points (0.25 = +25%).
## Compost finishing its rot adds to it; growing plants drain it.
var fertilization: Dictionary = {}
## Painted fertilize marks — air cell → the effective fertility the mark
## pushes the soil below toward. A mark keeps posting FERTILIZE jobs
## until the soil reaches its target; the field-side auto-fertilizer
## doesn't need the map — its rules live on the FarmField.
var fertilize_marks: Dictionary = {}
## Item-53 — soil columns holding rain-soak accrual: (x,z) Vector2i →
## fraction of saturation. The read floors at MOIST_AMBIENT, so values
## below it are just accumulation-in-progress; the drain erases at
## zero, so only rained-on ground costs memory.
var _soil_wet: Dictionary = {}
## Every soil cell a plant has asked moisture about — the rain sweep
## only wets tracked columns, so untended ground costs nothing.
var _moisture_cells: Dictionary = {}
## Water-body sizes cached per wet column: (x,z) Vector2i →
## [columns, expire_msec] — one BFS per nearby body per minute, not
## per plant query.
var _moist_body_cache: Dictionary = {}
## Cell → the pending FERTILIZE job posted for it, whether the mark or a
## field's auto-fertilizer opened it. Tracked like `_farm_jobs`: one
## fertilize job per cell, no marker of its own.
var _fertilize_jobs: Dictionary[Vector3i, ColonyJob] = {}
## Cell → the fertilize mark's own marker mesh — a separate layer from
## `_designation_markers` so a mark can share a cell with a farm zone
## without either visual eating the other.
var _fertilize_markers: Dictionary = {}
## The bill ingredient-radius outline — a hover-only ring of floor
## markers around a worksite, drawn and erased as a set.
var _radius_markers: Dictionary[Vector3i, MeshInstance3D] = {}
var _radius_marker_material: StandardMaterial3D
## Constructed things, keyed by voxel: built wall blocks and worksites
## (the crafting spot — a designated place that needs no materials).
## Each record keeps what the construction was built from so it can be
## deconstructed into exactly those items and later rendered in its
## material. Voxel blocks alone can't carry that.
var buildings: Dictionary[Vector3i, Building] = {}
## Whether designation markers render — the HUD's zones toggle. The
## designations keep working either way.
var markers_visible := true
## Plan markers — pending build walls and deconstruct marks — render on a
## second switch, Timberborn-style: the HUD's Plans toggle, OR whenever a
## planning tool (a wall action or deconstruct) is in hand.
var plans_visible_manual := true
var _plans_tool_active := false
var _plan_voxels: Dictionary[Vector3i, bool] = {}
## Face-keyed plan markers — Vector4i(cell, face index) so a cell can
## carry pave and strip plans on several faces at once. Always plan-
## visible driven; `_designation_markers` stays voxel-keyed.
var _face_markers: Dictionary = {}

## Nearest-* searches walk rings of [member SPATIAL_BUCKET_SHIFT]-voxel
## columns outward from the query instead of scanning every entry — the
## colony plays in a bounded area, so a local hit exits after a ring or
## two. Members are kept in sync everywhere item_piles/stockpiles change.
const SPATIAL_BUCKET_SHIFT := 4
enum _Match { VETO, RETRY, FRESH }
var _pile_buckets: Dictionary = {}      # Vector2i -> Array[Vector3i]
var _stockpile_buckets: Dictionary = {} # Vector2i -> Array[Vector3i]

var _designation_markers: Dictionary[Vector3i, Node3D] = {}
var _marker_mesh: BoxMesh
var _outline_mesh: ImmediateMesh
## Thin slab the pave and strip plans wear — thin on Z, rotated to face.
var _face_marker_mesh: BoxMesh
var _marker_material: StandardMaterial3D
var _clear_marker_material: StandardMaterial3D
var _build_marker_material: StandardMaterial3D
var _stockpile_marker_material: StandardMaterial3D
var _craft_spot_marker_material: StandardMaterial3D
var _craft_job_marker_material: StandardMaterial3D
var _deconstruct_marker_material: StandardMaterial3D
var _bed_marker_material: StandardMaterial3D
var _forage_marker_material: StandardMaterial3D
var _farm_marker_material: StandardMaterial3D
var _ladder_marker_material: StandardMaterial3D
## Low slab each bed cell renders as while real furniture meshes don't
## exist.
var _bed_mesh: BoxMesh
## The ladder's stand-in: a pole filling the cell's height at its center
## — attached-versus-freestanding rendering is deferred to real meshes.
var _ladder_mesh: BoxMesh
## The door's stand-in: a panel filling most of the doorway, hinged on
## one side — its open and shut states are implied by the unit pausing
## at the threshold rather than a swinging mesh.
var _door_marker_material: StandardMaterial3D
var _door_mesh: BoxMesh
## The campfire's stand-in: a low torus for the cobble ring plus an
## OmniLight child while it burns — created lazily in
## [method _sync_campfire_light].
var _campfire_marker_material: StandardMaterial3D
var _campfire_mesh: TorusMesh
## The recreation building's stand-in: a low table-slab for pins, boards
## and instruments alike until real meshes exist.
var _rec_marker_material: StandardMaterial3D
var _rec_mesh: BoxMesh
## The fortifications' stand-ins: the mound a low soil lump, the
## barricade a waist-high face — both rest on the cell floor.
var _mound_marker_material: StandardMaterial3D
var _mound_mesh: BoxMesh
var _barricade_marker_material: StandardMaterial3D
var _barricade_mesh: BoxMesh
var _gate_marker_material: StandardMaterial3D
var _gate_mesh: BoxMesh
## The river machines' stand-ins: an upright ring for the water wheel,
## a squat housing for the pump, nudged toward its intake face.
var _wheel_marker_material: StandardMaterial3D
var _wheel_mesh: TorusMesh
var _pump_marker_material: StandardMaterial3D
var _pump_mesh: BoxMesh
## The production buildings' stand-ins: the charcoal mound's earth dome,
## the pit smelter's cobble basin, the bloomery's clay chimney.
var _charcoal_marker_material: StandardMaterial3D
var _charcoal_mesh: SphereMesh
var _smelter_marker_material: StandardMaterial3D
var _smelter_mesh: BoxMesh
var _bloomery_marker_material: StandardMaterial3D
var _bloomery_mesh: CylinderMesh
## The ceramics/alloy line's stand-ins — the kiln and refractory wear
## the chimney shape in their own tints, the crusher and stove join
## the bench slab family.
var _kiln_marker_material: StandardMaterial3D
var _refractory_marker_material: StandardMaterial3D
var _crusher_marker_material: StandardMaterial3D
var _stove_marker_material: StandardMaterial3D
## The power-era stand-ins: a bench slab for both metalwork tables, a
## squat box for the generator, a small warm box for the heater, a
## pale panel for the cooler, a strung post for the pylon.
var _metalwork_marker_material: StandardMaterial3D
var _bench_mesh: BoxMesh
var _fabricator_marker_material: StandardMaterial3D
var _generator_marker_material: StandardMaterial3D
var _generator_mesh: BoxMesh
var _heater_marker_material: StandardMaterial3D
var _heater_mesh: BoxMesh
var _cooler_marker_material: StandardMaterial3D
var _cooler_mesh: BoxMesh
var _pylon_marker_material: StandardMaterial3D
var _pylon_mesh: BoxMesh
var _tailor_marker_material: StandardMaterial3D
var _toolmaker_marker_material: StandardMaterial3D
var _stonecutter_marker_material: StandardMaterial3D
## The furniture stand-ins: a low slab for tables and decor, a small
## cube for seats, a pole for lamps — shared shapes until real meshes.
var _furniture_marker_material: StandardMaterial3D
var _seat_marker_material: StandardMaterial3D
var _seat_mesh: BoxMesh
var _lamp_marker_material: StandardMaterial3D
## The warehouse zone's marker — crates and bulky goods live there,
## not on the open stockpile's floor.
var _warehouse_marker_material: StandardMaterial3D
## Registered lamps, anchor voxel → building — the light-at query's
## index; entries live and die in register/teardown.
var _lamps: Dictionary = {}

## Generated loose-rock slots whose pile still exists — voxel → its
## [ItemPile]. A slot that gets emptied is tombstoned in
## [member _rock_spent] so a re-streamed block doesn't restock free
## stone. See [method _seed_loose_rocks].
var _rock_slots: Dictionary = {}
var _rock_spent: Dictionary = {}

## Battered-but-standing terrain — voxel → accumulated combat damage.
## A cell reaches `hardness × Building.HP_PER_HARDNESS` and breaks as
## if mined; building cells never land here, their records carry `hp`.
var _block_damage: Dictionary = {}

## The site's sky — seasons, temperature, precipitation and storms
## (PLAN item 32). Owns the state machine; the colony ticks it and
## reads it for light, ignition and fire behaviour.
var weather := Weather.new()

## Live wildfires: burning voxel → `{"fuel": burn seconds left}`.
## A cell is flammable when grass, a bush, a tree part, a wooden block,
## a flammable building or a burnable pile occupies it. Beat-down work
## and rain drain fuel faster than it burns; at zero the contents are
## consumed (a beaten-out cell dies before that and keeps them).
var _fires: Dictionary = {}
## One FIREFIGHT job per burning cell — the claim-side dedupe.
var _firefight_at: Dictionary = {}
## The orange markers burning cells wear — separate from designation
## markers since a fire is never a plan.
var _fire_markers: Dictionary = {}
var _fire_elapsed := 0.0

## The mess layer (item 62): home cell → {kind → amount} for tracked-in
## dirt, spilled blood and burn-out ash. Sources write it; the scan
## posts CLEAN bills for cells past the threshold; scrubbers clear it.
## Off-home cells never accrue — the wilds keep their dirt.
var mess: Dictionary = {}
## One CLEAN job per messy cell — the claim-side dedupe, like
## [member _firefight_at].
var _clean_at: Dictionary = {}
var _mess_elapsed := 0.0

## The world's growing trees — chop designations resolve through it.
var forest: Forest

## The world's forageable plants — forage designations resolve through
## it. See plants.gd.
var plants: Plants

## Ground cover — grassed cells are ordinary dirt blocks carrying a
## decoration layer; construction and foot traffic wear it away.
## See grass.gd.
var grass: Grass

## Surface coverings — paved floors, dressed walls and ceilings as a
## decoration layer over plain terrain (PLAN item 34). See flooring.gd.
var flooring: Flooring

## The room graph — bounded flood-fill components of open cells, lazily
## detected and cached (PLAN items 23/34). See rooms.gd.
var rooms: Rooms
## The display overlays (PLAN item 64) — beauty and roofs heatmaps
## painted over the standing surface near the camera focus.
var overlays: ColonyOverlays

## Beauty-sampling instrumentation — the sight-line pass the spec
## worried about, metered: rays and cell probes per real second.
var beauty_rays_per_sec := 0.0
var beauty_cells_per_sec := 0.0
var _beauty_rays := 0
var _beauty_cells := 0
var _beauty_stat_elapsed := 0.0


func _ready() -> void:
	world = get_node(world_path)
	day_cycle = get_node_or_null(day_cycle_path)
	world.block_mined.connect(_on_block_mined)
	world.block_placed.connect(_on_block_placed)
	world.block_collapsed.connect(_on_block_collapsed)
	world.block_loaded.connect(_enqueue_world_block)
	forest = Forest.new()
	forest.name = "Forest"
	add_child(forest)
	forest.setup(world, self)
	plants = Plants.new()
	plants.name = "Plants"
	add_child(plants)
	plants.setup(world, self)
	grass = Grass.new()
	grass.name = "Grass"
	add_child(grass)
	grass.setup(world, self)
	flooring = Flooring.new()
	flooring.name = "Flooring"
	add_child(flooring)
	flooring.setup(world, self)
	rooms = Rooms.new()
	rooms.setup(world, self)
	# Any terrain edit — mine, place, collapse, teardown removal — may
	# have changed which open cells connect. Invalidation is cheap; the
	# lazily-flooded answers rebuild on the next query.
	world.block_edited.connect(_on_room_topology_changed)
	weather.setup(self)
	_marker_mesh = BoxMesh.new()
	_marker_mesh.size = Vector3.ONE * 1.02
	_outline_mesh = _make_outline_mesh()
	# A pave/strip plan: a thin slab on the face it dresses.
	_face_marker_mesh = BoxMesh.new()
	_face_marker_mesh.size = Vector3(0.98, 0.98, 0.06)
	_marker_material = _make_marker_material(Color(1.0, 0.85, 0.2, 0.35))
	_clear_marker_material = _make_marker_material(Color(0.35, 0.85, 1.0, 0.35))
	_build_marker_material = _make_marker_material(Color(0.65, 0.4, 0.15, 0.35))
	_stockpile_marker_material = _make_marker_material(Color(0.5, 1.0, 0.55, 0.45))
	_craft_spot_marker_material = _make_marker_material(Color(0.75, 0.5, 0.95, 0.45))
	_craft_job_marker_material = _make_marker_material(Color(0.75, 0.5, 0.95, 0.5))
	_deconstruct_marker_material = _make_marker_material(Color(1.0, 0.35, 0.2, 0.45))
	_forage_marker_material = _make_marker_material(Color(0.95, 0.3, 0.45, 0.4))
	_farm_marker_material = _make_marker_material(Color(0.85, 0.7, 0.25, 0.45))
	# A built bed: a low box per footprint cell — the building's stand-in
	# model until furniture gets real meshes.
	_bed_marker_material = _make_marker_material(Color(0.6, 0.45, 0.25, 0.6))
	_bed_mesh = BoxMesh.new()
	_bed_mesh.size = Vector3(0.94, 0.4, 0.94)
	# A built ladder: a pole running the cell's height — the rendering
	# doesn't yet distinguish wall-hugging from freestanding.
	_ladder_marker_material = _make_marker_material(Color(0.5, 0.32, 0.14, 0.9))
	_ladder_mesh = BoxMesh.new()
	_ladder_mesh.size = Vector3(0.14, 1.02, 0.14)
	# A built campfire: a low stone ring — the stand-in until real meshes
	# exist. Its OmniLight child is what "produces light" means today.
	_campfire_marker_material = _make_marker_material(Color(0.42, 0.4, 0.42, 0.95))
	_campfire_mesh = TorusMesh.new()
	_campfire_mesh.inner_radius = 0.18
	_campfire_mesh.outer_radius = 0.45
	_mound_marker_material = _make_marker_material(
		Color(0.45, 0.32, 0.20, 0.9)
	)
	_mound_mesh = BoxMesh.new()
	_mound_mesh.size = Vector3(0.86, 0.5, 0.86)
	_barricade_marker_material = _make_marker_material(
		Color(0.62, 0.45, 0.25, 0.9)
	)
	_barricade_mesh = BoxMesh.new()
	_barricade_mesh.size = Vector3(0.92, 0.6, 0.3)
	# A built floodgate: the sluice panel — taller than a barricade and
	# wetter-coloured; the stand-in until real meshes exist.
	_gate_marker_material = _make_marker_material(
		Color(0.35, 0.52, 0.55, 0.9)
	)
	_gate_mesh = BoxMesh.new()
	_gate_mesh.size = Vector3(0.92, 1.0, 0.3)
	# The water machines — the wheel an upright wooden ring half-sunk
	# in the flow, the pump a squat iron-ish housing.
	_wheel_marker_material = _make_marker_material(
		Color(0.55, 0.42, 0.22, 0.9)
	)
	_wheel_mesh = TorusMesh.new()
	_wheel_mesh.inner_radius = 0.28
	_wheel_mesh.outer_radius = 0.45
	_pump_marker_material = _make_marker_material(
		Color(0.4, 0.42, 0.45, 0.9)
	)
	_pump_mesh = BoxMesh.new()
	_pump_mesh.size = Vector3(0.5, 0.7, 0.5)
	# A built door: a near-full panel hung at the doorway's edge — the
	# hinge side is arbitrary until real meshes read the wall faces.
	_door_marker_material = _make_marker_material(Color(0.55, 0.38, 0.18, 0.95))
	_door_mesh = BoxMesh.new()
	_door_mesh.size = Vector3(0.88, 1.9, 0.14)
	# A built recreation furnishing: a low table-height slab — pins,
	# boards and instruments share the stand-in until real meshes exist.
	_rec_marker_material = _make_marker_material(Color(0.72, 0.5, 0.72, 0.9))
	_rec_mesh = BoxMesh.new()
	_rec_mesh.size = Vector3(0.7, 0.5, 0.7)
	# The furnaces and the mound — stand-in shapes until real meshes:
	# a sealed earth dome for the burn, a low cobble basin for the pit
	# smelter, a taller chimney of clay for the bloomery.
	_charcoal_marker_material = _make_marker_material(
		Color(0.35, 0.3, 0.26, 0.9)
	)
	_charcoal_mesh = SphereMesh.new()
	_charcoal_mesh.radius = 0.45
	_charcoal_mesh.height = 0.55
	_smelter_marker_material = _make_marker_material(
		Color(0.50, 0.48, 0.46, 0.9)
	)
	_smelter_mesh = BoxMesh.new()
	_smelter_mesh.size = Vector3(0.8, 0.45, 0.8)
	_bloomery_marker_material = _make_marker_material(
		Color(0.58, 0.46, 0.34, 0.9)
	)
	_bloomery_mesh = CylinderMesh.new()
	_bloomery_mesh.top_radius = 0.28
	_bloomery_mesh.bottom_radius = 0.4
	_bloomery_mesh.height = 0.9
	# The ceramics/alloy line — the kiln is the bloomery's shorter,
	# earthier sibling; the refractory runs darker brick; the crusher
	# and stove sit in the bench family, iron-toned and steel-toned.
	_kiln_marker_material = _make_marker_material(
		Color(0.60, 0.44, 0.32, 0.9)
	)
	_refractory_marker_material = _make_marker_material(
		Color(0.52, 0.30, 0.22, 0.9)
	)
	_crusher_marker_material = _make_marker_material(
		Color(0.42, 0.42, 0.44, 0.9)
	)
	_stove_marker_material = _make_marker_material(
		Color(0.38, 0.40, 0.46, 0.9)
	)
	# The power-era machines — stand-ins like everything else: a wide
	# bench slab for the two metalwork tables, a squat dark box for the
	# generator, a small warm box for the heater, a thin pale panel for
	# the cooler, a strung post for the pylon.
	# Furniture stand-ins — a low table slab, a seat cube, a lamp pole.
	_furniture_marker_material = _make_marker_material(
		Color(0.55, 0.42, 0.24, 0.9)
	)
	_seat_marker_material = _make_marker_material(
		Color(0.6, 0.5, 0.3, 0.9)
	)
	_seat_mesh = BoxMesh.new()
	_seat_mesh.size = Vector3(0.5, 0.5, 0.5)
	_lamp_marker_material = _make_marker_material(
		Color(0.7, 0.6, 0.2, 0.9)
	)
	_warehouse_marker_material = _make_marker_material(
		Color(0.75, 0.55, 0.25, 0.45)
	)
	_metalwork_marker_material = _make_marker_material(
		Color(0.45, 0.48, 0.55, 0.9)
	)
	_bench_mesh = BoxMesh.new()
	_bench_mesh.size = Vector3(0.9, 0.55, 0.6)
	_fabricator_marker_material = _make_marker_material(
		Color(0.40, 0.55, 0.62, 0.9)
	)
	_generator_marker_material = _make_marker_material(
		Color(0.30, 0.28, 0.26, 0.95)
	)
	_generator_mesh = BoxMesh.new()
	_generator_mesh.size = Vector3(0.85, 0.75, 0.85)
	_heater_marker_material = _make_marker_material(
		Color(0.72, 0.42, 0.20, 0.9)
	)
	_heater_mesh = BoxMesh.new()
	_heater_mesh.size = Vector3(0.6, 0.5, 0.6)
	_cooler_marker_material = _make_marker_material(
		Color(0.55, 0.75, 0.85, 0.9)
	)
	_cooler_mesh = BoxMesh.new()
	_cooler_mesh.size = Vector3(0.7, 0.85, 0.7)
	_pylon_marker_material = _make_marker_material(
		Color(0.42, 0.36, 0.30, 0.9)
	)
	_pylon_mesh = BoxMesh.new()
	_pylon_mesh.size = Vector3(0.16, 1.02, 0.16)
	# The tailor's bench shares the bench slab — a cloth-toned tint
	# tells it from anvil and assembly table.
	_tailor_marker_material = _make_marker_material(
		Color(0.62, 0.52, 0.40, 0.9)
	)
	# The toolmaker's bench shares the slab too — a soot-and-ember
	# tint for the little forge.
	_toolmaker_marker_material = _make_marker_material(
		Color(0.55, 0.32, 0.24, 0.9)
	)
	# The stonecutter's bench shares the slab — a dust-grey tint for
	# the saw table.
	_stonecutter_marker_material = _make_marker_material(
		Color(0.52, 0.52, 0.56, 0.9)
	)
	# A built shelf: a taller open-frame stand-in — two uprights and a
	# top read as shelving until real furniture meshes exist.
	_shelf_marker_material = _make_marker_material(
		Color(0.55, 0.42, 0.28, 0.9)
	)
	_shelf_mesh = BoxMesh.new()
	_shelf_mesh.size = Vector3(0.85, 1.7, 0.5)
	# A built compost bin: a low open slat box on the cell floor — the
	# pile inside shows above its rim as it fills and rots down.
	_compost_bin_marker_material = _make_marker_material(
		Color(0.45, 0.36, 0.22, 0.9)
	)
	_compost_bin_mesh = BoxMesh.new()
	_compost_bin_mesh.size = Vector3(0.9, 0.6, 0.9)
	# A fertilize mark's overlay — dark soil-brown, readable under a farm
	# outline the same way the area film reads under everything.
	_fertilize_marker_material = _make_marker_material(
		Color(0.42, 0.30, 0.14, 0.55)
	)
	# The allowed-area overlay: a floor-hugging film over the cell.
	_area_marker_mesh = BoxMesh.new()
	_area_marker_mesh.size = Vector3(0.98, 0.04, 0.98)
	# The home-area film — RimWorld's pale blue-green, a shade lighter
	# than the area hues so the two overlays read apart on one cell.
	_home_marker_material = _make_marker_material(
		Color(0.55, 0.85, 0.9, 0.3)
	)
	# The fetch-radius outline — a pale gold ring flash while a bill's
	# radius control is hovered.
	_radius_marker_material = _make_marker_material(
		Color(1.0, 0.8, 0.35, 0.3)
	)
	overlays = ColonyOverlays.new()
	overlays.name = "Overlays"
	overlays.colony = self
	add_child(overlays)


## The site's sim heartbeat: logical progress that must not depend on
## presentation. Pile-flight timing lives in DelveSim so a falling pile
## lands even when no ItemPile node is processing; node-driven `landed`
## emissions still arrive for rendered piles and are absorbed by the
## idempotency guard in _on_pile_landed.
func _physics_process(delta: float) -> void:
	var pt := Time.get_ticks_usec()
	# Stream-in backlog — a budgeted slice per frame (each handler
	# samples itself into "colony.blocks").
	if not _block_queue.is_empty():
		while (
			not _block_queue.is_empty()
			and Time.get_ticks_usec() - pt < TICK_SLICE_USEC
		):
			_on_world_block_loaded(_block_queue.pop_back())
		pt = Time.get_ticks_usec()
	# Organic decay runs off the game clock — `delta` already carries the
	# pause/speed scaling — and doesn't depend on the native sim.
	_decay_elapsed += delta
	if _decay_elapsed >= DECAY_TICK_SEC and _decay_keys.is_empty():
		var decay_elapsed := _decay_elapsed
		_decay_elapsed = 0.0
		_decay_begin(decay_elapsed)
	if not _decay_keys.is_empty():
		_decay_slice()
		Perf.sample(&"colony.decay", Time.get_ticks_usec() - pt)
		pt = Time.get_ticks_usec()
	if world != null:
		_farm_elapsed += delta
		if _farm_elapsed >= FARM_SCAN_SEC:
			_farm_elapsed = 0.0
			_farm_tick()
			Perf.sample(&"colony.farm", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
		_worksite_elapsed += delta
		if _worksite_elapsed >= WORKSITE_SCAN_SEC:
			var worksite_elapsed := _worksite_elapsed
			_worksite_elapsed = 0.0
			_worksite_tick()
			Perf.sample(&"colony.worksite", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
			_campfire_tick(worksite_elapsed)
			Perf.sample(&"colony.campfire", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
			# Fuel burn precedes the nets — a generator that just ran
			# dry stops carrying this same second — and powered devices
			# precede the climate tick so their heat lands now.
			_power_tick(worksite_elapsed)
			Perf.sample(&"colony.power", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
			_moisture_tick(worksite_elapsed)
			Perf.sample(&"colony.moisture", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
			_climate_tick(worksite_elapsed)
			Perf.sample(&"colony.climate", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
		_wildlife_elapsed += delta
		if _wildlife_elapsed >= WILDLIFE_SCAN_SEC:
			_wildlife_elapsed = 0.0
			_wildlife_tick()
			Perf.sample(&"colony.wildlife", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
		_medical_elapsed += delta
		if _medical_elapsed >= MEDICAL_SCAN_SEC:
			_medical_elapsed = 0.0
			_medical_tick()
			Perf.sample(&"colony.medical", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
		# The sky advances with the frame — the transition math is
		# delta-scaled, so resolution costs nothing.
		weather.tick(delta, day_cycle)
		Perf.sample(&"colony.weather", Time.get_ticks_usec() - pt)
		pt = Time.get_ticks_usec()
		_fire_elapsed += delta
		if _fire_elapsed >= FIRE_TICK_SEC:
			var fire_elapsed := _fire_elapsed
			_fire_elapsed = 0.0
			_fire_tick(fire_elapsed)
			Perf.sample(&"colony.fire", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
		_mess_elapsed += delta
		if _mess_elapsed >= MESS_SCAN_SEC:
			_mess_elapsed = 0.0
			_mess_tick()
			Perf.sample(&"colony.mess", Time.get_ticks_usec() - pt)
			pt = Time.get_ticks_usec()
		# Beauty-sampling cost accounting — the spec's worry made
		# visible: rays and cell probes per real second ride the HUD
		# perf line.
		_beauty_stat_elapsed += delta
		if _beauty_stat_elapsed >= 1.0:
			beauty_rays_per_sec = _beauty_rays / _beauty_stat_elapsed
			beauty_cells_per_sec = _beauty_cells / _beauty_stat_elapsed
			_beauty_rays = 0
			_beauty_cells = 0
			_beauty_stat_elapsed = 0.0
	if world == null or world.sim == null:
		return
	# Rain wets the streamed surface — mm per sweep × 1000 cm³/m². Snow
	# holds its water until melt, so only liquid states feed the sim.
	var rain_cm3 := 0
	if weather.state == Weather.State.RAIN:
		rain_cm3 = 300
	elif weather.state == Weather.State.STORM_WET:
		rain_cm3 = 1500
	world.sim.water_set_rain(rain_cm3)
	for pile_id in world.sim.tick(delta):
		var pile := instance_from_id(pile_id) as ItemPile
		if pile != null:
			_on_pile_landed(pile)
	Perf.sample(&"sim.tick", Time.get_ticks_usec() - pt)


## Game seconds between organic-decay sweeps — each pass rolls the
## stochastic decay on every landed pile.
const DECAY_TICK_SEC := 4.0
## Per-frame wall-clock budget for a cadence sweep's slice — decay,
## block-load bookkeeping and friends each pay at most this much per
## frame so a big colony spreads its pass across frames instead of
## hitching on cadence.
const TICK_SLICE_USEC := 1500
## The decay quantum: bulk stacks rot in chunks of this size — each sweep
## a stack sheds Poisson(V·dt/(life·Q)) quanta — so a large pile streams
## losses smoothly while a tiny one rots in rare whole bites instead of
## dust-shaving. A roll covering nearly the whole stack takes it all.
const DECAY_QUANTUM_CM3 := 8_000
const DECAY_WHOLE_FRAC := 0.9
## Organic decay freezes solid below this temperature — a cooled,
## sealed room keeps food the way the open snow does. Weathering (sun
## and rain, outdoors only) still rolls; only the rot pauses.
const TEMP_FREEZE_C := 0.0
## A fruit item whose last volume rots away over soil rolls this chance
## to sprout a same-species plant — a sapling for trees, a bush for the
## rest — subject to the neighbourhood spacing rule.
const DECAY_SPROUT_CHANCE := 0.05
## Game seconds between farm-field scans — each pass posts new sow,
## harvest and auto-chop jobs and suspends seed-starved sows.
const FARM_SCAN_SEC := 4.0
## Game seconds between worksite dispatches — each pass gives an idle
## queued worksite its next runnable order.
const WORKSITE_SCAN_SEC := 1.0
## Game seconds between wildlife bookkeeping passes — butcher-spot job
## posting and the slow repopulation trickle both ride this.
const WILDLIFE_SCAN_SEC := 2.0
## Game seconds between medical passes — tend and rescue jobs post on
## this cadence for wounded units.
const MEDICAL_SCAN_SEC := 1.0
## Wild animals the site tries to keep alive — a fresh spawn pops in at
## the map's edge each day while below it.
const WILDLIFE_TARGET := 9
## The largest herd a species keeps in the pens — breeding stops at
## the cap; the butcher is the herd's release valve past it.
const HERD_CAP := 12
## Game-days between livestock births — slow enough that a founding
## pair takes a season to become a herd.
const LIVESTOCK_INTERVAL_DAYS := 2.0
## Compost that finishes rotting fertilizes the block below its pile:
## one fertility point (1%) per 1000 cm³ rotted.
const FERTILIZE_PER_CM3 := 0.00001
## Stored fertilization a plant consumes per second of actual growth —
## a wheat-length cycle on lit ground drains ~19 points at this rate.
const FERTILITY_DEPLETION_PER_SEC := 0.0002
## A compost bin's multiplier on organic decay inside its cell —
## enclosed, managed rot runs hot.
const COMPOST_BIN_BOOST := 3.0
## Precipitation multiplies weathering rates — rain and snow take goods
## apart about three times as fast as open sky alone. The rule's `days`
## is the dry-weather lifetime.
const WEATHER_RAIN_MULT := 3.0
## The fill-fraction penalty a pile-source query adds to squared
## distance — a full heap counts about two voxels farther than an
## empty one, so a fetch digs into sparse piles first. Deliberately
## a *tie-breaker*: a heap only a couple of cells out yields to a
## closer dense one, since a long walk to save a heap's cover value
## isn't a trade the colony should make.
const SPARSE_FETCH_BIAS := 4.0
## Effective fertility a painted fertilize mark pushes its soil toward —
## dirt's base of 1.0 doubles: a deliberate "make this good ground"
## order rather than a maintenance top-up.
const FERTILIZE_PAINT_TARGET := 2.0
## How far up a column the daylight scan looks for a shading block —
## player towers taller than this read as open sky to the plants below.
const SKY_SCAN_LIMIT := 96

var _decay_elapsed := 0.0
var _farm_elapsed := 0.0
var _worksite_elapsed := 0.0
var _wildlife_elapsed := 0.0
var _medical_elapsed := 0.0
## Game-msec timestamp of the last edge-spawn — repopulation is a
## once-a-day trickle, not every scan.
var _wildlife_respawn_msec := 0
## Game-msec timestamp of the last herd birth — breeding rolls on a
## multi-day interval, not every wildlife scan.
var _livestock_breed_msec := 0
## Job → unit roster index for tend/rescue patients, resolved after the
## roster loads — same pattern as `_job_animal_links`.
var _job_patient_links: Dictionary = {}
## Job → animal roster index, stashed during a load: animals deserialize
## after jobs, so HUNT links resolve in a second pass.
var _job_animal_links: Dictionary = {}


## One decay pass over every landed pile. Bulk items shed quanta at a
## Poisson rate sized so the mean lifetime is the rule's day count;
## discrete items — logs, fruits, seed packets — convert or vanish whole
## at `dt/life` per sweep. Decayed organics leave compost behind in the
## pile, and a fully-rotted fruit may sprout a plant.
func _decay_tick(dt: float) -> void:
	_decay_begin(dt)
	while not _decay_keys.is_empty():
		_decay_slice()


## Slice state for the decay sweep — the cadence gate starts a sweep
## (a snapshot of the pile keys plus the tick's accumulated dt), then
## `_decay_slice` walks a time-budgeted span per physics frame so a
## colony of thousands of piles doesn't pay the whole pass in one
## frame. Each pile still rolls once per sweep with the sweep's full
## dt, so the decay statistics don't change. Direct `_decay_tick`
## calls drain synchronously — tests rely on that.
var _decay_keys: Array = []
var _decay_i := 0
var _decay_dt := 0.0
var _decay_day_sec := 0.0
var _decay_raining := false
var _decay_sprouts: Array = []
var _decay_emptied: Array = []
var _decay_stale: Array = []


func _decay_begin(dt: float) -> void:
	_decay_dt = dt
	_decay_day_sec = day_length()
	_decay_raining = weather.precipitating()
	_decay_keys = item_piles.keys()
	_decay_i = 0
	_decay_sprouts.clear()
	_decay_emptied.clear()
	_decay_stale.clear()


func _decay_slice() -> void:
	var t0 := Time.get_ticks_usec()
	while _decay_i < _decay_keys.size():
		_decay_pile(_decay_keys[_decay_i])
		_decay_i += 1
		if Time.get_ticks_usec() - t0 >= TICK_SLICE_USEC:
			break
	if _decay_i >= _decay_keys.size():
		_decay_finish()


func _decay_pile(voxel: Vector3i) -> void:
	var dt := _decay_dt
	var day_sec := _decay_day_sec
	var sprouts: Array = _decay_sprouts
	var emptied: Array = _decay_emptied
	var stale: Array = _decay_stale
	var raining := _decay_raining
	var pile: ItemPile = item_piles.get(voxel)
	# A deferred free can leave the key pointing at a dead pile —
	# sweep it rather than trip over `.items` every pass.
	if not is_instance_valid(pile):
		stale.append(voxel)
		return
	# Weathering is the second, outdoor-only axis (item 24): organic
	# decay rolls everywhere, weather only rolls on cells that see the
	# sky — computed once per pile since every item shares the roof.
	var exposed := sees_sky(voxel)
	# Item 57's freezer: below freezing the organic rot pauses — a
	# cooler plus a sealed room preserves food. Weathering still
	# rolls; sun and rain don't care about the cold.
	var frozen := temperature_at(voxel) < TEMP_FREEZE_C
	# A compost bin turns its cell's organic rot over three times as
	# fast — weathering is sun and rain, not microbes, so it stays
	# at the open-air rate, and finished compost keeps its own clock
	# (the bin makes compost; it shouldn't eat it).
	var bin_boost := (
		COMPOST_BIN_BOOST if compost_bin_at(voxel) != null else 1.0
	)
	var compost := 0
	var rotted := false
	var kept: Array[DropItem] = []
	for item in pile.items:
		var rule := (
			{} if frozen else DropItem.decay_rule(item)
		)
		var weather := (
			DropItem.weather_rule(item) if exposed else {}
		)
		if rule.is_empty() and weather.is_empty():
			kept.append(item)
			continue
		var life := (
			float(rule[&"days"]) * day_sec
			if not rule.is_empty()
			else INF
		)
		if (
			bin_boost != 1.0
			and item.material != BlockRegistry.Resource_.COMPOST
		):
			life /= bin_boost
		var weather_life := (
			float(weather[&"days"]) * day_sec
			if not weather.is_empty()
			else INF
		)
		if raining:
			weather_life /= WEATHER_RAIN_MULT
		if item.form != DropItem.Form.LOOSE:
			# Two independent hazards; organic rot claims the item
			# first so weathered-away goods never leave compost.
			var organic := randf() < dt / life
			var weathered := not organic and randf() < dt / weather_life
			if not organic and not weathered:
				kept.append(item)
				continue
			rotted = true
			if organic:
				compost += int(
					item.volume * float(rule.get(&"compost", 0.0))
				)
				if item.material == BlockRegistry.Resource_.COMPOST:
					fertilize(
						voxel + Vector3i.DOWN,
						item.volume * FERTILIZE_PER_CM3
					)
				if rule.get(&"spawn", false):
					sprouts.append([voxel, item.material])
			continue
		var rotted_loss := 0
		var weathered_loss := 0
		if not rule.is_empty():
			rotted_loss = mini(
				_poisson(
					float(item.volume) * dt
						/ (life * DECAY_QUANTUM_CM3)
				) * DECAY_QUANTUM_CM3,
				item.volume
			)
		if not weather.is_empty():
			weathered_loss = mini(
				_poisson(
					float(item.volume - rotted_loss) * dt
						/ (weather_life * DECAY_QUANTUM_CM3)
				) * DECAY_QUANTUM_CM3,
				item.volume - rotted_loss
			)
		var loss := rotted_loss + weathered_loss
		if loss <= 0:
			kept.append(item)
			continue
		rotted = true
		if loss >= item.volume * DECAY_WHOLE_FRAC:
			loss = item.volume
		item.volume -= loss
		# Only the organic share composts — weathered volume is gone.
		compost += int(
			mini(rotted_loss, loss) * float(rule.get(&"compost", 0.0))
		)
		if (
			rotted_loss > 0
			and item.material == BlockRegistry.Resource_.COMPOST
		):
			# Compost that finishes rotting feeds the soil it lay on.
			fertilize(
				voxel + Vector3i.DOWN,
				mini(rotted_loss, loss) * FERTILIZE_PER_CM3
			)
		if item.volume > 0:
			kept.append(item)
		elif rotted_loss > 0 and rule.get(&"spawn", false):
			sprouts.append([voxel, item.material])
	if not rotted:
		return
	pile.items = kept
	if compost > 0:
		pile.items.append(
			DropItem.new(
				BlockRegistry.Resource_.COMPOST,
				DropItem.Form.LOOSE, compost
			)
		)
	pile._rebuild_mesh()
	# Resync packed state — a shrunken pile may have opened its cell
	# or pulled the floor out from under a pile resting on top.
	pile.fill_changed.emit(pile)
	if pile.items.is_empty():
		emptied.append(voxel)


## Sweep end: the deferred ops the slices collected — empties out,
## stale keys swept, sprout rolls landed.
func _decay_finish() -> void:
	for voxel: Vector3i in _decay_emptied:
		remove_pile_if_empty(voxel)
	for voxel: Vector3i in _decay_stale:
		item_piles.erase(voxel)
		_index_remove(_pile_buckets, voxel)
		_sync_sim_packed(voxel)
	for sprout: Array in _decay_sprouts:
		_sprout_from_decay(sprout[0], sprout[1])
	_decay_keys = []


## Knuth's Poisson sampler — counts decay quanta per sweep. The loads it
## sees are small: a full voxel of fast-rotting fruit expects ~0.2.
func _poisson(mu: float) -> int:
	# Knuth's sampler never fires at mu == 0 — without the guard the loop
	# exits with count 0 and returns -1, a negative loss that resurrects
	# a quantum on items the organic roll already claimed.
	if mu <= 0.0:
		return 0
	var limit := exp(-mu)
	var count := 0
	var p := 1.0
	while p > limit:
		count += 1
		p *= randf()
	return count - 1


## A fruit item rotted away at [param voxel]: over soil it may sprout its
## species' plant — a sapling for trees (no plant in the cell or the
## eight around it) or an immature bush (no plant in the cell itself).
func _sprout_from_decay(
	voxel: Vector3i, material: BlockRegistry.Resource_
) -> void:
	if world == null or forest == null or plants == null:
		return
	if not world.is_editable(voxel):
		return
	var below := world.get_block(voxel + Vector3i.DOWN)
	if BlockRegistry.fertilizability(below) <= 0.0:
		return
	if randf() >= DECAY_SPROUT_CHANCE:
		return
	_sprout_plant(voxel, material)


## Try to plant [param material]'s species at [param voxel]: a sapling
## for trees (which demands the cell plus its eight neighbours free of
## trees and bushes), an immature bush otherwise (only its own cell).
## True when something planted — the soil check lives on the caller.
func _sprout_plant(voxel: Vector3i, material: BlockRegistry.Resource_) -> bool:
	var species: StringName = DropItem.FRUIT_SPECIES.get(material, &"")
	if species == &"":
		return false
	if Forest.species_table().has(species):
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if cell_claimed(
					voxel + Vector3i(dx, 0, dz), Occ.TREE | Occ.BUSH
				):
					return false
		return forest.plant_sapling(voxel, species)
	if not Plants.species_table().has(species):
		return false
	if cell_claimed(voxel, Occ.TREE | Occ.BUSH):
		return false
	return plants.plant(voxel, species)


## The length of this site's day in game seconds — the unit rest cycle's
## pacing reference. Falls back to the DayCycle default when no clock is
## wired (headless harnesses).
func day_length() -> float:
	return day_cycle.day_length_seconds if day_cycle != null else 240.0


## Light level at [param voxel] for plant growth: the sun's intensity
## (0 at night, ~0.94 at this site's noon) while the column overhead is
## open. Any solid voxel within SKY_SCAN_LIMIT shades the cell
## completely — caves and roofs grow nothing; decorations (leaves,
## grass) and piles don't shade. A roof higher than the limit reads as
## sky — towers that tall are a rare enough edge for now.
func daylight_at(voxel: Vector3i) -> float:
	var level := day_cycle.sun_intensity() if day_cycle != null else 1.0
	# An overcast sky dims everything under it — how weather gates the
	# plant-growth model.
	level *= weather.light_factor()
	if level <= 0.0 or world == null:
		return level
	return level if sees_sky(voxel) else 0.0


## Whether [param voxel] has a vertical line of sky — any solid voxel
## within SKY_SCAN_LIMIT overhead roofs it. Caves, canopy-free ceilings
## and player roofs all shelter; decorations (leaves, grass) and piles
## don't. This is the roofed half of item 23's indoors predicate and
## the gate for item 24's weathering.
func sees_sky(voxel: Vector3i) -> bool:
	if world == null:
		return true
	var scan := voxel
	for i in SKY_SCAN_LIMIT:
		scan += Vector3i.UP
		if world.is_solid(scan):
			return false
	return true


## Illumination at [param voxel], 0–1 — daylight plus whatever lit
## lamps reach it, each falling off linearly to its spec's radius.
## This is "can you see here": movement and mood code read it; crop
## growth reads [method grow_light_at], which only grow lamps feed.
func light_at(voxel: Vector3i) -> float:
	return maxf(daylight_at(voxel), _lamp_light_at(voxel, false))


## Growth light at [param voxel] — daylight plus sun lamps. A torch
## brightens a room but doesn't feed a crop; `grow` specs do.
func grow_light_at(voxel: Vector3i) -> float:
	return maxf(daylight_at(voxel), _lamp_light_at(voxel, true))


## The lamp contribution at [param voxel] — the strongest lit lamp in
## range, with linear falloff to its spec radius. [param grow_only]
## restricts the count to sun-lamp-style fixtures.
func _lamp_light_at(voxel: Vector3i, grow_only: bool) -> float:
	var level := 0.0
	for cell: Vector3i in _lamps:
		var lamp: Building = _lamps[cell]
		var strength := lamp.lamp_strength()
		if strength <= 0.0:
			continue
		var spec := BlockRegistry.furniture_spec(lamp.spec)
		if grow_only and not spec.get(&"grow", false):
			continue
		var radius := float(spec.get(&"radius", 0))
		var dist := Vector3(voxel - lamp.voxel).length()
		if dist >= radius:
			continue
		level = maxf(level, strength * (1.0 - dist / radius))
	return level


## Work light at [param voxel] — "bright enough to work by": daylight
## and lamps from [method light_at], plus the burning fires only
## [method illumination_at] counts. The dark-work penalty and the
## in-the-dark thought read this; crop growth keeps
## [method grow_light_at].
func work_light_at(voxel: Vector3i) -> float:
	return maxf(light_at(voxel), illumination_at(voxel))


## The nearest furniture building of [param kind] within [param radius]
## of [param voxel], or null — the shared scan behind the meal-table
## and seat-comfort checks.
func furniture_near(
	voxel: Vector3i, kind: Building.Kind, radius: float
) -> Building:
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if building.kind != kind or seen.has(building):
			continue
		seen[building] = true
		if Vector3(building.voxel - voxel).length() <= radius:
			return building
	return null


## How far out a table or seat counts for a meal — the pile next to
## the dining hall reads as "at the table".
const MEAL_AURA_RADIUS := 4.5


## The combined comfort bonus surrounding [param bed] — the end table
## and dresser auras, each spec's `bed_bonus` summed across decor
## pieces whose footprint touches the bed's edge.
func bed_bonus_at(bed: Building) -> float:
	var bonus := 0.0
	var seen := {}
	for cell in bed.footprint:
		for dir in SPILL_SIDES:
			var neighbour: Building = buildings.get(cell + dir)
			if (
				neighbour == null
				or neighbour.kind != Building.Kind.DECOR
				or seen.has(neighbour)
			):
				continue
			seen[neighbour] = true
			bonus += float(
				BlockRegistry.furniture_spec(neighbour.spec).get(
					&"bed_bonus", 0.0
				)
			)
	return bonus


## The research-rate multiplier a study at [param voxel] enjoys — 1.0
## plus the strongest bookcase aura in reach (books shelved beside the
## bench beat books across the camp).
func research_boost_at(voxel: Vector3i) -> float:
	var boost := 0.0
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if building.kind != Building.Kind.DECOR or seen.has(building):
			continue
		seen[building] = true
		var aura := float(
			BlockRegistry.furniture_spec(building.spec).get(
				&"research_bonus", 0.0
			)
		)
		if aura <= 0.0:
			continue
		for fcell in building.footprint:
			if Vector3(fcell - voxel).length() <= MEAL_AURA_RADIUS:
				boost = maxf(boost, aura)
				break
	return 1.0 + boost


## How far out a unit's surroundings read for beauty — the spec pins
## 5m where RimWorld uses 8: in 3D the exposed surface in the bubble
## grows cubically, not quadratically.
const BEAUTY_RADIUS := 5.0
## Score thresholds the unit's surroundings thoughts read — scaled for
## per-face means (~6 surfaces per room cell), not RimWorld's per-tile.
const BEAUTY_DRAB := -0.05
const BEAUTY_PLEASANT := 0.10
const BEAUTY_IMPRESSIVE := 0.22


## The beauty a unit standing at [param cell] perceives — the enclosing
## room's integrated score indoors, a sight-line sample of the
## surroundings outdoors (PLAN item 34).
func unit_beauty(eye: Vector3, cell: Vector3i) -> float:
	if rooms == null or flooring == null:
		return 0.0
	var room := rooms.room_at(cell)
	if room != null:
		return rooms.score(room)
	return _sample_surroundings(eye)


## Whether [param cell] sits indoors — inside a bounded room. The flood
## only yields a Room for sealed components, so open ground and
## unbounded caverns both answer false (PLAN item 23's predicate).
func is_indoors(cell: Vector3i) -> bool:
	return rooms != null and rooms.room_at(cell) != null


## The room grade at [param cell] — `""` outdoors or for a cell the
## flood won't bound, else the impressiveness tier the stat block
## names: `awful` … `wondrous` (PLAN item 68's room stats).
func room_tier_at(cell: Vector3i) -> StringName:
	if rooms == null:
		return &""
	var room := rooms.room_at(cell)
	return &"" if room == null else rooms.tier_of(room)


## What the room at [param cell] reads as — `bedroom`, `dining`,
## `hospital`, `recreation`, `workshop`, `room`, or `""` outdoors.
func room_use_at(cell: Vector3i) -> StringName:
	if rooms == null:
		return &""
	var room := rooms.room_at(cell)
	return &"" if room == null else rooms.use_of(room)


## Outdoor surroundings: the mean beauty of everything in the bubble
## the eye can see — exposed block faces, coverings laid on them, and
## furnishings — each credit requiring a clear voxel ray. Solid cells
## in range each buy one ray whose hit names the exact face seen, so a
## covered face reads its covering's value for free; the covering pass
## then catches faces whose backs aren't the ray-hit cell (the paved
## floor under a ledge, say). Raycasts and cell probes are metered —
## `beauty_rays_per_sec`/`beauty_cells_per_sec` ride the perf line.
func _sample_surroundings(eye: Vector3) -> float:
	var lo := Vector3i(
		(eye - Vector3.ONE * BEAUTY_RADIUS).floor()
	)
	var hi := Vector3i(
		(eye + Vector3.ONE * BEAUTY_RADIUS).floor()
	)
	var sum := 0.0
	var count := 0
	var seen_faces: Dictionary = {}
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var cell := Vector3i(x, y, z)
				_beauty_cells += 1
				var center := Vector3(cell) + Vector3.ONE * 0.5
				var to := center - eye
				var d := to.length()
				if d > BEAUTY_RADIUS + 0.5 or d < 0.01:
					continue
				if not world.is_solid(cell):
					continue
				var hit := world.raycast(eye, to / d, d + 0.1)
				_beauty_rays += 1
				if hit == null or hit.position != cell:
					continue
				# The ray's last open cell is exactly the viewer's side
				# of the face it landed on — coverings resolve for free.
				var face := Flooring.face_index(cell - hit.previous_position)
				var key := Vector4i(
					hit.previous_position.x, hit.previous_position.y,
					hit.previous_position.z, face
				)
				if seen_faces.has(key):
					continue
				seen_faces[key] = true
				if face >= 0:
					sum += flooring.face_beauty(hit.previous_position, face)
				else:
					sum += BlockRegistry.block_beauty(world.get_block(cell))
				count += 1
	# Covered faces whose backing block isn't the ray-hit cell —
	# e.g. a paved floor the eye's terrain rays all miss because a
	# sill's edge catches them first.
	for entry in flooring.covers_within(lo, hi):
		var cell: Vector3i = entry[0]
		var face: int = entry[1]
		var key := Vector4i(cell.x, cell.y, cell.z, face)
		if seen_faces.has(key):
			continue
		var dir := Vector3(Flooring.FACE_DIRS[face])
		var point := Vector3(cell) + Vector3.ONE * 0.5 + dir * 0.5
		var to := point - eye
		var d := to.length()
		if d > BEAUTY_RADIUS or d < 0.01:
			continue
		var hit := world.raycast(eye, to / d, d + 0.1)
		_beauty_rays += 1
		# The covering is visible only through its own open cell — the
		# ray must reach the backing block *through* the dressed face,
		# not land on the block from another side.
		if (
			hit == null
			or hit.position != cell + Flooring.FACE_DIRS[face]
			or hit.previous_position != cell
		):
			continue
		seen_faces[key] = true
		sum += flooring.face_beauty(cell, face)
		count += 1
	# Furnishings and doors in the bubble — one ray each, clear if it
	# reaches the object's cell unblocked.
	var seen_buildings: Dictionary = {}
	for cell: Vector3i in buildings:
		var building: Building = buildings[cell]
		if building.beauty == 0.0 or seen_buildings.has(building):
			continue
		seen_buildings[building] = true
		var center := Vector3(building.voxel) + Vector3.ONE * 0.5
		var to := center - eye
		var d := to.length()
		if d > BEAUTY_RADIUS or d < 0.01:
			continue
		var hit := world.raycast(eye, to / d, d + 0.1)
		_beauty_rays += 1
		if hit != null and (
			eye.distance_to(Vector3(hit.previous_position) + Vector3.ONE * 0.5)
			< d - 0.5
		):
			continue
		sum += building.beauty
		count += 1
	return sum / count if count > 0 else 0.0


## Effective fertility at [param cell]: the block type's default plus
## any stored fertilization. 0 for blocks that can't grow (stone, air);
## past 1.0 on fertilized dirt.
func effective_fertility(cell: Vector3i) -> float:
	var base := (
		BlockRegistry.default_fertility(world.get_block(cell))
		if world != null
		else 0.0
	)
	return base + float(fertilization.get(cell, 0.0))


## Adds [param amount] (fraction points — 0.01 = 1%) to [param cell]'s
## stored fertilization. Ignored on blocks that can't take it, so
## compost rotting on bare stone feeds nothing.
func fertilize(cell: Vector3i, amount: float) -> void:
	if world == null:
		return
	if BlockRegistry.fertilizability(world.get_block(cell)) <= 0.0:
		return
	var level := float(fertilization.get(cell, 0.0)) + amount
	if level <= 0.0:
		fertilization.erase(cell)
	else:
		fertilization[cell] = level


## Growth consumes the soil's stored boost — the plant systems call this
## with the game-seconds of growth actually accrued this tick.
func _deplete_fertility(cell: Vector3i, growth_seconds: float) -> void:
	var level := float(fertilization.get(cell, 0.0))
	if level <= 0.0:
		return
	level -= growth_seconds * FERTILITY_DEPLETION_PER_SEC
	if level <= 0.0:
		fertilization.erase(cell)
	else:
		fertilization[cell] = level


## Item-53 — the ground-moisture query: saturation 0..1 on the soil
## column holding [param cell]. The moisture seen is the max of the
## ambient damp, stored rain-soak (decaying), and the irrigation bonus
## of nearby standing water. Plants asking register their cell for
## rain wetting — untended ground never accrues.
func soil_moisture_at(cell: Vector3i) -> float:
	_moisture_cells[cell] = true
	var col := Vector2i(cell.x, cell.z)
	var m := maxf(MOIST_AMBIENT, float(_soil_wet.get(col, 0.0)))
	return maxf(m, _irrigation_bonus(col))


## The moisture a wet column lends [param col] — falls off linearly
## with column distance to the nearest wet column out to a reach set
## by the water body's size: a 100-column pond reaches ~6, a 4-column
## puddle ~1.5, a lone wet cell only its own. DESIGN's "size the
## radius by the water body, not the cell" abuse note.
func _irrigation_bonus(col: Vector2i) -> float:
	if world == null or world.sim == null:
		return 0.0
	var best := 0.0
	for dx in range(-MOIST_RADIUS_MAX, MOIST_RADIUS_MAX + 1):
		for dz in range(-MOIST_RADIUS_MAX, MOIST_RADIUS_MAX + 1):
			var dist := sqrt(float(dx * dx + dz * dz))
			if dist > MOIST_RADIUS_MAX:
				continue
			var c := col + Vector2i(dx, dz)
			if world.water_level_at(c.x, c.y) <= -30000:
				continue
			var radius := maxf(0.5, 0.75 * sqrt(_water_body_size(c)))
			if dist >= radius:
				continue
			best = maxf(best, MOIST_IRRIGATED * (1.0 - dist / radius))
	return best


## Columns in the connected body under [param col] — 4-neighbour flood
## over wet columns, bounded so a river doesn't run the whole map. The
## count drives the irrigation reach; cached a game-minute per wet
## column so a field full of crops shares one BFS.
func _water_body_size(col: Vector2i) -> int:
	var now := game_msec()
	var hit: Variant = _moist_body_cache.get(col)
	if hit is Array and now < int(hit[1]):
		return int(hit[0])
	var seen := {col: true}
	var queue: Array[Vector2i] = [col]
	var head := 0
	while head < queue.size() and seen.size() < 256:
		var c: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if not seen.has(n) and world.water_level_at(n.x, n.y) > -30000:
				seen[n] = true
				queue.append(n)
	_moist_body_cache[col] = [seen.size(), now + int(MOIST_BODY_CACHE_S * 1000.0)]
	return int(seen.size())


## The rain-soak sweep — wet tracked columns under the sky while liquid
## precipitation falls (snow holds its water, matching the sim's rain
## feed), and drain every wet column toward ambient. Runs on the
## worksite cadence; rates are per game-second.
func _moisture_tick(elapsed: float) -> void:
	var gain := 0.0
	if weather.state == Weather.State.RAIN:
		gain = MOIST_RAIN_GAIN
	elif weather.state == Weather.State.STORM_WET:
		gain = MOIST_STORM_GAIN
	if gain > 0.0:
		for cell in _moisture_cells:
			if not sees_sky(cell):
				continue
			var col := Vector2i(cell.x, cell.z)
			var w := float(_soil_wet.get(col, 0.0))
			_soil_wet[col] = minf(MOIST_SOAKED, w + gain * elapsed)
	var fade := MOIST_DRAIN * elapsed
	for col in _soil_wet.keys():
		var w: float = float(_soil_wet[col]) - fade
		if w <= 0.0:
			_soil_wet.erase(col)
		else:
			_soil_wet[col] = w


## The serialized shape of `_soil_wet` — [x, z, saturation] rows.
func _soil_wet_list() -> Array:
	var list: Array = []
	for col: Vector2i in _soil_wet:
		list.append([col.x, col.y, _soil_wet[col]])
	return list


## The game clock in milliseconds — job retry records, claim languish,
## plant regrow timers and blacklist cool-offs all compare against it, so
## pausing freezes them and speed multipliers accelerate them like every
## other in-game duration. Falls back to wall time without a day cycle.
func game_msec() -> int:
	return (
		day_cycle.game_msec() if day_cycle != null
		else Time.get_ticks_msec()
	)


## The single speed authority — the HUD's buttons and the overseer's hotkeys
## all come through here so the sleep boost can't fight a manual setting:
## pausing always wins, otherwise the clock runs at the boost speed while
## engaged and at the player's pick otherwise.
func set_speed(scale: float) -> void:
	if scale > 0.0:
		_selected_speed = scale
	get_tree().paused = scale <= 0.0
	_apply_speed()


func set_paused(on: bool) -> void:
	get_tree().paused = on
	_apply_speed()


## Arms or disarms the sleep-boost toggle — the HUD's Zz button.
func set_sleep_boost(on: bool) -> void:
	sleep_boost = on
	_apply_speed()


## True while the boost is actually driving the clock — armed, unpaused,
## and everyone asleep. The HUD reads this to show the engaged state.
func sleep_boost_engaged() -> bool:
	return sleep_boost and not get_tree().paused and _all_asleep()


## Every unit at the focused site is asleep — the roster is the site's
## unit list; the empty roster never counts as "everyone asleep".
func _all_asleep() -> bool:
	return not units.is_empty() and _sleeping.size() == units.size()


func _apply_speed() -> void:
	if get_tree().paused:
		return
	Engine.time_scale = (
		SLEEP_BOOST_SPEED if sleep_boost_engaged() else _selected_speed
	)


## The sleep counter's observer — one state_changed hook per unit (the
## bound unit argument trails the emitted from/to pair).
func _on_unit_state_changed(
	from_state: Unit.State, to_state: Unit.State, unit: Unit
) -> void:
	if to_state == Unit.State.SLEEPING:
		_sleeping[unit] = true
	elif from_state == Unit.State.SLEEPING:
		_sleeping.erase(unit)
	_apply_speed()


func _make_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


## A wireframe unit cube, centred at the origin — stockpile tiles get a
## faint outline rather than a filled box.
func _make_outline_mesh() -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var corners: Array[Vector3] = []
	for x in [-0.51, 0.51]:
		for y in [-0.51, 0.51]:
			for z in [-0.51, 0.51]:
				corners.append(Vector3(x, y, z))
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in corners.size():
		for j in range(i + 1, corners.size()):
			var d := (corners[i] - corners[j]).abs()
			if int(d.x > 0.0) + int(d.y > 0.0) + int(d.z > 0.0) == 1:
				mesh.surface_add_vertex(corners[i])
				mesh.surface_add_vertex(corners[j])
	mesh.surface_end()
	return mesh


## Queues a mining job, unless that voxel is already designated.
func designate_mine(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION):
		return null
	if not world.is_solid(voxel_position):
		return null
	if cell_claimed(voxel_position, Occ.TREE):
		# Tree parts are felled whole — designate_chop instead.
		return null

	var job := ColonyJob.new(ColonyJob.Type.MINE, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _marker_material)
	DLog.log("designated mine %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a clearing job for a voxel holding items: a unit moves the whole
## pile into adjoining voxels. Only piles can be designated.
func designate_clear(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION):
		return null
	var pile := item_pile_at(voxel_position)
	if pile == null or pile.items.is_empty():
		return null

	var job := ColonyJob.new(ColonyJob.Type.CLEAR, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _clear_marker_material)
	DLog.log("designated clear %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a construction of the player's chosen [param spec] — a wall
## block or a door — from [constant BlockRegistry.BUILD_SPECS]. A unit
## fetches what the spec's recipe needs from piles — loose soil, stone
## boulders and cobbles, logs or planks — and raises it. The voxel must
## be free of solid terrain, buildings, growing things and not packed
## full of items; a door leaves its cell open air, so the building
## check is what keeps two doors out of the same doorway.
func designate_build(
	voxel_position: Vector3i, spec: StringName,
	material_pin := int(BlockRegistry.Resource_.NONE)
) -> ColonyJob:
	if not BlockRegistry.BUILD_SPECS.has(spec):
		return null
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if (
		world.get_block(voxel_position) != BlockRegistry.Block.AIR
		or cell_claimed(voxel_position, Occ.PACKED)
	):
		return null
	if BlockRegistry.spec_is_door(spec):
		# A door is two cells tall — the capsule's headroom above the
		# sill is part of its doorway and must be open too.
		var headroom := voxel_position + Vector3i.UP
		if (
			cell_claimed(headroom, Occ.DESIGNATION | Occ.BUILDING)
			or world.get_block(headroom) != BlockRegistry.Block.AIR
		):
			return null
	if cell_claimed(voxel_position, Occ.TREE):
		# Sapling and leaf cells are air but claimed — a wall would entomb
		# the decoration and block the tree's growth.
		return null

	var job := ColonyJob.new(ColonyJob.Type.BUILD, voxel_position)
	job.build_spec = spec
	# A pin narrows the spec's material class to one member — it must be
	# a member (granite pins stone, never wood) or the order is generic.
	job.material = (
		material_pin
		if (
			material_pin != int(BlockRegistry.Resource_.NONE)
			and BlockRegistry.material_fits(
				material_pin, int(BlockRegistry.spec_material(spec))
			)
		)
		else int(BlockRegistry.spec_material(spec))
	)
	job.block_id = BlockRegistry.spec_block(spec)
	if BlockRegistry.spec_is_door(spec):
		# The headroom cell is half the doorway — the plan claims it too
		# so nothing else designates it out from under the door.
		job.extra_voxels.append(voxel_position + Vector3i.UP)
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated build %s %s" % [spec, voxel_position])
	job_added.emit(job)
	return job


## Queues a paving job on [param cell]'s [param face_dir]-ward face —
## a BUILD job that dresses the exposed block face rather than filling
## the cell (PLAN item 34). The unit fetches the spec's material and
## trowels it on; the job reuses the whole build fetch-and-deliver loop.
func designate_pave(cell: Vector3i, face_dir: Vector3i, spec: StringName) -> ColonyJob:
	if not BlockRegistry.FLOOR_SPECS.has(spec):
		return null
	var face := Flooring.face_index(face_dir)
	if face < 0 or not flooring.coverable(cell, face):
		return null
	if pave_job_at(cell, face) != null or strip_job_at(cell, face) != null:
		return null

	var job := ColonyJob.new(ColonyJob.Type.BUILD, cell)
	job.build_spec = spec
	job.material = BlockRegistry.FLOOR_SPECS[spec][&"material"]
	job.face_dir = face_dir
	_register_job(job)
	_add_face_marker(cell, face, _build_marker_material)
	DLog.log("designated pave %s %s face %d" % [spec, cell, face])
	job_added.emit(job)
	return job


## Queues a stripping job on [param cell]'s [param face_dir]-ward face —
## a DECONSTRUCT that takes the covering off and recovers nothing.
func designate_strip_pave(cell: Vector3i, face_dir: Vector3i) -> ColonyJob:
	var face := Flooring.face_index(face_dir)
	if face < 0 or flooring.covering_at(cell, face) == &"":
		return null
	if strip_job_at(cell, face) != null or pave_job_at(cell, face) != null:
		return null

	var job := ColonyJob.new(ColonyJob.Type.DECONSTRUCT, cell)
	job.face_dir = face_dir
	_register_job(job)
	_add_face_marker(cell, face, _deconstruct_marker_material)
	DLog.log("designated strip %s face %d" % [cell, face])
	job_added.emit(job)
	return job


## The active paving job on [param cell]'s [param face]-ward face —
## the designation dedupe.
func pave_job_at(cell: Vector3i, face: int) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BUILD
			and job.build_spec != &"conduit"
			and job.face_dir == Flooring.FACE_DIRS[face]
			and job.voxel_position == cell
			and job.is_active()
		):
			return job
	return null


## The active stripping job on the face — same lookup, other verb.
func strip_job_at(cell: Vector3i, face: int) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.DECONSTRUCT
			and job.face_dir == Flooring.FACE_DIRS[face]
			and job.voxel_position == cell
			and job.is_active()
		):
			return job
	return null


## A paving job is done once its material is all delivered: the face
## dresses. If the face can't take it anymore — backing mined out
## mid-work — the escrowed material drops at the site instead.
func complete_pave(job: ColonyJob) -> void:
	var face := Flooring.face_index(job.face_dir)
	if face < 0 or not flooring.lay(job.voxel_position, face, job.build_spec):
		for item in job.components:
			_drop_item(item, job.voxel_position)
		job.components.clear()
	_finish_job(job)


## A stripping job is done once its progress fills: the covering comes
## off and nothing comes back.
func complete_pave_strip(job: ColonyJob) -> void:
	var face := Flooring.face_index(job.face_dir)
	if face >= 0:
		flooring.strip(job.voxel_position, face)
	_finish_job(job)


## Queues a cooler build at [param voxel_position], its cold side
## facing [param cold_dir] — the direction heat is drawn from. The
## siting is the production rule (open air over solid, clear of piles
## and claims); the direction is the player's pick at designation and
## rides the job's `face_dir` through to the building.
func designate_cooler(
	voxel_position: Vector3i, cold_dir: Vector3i = Vector3i.ZERO
) -> ColonyJob:
	var job := designate_production(voxel_position, &"cooler")
	if job != null:
		job.face_dir = cold_dir
	return job


## The wall face a conduit line can hide in: [param cell] must be open
## air with a *constructed* solid block on its [param face_dir] side —
## a player-built wall, never natural stone or dirt — that isn't
## already wired and carries no live install job.
func conduit_face_open(cell: Vector3i, face_dir: Vector3i) -> bool:
	var face := Flooring.face_index(face_dir)
	if face < 0 or not world.is_editable(cell):
		return false
	if world.get_block(cell) != BlockRegistry.Block.AIR:
		return false
	var target := cell + face_dir
	if not world.is_solid(target):
		return false
	var building := building_at(target)
	return (
		building != null
		and building.kind == Building.Kind.WALL
		and not building.conduit
	)


## Queues a conduit install on [param cell]'s [param face_dir]-ward
## wall — a face job like paving: the unit works the open cell's face
## and the wire ends up inside the constructed block. Gated on
## Electrician — running live wire isn't unskilled work.
func designate_conduit(cell: Vector3i, face_dir: Vector3i) -> ColonyJob:
	var face := Flooring.face_index(face_dir)
	if face < 0 or not conduit_face_open(cell, face_dir):
		return null
	if conduit_job_at(cell, face) != null:
		return null
	var job := ColonyJob.new(ColonyJob.Type.BUILD, cell)
	job.build_spec = &"conduit"
	job.material = BlockRegistry.Resource_.COPPER
	job.face_dir = face_dir
	job.required_skill = ColonyJob.Skill.ELECTRICIAN
	_register_job(job)
	_add_face_marker(cell, face, _build_marker_material)
	DLog.log("designated conduit %s face %d" % [cell, face])
	job_added.emit(job)
	return job


## The active conduit install on [param cell]'s [param face]-ward wall
## — the designation dedupe.
func conduit_job_at(cell: Vector3i, face: int) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BUILD
			and job.build_spec == &"conduit"
			and job.face_dir == Flooring.FACE_DIRS[face]
			and job.voxel_position == cell
			and job.is_active()
		):
			return job
	return null


## A conduit install is done once the wire is delivered: the wall
## record gains its line (and keeps the wire among its components, so
## taking the wall down hands it back). If the wall went away mid-work
## the escrowed wire drops at the site instead.
func complete_conduit(job: ColonyJob) -> void:
	var target := job.voxel_position + job.face_dir
	var building := building_at(target)
	if building != null and building.kind == Building.Kind.WALL:
		building.conduit = true
		for item in job.components:
			building.components.append(item)
		# A conduit line is built infrastructure too — its wall pulls
		# the neighbourhood into the home area.
		_grow_home_around(target)
	else:
		for item in job.components:
			_drop_item(item, job.voxel_position)
	job.components.clear()
	_finish_job(job)


## The face marker for a pave or strip plan — a thin slab floating on
## the face it works, keyed (cell, face index) so a cell can carry a
## plan on more than one face at once.
func _add_face_marker(
	cell: Vector3i, face: int, material: StandardMaterial3D
) -> void:
	var key := Vector4i(cell.x, cell.y, cell.z, face)
	var stale: Node3D = _face_markers.get(key)
	if stale != null:
		# A second plan on one face — a wall can be both wired and
		# paved — replaces the visible slab rather than leaking it.
		stale.queue_free()
		_face_markers.erase(key)
	var marker := MeshInstance3D.new()
	marker.mesh = _face_marker_mesh
	marker.material_override = material
	var dir := Vector3(Flooring.FACE_DIRS[face])
	marker.position = (
		Vector3(cell) + Vector3.ONE * 0.5 + dir * 0.44
	)
	marker.basis = Basis.looking_at(
		dir, Vector3.FORWARD if absf(dir.y) > 0.9 else Vector3.UP
	)
	marker.visible = _plan_visible()
	add_child(marker)
	_face_markers[key] = marker


## Drops a face marker — the pair of [method _add_face_marker].
func _remove_face_marker(cell: Vector3i, face: int) -> void:
	var key := Vector4i(cell.x, cell.y, cell.z, face)
	var marker: Node3D = _face_markers.get(key)
	if marker != null:
		marker.queue_free()
		_face_markers.erase(key)


## Marks a voxel as a stockpile cell — a haul destination for idle
## units. Single-cell gestures go through the same zone resolution as a
## drag, with the voxel as its own anchor.
func designate_stockpile(voxel_position: Vector3i) -> bool:
	var cells: Array[Vector3i] = [voxel_position]
	return designate_stockpile_cells(cells, voxel_position) != null


## Designates the still-free, stockpileable cells of [param cells] into
## the single zone [_zone_target] resolves — a drag is one gesture with
## one target, never per-cell merging. [param anchor] is the first-click
## cell, [param override] the zone-override key held at that click.
## Returns the zone cells joined, or null when the gesture fails.
func designate_stockpile_cells(
	cells: Array[Vector3i], anchor: Vector3i, override: bool = false,
	dump := false, warehouse := false
) -> StockpileZone:
	var resolution := _zone_target(stockpiles, cells, anchor, override)
	if not resolution[&"ok"]:
		return null
	var zone: StockpileZone = resolution[&"zone"]
	if zone != null and zone.warehouse != warehouse:
		# A warehouse drag doesn't merge into a floor stockpile, nor
		# the reverse — different classes stay distinct zones, like
		# RimWorld's stockpile vs. dumping zone.
		if not _has_free_cell(stockpiles, cells):
			return null
		zone = null
	if zone == null:
		zone = StockpileZone.new()
		if dump:
			zone.priority = StockpileZone.Priority.LOW
			for material in BlockRegistry.Resource_.values():
				if material != BlockRegistry.Resource_.NONE and not DUMP_ADMITTED.has(material):
					zone.rejected[int(material)] = true
		zone.warehouse = warehouse
	var placed := false
	for cell in cells:
		if not _stockpile_cellable(cell):
			continue
		zone.cells[cell] = true
		stockpiles[cell] = zone
		_index_add(_stockpile_buckets, cell)
		_add_marker(
			cell,
			(
				_warehouse_marker_material
				if zone.warehouse
				else _stockpile_marker_material
			),
			_outline_mesh
		)
		_grow_home_around(cell)
		placed = true
	return zone if placed else null


## Marks the cells as warehouse — the bulk-goods zone: crates and
## oversized items stack twice a floor cell's fill there, and it's the
## only zone that admits a crate at all.
func designate_warehouse(voxel_position: Vector3i) -> bool:
	var cells: Array[Vector3i] = [voxel_position]
	return designate_warehouse_cells(cells, voxel_position) != null


func designate_warehouse_cells(
	cells: Array[Vector3i], anchor: Vector3i, override: bool = false
) -> StockpileZone:
	return designate_stockpile_cells(cells, anchor, override, false, true)


## Marks a voxel as a dumping-zone cell — same record, different
## defaults: low priority and a garbage-only filter (rubble, ores and
## litter) so haulers treat it as the far-away junk shelf.
func designate_dump_stockpile(voxel_position: Vector3i) -> bool:
	var cells: Array[Vector3i] = [voxel_position]
	return designate_stockpile_cells(cells, voxel_position, false, true) != null


func designate_dump_stockpile_cells(
	cells: Array[Vector3i], anchor: Vector3i, override: bool = false
) -> StockpileZone:
	return designate_stockpile_cells(cells, anchor, override, true)


## The materials a fresh dumping zone admits — mined rubble and organic
## litter; lumber, food and crafted goods stay out. The record is the
## ordinary reject set, so the preset is only a starting filter.
const DUMP_ADMITTED: Array[BlockRegistry.Resource_] = [
	BlockRegistry.Resource_.SOIL,
	BlockRegistry.Resource_.CLAY,
	BlockRegistry.Resource_.STONE,
	BlockRegistry.Resource_.COAL,
	BlockRegistry.Resource_.HEMATITE,
	BlockRegistry.Resource_.MALACHITE,
	BlockRegistry.Resource_.CASSITERITE,
	BlockRegistry.Resource_.NATIVE_GOLD,
	BlockRegistry.Resource_.BRANCH,
	BlockRegistry.Resource_.LEAF,
	BlockRegistry.Resource_.COMPOST,
]


## Sets the covering zone's priority — every cell shares the rank.
func set_stockpile_priority(
	voxel_position: Vector3i, priority: StockpileZone.Priority
) -> void:
	var zone := stockpile_at(voxel_position)
	if zone != null:
		zone.priority = priority


## The distinct zones on the board — the bill destination picker's
## list and a test seam.
func stockpile_zones() -> Array[StockpileZone]:
	var found: Array[StockpileZone] = []
	for voxel: Vector3i in stockpiles:
		var zone := stockpiles[voxel]
		if not found.has(zone):
			found.append(zone)
	return found


## Whether a cell can take a stockpile designation — the gesture's
## per-cell gate; already-zoned cells are never reassigned.
func _stockpile_cellable(voxel_position: Vector3i) -> bool:
	return (
		not cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING)
		and not stockpiles.has(voxel_position)
		and world.get_block(voxel_position) == BlockRegistry.Block.AIR
		and not cell_claimed(voxel_position, Occ.PILE)
		and world.is_solid(voxel_position + Vector3i.DOWN)
	)


## Removes a cell from its stockpile zone; the zone record lives on in
## the remaining cells. Any items piled there stay put.
func undesignate_stockpile(voxel_position: Vector3i) -> bool:
	var zone := stockpile_at(voxel_position)
	if zone == null:
		return false
	var standing := building_at(voxel_position)
	if standing != null and (
		standing.kind == Building.Kind.SHELF
		or standing.kind == Building.Kind.COMPOST_BIN
	):
		# A storage building's zone isn't a designation — it belongs to
		# the building and leaves with it, not with the erase tool.
		return false
	zone.cells.erase(voxel_position)
	stockpiles.erase(voxel_position)
	_index_remove(_stockpile_buckets, voxel_position)
	_remove_marker(voxel_position)
	return true


func is_stockpile(voxel_position: Vector3i) -> bool:
	return stockpiles.has(voxel_position)


## The zone covering [param voxel_position], or null.
func stockpile_at(voxel_position: Vector3i) -> StockpileZone:
	return stockpiles.get(voxel_position)


## Creates a named allowed area — "Area 3" when no label is given —
## and returns it for the panel's new row. Areas never overlap: a cell
## painted into one leaves whichever it had.
func add_area(label := "") -> AllowedArea:
	var area := AllowedArea.new()
	area.label = label if label != "" else "Area %d" % (areas.size() + 1)
	areas.append(area)
	return area


## Drops an area: its cells free, and every unit and animal assigned
## to it goes unrestricted.
func remove_area(area: AllowedArea) -> void:
	if paint_area == area:
		paint_area = null
	for cell in area.cells:
		_area_cells.erase(cell)
		_remove_area_marker(cell)
	areas.erase(area)
	for unit in units:
		if unit.allowed_area == area:
			set_unit_area(unit, null)
	for animal in animals:
		if animal.allowed_area == area:
			animal.allowed_area = null


## Paints [param cells] into [param area] — the expand tool's gesture.
## Cells already owned by another area move over; cells already in this
## one are skipped. A solid cell can be painted (RimWorld lets an area
## cover walls — the gate only tests job voxels). Area markers ride
## their own map — they can overlay stockpiles and designations alike.
func designate_area_cells(cells: Array, area: AllowedArea) -> int:
	if area == null or not areas.has(area):
		return 0
	var painted := 0
	for cell: Vector3i in cells:
		var owner: AllowedArea = _area_cells.get(cell)
		if owner == area:
			continue
		if owner != null:
			owner.cells.erase(cell)
		area.cells[cell] = true
		_area_cells[cell] = area
		_add_area_marker(cell, area)
		painted += 1
	return painted


## Erases [param cells] from whichever area owns them — the shrink
## tool's gesture; unowned cells are skipped.
func undesignate_area_cells(cells: Array) -> int:
	var erased := 0
	for cell: Vector3i in cells:
		var owner: AllowedArea = _area_cells.get(cell)
		if owner == null:
			continue
		owner.cells.erase(cell)
		_area_cells.erase(cell)
		_remove_area_marker(cell)
		erased += 1
	return erased


## The area overlay marker — a floor hugging tint on the cell's top
## face so it can share a cell with a stockpile outline or a plan.
func _add_area_marker(voxel_position: Vector3i, area: AllowedArea) -> void:
	_remove_area_marker(voxel_position)
	var marker := MeshInstance3D.new()
	marker.mesh = _area_marker_mesh
	marker.material_override = _area_marker_material(area)
	marker.position = Vector3(voxel_position) + Vector3(0.5, 0.98, 0.5)
	marker.visible = markers_visible
	add_child(marker)
	_area_markers[voxel_position] = marker


func _remove_area_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _area_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_area_markers.erase(voxel_position)


## The area owning [param voxel_position], or null.
func area_at(voxel_position: Vector3i) -> AllowedArea:
	return _area_cells.get(voxel_position)


## Whether [param voxel] sits inside [param area] — the gate every
## target-selection path shares: a null area is unrestricted.
static func in_area(area: AllowedArea, voxel: Vector3i) -> bool:
	return area == null or area.cells.has(voxel)


## The nearest cell of [param area] to [param from] — where a unit or
## animal assigned to the area but standing outside it walks back to.
## Linear over the area's cells: areas are small against the map.
func nearest_area_cell(from: Vector3i, area: AllowedArea) -> Vector3i:
	if area == null:
		return Vector3i.MAX
	var best := Vector3i.MAX
	var best_sq := INF
	for cell: Vector3i in area.cells:
		var sq := (Vector3(cell) - Vector3(from)).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = cell
	return best


## Assigns [param unit] to [param area] (null = unrestricted) — drops
## its job when the job's target cell sits outside the new bounds.
func set_unit_area(unit: Unit, area: AllowedArea) -> void:
	unit.allowed_area = area
	if (
		area != null
		and unit.job != null
		and not area.cells.has(unit.job.voxel_position)
	):
		unit.abandon_job()


## Assigns [param animal] to [param area] (null = unrestricted).
func set_animal_area(animal: Animal, area: AllowedArea) -> void:
	animal.allowed_area = area


## The marker tint an area's cells wear — one hue per area, picked from
## its slot so neighbours read as distinct paint.
func _area_marker_material(area: AllowedArea) -> StandardMaterial3D:
	var index := areas.find(area)
	while _area_marker_materials.size() <= index:
		var hue := fmod(_area_marker_materials.size() * 0.29 + 0.55, 1.0)
		var material := _make_marker_material(
			Color.from_hsv(hue, 0.65, 0.95, 0.4)
		)
		_area_marker_materials.append(material)
	return _area_marker_materials[maxi(index, 0)]


## ---------------------------------------------------------------------------
## Home area (PLAN item 44) — the colony's lived-in footprint. Firefight,
## repair and (future) clean bills only spawn on its cells; the
## autonomous fetch queries prefer in-home piles. Painted by hand or
## grown around construction while `auto_home` holds — unlike an
## allowed area it restricts jobs, not units, and overlaps everything.
## ---------------------------------------------------------------------------

## Whether [param voxel] sits inside the home area — the gate the
## firefight and repair bill posters share.
func in_home_area(voxel: Vector3i) -> bool:
	return home_cells.has(voxel)


## Paints [param cells] into the home area — the expand tool's gesture.
## Like an allowed area a home cell may cover walls and open ground
## alike; the gates only read membership, never the terrain.
func designate_home_cells(cells: Array) -> int:
	var painted := 0
	for cell: Vector3i in cells:
		if home_cells.has(cell):
			continue
		home_cells[cell] = true
		_index_add(_home_buckets, cell)
		_add_home_marker(cell)
		painted += 1
	return painted


## Erases [param cells] from the home area — the shrink tool's gesture;
## unowned cells are skipped.
func undesignate_home_cells(cells: Array) -> int:
	var erased := 0
	for cell: Vector3i in cells:
		if not home_cells.has(cell):
			continue
		home_cells.erase(cell)
		_index_remove(_home_buckets, cell)
		_remove_home_marker(cell)
		erased += 1
	return erased


## One built or designated cell's neighbourhood joins the home area —
## the cell itself plus the 3×3×3 cube around it, RimWorld's
## construction halo. Skipped while [member auto_home] is off.
func _grow_home_around(voxel: Vector3i) -> void:
	if not auto_home:
		return
	var cells: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				cells.append(voxel + Vector3i(dx, dy, dz))
	designate_home_cells(cells)


## The nearest home cell to [param from] — for AI that needs to walk
## back into the colony's footprint. Ring search over the bucket index;
## empty when the area is empty.
func nearest_home_cell(from: Vector3i) -> Vector3i:
	return _nearest_indexed(
		from, _home_buckets, func(_voxel: Vector3i) -> int:
			return _Match.FRESH
	)


## Wraps a fetch classifier so an out-of-home FRESH drops to RETRY —
## the in-home hit at any distance outranks an outside one, and the
## outside pick only wins when nothing at home qualifies. Identity
## while the home area is empty: no paint, no preference.
func _home_match(classify: Callable, far_ok := false) -> Callable:
	if home_cells.is_empty() or far_ok:
		return classify
	return func(voxel: Vector3i) -> int:
		var tier: int = classify.call(voxel)
		if tier == _Match.FRESH and not home_cells.has(voxel):
			return _Match.RETRY
		return tier


## The home overlay marker — shares the area film's mesh; only the tint
## and the visibility switch differ.
func _add_home_marker(voxel_position: Vector3i) -> void:
	_remove_home_marker(voxel_position)
	var marker := MeshInstance3D.new()
	marker.mesh = _area_marker_mesh
	marker.material_override = _home_marker_material
	marker.position = Vector3(voxel_position) + Vector3(0.5, 0.96, 0.5)
	marker.visible = _home_visible
	add_child(marker)
	_home_markers[voxel_position] = marker


func _remove_home_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _home_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_home_markers.erase(voxel_position)


## Shows or hides the home overlay — the HUD's "Home area" toggle.
func set_home_visible(value: bool) -> void:
	_home_visible = value
	for voxel: Vector3i in _home_markers:
		_home_markers[voxel].visible = value


## The Beauty and Roofs display toggles — each flips its overlay
## layer; the paint itself is the overlays node's rolling budget.
func set_beauty_overlay(on: bool) -> void:
	if overlays != null:
		overlays.set_beauty(on)


func set_roofs_overlay(on: bool) -> void:
	if overlays != null:
		overlays.set_roofs(on)


## Per-frame drive for the overlays while any is up — the HUD feeds
## the camera focus the region centres on. Cheap while both are off.
func push_overlay_focus(focus: Vector3) -> void:
	if overlays != null and overlays.any_active():
		overlays.tick(focus)


## Sets or clears the forbid flag on every item in the pile at
## [param voxel_position] — a pile is the selectable granularity since
## its contents merge visually.
func set_pile_forbidden(voxel_position: Vector3i, forbidden: bool) -> void:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return
	for item in pile.items:
		item.forbidden = forbidden
	# The flags moved but nothing else did — redraw the pile's X mark.
	pile._rebuild_mesh()


## True when the pile at [param voxel_position] holds nothing a settler
## may take — the "unforbid" state for the toggle.
func pile_all_forbidden(voxel_position: Vector3i) -> bool:
	var pile := item_pile_at(voxel_position)
	if pile == null or pile.items.is_empty():
		return false
	for item in pile.items:
		if not item.forbidden:
			return false
	return true


## True when at least one item in the pile is forbidden — the
## unforbid tool's validity check.
func pile_any_forbidden(voxel_position: Vector3i) -> bool:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return false
	for item in pile.items:
		if item.forbidden:
			return true
	return false


## Applies a zone filter to every cell of the zone at
## [param voxel_position] — the paste and preset-load path: the reject
## set is replaced wholesale.
func set_stockpile_filter(voxel_position: Vector3i, rejected: Dictionary) -> void:
	var zone := stockpile_at(voxel_position)
	if zone == null:
		return
	zone.rejected = rejected.duplicate()


## The shelf standing at [param voxel_position], or null — shelf cells
## double as stockpile cells with a taller capacity.
func shelf_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.kind == Building.Kind.SHELF:
		return building
	return null


## The compost bin standing at [param voxel_position], or null — like a
## shelf its cell is a stockpile, but one that takes only compostable
## materials and rots them three times as fast.
func compost_bin_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.kind == Building.Kind.COMPOST_BIN:
		return building
	return null


## The neighbour's zone when [param voxel_position] borders one, else a
## fresh record — deserialize uses it so old per-tile filters keep
## their groupings: [param signature] narrows the match to zones whose
## reject set prints identically.
func _stockpile_zone_for(
	voxel_position: Vector3i, signature := ""
) -> StockpileZone:
	# The cell's own zone first — a shelf registers its cell ahead of
	# the stockpile list, and a signature match reuses that record
	# instead of orphaning it.
	var own: StockpileZone = stockpiles.get(voxel_position)
	if own != null and (signature == "" or own.signature() == signature):
		return own
	for dir in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		var zone: StockpileZone = stockpiles.get(voxel_position + dir)
		if zone != null and (signature == "" or zone.signature() == signature):
			return zone
	return StockpileZone.new()


## The zone-targeting rules for a designation gesture — shared by
## stockpiles and farm fields, which both keep a cell → zone map.
## [param cells] is the whole selection, [param anchor] its first-click
## cell, [param override] whether the zone-override key was held at that
## click. Returns {&"ok": false} when the gesture fails — anchor
## bordering two or more zones, an anchorless box spanning two or more
## zones, or nothing left to add — else {&"zone": X} to target X, or
## {"zone": null} to create a fresh zone. Zones never adopt cells
## already owned by another zone; covered cells are skipped at apply.
func _zone_target(
	zones: Dictionary, cells: Array[Vector3i], anchor: Vector3i, override: bool
) -> Dictionary:
	if override:
		# Alt: a fresh zone — fails only when the box is entirely covered.
		return {&"ok": _has_free_cell(zones, cells), &"zone": null}
	if zones.has(anchor):
		return {&"ok": true, &"zone": zones[anchor]}
	var touching := _zones_touching(zones, anchor)
	if touching.size() > 1:
		return {&"ok": false}
	if touching.size() == 1:
		return {&"ok": true, &"zone": touching[0]}
	var overlapped := _zones_under(zones, cells)
	if overlapped.size() > 1:
		return {&"ok": false}
	if overlapped.size() == 1:
		return {&"ok": true, &"zone": overlapped[0]}
	return {&"ok": _has_free_cell(zones, cells), &"zone": null}


## The distinct zones the orthogonal neighbours of [param voxel] sit in.
func _zones_touching(zones: Dictionary, voxel: Vector3i) -> Array:
	var found: Array = []
	for dir in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		var zone: RefCounted = zones.get(voxel + dir)
		if zone != null and not found.has(zone):
			found.append(zone)
	return found


## The distinct zones that already cover cells of [param cells].
func _zones_under(zones: Dictionary, cells: Array[Vector3i]) -> Array:
	var found: Array = []
	for cell in cells:
		var zone: RefCounted = zones.get(cell)
		if zone != null and not found.has(zone):
			found.append(zone)
	return found


func _has_free_cell(zones: Dictionary, cells: Array[Vector3i]) -> bool:
	for cell in cells:
		if not zones.has(cell):
			return true
	return false


## The zone's admission filter: whether [param material] may be stored
## anywhere on the zone at [param voxel_position].
func stockpile_admits(voxel_position: Vector3i, material: BlockRegistry.Resource_) -> bool:
	var zone := stockpile_at(voxel_position)
	return zone != null and not zone.rejected.get(int(material), false)


## Whether the covering zone takes [param item] — the material filter
## plus the goods-class rules: a crate only lands in a warehouse, and
## nothing oversized sits on a floor pile that can't take its bulk.
func stockpile_admits_item(voxel_position: Vector3i, item: DropItem) -> bool:
	var zone := stockpile_at(voxel_position)
	if zone == null:
		return false
	if not item.stored.is_empty():
		# A container's contents decide: it lands only where every item
		# inside is admitted — the shell is just packaging. The check
		# recurses so a box of bags (if bags could nest) would gate on
		# the innermost goods.
		for inner in item.stored:
			if not stockpile_admits_item(voxel_position, inner):
				return false
		if item.is_container():
			# A small container lands where its freight does — a sack
			# of stone is stone-pile goods, not warehouse goods.
			return true
		# A freight crate — goods sealed in a minified shelf — is still
		# bulk storage; the warehouse's racking takes it.
		return zone.warehouse if item.form == DropItem.Form.CRATE else true
	if item.form == DropItem.Form.CRATE:
		# Furniture crates and empty bags alike are warehouse goods.
		return zone.warehouse
	return stockpile_admits(voxel_position, item.material)


## Sets the zone's admission for [param material] — every cell in the
## zone shares the one filter. Rejected materials that are already piled
## on the tile become haul-out candidates, so the filter cleans up
## existing contents instead of only gating new deposits.
func set_stockpile_admission(
	voxel_position: Vector3i, material: BlockRegistry.Resource_, admitted: bool
) -> void:
	var zone := stockpile_at(voxel_position)
	if zone == null:
		return
	if admitted:
		zone.rejected.erase(int(material))
	else:
		zone.rejected[int(material)] = true


## Whether anything piled on the voxel offends its own tile's filter —
## those piles want hauling elsewhere.
func _pile_rejected_here(voxel_position: Vector3i) -> bool:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return false
	for item in pile.items:
		# A forbidden item stays whatever the filter says — only an
		# allowed item the zone refuses wants hauling away.
		if item.forbidden:
			continue
		if not stockpile_admits_item(voxel_position, item):
			return true
	return false


## Marks a voxel as a farm-field cell — the growing zone. Single-cell
## gestures go through the same zone resolution as a drag, with the
## voxel as its own anchor.
func designate_farm(voxel_position: Vector3i) -> bool:
	var cells: Array[Vector3i] = [voxel_position]
	return designate_farm_cells(cells, voxel_position) != null


## Designates the still-free, farmable cells of [param cells] into the
## single field [_zone_target] resolves — same gesture rules as
## stockpiles. Returns the field cells joined, or null on failure.
func designate_farm_cells(
	cells: Array[Vector3i], anchor: Vector3i, override: bool = false
) -> FarmField:
	var resolution := _zone_target(farms, cells, anchor, override)
	if not resolution[&"ok"]:
		return null
	var field: FarmField = resolution[&"zone"]
	if field == null:
		field = FarmField.new()
	var placed := false
	for cell in cells:
		if not _farm_cellable(cell):
			continue
		field.cells[cell] = true
		farms[cell] = field
		_add_marker(cell, _farm_marker_material, _outline_mesh)
		_grow_home_around(cell)
		placed = true
	if placed:
		DLog.log("designated farm cells %s" % cells)
	return field if placed else null


## Whether a cell can take a farm designation — empty, unclaimed and
## over solid ground; whether it can grow the assigned crop is the sow
## gate's question, not the zone's.
func _farm_cellable(voxel_position: Vector3i) -> bool:
	return (
		not cell_claimed(
			voxel_position,
			Occ.DESIGNATION | Occ.BUILDING | Occ.TREE | Occ.BUSH | Occ.PILE
		)
		and not farms.has(voxel_position)
		and world.get_block(voxel_position) == BlockRegistry.Block.AIR
		and world.is_solid(voxel_position + Vector3i.DOWN)
		and world.water_level_at(voxel_position.x, voxel_position.z) < voxel_position.y
	)


## Removes the voxel from its farm field; the field record lives on in
## the remaining cells. A pending farm-generated job at the cell dies
## with the designation.
func undesignate_farm(voxel_position: Vector3i) -> bool:
	var field := farm_at(voxel_position)
	if field == null:
		return false
	field.cells.erase(voxel_position)
	farms.erase(voxel_position)
	var job: ColonyJob = _farm_jobs.get(voxel_position)
	if job != null:
		if job.is_active():
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
		_farm_jobs.erase(voxel_position)
		_prune_jobs()
	_remove_marker(voxel_position)
	return true


## The field covering [param voxel_position], or null.
func farm_at(voxel_position: Vector3i) -> FarmField:
	return farms.get(voxel_position)


## Assigns the crop the field under [param voxel_position] grows — a
## Plants or Forest species key, or empty to idle the zone.
func set_farm_crop(voxel_position: Vector3i, species: StringName) -> void:
	var field := farm_at(voxel_position)
	if field == null:
		return
	if species != &"" and not farmable_species_ids().has(species):
		return
	field.species = species


## Tree fields only have a use for this: fell each tree the moment it
## matures. Off leaves them standing — and fruiting.
func set_farm_auto_chop(voxel_position: Vector3i, on: bool) -> void:
	var field := farm_at(voxel_position)
	if field != null:
		field.auto_chop = on


## The field's auto-fertilizer switch — on means the farm scan keeps
## every cell's soil at or above its target fertility by posting
## FERTILIZE jobs for whatever falls short.
func set_farm_auto_fertilize(voxel_position: Vector3i, on: bool) -> void:
	var field := farm_at(voxel_position)
	if field != null:
		field.auto_fertilize = on


## The effective fertility the auto-fertilizer pushes each field cell
## toward — clamped to a sane band so the slider can't order the
## impossible.
func set_farm_fertilize_target(voxel_position: Vector3i, target: float) -> void:
	var field := farm_at(voxel_position)
	if field != null:
		field.fertilize_target = clampf(target, 0.0, 5.0)


## Paints a one-time fertilize mark on [param voxel_position]: the
## colony keeps posting FERTILIZE jobs there until the soil reaches
## [constant FERTILIZE_PAINT_TARGET]. Only open air over fertilizable
## ground takes a mark — a pile, a building or a plant in the cell
## doesn't disqualify it, but stone floor does.
func designate_fertilize(voxel_position: Vector3i) -> bool:
	if fertilize_marks.has(voxel_position):
		return false
	if not _fertilizable_soil(voxel_position):
		return false
	fertilize_marks[voxel_position] = FERTILIZE_PAINT_TARGET
	_add_fertilize_marker(voxel_position)
	DLog.log("designated fertilize %s" % voxel_position)
	return true


## Whether the cell can take a fertilize mark or job: open, editable air
## over a block that stores fertility.
func _fertilizable_soil(voxel_position: Vector3i) -> bool:
	return (
		world.is_editable(voxel_position)
		and world.get_block(voxel_position) == BlockRegistry.Block.AIR
		and BlockRegistry.fertilizability(
			world.get_block(voxel_position + Vector3i.DOWN)
		) > 0.0
	)


## Lifts the mark at [param voxel_position] — its pending job cancels
## with it, since reposting is the whole point of the mark.
func _clear_fertilize_mark(voxel_position: Vector3i) -> void:
	if not fertilize_marks.erase(voxel_position):
		return
	_remove_fertilize_marker(voxel_position)
	var job: ColonyJob = _fertilize_jobs.get(voxel_position)
	if job != null and job.is_active():
		job.state = ColonyJob.State.CANCELLED
		if job.assignee != null and job.assignee.has_method(&"abandon_job"):
			job.assignee.abandon_job()
		_prune_jobs()


## The mark's own overlay marker — kept out of `_designation_markers`
## so a mark coexists with the farm outline over the same cell.
func _add_fertilize_marker(voxel_position: Vector3i) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = _outline_mesh
	marker.material_override = _fertilize_marker_material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	marker.visible = markers_visible
	add_child(marker)
	_fertilize_markers[voxel_position] = marker


func _remove_fertilize_marker(voxel_position: Vector3i) -> void:
	var marker: MeshInstance3D = _fertilize_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_fertilize_markers.erase(voxel_position)


## A fertilize job's finish: the carried compost volume sinks into the
## soil under the cell at the standard conversion — the same rate the
## natural rot pays. A painted mark whose soil just reached target
## clears itself; a field cell's auto scan handles its own reposts.
func complete_fertilize(job: ColonyJob, compost_cm3: int) -> void:
	var soil := job.voxel_position + Vector3i.DOWN
	if compost_cm3 > 0:
		fertilize(soil, compost_cm3 * FERTILIZE_PER_CM3)
	# Finish first: clearing the mark below cancels the cell's tracked
	# job — which must no longer be live when it happens.
	_finish_job(job)
	var mark: Variant = fertilize_marks.get(job.voxel_position)
	if mark != null and effective_fertility(soil) >= float(mark):
		_clear_fertilize_mark(job.voxel_position)


## The voxel of the nearest pile holding loose compost — the fertilize
## job's fetch query. Only the loose form spreads on soil.
func nearest_compost_voxel(
	from: Vector3i, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			if _is_loose_compost(item):
				return _Match.FRESH
			if item.is_container():
				# A sack of compost advertises its fill — the fetch
				# carries it whole and pours at the field.
				for inner in item.stored:
					if _is_loose_compost(inner):
						return _Match.FRESH
		return _Match.VETO, area)


## True when [param item] is loose compost — the fertilize queries'
## per-item test, shared by the loose scan and the look inside sacks.
func _is_loose_compost(item: DropItem) -> bool:
	return (
		item.material == BlockRegistry.Resource_.COMPOST
		and item.form == DropItem.Form.LOOSE
	)


## True when any pile in the colony holds usable loose compost — the
## fertilize scan's posting gate, so cells don't churn through
## give-ups while the larder is empty.
func _compost_exists() -> bool:
	for voxel: Vector3i in item_piles:
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			if _is_loose_compost(item):
				return true
			if item.is_container():
				for inner in item.stored:
					if _is_loose_compost(inner):
						return true
	return false


## The picker's species list: every shrub and tree species, tagged for
## the farm panel. Returns {id, name, tree} per entry.
func farmable_species() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: StringName in Plants.species_table():
		out.append({
			&"id": id, &"name": Plants.species_table()[id][&"name"], &"tree": false,
		})
	for id: StringName in Forest.species_table():
		out.append({
			&"id": id, &"name": Forest.species_table()[id][&"name"], &"tree": true,
		})
	return out


## The bare species-key set — the crop setter's validation.
func farmable_species_ids() -> Array:
	var ids := Plants.species_table().keys()
	ids.append_array(Forest.species_table().keys())
	return ids


## Places a crafting spot — a worksite, the simplest building: no
## materials, nothing to construct, just a designated place a craft job
## can be ordered at. The voxel must be empty, unclaimed by a tree and
## rest on a solid block.
func designate_craft_spot(voxel_position: Vector3i) -> bool:
	if cell_claimed(voxel_position, Occ.DESIGNATION):
		return false
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return false
	if cell_claimed(voxel_position, Occ.PILE):
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	if cell_claimed(voxel_position, Occ.TREE):
		# A growing tree would raise its trunk into the spot.
		return false
	var building := Building.new(Building.Kind.WORKSITE, voxel_position)
	register_building(building)
	_add_marker(voxel_position, _craft_spot_marker_material, _outline_mesh)
	DLog.log("designated crafting spot %s" % voxel_position)
	return true


## The building record at [param voxel_position], or null — the lookup the
## deconstruct tool and the inspect panel share.
func building_at(voxel_position: Vector3i) -> Building:
	return buildings.get(voxel_position)


## The four lateral edges a floodgate cell regulates — the sluice rides
## its cell: closed dams every side, part-open throttles them evenly.
const FLOODGATE_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


## Pushes a gate's open fraction to the water sim — [param fraction] 1.0
## clears the edge records back to unregulated flow.
func _apply_floodgate_edges(cell: Vector3i, fraction: float) -> void:
	for dir in FLOODGATE_DIRS:
		world.sim.water_set_edge_scale(cell, dir, fraction)


## Sets the floodgate's open fraction at [param voxel_position] — the
## inspect panel's seam. The fraction rides the building record through
## the save; registration replays it onto the sim on load.
func set_floodgate_open(voxel_position: Vector3i, fraction: float) -> void:
	var building: Building = buildings.get(voxel_position)
	if building == null or building.kind != Building.Kind.FLOODGATE:
		return
	building.open_fraction = clampf(fraction, 0.0, 1.0)
	if world.sim != null:
		for cell in building.footprint:
			_apply_floodgate_edges(cell, building.open_fraction)


func register_building(building: Building, grow_home := true) -> void:
	if building.max_hp <= 0.0:
		# Computed once from what the thing is made of — a record with
		# hp set (a damaged building on load) keeps its numbers.
		building.max_hp = building.compute_max_hp()
		if building.hp <= 0.0:
			building.hp = building.max_hp
	_derive_beauty(building)
	for cell in building.footprint:
		buildings[cell] = building
		if grass != null:
			# Anything built on a grassed block buries its cover.
			grass.bare(cell + Vector3i.DOWN)
		if building.kind == Building.Kind.LADDER and world.sim != null:
			# Mirror the climb edge into the native sim — ladders are
			# walkability, not occupancy, so there's nothing to render
			# in the voxel itself.
			world.sim.set_ladder(cell, true)
		if building.kind == Building.Kind.FLOODGATE and world.sim != null:
			# The sluice's edge throttles — replays through this same
			# register call on load, the way a ladder's climb edge does.
			_apply_floodgate_edges(cell, building.open_fraction)
	if building.kind == Building.Kind.DOOR:
		if world.sim != null:
			# Same mirror for the open-pause — only the sill cell pays the
			# swing time; the headroom cell above is just air.
			world.sim.set_door(building.voxel, true)
		# A door seals the room it hangs in — topology changed.
		if rooms != null:
			rooms.invalidate()
	elif building.kind == Building.Kind.FENCE:
		# The animal-blocked rail mirrors into the sim like the door's
		# cost — unit paths pay the hop, animal paths refuse the cell.
		# Replays through this same register call on load.
		if world.sim != null:
			for cell in building.footprint:
				world.sim.set_fence(cell, true)
	elif building.kind == Building.Kind.SPIKE_TRAP:
		# The trap mirrors into the sim like the fence: unit paths pay
		# the know-better detour, animal routes (ignore_traps) see open
		# ground — the trap's prey walks itself onto the points.
		if world.sim != null:
			for cell in building.footprint:
				world.sim.set_trap(cell, true)
	elif building.kind == Building.Kind.COOLER:
		# The machine body seals its cell for room purposes too —
		# that's what makes a wall-gap cooler hold two climates.
		if rooms != null:
			rooms.invalidate()
	elif rooms != null and building.beauty != 0.0:
		rooms.invalidate_beauty()
	if building.kind == Building.Kind.SHELF:
		# A shelf *is* a stockpile — one shared zone across its cells so
		# the admission filter machinery, the deliver query and the HUD
		# panel all just work. Save-load registers the shelf before the
		# stockpile list restores, and that pass rebinds the cell to the
		# zone carrying the saved filter.
		var zone := StockpileZone.new()
		for cell in building.footprint:
			if not stockpiles.has(cell):
				zone.cells[cell] = true
				stockpiles[cell] = zone
				_index_add(_stockpile_buckets, cell)
	if building.kind == Building.Kind.LAMP:
		_lamps[building.voxel] = building
	if building.kind == Building.Kind.COMPOST_BIN:
		# A compost bin *is* a stockpile too, but one whose preset filter
		# admits only what rots to compost — stray corpses, leaves and
		# offcuts haul themselves in on the idle sweep; the finished
		# compost (not in the filter) hauls back out to a general zone.
		var bin_zone := StockpileZone.new()
		# High priority: a general zone admits leaves and corpses too,
		# but the bin is where they belong — it should win the delivery.
		bin_zone.priority = StockpileZone.Priority.HIGH
		var admitted := DropItem.compostable_materials()
		for material in BlockRegistry.Resource_.values():
			if not admitted.has(int(material)):
				bin_zone.rejected[int(material)] = true
		for cell in building.footprint:
			if not stockpiles.has(cell):
				bin_zone.cells[cell] = true
				stockpiles[cell] = bin_zone
				_index_add(_stockpile_buckets, cell)
	if grow_home:
		# A finished structure pulls its neighbourhood into the home
		# area — walls, furniture and worksites alike. Save-load passes
		# grow_home=false: the painted set is authoritative, and a cell
		# the player erased around a building stays erased.
		for cell in building.footprint:
			_grow_home_around(cell)


## What the construction is worth looking at: doors a token, recreation
## furniture from its spec, a bed scaled by the maker's roll — the same
## quality its comfort effect reads.
func _derive_beauty(building: Building) -> void:
	match building.kind:
		Building.Kind.DOOR:
			building.beauty = 0.04
		Building.Kind.RECREATION:
			building.beauty = (
				BlockRegistry.rec_beauty(building.spec) * building.quality
			)
		Building.Kind.BED:
			# A spec'd bed carries the spec's beauty scaled by the
			# maker's roll; an old unpec'd bed keeps the flat figure.
			building.beauty = (
				float(
					BlockRegistry.furniture_spec(building.spec).get(
						&"beauty", 0.08
					)
				)
				* building.quality
			)
		Building.Kind.TABLE, Building.Kind.SEAT, Building.Kind.LAMP, \
		Building.Kind.DECOR:
			building.beauty = (
				float(
					BlockRegistry.furniture_spec(building.spec).get(
						&"beauty", 0.0
					)
				)
				* building.quality
			)


func is_craft_spot(voxel_position: Vector3i) -> bool:
	var building := building_at(voxel_position)
	return building != null and building.kind == Building.Kind.WORKSITE


## The door at [param voxel_position], or null — the unit's approach
## pause and the pathing surcharge both read it.
func door_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.kind == Building.Kind.DOOR:
		return building
	return null


## Queues a deconstruction job on the building at [param voxel_position]:
## a unit takes it apart and it drops exactly the items it was built of.
## Packed-dirt walls aren't buildings from the tool's point of view —
## tamped soil reads as natural ground and has to be mined out.
func designate_deconstruct(voxel_position: Vector3i) -> ColonyJob:
	var building := building_at(voxel_position)
	if building == null:
		# Timberborn: the deconstruct tool also cancels a planned build —
		# there's nothing standing there to take apart.
		if plan_job_at(voxel_position) != null:
			cancel_designation(voxel_position)
		return null
	if not building.deconstructable:
		return null
	# Multi-cell buildings anchor their job at the record's own voxel so
	# either cell designates (and finds) the same teardown.
	var anchor := building.voxel
	if deconstruct_job_at(anchor) != null:
		return null
	if building.kind == Building.Kind.WALL and _designation_markers.has(anchor):
		# Walls share the marker map with designations — a marker there
		# means another job (e.g. a mine) already owns the cell.
		return null
	var job := ColonyJob.new(ColonyJob.Type.DECONSTRUCT, anchor)
	for cell in building.footprint:
		if cell != anchor:
			job.extra_voxels.append(cell)
	_register_job(job)
	if building.kind == Building.Kind.WALL:
		_add_marker(anchor, _deconstruct_marker_material, null, true)
	else:
		for cell in building.footprint:
			_set_marker_appearance(cell, _deconstruct_marker_material, _marker_mesh)
	DLog.log("designated deconstruct %s" % anchor)
	job_added.emit(job)
	return job


## The active build job at [param voxel_position], or null — pending walls
## are aimable plan cells, so the designator tools query this per voxel
## the cursor's ray crosses.
func build_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BUILD
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## The active construction job claiming [param voxel_position] — a pending
## wall or furnish plan at its anchor *or* any of its extra cells. This is
## the lookup the aim ray and the deconstruct-as-cancel tool share.
func plan_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			(
				job.type == ColonyJob.Type.BUILD
				or job.type == ColonyJob.Type.FURNISH
				or (
					job.type == ColonyJob.Type.CRAFT
					and recipe_of(job.recipe).has("builds")
				)
			)
			and job.is_active()
			and (
				job.voxel_position == voxel_position
				or job.extra_voxels.has(voxel_position)
			)
		):
			return job
	return null


## The active deconstruction job at [param voxel_position], or null —
## matches any cell of a multi-cell building's footprint.
func deconstruct_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.DECONSTRUCT
			and job.is_active()
			and (
				job.voxel_position == voxel_position
				or job.extra_voxels.has(voxel_position)
			)
		):
			return job
	return null


## Deconstruction done: the block comes out, the construction's exact
## input items drop where it stood, and its record dies. Any task the
## worksite was running dies with it.
func complete_deconstruct(job: ColonyJob) -> void:
	_teardown_building(job.voxel_position, job)
	_finish_job(job)


## Shared end of losing a construction — deconstructed on purpose or
## battered to pieces in a fight. Whatever work ran at the cell dies
## with it (escrow back out), the occupant is turned out, the block
## comes down through the collapse machinery if it was terrain, and the
## exact input items drop where it stood — the "does a wreck drop
## broken goods?" question stays open for rebalancing, so today a
## wreck pays back what a teardown pays.
func _teardown_building(
	voxel_position: Vector3i,
	except_job: ColonyJob = null,
	suppress_drops := false,
	wrecked := false
) -> void:
	var building: Building = buildings.get(voxel_position)
	if building == null:
		return
	for j in jobs:
		if j != except_job and j.voxel_position == voxel_position and j.is_active():
			_return_escrow(j)
			j.state = ColonyJob.State.CANCELLED
			if j.assignee != null and j.assignee.has_method(&"abandon_job"):
				j.assignee.abandon_job()
			if j.face_dir != Vector3i.ZERO:
				_remove_face_marker(
					j.voxel_position, Flooring.face_index(j.face_dir)
				)
	if building.occupant != null and is_instance_valid(building.occupant):
		# The sleeper's bed just went away — it wakes and finds the
		# ground like anyone whose rest was cut short.
		building.occupant.abandon_job()
	for sleeper in building.occupants:
		if sleeper != building.occupant and is_instance_valid(sleeper):
			sleeper.abandon_job()
	if (
		building.block_id != BlockRegistry.Block.AIR
		and world.get_block(building.voxel) == building.block_id
	):
		world.remove_voxel(building.voxel)
		# Whatever rested on the block lost its floor.
		_settle_pile_at(building.voxel + Vector3i.UP)
	if not suppress_drops:
		# An uninstall already moved these into the crate — dropping
		# them again would mint a second set.
		for item in building.components:
			if wrecked:
				# A wreck pays salvage, not kit: about a third of what
				# held the building up is destroyed outright, loose
				# goods lose a third of their volume, and what survives
				# reads battered — wear and the build's fine craft both
				# take the hit.
				if randf() < WRECK_LOSS_CHANCE:
					continue
				if item.form == DropItem.Form.LOOSE:
					item.volume = maxi(1, item.volume * 2 / 3)
				item.wear = minf(item.wear, 0.5)
				item.quality = minf(item.quality, 1.0)
			_drop_item(item, voxel_position)
	if building.kind == Building.Kind.LAMP:
		_lamps.erase(building.voxel)
	for cell in building.footprint:
		buildings.erase(cell)
		_remove_marker(cell)
		if (
			building.kind == Building.Kind.SHELF
			or building.kind == Building.Kind.COMPOST_BIN
		):
			# The storage building's stockpile zone dies with it —
			# whatever it held stays where it stood, now a floor pile;
			# over-full by the floor's smaller cap, it spills.
			var zone := stockpile_at(cell)
			if zone != null:
				zone.cells.erase(cell)
			stockpiles.erase(cell)
			_index_remove(_stockpile_buckets, cell)
			_enforce_capacity(cell)
		if world.sim != null:
			if building.kind == Building.Kind.LADDER:
				world.sim.set_ladder(cell, false)
			elif building.kind == Building.Kind.DOOR:
				world.sim.set_door(cell, false)
			elif building.kind == Building.Kind.FENCE:
				world.sim.set_fence(cell, false)
			elif building.kind == Building.Kind.SPIKE_TRAP:
				world.sim.set_trap(cell, false)
			elif building.kind == Building.Kind.FLOODGATE:
				# Teardown returns the edges to unregulated flow.
				_apply_floodgate_edges(cell, 1.0)
			elif building.kind == Building.Kind.PUMP:
				world.sim.water_set_pump(
					cell + building.face_dir, cell - building.face_dir, 0
				)
	if rooms != null:
		# A sealing building going away opens the rooms it divided —
		# a door leaf or a wall-gap cooler alike; any pretty object
		# going away stales the score of the room it stood in.
		if (
			building.kind == Building.Kind.DOOR
			or building.kind == Building.Kind.COOLER
		):
			rooms.invalidate()
		elif building.beauty != 0.0:
			rooms.invalidate_beauty()


## Combat damage on a construction: the record bleeds hit points, a
## repair bill posts itself the first time it's hurt, and at zero the
## thing comes down — same teardown a deconstruct runs.
func damage_building(building: Building, amount: float) -> void:
	if building == null or amount <= 0.0:
		return
	# A record mid-teardown reads stale in its footprint — the colony
	# map is the liveness truth, not the object.
	if buildings.get(building.voxel) != building:
		return
	building.hp = maxf(building.hp - amount, 0.0)
	if building.hp <= 0.0:
		DLog.log("building wrecked at %s" % building.voxel)
		_teardown_building(building.voxel, null, false, true)
	elif repair_job_at(building.voxel) == null:
		_post_repair(building.voxel)


## Combat damage on a cell: a construction standing there takes it,
## otherwise a solid block remembers the battering until it breaks
## "as if mined" — collapse cascades come free with the removal.
func damage_cell(cell: Vector3i, amount: float) -> void:
	if amount <= 0.0:
		return
	var building := building_at(cell)
	if building != null:
		damage_building(building, amount)
		return
	var pile := item_pile_at(cell)
	if pile != null and pile.is_dense():
		# A dense heap soaks the blow like a low wall — flimsy cover with
		# no hit points of its own, just goods chewed up where they lie.
		_erode_pile(pile, amount)
		return
	var block_id := world.get_block(cell)
	if not BlockRegistry.is_solid(block_id):
		# Whatever stood here is gone — the battering went with it.
		_block_damage.erase(cell)
		return
	var cap := BlockRegistry.hardness(block_id) * Building.HP_PER_HARDNESS
	var damage := float(_block_damage.get(cell, 0.0)) + amount
	if damage >= cap:
		_block_damage.erase(cell)
		_wreck_block(cell)
	else:
		_block_damage[cell] = damage


## A solid block beaten to zero breaks as if mined: the block comes
## out (support checks and collapse cascades included), its rubble
## drops where it stood, and any plan on the cell dies with it.
func _wreck_block(cell: Vector3i) -> void:
	DLog.log("block wrecked at %s" % cell)
	cancel_designation(cell)
	var block_id := world.mine(cell)
	if block_id == BlockRegistry.Block.AIR:
		return
	drop_block(block_id, cell)
	_settle_pile_at(cell + Vector3i.UP)


## Beats on a dense heap until `amount`'s worth of goods is chewed up —
## loose fill shaves off by the volume, discrete goods come out whole
## (a boulder shrugs the chip off; what's left of a bite under the
## smallest item is lost).
func _erode_pile(pile: ItemPile, amount: float) -> void:
	var bite := int(amount * SPLASH_ERODE_CM3_PER_HP)
	while bite > 0 and not pile.items.is_empty():
		var smallest := pile.smallest_item()
		if smallest.form == DropItem.Form.LOOSE:
			var part := mini(bite, smallest.volume)
			smallest.volume -= part
			if smallest.volume <= 0:
				pile.take_smallest()
			else:
				pile.fill_changed.emit(pile)
				pile._rebuild_mesh()
			bite -= part
		elif smallest.volume <= bite:
			pile.take_smallest()
			bite -= smallest.volume
		else:
			break
	remove_pile_if_empty(pile.voxel_position)


## Stray force around a melee hit. Whatever stands between the
## combatants — a barricade, a wall face, the earth itself — soaks half
## the blow (this is how cover erodes mid-fight), and now and then a
## swing goes wide onto a neighbouring structure or block. The caller's
## `damage` is already the per-tick share.
func combat_splash(victim_pos: Vector3, attacker_pos: Vector3, damage: float) -> void:
	if damage <= 0.0:
		return
	var cell := Vector3i(victim_pos.floor())
	var facing := cell + (Vector3i(attacker_pos.floor()) - cell).sign()
	if facing != cell:
		damage_cell(facing, damage * SPLASH_SHARE)
	if randf() < SPLASH_STRAY_CHANCE:
		var cells: Array[Vector3i] = []
		for side: Vector3i in [
			Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD,
			Vector3i.BACK, Vector3i.UP, Vector3i.DOWN,
		]:
			var c: Vector3i = cell + side
			if c != facing and (
				buildings.has(c) or world.is_solid(c) or is_dense_pile(c)
			):
				cells.append(c)
		if not cells.is_empty():
			damage_cell(
				cells[randi() % cells.size()], damage * SPLASH_STRAY_SHARE
			)


## Line of fire between two points (item 61): a voxel DDA from eye to
## target chest. Solids block, and so does a cover building — that's
## the barricade's whole job. The shooter's own cell is skipped: a unit
## behind its own mound still gets to shoot back.
func line_of_fire(from_pos: Vector3, to_pos: Vector3) -> bool:
	# Origins ride ~0.9 above the foot cell — eye a shoulder's height
	# over that, chest a bit lower.
	var eye := from_pos + Vector3(0, 0.7, 0)
	var chest := to_pos + Vector3(0, 0.3, 0)
	var to := chest - eye
	var dist := to.length()
	if dist < 0.01:
		return true
	var dir := to / dist
	var cell := Vector3i(eye.floor())
	var end := Vector3i(chest.floor())
	if cell == end:
		return true
	var step := Vector3i(dir.sign())
	var t_max := Vector3.ZERO
	var t_delta := Vector3.ZERO
	for axis in 3:
		var d := dir[axis]
		if absf(d) < 0.0001:
			t_max[axis] = INF
			t_delta[axis] = INF
		else:
			var boundary := float(
				cell[axis] + (1 if d > 0.0 else 0)
			)
			t_max[axis] = (boundary - eye[axis]) / d
			t_delta[axis] = absf(1.0 / d)
	var guard := 0
	while cell != end and guard < 64:
		guard += 1
		var t := 0.0
		if t_max.x <= t_max.y and t_max.x <= t_max.z:
			t = t_max.x
			cell.x += step.x
			t_max.x += t_delta.x
		elif t_max.y <= t_max.z:
			t = t_max.y
			cell.y += step.y
			t_max.y += t_delta.y
		else:
			t = t_max.z
			cell.z += step.z
			t_max.z += t_delta.z
		if t > dist or cell == end:
			# Overshot — or arrived: the target's own cell doesn't
			# count its cover (a unit on the mound is exposed, not
			# behind it).
			break
		if world.is_solid(cell):
			return false
		# Cover is partial-height — it counts from the ray's cell and
		# the cell beneath: a shot riding a cell above a mound is
		# still a shot denied.
		if (
			cover_at(cell) != null
			or cover_at(cell - Vector3i.UP) != null
		):
			return false
	return true


## Something stepped onto the trap cell — the stakes spring once:
## the occupant eats the wound and the trap's spent. Downed bodies
## dragged across don't spring it (the rescuer isn't what it wants);
## the dead are past caring.
func try_trap(cell: Vector3i, entity: Node) -> void:
	var building := building_at(cell)
	if building == null or building.kind != Building.Kind.SPIKE_TRAP:
		return
	if entity is Unit and (entity.dead or entity.is_downed()):
		return
	if entity is Animal and entity.dead:
		return
	DLog.log("spike trap sprung at %s" % cell)
	# The stakes splinter under the body — nothing to salvage, so the
	# components don't drop back as a free re-set.
	_teardown_building(cell, null, true)
	if entity is Unit:
		entity.take_hit(SPIKE_TRAP_DAMAGE, null, &"stab")
	elif entity is Animal:
		entity.take_hit(SPIKE_TRAP_DAMAGE, null, &"stab")


## Wound severity a sprung trap deals — a leg-full of sharpened
## stakes. Crippling, not instantly lethal.
const SPIKE_TRAP_DAMAGE := 22.0
## Walk cost a settler prices a trap cell at — they know where their
## own stakes are, so paths steer around them. Animals don't get the
## discount: the rail and the pit are how the camp feeds itself.
const TRAP_AVOID := 40.0


## ---------------------------------------------------------------------------
## Fire (PLAN item 33) — wildfires burning cells, spreading to burnable
## neighbours, doused by precipitation and beaten out by units.
## ---------------------------------------------------------------------------

## Try to set [param cell] alight — returns false when nothing there
## burns or the ground is too soaked to catch. Ignition seeds the fuel
## budget from what's present and posts the firefighting bill.
func ignite(cell: Vector3i) -> bool:
	if _fires.has(cell):
		return false
	var flam := _cell_flammability(cell)
	if flam <= 0.0:
		return false
	# Wet ground resists — a strike into soaked terrain fizzles, and
	# fully saturated ground can't catch at all.
	if weather.saturation >= 0.95 or randf() < weather.saturation * 0.9:
		return false
	_fires[cell] = {&"fuel": _cell_fuel(cell), &"flam": flam}
	_add_fire_marker(cell)
	_post_firefight(cell)
	return true


## Whether [param cell] is burning right now.
func is_burning(cell: Vector3i) -> bool:
	return _fires.has(cell)


## How readily what's in [param cell] catches — the highest rating
## among its layers (building, tree part, block, vegetation, pile).
func _cell_flammability(cell: Vector3i) -> float:
	var best := 0.0
	var building: Building = buildings.get(cell)
	if building != null:
		best = maxf(
			best, BlockRegistry.material_flammability(building.material)
		)
		if (
			building.kind == Building.Kind.HEATER
			or building.kind == Building.Kind.COOLER
		):
			# A powered machine's windings and contacts smolder even in
			# a sheet-metal housing — the housing only changes the odds
			# a fault sparks one.
			best = maxf(best, 0.4)
	var root := forest.tree_root_at(cell)
	if root != Vector3i.MAX or forest.leaf_at(cell):
		best = maxf(best, BlockRegistry.material_flammability(BlockRegistry.Resource_.WOOD))
	elif BlockRegistry.flammability(world.get_block(cell)) > 0.0:
		best = maxf(best, BlockRegistry.flammability(world.get_block(cell)))
	if plants.bush_at(cell) != Vector3i.MAX:
		best = maxf(best, 0.9)
	if grass.grassed(cell):
		best = maxf(best, 1.2)
	var pile := item_pile_at(cell)
	if pile != null:
		for item in pile.items:
			best = maxf(
				best,
				BlockRegistry.material_flammability(item.material)
			)
	# A paved floor fights the spread: stone paving under the load
	# cancels a share of what would carry the flame into the cell,
	# plank paving none at all.
	best *= 1.0 - BlockRegistry.floor_fire_resist(
		flooring.covering_at(cell, Flooring.face_index(Vector3i.DOWN))
	)
	return best


## Burn seconds the contents of [param cell] provide — each layer
## contributes, so a bushy grass cell outburns a bare one.
func _cell_fuel(cell: Vector3i) -> float:
	var fuel := 0.0
	var building: Building = buildings.get(cell)
	if (
		building != null
		and (
			BlockRegistry.material_flammability(building.material) > 0.0
			or building.kind == Building.Kind.HEATER
			or building.kind == Building.Kind.COOLER
		)
	):
		fuel += FIRE_FUEL_BUILDING
	var root := forest.tree_root_at(cell)
	if root != Vector3i.MAX or forest.leaf_at(cell):
		fuel += FIRE_FUEL_TREE
	elif BlockRegistry.flammability(world.get_block(cell)) > 0.0:
		fuel += FIRE_FUEL_BLOCK
	if plants.bush_at(cell) != Vector3i.MAX:
		fuel += FIRE_FUEL_BUSH
	if grass.grassed(cell):
		fuel += FIRE_FUEL_GRASS
	var pile := item_pile_at(cell)
	if pile != null:
		for item in pile.items:
			if BlockRegistry.material_flammability(item.material) > 0.0:
				fuel += FIRE_FUEL_PILE
				break
	return fuel


## A lightning bolt reaches for the site: a random column around a
## colony anchor (buildings and units count — the bolt finds the
## colony, not empty map), struck top-down until something flammable.
func lightning_strike() -> void:
	var anchors: Array[Vector3i] = []
	for building_cell: Vector3i in buildings:
		anchors.append(building_cell)
	for unit in units:
		anchors.append(Vector3i(unit.global_position.floor()))
	if anchors.is_empty():
		return
	var anchor: Vector3i = anchors[randi() % anchors.size()]
	var cx := anchor.x + randi_range(-LIGHTNING_RADIUS, LIGHTNING_RADIUS)
	var cz := anchor.z + randi_range(-LIGHTNING_RADIUS, LIGHTNING_RADIUS)
	# Scan down from above the column — the canopy, a roof or the grass
	# catches before the ground does.
	var top: int = world.predicted_surface_height(cx, cz) + 12
	for y in range(top, top - 16, -1):
		var cell := Vector3i(cx, y, cz)
		if _cell_flammability(cell) > 0.0:
			if ignite(cell):
				DLog.log("lightning ignited %s" % cell)
			return


## The fire heartbeat: fuel burns down (faster under precipitation),
## spread rolls run to each flammable neighbour, and empty cells burn
## out — consuming whatever they held.
func _fire_tick(elapsed: float) -> void:
	if _fires.is_empty():
		return
	var douse := FIRE_RAIN_DOUSE if weather.precipitating() else 1.0
	var dry_spread := 1.0 - weather.saturation * 0.8
	for cell: Vector3i in _fires.keys():
		var rec: Dictionary = _fires.get(cell, {})
		if rec.is_empty():
			continue
		# A burning building pays hp all along — if it wrecks mid-burn
		# the usual teardown handles its remains.
		var building: Building = buildings.get(cell)
		if (
			building != null
			and BlockRegistry.material_flammability(building.material) > 0.0
		):
			damage_building(building, FIRE_DPS * elapsed)
		# Plants in the burning cell bleed hit points all along — a fire
		# beaten out mid-burn leaves damaged or dead plants standing
		# instead of pristine ones.
		var bush := plants.bush_at(cell)
		if bush != Vector3i.MAX:
			plants.damage(bush, FIRE_PLANT_DPS * elapsed)
		var tree := forest.tree_root_at(cell)
		if tree != Vector3i.MAX:
			forest.damage(tree, FIRE_TREE_DPS * elapsed)
		rec[&"fuel"] = float(rec[&"fuel"]) - elapsed * douse
		var flam := float(rec[&"flam"])
		for side: Vector3i in [
			Vector3i.RIGHT, Vector3i.LEFT,
			Vector3i.FORWARD, Vector3i.BACK, Vector3i.UP
		]:
			var n: Vector3i = cell + side
			if _fires.has(n):
				continue
			var n_flam := _cell_flammability(n)
			if (
				n_flam > 0.0
				and randf()
					< flam * n_flam * FIRE_SPREAD_RATE * elapsed * dry_spread
			):
				ignite(n)
		_pulse_fire_marker(cell)
		if float(rec[&"fuel"]) <= 0.0:
			# A beater mid-stomp owns the kill — the heartbeat draining
			# the last fuel first is still a beaten fire, not a
			# burn-out. Only a cell nobody is fighting consumes goods.
			var beat: ColonyJob = _firefight_at.get(cell)
			var beater := (
				beat.assignee as Unit if beat != null else null
			)
			if (
				beater != null
				and beater.job == beat
				and beater.state == Unit.State.WORKING
			):
				_extinguish(cell)
			else:
				_burn_out_cell(cell)


## A firefighter's stomp — [param work] fuel-seconds of beating. The
## cell beaten dry is extinguished with its contents intact; returns
## false when the fire is out (or never was).
func beat_fire(cell: Vector3i, work: float) -> bool:
	var rec: Dictionary = _fires.get(cell, {})
	if rec.is_empty():
		return false
	rec[&"fuel"] = float(rec[&"fuel"]) - work
	if float(rec[&"fuel"]) <= 0.0:
		_extinguish(cell)
		return false
	return true


## The fuel ran out — the fire dies taking its contents with it:
## buildings were already paying hp, wood blocks burn away without
## drops, grass is stripped, bushes and tree parts are destroyed, and
## burnable pile goods are consumed.
func _burn_out_cell(cell: Vector3i) -> void:
	_fires.erase(cell)
	_remove_fire_marker(cell)
	# An unclaimed bill dies with the fire — an assigned beater sees
	# the cell out on its next tick and completes the job itself.
	var job: ColonyJob = _firefight_at.get(cell)
	if job != null and job.is_active() and job.assignee == null:
		job.state = ColonyJob.State.CANCELLED
	_firefight_at.erase(cell)
	var building: Building = buildings.get(cell)
	if (
		building != null
		and BlockRegistry.material_flammability(building.material) > 0.0
	):
		# The flames finish what the damage started.
		damage_building(building, building.hp + 1.0)
	var root := forest.tree_root_at(cell)
	if root != Vector3i.MAX:
		# A tree part burns in place — no drops; the rest of the tree
		# loses its support through the normal collapse check.
		forest._forget(root, cell)
		var rec: Dictionary = forest.trees.get(root, {})
		if not rec.is_empty() and (rec[&"voxels"] as Array).is_empty():
			# The last of it — the record goes with the wood.
			forest.trees.erase(root)
		if world.is_solid(cell):
			world.remove_voxel(cell)
			_settle_pile_at(cell + Vector3i.UP)
	elif BlockRegistry.flammability(world.get_block(cell)) > 0.0:
		# A burning wall block leaves nothing — it burned, not broke.
		_block_damage.erase(cell)
		cancel_designation(cell)
		world.mine(cell)
		_settle_pile_at(cell + Vector3i.UP)
	var bush := plants.bush_at(cell)
	if bush != Vector3i.MAX:
		# The plant burned to nothing — tombstone a generated slot so it
		# never regrows on a stream-in.
		plants._forget(bush)
		plants._destroyed[bush] = true
	if grass.grassed(cell):
		grass.bare(cell)
	var pile := item_pile_at(cell)
	if pile != null:
		var kept: Array[DropItem] = []
		for item in pile.items:
			if BlockRegistry.material_flammability(item.material) > 0.0:
				# Mostly consumed — a scorched remnant remains.
				item.volume /= 4
			if item.volume > 0:
				kept.append(item)
		pile.items = kept
		remove_pile_if_empty(cell)
	# The burn leaves ash for the cleaning crews.
	add_mess(cell, &"ash", BURN_ASH)


## The fire dies early — beaten out, drenched or both — leaving what it
## held standing. Its firefighting bill dies with it.
func _extinguish(cell: Vector3i) -> void:
	_fires.erase(cell)
	_remove_fire_marker(cell)
	var job: ColonyJob = _firefight_at.get(cell)
	if job != null and job.is_active() and job.assignee == null:
		job.state = ColonyJob.State.CANCELLED
	_firefight_at.erase(cell)


## The firefighting bill a burning cell asks for — one per cell, and
## only inside the home area: a fire out in the wilderness burns on its
## own, like RimWorld's.
func _post_firefight(cell: Vector3i) -> ColonyJob:
	if not home_cells.has(cell):
		return null
	var job := ColonyJob.new(ColonyJob.Type.FIREFIGHT, cell)
	_register_job(job)
	_firefight_at[cell] = job
	job_added.emit(job)
	return job


## The live firefighting bill at [param cell], or null.
func firefight_job_at(cell: Vector3i) -> ColonyJob:
	var job: ColonyJob = _firefight_at.get(cell)
	return job if job != null and job.is_active() else null


## The cell is out — the beater's bill is done.
func complete_firefight(job: ColonyJob) -> void:
	_firefight_at.erase(job.voxel_position)
	_finish_job(job)


## Adds [param amount] of [param kind] mess to [param cell] — only home
## cells accrue; the wilds keep their dirt, and a cell that stops being
## home sheds its record at the next scan.
func add_mess(cell: Vector3i, kind: StringName, amount: float) -> void:
	if amount <= 0.0 or not home_cells.has(cell):
		return
	var rec: Dictionary = mess.get(cell, {})
	rec[kind] = float(rec.get(kind, 0.0)) + amount
	mess[cell] = rec
	if rooms != null:
		rooms.stale_cell(cell)


## The total mess on [param cell] — zero for a clean or off-home cell.
func mess_amount(cell: Vector3i) -> float:
	var total := 0.0
	for kind: StringName in mess.get(cell, {}):
		total += float(mess[cell][kind])
	return total


## A cleaner's work — [param work] mess-seconds of scrubbing spread
## across whatever kinds the cell carries, so no kind lingers as the
## last one standing. Returns false when the cell is clean.
func scrub_cell(cell: Vector3i, work: float) -> bool:
	var rec: Dictionary = mess.get(cell, {})
	if rec.is_empty():
		return false
	var total := mess_amount(cell)
	var left := maxf(total - work, 0.0)
	if left <= 0.0:
		mess.erase(cell)
		if rooms != null:
			rooms.stale_cell(cell)
		return false
	for kind: StringName in rec:
		rec[kind] = float(rec[kind]) * left / total
	if rooms != null:
		rooms.stale_cell(cell)
	return true


## The clean-bill scan: every messy home cell past the threshold earns
## a CLEAN job; a cell that left home sheds its record and its open bill.
func _mess_tick() -> void:
	for cell: Vector3i in mess.keys():
		if not home_cells.has(cell):
			mess.erase(cell)
			if rooms != null:
				rooms.stale_cell(cell)
			var stale: ColonyJob = _clean_at.get(cell)
			if stale != null and stale.is_active() and stale.assignee == null:
				stale.state = ColonyJob.State.CANCELLED
			_clean_at.erase(cell)
			continue
		if mess_amount(cell) >= MESS_JOB_THRESHOLD:
			_post_clean(cell)


## The cleaning bill a messy cell asks for — one per cell, and only
## inside the home area: the same shape as the firefighting post.
func _post_clean(cell: Vector3i) -> ColonyJob:
	var live: ColonyJob = _clean_at.get(cell)
	if live != null and live.is_active():
		return live
	var job := ColonyJob.new(ColonyJob.Type.CLEAN, cell)
	_register_job(job)
	_clean_at[cell] = job
	job_added.emit(job)
	return job


## The live cleaning bill at [param cell], or null.
func clean_job_at(cell: Vector3i) -> ColonyJob:
	var job: ColonyJob = _clean_at.get(cell)
	return job if job != null and job.is_active() else null


## The cell is clean — the scrubber's bill is done.
func complete_clean(job: ColonyJob) -> void:
	_clean_at.erase(job.voxel_position)
	_finish_job(job)


## The orange box a burning cell wears, with the same work-light a lit
## campfire carries. Pulsed from the fire tick.
func _add_fire_marker(cell: Vector3i) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = _marker_mesh
	marker.material_override = _make_marker_material(Color(1.0, 0.45, 0.1, 0.45))
	marker.position = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	var light := OmniLight3D.new()
	light.name = "Fire"
	light.omni_range = CAMPFIRE_LIGHT_RADIUS
	light.light_color = Color(1.0, 0.5, 0.15)
	light.light_energy = 1.2
	marker.add_child(light)
	add_child(marker)
	_fire_markers[cell] = marker


func _remove_fire_marker(cell: Vector3i) -> void:
	var marker: Node3D = _fire_markers.get(cell)
	if marker != null:
		marker.queue_free()
		_fire_markers.erase(cell)


func _pulse_fire_marker(cell: Vector3i) -> void:
	var light := (
		_fire_markers[cell].get_node_or_null("Fire") as OmniLight3D
		if _fire_markers.has(cell)
		else null
	)
	if light != null:
		light.light_energy = randf_range(0.8, 1.6)


## The knowledge opening up a powered device for repair asks for — the
## same tech that built it. Conduit walls are exempt: a patched wall
## keeps its wire, so the repair is plain construction.
const REPAIR_SKILLS: Dictionary = {
	Building.Kind.GENERATOR: ColonyJob.Skill.ELECTRICIAN,
	Building.Kind.HEATER: ColonyJob.Skill.ELECTRICIAN,
	Building.Kind.COOLER: ColonyJob.Skill.HVAC,
	Building.Kind.PYLON: ColonyJob.Skill.ELECTRICIAN,
}


## The repair bill a damaged construction asks for — one per anchor
## cell; it runs until the thing stands whole again. Home-area work
## only: a structure battered out in the wild goes unmended unless the
## player brings its cell home. Powered devices stay gated on the
## technology that built them.
func _post_repair(voxel_position: Vector3i) -> ColonyJob:
	if not home_cells.has(voxel_position):
		return null
	if repair_job_at(voxel_position) != null:
		return null
	var job := ColonyJob.new(ColonyJob.Type.REPAIR, voxel_position)
	var building: Building = buildings.get(voxel_position)
	if building != null and REPAIR_SKILLS.has(building.kind):
		job.required_skill = REPAIR_SKILLS[building.kind]
	_register_job(job)
	job_added.emit(job)
	return job


## The live repair job at [param voxel_position], or null.
func repair_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.REPAIR
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## A repair bill's finish — nothing to drop or consume, the building
## just stands whole again.
func complete_repair(job: ColonyJob) -> void:
	_finish_job(job)


## Returns a job's escrowed items to the world — material already
## absorbed into a pending build, or inputs a craft job collected — so a
## cancellation conserves everything that went in.
func _return_escrow(job: ColonyJob) -> void:
	for item in job.components:
		_drop_item(item, job.voxel_position)
	job.components.clear()


## Bucket a voxel belongs to for the spatial index.
func _bucket_of(voxel: Vector3i) -> Vector2i:
	return Vector2i(voxel.x >> SPATIAL_BUCKET_SHIFT, voxel.z >> SPATIAL_BUCKET_SHIFT)


func _index_add(buckets: Dictionary, voxel: Vector3i) -> void:
	var key := _bucket_of(voxel)
	var list: Array = buckets.get(key, [])
	if list.is_empty():
		buckets[key] = list
	list.append(voxel)


func _index_remove(buckets: Dictionary, voxel: Vector3i) -> void:
	var key := _bucket_of(voxel)
	var list: Array = buckets.get(key, [])
	if list.is_empty():
		return
	list.erase(voxel)
	if list.is_empty():
		buckets.erase(key)


## The voxel of the nearest index member satisfying [param classify],
## which returns [enum _Match] per candidate: VETO skips it, FRESH is a
## normal hit and RETRY a deprioritised one — a retry only wins when no
## fresh hit exists at any distance. Rings expand outward from [param
## from]'s column and stop as soon as no member of the next ring could be
## closer than the best fresh hit; with no fresh hit the whole index is
## walked (unavoidable — every entry must be ruled out).
## [param area], when given, vetoes voxels outside the caller's allowed
## area — the gate every unit-restricted fetch query shares.
func _nearest_indexed(
	from: Vector3i, buckets: Dictionary, classify: Callable,
	area: AllowedArea = null
) -> Vector3i:
	var centre := _bucket_of(from)
	var best := Vector3i.MAX
	var best_sq := INF
	var retry := Vector3i.MAX
	var retry_sq := INF

	var extent := 0
	for key in buckets:
		extent = maxi(extent, maxi(absi(key.x - centre.x), absi(key.y - centre.y)))

	var radius := 0
	while radius <= extent:
		# The nearest voxel in ring [param radius] sits at least this far
		# out — past that, nothing can beat a hit already found.
		var ring_min := float(maxi(radius - 1, 0) << SPATIAL_BUCKET_SHIFT)
		if best != Vector3i.MAX and ring_min * ring_min > best_sq:
			break
		for bx in range(centre.x - radius, centre.x + radius + 1):
			for bz in range(centre.y - radius, centre.y + radius + 1):
				if maxi(absi(bx - centre.x), absi(bz - centre.y)) != radius:
					continue
				var list: Array = buckets.get(Vector2i(bx, bz), [])
				if list.is_empty():
					continue
				for voxel in list:
					if area != null and not area.cells.has(voxel):
						continue
					var tier: int = classify.call(voxel)
					if tier == _Match.VETO:
						continue
					var sq := (Vector3(voxel) - Vector3(from)).length_squared()
					if buckets == _pile_buckets:
						# Clutter-aware fetch: among near-tied piles,
						# the sparse heap wins — digging into a thin
						# pile clears it sooner and the dense heap
						# keeps its cover value a while longer.
						sq += (
							float(voxel_fill(voxel))
							/ maxf(1.0, float(voxel_capacity(voxel)))
							* SPARSE_FETCH_BIAS
						)
					if tier == _Match.FRESH:
						if sq < best_sq:
							best_sq = sq
							best = voxel
					elif sq < retry_sq:
						retry_sq = sq
						retry = voxel
		radius += 1
	return best if best != Vector3i.MAX else retry


## The active craft job queued at [param voxel_position], or null.
func craft_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.CRAFT
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## Queues a bill on the worksite at [param voxel_position] and returns
## it; the queue's scan turns runnable bills into craft jobs in order.
## A unit fetches the recipe's inputs — as many trips as the carry load
## needs — saws at the spot and drops the products there. Inputs are
## escrowed into the *running job* as they arrive, so a cancelled order
## hands them back rather than eating them; a still-queued bill owns
## nothing. A spot coming down takes no new bills.
func queue_order(
	voxel_position: Vector3i,
	recipe: StringName,
	condition: WorksiteOrder.Condition = WorksiteOrder.Condition.TIMES,
	target: int = 1
) -> WorksiteOrder:
	var recipe_data := recipe_of(recipe)
	if recipe_data.is_empty() or recipe_data.has("builds"):
		return null
	var building: Building = buildings.get(voxel_position)
	if building == null or not building.is_worksite():
		return null
	# A recipe pinned to a site (the meal wants the campfire, a study
	# the research bench) refuses a bare spot; multi-site recipes take
	# any worksite their `sites` table names — at the rate it gives.
	if recipe_site_rate(recipe_data, building.kind) <= 0.0:
		return null
	if deconstruct_job_at(voxel_position) != null:
		return null
	var order := WorksiteOrder.new()
	order.recipe = recipe
	order.condition = condition
	order.target = target
	building.orders.append(order)
	DLog.log("queued craft order %s at %s" % [recipe, voxel_position])
	_dispatch_worksite(building)
	return order


## Back-compat shortcut: enqueue a one-shot bill and return the craft
## job it became, or null if it can't dispatch yet (queued and waiting)
## or the order itself was refused.
func designate_craft(voxel_position: Vector3i, recipe: StringName = &"planks") -> ColonyJob:
	if queue_order(voxel_position, recipe) == null:
		return null
	return craft_job_at(voxel_position)


## Drops [param order] from the worksite at [param voxel_position]. If
## it's the order currently running, its job is cancelled too — the
## escrowed inputs drop back at the spot. Returns false if the order
## isn't on this worksite's queue.
func remove_order(voxel_position: Vector3i, order: WorksiteOrder) -> bool:
	var building: Building = buildings.get(voxel_position)
	if building == null or not building.orders.has(order):
		return false
	building.orders.erase(order)
	var job := craft_job_at(voxel_position)
	if job != null and job.order == order:
		_cancel_job(job)
	return true


## Suspends or resumes a bill — RimWorld's yellow S. A paused bill
## keeps its place in the queue but dispatches nothing; a paused bill
## whose job is already running suspends the job itself — the worker
## walks off, the escrowed inputs stay put, and unpausing puts the job
## back on the board where it left off.
func set_order_paused(
	voxel_position: Vector3i, order: WorksiteOrder, paused: bool
) -> void:
	order.paused = paused
	var job := craft_job_at(voxel_position)
	if job == null or job.order != order:
		return
	job.suspended = paused
	if world.sim != null:
		world.sim.job_suspend(job.get_instance_id(), paused)
	if paused and job.assignee != null:
		# Hand the job back to the board (suspended, escrow intact) and
		# free the worker — the release_job/abandon pair is the same
		# path a give-up takes.
		if job.assignee.has_method(&"abandon_job"):
			job.assignee.abandon_job()
		release_job(job, "bill paused")


## Moves a bill one slot earlier or later in the worksite's queue —
## RimWorld's up/down triangles. [param delta] is −1 or +1.
func move_order(
	voxel_position: Vector3i, order: WorksiteOrder, delta: int
) -> bool:
	var building: Building = buildings.get(voxel_position)
	if building == null:
		return false
	var i := building.orders.find(order)
	var j := i + delta
	if i < 0 or j < 0 or j >= building.orders.size():
		return false
	var other: WorksiteOrder = building.orders[j]
	building.orders[i] = other
	building.orders[j] = order
	return true


## Enqueues a copy of [param order] on the same worksite — RimWorld's
## bill copy/paste, one bench at a time. The copy starts fresh: no run
## count, not paused. Returns the new order, or null.
func duplicate_order(voxel_position: Vector3i, order: WorksiteOrder) -> WorksiteOrder:
	var building: Building = buildings.get(voxel_position)
	if building == null or not building.orders.has(order):
		return null
	var copy := WorksiteOrder.new()
	order.copy_into(copy)
	building.orders.append(copy)
	_dispatch_worksite(building)
	return copy


## Cancels a job mid-flight: escrow returns, the assignee lets go, the
## worksite marker comes back, and the corpse is pruned.
func _cancel_job(job: ColonyJob) -> void:
	_return_escrow(job)
	job.state = ColonyJob.State.CANCELLED
	if job.assignee != null and job.assignee.has_method(&"abandon_job"):
		job.assignee.abandon_job()
	_restore_worksite_marker(job.voxel_position)
	_prune_jobs()


## One dispatch pass over every worksite: the site that has queued bills
## and no live craft job takes its next runnable one.
func _worksite_tick() -> void:
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building):
			continue
		seen[building] = true
		if building.is_worksite() and not building.orders.is_empty():
			_dispatch_worksite(building)


## Gives [param building] its next runnable bill, if any. The queue is
## walked head-first: a finished TIMES order drops out, a stocked
## UNTIL_HAVE order parks in place (it keeps priority and resumes when
## the count dips), and an order whose inputs don't exist anywhere
## rotates to the back of the line rather than blocking it. At most one
## job posts per call.
func _dispatch_worksite(building: Building) -> void:
	if (
		craft_job_at(building.voxel) != null
		or deconstruct_job_at(building.voxel) != null
	):
		return
	if building.uses_fuel() and not building.lit():
		# A cold fire suspends its bills — they keep their places in
		# the queue and resume the moment the fire is fed again. The
		# toolmaker's forge gates the same way: no fuel, no work.
		return
	var deferred: Array[WorksiteOrder] = []
	var i := 0
	while i < building.orders.size():
		var order := building.orders[i]
		if (
			order.condition == WorksiteOrder.Condition.TIMES
			and order.done >= order.target
		):
			building.orders.remove_at(i)
			continue
		if order.paused:
			# Suspended by the player — it holds its place in line.
			i += 1
			continue
		if not order.wants_work(_have_count(order.recipe, order)):
			# Parked, not broken — it holds its place in line.
			i += 1
			continue
		if _order_dispatchable(order, building.voxel):
			var job := ColonyJob.new(ColonyJob.Type.CRAFT, building.voxel)
			job.recipe = order.recipe
			job.order = order
			if (
				recipe_of(order.recipe).get(&"repair", false)
				or recipe_of(order.recipe).get(&"tool_repair", false)
			):
				# The loose bill isn't known until the worn item arrives
				# — its cost scales with the wear. Empty means "fetch
				# the garment or tool first"; the escrow fills the real
				# bill in.
				job.repair_loose = {}
			_register_job(job)
			# The spot marker stays — it just switches to the running look.
			_set_marker_appearance(
				building.voxel,
				_craft_job_marker_material,
				_worksite_job_mesh(building.voxel)
			)
			job_added.emit(job)
			break
		deferred.append(order)
		building.orders.remove_at(i)
	for order in deferred:
		building.orders.append(order)


## True when every input the order's recipe calls for exists in some
## landed pile a fetch could actually reach: counted by the cm³ the
## recipe wants, items of materials the bill rejects don't count, and
## a bill with an ingredient radius only sees piles within it of the
## worksite. In-flight items and escrowed components don't count.
func _order_dispatchable(order: WorksiteOrder, origin: Vector3i) -> bool:
	var recipe: Dictionary = recipe_of(order.recipe)
	if recipe.is_empty():
		return false
	var inputs: Dictionary = recipe["inputs"]
	var volumes: Dictionary = recipe.get(&"input_cm3", {})
	var pins: Dictionary = recipe.get(&"input_material", {}).duplicate()
	# `input_spec` pins a form to a garment spec the way `input_material`
	# pins it to a material — the repair and salvage bills' garment.
	for pinned: int in recipe.get(&"input_spec", {}):
		pins[pinned] = recipe[&"input_spec"][pinned]
	for form: int in inputs:
		# `input_cm3` overrides the per-item count — a loose input is
		# measured in volume (the mound's soil), and `input_material`
		# narrows which material of the form counts (branches, clay).
		var need := int(inputs[form]) * DropItem.form_volume(form)
		if volumes.has(form):
			need = int(volumes[form])
		var have := 0
		for voxel: Vector3i in item_piles:
			if (
				order.ingredient_radius > 0.0
				and Vector3(voxel).distance_to(Vector3(origin))
					> order.ingredient_radius
			):
				continue
			var pile := item_pile_at(voxel)
			if pile == null:
				continue  # a deferred free left a dead key
			for item in pile.items:
				var pin: Variant = pins.get(form)
				if (
					DropItem.want_form_for(inputs, item.form) == form
					and not item.forbidden
					and order.admits_item(item)
					and (
						pin == null
						or (pin is StringName and item.spec == pin)
						or (pin is int and item.material == pin)
						or (pin is Array and pin.has(item.material))
					)
				):
					have += item.volume
		if have < need:
			return false
	# `input_loose` entries are material-keyed — a smelt wants malachite
	# gravel AND charcoal, both LOOSE, so the form-level check can't
	# separate them.
	var loose: Dictionary = recipe.get(&"input_loose", {})
	for material: int in loose:
		var need := int(loose[material])
		var have := 0
		for voxel: Vector3i in item_piles:
			if (
				order.ingredient_radius > 0.0
				and Vector3(voxel).distance_to(Vector3(origin))
					> order.ingredient_radius
			):
				continue
			for item in _items_of(voxel):
				if (
					item.form == DropItem.Form.LOOSE
					and item.material == material
					and not item.forbidden
					and order.admits_item(item)
				):
					have += item.volume
		if have < need:
			return false
	# `needs_spec` is presence, not escrow — the bill wants a crucible
	# in the stores before the gold melt starts, and the vessel comes
	# back when the pour is done.
	var need_spec := StringName(recipe.get(&"needs_spec", &""))
	if need_spec != &"" and not has_spec_item(need_spec):
		return false
	return true


## True when some landed, unforbidden pile holds an item carrying
## [param spec_id] — the crucible the gold bill waits on. In-flight
## goods don't count: dispatch can't fetch what's being carried.
func has_spec_item(
	spec_id: StringName, form: DropItem.Form = DropItem.Form.TOOL
) -> bool:
	for voxel: Vector3i in item_piles:
		var pile := item_pile_at(voxel)
		if pile != null and pile.has_spec_item(form, spec_id):
			return true
	return false


## How many of [param recipe]'s output items the colony holds. The
## count is by the recipe's first output form, material-agnostic:
## "until you have 10 planks". With no order the tally is every landed
## pile, falling pile, and item in a unit's hands — owned goods,
## wherever they rest. [param order]'s `count_stored_only` narrows it
## to stockpile tiles — RimWorld's "items not in a stockpile are not
## counted" — and then in-flight goods stop counting too.
func _have_count(recipe: StringName, order: WorksiteOrder = null) -> int:
	var outputs: Array = recipe_of(recipe).get("outputs", [])
	if outputs.is_empty():
		# Loose-output recipes (the smelts) count in batches: total
		# volume of the product material held, over the batch's yield.
		var loose_out: Dictionary = recipe_of(recipe).get(
			&"output_loose", {}
		)
		if loose_out.is_empty():
			return 0
		var material_out: int = loose_out.keys()[0]
		var per_batch := int(loose_out[material_out])
		if per_batch <= 0:
			return 0
		# MAT_INHERIT output can't name its material ahead of the
		# fetch — count whatever gravel the bill's input pin admits.
		var mats: Array = []
		if material_out == MAT_INHERIT:
			for pin: Variant in recipe_of(recipe).get(&"input_material", {}).values():
				if pin is Array:
					mats.append_array(pin)
				elif pin is int:
					mats.append(pin)
		else:
			mats = [material_out]
		if mats.is_empty():
			return 0
		var stored_only := order != null and order.count_stored_only
		var volume := 0
		for voxel: Vector3i in item_piles:
			if stored_only and not stockpiles.has(voxel):
				continue
			for item in _items_of(voxel):
				if (
					item.form == DropItem.Form.LOOSE
					and mats.has(item.material)
				):
					volume += item.volume
		if not stored_only:
			for pile: ItemPile in _in_flight:
				for item in pile.items:
					if (
						item.form == DropItem.Form.LOOSE
						and mats.has(item.material)
					):
						volume += item.volume
			for unit in units:
				for item in unit._carried:
					if (
						item.form == DropItem.Form.LOOSE
						and mats.has(item.material)
					):
						volume += item.volume
		return volume / per_batch
	var stored_only := order != null and order.count_stored_only
	var form: int = outputs[0].keys()[0]
	var count := 0
	for voxel: Vector3i in item_piles:
		if stored_only and not stockpiles.has(voxel):
			continue
		var pile := item_pile_at(voxel)
		if pile == null:
			continue  # a deferred free left a dead key — the sweep reaps it
		for item in pile.items:
			if item.form == form:
				count += 1
	if stored_only:
		return count
	for pile: ItemPile in _in_flight:
		for item in pile.items:
			if item.form == form:
				count += 1
	for unit in units:
		for item in unit._carried:
			if item.form == form:
				count += 1
	return count


## A craft job is done once its products hit the ground at the spot —
## or, for a construct-in-place recipe like the ladder, once the
## escrowed inputs have become the building. A worksite bill counts the
## run against its condition; a finished TIMES order leaves the queue.
func complete_craft(job: ColonyJob) -> void:
	if recipe_of(job.recipe).has("builds"):
		complete_construct(job)
		return
	if job.order != null:
		job.order.done += 1
		if (
			job.order.condition == WorksiteOrder.Condition.TIMES
			and job.order.done >= job.order.target
		):
			var building: Building = buildings.get(job.voxel_position)
			if building != null:
				building.orders.erase(job.order)
	_finish_job(job)


## The research bench's Study bills — one pseudo-recipe per studyable
## item type, synthesized from the recipe that makes such an item (or a
## hand-written make-record for charcoal, which no craft bill produces).
## `study_*` ids never appear in RECIPES itself — it's const — so every
## recipe lookup a job or order does goes through [method recipe_of],
## which resolves either table. The item is the teacher: a found or
## bought thing teaches exactly the skill that would have made it.
static var _study_recipes: Dictionary = {}
## Item type → study recipe id, keyed Vector2i(form, material). A
## material of −1 is the wildcard — the recipe accepts any material of
## the form (a bed kit studies the same whatever wood it was sawn from).
static var _study_item_type: Dictionary = {}

## The loose-material scoop a study bill works over — one cobble's
## worth of gravel or powder.
const STUDY_LOOSE_CM3 := 10_000
## Base chance a study breaks its specimen — at skill level 0.
const STUDY_BREAK_BASE := 0.6
## Each level of the studied skill cuts the break chance to 2/3 —
## 60% at 0, 40% at 1, 26.7% at 2, 17.8% at 3.


## Fills the study tables on first use — the bench panel and every
## `recipe_of` lookup share the one synthesized set.
static func _ensure_study_recipes() -> void:
	if not _study_recipes.is_empty():
		return
	for base_id in RECIPE_ORDER:
		var base: Dictionary = RECIPES[base_id]
		# `builds` recipes make buildings, not items — there is no
		# specimen to hold up to the light.
		if base.has("builds"):
			continue
		# What making the specimen is worth — the knowledge gate first
		# (found goods teach gated skills: studying an iron pick teaches
		# bloomery knowledge, which is what the forge demands), else the
		# discipline the base recipe trains (Crafting by default).
		var reqs := recipe_requires(base)
		var skill := int(
			reqs[0] if not reqs.is_empty()
			else base.get("skill", ColonyJob.SKILL_FOR[ColonyJob.Type.CRAFT])
		)
		var xp := float(
			base.get("xp", ColonyJob.XP_FOR[ColonyJob.Type.CRAFT])
		)
		# The normalized make-record a break drop is recomputed from:
		# the base recipe's declared inputs plus its total output volume.
		var out_cm3 := 0
		for output: Dictionary in base.get("outputs", []):
			for form: int in output:
				out_cm3 += int(output[form]) * DropItem.form_volume(form)
		for mat: int in base.get(&"output_loose", {}):
			out_cm3 += int(base[&"output_loose"][mat])
		var make := {
			"inputs": base.get("inputs", {}),
			"input_cm3": base.get(&"input_cm3", {}),
			"input_material": base.get(&"input_material", {}),
			"input_loose": base.get(&"input_loose", {}),
			"out_cm3": out_cm3,
		}
		for output: Dictionary in base.get("outputs", []):
			for form: int in output:
				# A container product is freight gear, not a craft
				# specimen — the crate wildcard below owns (CRATE, -1),
				# and first-claim would hand a sack's sewing lesson to
				# every furniture crate in the world.
				if DropItem.CONTAINER_SPECS.has(
					base.get(&"output_spec", &"")
				):
					continue
				# The specimen's material: the recipe's output pin when
				# there is one (a meal is MEAL, a seed packet SEED),
				# else the material(s) its lone input pin names — a set
				# pin like the crush bills' rock kinds registers one
				# study entry per material — else the wildcard.
				var material := int(base.get("output_material", -1))
				var mats: Array[int] = []
				if material >= 0:
					mats = [material]
				else:
					var pins: Dictionary = base.get(&"input_material", {})
					if pins.size() == 1:
						var pin: Variant = pins.values()[0]
						if pin is Array:
							for m: int in pin:
								mats.append(m)
						elif pin is int:
							mats.append(int(pin))
				if mats.is_empty():
					mats = [-1]
				for m in mats:
					_add_study_recipe(form, int(m), make, skill, xp)
		for mat: int in base.get(&"output_loose", {}):
			# MAT_INHERIT pours whatever the inputs committed — the
			# make-record can't name a material for the study key.
			if mat < 0:
				continue
			_add_study_recipe(DropItem.Form.LOOSE, int(mat), make, skill, xp)
	# Charcoal — no bill makes it; the mound's BURN job does. A
	# hand-written make-record keeps found charcoal studyable.
	var charcoal_key := Vector2i(
		DropItem.Form.LOOSE, BlockRegistry.Resource_.CHARCOAL
	)
	if not _study_item_type.has(charcoal_key):
		_add_study_recipe(
			DropItem.Form.LOOSE,
			BlockRegistry.Resource_.CHARCOAL,
			{
				"inputs": {DropItem.Form.LOG: 1},
				"input_cm3": {DropItem.Form.LOOSE: 100_000},
				"input_material": {
					DropItem.Form.LOG: BlockRegistry.Resource_.WOOD,
					DropItem.Form.LOOSE: BlockRegistry.Resource_.BRANCH,
				},
				"input_loose": {},
				"out_cm3": CHARCOAL_OUT_CM3,
			},
			ColonyJob.Skill.CHARCOAL_BURNING,
			ColonyJob.XP_FOR[ColonyJob.Type.BURN],
		)
	# A packed furniture crate — a bought or salvaged piece teaches the
	# joinery that made it. The wildcard entry covers every crate; the
	# recipe's `requires` reads off the specimen's spec at dispatch.
	var crate_key := Vector2i(DropItem.Form.CRATE, -1)
	if not _study_item_type.has(crate_key):
		_add_study_recipe(
			DropItem.Form.CRATE, -1,
			{
				"inputs": {DropItem.Form.PLANK: 5},
				"input_cm3": {},
				"input_material": {},
				"input_loose": {},
				"out_cm3": 5 * DropItem.PLANK_CM3,
			},
			ColonyJob.Skill.COMPLEX_FURNITURE,
			ColonyJob.XP_FOR[ColonyJob.Type.CRAFT],
		)


## Registers one study pseudo-recipe for an item type. First claim
## wins — when two recipes make the same type (a loose ore from two
## crush routes) the earlier bill owns the teaching.
static func _add_study_recipe(
	form: int, material: int, make: Dictionary, skill: int, xp: float
) -> void:
	var key := Vector2i(form, material)
	if _study_item_type.has(key):
		return
	var material_name := (
		BlockRegistry.resource_name_of(material).to_lower()
		if material >= 0 else "any"
	)
	var id := StringName(
		"study_%s_%s" % [
			String(DropItem.Form.keys()[form]).to_lower(),
			material_name.replace(" ", "_"),
		]
	)
	_study_item_type[key] = id
	# The specimen's display name: "stone cobble", "copper gravel" —
	# except where material and form are the same word ("seeds",
	# "meals"), which reads better alone.
	var form_label := (
		"gravel" if form == DropItem.Form.LOOSE else DropItem.form_name(form)
	)
	var specimen_label := form_label
	if material >= 0 and material_name.rstrip("s") != form_label.rstrip("s"):
		specimen_label = "%s %s" % [material_name, form_label]
	elif material >= 0:
		specimen_label = material_name
	var recipe := {
		"label": "Study %s" % specimen_label,
		# Marker the craft paths branch on: no products, no quality
		# roll — the lesson lands scaled by what the student knows.
		"study": true,
		"study_make": make,
		"site": Building.Kind.RESEARCH,
		"inputs": {},
		"outputs": [],
		"skill": skill,
		"xp": xp,
	}
	if form == DropItem.Form.LOOSE:
		recipe["input_loose"] = {material: STUDY_LOOSE_CM3}
	else:
		recipe["inputs"] = {form: 1}
		if material >= 0:
			recipe["input_material"] = {form: material}
	_study_recipes[id] = recipe


## Resolves a job or order's recipe id — a real entry of
## [constant RECIPES] or a synthesized study_* pseudo-recipe. Empty
## for anything else; call sites treat that as "no recipe".
static func recipe_of(recipe_id: StringName) -> Dictionary:
	if RECIPES.has(recipe_id):
		return RECIPES[recipe_id]
	_ensure_study_recipes()
	if _study_recipes.has(recipe_id):
		return _study_recipes[recipe_id]
	_ensure_garment_recipes()
	if _garment_recipes.has(recipe_id):
		return _garment_recipes[recipe_id]
	_ensure_tool_recipes()
	return _tool_recipes.get(recipe_id, {})


## The item-form → cm³ recipe a BUILD job is feeding: conduit wires a
## wall's face, a `face_dir` job paves it, and anything else is a wall
## or door spec — falling back to the material's canonical wall recipe
## for legacy jobs that recorded no spec.
static func build_recipe_of(job: ColonyJob) -> Dictionary:
	if job.build_spec == &"conduit":
		return {DropItem.Form.WIRE: CONDUIT_WIRE_CM3}
	if job.face_dir != Vector3i.ZERO:
		return BlockRegistry.floor_recipe(job.build_spec)
	var recipe := BlockRegistry.build_recipe(job.build_spec)
	if recipe.is_empty():
		recipe = BlockRegistry.wall_recipe(job.material)
	return recipe


## What a job needs in hand — the tool classes that satisfy it and
## the spec key that rates the work: felling wants an axe, hard rock
## a pick alone, and soft ground either digging tool. Empty for jobs
## with no tool requirement. The unit reads this on claim, on wield,
## and on every work tick.
static func required_tool(job: ColonyJob, world: VoxelWorld) -> Dictionary:
	if job.type == ColonyJob.Type.CHOP:
		return {&"classes": [&"axe"], &"use": &"chop"}
	if job.type == ColonyJob.Type.MINE:
		if (
			BlockRegistry.hardness(world.get_block(job.voxel_position))
			>= HARD_MINE_HARDNESS
		):
			return {&"classes": [&"pick"], &"use": &"mine"}
		return {&"classes": [&"shovel", &"pick"], &"use": &"dig"}
	return {}


## The worksite kinds a recipe runs at and how fast — `sites` maps
## kind → speed multiplier for the multi-bench crafts (sheet metal and
## wire crawl at a bare spot); a plain `site` is the one-site
## shorthand at full rate, and absent means the crafting spot. 0.0
## means the worksite can't run the bill at all.
static func recipe_site_rate(recipe: Dictionary, kind: int) -> float:
	var sites: Dictionary = recipe.get(&"sites", {})
	if not sites.is_empty():
		return float(sites.get(kind, 0.0))
	return 1.0 if kind == int(recipe.get("site", Building.Kind.WORKSITE)) else 0.0


## The bill-menu category a recipe files under — prefix-keyed so a new
## recipe lands with its kin without a data field. Order of checks
## matters: a `sew_*` garment is tailoring, not food prep.
static func recipe_category(recipe_id: StringName) -> String:
	var id := String(recipe_id)
	if id.begins_with("crush_") or id.begins_with("cut_blocks"):
		return "Stone & ore"
	if (
		id.begins_with("smelt_") or id.begins_with("alloy_")
		or id.begins_with("fire_")
	):
		return "Foundry"
	if (
		id.begins_with("sheet_metal") or id.begins_with("wire_")
		or id == "machine_components" or id.begins_with("nail_box")
	):
		return "Metalwork"
	if (
		id.begins_with("garb_") or id.begins_with("sew_")
		or id.begins_with("tool_belt") or id.begins_with("backpack")
		or id == "cotton_cloth"
	):
		return "Tailoring"
	if id == "planks":
		return "Woodwork"
	if (
		id == "prepare_meal" or id == "make_pemmican"
		or id == "cook_stew" or id == "extract_seed"
	):
		return "Kitchen"
	# Axes, shovels, picks, spear, bow — the catch-all is the gear rack.
	return "Tools & weapons"


## The skill gates a recipe imposes, normalized to a list — `requires`
## accepts one skill or an array (the cooler wants Electrician AND
## HVAC). Empty for ungated work.
static func recipe_requires(recipe: Dictionary) -> Array:
	var req: Variant = recipe.get("requires", null)
	if req is Array:
		return req
	return [req] if req != null and int(req) >= 0 else []


## The study bill id for an item type — the exact material's recipe
## first, then the form's wildcard. Empty when nothing makes the type:
## raw logs, boulders and foraged fruit aren't manufactured goods.
static func study_recipe_for(form: int, material: int) -> StringName:
	_ensure_study_recipes()
	var id: StringName = _study_item_type.get(Vector2i(form, material), &"")
	if id == &"":
		id = _study_item_type.get(Vector2i(form, -1), &"")
	return id


## Every study bill id — the bench panel's fixed button set.
static func study_recipe_ids() -> Array[StringName]:
	_ensure_study_recipes()
	var ids: Array[StringName] = []
	ids.assign(_study_recipes.keys())
	return ids


## The study bills a bench could run right now — one per studyable
## item type sitting in a landed pile. Goods in a unit's hands don't
## count: dispatch can't fetch what's being carried.
func study_options() -> Array[StringName]:
	var found: Array[StringName] = []
	for voxel: Vector3i in item_piles:
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			var id := study_recipe_for(int(item.form), int(item.material))
			if id != &"" and not found.has(id):
				found.append(id)
	return found


## The garment work bills — one `repair_*` and one `salvage_*`
## pseudo-recipe per apparel spec, synthesized like the study set and
## resolved by the same [method recipe_of]. Both take the worn garment
## as their lone discrete input — `input_spec` pins the form to the
## spec — and leave the material bill to the running job, since a
## repair's cost scales with the garment's actual wear.
static var _garment_recipes: Dictionary = {}

## What a repair restores — 80% of the wear the garment had lost. The
## last sliver of damage never quite comes out.
const GARMENT_REPAIR_RESTORE := 0.8
## What a salvage returns — half the garment's original material cost,
## scaled down by how worn it is.
const GARMENT_SALVAGE_FRACTION := 0.5


## Fills the garment-work table on first use — one repair and one
## salvage bill per known apparel spec.
static func _ensure_garment_recipes() -> void:
	if not _garment_recipes.is_empty():
		return
	for spec_id: StringName in DropItem.APPAREL_SPECS:
		var label := String(
			DropItem.APPAREL_SPECS[spec_id].get(&"name", String(spec_id))
		)
		_garment_recipes[StringName("repair_%s" % spec_id)] = {
			"label": "Repair %s" % label.to_lower(),
			"repair": true,
			"garment_spec": spec_id,
			"site": Building.Kind.TAILOR,
			"inputs": {DropItem.Form.GARMENT: 1},
			"input_spec": {DropItem.Form.GARMENT: spec_id},
			"outputs": [],
			"xp": 3.0,
		}
		_garment_recipes[StringName("salvage_%s" % spec_id)] = {
			"label": "Salvage %s" % label.to_lower(),
			"salvage": true,
			"garment_spec": spec_id,
			"site": Building.Kind.TAILOR,
			"inputs": {DropItem.Form.GARMENT: 1},
			"input_spec": {DropItem.Form.GARMENT: spec_id},
			"outputs": [],
			"xp": 2.0,
		}


## Every garment-work bill id — the bench panel's repair/salvage set.
static func garment_recipe_ids() -> Array[StringName]:
	_ensure_garment_recipes()
	var ids: Array[StringName] = []
	ids.assign(_garment_recipes.keys())
	return ids


## The loose-material bill for making [param spec_id] of
## [param material] — the make recipe's `input_loose`, looked up so a
## repair or salvage can recompute the original crafting cost. Empty
## for an unknown spec/material pair.
static func garment_make_loose(spec_id: StringName, material: int) -> Dictionary:
	for id: StringName in RECIPES:
		var recipe: Dictionary = RECIPES[id]
		if recipe.get(&"output_spec", &"") != spec_id:
			continue
		var loose: Dictionary = recipe.get(&"input_loose", {})
		if loose.has(material):
			return loose
	return {}


## The loose-material bill a repair on [param garment] wants — the
## original make cost scaled by the wear it has lost (a half-worn
## garment takes half the cloth). Empty when the garment is pristine.
static func repair_loose_for(garment: DropItem) -> Dictionary:
	var out: Dictionary = {}
	var loss := clampf(1.0 - garment.wear, 0.0, 1.0)
	for material: int in garment_make_loose(garment.spec, garment.material):
		var volume := int(
			garment_make_loose(garment.spec, garment.material)[material] * loss
		)
		if volume > 0:
			out[material] = volume
	return out


## The garment-work bills a bench could run right now — repair and
## salvage ids for the apparel specs of garments sitting in landed
## piles, the same gate study_options applies.
func garment_work_options() -> Array[StringName]:
	var found: Array[StringName] = []
	for voxel: Vector3i in item_piles:
		for item in _items_of(voxel):
			if item.form != DropItem.Form.GARMENT or item.forbidden:
				continue
			for id: StringName in garment_recipe_ids():
				if (
					recipe_of(id).get(&"garment_spec", &"") == item.spec
					and not found.has(id)
				):
					found.append(id)
	return found


## A repair bill's finish — the garment goes back into the world with
## most of its wear restored; the scaled material bill was already
## escrowed and is spent.
func complete_garment_repair(job: ColonyJob) -> void:
	var garment: DropItem = null
	for item in job.components:
		if item.form == DropItem.Form.GARMENT:
			garment = item
			break
	job.components.clear()
	job.delivered.clear()
	if garment != null:
		garment.wear = minf(
			1.0, garment.wear + GARMENT_REPAIR_RESTORE * (1.0 - garment.wear)
		)
		_drop_item(garment, job.voxel_position)
	complete_craft(job)


## A salvage bill's finish — the garment is cut up for part of what it
## cost to make, scaled by the wear still left in it.
func complete_garment_salvage(job: ColonyJob) -> void:
	var garment: DropItem = null
	for item in job.components:
		if item.form == DropItem.Form.GARMENT:
			garment = item
			break
	job.components.clear()
	job.delivered.clear()
	if garment != null:
		var loose := garment_make_loose(garment.spec, garment.material)
		for material: int in loose:
			var volume := int(
				loose[material] * GARMENT_SALVAGE_FRACTION * garment.wear
			)
			if volume > 0:
				_drop_item(
					DropItem.new(material, DropItem.Form.LOOSE, volume),
					job.voxel_position
				)
	complete_craft(job)


## The tool work bills — one `repair_*` pseudo-recipe per metal tool
## spec, synthesized like the garment set. The worn tool is the lone
## discrete input; the metal bill is priced off its actual wear once
## the escrow sees it, like a garment repair's cloth.
static var _tool_recipes: Dictionary = {}


## The smelting knowledge a metal's work belongs to — re-forging an
## iron head asks what the bloomery taught, a soft-metal one what the
## pit smelter did.
const METAL_SMELT_SKILL: Dictionary = {
	BlockRegistry.Resource_.COPPER: ColonyJob.Skill.PIT_SMELTING,
	BlockRegistry.Resource_.TIN: ColonyJob.Skill.PIT_SMELTING,
	BlockRegistry.Resource_.IRON: ColonyJob.Skill.BLOOMERY_SMELTING,
	BlockRegistry.Resource_.GOLD: ColonyJob.Skill.PIT_SMELTING,
}


## Fills the tool-work table on first use — one repair bill per tool
## spec whose head is a repairable metal.
static func _ensure_tool_recipes() -> void:
	if not _tool_recipes.is_empty():
		return
	for spec_id: StringName in DropItem.TOOL_SPECS:
		var spec: Dictionary = DropItem.TOOL_SPECS[spec_id]
		var head := int(spec.get(&"head", BlockRegistry.Resource_.NONE))
		if not DropItem.METALS.has(head):
			continue
		var label := String(spec.get(&"name", String(spec_id)))
		_tool_recipes[StringName("repair_%s" % spec_id)] = {
			"label": "Repair %s" % label.to_lower(),
			"tool_repair": true,
			"tool_spec": spec_id,
			"site": Building.Kind.TOOLMAKER,
			"inputs": {DropItem.Form.TOOL: 1},
			"input_spec": {DropItem.Form.TOOL: spec_id},
			"outputs": [],
			"skill": ColonyJob.Skill.MANUFACTURING,
			"requires": METAL_SMELT_SKILL.get(
				head, ColonyJob.Skill.PIT_SMELTING
			),
			"xp": 3.0,
		}


## Every tool-work bill id — the bench panel's repair set.
static func tool_recipe_ids() -> Array[StringName]:
	_ensure_tool_recipes()
	var ids: Array[StringName] = []
	ids.assign(_tool_recipes.keys())
	return ids


## The tool-repair bills a bench could run right now — one per metal
## tool sitting in a landed pile that's worn enough to mend. Stone
## tools never appear: knapped heads can't be re-forged.
func tool_work_options() -> Array[StringName]:
	var found: Array[StringName] = []
	for voxel: Vector3i in item_piles:
		for item in _items_of(voxel):
			if (
				item.form != DropItem.Form.TOOL
				or item.forbidden
				or not DropItem.tool_repairable(item)
				or item.wear >= TOOL_REPAIR_CAP
			):
				continue
			for id: StringName in tool_recipe_ids():
				if (
					recipe_of(id).get(&"tool_spec", &"") == item.spec
					and not found.has(id)
				):
					found.append(id)
	return found


## The loose-metal bill a repair on [param tool] wants — one unit of
## raw metal per 40% of wear restored, priced against the cap: a
## half-worn pick takes one unit, a dead one takes two. Empty when
## the tool is at or above the repair cap.
static func tool_repair_loose_for(tool: DropItem) -> Dictionary:
	var damage := TOOL_REPAIR_CAP - tool.wear
	if damage <= 0.0 or not DropItem.tool_repairable(tool):
		return {}
	var units := int(ceil(damage / TOOL_REPAIR_STEP))
	return {int(tool.material): units * TOOL_METAL_CM3}


## A tool-repair bill's finish — the head is re-forged, buying back
## wear in 40% steps against the 80% cap; the priced metal was already
## escrowed and is spent. The mended tool drops at the bench.
func complete_tool_repair(job: ColonyJob) -> void:
	var tool: DropItem = null
	for item in job.components:
		if item.form == DropItem.Form.TOOL:
			tool = item
			break
	var units := 0
	var loose: Dictionary = (
		job.repair_loose if job.repair_loose != null else {}
	)
	for material: int in loose:
		units += int(loose[material]) / TOOL_METAL_CM3
	job.components.clear()
	job.delivered.clear()
	if tool != null:
		tool.wear = minf(
			TOOL_REPAIR_CAP, tool.wear + units * TOOL_REPAIR_STEP
		)
		_drop_item(tool, job.voxel_position)
	complete_craft(job)


## The chance a study breaks its specimen — 0.6 at level 0, shrinking
## by a third per level of the studied skill (0.4, 0.267, 0.178, …).
static func study_break_chance(level: int) -> float:
	return STUDY_BREAK_BASE * pow(2.0 / 3.0, maxi(level, 0))


## The lesson a study pays — the make recipe's XP scaled by
## (1 − level/10): full at level 0, nothing left at level 10.
static func study_xp(recipe: Dictionary, level: int) -> float:
	return float(recipe.get("xp", 0.0)) * maxf(0.0, 1.0 - level / 10.0)


## What a fumbled study leaves: the materials the specimen was made
## from, scaled to the studied portion of its batch. Whole-item inputs
## return whole items while the scaled count reaches one — a bed kit
## bursts back into planks — and the rest pours loose. Provisional:
## real item breakage/integrity replaces this when it exists.
func _study_remains(recipe: Dictionary, specimen: DropItem) -> Array[DropItem]:
	if specimen.form == DropItem.Form.CRATE:
		# A broken crate gives back its real contents — the packed
		# components and the shell it was wrapped in — never a
		# recomputed approximation.
		var contents: Array[DropItem] = []
		contents.append_array(specimen.packed)
		contents.append_array(specimen.shell)
		return contents
	var make: Dictionary = recipe.get(&"study_make", {})
	var out_cm3 := int(make.get("out_cm3", 0))
	if out_cm3 <= 0:
		return []
	var frac := float(specimen.volume) / float(out_cm3)
	var pins: Dictionary = make.get("input_material", {})
	var remains: Array[DropItem] = []
	for form: int in make.get("inputs", {}):
		var material := int(pins.get(form, -1))
		if material < 0:
			# Unpinned inputs inherit the specimen's own class — a wood
			# bed kit bursts into wood planks.
			material = int(specimen.material)
		var scaled := float(make["inputs"][form]) * frac
		var whole := floori(scaled)
		for i in whole:
			remains.append(
				DropItem.new(material, form, DropItem.form_volume(form))
			)
		var rest := int(
			round((scaled - whole) * DropItem.form_volume(form))
		)
		if rest > 0:
			remains.append(DropItem.new(material, DropItem.Form.LOOSE, rest))
	for form: int in make.get("input_cm3", {}):
		var material := int(pins.get(form, specimen.material))
		var vol := int(round(float(make["input_cm3"][form]) * frac))
		if vol > 0:
			remains.append(DropItem.new(material, DropItem.Form.LOOSE, vol))
	for material: int in make.get("input_loose", {}):
		var vol := int(round(float(make["input_loose"][material]) * frac))
		if vol > 0:
			remains.append(DropItem.new(material, DropItem.Form.LOOSE, vol))
	return remains


## A study bill's finish — no products: the specimen goes back to the
## pile intact, or, on a fumbled examination, comes apart into the
## materials it was made from. The scaled lesson lands in _finish_job.
func complete_study(job: ColonyJob) -> void:
	var recipe := recipe_of(job.recipe)
	var specimen: DropItem = (
		job.components[0] if not job.components.is_empty() else null
	)
	job.components.clear()
	job.delivered.clear()
	var level := 0
	if job.assignee != null:
		level = job.assignee.skill_level(int(recipe.get("skill", -1)))
	if specimen != null:
		if randf() < study_break_chance(level):
			for item in _study_remains(recipe, specimen):
				_drop_item(item, job.voxel_position)
		else:
			# Studied and survived — back to the pile it came from,
			# quality and all.
			_drop_item(specimen, job.voxel_position)
	complete_craft(job)


## The cells a bed built at [param anchor] would claim: [param anchor]
## plus the first valid horizontal neighbor. A bed needs open air over
## solid floor on both cells; the second picks from +X, −X, +Z, −Z in
## order until a real orientation control exists. Empty when the anchor
## can't host a bed at all.
func bed_cells(anchor: Vector3i) -> Array[Vector3i]:
	return furniture_cells(
		anchor, BlockRegistry.furniture_spec(&"bed")
	)


## The footprint a [param spec] piece would claim at [param anchor], or
## empty when no orientation fits. The anchor stays in the footprint;
## the rectangle is tried in each anchor-corner role and (for oblong
## pieces) both rotations — first fit wins.
func furniture_cells(
	anchor: Vector3i, fspec: Dictionary
) -> Array[Vector3i]:
	var size: Vector2i = fspec.get(&"size", Vector2i(1, 1))
	var dims: Array[Vector2i] = [size]
	if size.x != size.y:
		dims.append(Vector2i(size.y, size.x))
	for dim: Vector2i in dims:
		for sx in [1, -1]:
			for sz in [1, -1]:
				var cells: Array[Vector3i] = []
				var fits := true
				for dx in dim.x:
					for dz in dim.y:
						var cell := anchor + Vector3i(dx * sx, 0, dz * sz)
						if not _furniture_cell_free(cell):
							fits = false
							break
						cells.append(cell)
					if not fits:
						break
				if fits:
					return cells
	return []


## True when [param voxel] can host part of a furniture footprint:
## open air over solid ground, not packed with items, not already
## designated, built on or zoned for storage — a piece of furniture
## claims the cell outright.
func _furniture_cell_free(voxel: Vector3i) -> bool:
	return (
		world.is_editable(voxel)
		and world.get_block(voxel) == BlockRegistry.Block.AIR
		and not cell_claimed(voxel, Occ.PILE)
		and world.is_solid(voxel + Vector3i.DOWN)
		and not cell_claimed(
			voxel, Occ.DESIGNATION | Occ.BUILDING | Occ.TREE
		)
		and not stockpiles.has(voxel)
	)


## True for building kinds that minify — furniture in the RimWorld
## sense: beds, seating, tables, shelves, lamps, decor and recreation
## pieces uninstall into a crate rather than deconstructing.
static func is_furniture(building: Building) -> bool:
	return (
		building != null
		and (
			building.kind == Building.Kind.BED
			or building.kind == Building.Kind.TABLE
			or building.kind == Building.Kind.SEAT
			or building.kind == Building.Kind.LAMP
			or building.kind == Building.Kind.DECOR
			or building.kind == Building.Kind.SHELF
			or building.kind == Building.Kind.RECREATION
		)
	)


## The furniture spec a building packs as — its `spec` when it's a
## catalog piece; legacy BED buildings with no spec answer the plain
## bed so an old construction still crates up correctly.
func _furniture_spec_of(building: Building) -> StringName:
	if BlockRegistry.furniture_spec(building.spec).is_empty():
		return &"bed" if building.kind == Building.Kind.BED else &""
	return building.spec


## Queues a furniture build at [param anchor]: the spec's footprint is
## resolved first (either orientation, anchor in any corner), then the
## order runs through the craft machinery — haul the inputs, assemble
## in place. A matching crate in the world satisfies the whole thing:
## the fetch prefers it, and reinstalling skips the recipe entirely.
func designate_furniture(anchor: Vector3i, spec: StringName) -> ColonyJob:
	var fspec := BlockRegistry.furniture_spec(spec)
	if (
		fspec.is_empty()
		or not RECIPES.has(spec)
		or not RECIPES[spec].has("builds")
	):
		return null
	var cells := furniture_cells(anchor, fspec)
	if cells.is_empty():
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, cells[0])
	job.recipe = spec
	for cell in cells:
		if cell != job.voxel_position:
			job.extra_voxels.append(cell)
	_register_job(job)
	for cell in cells:
		_add_marker(cell, _build_marker_material, null, true)
	DLog.log("designated furniture %s %s" % [spec, cells])
	job_added.emit(job)
	return job


## Legacy name for the plain bed build — the kit pipeline is gone;
## beds construct in place like every other furniture piece.
func designate_bed(voxel_position: Vector3i) -> ColonyJob:
	return designate_furniture(voxel_position, &"bed")


## Queues an uninstall: a unit fetches a sheet-material shell, packs
## the piece into a crate at its site, and leaves the crate standing —
## parts and quality ride inside. Furniture only.
func designate_uninstall(voxel_position: Vector3i) -> ColonyJob:
	var building := building_at(voxel_position)
	if building == null or not is_furniture(building):
		return null
	if not building.deconstructable:
		return null
	var anchor := building.voxel
	if plan_job_at(anchor) != null or deconstruct_job_at(anchor) != null:
		return null
	for job in jobs:
		if (
			job.type == ColonyJob.Type.UNINSTALL
			and job.is_active()
			and (
				job.voxel_position == anchor
				or job.extra_voxels.has(anchor)
			)
		):
			return null
	var job := ColonyJob.new(ColonyJob.Type.UNINSTALL, anchor)
	for cell in building.footprint:
		if cell != anchor:
			job.extra_voxels.append(cell)
	_register_job(job)
	for cell in building.footprint:
		_set_marker_appearance(cell, _deconstruct_marker_material, _marker_mesh)
	DLog.log("designated uninstall %s" % anchor)
	job_added.emit(job)
	return job


## The uninstall's finish: the building's components pack into a crate
## wrapped in the delivered shell, and the site clears — nothing drops
## loose, nothing is lost. The crate lands where the piece stood.
func complete_uninstall(job: ColonyJob) -> void:
	var building: Building = buildings.get(job.voxel_position)
	if building == null:
		_finish_job(job)
		return
	var crate := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.CRATE, 0
	)
	# Every sheet item the packer delivered becomes the crate shell —
	# reinstalling returns them all, so a two-sheet shell refunds both.
	if not job.components.is_empty():
		crate.material = job.components[0].material
		crate.species = job.components[0].species
	for item in job.components:
		if (
			item.form == DropItem.Form.PLANK
			or item.form == DropItem.Form.SHEET
		):
			crate.shell.append(item)
			crate.volume += item.volume
	if crate.shell.is_empty():
		# The fetch died mid-job — improbable, but never synthesize:
		# the piece packs bare and yields no shell back.
		pass
	crate.spec = _furniture_spec_of(building)
	crate.quality = building.quality
	for item in building.components:
		crate.packed.append(item)
		crate.volume += item.volume
	if building.kind == Building.Kind.SHELF:
		# A shelf packs with its stock: the pile's items ride inside the
		# crate as `stored` freight — sealed until the shelf stands
		# again, so nothing reaches them while it's a box.
		var shelf_pile := item_pile_at(job.voxel_position)
		if shelf_pile != null:
			for item in shelf_pile.items:
				crate.stored.append(item)
				crate.volume += item.volume
			shelf_pile.items.clear()
			shelf_pile.fill_changed.emit(shelf_pile)
			remove_pile_if_empty(job.voxel_position)
	_teardown_building(job.voxel_position, job, true)
	_drop_item(crate, job.voxel_position)
	_finish_job(job)


## Queues an unpack order on the crate in [param voxel_position]'s
## pile: a unit cracks the shell there and spills the contents —
## furniture comes back to parts, the shell to a plank.
func designate_unpack(voxel_position: Vector3i) -> ColonyJob:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return null
	var has_crate := false
	for item in pile.items:
		if (
			item.form == DropItem.Form.CRATE
			and not item.forbidden
			and _crate_unpackable(item)
		):
			has_crate = true
			break
	if not has_crate:
		return null
	for job in jobs:
		if (
			job.type == ColonyJob.Type.UNPACK
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return null
	var job := ColonyJob.new(ColonyJob.Type.UNPACK, voxel_position)
	_register_job(job)
	_add_marker(voxel_position, _marker_material)
	DLog.log("designated unpack %s" % voxel_position)
	job_added.emit(job)
	return job


## The unpack's finish: the crate's packed items spill where it stood
## and the shell comes back as a sheet good — nothing vanishes.
## True when the crate can be cracked open where it lies — a small
## container (a sack, a box) always can: unpacking one just dumps the
## bag. A *large* container's freight stays sealed until the piece
## stands again — an uninstalled shelf's stock is inaccessible, which
## is why it rides `stored` and not `packed` out to a pile.
func _crate_unpackable(item: DropItem) -> bool:
	return item.is_container() or item.stored.is_empty()


func complete_unpack(job: ColonyJob) -> void:
	var pile := item_pile_at(job.voxel_position)
	var crate: DropItem = null
	if pile != null:
		for item in pile.items:
			if (
				item.form == DropItem.Form.CRATE
				and not item.forbidden
				and _crate_unpackable(item)
			):
				crate = pile.take_spec_item(DropItem.Form.CRATE, item.spec)
				break
	if crate == null:
		_finish_job(job)
		return
	for item in crate.packed:
		_drop_item(item, job.voxel_position)
	for item in crate.stored:
		_drop_item(item, job.voxel_position)
	# The shell comes back as the sheet goods it was wrapped in.
	for item in crate.shell:
		_drop_item(item, job.voxel_position)
	if crate.is_container():
		# A bag survives being dumped — the emptied container drops as
		# itself, tare volume and all, ready to haul again.
		crate.stored.clear()
		crate.packed.clear()
		crate.volume = crate.container_tare()
		_drop_item(crate, job.voxel_position)
	remove_pile_if_empty(job.voxel_position)
	_finish_job(job)


## The nearest pile voxel holding a crate of [param spec] — the
## furniture fetch's reinstall preference: an existing crate always
## beats fresh materials.
func nearest_crate_voxel(
	from: Vector3i, spec: StringName, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		var pile := item_pile_at(voxel)
		return (
			_Match.FRESH
			if pile != null and pile.has_spec_item(DropItem.Form.CRATE, spec)
			else _Match.VETO
		), area)


## The nearest pile voxel holding any crate — the unpack designation
## and the warehouse haul's queries.
func nearest_any_crate_voxel(
	from: Vector3i, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if item.form == DropItem.Form.CRATE and not item.forbidden:
				return _Match.FRESH
		return _Match.VETO, area)


## A furnish job is done once its kit is delivered to the anchor: the
## building registers across its footprint and the delivered items are
## what deconstruction later hands back. Legacy path — FURNISH jobs
## only survive in old saves; furniture is built in place now.
func complete_furnish(job: ColonyJob) -> void:
	var building := Building.new(job.furniture_kind, job.voxel_position)
	building.footprint.append_array(job.extra_voxels)
	building.components = job.components
	# The kit's craft quality becomes the furniture's — a masterwork
	# kit unpacks a masterwork bed, a shoddy one a shoddy bed.
	if not job.components.is_empty():
		building.quality = job.components[0].quality
	if building.kind == Building.Kind.BED and building.spec == &"":
		building.spec = &"bed"
	register_building(building)
	_finish_job(job)


## True when a ladder occupies [param voxel_position] — the query the
## no-sim standability fallback and pile-capacity rule share.
func ladder_at(voxel_position: Vector3i) -> bool:
	var building := building_at(voxel_position)
	return building != null and building.kind == Building.Kind.LADDER


## Item capacity of a voxel: a cubic metre, or three quarters when a
## ladder shares the cell — it claims the rest of the space.
## A shelf cell's pile capacity — shelving holds twice what the floor
## does per voxel. The single knob the compactness tuning turns on.
const SHELF_PILE_CM3 := DropItem.BLOCK_CM3 * 2


func voxel_capacity(voxel_position: Vector3i) -> int:
	var building := building_at(voxel_position)
	if (
		building != null
		and (
			building.kind == Building.Kind.SHELF
			or building.kind == Building.Kind.COMPOST_BIN
		)
	):
		# A bin packs as tight as a shelf — it's a container, not a floor.
		return SHELF_PILE_CM3
	var zone: StockpileZone = stockpiles.get(voxel_position)
	if zone != null and zone.warehouse:
		# Racked bulk storage: crates and big goods stack as deep as a
		# shelf holds — the warehouse's reason to exist.
		return SHELF_PILE_CM3
	return LADDER_PILE_CM3 if ladder_at(voxel_position) else DropItem.BLOCK_CM3


## Queues a ladder build at [param voxel_position]: a unit fetches three
## planks and assembles them in place. The cell is open air — a ladder
## shares its voxel with whatever already hangs or piles there, so a
## pile is allowed; the pile's capacity shrinks once the ladder stands.
func designate_ladder(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if cell_claimed(voxel_position, Occ.TREE):
		return null

	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = &"ladder"
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated ladder %s" % voxel_position)
	job_added.emit(job)
	return job


## A construct order's finish: the escrowed inputs become the building —
## the ladder records itself and claims the voxel's pathing edge in the
## sim. A pile sharing the cell just lost a quarter of its capacity.
func complete_construct(job: ColonyJob) -> void:
	var building := Building.new(recipe_of(job.recipe)["builds"], job.voxel_position)
	building.material = job.material
	building.components = job.components
	# The maker's quality roll rides the job through from the craft
	# tick — recreation builds read it for their fill rate.
	building.quality = job.quality
	# The cooler's orientation rides the job's face_dir through —
	# `designate_cooler` set which way the cold side points.
	building.face_dir = job.face_dir
	if building.kind == Building.Kind.RECREATION:
		# The recipe key doubles as the recreation spec — it decides what
		# the thing is called and what playing it feels like.
		building.spec = job.recipe
	var fspec := BlockRegistry.furniture_spec(job.recipe)
	if not fspec.is_empty():
		# A furniture build spans the designated footprint — the extra
		# cells joined the job at designation time.
		for cell in job.extra_voxels:
			if not building.footprint.has(cell):
				building.footprint.append(cell)
		building.spec = job.recipe
		if bool(fspec.get(&"medical", false)):
			# A hospital bed registers medical outright — toggling a
			# plain bed medical stays a panel choice.
			building.medical = true
		if bool(fspec.get(&"art", false)):
			# A carved work takes a subject — the carver picks from the
			# species on the table, portrait included. Unit tastes can
			# read it through `depicts`.
			var table := Species.species_table()
			building.depicts = StringName(
				table.keys()[randi() % table.size()]
			)
		# A crate in the escrow reinstalls: its contents are the
		# building's true components and its roll the real quality —
		# the installer's inputs (if any strayed in) hand back.
		var crate := _escrowed_crate(job)
		if crate != null:
			building.components = crate.packed
			building.quality = crate.quality
			# The shell comes back as the sheet goods it was wrapped in.
			for item in crate.shell:
				_drop_item(item, job.voxel_position)
			for item in job.components:
				if item != crate:
					_drop_item(item, job.voxel_position)
			# The freight an uninstalled shelf was carrying goes back on
			# the shelf — the crate sealed it until now.
			for item in crate.stored:
				_drop_item(item, job.voxel_position)
	register_building(building)
	_enforce_capacity(job.voxel_position)
	_finish_job(job)
	if building.kind == Building.Kind.CHARCOAL_MOUND:
		# The stack is sealed — now somebody has to tend the smoulder.
		# The burn posts as its own job so an untrained colony sees it
		# waiting rather than silently never firing.
		_post_burn(building.voxel)


## The crate escrowed into [param job]'s components, or null — a
## furniture build that fetched a matching crate carries it whole,
## contents and all, where a materials fetch carries loose parts.
func _escrowed_crate(job: ColonyJob) -> DropItem:
	for item in job.components:
		if item.form == DropItem.Form.CRATE:
			return item
	return null


## The supervised-smoulder job a finished charcoal mound wants. Gated
## on Charcoal burning — only a unit with basic knowledge claims it.
func _post_burn(voxel_position: Vector3i) -> ColonyJob:
	if burn_job_at(voxel_position) != null:
		return null
	var job := ColonyJob.new(ColonyJob.Type.BURN, voxel_position)
	job.required_skill = ColonyJob.Skill.CHARCOAL_BURNING
	_register_job(job)
	DLog.log("charcoal burn at %s" % voxel_position)
	job_added.emit(job)
	return job


## The live burn job at [param voxel_position], or null.
func burn_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BURN
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## A supervised burn's finish: the mound has smouldered out — its record
## goes (the stack is spent, not salvageable) and the charcoal pours
## onto the cell beside it. The components — log and branches — are
## consumed: that's what burning means.
func complete_burn(job: ColonyJob) -> void:
	var voxel := job.voxel_position
	var building: Building = buildings.get(voxel)
	if building != null and building.kind == Building.Kind.CHARCOAL_MOUND:
		for cell in building.footprint:
			buildings.erase(cell)
		_remove_marker(voxel)
	_drop_item(
		DropItem.new(
			BlockRegistry.Resource_.CHARCOAL,
			DropItem.Form.LOOSE, CHARCOAL_OUT_CM3
		),
		voxel + Vector3i.UP
	)
	_finish_job(job)


## The lesson's over — the student's caught up or the session ran its
## course. The tick already dripped the XP; this just closes the job.
func complete_teach(job: ColonyJob) -> void:
	_finish_job(job)


## Opens a lesson on [param student]: a TEACH job any unit can take when
## it out-levels the student in some skill — the claim gate and the
## tick both find the best gap via [method teachable_skill]. One-shot:
## the session ends when the gap closes or the session clock runs out.
func post_teach(student: Unit) -> ColonyJob:
	if student == null:
		return null
	for job in jobs:
		if (
			job.type == ColonyJob.Type.TEACH
			and job.patient == student
			and job.is_active()
		):
			return null
	var job := ColonyJob.new(ColonyJob.Type.TEACH, student._standing_voxel())
	job.patient = student
	_register_job(job)
	DLog.log("teach %s" % student)
	job_added.emit(job)
	return job


## True when a campfire occupies [param voxel_position] — the query the
## inspect panel and the cook's cold-fire check share.
func campfire_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.kind == Building.Kind.CAMPFIRE:
		return building
	return null


## Queues a campfire build at [param voxel_position]: a unit fetches the
## ring's cobbles and assembles them in place — the campfire is a
## construct-in-place recipe like the ladder. The cell must be open air
## over solid ground, and clear of piles, claims and other works.
func designate_campfire(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = &"campfire"
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated campfire %s" % voxel_position)
	job_added.emit(job)
	return job


## Queues a partial-height fortification at [param voxel_position] — a
## dirt mound or a barricade — or a floodgate's sluice, a water wheel,
## or a pump housing, by [param recipe]. Same construct-in-place path
## as the campfire. The cell must be open air over solid ground and
## clear of piles, claims, bushes and other works: once built the
## mound holds the whole cell for cover purposes even though it only
## fills it partway. Water in the cell is fine — a gate's whole job is
## standing in it; for the wheel it's mandatory, the river's own edge.
func designate_cover(voxel_position: Vector3i, recipe: StringName) -> ColonyJob:
	if (
		not RECIPES.has(recipe)
		or not RECIPES[recipe].has("builds")
		or not (
			RECIPES[recipe]["builds"] == Building.Kind.MOUND
			or RECIPES[recipe]["builds"] == Building.Kind.BARRICADE
			or RECIPES[recipe]["builds"] == Building.Kind.FENCE
			or RECIPES[recipe]["builds"] == Building.Kind.FLOODGATE
			or RECIPES[recipe]["builds"] == Building.Kind.WATER_WHEEL
			or RECIPES[recipe]["builds"] == Building.Kind.PUMP
		)
	):
		return null
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	if cell_claimed(voxel_position, Occ.BUSH):
		return null
	if RECIPES[recipe]["builds"] == Building.Kind.WATER_WHEEL:
		# The wheel has to stand in the flow — its own cell or a
		# lateral neighbor must hold water at designation. A dry-season
		# riverbed is fair game; an open field isn't.
		var wet: bool = (
			world.sim != null
			and world.sim.water_volume_at(voxel_position) > 0
		)
		if not wet and world.sim != null:
			for dir in FLOODGATE_DIRS:
				if world.sim.water_volume_at(voxel_position + dir) > 0:
					wet = true
					break
		if not wet:
			return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = recipe
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated cover %s at %s" % [recipe, voxel_position])
	job_added.emit(job)
	return job


## Queues a pump build at [param voxel_position] — intake on the
## [param face_dir] side, outflow off the opposite face. Any face is
## fair — a downward intake is a sump, an upward outflow a lift. A
## missing or diagonal normal defaults to the wettest lateral face —
## a river's pull is the natural intake; bone-dry ground gets -x so
## the machine is still placeable and re-plumbing is a rebuild.
## Both side cells must be open: a pump sealed into rock is dead
## plumbing.
func designate_pump(
	voxel_position: Vector3i, face_dir: Vector3i = Vector3i.ZERO
) -> ColonyJob:
	var dir := face_dir
	if not Flooring.FACE_DIRS.has(dir):
		dir = Vector3i.ZERO
	if dir == Vector3i.ZERO:
		var wettest := 0
		for cand in FLOODGATE_DIRS:
			if world.sim == null:
				break
			var v := int(world.sim.water_volume_at(voxel_position + cand))
			if v > wettest:
				wettest = v
				dir = cand
		if dir == Vector3i.ZERO:
			dir = Vector3i(-1, 0, 0)
	if (
		world.is_solid(voxel_position + dir)
		or world.is_solid(voxel_position - dir)
	):
		return null
	var job := designate_cover(voxel_position, &"pump")
	if job != null:
		job.face_dir = dir
	return job


## Queues a production construction at [param voxel_position] — a
## charcoal mound, pit smelter or bloomery, by [param recipe]. Same
## construct-in-place path as the campfire: open air over solid ground,
## clear of piles, claims, bushes and other works.
func designate_production(voxel_position: Vector3i, recipe: StringName) -> ColonyJob:
	if (
		not RECIPES.has(recipe)
		or not RECIPES[recipe].has("builds")
		or not (
			RECIPES[recipe]["builds"] == Building.Kind.CHARCOAL_MOUND
			or RECIPES[recipe]["builds"] == Building.Kind.SMELTER
			or RECIPES[recipe]["builds"] == Building.Kind.BLOOMERY
			or RECIPES[recipe]["builds"] == Building.Kind.RESEARCH
			or RECIPES[recipe]["builds"] == Building.Kind.METALWORK
			or RECIPES[recipe]["builds"] == Building.Kind.FABRICATOR
			or RECIPES[recipe]["builds"] == Building.Kind.GENERATOR
			or RECIPES[recipe]["builds"] == Building.Kind.HEATER
			or RECIPES[recipe]["builds"] == Building.Kind.COOLER
			or RECIPES[recipe]["builds"] == Building.Kind.PYLON
			or RECIPES[recipe]["builds"] == Building.Kind.TAILOR
			or RECIPES[recipe]["builds"] == Building.Kind.SHELF
			or RECIPES[recipe]["builds"] == Building.Kind.COMPOST_BIN
			or RECIPES[recipe]["builds"] == Building.Kind.TOOLMAKER
			or RECIPES[recipe]["builds"] == Building.Kind.STONECUTTER
			or RECIPES[recipe]["builds"] == Building.Kind.KILN
			or RECIPES[recipe]["builds"] == Building.Kind.REFRACTORY
			or RECIPES[recipe]["builds"] == Building.Kind.STONE_CRUSHER
			or RECIPES[recipe]["builds"] == Building.Kind.STOVE
		)
	):
		return null
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	if cell_claimed(voxel_position, Occ.BUSH):
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = recipe
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated production %s at %s" % [recipe, voxel_position])
	job_added.emit(job)
	return job


## The cover building in [param voxel_position] — a mound or barricade
## breaking the cell's line of fire — or null.
func cover_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.provides_cover():
		return building
	return null


## Walk-speed multiplier for crossing [param voxel_position]: climbing a
## mound or barricade costs the scramble; wading through an item pile
## costs a fraction of its fill, so a heaped pile is nearly a wall's
## climb and never a shortcut over one. [param entity] makes the answer
## per-traveler — a fence is a hop for a settler and a wall for an
## animal, which is the pen's whole point: the rail's block also lives
## in the pathfinder, so an animal never routes through to begin with.
func traversal_mult(voxel_position: Vector3i, entity: Node = null) -> float:
	var mult := 1.0
	if _fires.has(voxel_position):
		mult = FIRE_TRAVERSAL
	elif cover_at(voxel_position) != null:
		mult = COVER_CRAWL
	else:
		var building: Building = buildings.get(voxel_position)
		if building != null and building.kind == Building.Kind.FENCE:
			# Hoof and claw can't climb a rail — 0 is the block; the
			# follower treats it as "route around", never "freeze".
			if entity is Animal:
				return 0.0
			mult = FENCE_CRAWL
		elif (
			building != null
			and building.kind == Building.Kind.SPIKE_TRAP
			and entity is Unit
		):
			# A settler knows where the stakes are — priced like a
			# swim so paths steer around, not forbidden so a desperate
			# order can still wade in. Animals read the cell as open
			# ground and blunder straight onto the points.
			mult = TRAP_AVOID
		elif (
			building != null
			and (
				building.kind == Building.Kind.PYLON
				or building.kind == Building.Kind.COOLER
			)
		):
			# A strung line or a wall machine is in the way — the cell is
			# passable, barely: squeezing past the pole costs the scramble.
			mult = PYLON_CRAWL
		else:
			var pile := item_pile_at(voxel_position)
			if pile != null:
				var cap := float(voxel_capacity(voxel_position))
				# Wading up a loose mound's slope costs stride linearly;
				# pushing through discrete clutter costs on a curve that
				# steepens as the heap packs — past the dense threshold
				# the cell doesn't admit at all (path and motion refuse
				# it there).
				var loose := minf(float(pile.loose_volume()) / cap, 1.0)
				var clutter := minf(float(pile.clutter_volume()) / cap, 1.0)
				mult = (
					lerpf(1.0, PILE_CRAWL, loose)
					/ (1.0 + DropItem.CLUTTER_K * clutter * clutter)
				)
	# Water costs stride too: a wading-depth cell slows with its fill,
	# and a submerged cell is swim-only, priced like the fatigue.
	if world != null and world.sim != null:
		var level := int(
			world.sim.water_level_at(voxel_position.x, voxel_position.z)
		)
		if level >= voxel_position.y + 1:
			mult *= SWIM_TRAVEL
		elif level == voxel_position.y:
			var fill := clampf(
				float(world.sim.water_volume_at(voxel_position))
					/ 1_000_000.0,
				0.0, 1.0
			)
			mult *= lerpf(1.0, WADE_TRAVEL, fill)
	# A paved floor quickens the stride — the covering's `speed`
	# multiplies through like the water drag above does. Bare ground
	# and packed earth read 1.0, so unfloored cells are untouched.
	if flooring != null:
		mult *= BlockRegistry.floor_speed(
			flooring.covering_at(
				voxel_position, Flooring.face_index(Vector3i.DOWN)
			)
		)
	return mult


## Queues a recreation building at [param voxel_position]: a unit fetches
## the spec's inputs and assembles it in place — same construct-in-place
## path as the campfire. Sky-gated specs (the telescope) refuse a roofed
## cell. The cell must be open air over solid ground, clear of piles,
## claims and other works.
func designate_rec(voxel_position: Vector3i, spec: StringName) -> ColonyJob:
	if (
		not BlockRegistry.REC_SPECS.has(spec)
		or not RECIPES.has(spec)
		or not RECIPES[spec].has("builds")
	):
		return null
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	if BlockRegistry.rec_needs_sky(spec) and not sees_sky(voxel_position):
		# A telescope under a roof is furniture nobody uses.
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = spec
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated recreation %s %s" % [spec, voxel_position])
	job_added.emit(job)
	return job


## Every recreation building free for a session — no user claimed, no
## pending teardown, and sky-gated ones (the telescope) only while the
## sky shows. A unit about to relax claims one by setting its
## `occupant`, the same convention beds use.
func free_rec_buildings() -> Array[Building]:
	var out: Array[Building] = []
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building):
			continue
		seen[building] = true
		if (
			building.kind != Building.Kind.RECREATION
			or building.occupant != null
			or deconstruct_job_at(building.voxel) != null
			or (
				BlockRegistry.rec_needs_sky(building.spec)
				and not sees_sky(building.voxel)
			)
			or (
				BlockRegistry.rec_watts(building.spec) > 0.0
				and not building.powered
			)
		):
			continue
		out.append(building)
	return out


## One burn tick over every campfire: lit fires consume fuel, a fire
## that just went out drops its light, and an auto-refuelling fire at
## under its threshold fraction of the cap posts the refuel job — the
## fire's own refuel_fraction decides how low it lets itself get.
func _campfire_tick(elapsed: float) -> void:
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building) or not building.uses_fuel():
			continue
		seen[building] = true
		var was_lit := building.lit()
		if building.burns_passively():
			# The campfire and generator burn around the clock; the
			# toolmaker's forge only burns while a bill runs — its fuel
			# drain lives in the unit's craft tick.
			building.fuel = maxf(0.0, building.fuel - elapsed)
		var marker: MeshInstance3D = _designation_markers.get(building.voxel)
		var child := (
			marker.get_node_or_null("Fire") if marker != null else null
		)
		# Resync on a lit transition *or* a stale light — fuel can reach
		# zero outside this tick (tests, loads, debug) and the visible
		# state must still follow the record. Only the campfire wears a
		# light; the generator's burn is heat, not glow.
		if (
			building.kind == Building.Kind.CAMPFIRE
			and (
				building.lit() != was_lit
				or (child != null and child.visible != building.lit())
			)
		):
			_sync_campfire_light(building.voxel)
		if (
			building.auto_refuel
			and building.fuel < fuel_cap_of(building) * building.refuel_fraction
		):
			request_refuel(building.voxel)


## The fuel reserve size of a fuelled building — the campfire's ring
## and the generator's firebox share the scale for now.
func fuel_cap_of(building: Building) -> float:
	match building.kind:
		Building.Kind.GENERATOR:
			return GENERATOR_FUEL_CAP
		Building.Kind.TOOLMAKER:
			return TOOLMAKER_FUEL_CAP
	return CAMPFIRE_FUEL_CAP


## The fuelled building at [param voxel_position] — campfire ring or
## generator — the query the refuel machinery and inspect panel share.
func fueled_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.uses_fuel():
		return building
	return null


## What a powered device draws while running.
func device_watts(building: Building) -> float:
	match building.kind:
		Building.Kind.HEATER:
			return HEATER_WATTS
		Building.Kind.COOLER:
			return COOLER_WATTS
		Building.Kind.PUMP:
			return PUMP_WATTS
		Building.Kind.LAMP:
			return float(
				BlockRegistry.furniture_spec(building.spec).get(
					&"watts", 0.0
				)
			)
		Building.Kind.RECREATION:
			# Only powered rec specs draw — a television rides the net,
			# the horseshoe pin never does.
			return BlockRegistry.rec_watts(building.spec)
	return 0.0


## Whether [param cell] carries current — a wall with a line in it, a
## pylon's strung post, or a generator's own terminals. The water
## wheel's hub conducts too — its shaft is where the watts come off.
func _power_conductor(cell: Vector3i) -> bool:
	var building: Building = buildings.get(cell)
	return (
		building != null
		and (
			building.conduit
			or building.kind == Building.Kind.PYLON
			or building.kind == Building.Kind.GENERATOR
			or building.kind == Building.Kind.WATER_WHEEL
		)
	)


## Watts a conductor-node produces this tick — a fuelled generator's
## full rating, or the wheel's read of the flux through its cell.
## Everything else carries current but makes none.
func _producer_watts(building: Building) -> float:
	if building.kind == Building.Kind.GENERATOR and building.fuel > 0.0:
		return GENERATOR_WATTS
	if building.kind == Building.Kind.WATER_WHEEL:
		return _wheel_watts(building)
	return 0.0


## The wheel's output — the accumulated outflow the last water step
## left on its cell, converted at the perpetual-motion-safe rate.
## Still water turns nothing; rapids pay.
func _wheel_watts(building: Building) -> float:
	if world == null or world.sim == null:
		return 0.0
	var flux: Vector3i = world.sim.water_flux_at(building.voxel)
	return minf(flux.length() * WHEEL_W_PER_CM3, WHEEL_MAX_WATTS)


## One tick over the site's power nets: conductors — conduit walls,
## pylons and generator cells — flood into nets; each net's fuelled
## generators spend their watts on the devices touching the net,
## cheapest-cell-first so the brownout order is deterministic, and
## `building.powered` lands on whatever current actually reached. A
## running heater then rolls its fire chance — a metal housing smokes
## rarely, a wooden one is the hazard the spec warns about.
func _power_tick(elapsed: float) -> void:
	var devices: Array[Building] = []
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building):
			continue
		if (
			building.kind == Building.Kind.HEATER
			or building.kind == Building.Kind.COOLER
			or device_watts(building) > 0.0
		):
			seen[building] = true
			devices.append(building)
			building.powered = false
	var visited := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if visited.has(cell) or not _power_conductor(cell):
			continue
		# Flood one net.
		var comp := {}
		var queue: Array[Vector3i] = [cell]
		visited[cell] = true
		var watts := 0.0
		while not queue.is_empty():
			var at: Vector3i = queue.pop_back()
			comp[at] = true
			var node: Building = buildings.get(at)
			if node != null:
				watts += _producer_watts(node)
			for dir in Flooring.FACE_DIRS:
				var next := at + dir
				if _power_conductor(next) and not visited.has(next):
					visited[next] = true
					queue.append(next)
		if watts <= 0.0:
			continue
		# Spend the net's watts on the devices that touch it — a device
		# ties in beside any conductor cell, so a machine parked against
		# a wired wall or a strung pylon works.
		var adjacent: Array[Building] = []
		for device in devices:
			if device.powered:
				continue
			var touches := false
			for dcell in device.footprint:
				for dir in Flooring.FACE_DIRS:
					if comp.has(dcell + dir):
						touches = true
						break
				if touches:
					break
			if touches:
				adjacent.append(device)
		adjacent.sort_custom(
			func(a: Building, b: Building) -> bool:
				return (
					a.voxel.x * 65536 + a.voxel.y * 256 + a.voxel.z
					< b.voxel.x * 65536 + b.voxel.y * 256 + b.voxel.z
				)
		)
		for device in adjacent:
			var draw := device_watts(device)
			if draw <= watts:
				watts -= draw
				device.powered = true
	# Powered pumps translate into the sim's pump records — a running
	# pump moves water this same step; unpowered ones stand down, and
	# an unoriented one (no face picked) is dead plumbing.
	if world != null and world.sim != null:
		for device in devices:
			if device.kind != Building.Kind.PUMP:
				continue
			var rate := 0
			if device.powered and device.face_dir != Vector3i.ZERO:
				rate = PUMP_CM3_STEP
			world.sim.water_set_pump(
				device.voxel + device.face_dir,
				device.voxel - device.face_dir,
				rate
			)
	# A running heater's fault roll — the housing decides the odds:
	# a plank casing is the kindling the spec warned about.
	for device in devices:
		if device.kind != Building.Kind.HEATER or not device.powered:
			continue
		var wooden := false
		for item in device.components:
			if item.form == DropItem.Form.PLANK:
				wooden = true
				break
		var chance := (
			HEATER_FIRE_CHANCE_WOOD if wooden else HEATER_FIRE_CHANCE
		)
		if randf() < chance * elapsed:
			ignite(device.voxel)


## One tick of the site's weather-to-room climate: the outdoor
## temperature comes from the weather model, the biome mean is its
## annual baseline for now (a regional biome temperature is future
## work); rooms equalize across their boundaries in rooms.gd, and the
## powered devices move heat here — the heater pours into its room,
## the cooler pumps from its cold face to its hot one plus a little
## compressor waste.
func _climate_tick(elapsed: float) -> void:
	var outdoor := weather.temperature_c(day_cycle)
	rooms.tick_temperature(elapsed, outdoor, Weather.MEAN_C)
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building):
			continue
		seen[building] = true
		# Open flame warms the air on its own account — a lit campfire
		# heats its room whether or not the power net knows it. The
		# generator's enclosed firebox doesn't count — its waste heat
		# is the combustion, not the room.
		if building.lit() and building.kind != Building.Kind.GENERATOR:
			var warm_room := rooms.room_at(building.voxel)
			if warm_room != null:
				if not is_nan(warm_room.temperature):
					warm_room.temperature += (
						FLAME_HEAT * elapsed
						/ maxf(1.0, rooms.volume_of(warm_room))
					)
				# An indoor fire smokes its room whether it's wild or
				# tended — slow enough that a vented room keeps up, a
				# sealed one doesn't.
				warm_room.smoke = minf(
					1.0,
					(
						0.0
						if is_nan(warm_room.smoke)
						else warm_room.smoke
					) + SMOKE_PER_CAMPFIRE * elapsed
						/ maxf(1.0, rooms.volume_of(warm_room))
				)
		if not building.powered:
			continue
		if building.kind == Building.Kind.HEATER:
			var room := rooms.room_at(building.voxel)
			if room != null and not is_nan(room.temperature):
				room.temperature += (
					HEATER_POWER * elapsed
					/ maxf(1.0, rooms.volume_of(room))
				)
		elif (
			building.kind == Building.Kind.COOLER
			and building.face_dir != Vector3i.ZERO
		):
			var moved := COOLER_POWER * elapsed
			var cold := rooms.room_at(building.voxel + building.face_dir)
			var hot := rooms.room_at(building.voxel - building.face_dir)
			if cold != null and not is_nan(cold.temperature):
				cold.temperature -= moved / maxf(1.0, rooms.volume_of(cold))
			if hot != null and not is_nan(hot.temperature):
				hot.temperature += (
					moved * 1.15 / maxf(1.0, rooms.volume_of(hot))
				)
	# A wildfire cell indoors pours far more heat than any lamp while
	# it burns — a room on fire is a furnace, and a smokey one at
	# that: the haze the flames throw off vents through the same
	# boundary the heat does.
	for fire_cell: Vector3i in _fires:
		var froom := rooms.room_at(fire_cell)
		if froom != null:
			if not is_nan(froom.temperature):
				froom.temperature += (
					WILDFIRE_HEAT * elapsed
					/ maxf(1.0, rooms.volume_of(froom))
				)
			froom.smoke = minf(
				1.0,
				(0.0 if is_nan(froom.smoke) else froom.smoke)
					+ SMOKE_PER_FIRE * elapsed
					/ maxf(1.0, rooms.volume_of(froom))
			)
	rooms.tick_smoke(elapsed)


## The air temperature at [param cell] — the room's uniform
## temperature indoors, the weather's ambient out. What units read
## when the needs model asks how warm the ground under them is.
func temperature_at(cell: Vector3i) -> float:
	return rooms.temperature_at(cell, weather.temperature_c(day_cycle))


## The live refuel job at [param voxel_position], or null.
func refuel_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.REFUEL
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## Posts a "refuel campfire" job for the fire at [param voxel_position]
## — a unit fetches a load of fuel and feeds the fire. Refuses when the
## job is already out, the fire is coming down, or no pile anywhere
## holds burnable material; the last check keeps a fuel-less colony
## from posting work nobody can do.
func request_refuel(voxel_position: Vector3i) -> ColonyJob:
	var building := fueled_at(voxel_position)
	if building == null:
		return null
	if (
		refuel_job_at(voxel_position) != null
		or deconstruct_job_at(voxel_position) != null
	):
		return null
	if nearest_fuel_voxel(voxel_position) == Vector3i.MAX:
		return null
	var job := ColonyJob.new(ColonyJob.Type.REFUEL, voxel_position)
	_register_job(job)
	DLog.log("refuel %s %s" % [building.label(), voxel_position])
	job_added.emit(job)
	return job


## A delivered load joins the fire — burn-seconds, capped. What the
## job's unit hauled is consumed on arrival; over-cap burn is lost
## rather than banked.
func complete_refuel(job: ColonyJob, seconds: float) -> void:
	var building := fueled_at(job.voxel_position)
	if building != null:
		building.fuel = minf(building.fuel + seconds, fuel_cap_of(building))
		if building.kind == Building.Kind.CAMPFIRE:
			_sync_campfire_light(job.voxel_position)
	_finish_job(job)


## The pile a refuel job should fetch from — the densest fuel within a
## soft distance band: burn-seconds on the pile divided by distance in
## metres, floor 8 m, so a log pile beats a leaf pile unless the leaves
## are drastically closer. PROVISIONAL: this is the fuel-selection
## policy — when fuels diversify (coal, charcoal, dung) it may want
## per-fuel preferences or a stockpile admission flag instead.
func nearest_fuel_voxel(
	from: Vector3i, skip: Dictionary = {}, area: AllowedArea = null,
	far_ok := false
) -> Vector3i:
	var now := game_msec()
	var best := Vector3i.MAX
	var best_score := 0.0
	var best_home := Vector3i.MAX
	var best_home_score := 0.0
	for voxel: Vector3i in item_piles:
		if not in_area(area, voxel):
			continue
		var seconds := 0.0
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			seconds += DropItem.fuel_seconds_of(item)
			if item.is_container():
				# A sack of charcoal scores like loose stock — the
				# fetch can carry the bag whole.
				for inner in item.stored:
					seconds += DropItem.fuel_seconds_of(inner)
		if seconds <= 0.0:
			continue
		var record: Dictionary = skip.get(voxel, {})
		if not record.is_empty() and now - int(record.get("at", 0)) < retry_delay_msec(record):
			continue
		var dist := Vector3(voxel).distance_to(Vector3(from))
		var score := seconds / maxf(dist, 8.0)
		if score > best_score:
			best_score = score
			best = voxel
		# The home-area preference: the best fuel inside the area beats
		# anything outside it, whatever the score — like the indexed
		# queries' FRESH-over-RETRY demotion.
		if home_cells.has(voxel) and score > best_home_score:
			best_home_score = score
			best_home = voxel
	if far_ok or best_home == Vector3i.MAX:
		return best
	return best_home


## How well lit [param voxel_position] is by burning campfires — a 0..1
## radial falloff out to [constant CAMPFIRE_LIGHT_RADIUS]. This is the
## query the deferred work-light rules will consume; daylight lives in
## [method daylight_at] and is a separate concern.
func illumination_at(voxel_position: Vector3i) -> float:
	var best := 0.0
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if seen.has(building) or not building.lit():
			continue
		seen[building] = true
		var dist := Vector3(voxel_position).distance_to(
			Vector3(building.voxel) + Vector3(0.5, 0.5, 0.5)
		)
		if dist <= CAMPFIRE_LIGHT_RADIUS:
			best = maxf(best, 1.0 - dist / CAMPFIRE_LIGHT_RADIUS)
	return best


## Points the campfire's OmniLight child at the fire's current lit
## state — created on demand so unlit fires cost nothing but the mesh.
func _sync_campfire_light(voxel_position: Vector3i) -> void:
	var marker: MeshInstance3D = _designation_markers.get(voxel_position)
	if marker == null:
		return
	var building := campfire_at(voxel_position)
	var light := marker.get_node_or_null("Fire") as OmniLight3D
	if building == null:
		if light != null:
			light.queue_free()
		return
	if light == null:
		light = OmniLight3D.new()
		light.name = "Fire"
		light.omni_range = CAMPFIRE_LIGHT_RADIUS
		light.light_color = Color(1.0, 0.62, 0.30)
		light.light_energy = 1.4
		light.position = Vector3(0.0, 0.35, 0.0)
		marker.add_child(light)
	light.visible = building.lit()


## The closest bed with a berth free and no pending teardown, or null —
## a unit about to rest claims it through `claim_bed`, and a double
## bed still answers while one sleeper occupies it.
func nearest_free_bed(from: Vector3i, area: AllowedArea = null) -> Building:
	var best: Building = null
	var best_sq := INF
	var seen := {}
	for cell in buildings:
		var bed: Building = buildings[cell]
		if (
			bed.kind != Building.Kind.BED
			or not bed.bed_vacancy()
			or seen.has(bed)
			or deconstruct_job_at(bed.voxel) != null
			or not in_area(area, bed.voxel)
		):
			continue
		seen[bed] = true
		var sq := Vector3(cell - from).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = bed
	return best


## Queues a felling job for the tree containing [param voxel_position] —
## any part of it resolves to the root, which is what the unit chops.
func designate_chop(voxel_position: Vector3i) -> ColonyJob:
	var root := forest.tree_root_at(voxel_position)
	var snag: Array[Vector3i] = []
	if root == Vector3i.MAX:
		# No record claims the cell — an orphan snag (tree blocks a fell
		# left standing when its chunk was unstreamed) is still choppable,
		# keyed on the designated voxel itself.
		snag = forest._orphan_voxels(voxel_position)
		if snag.is_empty():
			return null
		root = voxel_position
	if cell_claimed(root, Occ.DESIGNATION):
		return null

	var job := ColonyJob.new(ColonyJob.Type.CHOP, root)
	if not snag.is_empty():
		job.extra_voxels = snag
	_register_job(job)
	_add_marker(root, _marker_material)
	DLog.log("designated chop %s" % root)
	job_added.emit(job)
	return job


## A chop job's finish: the whole tree comes down — every part voxel is
## removed and its contents spilled as items where they stood.
func fell_tree(job: ColonyJob) -> void:
	forest.fell(job.voxel_position)
	_finish_job(job)


## A chop job whose tree vanished under the unit is simply done.
func complete_chop(job: ColonyJob) -> void:
	_finish_job(job)


## Queues a foraging job for the bush at [param voxel_position] — a unit
## strips its ripe yield and drops the food where it stands for hauling.
## Only a ripe bush can be designated; an unripe one bears again on its
## own clock (see plants.gd).
func designate_forage(voxel_position: Vector3i) -> ColonyJob:
	var root := plants.bush_at(voxel_position)
	if root == Vector3i.MAX or cell_claimed(root, Occ.DESIGNATION):
		return null
	if not plants.can_forage(root):
		return null

	var job := ColonyJob.new(ColonyJob.Type.FORAGE, root)
	_register_job(job)
	_add_marker(root, _forage_marker_material)
	DLog.log("designated forage %s" % root)
	job_added.emit(job)
	return job


## Queues a cut-plant job — the removal order for a bush the colony
## wants gone rather than harvested: a live bush can be cut whether or
## not it bears, and the plant dies to it. Dead plants compost on their
## own and take no designation.
func designate_cut_plant(voxel_position: Vector3i) -> ColonyJob:
	var root := plants.bush_at(voxel_position)
	if root == Vector3i.MAX or cell_claimed(root, Occ.DESIGNATION):
		return null
	var rec: Dictionary = plants.bushes.get(root, {})
	if rec.is_empty() or rec.get(&"dead", false):
		return null
	var job := ColonyJob.new(ColonyJob.Type.FORAGE, root)
	job.cut = true
	_register_job(job)
	_add_marker(root, _forage_marker_material)
	DLog.log("designated cut %s" % root)
	job_added.emit(job)
	return job


## A forage job's finish: the bush's yield becomes physical food items at
## its cell — haulable like anything else. A `cut` job takes the plant
## with the fruit — the yield still lands, scaled by growth.
func complete_forage(job: ColonyJob) -> void:
	var drops: Array[DropItem] = (
		plants.cut(job.voxel_position)
		if job.cut
		else plants.forage(job.voxel_position)
	)
	for item in drops:
		_drop_item(item, job.voxel_position)
	_finish_job(job)


## A sow job's finish: the fetched seed packet becomes an immature plant
## — a sapling for tree species, a bush otherwise. Planting turns the
## sod, so the grass under the cell dies. A cell that filled up in the
## meantime hands the packet back rather than eating it.
func complete_sow(job: ColonyJob, seed: DropItem) -> void:
	var cell := job.voxel_position
	var planted := false
	if Forest.species_table().has(job.species):
		planted = forest.plant_sapling(cell, job.species)
	else:
		planted = plants.plant(cell, job.species)
	if planted:
		if grass != null:
			grass.bare(cell + Vector3i.DOWN)
	elif seed != null:
		_drop_item(seed, cell)
	_finish_job(job)


## The voxel of the nearest pile holding a seed packet of
## [param species] — the sow job's fetch query. Seeds are species-tagged
## discrete items; an untagged or foreign packet doesn't count.
func nearest_seed_voxel(
	from: Vector3i, species: StringName, area: AllowedArea = null,
	far_ok := false
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, _home_match(func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			if _is_seed_of(item, species):
				return _Match.FRESH
			if item.is_container():
				# A seed pouch advertises its packets — the sower
				# carries it whole and draws the seed at the field.
				for inner in item.stored:
					if _is_seed_of(inner, species):
						return _Match.FRESH
		return _Match.VETO, far_ok), area)


## True when [param item] is a seed packet of [param species] — the
## sow gate's per-item test, shared by the loose scan and the look
## inside pouches.
func _is_seed_of(item: DropItem, species: StringName) -> bool:
	return item.form == DropItem.Form.SEED and item.species == species


## True when a seed packet of [param species] exists anywhere in the
## colony's piles — the farm's sow gate.
func _seed_exists(species: StringName) -> bool:
	for voxel: Vector3i in item_piles:
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			if _is_seed_of(item, species):
				return true
			if item.is_container():
				for inner in item.stored:
					if _is_seed_of(inner, species):
						return true
	return false


## The periodic farm-field pass: for every field, post a sow job per
## cell that could take the assigned crop (gated on a seed packet
## existing anywhere), a forage job per ripe shrub, and — tree fields
## with auto-chop on — a chop job per mature in-field tree. Cells with
## a live farm job are left alone; finished ones drop out of the index.
func _farm_tick() -> void:
	var seen := {}
	for cell: Vector3i in farms:
		var field: FarmField = farms[cell]
		if seen.has(field):
			continue
		seen[field] = true
		_tick_field(field)
	_fertilize_scan()


## The fertilize-job generator, run on the farm scan's cadence: painted
## marks repost until their soil reaches the mark's target, and each
## auto-fertilizing field posts for cells below its own. One job per
## cell — marks and fields never double-post the same ground.
func _fertilize_scan() -> void:
	var composted := _compost_exists()
	for cell: Vector3i in fertilize_marks.keys():
		if not _fertilizable_soil(cell):
			_clear_fertilize_mark(cell)
			continue
		if (
			effective_fertility(cell + Vector3i.DOWN)
			>= float(fertilize_marks[cell])
		):
			_clear_fertilize_mark(cell)
			continue
		_post_fertilize(cell, float(fertilize_marks[cell]), composted)
	var seen := {}
	for cell: Vector3i in farms:
		var field: FarmField = farms[cell]
		if seen.has(field):
			continue
		seen[field] = true
		if not field.auto_fertilize:
			continue
		for fcell: Vector3i in field.cells:
			if (
				fertilize_marks.has(fcell)
				or not _fertilizable_soil(fcell)
				or (
					effective_fertility(fcell + Vector3i.DOWN)
					>= field.fertilize_target
				)
			):
				# A painted mark already drives the cell — and at its
				# own target, which always wins.
				continue
			_post_fertilize(fcell, field.fertilize_target, composted)


## The shared posting path for mark- and field-driven fertilize jobs:
## refresh a live job's target and larder state, else open a new one.
func _post_fertilize(
	cell: Vector3i, target: float, composted: bool
) -> void:
	var job: ColonyJob = _fertilize_jobs.get(cell)
	if job != null:
		if job.is_active():
			job.fertilize_target = target
			if job.suspended != not composted:
				# A job waiting on an empty larder wakes when compost
				# exists again — same quiet-wait as a seedless sow.
				job.suspended = not composted
				if world.sim != null:
					world.sim.job_suspend(
						job.get_instance_id(), job.suspended
					)
			return
		_fertilize_jobs.erase(cell)
	var new_job := ColonyJob.new(ColonyJob.Type.FERTILIZE, cell)
	new_job.fertilize_target = target
	_register_job(new_job)
	if not composted:
		# Posted hungry — a unit claiming it would just fetch, fail and
		# suspend anyway, so it waits on the board from the start.
		new_job.suspended = true
		if world.sim != null:
			world.sim.job_suspend(new_job.get_instance_id(), true)
	_fertilize_jobs[cell] = new_job
	job_added.emit(new_job)


func _tick_field(field: FarmField) -> void:
	if field.species == &"":
		return
	var is_tree := Forest.species_table().has(field.species)
	var seeded := _seed_exists(field.species)
	for cell: Vector3i in field.cells:
		var job: ColonyJob = _farm_jobs.get(cell)
		if job != null:
			if job.is_active():
				# A sow waiting on a seed that vanished goes quiet
				# instead of churning through give-ups — the next
				# seeded scan wakes it.
				if job.type == ColonyJob.Type.SOW and job.suspended != not seeded:
					job.suspended = not seeded
					if world.sim != null:
						world.sim.job_suspend(
							job.get_instance_id(), job.suspended
						)
				continue
			_farm_jobs.erase(cell)
		if is_tree:
			# Only a tree rooted inside the field chops — canopy cells
			# belonging to a neighbour's tree are just occupied. An
			# occupied cell never sows; an empty one falls through to
			# the sow gate (which enforces the 3×3 spacing rule).
			var root := forest.tree_root_at(cell)
			if root != Vector3i.MAX:
				if (
					field.auto_chop and root == cell
					and forest.mature(root)
				):
					_farm_jobs[cell] = _post_farm_job(
						ColonyJob.Type.CHOP, root, field
					)
				continue
		else:
			var bush := plants.bush_at(cell)
			if bush != Vector3i.MAX:
				var rec: Dictionary = plants.bushes.get(bush, {})
				if (
					rec.get(&"species") == field.species
					and plants.can_forage(bush)
				):
					_farm_jobs[cell] = _post_farm_job(
						ColonyJob.Type.FORAGE, bush, field
					)
				continue
		if not seeded or not _sowable(cell, is_tree):
			continue
		_farm_jobs[cell] = _post_farm_job(ColonyJob.Type.SOW, cell, field)


## A farm-generated job: posted on the board like any other, but the
## zone's own marker stays — the job borrows the cell, it doesn't
## redesignate it.
func _post_farm_job(type: ColonyJob.Type, voxel: Vector3i, field: FarmField) -> ColonyJob:
	var job := ColonyJob.new(type, voxel)
	job.species = field.species
	_register_job(job)
	job_added.emit(job)
	return job


## Whether the farm cell can take a sowing right now: open air, no pile,
## no building, dirt underfoot — the sprout rules' soil requirement —
## and, for trees, the spacing rule: no plant in the cell or the eight
## around it, same as a fruit sprouting in the wild. Light and soil
## fertility modulate growth rather than gate sowing (item 20);
## weather arrives with roadmap items 31/38.
func _sowable(cell: Vector3i, is_tree: bool) -> bool:
	if not world.is_editable(cell):
		return false
	if world.get_block(cell) != BlockRegistry.Block.AIR:
		return false
	if voxel_fill(cell) > 0:
		return false
	if BlockRegistry.fertilizability(world.get_block(cell + Vector3i.DOWN)) <= 0.0:
		return false
	if cell_claimed(cell, Occ.BUILDING):
		return false
	# Item-53 — standing water deeper than a skim refuses seed: a
	# flooded field isn't a field. A damp one is fine — moisture shapes
	# growth, not eligibility.
	if (
		world.sim != null
		and world.sim.water_volume_at(cell) > SOW_WATER_MAX
	):
		return false
	if is_tree:
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if cell_claimed(
					cell + Vector3i(dx, 0, dz), Occ.TREE | Occ.BUSH
				):
					return false
		return true
	return not cell_claimed(cell, Occ.TREE | Occ.BUSH)


## The voxel of the nearest pile holding anything edible — where a hungry
## unit goes to eat. [param skip] blacklists recently-failed piles — an
## expired failure is only picked when no fresh pile is in reach.
func nearest_food_pile(
	from: Vector3i, skip: Dictionary = {}, area: AllowedArea = null,
	far_ok := false
) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(from, _pile_buckets, _home_match(func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			var edible := DropItem.is_food(item.material)
			if not edible and item.is_container():
				# A sack of meals answers a hungry seek the same — the
				# eater bites straight out of the bag.
				for inner in item.stored:
					if DropItem.is_food(inner.material):
						edible = true
						break
			if not edible:
				continue
			var record: Dictionary = skip.get(voxel, {})
			if record.is_empty():
				return _Match.FRESH
			if now - int(record.get("at", 0)) < retry_delay_msec(record):
				return _Match.VETO
			return _Match.RETRY
		return _Match.VETO, far_ok), area)


## The voxel of the nearest ripe bush with no job on it — where a
## starving unit goes when no edible pile exists. Player-designated
## bushes (marked) are left to their orders; desperation doesn't compete
## with designations. [param skip] blacklists recently-failed bushes the
## same way [member nearest_food_pile] skips piles. Linear over
## `plants.bushes` — desperation is rare, and the scaling note in
## PLAN.md already flags per-cell scans for a spatial index later.
func nearest_ripe_bush(
	from: Vector3i, skip: Dictionary = {}, area: AllowedArea = null
) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(
		from, plants.bush_buckets,
		func(root: Vector3i) -> int:
			if (
				cell_claimed(root, Occ.DESIGNATION)
				or not plants.can_forage(root)
			):
				return _Match.VETO
			# Desperation wants food — a ripe heal-all is medicine, not
			# a meal; stripping it would leave the unit still starving.
			var rec: Dictionary = plants.bushes[root]
			var yield_mat: int = (
				Plants.species_table()[rec[&"species"]][&"yield_material"]
			)
			if not DropItem.is_food(yield_mat):
				return _Match.VETO
			var record: Dictionary = skip.get(root, {})
			if record.is_empty():
				return _Match.FRESH
			if now - int(record.get("at", 0)) < retry_delay_msec(record):
				return _Match.VETO
			return _Match.RETRY,
		area
	)


## How long a dropped target stays off-limits: doubles with each
## consecutive failure ([param record] is {at: msec, n: drops}), capped —
## a permanently impossible target goes quiet instead of being hammered.
func retry_delay_msec(record: Dictionary) -> int:
	var attempts := int(record.get("n", 1))
	return mini(
		DROPPED_JOB_RETRY_MSEC * (1 << (attempts - 1)),
		DROPPED_JOB_RETRY_MAX_MSEC
	)


## The voxel of the nearest pile eligible for hauling — not fully admitted
## by its stockpile tile (a pile holding rejected items wants hauling
## away), not recently failed ([param skip] maps voxel → {at, n}).
## A pile the unit failed before comes last: it is only picked once its
## retry delay has elapsed and no fresh pile is in reach.
func nearest_haulable_pile(
	from: Vector3i, skip: Dictionary = {}, area: AllowedArea = null,
	far_ok := false
) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(from, _pile_buckets, _home_match(func(voxel: Vector3i) -> int:
		# A pile whose every item is forbidden is un-touchable — the
		# flag means "leave it", whatever the filters would say. A stale
		# bucket key reads null and vetoes out.
		var pile := item_pile_at(voxel)
		if pile == null or not pile.has_takeable():
			return _Match.VETO
		if stockpiles.has(voxel) and not _pile_rejected_here(voxel):
			return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY, far_ok), area)


## The best stockpile tile that can hold [param load] more cubic
## centimetres, or Vector3i.MAX. RimWorld's rule: the highest-priority
## zone wins, ties broken by distance — so a far Critical zone beats a
## close Normal one. When [param materials] is given, a tile must admit
## at least one of them. [param skip] blacklists recently-failed tiles —
## a fresh tile at any rank outranks an expired failure.
func nearest_stockpile_with_room(
	from: Vector3i, load: int, skip: Dictionary = {}, materials: Array = [],
	area: AllowedArea = null, forms: Array = []
) -> Vector3i:
	var now := game_msec()
	var best := Vector3i.MAX
	var best_rank := -1
	var best_sq := INF
	var retry := Vector3i.MAX
	var retry_rank := -1
	var retry_sq := INF
	for key in _stockpile_buckets:
		for voxel: Vector3i in _stockpile_buckets[key]:
			if not in_area(area, voxel):
				continue
			if voxel_fill(voxel) + load > voxel_capacity(voxel):
				continue
			# Goods-class rules ride the forms list: a crate only ever
			# qualifies at a warehouse cell.
			if forms.has(int(DropItem.Form.CRATE)):
				var zone := stockpiles[voxel]
				if zone == null or not zone.warehouse:
					continue
			if not materials.is_empty():
				var admits_any := false
				for material in materials:
					if stockpile_admits(voxel, material):
						admits_any = true
						break
				if not admits_any:
					continue
			var rank := int(stockpiles[voxel].priority)
			var sq := (Vector3(voxel) - Vector3(from)).length_squared()
			var record: Dictionary = skip.get(voxel, {})
			if record.is_empty():
				if rank > best_rank or (rank == best_rank and sq < best_sq):
					best_rank = rank
					best_sq = sq
					best = voxel
				continue
			if now - int(record.get("at", 0)) < retry_delay_msec(record):
				continue
			if rank > retry_rank or (rank == retry_rank and sq < retry_sq):
				retry_rank = rank
				retry_sq = sq
				retry = voxel
	return best if best != Vector3i.MAX else retry


## Frees the pile at [param voxel_position] when it's been emptied, settling
## whatever may be piled on top.
func remove_pile_if_empty(voxel_position: Vector3i) -> void:
	var pile := item_pile_at(voxel_position)
	if pile != null and pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
		if _rock_slots.erase(voxel_position):
			# A generated rock pile picked clean — the slot is spent and
			# won't restock when its block re-streams.
			_rock_spent[voxel_position] = true
		_settle_pile_at(voxel_position + Vector3i.UP)


## Mirrors the voxel's pile fill into the native sim so its fill-aware
## pathing and spill searches see the same occupancy — loose fill and
## clutter go separately: only loose raises footing, clutter slows and
## chokes instead. Packed derives from the total, no separate flag.
func _sync_sim_packed(voxel_position: Vector3i) -> void:
	if world.sim == null:
		return
	var pile: ItemPile = item_piles.get(voxel_position)
	world.sim.set_pile_fill(
		voxel_position,
		pile.loose_volume() if pile != null else 0,
		pile.clutter_volume() if pile != null else 0
	)


## Loose fill piled in [param voxel_position] in cm³ — the floor-
## raising fraction only (0 for a solid block, which reports its own
## metre).
func pile_loose_fill(voxel_position: Vector3i) -> int:
	if world.sim != null:
		return int(world.sim.pile_loose_at(voxel_position))
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile.loose_volume() if pile != null else 0


## Clutter piled in [param voxel_position] in cm³ — the discrete
## fraction that slows passage and chokes the cell when dense.
func pile_clutter_fill(voxel_position: Vector3i) -> int:
	if world.sim != null:
		return int(world.sim.pile_clutter_at(voxel_position))
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile.clutter_volume() if pile != null else 0


## True when discrete goods choke [param voxel_position] enough to
## stand in the way — walked around, not through, and read as flimsy
## cover in a scuffle.
func is_dense_pile(voxel_position: Vector3i) -> bool:
	if world.sim != null:
		return world.sim.is_dense(voxel_position)
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile != null and pile.is_dense()


## True when [param voxel_position]'s top surface is ground a unit can
## stand on — a solid block, or a loose mound compacted full. A heap of
## discrete goods, however dense, offers no footing.
func is_flooring(voxel_position: Vector3i) -> bool:
	if world.is_solid(voxel_position):
		return true
	return pile_loose_fill(voxel_position) >= voxel_capacity(voxel_position)


func _on_pile_fill_changed(pile: ItemPile) -> void:
	# An in-flight pile isn't keyed under its voxel yet; the resident pile
	# (if any) owns the packed state until it lands.
	if item_piles.get(pile.voxel_position) == pile:
		_sync_sim_packed(pile.voxel_position)
		# A shrinking pile can pull the floor out from under the pile
		# resting on it — re-settle the voxel above. No-op while the
		# floor still holds.
		_settle_pile_at(pile.voxel_position + Vector3i.UP)


## The voxel of the nearest pile holding material a wall can use —
## [param material] specifically, or any wall material when NONE.
## [param need] is the recipe still missing (form → cm³): only piles
## holding items the wall can still absorb qualify.
func nearest_wall_voxel(
	from: Vector3i, material: BlockRegistry.Resource_,
	need: Dictionary = {}, area: AllowedArea = null, far_ok := false
) -> Vector3i:
	var want := need
	if want.is_empty() and material != BlockRegistry.Resource_.NONE:
		# No remaining-need passed: the wall wants its whole recipe.
		want = BlockRegistry.wall_recipe(material)
	return _nearest_indexed(from, _pile_buckets, _home_match(func(voxel: Vector3i) -> int:
		var pile := item_pile_at(voxel)
		return _Match.FRESH if pile != null and pile.wall_need_volume(material, want) > 0 else _Match.VETO,
		far_ok), area)


## Why a wall fetch came up empty for [param material]'s remaining
## [param want] — the board line the player reads when the job drops.
## "No materials" when nothing anywhere fits; the forbidden count when
## every matching pile is flag-locked; "can't be reached" when usable
## stock exists but no path/area allows the trip.
func wall_failure_reason(
	material: BlockRegistry.Resource_, want: Dictionary
) -> String:
	var usable := 0
	var locked := 0
	for voxel: Vector3i in item_piles:
		var pile := item_piles[voxel]
		usable += pile.wall_need_volume(material, want)
		locked += (
			pile.wall_need_volume(material, want, true)
			- pile.wall_need_volume(material, want)
		)
	if usable + locked == 0:
		return "no materials in reach"
	# Count in the want's leading unit — blocks read as items, loose as m³.
	var amount := func(volume_cm3: int) -> String:
		if want.has(DropItem.Form.BLOCK):
			return "%d blocks" % (volume_cm3 / DropItem.STONE_BLOCK_CM3)
		if want.has(DropItem.Form.LOOSE):
			return "%.1f m³" % (volume_cm3 / 1000000.0)
		return "%d cm³" % volume_cm3
	if usable == 0:
		return (
			"no usable materials — all %s are forbidden"
			% amount.call(locked)
		)
	return (
		"materials exist but can't be reached — %s usable, %s forbidden"
		% [amount.call(usable), amount.call(locked)]
	)


## The voxel of the nearest pile holding an item of [param form] — the
## fetch query for a craft job's input.
func nearest_form_voxel(
	from: Vector3i, form: DropItem.Form, area: AllowedArea = null,
	include_forbidden := false, far_ok := false
) -> Vector3i:
	return nearest_forms_voxel(
		from, [form], Vector3i.MAX, 0.0, {}, {}, area, include_forbidden,
		false, far_ok
	)


## The voxel of the nearest pile holding a usable tool of a class in
## [param classes] — the fetch query for a job whose requirement the
## unit can't already satisfy. Worn-out shells and forbidden tools
## don't count.
func nearest_tool_voxel(
	from: Vector3i, classes: Array, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if (
				item.form == DropItem.Form.TOOL
				and not item.forbidden
				and classes.has(DropItem.tool_class(item))
				and item.wear > 0.0
			):
				return _Match.FRESH
		return _Match.VETO, area)


## The voxel of the nearest pile holding a corpse of at most
## [param max_kg] — a butcher job's fetch query: only carcasses the
## assignee can drag count.
func nearest_corpse_voxel(
	from: Vector3i, max_kg: float, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if (
				item.form == DropItem.Form.CORPSE
				and not item.forbidden
				and item.mass_kg() <= max_kg
				# A settler's corpse isn't butcher stock — only
				# species with yields go on the slab.
				and Species.spec(item.species).has(&"yields")
			):
				return _Match.FRESH
		return _Match.VETO, area)


## The voxel of the nearest pile holding an item of any of [param forms]
## — the fetch query when a recipe still wants more than one kind of
## input. [param rejected_materials] (int keys) excludes piles holding
## only disallowed-material items, [param required_materials] (form →
## material) pins a form to one material when the recipe does, and
## [param radius] > 0 around [param centre] restricts the search — the
## bill's ingredient range.
func nearest_forms_voxel(
	from: Vector3i,
	forms: Array,
	centre: Vector3i = Vector3i.MAX,
	radius: float = 0.0,
	rejected_materials: Dictionary = {},
	required_materials: Dictionary = {},
	area: AllowedArea = null,
	include_forbidden := false,
	include_stored := false,
	far_ok := false,
	wear_bounds := Vector2(0.0, 1.0)
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, _home_match(func(voxel: Vector3i) -> int:
		if (
			radius > 0.0 and centre != Vector3i.MAX
			and Vector3(voxel).distance_to(Vector3(centre)) > radius
		):
			return _Match.VETO
		var pile := item_pile_at(voxel)
		if pile == null:
			return _Match.VETO
		for item in pile.items:
			if item.forbidden and not include_forbidden:
				continue
			if _fetch_item_matches(
				item, forms, rejected_materials, required_materials,
				wear_bounds
			):
				return _Match.FRESH
			if include_stored and item.is_container():
				# Goods inside a bag advertise themselves — the fetch
				# can carry the whole container and unpack at the site.
				# A furniture crate's `packed` stays hidden: that's the
				# piece itself, only the whole crate matches (above).
				for inner in item.stored:
					if _fetch_item_matches(
						inner, forms, rejected_materials,
						required_materials, wear_bounds
					):
						return _Match.FRESH
		return _Match.VETO, far_ok), area)


## One item's match against [method nearest_forms_voxel]'s filters —
## form membership, the bill's material rejections, and whatever pin
## the slot carries (material id, material set, garment spec, or a
## custom predicate). Shared by the top-level scan and the look inside
## containers.
func _fetch_item_matches(
	item: DropItem, forms: Array, rejected_materials: Dictionary,
	required_materials: Dictionary,
	wear_bounds := Vector2(0.0, 1.0)
) -> bool:
	if not forms.has(item.form):
		return false
	if rejected_materials.get(int(item.material), false):
		return false
	if item.wear < wear_bounds.x or item.wear > wear_bounds.y:
		return false
	var pin: Variant = required_materials.get(item.form)
	if pin == null:
		return true
	if pin is int:
		return item.material == pin
	if pin is Array:
		return pin.has(item.material)
	if pin is StringName:
		return item.spec == pin
	if pin is Callable:
		return bool(pin.call(item))
	return false


## True when anything is designated at [param voxel_position] — the cancel
## tool's validity check.
func is_designated(voxel_position: Vector3i) -> bool:
	return _designation_markers.has(voxel_position)


## Cancels the order queued at a worksite — the site itself stays.
## The panel's task-level cancel; the site goes away via deconstruct.
## Inputs the order already escrowed drop back at the spot.
func cancel_craft_order(voxel_position: Vector3i) -> void:
	var job := craft_job_at(voxel_position)
	if job == null:
		return
	# The running order leaves the queue too — cancelling just the job
	# would re-dispatch the same bill on the next scan.
	if job.order != null:
		var building: Building = buildings.get(voxel_position)
		if building != null:
			building.orders.erase(job.order)
	_cancel_job(job)


func cancel_designation(voxel_position: Vector3i) -> void:
	# Clicking any part of a designated tree cancels the chop job at its
	# root.
	var root := forest.tree_root_at(voxel_position)
	var target := root if root != Vector3i.MAX else voxel_position
	for job in jobs:
		if (
			job.is_active()
			and (
				job.voxel_position == target
				or job.extra_voxels.has(target)
			)
		):
			# Escrowed items — wall material, craft inputs — drop back
			# into the world rather than vanishing with the job.
			_return_escrow(job)
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
			if job.face_dir != Vector3i.ZERO:
				_remove_face_marker(
					job.voxel_position, Flooring.face_index(job.face_dir)
				)
			for cell in job.extra_voxels:
				_remove_marker(cell)
			if job.voxel_position != target:
				# Clicked an extra cell — the anchor's marker goes too.
				_remove_marker(job.voxel_position)
	var zone := stockpile_at(voxel_position)
	var shelf := building_at(voxel_position)
	if zone != null and (
		shelf == null
		or (
			shelf.kind != Building.Kind.SHELF
			and shelf.kind != Building.Kind.COMPOST_BIN
		)
	):
		zone.cells.erase(voxel_position)
		# A shelf's zone isn't a designation — cancel skips it; the
		# building's own teardown removes the cells.
		if stockpiles.erase(voxel_position):
			_index_remove(_stockpile_buckets, voxel_position)
	var field := farm_at(voxel_position)
	if field != null:
		field.cells.erase(voxel_position)
		farms.erase(voxel_position)
	if fertilize_marks.has(voxel_position):
		# A painted mark is a designation like the others — the cancel
		# sweep lifts it, job included.
		_clear_fertilize_mark(voxel_position)
	var building: Building = buildings.get(target)
	if building != null:
		# A building is a construction, not a designation — the cancel
		# sweep only lifts its pending tasks (a craft order, a deconstruct
		# marking). The site itself comes down via deconstruct. Every
		# footprint cell's marker goes back — a deconstruct tint had
		# recolored them all.
		building.orders.clear()
		for cell in building.footprint:
			_restore_worksite_marker(cell)
	else:
		_remove_marker(target)
	_prune_jobs()


## Best-scoring open job for [param unit], claimed for it. A job the unit
## dropped before comes last: it is only claimable once its retry delay
## has elapsed and no other open job exists — a unit always tries a
## different job before retrying one it failed.
func claim_job(unit: Unit) -> ColonyJob:
	var now := game_msec()
	var type_scores := _claim_type_scores(unit)
	if world.sim != null:
		# The native board picks by score without knowing bill-level
		# eligibility (worker pins, skill bands) — suspend the jobs the
		# unit may not take for the duration of the call rather than
		# dropping the pick, which would write a colony-wide backoff.
		var hidden: Array[ColonyJob] = []
		for job in jobs:
			if job.is_open() and job_block_reason(unit, job) != "":
				job.suspended = true
				world.sim.job_suspend(job.get_instance_id(), true)
				hidden.append(job)
		var job_id: int = world.sim.job_claim(
			unit.get_instance_id(), unit.global_position, now,
			DROPPED_JOB_RETRY_MSEC, DROPPED_JOB_RETRY_MAX_MSEC,
			type_scores, CLAIM_DIST_WEIGHT,
			CLAIM_LANGUISH_RATE, CLAIM_LANGUISH_CAP
		)
		for job in hidden:
			job.suspended = false
			world.sim.job_suspend(job.get_instance_id(), false)
		var claimed: ColonyJob = _job_index.get(job_id)
		if claimed == null:
			return null
		claimed.state = ColonyJob.State.ASSIGNED
		claimed.assignee = unit
		return claimed
	var best: ColonyJob = null
	var best_score := INF
	var retry: ColonyJob = null
	var retry_score := INF
	for job in jobs:
		if not job.is_open():
			continue
		if job_block_reason(unit, job) != "":
			continue
		# Cooling off colony-wide: a job that keeps getting dropped backs
		# off for everyone, not just the unit that failed it.
		var global: Dictionary = job.dropped_by.get(0, {})
		if not global.is_empty() and now - int(global.get("at", 0)) < retry_delay_msec(global):
			continue
		var score := (
			Vector3(job.voxel_position).distance_to(unit.global_position)
			* CLAIM_DIST_WEIGHT
			- type_scores[job.type]
			- _languish_bonus(job, now)
		)
		var record: Dictionary = job.dropped_by.get(unit, {})
		if record.is_empty():
			if score < best_score:
				best_score = score
				best = job
			continue
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			continue
		if score < retry_score:
			retry_score = score
			retry = job
	var chosen := best if best != null else retry
	if chosen != null:
		chosen.state = ColonyJob.State.ASSIGNED
		chosen.assignee = unit
	return chosen


## Why [param unit] may not work [param job] — "" when it may. The
## bill-level gates the job board can't see: a worker-pinned bill
## accepts only that unit, and a skill band accepts only levels inside
## it. Jobs that never came through a worksite queue (builds orders,
## designations) are open. claim_job reads this to hide ineligible
## jobs; the Work tab's job board shows the same reason per unit.
func job_block_reason(unit: Unit, job: ColonyJob) -> String:
	# The allowed-area gate: a restricted unit only works cells its area
	# covers. Orders are player-forced, so ORDER jobs skip the gate.
	if (
		unit.allowed_area != null
		and job.type != ColonyJob.Type.ORDER
		and not unit.allowed_area.cells.has(job.voxel_position)
	):
		return "outside allowed area"
	# A hunt whose quarry died, fled the map or never linked (a job
	# restored without its animal) is unclaimable — the corpse is
	# butcher work, the job gets pruned.
	if job.type == ColonyJob.Type.HUNT and (
		job.animal == null
		or not is_instance_valid(job.animal)
		or job.animal.dead
	):
		return "quarry dead or gone"
	# A tame dies with its mark too — or completes the moment someone
	# else finishes it: a domestic animal is no longer a job. An
	# enraged mark can't be worked either; it calms or it doesn't.
	if job.type == ColonyJob.Type.TAME:
		if (
			job.animal == null
			or not is_instance_valid(job.animal)
			or job.animal.dead
		):
			return "mark dead or gone"
		if job.animal.domestic:
			return "already tamed"
		if job.animal.enraged():
			return "mark enraged"
	# Surgery is the strictest care of all — a billed patient who
	# isn't lying on an established medical bed is no operation at
	# all. And nobody operates on themselves.
	if job.type == ColonyJob.Type.SURGERY:
		var patient: Unit = job.patient
		if patient == unit:
			return "can't operate on self"
		if (
			patient == null
			or not is_instance_valid(patient)
			or patient.dead
			or patient.surgery_bills.is_empty()
		):
			return "patient dead, gone or unbilled"
		if not _patient_on_medical_bed(patient):
			return "patient not in a medical bed"
	# Medical jobs die with their patient — and nobody self-tends.
	if job.type == ColonyJob.Type.TEND:
		var patient: Unit = job.patient
		if patient == unit:
			return "can't tend self"
		if (
			patient == null
			or not is_instance_valid(patient)
			or patient.dead
			or patient.wounds.is_empty()
		):
			return "patient dead, gone or healed"
	if job.type == ColonyJob.Type.RESCUE:
		var patient: Unit = job.patient
		if patient == unit:
			return "can't rescue self"
		if (
			patient == null
			or not is_instance_valid(patient)
			or patient.dead
			or patient._carried_by != null
			or patient.state != Unit.State.DOWNED
		):
			return "patient dead, gone, carried or standing"
		# Too heavy to drag is too heavy to rescue — a stronger
		# unit can still take the job.
		if patient.mass_kg() > unit._drag_kg():
			return "patient too heavy to drag"
	# An arrest lives exactly as long as the rampage does — and nobody
	# grabs themselves.
	if job.type == ColonyJob.Type.ARREST:
		var patient: Unit = job.patient
		if patient == unit:
			return "can't arrest self"
		if (
			patient == null
			or not is_instance_valid(patient)
			or patient.dead
			or not patient._berserk
		):
			return "nobody to arrest"
	# Knowledge gates: a job carrying `required_skill` (a charcoal burn)
	# or running a `requires` recipe (a smelt) belongs only to workers
	# with basic knowledge of it — level 1, the first XP band. Technology
	# is held by people, not the colony.
	if job.required_skill >= 0 and unit.skill_level(job.required_skill) < 1:
		return "needs %s" % ColonyJob.SKILL_NAMES.get(
			job.required_skill, "a skill"
		)
	if job.type == ColonyJob.Type.TEACH:
		var student: Unit = job.patient
		if student == unit:
			return "can't teach self"
		if (
			student == null
			or not is_instance_valid(student)
			or student.dead
		):
			return "student dead or gone"
		if teachable_skill(unit, student) < 0:
			return "nothing left to teach"
	# The recipe's knowledge gate applies whether or not the job came
	# through a worksite queue — the powered machines are `builds`
	# recipes (Electrician/HVAC ratings), the smelts are worksite bills.
	# A worker without basic knowledge can't claim it at all.
	if job.type == ColonyJob.Type.CRAFT and not recipe_of(job.recipe).is_empty():
		for skill_req: int in recipe_requires(recipe_of(job.recipe)):
			if unit.skill_level(skill_req) < 1:
				return "needs %s" % ColonyJob.SKILL_NAMES.get(
					skill_req, "a skill"
				)
	var order := job.order
	if order == null:
		return ""
	if order.worker_index >= 0 and (
		order.worker_index < units.size()
		and units[order.worker_index] != unit
	):
		return "pinned to %s" % units[order.worker_index].name
	if job.type == ColonyJob.Type.CRAFT and not recipe_of(job.recipe).is_empty():
		var recipe: Dictionary = recipe_of(job.recipe)
		var skill := int(ColonyJob.SKILL_FOR.get(job.type, -1))
		skill = int(recipe.get("skill", skill))
		# A study bill is remedial — a master has nothing left to learn
		# from the specimen and never claims the job.
		if recipe.get(&"study", false) and unit.skill_level(skill) >= 10:
			return "already mastered"
		if skill >= 0:
			var level := unit.skill_level(skill)
			if level < order.skill_min or level > order.skill_max:
				return "needs %s %d-%d" % [
					ColonyJob.SKILL_NAMES.get(skill, "a skill"),
					order.skill_min, order.skill_max
				]
	return ""


## The bool view of job_block_reason — claim_job's eligibility gate
## and the test suite's seam, kept so callers that only need
## allowed/blocked don't read the phrasing.
func _job_allowed_for(unit: Unit, job: ColonyJob) -> bool:
	return job_block_reason(unit, job).is_empty()


## The board's own read on [param job] — assignment, suspension cause
## and colony-wide cooldown — for the Work tab's job list. Per-unit
## gates stay in job_block_reason; this is deliberately unit-free so a
## row answers "is anything doing it" before "who could".
func job_board_status(job: ColonyJob) -> String:
	if job.state == ColonyJob.State.ASSIGNED:
		return "assigned to %s" % (
			job.assignee.name if job.assignee != null else "?"
		)
	if job.state != ColonyJob.State.PENDING:
		return ""
	if job.suspended:
		# Suspension carries no recorded cause — the few producers each
		# map cleanly onto the job's own shape.
		if job.order != null and job.order.paused:
			return "blocked: bill paused"
		match job.type:
			ColonyJob.Type.SOW:
				return "blocked: waiting for seed"
			ColonyJob.Type.FERTILIZE:
				return "blocked: waiting for compost"
			ColonyJob.Type.BUILD:
				return "blocked: unsupported cell"
		return "blocked: suspended"
	# Cooling off colony-wide: a job that keeps getting dropped backs
	# off for everyone, not just the unit that failed it.
	var global: Dictionary = job.dropped_by.get(0, {})
	if not global.is_empty():
		var wait := retry_delay_msec(global) - (
			game_msec() - int(global.get("at", 0))
		)
		if wait > 0:
			var why := String(global.get("why", ""))
			return "cooling off %ds (dropped %dx%s)" % [
				(wait + 999) / 1000, int(global.get("n", 1)),
				"" if why.is_empty() else ": " + why,
			]
	return "open"


## The skill [param teacher] could pass to [param student]: the one with
## the widest level gap, or −1 when the student already matches the
## teacher everywhere. Teaching transfers XP until the student draws
## level — competency up to the teacher's own, per the knowledge model.
static func teachable_skill(teacher: Unit, student: Unit) -> int:
	var best := -1
	var best_gap := 0
	for skill: int in ColonyJob.Skill.values():
		var gap := teacher.skill_level(skill) - student.skill_level(skill)
		if gap > best_gap:
			best_gap = gap
			best = skill
	return best


## Per-type skill bonus for [param unit] — metres-equivalent of distance
## each job type is worth to it, indexed by [constant ColonyJob.Type].
## Unskilled types score zero, and a specialist's weight dwarfs a
## generalist's.
func _claim_type_scores(unit: Unit) -> PackedFloat64Array:
	var weight := (
		CLAIM_SKILL_SPECIALIZE if unit.specialize else CLAIM_SKILL_GENERALIZE
	)
	var scores := PackedFloat64Array()
	scores.resize(ColonyJob.Type.size())
	var skill_types: Array = ColonyJob.SKILL_FOR.keys()
	for skill_type: ColonyJob.Type in skill_types:
		var skill: ColonyJob.Skill = ColonyJob.SKILL_FOR[skill_type]
		scores[skill_type] = weight * unit.skill_level(skill)
	# Firefighting outranks every discipline — a flat urgency bonus,
	# not a skill read.
	scores[ColonyJob.Type.FIREFIGHT] = CLAIM_FIREFIGHT_BONUS
	# The designated role argues for its lane — additive on top of the
	# skill read, so a specialist still outbids it up close.
	for type: ColonyJob.Type in ROLES.get(unit.role, []):
		scores[type] += CLAIM_ROLE_BONUS
	return scores


## Metres-equivalent the job's age is worth — capped so a long-waiting
## job gets attractive but not infinitely so.
func _languish_bonus(job: ColonyJob, now: int) -> float:
	var age := maxf(now - job.posted_msec, 0.0) / 1000.0
	return minf(age, CLAIM_LANGUISH_CAP) * CLAIM_LANGUISH_RATE


func release_job(job: ColonyJob, reason := "") -> void:
	if job.state == ColonyJob.State.ASSIGNED:
		var now := game_msec()
		var record: Dictionary = job.dropped_by.get(job.assignee, {})
		record["at"] = now
		record["n"] = int(record.get("n", 0)) + 1
		# The failure's own words — the job board shows it beside the
		# retry countdown so "dropped" answers "why".
		if not reason.is_empty():
			record["why"] = reason
		job.dropped_by[job.assignee] = record
		# A colony-wide drop record too: a job nobody can finish shouldn't
		# carousel between units — each failure backs it off for everyone.
		var global: Dictionary = job.dropped_by.get(0, {})
		global["at"] = now
		global["n"] = int(global.get("n", 0)) + 1
		if not reason.is_empty():
			global["why"] = reason
		job.dropped_by[0] = global
		if world.sim != null:
			world.sim.job_drop(
				job.get_instance_id(), job.assignee.get_instance_id(), now
			)
		job.state = ColonyJob.State.PENDING
		job.assignee = null


func complete_job(job: ColonyJob, mined_block_id: int) -> void:
	# A wall that gets dug out stops being a building — its recorded
	# components go to the generic shatter like everything else mined.
	var building: Building = buildings.get(job.voxel_position)
	if building != null:
		for cell in building.footprint:
			buildings.erase(cell)
			if world.sim != null:
				if building.kind == Building.Kind.LADDER:
					world.sim.set_ladder(cell, false)
				elif building.kind == Building.Kind.DOOR:
					world.sim.set_door(cell, false)
				elif building.kind == Building.Kind.FENCE:
					world.sim.set_fence(cell, false)
				elif building.kind == Building.Kind.SPIKE_TRAP:
					world.sim.set_trap(cell, false)
				elif building.kind == Building.Kind.FLOODGATE:
					_apply_floodgate_edges(cell, 1.0)
				elif building.kind == Building.Kind.PUMP:
					world.sim.water_set_pump(
						cell + building.face_dir, cell - building.face_dir, 0
					)
	else:
		buildings.erase(job.voxel_position)
	drop_block(mined_block_id, job.voxel_position)
	_finish_job(job)


## A clearing job is done once its voxel holds no pile.
func complete_clear(job: ColonyJob) -> void:
	_finish_job(job)


## A build job is done once the block is in place — or, for a door, once
## the frame is hung: the cell stays open air with a building record over
## it, and the rounding overcharge drops at the site as offcut. Either
## way the record carries the material class and the exact items that
## went in, for deconstruction and material-tinted rendering.
func complete_build(job: ColonyJob) -> void:
	var is_door := BlockRegistry.spec_is_door(job.build_spec)
	var building := Building.new(
		Building.Kind.DOOR if is_door else Building.Kind.WALL,
		job.voxel_position
	)
	if is_door:
		# The doorway's headroom cell is part of the building — it stays
		# open air, but it's claimed so nothing else can fill it.
		building.footprint.append(job.voxel_position + Vector3i.UP)
	building.spec = job.build_spec
	building.block_id = job.block_id
	building.material = job.material
	building.components = job.components
	# A packed-dirt wall is indistinguishable from natural ground — it
	# has to be mined out like terrain, not taken apart.
	building.deconstructable = job.material != BlockRegistry.Resource_.SOIL
	register_building(building)
	if is_door:
		# The offcut — what the rounded-up recipe over-delivered past the
		# quarter surcharge — drops at the site as sawdust or gravel.
		var offcut := BlockRegistry.spec_offcut(job.build_spec)
		if offcut > 0:
			_drop_item(
				DropItem.new(job.material, DropItem.Form.LOOSE, offcut),
				job.voxel_position
			)
	_finish_job(job)


func _finish_job(job: ColonyJob) -> void:
	job.state = ColonyJob.State.DONE
	# Completing a job trains its discipline — the assignee is still
	# attached here (released on the next line). Unskilled types map to
	# -1 and earn nothing. Work gated on a technology trains that
	# technology — a conduit install's lesson is electrical, not
	# masonry, and a generator repair is electrician's work.
	var skill: int = ColonyJob.SKILL_FOR.get(job.type, -1)
	if job.required_skill >= 0:
		skill = job.required_skill
	var xp := float(ColonyJob.XP_FOR.get(job.type, 0.0))
	if job.type == ColonyJob.Type.CRAFT and not recipe_of(job.recipe).is_empty():
		# A recipe may re-tune the lesson — cooking trains Cooking, not
		# Crafting, and a meal is worth less than a sawn plank run.
		var recipe: Dictionary = recipe_of(job.recipe)
		skill = int(recipe.get("skill", skill))
		xp = float(recipe.get("xp", xp))
		if recipe.get(&"study", false) and job.assignee != null:
			# Studying pays the make lesson scaled down by what the
			# student already knows — nothing left at level 10.
			xp = study_xp(recipe, job.assignee.skill_level(skill))
	if skill >= 0 and job.assignee != null:
		job.assignee.gain_skill_xp(skill, xp)
	job.assignee = null
	# A surface job's marker rides its face key, not a voxel key.
	if job.face_dir != Vector3i.ZERO:
		_remove_face_marker(job.voxel_position, Flooring.face_index(job.face_dir))
	# Every cell the job covered — a furnish plan's second cell included —
	# restores its building's standing look or drops its marker outright.
	for cell in [job.voxel_position] + job.extra_voxels:
		var building: Building = buildings.get(cell)
		if building != null:
			# The job is done but the construction stands — its marker
			# goes back to showing the building rather than the task.
			_restore_worksite_marker(cell)
		elif farms.has(cell):
			# Farm cells keep their zone marker — an auto job only
			# borrowed the cell, the field still owns it.
			pass
		else:
			_remove_marker(cell)
	job_finished.emit(job)
	_prune_jobs()


## Every unit's decision trail — the snapshot line and recorded
## transitions — one block per unit. The overseer's debug dump (F9)
## writes this to the clipboard and a user:// file.
func unit_diagnostics() -> String:
	var parts := PackedStringArray()
	for unit in units:
		parts.append(unit.decision_trail())
	return "\n\n".join(parts)


## Drops the loot of [param block_id] into the world as [ItemPile]s, letting
## each item spill into neighboring voxels that still have room.
func drop_block(block_id: int, voxel_position: Vector3i) -> void:
	# The cell's rubble is out — any battering it took dies with it.
	_block_damage.erase(voxel_position)
	# Ore tailings take the column's own country rock — the site field
	# knows the bedrock kind under this voxel.
	var host := BlockRegistry.rock_material_of(
		world.generator_script.field_rock_block_at(
			voxel_position.x, voxel_position.z
		)
	)
	for item in DropItem.for_block(block_id, host):
		_drop_item(item, voxel_position)


## Drops [param item] into [param voxel_position]. Part or all of it may spill
## into an adjacent voxel: the spill probability is the voxel's occupancy plus
## half the item's own volume. Loose items split proportionally — the spill
## fraction moves on — while solid items move whole. Moved items re-roll the
## same check at their new voxel, so drops settle downward and sideways.
func _drop_item(item: DropItem, voxel_position: Vector3i, hops: int = 0) -> void:
	if hops >= MAX_SPILL_HOPS:
		_deposit_item(item, voxel_position)
		return
	if item.form == DropItem.Form.LOOSE and item.volume < MIN_LOOSE_CM3:
		_deposit_item(item, voxel_position)
		return

	# The spill probability — a fraction of a voxel — while the moved
	# amount stays integer cm³.
	var spill := (voxel_fill(voxel_position) + item.volume / 2.0) / DropItem.CM3_PER_M3
	var target := _spill_target(voxel_position)
	if item.form == DropItem.Form.LOOSE:
		var moved := 0 if target == voxel_position else int(minf(spill, 1.0) * item.volume)
		var kept := item.volume - moved
		if kept > 0:
			var kept_item := DropItem.new(item.material, item.form, kept)
			kept_item.species = item.species
			_deposit_item(kept_item, voxel_position)
		if moved > 0:
			item.volume = moved
			_drop_item(item, target, hops + 1)
	elif randf() < spill and target != voxel_position:
		_drop_item(item, target, hops + 1)
	else:
		_deposit_item(item, voxel_position)


## The voxel an item spills into: straight down if it has room, otherwise any
## of the four orthogonal sides. Returns the voxel itself when every neighbor
## is fully occupied, in which case the item just squeezes in where it is.
func _spill_target(voxel_position: Vector3i) -> Vector3i:
	if world.sim != null:
		return world.sim.spill_target(voxel_position)
	var below := voxel_position + Vector3i.DOWN
	if not is_packed(below):
		return below
	var sides := SPILL_SIDES.duplicate()
	sides.shuffle()
	for side in sides:
		var neighbor: Vector3i = voxel_position + side
		if not is_packed(neighbor):
			return neighbor
	return voxel_position


## Portion of [param voxel_position]'s space occupied in cubic centimetres:
## a full cubic metre when the voxel holds a solid block, otherwise the
## volume of the items piled in it.
func voxel_fill(voxel_position: Vector3i) -> int:
	if world.sim != null:
		return int(world.sim.fill_of(voxel_position))
	if world.is_solid(voxel_position):
		return DropItem.BLOCK_CM3
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile.total_volume() if pile != null else 0


## Occupancy flags for [method cell_claimed] — every claim a voxel can
## carry that terrain solidity can't see. A cell-claiming system adds a
## flag here and a clause below once, and each caller picks the mask
## naming the claims *it* can't coexist with — retiring the per-pair
## pile/tree checks every new claim source used to re-derive (the PLAN
## "occupancy" follow-up). Terrain questions — solid, water, editable —
## stay the caller's; these flags are everything blocks aren't.
enum Occ {
	PILE = 1,        ## an ItemPile holding goods
	PACKED = 2,      ## a pile filled to capacity — movement-blocking
	BUILDING = 4,    ## an entity building (door, campfire, furniture)
	TREE = 8,        ## a forest claim — root, trunk, or canopy cell
	UNIT = 16,       ## a unit's capsule — feet or head voxel
	DESIGNATION = 32, ## a queued designation marker
	LADDER = 64,     ## a ladder building specifically
	ZONE = 128,      ## a land-use zone — stockpile or farm
	BUSH = 256,      ## a forageable bush's claim on its root cell
}


## Whether any of the flagged claims hold at [param voxel_position] —
## the shared "cell claimed" predicate. The mask names what the caller
## can't share with: a wall wants `DESIGNATION|BUILDING|PACKED|TREE`,
## a ladder leaves `PACKED` out because it shares its cell with piles,
## a sapling asks only `PILE`. Cheap dictionary claims run first; the
## unit scan runs last since it walks the roster.
func cell_claimed(voxel_position: Vector3i, mask: int) -> bool:
	if mask & Occ.PILE:
		var pile := item_pile_at(voxel_position)
		if pile != null and pile.total_volume() > 0:
			return true
	if mask & Occ.PACKED:
		if world.sim != null:
			if bool(world.sim.is_packed(voxel_position)):
				return true
		else:
			var packed: ItemPile = item_piles.get(voxel_position)
			if (
				packed != null
				and packed.is_full(voxel_capacity(voxel_position))
			):
				return true
	if mask & Occ.BUILDING and buildings.has(voxel_position):
		return true
	if mask & Occ.LADDER and ladder_at(voxel_position):
		return true
	if mask & Occ.DESIGNATION and _designation_markers.has(voxel_position):
		return true
	if mask & Occ.ZONE and (
		is_stockpile(voxel_position) or farms.has(voxel_position)
	):
		return true
	if mask & Occ.TREE and (
		forest != null
		and forest.tree_root_at(voxel_position) != Vector3i.MAX
	):
		return true
	if mask & Occ.BUSH and (
		plants != null
		and plants.bush_at(voxel_position) != Vector3i.MAX
	):
		return true
	if mask & Occ.UNIT:
		for unit in units:
			if unit.occupies(voxel_position):
				return true
	return false


## True when the voxel is effectively solid — a real block or packed with a
## full cubic metre of items. Packed voxels are impassible to units and act
## as a floor for anything falling or standing above them. Dense clutter
## isn't packed — it blocks units without being full.
func is_packed(voxel_position: Vector3i) -> bool:
	if world.sim != null:
		return world.sim.is_solid(voxel_position) or world.sim.is_packed(
			voxel_position
		)
	if world.is_solid(voxel_position):
		return true
	var pile: ItemPile = item_piles.get(voxel_position)
	return pile != null and pile.is_full(voxel_capacity(voxel_position))


func _deposit_item(item: DropItem, voxel_position: Vector3i, seen := {}) -> void:
	var fit := _pile_room_under_stander(item, voxel_position)
	if fit < item.volume and not seen.has(voxel_position):
		# Some or all of the deposit can't land here without burying a
		# stander — keep what fits (loose pours partway, discrete moves
		# whole) and evict the rest to the nearest accepting tile. `seen`
		# guards the eviction walk: two guarded cells mustn't bounce the
		# same item between them forever.
		seen[voxel_position] = true
		if fit > 0 and item.form == DropItem.Form.LOOSE:
			var part := DropItem.new(item.material, item.form, fit)
			part.species = item.species
			part.nutrition = item.nutrition
			_deposit_into(part, voxel_position)
			item.volume -= fit
		var evict := _accepting_voxel(item, voxel_position)
		if evict != Vector3i.MAX and not seen.has(evict):
			_deposit_item(item, evict, seen)
		else:
			_deposit_into(item, voxel_position)
		return
	_deposit_into(item, voxel_position)


## Drops [param item] onto the voxel's pile, creating it when needed.
func _deposit_into(item: DropItem, voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		pile = ItemPile.create(voxel_position, world.sim == null)
		add_child(pile)
		pile.landed.connect(_on_pile_landed)
		pile.fill_changed.connect(_on_pile_fill_changed)
		item_piles[voxel_position] = pile
		_index_add(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		item_dropped.emit(pile)
	pile.add_item(item)
	_settle_pile_at(voxel_position)
	_enforce_capacity(pile.voxel_position)


## How much of [param item] may pile at [param voxel_position] while
## somebody stands there — the caught-in-a-pile rules. Loose fill over a
## fifth of the cell lifts the stander; that's fine while the cell two
## up is free (they ride the pour), but a blocked cell over their head
## refuses the rest of the pour. Discrete goods can't choke the cell
## past the dense threshold around them either — a heap you can't wade
## out of is no place to stand. Returns the volume that may land; a
## discrete item is all-or-nothing by form.
func _pile_room_under_stander(item: DropItem, voxel_position: Vector3i) -> int:
	if not _someone_stands_at(voxel_position):
		return item.volume
	if item.form == DropItem.Form.LOOSE:
		var above := voxel_position + Vector3i(0, 2, 0)
		if is_packed(above) or is_dense_pile(above):
			return maxi(0, PILE_HEADROOM_CM3 - pile_loose_fill(voxel_position))
		return item.volume
	var room := DropItem.CLUTTER_BLOCK_CM3 - 1 - pile_clutter_fill(voxel_position)
	return mini(item.volume, maxi(0, room))


## True when a unit or animal's feet rest inside [param voxel_position].
func _someone_stands_at(voxel_position: Vector3i) -> bool:
	for unit in units:
		if unit._standing_voxel() == voxel_position:
			return true
	for animal in animals:
		if animal._standing_voxel() == voxel_position:
			return true
	return false


## Merges [param incoming] into [param pile] under the stander rules and
## returns the items that couldn't land — a falling pile arriving under
## someone's feet can't bury them any more than a direct pour can.
func _merge_guarded(pile: ItemPile, incoming: Array[DropItem]) -> Array[DropItem]:
	var evicted: Array[DropItem] = []
	for item in incoming:
		var fit := _pile_room_under_stander(item, pile.voxel_position)
		if fit >= item.volume:
			pile.add_item(item, false)
			continue
		if fit > 0 and item.form == DropItem.Form.LOOSE:
			var part := DropItem.new(item.material, item.form, fit)
			part.species = item.species
			part.nutrition = item.nutrition
			pile.add_item(part, false)
			item.volume -= fit
		evicted.append(item)
	return evicted


## True when [param voxel_position] acts as a floor for something falling
## onto it: packed solid, or holding a pile the incoming material can't
## merge into. Loose material ([param splittable]) can always pour into a
## pile that has any room left — the surplus overflows back onto it — but
## an unsplittable item that doesn't fit must rest on top, or it would
## fall in, overfill the pile and be pushed straight back out forever.
func _is_floor_for(voxel_position: Vector3i, volume: int, splittable: bool) -> bool:
	if is_packed(voxel_position):
		return true
	var resident: ItemPile = item_piles.get(voxel_position)
	if resident == null:
		return false
	if splittable:
		return false
	return resident.total_volume() + volume > voxel_capacity(voxel_position)


## The voxel an [param item] dropped at [param voxel_position] would
## actually come to rest in: the lowest voxel in its column whose floor
## supports it — the same walk [method _settle_pile_at] performs.
func _settle_floor(voxel_position: Vector3i, item: DropItem) -> Vector3i:
	var splittable := item.form == DropItem.Form.LOOSE
	if world.sim != null:
		return world.sim.settle_floor(voxel_position, item.volume, splittable)
	var landing := voxel_position
	var below := landing + Vector3i.DOWN
	while world.is_editable(below) and not _is_floor_for(below, item.volume, splittable):
		landing = below
		below = landing + Vector3i.DOWN
	return landing


## The nearest voxel that can hold [param item] without overfilling —
## [param needed] is the volume that must fit (the item's whole volume for
## a solid, or the surplus for a loose item). Adjoining voxels are tried
## first in the usual order (below, emptiest side, above); when none can
## take it the search expands outward from the voxel above. A boulder
## that won't fit a 95%-full hole can't just be pushed onto the voxel
## above — it would settle straight back down and bounce forever — so
## every candidate is judged by the voxel it would settle in, and landings
## back in the source voxel don't count. Packed candidates are skipped
## outright — an item can't be dropped into a solid block or full pile —
## and don't expand the outward search, so items can't tunnel under an
## obstacle into a pocket beneath it. Returns [constant Vector3i.MAX]
## when nothing has room (a loose item may return a nearer partial fit).
func _accepting_voxel(item: DropItem, voxel_position: Vector3i, needed := -1) -> Vector3i:
	if world.sim != null:
		return world.sim.accepting_voxel(
			voxel_position, item.volume, item.form == DropItem.Form.LOOSE, needed
		)
	# The volume that has to fit: a solid item needs its whole volume; a
	# loose item only needs what will actually move (the surplus), and can
	# settle for less — a fragment still moves.
	var want := mini(item.volume, needed) if needed >= 0 else mini(item.volume, voxel_capacity(voxel_position))
	var partial := Vector3i.MAX
	# Adjoining voxels first, in preference order — below, emptiest side,
	# then straight up — each judged by where the item would settle.
	var neighbors: Array[Vector3i] = [voxel_position + Vector3i.DOWN]
	var sides := SPILL_SIDES.duplicate()
	sides.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return (
				voxel_fill(voxel_position + a) < voxel_fill(voxel_position + b)
			)
	)
	for side in sides:
		neighbors.append(voxel_position + side)
	neighbors.append(voxel_position + Vector3i.UP)
	for candidate in neighbors:
		# A packed voxel can't be entered at all — an item dropped "into" it
		# would materialise inside the block or full pile, and _settle_floor
		# would happily land it in any open pocket underneath, tunnelling
		# the item through the obstacle.
		if is_packed(candidate):
			continue
		var landing := _settle_floor(candidate, item)
		if landing == voxel_position:
			continue
		var room := voxel_capacity(landing) - voxel_fill(landing)
		if room >= want:
			return landing
		if (
			partial == Vector3i.MAX
			and item.form == DropItem.Form.LOOSE
			and room > MIN_LOOSE_CM3
		):
			partial = landing
	# Nothing adjoining can take it — expand outward from the voxel above.
	var visited := {voxel_position: true}
	var queue: Array[Vector3i] = [voxel_position + Vector3i.UP]
	var head := 0
	while head < queue.size() and head < 4096:
		var candidate := queue[head]
		head += 1
		if visited.has(candidate):
			continue
		visited[candidate] = true
		# Packed voxels are walls to the search too: the item can't enter or
		# pass through one, so the cell doesn't expand the frontier — the
		# voxel on top of the obstacle is reached from the cells above it.
		if is_packed(candidate):
			continue
		var landing := _settle_floor(candidate, item)
		# A candidate that would settle back into the source can't accept the
		# item, but the search still expands through it — the rim of a hole is
		# only reachable past the cell above the hole.
		if landing != voxel_position:
			var room := voxel_capacity(landing) - voxel_fill(landing)
			if room >= want:
				return landing
			if (
				partial == Vector3i.MAX
				and item.form == DropItem.Form.LOOSE
				and room > MIN_LOOSE_CM3
			):
				partial = landing
		for side in SPILL_SIDES:
			queue.append(candidate + side)
		queue.append(candidate + Vector3i.UP)
		queue.append(candidate + Vector3i.DOWN)
	return partial


## Voxels mid-spill (re-entrancy guard) and already-spilled in this
## cascade — a pile may spill at most once per cascade, which is what
## stops a two-pile ping-pong from shuttling the same surplus forever.
var _enforcing := {}
var _enforced := {}


## A pile must never hold more than a cubic metre: split the excess off —
## smallest items first, cutting loose items down so only the surplus
## leaves — and move it to the nearest voxel that can accept it. Only when
## nowhere nearby has room does the surplus squeeze in anyway.
func _enforce_capacity(voxel_position: Vector3i) -> void:
	if _enforced.has(voxel_position):
		return
	_enforced[voxel_position] = true
	_enforcing[voxel_position] = true
	var moved := 0
	var capacity := voxel_capacity(voxel_position)
	for _i in 64:
		var pile: ItemPile = item_piles.get(voxel_position)
		if pile == null or pile.total_volume() <= capacity:
			break
		var excess := pile.total_volume() - capacity
		var item := pile.smallest_item()
		if item == null:
			break
		var needed := item.volume
		if item.form == DropItem.Form.LOOSE:
			needed = mini(item.volume, excess)
		# The pile keeps its contents while the excess searches for a landing:
		# an over-full voxel still counts as packed, so the cell above a
		# buried pile reads as resting on it rather than settling back into
		# the hole.
		var target := _accepting_voxel(item, voxel_position, needed)
		if target == Vector3i.MAX:
			break
		moved += 1
		item = pile.take_smallest()
		if item.form == DropItem.Form.LOOSE:
			var room := voxel_capacity(target) - voxel_fill(target)
			var moving := mini(excess, mini(item.volume, room))
			item.volume -= moving
			if item.volume > 0:
				pile.add_item(item, false)
			_deposit_item(DropItem.new(item.material, item.form, moving), target)
		else:
			_deposit_item(item, target)
	if moved >= 64:
		DLog.log(
			"enforce_capacity at %s capped after %d spills" % [voxel_position, moved]
		)
	_enforcing.erase(voxel_position)
	if _enforcing.is_empty():
		_enforced.clear()


## Mining removes the floor under whatever was piled above it: let it fall.
func _on_block_mined(position: Vector3i, _block_id: int) -> void:
	# Mined fuel stops burning — a fire on the cell dies with its block.
	if _fires.has(position):
		_extinguish(position)
	_settle_pile_at(position + Vector3i.UP)


## Terrain changed under rooms — drop the cached partition.
func _on_room_topology_changed(_cell: Vector3i, _block_id: int) -> void:
	if rooms != null:
		rooms.invalidate()


## Collapse is "deconstruct as if mined": the cell's jobs and building
## record die with the block, the mined rubble drops where it stood, and
## whatever was piled on top falls.
func _on_block_collapsed(cell: Vector3i, block_id: int) -> void:
	var building: Building = buildings.get(cell)
	if building != null:
		# Erase the record first so the cancel pass below clears the
		# cell's markers instead of restoring the construction's.
		for bc in building.footprint:
			buildings.erase(bc)
	cancel_designation(cell)
	if _fires.has(cell):
		_extinguish(cell)
	drop_block(block_id, cell)
	_settle_pile_at(cell + Vector3i.UP)


## A successful placement may be the support a suspended build was
## waiting on — check the six adjacent cells for held plans and put them
## back on the board.
func _on_block_placed(position: Vector3i, _block_id: int) -> void:
	for side in [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN,
		Vector3i.UP, Vector3i.BACK, Vector3i.FORWARD,
	]:
		var job := plan_job_at(position + side)
		if job != null and job.suspended:
			job.suspended = false
			if world.sim != null:
				world.sim.job_suspend(job.get_instance_id(), false)


## A streamed-in chunk can also be the missing support — a suspended
## plan near the frontier gets re-checked whenever new terrain arrives.
## It's also the arrival event for the generator's loose-rock slots:
## surface scree spawns as real piles so settlers start with free
## stone within reach.
## Stream-in backlog — the signal enqueues and `_physics_process`
## drains a slice per frame; a streaming burst no longer pays the
## whole set of handlers in one frame. Pop order doesn't matter —
## each block's bookkeeping is independent.
var _block_queue: Array = []


func _enqueue_world_block(block_origin: Vector3i) -> void:
	_block_queue.append(block_origin)


func _on_world_block_loaded(block_origin: Vector3i) -> void:
	var pt := Time.get_ticks_usec()
	for job in jobs:
		if job.suspended and would_be_supported(job.voxel_position):
			job.suspended = false
			if world.sim != null:
				world.sim.job_suspend(job.get_instance_id(), false)
	_seed_loose_rocks(block_origin)
	Perf.sample(&"colony.blocks", Time.get_ticks_usec() - pt)


## Drops the generator's loose-rock slots into this block as item piles
## — a few boulders and cobbles scattered on the surface, the colony's
## bootstrap stone before any mining runs. Each slot spawns once:
## `_rock_slots` tracks the live pile, and `remove_pile_if_empty`
## tombstones it into `_rock_spent` when it's picked clean so a
## re-streamed block doesn't restock it.
func _seed_loose_rocks(block_origin: Vector3i) -> void:
	var base := block_origin * 16
	var generator := world.generator_script
	# Rock piles sit one voxel above the surface — a block outside that
	# band holds none, so the lattice scan is skipped outright.
	if (
		base.y > generator.max_surface_height() + 1
		or base.y + 16 <= generator.min_surface_height() + 1
	):
		return
	var slots: Dictionary = generator.loose_rocks_in(base, 16)
	for pos: Vector2i in slots:
		var voxel := Vector3i(
			pos.x, generator.surface_height(pos.x, pos.y) + 1, pos.y
		)
		if _rock_spent.has(voxel) or _rock_slots.has(voxel):
			continue
		if cell_claimed(voxel, Occ.TREE):
			continue  # a tree claim beats the scree slot
		var resident := item_pile_at(voxel)
		if resident != null:
			# Something else already piles there — adopt it, so its
			# emptying spends the slot like a generated pile's.
			_rock_slots[voxel] = resident
			continue
		if world.get_block(voxel) != BlockRegistry.Block.AIR:
			continue  # somebody dug or built here since generation
		var counts: Dictionary = slots[pos]
		# Ore-bearing scree: the pile's material is the intrusion mineral
		# instead of plain stone — surface ore the colony can gather
		# before ever digging.
		var scree_material := int(counts.get(&"mineral", -1))
		if scree_material < 0:
			# Scree is the bedrock's own litter — the field's rock pick
			# for this cell, not generic stone.
			scree_material = BlockRegistry.rock_material_of(
				generator.field_rock_block_at(pos.x, pos.y)
			)
		for i in int(counts.get(&"boulders", 0)):
			_deposit_item(
				DropItem.new(
					scree_material,
					DropItem.Form.BOULDER, DropItem.BOULDER_CM3
				),
				voxel
			)
		for i in int(counts.get(&"cobbles", 0)):
			_deposit_item(
				DropItem.new(
					scree_material,
					DropItem.Form.COBBLE, DropItem.COBBLE_CM3
				),
				voxel
			)
		_rock_slots[voxel] = item_pile_at(voxel)


## Would a block placed at [param voxel_position] stand? A cell at the
## base level anchors itself; otherwise one solid face-neighbour is a
## full proof, since every standing solid is already anchored — the
## collapse rule removes any that aren't. Piles and ladders don't bear
## load; only blocks do.
func would_be_supported(voxel_position: Vector3i) -> bool:
	if voxel_position.y <= world.generator_script.bedrock_height:
		return true
	for side in [
		Vector3i.LEFT, Vector3i.RIGHT, Vector3i.DOWN,
		Vector3i.UP, Vector3i.BACK, Vector3i.FORWARD,
	]:
		if world.is_solid(voxel_position + side):
			return true
	return false


## Suspends a build job on an unsupported cell: the designation marker
## stays up (the plan is still wanted), the escrowed material stays with
## the job, and the job leaves the claimable pool until a neighbouring
## placement lifts the flag.
func suspend_build_job(job: ColonyJob) -> void:
	job.suspended = true
	job.state = ColonyJob.State.PENDING
	job.assignee = null
	if world.sim != null:
		world.sim.job_suspend(job.get_instance_id(), true)
	DLog.log("build at %s suspended — unsupported" % job.voxel_position)


## Lets the pile at [param voxel_position] fall through open space until it
## rests on solid ground. The logical voxel moves at once; the pile node
## falls visually and merges into whatever pile it lands on. Stops at the
## edge of loaded terrain rather than letting items drop into the void.
func _settle_pile_at(voxel_position: Vector3i) -> void:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		return
	var splittable := true
	for item in pile.items:
		if item.form != DropItem.Form.LOOSE:
			splittable = false
			break
	var landing := voxel_position
	if world.sim != null:
		landing = world.sim.settle_floor(voxel_position, pile.total_volume(), splittable)
	else:
		var below := landing + Vector3i.DOWN
		while world.is_editable(below) and not _is_floor_for(
			below, pile.total_volume(), splittable
		):
			landing = below
			below = landing + Vector3i.DOWN
	if landing == voxel_position:
		return
	item_piles.erase(voxel_position)
	_index_remove(_pile_buckets, voxel_position)
	_sync_sim_packed(voxel_position)
	pile.voxel_position = landing
	if item_piles.has(landing):
		# The landing voxel is claimed: keep this pile unkeyed until it
		# arrives, then merge it in.
		_in_flight.append(pile)
	else:
		item_piles[landing] = pile
		_index_add(_pile_buckets, landing)
		_sync_sim_packed(landing)
	pile.fall_to(float(landing.y))
	if world.sim != null:
		world.sim.pile_fall_start(
				pile.get_instance_id(), pile.position.y, float(landing.y),
				pile._fall_speed)
	# This pile just vacated its voxel — whatever rested on that voxel
	# lost its floor and may need to follow it down the column.
	_settle_pile_at(voxel_position + Vector3i.UP)


## A falling pile reached its voxel: fold it into the pile already there,
## or claim the voxel if it is empty — re-settling in case the floor gave
## out while it fell. Landing is reported by DelveSim.tick and (for
## presentation nodes) by the pile's own fall animation — whichever fires
## second is absorbed by the guard.
func _on_pile_landed(pile: ItemPile) -> void:
	if not is_instance_valid(pile) or pile.merged:
		return
	_in_flight.erase(pile)
	var resident: ItemPile = item_piles.get(pile.voxel_position)
	if resident == pile:
		return
	if resident != null:
		var leftover := _merge_guarded(resident, pile.items)
		pile.merged = true
		pile.queue_free()
		for item in leftover:
			var evict := _accepting_voxel(item, resident.voxel_position)
			if evict != Vector3i.MAX:
				_deposit_item(item, evict)
			else:
				resident.add_item(item, false)
		_enforce_capacity(resident.voxel_position)
		return
	item_piles[pile.voxel_position] = pile
	_index_add(_pile_buckets, pile.voxel_position)
	_sync_sim_packed(pile.voxel_position)
	_settle_pile_at(pile.voxel_position)
	_enforce_capacity(pile.voxel_position)


## Shoves a blocking pile aside: moves items out of an impassable voxel
## into neighbouring voxels until passage is restored — a unit digs
## through a packed pile or a dense heap that blocks its path. Returns
## false when the pile stays impassable because no neighbour has room.
func shove_pile(voxel_position: Vector3i) -> bool:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null:
		return true
	var capacity := voxel_capacity(voxel_position)
	while pile.is_full(capacity) or pile.is_dense():
		var item := pile.take_smallest()
		if item == null:
			break
		if _move_item_to(pile, item, voxel_position) == null:
			break
	if pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
	# Items piled above the cleared voxel may hover now — let them fall in.
	_settle_pile_at(voxel_position + Vector3i.UP)
	return not is_packed(voxel_position) and not is_dense_pile(voxel_position)


## Moves one item — the smallest — out of the pile at [param voxel_position]
## to the nearest voxel that can accept it. Returns the moved item, or null
## when the pile is empty or nowhere has room.
func move_pile_item(voxel_position: Vector3i) -> DropItem:
	var pile: ItemPile = item_piles.get(voxel_position)
	if pile == null or pile.items.is_empty():
		return null
	var item := pile.take_smallest_allowed()
	if item == null:
		return null
	var moved := _move_item_to(pile, item, voxel_position)
	if pile.items.is_empty():
		item_piles.erase(voxel_position)
		_index_remove(_pile_buckets, voxel_position)
		_sync_sim_packed(voxel_position)
		pile.queue_free()
		_settle_pile_at(voxel_position + Vector3i.UP)
	return moved


## Moves [param item] — or the part of it that fits — from [param pile] at
## [param voxel_position] to the nearest voxel with room for it. A loose
## item splits when only a partial fit is available; a solid item moves
## whole or not at all. Returns the moved piece, or null when nowhere has
## room (the item is put back).
func _move_item_to(
	pile: ItemPile, item: DropItem, voxel_position: Vector3i
) -> DropItem:
	var target := _accepting_voxel(item, voxel_position)
	if target == Vector3i.MAX:
		pile.add_item(item, false)
		return null
	var room := voxel_capacity(target) - voxel_fill(target)
	var moved := item
	if item.form == DropItem.Form.LOOSE and item.volume > room:
		moved = DropItem.new(item.material, item.form, room)
		item.volume -= room
		pile.add_item(item, false)
	_deposit_item(moved, target)
	return moved


func item_pile_at(voxel_position: Vector3i) -> ItemPile:
	# A deferred free can leave the key pointing at a dead pile until the
	# decay sweep reaps it — read through a Variant so the check never
	# throws on assignment.
	var raw: Variant = item_piles.get(voxel_position)
	if raw == null or not is_instance_valid(raw):
		return null
	return raw


## The items at [param voxel_position], or an empty list when the cell's
## pile is gone or the key is stale — for scans that must never trip on
## dead entries (`item_piles[v]` throws on both a missing key and a
## freed pile).
func _items_of(voxel_position: Vector3i) -> Array:
	var pile := item_pile_at(voxel_position)
	if pile == null:
		return []
	return pile.items


## Everything piled on stockpile tiles, tallied for the resources list —
## one entry per material class and item form: `{"material": r, "form": f,
## "count": n, "cm3": v}`.
func stockpile_contents() -> Array[Dictionary]:
	var tallies := {}
	for voxel in stockpiles:
		var pile := item_pile_at(voxel)
		if pile == null:
			continue
		for item in pile.items:
			# Species matters: oak and berry-bush seed packets are
			# different goods sharing one material+form.
			var key := "%d:%d:%s" % [
				int(item.material), int(item.form), item.species
			]
			var entry: Dictionary = tallies.get(
				key,
				{
					"material": item.material, "form": item.form,
					"species": item.species,
					"count": 0, "cm3": 0,
				}
			)
			entry["count"] += 1
			entry["cm3"] += item.volume
			tallies[key] = entry
	var contents: Array[Dictionary] = []
	for entry in tallies.values():
		contents.append(entry)
	contents.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			var ka := int(a["material"]) * 64 + int(a["form"])
			var kb := int(b["material"]) * 64 + int(b["form"])
			if ka != kb:
				return ka < kb
			return String(a["species"]) < String(b["species"])
	)
	return contents


func open_job_count() -> int:
	var count := 0
	for job in jobs:
		if job.is_active():
			count += 1
	return count


## The colony's rectangular bounds in x/z columns — the site's
## [member Site.bounds], handed over by Main so newcomer arrivals can
## resolve where a travel bearing crosses the edge.
var site_bounds := Rect2i()

## The scenario this colony is running — set at embark (or defaulting
## to the package's dev scenario for a direct boot) and serialized so a
## load keeps the same entry rules for later arrivals.
var scenario_id: StringName = &""

## The colony's founding instant on the game clock — the expectations
## bonus decays from full to nothing across the first days after it.
## -1 until the settlers land; old saves without it get a fresh grace.
var founded_msec := -1

## Bootstrap grace — RimWorld's "low expectations" ramp: new settlers
## expect hardship, not comfort, so mood floats a full [constant
## EXPECTATIONS_MAX] above the bare thought math at landing and the
## cushion decays linearly to zero across the window. A colony that
## never builds beds, tables or a cooking fire slides into misery on
## a schedule rather than off a cliff.
const EXPECTATIONS_MAX := 0.30
const EXPECTATIONS_DAYS := 15.0


## The live expectations cushion: [constant EXPECTATIONS_MAX] at
## founding, decaying linearly to zero over [constant EXPECTATIONS_DAYS].
## Read by `Unit.mood_target()` — it's a circumstance, not a thought.
## [param now_msec] lets tests read the curve at any instant.
func expectations_bonus(now_msec := -1) -> float:
	if founded_msec < 0:
		return 0.0
	var now := now_msec if now_msec >= 0 else game_msec()
	var age_days := (
		float(now - founded_msec) / (day_length() * 1000.0)
	)
	return (
		EXPECTATIONS_MAX
		* clampf(1.0 - age_days / EXPECTATIONS_DAYS, 0.0, 1.0)
	)


## Drops the starting roster on solid ground around [param origin] —
## the active scenario's settler count and per-settler skill/knowledge
## rolls, its founding animals, and its item scatter.
func spawn_initial_units(origin: Vector3i) -> void:
	var scn := scenario()
	scenario_id = StringName(scn.get(&"id", scenario_id))
	if founded_msec < 0:
		founded_msec = game_msec()
	var roster: Array = scn.get(&"settlers", [])
	var count := maxi(
		int(scn.get(&"settler_count", initial_units)), roster.size()
	)
	for i in count:
		var angle := TAU * float(i) / float(maxi(count, 1))
		var offset := Vector3i(
			int(cos(angle) * spawn_radius), 0, int(sin(angle) * spawn_radius)
		)
		var unit := spawn_unit(_dry_landing_cell(origin + offset))
		_apply_settler(
			unit,
			roster[i] if i < roster.size() else {},
			scn
		)
	for herd: Dictionary in scn.get(&"animals", []):
		var n := int(herd.get(&"count", 1))
		for j in n:
			var angle2 := TAU * float(j) / float(maxi(n, 1))
			var cell := origin + Vector3i(
				int(cos(angle2) * (spawn_radius + 3 + j)), 0,
				int(sin(angle2) * (spawn_radius + 3 + j))
			)
			var animal := spawn_animal(
				StringName(herd.get(&"species", &"")), _dry_landing_cell(cell)
			)
			animal.domestic = bool(herd.get(&"domestic", false))
	for item_def: Dictionary in scn.get(&"items", []):
		_scatter_scenario_items(item_def, origin)
	spawn_wildlife(origin)


## The scenario this colony runs — the staged selection, or the pack's
## default when nothing chose one (the dev boot path).
func scenario() -> Dictionary:
	if scenario_id != &"" and DataPackage.scenario_named(scenario_id).is_empty() == false:
		return DataPackage.scenario_named(scenario_id)
	return DataPackage.scenario()


## Applies one roster entry to a fresh unit — background band first
## (every ungated skill rolls in `skill_range`), then the settler's own
## skill overrides (an int level or a [lo, hi] roll), then the
## knowledge list: gated skills start at level 1 — basic competence.
func _apply_settler(
	unit: Unit, roll: Dictionary, scn: Dictionary
) -> void:
	var band: Array = scn.get(&"skill_range", [])
	if band.size() == 2:
		for skill in ColonyJob.Skill.values():
			if ColonyJob.GATED_SKILLS.has(skill):
				continue
			var lvl := randi_range(int(band[0]), int(band[1]))
			unit.skills[skill] = _skill_level_xp(lvl)
	# Caller-passed rolls may carry raw name keys — resolve them the
	# same way the package normaliser does.
	for key in roll.get(&"skills", {}):
		var skill := DataPackage._skill_id(key)
		if skill < 0:
			continue
		var v = roll[&"skills"][key]
		var lvl: int = (
			randi_range(int(v[0]), int(v[1])) if v is Array else int(v)
		)
		unit.skills[skill] = _skill_level_xp(lvl)
	for skill in scn.get(&"knowledge", []):
		unit.skills[skill] = maxf(
			unit.skills.get(skill, 0.0), _skill_level_xp(1)
		)
	for key in roll.get(&"knowledge", []):
		var skill := DataPackage._skill_id(key)
		if skill < 0:
			continue
		unit.skills[skill] = maxf(
			unit.skills.get(skill, 0.0), _skill_level_xp(1)
		)
	_roll_passions(unit)


## The settler's aptitude roll — RimWorld's passions. Each work skill
## rolls independently: a dead interest never learns (×0, kept so the
## save and the inspector can show it), a minor one learns at ×1.5,
## a burning one at ×2 and earns the `passion` moodlet at work. The
## band is generous — most of a settler's aptitudes stay ordinary.
func _roll_passions(unit: Unit) -> void:
	for skill in ColonyJob.Skill.values():
		var r := randf()
		if r < PASSION_DEAD_CHANCE:
			unit.passions[skill] = 0.0
		elif r < PASSION_DEAD_CHANCE + PASSION_MINOR_CHANCE:
			unit.passions[skill] = 1.5
		elif r < (
			PASSION_DEAD_CHANCE + PASSION_MINOR_CHANCE
			+ PASSION_BURNING_CHANCE
		):
			unit.passions[skill] = Unit.PASSION_BURNING


## Passion roll shares per skill — of sixteen skills a settler lands
## roughly two dead interests, three minor and one burning on average.
const PASSION_DEAD_CHANCE := 0.12
const PASSION_MINOR_CHANCE := 0.18
const PASSION_BURNING_CHANCE := 0.08


## XP total for a whole skill level — the triangular-XP ladder inverted.
static func _skill_level_xp(level: int) -> float:
	return Unit.SKILL_XP_BASE * level * (level + 1) / 2.0


## Spawns the scenario's starting goods near the landing — one
## [DropItem] per count unit, or one loose pile sized by cm3.
func _scatter_scenario_items(item_def: Dictionary, origin: Vector3i) -> void:
	var form := int(item_def.get(&"form", DropItem.Form.LOOSE))
	var material := int(
		item_def.get(&"material", BlockRegistry.Resource_.NONE)
	)
	var spec := StringName(item_def.get(&"spec", &""))
	var n := int(item_def.get(&"count", 1))
	if item_def.has(&"cm3"):
		# Forms without a discrete unit (loose pours report 0) can't be
		# item-counted — split the volume into a handful of chunks so
		# the scatter still spreads, instead of one drop per cm³.
		n = maxi(1, roundi(
			float(item_def[&"cm3"])
			/ maxf(DropItem.form_volume(form), 20_000.0)
		))
		var per := maxi(1, roundi(
			float(item_def[&"cm3"]) / float(n)
		))
		for i in n:
			_drop_scatter_item(
				DropItem.new(material, form, per), spec, origin, i
			)
		return
	for i in n:
		_drop_scatter_item(
			DropItem.new(material, form, DropItem.form_volume(form)),
			spec, origin, i
		)


## The embark ring and scatter can dip into a lake — settlers and
## starting goods belong on dry standable ground, not under water they
## can't swim out of (or reach into). Returns [param cell] when it's
## already dry, else the nearest dry standable column found spiralling
## outward — the anchor itself as the last resort.
func _dry_landing_cell(cell: Vector3i) -> Vector3i:
	if world.sim == null:
		return cell
	var level := int(world.sim.water_level_at(cell.x, cell.z))
	var ground := world.ground_height(cell.x, cell.z, cell.y + 32)
	if level <= ground and world.is_standable(
		Vector3i(cell.x, ground + 1, cell.z)
	):
		return cell
	# Ring-search outward — nearest dry column wins. Bounded: a truly
	# waterlogged embark just lands wet like before.
	for r in range(1, 40):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var c := Vector3i(cell.x + dx, 0, cell.z + dz)
				var g := world.ground_height(c.x, c.z, cell.y + 32)
				if (
					int(world.sim.water_level_at(c.x, c.z)) <= g
					and world.is_standable(Vector3i(c.x, g + 1, c.z))
				):
					return Vector3i(c.x, g + 1, c.z)
	return cell


## One scattered item — dropped a few cells off the landing so the pile
## spreads rather than stacking on the anchor.
func _drop_scatter_item(
	item: DropItem, spec: StringName, origin: Vector3i, index: int
) -> void:
	if spec != &"":
		item.spec = spec
	var angle := TAU * float(index % 11) / 11.0 + float(index) * 0.37
	var cell := _dry_landing_cell(origin + Vector3i(
		int(cos(angle) * (2 + index % 4)), 0,
		int(sin(angle) * (2 + index % 4))
	))
	cell.y = world.ground_height(cell.x, cell.z, origin.y + 32) + 1
	_drop_item(item, cell)


## A post-embark arrival — a wanderer joining, a rescue, anyone the
## roster gains after the landing. The scenario's `entry` rule picks
## the spot: `periphery` walks the boundary intercept of the approach
## bearing, `centre` lands them by the anchor.
func spawn_settler(roll: Dictionary = {}, bearing := Vector2.ZERO) -> Unit:
	var scn := scenario()
	var bc := site_bounds.get_center() if site_bounds.has_area() else Vector2i.ZERO
	var cell := Vector3i.ZERO
	var entry := StringName(scn.get(&"entry", {}).get(&"kind", &"periphery"))
	match entry:
		&"periphery":
			cell = (
				periphery_entry(bearing)
				if site_bounds.has_area()
				else Vector3i(bc.x, 0, bc.y)
			)
		_:
			cell = Vector3i(bc.x, 0, bc.y)
	var unit := spawn_unit(_dry_landing_cell(cell))
	_apply_settler(unit, roll, scn)
	# Walk them into the colony — the same self-issued move order an
	# out-of-area unit uses; arrival lands them on ordinary idle.
	if entry == &"periphery" and site_bounds.has_area():
		unit.arrive(Vector3i(bc.x, 0, bc.y))
	return unit


## A rescue-and-recruit event: a hurt stranger collapses at the site's
## edge — downed, bleeding, not roster labour. RESCUE carries them to
## a bed and TEND mends them like anyone; once they're back on their
## feet `_guests_tick` runs the recruit roll — they join the roster
## or walk off. The wounds hurt without crippling: every hit stays
## under its part's ruin line so convalescence ends cleanly.
func spawn_stranger(bearing: Vector2 = Vector2.ZERO) -> Unit:
	var guest := spawn_settler({}, bearing)
	guest.stranger = true
	guest.relieved = true
	guest.name = "Stranger%d" % units.size()
	# Traveller's injuries — enough pooled damage to drop them where
	# they landed, all on parts that knit.
	guest.add_wound(&"left_leg", &"cut", 12.0)
	guest.add_wound(&"right_leg", &"cut", 12.0)
	guest.add_wound(&"left_arm", &"bruise", 8.0)
	guest.add_wound(&"torso", &"bruise", 25.0)
	# The walk-in order means nothing to a unit on the ground —
	# clear it before the rescue takes the body.
	guest.abandon_job()
	DLog.log("stranger down at %s" % guest.global_position)
	return guest


## Where a traveller on [param bearing] (the direction they walk) first
## crosses the site's bounds rectangle — the ray from the centre
## backwards along the bearing hits one edge. A zero bearing picks a
## random approach.
func periphery_entry(bearing: Vector2 = Vector2.ZERO) -> Vector3i:
	var centre := (
		Vector2(site_bounds.position) + Vector2(site_bounds.size) * 0.5
		if site_bounds.has_area()
		else Vector2.ZERO
	)
	var dir := bearing
	if dir.length() < 0.01:
		var a := randf() * TAU
		dir = Vector2(cos(a), sin(a))
	dir = dir.normalized()
	var hx := float(site_bounds.size.x) * 0.5 - 1.0
	var hy := float(site_bounds.size.y) * 0.5 - 1.0
	var tx := hx / maxf(absf(dir.x), 0.0001)
	var ty := hy / maxf(absf(dir.y), 0.0001)
	var t := minf(tx, ty)
	var col := centre - dir * t
	var x := roundi(col.x)
	var z := roundi(col.y)
	return Vector3i(x, world.ground_height(x, z, 96) + 1, z)


## Scatters the opening wildlife on a ring outside the unit spawn
## circle, then lets their own wander AI take over. The mix is the
## pack's `wildlife.opening` list — vanilla covers each diet and
## temperament: grazers, small prey, an omnivore, a predator, one big
## dangerous animal.
func spawn_wildlife(origin: Vector3i) -> void:
	var opening: Array = DataPackage.wildlife_opening()
	for i in opening.size():
		var angle := TAU * float(i) / opening.size()
		var offset := Vector3i(
			int(cos(angle) * (spawn_radius + 12 + i)),
			0,
			int(sin(angle) * (spawn_radius + 12 + i))
		)
		spawn_animal(StringName(opening[i]), origin + offset)


## Spawns one wild animal of [param species] on the ground nearest
## [param near_voxel] — registers it with the sim, tints its placeholder
## mesh from the species spec and adds it to the colony's roster.
func spawn_animal(species_id: StringName, near_voxel: Vector3i) -> Animal:
	var ground_y := world.ground_height(
		near_voxel.x, near_voxel.z, near_voxel.y + 32
	)
	var animal: Animal = ANIMAL_SCENE.instantiate()
	animal.name = "Animal%d" % (animals.size() + 1)
	animal.species = species_id
	add_child(animal)
	animal.global_position = Vector3(
		near_voxel.x + 0.5, ground_y + 1.9, near_voxel.z + 0.5
	)
	animal.setup(world, self)
	var spec := Species.spec(species_id)
	var mesh := animal.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh != null:
		var material := StandardMaterial3D.new()
		material.albedo_color = spec.get(&"color", Color(0.55, 0.40, 0.25))
		material.roughness = 0.9
		mesh.material_override = material
		var scale_factor := float(spec.get(&"scale", 0.6))
		mesh.scale = Vector3.ONE * scale_factor
		mesh.position.y = 0.35 * scale_factor
	animal.died.connect(_on_animal_died)
	animals.append(animal)
	DLog.log(
		"animal %s (%s) spawned at %s"
		% [species_id, animal.get_instance_id(), animal.global_position]
	)
	return animal


func _on_animal_died(animal: Animal) -> void:
	animals.erase(animal)
	# A hunt whose quarry dropped counts as finished — `_finish_job`
	# pays the hunter its XP and releases the assignment; the unit's
	# next tick sees the job inactive and walks off. A tame whose mark
	# died is just lost work — it cancels, no lesson for a carcass.
	for job in jobs:
		if job.animal == animal and job.is_active():
			job.animal = null
			if job.type == ColonyJob.Type.TAME:
				job.state = ColonyJob.State.CANCELLED
			else:
				_finish_job(job)


## The closest living animal to [param from] within [param radius]
## metres — the hunt designator's pick. INFINITY scans everywhere.
func nearest_animal(from: Vector3i, radius: float = INF) -> Animal:
	var best: Animal = null
	var best_d := radius
	var origin := Vector3(from) + Vector3(0.5, 0.5, 0.5)
	for animal in animals:
		if (
			animal == null
			or not is_instance_valid(animal)
			or animal.dead
		):
			continue
		var d := origin.distance_to(animal.global_position)
		if d < best_d:
			best_d = d
			best = animal
	return best


## Orders a hunt on the animal nearest [param voxel_position] — the job
## chases the live target and the kill leaves a corpse. Refuses when
## nothing alive is close enough to mean or the animal's already marked.
func designate_hunt(voxel_position: Vector3i) -> ColonyJob:
	var animal := nearest_animal(voxel_position, 6.0)
	if animal == null or not is_instance_valid(animal) or animal.dead:
		return null
	for job in jobs:
		if job.animal == animal and job.is_active():
			return null
	var job := ColonyJob.new(
		ColonyJob.Type.HUNT, Vector3i(animal.global_position.floor())
	)
	job.animal = animal
	_register_job(job)
	DLog.log("hunt designated on %s" % animal.label())
	job_added.emit(job)
	return job


## The nearest wild, tameable animal to [param from] within [param
## radius] — the tame designator's pick. Only plant-and-mixed eaters
## take bait: a carnivore's idea of livestock is the handler.
func nearest_tameable(from: Vector3i, radius: float = INF) -> Animal:
	var best: Animal = null
	var best_d := radius
	var origin := Vector3(from) + Vector3(0.5, 0.5, 0.5)
	for animal in animals:
		if (
			animal == null
			or not is_instance_valid(animal)
			or animal.dead
			or animal.domestic
			or not animal.tameable()
		):
			continue
		var d := origin.distance_to(animal.global_position)
		if d < best_d:
			best_d = d
			best = animal
	return best


## Orders taming on the wild animal nearest [param voxel_position] —
## the job fetches bait, then works the animal in sessions until it
## turns domestic or the handler gives up. Refuses when nothing
## tameable is close enough or the animal's already marked.
func designate_tame(voxel_position: Vector3i) -> ColonyJob:
	var animal := nearest_tameable(voxel_position, 6.0)
	if animal == null or not is_instance_valid(animal) or animal.dead:
		return null
	return designate_tame_animal(animal)


## The per-animal tame designation — the Animals tab's pick, where the
## click order's radius check doesn't apply.
func designate_tame_animal(animal: Animal) -> ColonyJob:
	if (
		animal == null
		or not is_instance_valid(animal)
		or animal.dead
		or not animal.tameable()
	):
		return null
	for job in jobs:
		if job.animal == animal and job.is_active():
			return null
	var job := ColonyJob.new(
		ColonyJob.Type.TAME, Vector3i(animal.global_position.floor())
	)
	job.animal = animal
	_register_job(job)
	DLog.log("tame designated on %s" % animal.label())
	job_added.emit(job)
	return job


## True while an active tame job holds [param animal] — the roster's
## "marked" readout and the designator's dedupe share the answer.
func tame_marked(animal: Animal) -> bool:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.TAME
			and job.animal == animal
			and job.is_active()
		):
			return true
	return false


## The voxel of the nearest pile holding bait [param animal] would
## take — food an herbivore eats (no meat) or anything a mixed eater
## fancies. Same index ride as [method nearest_food_pile].
func nearest_bait_pile(
	from: Vector3i, animal: Animal, skip: Dictionary = {},
	area: AllowedArea = null, far_ok := false
) -> Vector3i:
	var now := game_msec()
	return _nearest_indexed(from, _pile_buckets, _home_match(func(voxel: Vector3i) -> int:
		var edible := false
		for item in _items_of(voxel):
			if item.forbidden:
				continue
			if animal.bait_ok(item):
				edible = true
				break
			if item.is_container():
				for inner in item.stored:
					if animal.bait_ok(inner):
						edible = true
						break
				if edible:
					break
		if not edible:
			return _Match.VETO
		var record: Dictionary = skip.get(voxel, {})
		if record.is_empty():
			return _Match.FRESH
		if now - int(record.get("at", 0)) < retry_delay_msec(record):
			return _Match.VETO
		return _Match.RETRY, far_ok), area)


## A taming job's payoff: the mark turned domestic — it stops fearing
## the hands that fed it, and any herd assignment the pen already
## carried over stays in force.
func complete_tame(job: ColonyJob, _worker: Unit) -> void:
	if job.animal != null and is_instance_valid(job.animal):
		job.animal.calm()
	_finish_job(job)


## Queues a butcher spot — a flagged work area where corpses are cut
## into meat, leather and bone. Same construct-in-place path as the
## campfire: a unit brings the stones and sets it up.
func designate_butcher_spot(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = &"butcher_spot"
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated butcher spot %s" % voxel_position)
	job_added.emit(job)
	return job


## True when a butcher spot occupies [param voxel_position].
func butcher_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.kind == Building.Kind.BUTCHER:
		return building
	return null


## Queues a grave build at [param voxel_position] — a mound and a
## cobble marker, same construct-in-place path as the butcher spot.
func designate_grave(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = &"grave"
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated grave %s" % voxel_position)
	job_added.emit(job)
	return job


## The grave at [param voxel_position], or null.
func grave_at(voxel_position: Vector3i) -> Building:
	var building := building_at(voxel_position)
	if building != null and building.kind == Building.Kind.GRAVE:
		return building
	return null


## Queues a spike-trap build at [param voxel_position] — sharpened
## stakes in a pit, same construct-in-place path as the grave.
func designate_spike_trap(voxel_position: Vector3i) -> ColonyJob:
	if cell_claimed(voxel_position, Occ.DESIGNATION | Occ.BUILDING):
		return null
	if world.get_block(voxel_position) != BlockRegistry.Block.AIR:
		return null
	if not world.is_editable(voxel_position):
		return null
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return null
	if cell_claimed(voxel_position, Occ.PILE):
		return null
	if cell_claimed(voxel_position, Occ.ZONE | Occ.TREE):
		return null
	var job := ColonyJob.new(ColonyJob.Type.CRAFT, voxel_position)
	job.recipe = &"spike_trap"
	_register_job(job)
	_add_marker(voxel_position, _build_marker_material, null, true)
	DLog.log("designated spike trap %s" % voxel_position)
	job_added.emit(job)
	return job


## The nearest grave still waiting for a body — a burial's
## destination pick.
func nearest_free_grave(
	from: Vector3i, area: AllowedArea = null
) -> Building:
	var best: Building = null
	var best_sq := INF
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if (
			building.kind != Building.Kind.GRAVE
			or building.buried != &""
			or seen.has(building)
			or deconstruct_job_at(building.voxel) != null
			or not in_area(area, building.voxel)
		):
			continue
		seen[building] = true
		var sq := Vector3(building.voxel - from).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = building
	return best


## The nearest grave with somebody in it — the mourn visit's target.
func nearest_occupied_grave(
	from: Vector3i, area: AllowedArea = null
) -> Building:
	var best: Building = null
	var best_sq := INF
	var seen := {}
	for cell in buildings:
		var building: Building = buildings[cell]
		if (
			building.kind != Building.Kind.GRAVE
			or building.buried == &""
			or seen.has(building)
			or not in_area(area, building.voxel)
		):
			continue
		seen[building] = true
		var sq := Vector3(building.voxel - from).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = building
	return best


## The nearest pile holding an unburied settler corpse — the BURY
## job's fetch target. Animal carcasses go to the butcher spot; a
## settler goes in the ground.
func nearest_settler_corpse_voxel(
	from: Vector3i, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if (
				item.form == DropItem.Form.CORPSE
				and item.species == &"settler"
				and not item.forbidden
			):
				return _Match.FRESH
		return _Match.VETO, area)


## The live butcher job at [param voxel_position], if one's posted.
func butcher_job_at(voxel_position: Vector3i) -> ColonyJob:
	for job in jobs:
		if (
			job.type == ColonyJob.Type.BUTCHER
			and job.voxel_position == voxel_position
			and job.is_active()
		):
			return job
	return null


## Wildlife bookkeeping on the scan cadence: post a butcher job at any
## idle spot once a corpse exists, and trickle a new animal in from the
## edge about once a day while the population is under target.
func _wildlife_tick() -> void:
	_post_butcher_jobs()
	_livestock_tick()
	_arrivals_tick()
	var day_msec := int(day_length() * 1000.0)
	if game_msec() - _wildlife_respawn_msec < day_msec:
		return
	_wildlife_respawn_msec = game_msec()
	var alive := 0
	for animal in animals:
		# A tamed herd isn't wild stock — it shouldn't hold the
		# wildlings out of the woods either way the count tips.
		if not animal.dead and not animal.domestic:
			alive += 1
	if alive >= WILDLIFE_TARGET or units.is_empty():
		return
	# Walk in from a random point on a wide ring around the colony.
	var centre := Vector3i(units[0].global_position.floor())
	var angle := randf() * TAU
	var edge := centre + Vector3i(
		int(cos(angle) * 55), 0, int(sin(angle) * 55)
	)
	edge.y = world.ground_height(edge.x, edge.z, centre.y + 48) + 1
	var trickle: Array = DataPackage.wildlife_trickle()
	if trickle.is_empty():
		return
	var animal := spawn_animal(
		StringName(trickle[randi() % trickle.size()]), edge
	)
	DLog.log("wildlife wandered in: %s at %s" % [animal.label(), edge])


## Domestic herd bookkeeping on the wildlife cadence: a herd of two or
## more under its cap breeds on a slow interval — a juvenile joins the
## herd beside a parent, inheriting its pen. One birth per interval,
## herd cap per species, no pair no calf.
func _livestock_tick() -> void:
	var interval_msec := int(day_length() * 1000.0 * LIVESTOCK_INTERVAL_DAYS)
	if game_msec() - _livestock_breed_msec < interval_msec:
		return
	_livestock_breed_msec = game_msec()
	breed_livestock()


## Breed one juvenile for a domestic herd that has a pair and room —
## returns the calf, or null when every herd is alone or full. Kept
## separate from the interval gate so tests and events can call it
## directly.
func breed_livestock() -> Animal:
	var herds := {}
	for animal in animals:
		if (
			animal != null
			and is_instance_valid(animal)
			and not animal.dead
			and animal.domestic
		):
			herds.get_or_add(animal.species, []).append(animal)
	for species_id: StringName in herds:
		var herd: Array = herds[species_id]
		if herd.size() < 2 or herd.size() >= HERD_CAP:
			continue
		var parent: Animal = herd[randi() % herd.size()]
		var juvenile := spawn_animal(
			species_id, Vector3i(parent.global_position.floor())
		)
		juvenile.domestic = true
		juvenile.tame_progress = 1.0
		juvenile.allowed_area = parent.allowed_area
		DLog.log(
			"livestock bred: %s joins the herd" % juvenile.label()
		)
		return juvenile
	return null


## Item 60's wanderer cadence — RimWorld's storyteller arrival
## approximated without a director: a per-day roll scaled by how the
## camp feels and how crowded it already is. A happy, small camp
## draws feet; a miserable or bursting one repels them. On a landed
## roll the event is a walk-in join most days, a downed stranger for
## the rescue-and-recruit play the rest. The regional simulation will
## supply real travel paths to both later.
func _arrivals_tick() -> void:
	var day_msec := int(day_length() * 1000.0)
	if game_msec() - _arrivals_msec < day_msec:
		return
	_arrivals_msec = game_msec()
	if randf() >= arrival_chance():
		return
	var bearing := Vector2.RIGHT.rotated(randf() * TAU)
	if randf() < STRANGER_SHARE:
		spawn_stranger(bearing)
	else:
		var wanderer := spawn_settler({}, bearing)
		DLog.log("wanderer joined: %s" % wanderer.name)


## The day's odds of somebody arriving — base rate swung hard by mean
## morale (a despairing camp draws a fifth of the base, a euphoric
## one nearly double), fading to zero as the roster nears the cap.
## Guests waiting on a verdict don't count — they aren't settled.
func arrival_chance() -> float:
	var mood_sum := 0.0
	var roster := 0
	for unit in units:
		if unit.dead or unit.stranger:
			continue
		mood_sum += unit.mood
		roster += 1
	if roster == 0 or roster >= ROSTER_SOFT_CAP:
		return 0.0
	var mean := mood_sum / float(roster)
	return (
		ARRIVAL_DAILY
		* lerpf(ARRIVAL_MOOD_MIN, ARRIVAL_MOOD_MAX, mean)
		* (1.0 - float(roster) / float(ROSTER_SOFT_CAP))
	)


## The daily join odds at mean mood for a small camp — a few arrivals
## a month, not a conveyor.
const ARRIVAL_DAILY := 0.10
## Mean-mood multipliers on the roll — the whole range of morale
## moves the odds by nearly 10x.
const ARRIVAL_MOOD_MIN := 0.2
const ARRIVAL_MOOD_MAX := 1.8
## Roster size that chokes arrivals to nothing — RimWorld's soft cap
## where the camp stops drawing wanderers.
const ROSTER_SOFT_CAP := 14
## Share of landed rolls that are a downed stranger instead of a
## walk-in join — the rescue play is the rare card.
const STRANGER_SHARE := 0.3
var _arrivals_msec := 0


## Guest bookkeeping on the medical cadence: a recovered stranger
## faces the recruit roll — join the roster or walk off — and a
## departing one despawns once they've idled at the edge. A refused
## guest's body isn't the colony's to mourn either way.
func _guests_tick() -> void:
	var leaving: Array[Unit] = []
	for unit in units:
		if unit.dead or not unit.stranger:
			continue
		if unit.departing:
			if _walked_off(unit):
				# Reached the rim — despawn; still deep inside (a
				# rescue dragged them back, the path broke) means
				# keep walking: reissue the way out.
				var cell := Vector3i(unit.global_position.floor())
				if (
					not site_bounds.has_area()
					or _edge_distance(cell) <= DEPART_EDGE_CELLS
				):
					leaving.append(unit)
				else:
					unit.drafted = false
					unit.arrive(periphery_entry())
			continue
		if unit.is_downed() or unit.health < RECRUIT_READY_HEALTH:
			continue
		resolve_guest(unit)
	for unit in leaving:
		_unit_departed(unit)


## The recruit verdict — [param roll] under the chance joins them;
## over it they leave. The colony's best Social does the persuading:
## a silver tongue keeps more strangers than a rough camp does, and
## the attempt pays the talker's lesson either way.
func resolve_guest(unit: Unit, roll := -1.0) -> bool:
	var best_social := 0
	var talker: Unit = null
	for other in units:
		if (
			other == unit
			or other.dead
			or other.stranger
			or not is_instance_valid(other)
		):
			continue
		var lvl := other.skill_level(ColonyJob.Skill.SOCIAL)
		if lvl > best_social:
			best_social = lvl
			talker = other
	var chance := minf(
		RECRUIT_BASE + RECRUIT_SOCIAL_STEP * float(best_social),
		RECRUIT_CAP
	)
	if roll < 0.0:
		roll = randf()
	if talker != null:
		talker.gain_skill_xp(ColonyJob.Skill.SOCIAL, RECRUIT_XP)
	if roll < chance:
		unit.stranger = false
		unit.relieved = false
		unit.name = "Unit%d" % (units.size() + 1)
		DLog.log("%s joins the colony" % unit.name)
		return true
	# Refused — they walk back the way they came, on the same
	# self-issued move order an arrival uses. A drafted guest sheds
	# the stance first — `arrive` won't move a drafted unit.
	unit.departing = true
	unit.drafted = false
	unit.arrive(periphery_entry())
	DLog.log("the stranger moves on")
	return false


## Marching orders for an off-site trip (PLAN item 65): the unit turns
## relieved so the board never reclaims them mid-walk, then takes the
## same self-issued move order a departing guest uses — aimed at the
## rim nearest the destination. The travellers tick packs them into a
## party once they've made the edge.
func send_traveller(unit: Unit, target: Dictionary) -> void:
	unit.travelling = true
	unit.travel_target = target
	unit.departing = true
	unit.relieved = true
	unit.drafted = false
	unit.abandon_job()
	# periphery_entry's convention is inbound: the rim a traveller
	# moving in direction d CROSSES entering is centre - d·t. A
	# departure wants the rim facing the destination — flip it.
	unit.arrive(periphery_entry(-_travel_bearing(target)))
	DLog.log("%s sets out for %s" % [unit.name, target.get(&"label", "a site")])


## The direction a [param target] record says to leave by — the
## bearing Main computed from here to the destination.
func _travel_bearing(target: Dictionary) -> Vector2:
	var b: Array = target.get(&"bearing", [])
	if b.size() == 2:
		return Vector2(float(b[0]), float(b[1]))
	return Vector2.ZERO


## Traveller bookkeeping on the same cadence as the guests: a unit
## who's made the rim under travel orders serializes into an off-site
## party (the signal carries the payload — serialize must run while
## the unit still lives); one stuck inside gets the walk reissued.
## A rim-bound unit that's done walking: standing idle, or holding the
## move order's post — ORDER jobs stand watch at their destination
## rather than completing, so "arrived" reads as WORKING-on-a-move,
## never IDLE. Anything else (still walking, fighting, carried) is a
## departure still in progress.
func _walked_off(unit: Unit) -> bool:
	if unit.state == Unit.State.IDLE:
		return true
	return (
		unit.state == Unit.State.WORKING
		and unit.job != null
		and unit.job.type == ColonyJob.Type.ORDER
		and unit.job.animal == null
		and unit.job.foe == null
		and unit.job.structure == null
	)


func _travellers_tick() -> void:
	var leaving: Array[Unit] = []
	for unit in units:
		if not is_instance_valid(unit) or unit.dead or not unit.travelling:
			continue
		if not _walked_off(unit):
			continue
		var cell := Vector3i(unit.global_position.floor())
		if (
			not site_bounds.has_area()
			or _edge_distance(cell) <= DEPART_EDGE_CELLS
		):
			leaving.append(unit)
		else:
			unit.drafted = false
			unit.arrive(periphery_entry(-_travel_bearing(unit.travel_target)))
	for unit in leaving:
		_unit_travelled(unit)


## A traveller's exit — like a guest's, but the serialized payload
## survives: Main turns it into a region party bound for the target.
func _unit_travelled(unit: Unit) -> void:
	var payload := unit.serialize()
	# The rim-hold state is a move order's WORKING — it means "arrived"
	# here but restores as a stuck watch at the far end. Pack the unit
	# standing free instead.
	payload["state"] = int(Unit.State.IDLE)
	var target: Dictionary = unit.travel_target
	units.erase(unit)
	_sleeping.erase(unit)
	DLog.log("%s left the map for travel" % unit.name)
	unit.queue_free()
	unit_travelled.emit(payload, target)


## Cells between [param cell] and the site bounds' nearest edge —
## the departure check's "made it to the rim" measure.
func _edge_distance(cell: Vector3i) -> int:
	if not site_bounds.has_area():
		return 0
	return mini(
		cell.x - site_bounds.position.x,
		mini(
			site_bounds.end.x - 1 - cell.x,
			mini(
				cell.z - site_bounds.position.y,
				site_bounds.end.y - 1 - cell.z
			)
		)
	)


## A guest's exit — walking off the world isn't dying: no corpse, no
## thoughts, just an empty roster slot where they stood.
func _unit_departed(unit: Unit) -> void:
	units.erase(unit)
	_sleeping.erase(unit)
	DLog.log("%s left the map" % unit.name)
	unit.queue_free()
	unit_departed.emit(unit)


## Health the guest needs before they're persuadable — well past the
## patient line, standing on their own.
const RECRUIT_READY_HEALTH := 70.0
## Base recruit odds before the colony's best Social weighs in —
## alone in a field hospital, a quarter of recoveries stay.
const RECRUIT_BASE := 0.25
## Each level of the best talker's Social adds this much — the skill's
## first real use.
const RECRUIT_SOCIAL_STEP := 0.07
## Even a legendary diplomat can't promise the moon.
const RECRUIT_CAP := 0.85
## The talker's lesson per attempt — the recruit conversation is
## Social work.
const RECRUIT_XP := 8.0
## Cells from the site's edge that count as walked-off — the boundary
## intercept lands just inside, so a small rim counts as gone.
const DEPART_EDGE_CELLS := 2


## Every idle butcher spot posts a job once a corpse pile exists
## somewhere — the fetch side figures out which corpse to take.
func _post_butcher_jobs() -> void:
	var corpse := Vector3i.MAX
	var seen := {}
	for cell: Vector3i in buildings:
		var building: Building = buildings[cell]
		if seen.has(building) or building.kind != Building.Kind.BUTCHER:
			continue
		seen[building] = true
		if (
			butcher_job_at(building.voxel) != null
			or deconstruct_job_at(building.voxel) != null
		):
			continue
		if corpse == Vector3i.MAX:
			corpse = _nearest_butcherable_corpse(building.voxel)
		if corpse == Vector3i.MAX:
			break
		var job := ColonyJob.new(ColonyJob.Type.BUTCHER, building.voxel)
		_register_job(job)
		job_added.emit(job)


## Nearest pile holding a corpse something can be butchered out of —
## species with yields; a settler's body isn't stock.
func _nearest_butcherable_corpse(from: Vector3i) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if (
				item.form == DropItem.Form.CORPSE
				and not item.forbidden
				and Species.spec(item.species).has(&"yields")
			):
				return _Match.FRESH
		return _Match.VETO)


## Butcher-skill yield floor and per-level gain — a level-0 butcher gets
## three quarters of a carcass onto the table, and the rest — plus
## everything a clumsy hand wastes — falls to scraps.
const BUTCHER_YIELD_BASE := 0.75
const BUTCHER_YIELD_PER_LEVEL := 0.05

## Products keyed by the yields table — the fractions the species spec
## assigns to each cut.
const BUTCHER_MATERIALS := {
	&"meat": BlockRegistry.Resource_.MEAT,
	&"leather": BlockRegistry.Resource_.LEATHER,
	&"bone": BlockRegistry.Resource_.BONE,
}


## A fresh corpse item of [param species_id] — what an animal's death
## drops and the test hook for butchering fixtures.
func make_corpse(species_id: StringName) -> DropItem:
	var corpse := DropItem.new(
		BlockRegistry.Resource_.CORPSE,
		DropItem.Form.CORPSE,
		Species.corpse_cm3(species_id)
	)
	corpse.species = species_id
	return corpse


## The corpse escrowed on [param job] is cut up at the spot: species
## yields scaled by the butcher's skill, species extras whole, and the
## remainder — by definition everything not made into product — as
## butchering scraps that rot to compost. Volume in = volume out.
func complete_butcher(job: ColonyJob, unit: Unit) -> void:
	var corpse: DropItem = null
	for item in job.components:
		if item.form == DropItem.Form.CORPSE:
			corpse = item
			break
	if corpse == null or butcher_at(job.voxel_position) == null:
		for item in job.components:
			_drop_item(item, job.voxel_position)
		job.components.clear()
		_finish_job(job)
		return
	var level := (
		unit.skill_level(ColonyJob.Skill.BUTCHERING) if unit != null else 0
	)
	var mult := minf(
		1.0, BUTCHER_YIELD_BASE + level * BUTCHER_YIELD_PER_LEVEL
	)
	var spec := Species.spec(corpse.species)
	var yields: Dictionary = spec.get(&"yields", {})
	var drops: Array[DropItem] = []
	var used := 0
	for cut: StringName in BUTCHER_MATERIALS:
		var frac := float(yields.get(cut, 0.0))
		if frac <= 0.0:
			continue
		var volume := int(corpse.volume * frac * mult)
		if volume <= 0:
			continue
		used += volume
		# The cut keeps its beast — wolf meat is wolf to a diner who
		# cares what's on the plate.
		var drop := DropItem.new(
			BUTCHER_MATERIALS[cut], DropItem.Form.LOOSE, volume
		)
		drop.species = corpse.species
		drops.append(drop)
	for extra: Dictionary in spec.get(&"extras", []):
		for i in int(extra.get(&"count", 1)):
			var extra_drop := DropItem.new(
				int(extra[&"material"]),
				DropItem.Form.LOOSE,
				int(extra[&"cm3"])
			)
			extra_drop.species = corpse.species
			drops.append(extra_drop)
	var scraps_volume := maxi(corpse.volume - used, corpse.volume / 20)
	drops.append(DropItem.new(
		BlockRegistry.Resource_.SCRAPS, DropItem.Form.LOOSE, scraps_volume
	))
	for item in drops:
		_drop_item(item, job.voxel_position)
	job.components.clear()
	_finish_job(job)


## ---------------------------------------------------------------------------
## Health (item 28) — the colony side of the per-part wound model in
## unit.gd: posting tend/rescue work, resolving what a tend can do where
## the patient lies, and turning a dead unit into a physical corpse.
## ---------------------------------------------------------------------------

## The medical pass: every unit whose wounds want care gets a TEND job,
## every downed unit lying where it fell gets a RESCUE. Both are posted
## on this cadence — first aid can reach a patient anywhere; a rescue
## needs a free bed to carry them to (a medical one when there is one —
## that's the facility a real treatment takes).
func _medical_tick() -> void:
	# An open medical job goes stale once its patient dies, heals past
	# needing it, or stops being a rescue case — pull it off the board
	# so a freed post doesn't linger unclaimable forever.
	var stale: Array[ColonyJob] = []
	for job: ColonyJob in jobs:
		if (
			job.type != ColonyJob.Type.TEND
			and job.type != ColonyJob.Type.RESCUE
			and job.type != ColonyJob.Type.SURGERY
			and job.type != ColonyJob.Type.ARREST
		):
			continue
		if job.state != ColonyJob.State.PENDING or job.patient == null:
			continue
		var patient: Unit = job.patient
		if not is_instance_valid(patient) or patient.dead:
			stale.append(job)
		elif job.type == ColonyJob.Type.ARREST and not patient._berserk:
			# The break passed before anybody grabbed them — no job.
			stale.append(job)
		elif job.type == ColonyJob.Type.TEND and not _unit_wants_tend(patient):
			stale.append(job)
		elif job.type == ColonyJob.Type.SURGERY and (
			patient.surgery_bills.is_empty()
			or not _patient_on_medical_bed(patient)
		):
			stale.append(job)
		elif job.type == ColonyJob.Type.RESCUE and (
			patient.state != Unit.State.DOWNED
			or patient._carried_by != null
			or not _rescue_bed_exists(patient)
		):
			stale.append(job)
	for job: ColonyJob in stale:
		job.state = ColonyJob.State.CANCELLED
		_unregister_job(job)
	for unit in units:
		if unit.dead or unit._carried_by != null:
			# A patient riding a rescuer's shoulder can't be tended
			# mid-haul — the job lands once they're set down.
			continue
		if _unit_wants_tend(unit) and _patient_job(unit, ColonyJob.Type.TEND) == null:
			var tend := ColonyJob.new(ColonyJob.Type.TEND, unit._standing_voxel())
			tend.patient = unit
			_register_job(tend)
			job_added.emit(tend)
		# The surgeons triage their own: a wound past the line draws a
		# `treat_infection` bill whether or not the overseer noticed.
		if (
			unit.worst_infection() >= Unit.INFECT_SURGERY_LINE
			and not unit.surgery_bills.has(&"treat_infection")
		):
			post_surgery_bill(unit, &"treat_infection")
		# A billed patient on a medical bed is an operation waiting for
		# a surgeon — the bedded patient is the bill's ingredient.
		if (
			not unit.surgery_bills.is_empty()
			and _patient_on_medical_bed(unit)
			and _patient_job(unit, ColonyJob.Type.SURGERY) == null
		):
			var surgery := ColonyJob.new(
				ColonyJob.Type.SURGERY, unit._standing_voxel()
			)
			surgery.patient = unit
			surgery.recipe = unit.surgery_bills[0]
			_register_job(surgery)
			job_added.emit(surgery)
		if (
			unit.state == Unit.State.DOWNED
			and unit._carried_by == null
			and _patient_job(unit, ColonyJob.Type.RESCUE) == null
			and _rescue_bed_exists(unit)
		):
			var rescue := ColonyJob.new(
				ColonyJob.Type.RESCUE, unit._standing_voxel()
			)
			rescue.patient = unit
			_register_job(rescue)
			job_added.emit(rescue)
		# A rampage wants hands on it — one ARREST job per berserk unit,
		# reposted by this tick while the flag stands.
		if (
			unit._berserk
			and _patient_job(unit, ColonyJob.Type.ARREST) == null
		):
			post_arrest(unit)
	_burial_tick()
	_guests_tick()
	_travellers_tick()


## The graveyard pass: an unburied settler corpse under an open grave
## gets a BURY job — one per corpse, capped by the plots that stand
## ready. Animal carcasses never qualify; the butcher wants those.
func _burial_tick() -> void:
	var stale: Array[ColonyJob] = []
	for job: ColonyJob in jobs:
		if (
			job.type != ColonyJob.Type.BURY
			or job.state != ColonyJob.State.PENDING
		):
			continue
		# A pending BURY goes stale when its corpse leaves the pile —
		# butchered by mistake can't happen (settler corpses are
		# refused) but a decayed pile can. An assigned job's body is
		# in the bearer's hands; its failure path is the give-up.
		var pile := item_pile_at(job.voxel_position)
		var still := false
		if pile != null:
			for item in pile.items:
				if (
					item.form == DropItem.Form.CORPSE
					and item.species == &"settler"
				):
					still = true
					break
		if not still:
			stale.append(job)
	for job: ColonyJob in stale:
		job.state = ColonyJob.State.CANCELLED
		_unregister_job(job)
	var graves_open := 0
	var grave_jobs := 0
	for cell in buildings:
		var building: Building = buildings[cell]
		if building.kind == Building.Kind.GRAVE and building.buried == &"":
			graves_open += 1
	for job: ColonyJob in jobs:
		if job.type == ColonyJob.Type.BURY and job.is_active():
			grave_jobs += 1
	if graves_open - grave_jobs <= 0:
		return
	var seen := {}
	for cell in item_piles:
		var pile := item_pile_at(cell)
		if pile == null:
			continue
		for item in pile.items:
			if (
				item.form != DropItem.Form.CORPSE
				or item.species != &"settler"
				or item.forbidden
			):
				continue
			seen[cell] = true
			break
	for cell in seen:
		if graves_open - grave_jobs <= 0:
			break
		var duplicate := false
		for job: ColonyJob in jobs:
			if (
				job.type == ColonyJob.Type.BURY
				and job.is_active()
				and job.voxel_position == cell
			):
				duplicate = true
				break
		if duplicate:
			continue
		var job := ColonyJob.new(ColonyJob.Type.BURY, cell)
		_register_job(job)
		job_added.emit(job)
		grave_jobs += 1


## Adds [param op] to [param unit]'s surgery queue — the worksite-bill
## list where the bedded patient is the ingredient. Bills validate
## against the body: no infection, no treat bill; nothing ruined, no
## amputation. Returns false when the bill makes no sense or the op's
## already queued.
func post_surgery_bill(unit: Unit, op: StringName) -> bool:
	if (
		unit == null
		or not is_instance_valid(unit)
		or unit.dead
		or not Unit.SURGERY_OPS.has(op)
		or unit.surgery_bills.has(op)
	):
		return false
	match op:
		&"treat_infection":
			if unit.worst_infection() <= 0.0:
				return false
		&"amputate":
			if unit.ruined_parts.is_empty():
				return false
	unit.surgery_bills.append(op)
	DLog.log("surgery bill %s for %s" % [op, unit.name])
	return true


## An operation's finish: the surgeon's channel ends, the medicine is
## spent, and the bill comes off the patient's queue — infection
## cleared or the ruined part off. The patient-as-ingredient was the
## eligibility; the bundle was the consumable.
func complete_surgery(job: ColonyJob, surgeon: Unit) -> void:
	var patient: Unit = job.patient
	var op := job.recipe
	if (
		patient == null
		or not is_instance_valid(patient)
		or patient.dead
	):
		_finish_job(job)
		return
	var bundle := surgeon._carried_material(BlockRegistry.Resource_.MEDICINE)
	if bundle != null:
		surgeon._carried.erase(bundle)
	# Whatever medicine the operation didn't spend goes back on the
	# ground — a surgeon's hands don't stay loaded forever.
	while true:
		var spare := surgeon._carried_material(BlockRegistry.Resource_.MEDICINE)
		if spare == null:
			break
		surgeon._carried.erase(spare)
		_drop_item(spare, surgeon._standing_voxel())
	patient.surgery_bills.erase(op)
	match op:
		&"treat_infection":
			patient.treat_infection()
		&"amputate":
			var part := patient.amputate()
			if part != &"":
				DLog.log("amputated %s's %s" % [patient.name, part])
		_:
			pass
	_finish_job(job)


## A burial's finish: the carried corpse is laid in the grave and its
## item consumed — the plot keeps the species for its label and the
## mourners' visits. The grave is the bearer's goal — the job's post
## voxel still names the pile the body came from.
func complete_bury(job: ColonyJob, bearer: Unit) -> void:
	var grave := grave_at(bearer._goal_voxel)
	var corpse := bearer._carried_form(DropItem.Form.CORPSE)
	if (
		grave != null
		and grave.buried == &""
		and corpse != null
		and corpse.species == &"settler"
	):
		grave.buried = corpse.species
		bearer._carried.erase(corpse)
		DLog.log("buried a %s at %s" % [corpse.species, grave.voxel])
	_finish_job(job)


## The arrester's hands closed — the rampage ends where the release
## line or a down would have taken it: `catharsis` lands through the
## ordinary break-off path and the berserk flag clears.
func complete_arrest(job: ColonyJob) -> void:
	var breaker: Unit = job.patient
	if (
		breaker != null
		and is_instance_valid(breaker)
		and not breaker.dead
	):
		breaker._end_berserk("arrested")
	_finish_job(job)


## Post the grab for a berserk unit — one ARREST job per breaker,
## refreshed by `_arrest_tick` while the flag stands.
func post_arrest(breaker: Unit) -> ColonyJob:
	var job := ColonyJob.new(
		ColonyJob.Type.ARREST, Vector3i(breaker.global_position.floor())
	)
	job.patient = breaker
	_register_job(job)
	job_added.emit(job)
	return job


## Whether somebody's waiting on care — an unclaimed TEND or RESCUE on
## the board. The units' needs gate reads this as colony-level
## alertness: while a patient waits, nobody beds down early or wanders
## off for fun — the nearest free body takes the job.
func care_pending() -> bool:
	for job: ColonyJob in jobs:
		if job.state == ColonyJob.State.PENDING and (
			job.type == ColonyJob.Type.TEND
			or job.type == ColonyJob.Type.RESCUE
			or job.type == ColonyJob.Type.SURGERY
		):
			return true
	return false


## Whether [param unit] has work a tend could do — an untreated wound,
## or a wound only field-dressed while the patient now lies somewhere
## real care is possible (a medical bed).
func _unit_wants_tend(unit: Unit) -> bool:
	var want_care := 2 if _patient_on_medical_bed(unit) else 1
	for wound: Dictionary in unit.wounds:
		if int(wound[&"care"]) < want_care:
			return true
	return false


## True while [param unit] lies in a medical bed — the only place a
## tend does more than stop bleeding.
func _patient_on_medical_bed(unit: Unit) -> bool:
	return unit._rest_bed != null and unit._rest_bed.medical


## Whether a bed exists for a rescue to carry [param unit] to —
## medical first, else any free bed still beats the ground.
func _rescue_bed_exists(unit: Unit) -> bool:
	# A downed patient already in a bed needs no rescue — though a
	# field-tended one in a plain bed upgrades to a medical bed when
	# one is free.
	if unit._rest_bed != null:
		return (
			not unit._rest_bed.medical
			and nearest_free_medical_bed(unit._standing_voxel()) != null
		)
	return (
		nearest_free_medical_bed(unit._standing_voxel()) != null
		or nearest_free_bed(unit._standing_voxel()) != null
	)


## The live TEND/RESCUE job already posted for [param patient], or
## null — keeps the medical tick from stacking duplicates.
func _patient_job(patient: Unit, type: ColonyJob.Type) -> ColonyJob:
	for job in jobs:
		if job.type == type and job.patient == patient and job.is_active():
			return job
	return null


## The closest free bed flagged medical — the facility marker the
## player sets on a bed's inspect panel.
func nearest_free_medical_bed(
	from: Vector3i, area: AllowedArea = null
) -> Building:
	var best: Building = null
	var best_sq := INF
	var seen := {}
	for cell in buildings:
		var bed: Building = buildings[cell]
		if (
			bed.kind != Building.Kind.BED
			or not bed.medical
			or not bed.bed_vacancy()
			or seen.has(bed)
			or deconstruct_job_at(bed.voxel) != null
			or not in_area(area, bed.voxel)
		):
			continue
		seen[bed] = true
		var sq := Vector3(cell - from).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = bed
	return best


## The voxel of the nearest pile holding a medicine bundle — the
## doctor's fetch target for a medical-bed tend.
func nearest_medicine_voxel(
	from: Vector3i, area: AllowedArea = null
) -> Vector3i:
	return _nearest_indexed(from, _pile_buckets, func(voxel: Vector3i) -> int:
		for item in _items_of(voxel):
			if (
				item.material == BlockRegistry.Resource_.MEDICINE
				and not item.forbidden
			):
				return _Match.FRESH
		return _Match.VETO, area)


## A tend's finish: the doctor's pass over the patient's wounds — field
## care stops bleeding; a medical-bed tend treats, and burns a carried
## herb bundle when the doctor brought one.
func complete_tend(job: ColonyJob, doctor: Unit) -> void:
	var patient: Unit = job.patient
	if (
		patient == null
		or not is_instance_valid(patient)
		or patient.dead
	):
		_finish_job(job)
		return
	var medical := _patient_on_medical_bed(patient)
	# The patient's medicine policy decides whether a bundle may be
	# spent: NEVER never touches the stock; STOCKED spends on
	# medical-bed tends; ALWAYS spends wherever the doctor caught up.
	var may_spend := (
		patient.med_policy != Unit.MedPolicy.NEVER
		and (medical or patient.med_policy == Unit.MedPolicy.ALWAYS)
	)
	var medicine: DropItem = null
	if may_spend:
		medicine = doctor._carried_material(BlockRegistry.Resource_.MEDICINE)
		if medicine != null:
			doctor._carried.erase(medicine)
			# The bundle is consumed — used up on the patient.
	patient.apply_tend(medical, medicine != null)
	# Whatever medicine the tend didn't spend goes back on the ground —
	# a doctor's hands don't stay loaded forever.
	while true:
		var spare := doctor._carried_material(BlockRegistry.Resource_.MEDICINE)
		if spare == null:
			break
		doctor._carried.erase(spare)
		_drop_item(spare, doctor._standing_voxel())
	_finish_job(job)


## A rescue's finish: the patient's tucked into the claimed bed.
func complete_rescue(job: ColonyJob, _rescuer: Unit) -> void:
	_finish_job(job)


## The unit's end — its carried items already dropped by `abandon_job`;
## here the body becomes a physical corpse and leaves the roster. The
## survivors feel it: everyone close enough to see it happen carries
## `witnessed_death`, and in a camp this small everyone `lost_friend`.
func _unit_died(unit: Unit) -> void:
	_drop_item(make_corpse(unit.species), unit._standing_voxel())
	units.erase(unit)
	_sleeping.erase(unit)
	DLog.log("unit %d died at %s" % [unit.get_instance_id(), unit.global_position])
	for survivor in units:
		if survivor.dead:
			continue
		if (
			survivor.global_position.distance_to(unit.global_position)
			<= WITNESS_DEATH_RANGE
		):
			survivor.add_thought(&"witnessed_death")
		# A guest who never joined was nobody's friend yet — the sight
		# still lands, the grief doesn't.
		if not unit.stranger:
			survivor.add_thought(&"lost_friend")
	unit.queue_free()
	unit_died.emit(unit)


## How close a settler has to be for a death to count as witnessed —
## inside this range the survivor saw it happen.
const WITNESS_DEATH_RANGE := 12.0


func spawn_unit(near_voxel: Vector3i) -> Unit:
	var ground_y := world.ground_height(near_voxel.x, near_voxel.z, near_voxel.y + 32)
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.name = "Unit%d" % (units.size() + 1)
	add_child(unit)
	# Spawn at the settled capsule height — `_standing_voxel` reads the
	# feet convention (pos.y - 0.9), so a +1.5 spawn would report the
	# solid cell below and a too-early death would bury its corpse.
	unit.global_position = Vector3(near_voxel.x + 0.5, ground_y + 1.9, near_voxel.z + 0.5)
	unit.setup(world, self)
	unit.state_changed.connect(_on_unit_state_changed.bind(unit))
	units.append(unit)
	DLog.log("unit %d spawned at %s" % [unit.get_instance_id(), unit.global_position])
	unit_spawned.emit(unit)
	return unit


func _add_marker(
	voxel_position: Vector3i,
	material: StandardMaterial3D,
	mesh: Mesh = null,
	plan := false
) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = mesh if mesh != null else _marker_mesh
	marker.material_override = material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	marker.visible = _plan_visible() if plan else markers_visible
	add_child(marker)
	_designation_markers[voxel_position] = marker
	if plan:
		_plan_voxels[voxel_position] = true


## Whether plan markers render — the HUD toggle or a planning tool in
## hand both count.
func plans_visible() -> bool:
	return _plan_visible()


## The HUD's Plans toggle.
func set_plans_visible_manual(value: bool) -> void:
	plans_visible_manual = value
	_update_plan_visibility()


## A planning tool (a wall action or deconstruct) auto-shows plans.
func set_plans_tool_active(value: bool) -> void:
	_plans_tool_active = value
	_update_plan_visibility()


func _plan_visible() -> bool:
	return plans_visible_manual or _plans_tool_active


func _update_plan_visibility() -> void:
	for voxel: Vector3i in _plan_voxels:
		_designation_markers[voxel].visible = _plan_visible()
	for key in _face_markers:
		_face_markers[key].visible = _plan_visible()


## Shows or hides every designation marker — the zones display toggle.
func set_markers_visible(value: bool) -> void:
	markers_visible = value
	for voxel: Vector3i in _designation_markers:
		if not _plan_voxels.has(voxel):
			_designation_markers[voxel].visible = value
	for voxel: Vector3i in _area_markers:
		_area_markers[voxel].visible = value
	for voxel: Vector3i in _fertilize_markers:
		_fertilize_markers[voxel].visible = value
	for voxel: Vector3i in _radius_markers:
		_radius_markers[voxel].visible = value


## Draws a bill's ingredient fetch radius as a surface ring around
## [param center] — the HUD flashes it while the radius control is
## hovered. `radius <= 0` (fetch anywhere) draws nothing.
func show_fetch_radius(center: Vector3i, radius: float) -> void:
	hide_fetch_radius()
	if radius <= 0.0:
		return
	var steps := clampi(int(radius * 4.0), 16, 192)
	for i in steps:
		var angle := TAU * float(i) / float(steps)
		var x := center.x + int(round(cos(angle) * radius))
		var z := center.z + int(round(sin(angle) * radius))
		var cell := _radius_surface_cell(x, z)
		if not world.is_standable(cell) or _radius_markers.has(cell):
			continue
		var marker := MeshInstance3D.new()
		marker.mesh = _area_marker_mesh
		marker.material_override = _radius_marker_material
		marker.position = Vector3(cell) + Vector3(0.5, 0.98, 0.5)
		marker.visible = markers_visible
		add_child(marker)
		_radius_markers[cell] = marker


func hide_fetch_radius() -> void:
	for cell: Vector3i in _radius_markers:
		_radius_markers[cell].queue_free()
	_radius_markers.clear()


## The standable cell a radius marker hugs in column x/z — the scan
## drops from just above the predicted surface until it finds floor.
func _radius_surface_cell(x: int, z: int) -> Vector3i:
	var top: int = world.predicted_surface_height(x, z) + 8
	for y in range(top, top - 24, -1):
		var cell := Vector3i(x, y, z)
		if world.is_standable(cell):
			return cell
	return Vector3i(x, top - 24, z)


func _remove_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _designation_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_designation_markers.erase(voxel_position)
		_plan_voxels.erase(voxel_position)


## Puts a building's marker back to showing the building itself — the
## worksite outline, a bed's low slab, or filled with the queued-order
## look while an order runs. Walls keep no standing marker at all.
func _restore_worksite_marker(voxel_position: Vector3i) -> void:
	var building: Building = buildings.get(voxel_position)
	if building == null or building.kind == Building.Kind.WALL:
		_remove_marker(voxel_position)
		return
	# The cell's marker now shows the standing building, not a plan —
	# the Plans toggle must stop driving it.
	_plan_voxels.erase(voxel_position)
	if building.kind == Building.Kind.BED:
		_set_marker_appearance(voxel_position, _bed_marker_material, _bed_mesh)
		var marker: MeshInstance3D = _designation_markers.get(voxel_position)
		if marker != null:
			# The slab sits on the cell floor, not the voxel centre.
			marker.position.y = voxel_position.y + _bed_mesh.size.y * 0.5
			marker.visible = true
		return
	if building.kind == Building.Kind.LADDER:
		# A pole filling the cell — freestanding and wall-attached look
		# alike until real rendering exists.
		_set_marker_appearance(voxel_position, _ladder_marker_material, _ladder_mesh)
		var pole: MeshInstance3D = _designation_markers.get(voxel_position)
		if pole != null:
			pole.visible = true
		return
	if building.kind == Building.Kind.DOOR:
		# A panel standing in the doorway — the hinge sits against one
		# cell face; which one is cosmetic until doors read the walls.
		_set_marker_appearance(voxel_position, _door_marker_material, _door_mesh)
		var panel: MeshInstance3D = _designation_markers.get(voxel_position)
		if panel != null:
			# Two cells tall, hinged thin on z — center it a half-cell up
			# so it fills the doorway and its headroom.
			panel.position = Vector3(voxel_position) + Vector3(0.5, 1.0, 0.5) \
				+ Vector3(0, 0, 0.41)
			panel.visible = true
		return
	if building.kind == Building.Kind.CAMPFIRE:
		# A low stone ring on the cell floor, lit by its own light while
		# it burns — the ring is a standing visual like the bed's slab.
		# A running bill keeps the ring, only the tint switches over.
		_set_marker_appearance(
			voxel_position,
			(
				_craft_job_marker_material
				if craft_job_at(voxel_position) != null
				else _campfire_marker_material
			),
			_campfire_mesh
		)
		var ring: MeshInstance3D = _designation_markers.get(voxel_position)
		if ring != null:
			# The torus tube's radius is half the inner/outer gap — rest
			# its underside on the cell floor.
			ring.position.y = (
				voxel_position.y
				+ (_campfire_mesh.outer_radius - _campfire_mesh.inner_radius) * 0.5
			)
			ring.visible = true
		_sync_campfire_light(voxel_position)
		return
	if building.kind == Building.Kind.RECREATION:
		# A low table-slab resting on the cell floor — one look for pins,
		# boards and instruments until real furniture meshes exist.
		_set_marker_appearance(voxel_position, _rec_marker_material, _rec_mesh)
		var rec: MeshInstance3D = _designation_markers.get(voxel_position)
		if rec != null:
			rec.position.y = voxel_position.y + _rec_mesh.size.y * 0.5
			rec.visible = true
		return
	if building.provides_cover():
		# The fortifications: the mound's low soil lump and the
		# barricade's waist-high face — both rest on the cell floor and
		# stay visible like the bed slab regardless of the markers
		# toggle.
		var mesh := (
			_mound_mesh
			if building.kind == Building.Kind.MOUND
			else _barricade_mesh
		)
		var material := (
			_mound_marker_material
			if building.kind == Building.Kind.MOUND
			else _barricade_marker_material
		)
		_set_marker_appearance(voxel_position, material, mesh)
		var cover: MeshInstance3D = _designation_markers.get(voxel_position)
		if cover != null:
			cover.position.y = voxel_position.y + mesh.size.y * 0.5
			cover.visible = true
		return
	if building.kind == Building.Kind.FLOODGATE:
		# The sluice frame — its panel stands full height on the cell
		# floor; open fraction is a control, not a shape (for now).
		_set_marker_appearance(
			voxel_position, _gate_marker_material, _gate_mesh
		)
		var gate: MeshInstance3D = _designation_markers.get(voxel_position)
		if gate != null:
			gate.position.y = voxel_position.y + _gate_mesh.size.y * 0.5
			gate.visible = true
		return
	if building.kind == Building.Kind.WATER_WHEEL:
		# The wheel's ring stands on edge in the flow — torus default
		# lies flat, so roll it upright around the x axis.
		_set_marker_appearance(
			voxel_position, _wheel_marker_material, _wheel_mesh
		)
		var wheel: MeshInstance3D = _designation_markers.get(voxel_position)
		if wheel != null:
			wheel.rotation.x = PI * 0.5
			wheel.position.y = voxel_position.y + _wheel_mesh.outer_radius
			wheel.visible = true
		return
	if building.kind == Building.Kind.PUMP:
		# The pump's housing nudges a quarter-cell toward its intake
		# face — the lean is the only facing cue until real meshes.
		_set_marker_appearance(
			voxel_position, _pump_marker_material, _pump_mesh
		)
		var pump: MeshInstance3D = _designation_markers.get(voxel_position)
		if pump != null:
			pump.position = (
				Vector3(voxel_position) + Vector3.ONE * 0.5
				+ Vector3(building.face_dir) * 0.25
			)
			pump.position.y = voxel_position.y + _pump_mesh.size.y * 0.5
			pump.visible = true
		return
	if building.kind == Building.Kind.CHARCOAL_MOUND:
		# The sealed stack — an earth dome on the cell floor.
		_set_marker_appearance(
			voxel_position, _charcoal_marker_material, _charcoal_mesh
		)
		var dome: MeshInstance3D = _designation_markers.get(voxel_position)
		if dome != null:
			dome.position.y = voxel_position.y + _charcoal_mesh.height * 0.5
			dome.visible = true
		return
	if building.kind == Building.Kind.SMELTER:
		# The pit smelter's cobble basin — a running smelt keeps the
		# basin, just tinted like the campfire's ring.
		_set_marker_appearance(
			voxel_position,
			(
				_craft_job_marker_material
				if craft_job_at(voxel_position) != null
				else _smelter_marker_material
			),
			_smelter_mesh
		)
		var basin: MeshInstance3D = _designation_markers.get(voxel_position)
		if basin != null:
			basin.position.y = voxel_position.y + _smelter_mesh.size.y * 0.5
			basin.visible = true
		return
	if building.kind == Building.Kind.BLOOMERY:
		# The bloomery's clay chimney, same running-tint rule.
		_set_marker_appearance(
			voxel_position,
			(
				_craft_job_marker_material
				if craft_job_at(voxel_position) != null
				else _bloomery_marker_material
			),
			_bloomery_mesh
		)
		var chimney: MeshInstance3D = _designation_markers.get(voxel_position)
		if chimney != null:
			chimney.position.y = voxel_position.y + _bloomery_mesh.height * 0.5
			chimney.visible = true
		return
	if (
		building.kind == Building.Kind.KILN
		or building.kind == Building.Kind.REFRACTORY
	):
		# The ceramics line's chimneys — the kiln's earthen cone and
		# the refractory's brick stack share the bloomery's shape in
		# their own tints, same running-tint rule.
		_set_marker_appearance(
			voxel_position,
			(
				_craft_job_marker_material
				if craft_job_at(voxel_position) != null
				else (
					_kiln_marker_material
					if building.kind == Building.Kind.KILN
					else _refractory_marker_material
				)
			),
			_bloomery_mesh
		)
		var stack: MeshInstance3D = _designation_markers.get(voxel_position)
		if stack != null:
			stack.position.y = voxel_position.y + _bloomery_mesh.height * 0.5
			stack.visible = true
		return
	if (
		building.kind == Building.Kind.METALWORK
		or building.kind == Building.Kind.FABRICATOR
		or building.kind == Building.Kind.TAILOR
		or building.kind == Building.Kind.TOOLMAKER
		or building.kind == Building.Kind.STONECUTTER
		or building.kind == Building.Kind.STONE_CRUSHER
		or building.kind == Building.Kind.STOVE
	):
		# The benches share the slab — the tint tells anvil from
		# assembly table from tailor from saw table, crusher from
		# stove. A running bill keeps it, tinted like the rest.
		_set_marker_appearance(
			voxel_position,
			(
				_craft_job_marker_material
				if craft_job_at(voxel_position) != null
				else (
					_fabricator_marker_material
					if building.kind == Building.Kind.FABRICATOR
					else (
						_tailor_marker_material
						if building.kind == Building.Kind.TAILOR
						else (
							_toolmaker_marker_material
							if building.kind == Building.Kind.TOOLMAKER
							else (
								_stonecutter_marker_material
								if building.kind == Building.Kind.STONECUTTER
								else (
									_crusher_marker_material
									if building.kind == Building.Kind.STONE_CRUSHER
									else (
										_stove_marker_material
										if building.kind == Building.Kind.STOVE
										else _metalwork_marker_material
									)
								)
							)
						)
					)
				)
			),
			_bench_mesh
		)
		var bench: MeshInstance3D = _designation_markers.get(voxel_position)
		if bench != null:
			bench.position.y = voxel_position.y + _bench_mesh.size.y * 0.5
			bench.visible = true
		return
	if building.kind == Building.Kind.GENERATOR:
		_set_marker_appearance(
			voxel_position, _generator_marker_material, _generator_mesh
		)
		var generator: MeshInstance3D = _designation_markers.get(voxel_position)
		if generator != null:
			generator.position.y = (
				voxel_position.y + _generator_mesh.size.y * 0.5
			)
			generator.visible = true
		return
	if building.kind == Building.Kind.HEATER:
		_set_marker_appearance(
			voxel_position, _heater_marker_material, _heater_mesh
		)
		var heater: MeshInstance3D = _designation_markers.get(voxel_position)
		if heater != null:
			heater.position.y = voxel_position.y + _heater_mesh.size.y * 0.5
			heater.visible = true
		return
	if building.kind == Building.Kind.COOLER:
		_set_marker_appearance(
			voxel_position, _cooler_marker_material, _cooler_mesh
		)
		var cooler: MeshInstance3D = _designation_markers.get(voxel_position)
		if cooler != null:
			cooler.position.y = voxel_position.y + _cooler_mesh.size.y * 0.5
			cooler.visible = true
		return
	if building.kind == Building.Kind.PYLON:
		_set_marker_appearance(
			voxel_position, _pylon_marker_material, _pylon_mesh
		)
		var pylon: MeshInstance3D = _designation_markers.get(voxel_position)
		if pylon != null:
			pylon.visible = true
		return
	if building.kind == Building.Kind.SHELF:
		# The tall open frame stands against the cell's back half, its
		# base on the floor — the front stays clear for the pile.
		_set_marker_appearance(
			voxel_position, _shelf_marker_material, _shelf_mesh
		)
		var shelf: MeshInstance3D = _designation_markers.get(voxel_position)
		if shelf != null:
			shelf.position.y = (
				voxel_position.y + _shelf_mesh.size.y * 0.5
			)
			shelf.visible = true
		return
	if building.kind == Building.Kind.COMPOST_BIN:
		# The low slat box sits on the cell floor like the shelf frame —
		# the pile it rots renders above the rim.
		_set_marker_appearance(
			voxel_position, _compost_bin_marker_material, _compost_bin_mesh
		)
		var bin: MeshInstance3D = _designation_markers.get(voxel_position)
		if bin != null:
			bin.position.y = (
				voxel_position.y + _compost_bin_mesh.size.y * 0.5
			)
			bin.visible = true
		return
	if craft_job_at(voxel_position) != null:
		_set_marker_appearance(voxel_position, _craft_job_marker_material, _marker_mesh)
	else:
		_set_marker_appearance(voxel_position, _craft_spot_marker_material, _outline_mesh)


## The mesh a worksite marker keeps while a bill runs on it — a
## campfire's ring stays a ring, just tinted; generic spots box over.
func _worksite_job_mesh(voxel_position: Vector3i) -> Mesh:
	var building: Building = buildings.get(voxel_position)
	if building != null:
		if building.kind == Building.Kind.CAMPFIRE:
			return _campfire_mesh
		if building.kind == Building.Kind.SMELTER:
			return _smelter_mesh
		if building.kind == Building.Kind.BLOOMERY:
			return _bloomery_mesh
		if (
			building.kind == Building.Kind.KILN
			or building.kind == Building.Kind.REFRACTORY
		):
			return _bloomery_mesh
		if (
			building.kind == Building.Kind.METALWORK
			or building.kind == Building.Kind.FABRICATOR
			or building.kind == Building.Kind.TAILOR
			or building.kind == Building.Kind.TOOLMAKER
			or building.kind == Building.Kind.STONECUTTER
			or building.kind == Building.Kind.STONE_CRUSHER
			or building.kind == Building.Kind.STOVE
		):
			return _bench_mesh
	return _marker_mesh


## Recolors and reshapes the marker at [param voxel_position] — craft
## spots tint to show a queued order without gaining a second marker.
func _set_marker_appearance(
	voxel_position: Vector3i, material: StandardMaterial3D, mesh: Mesh
) -> void:
	var marker: MeshInstance3D = _designation_markers.get(voxel_position)
	if marker == null:
		return
	marker.material_override = material
	marker.mesh = mesh


func _prune_jobs() -> void:
	for job in jobs:
		if not job.is_active():
			_unregister_job(job)
	jobs = jobs.filter(func(job: ColonyJob) -> bool: return job.is_active())
	for cell: Vector3i in _farm_jobs.keys():
		if not _farm_jobs[cell].is_active():
			_farm_jobs.erase(cell)
	for cell: Vector3i in _fertilize_jobs.keys():
		if not _fertilize_jobs[cell].is_active():
			_fertilize_jobs.erase(cell)


## Adds a job to the list, the id index and the native board.
func _register_job(job: ColonyJob) -> void:
	jobs.append(job)
	_job_index[job.get_instance_id()] = job
	job.posted_msec = game_msec()
	if world.sim != null:
		world.sim.job_add(
			job.get_instance_id(), job.voxel_position, job.type,
			job.posted_msec
		)


## Drops a job from the id index and the native board. Pruning keeps the
## list itself; this only tears down the mirrors.
func _unregister_job(job: ColonyJob) -> void:
	_job_index.erase(job.get_instance_id())
	if world.sim != null:
		world.sim.job_remove(job.get_instance_id())


## ---------------------------------------------------------------------------
## Persistence — the colony is a Site's payload inside the Region save.
## Everything serializes to plain JSON-safe data (ints, floats, strings,
## arrays, dictionaries); Vector3i rows are [x, y, z], items come through
## DropItem.serialize.
## ---------------------------------------------------------------------------

static func _v3i_data(voxel: Vector3i) -> Array:
	return [voxel.x, voxel.y, voxel.z]


static func _v3i(data: Array) -> Vector3i:
	return Vector3i(int(data[0]), int(data[1]), int(data[2]))


static func _items_data(items: Array[DropItem]) -> Array:
	var out: Array = []
	for item in items:
		out.append(item.serialize())
	return out


static func _items_from(data: Array) -> Array[DropItem]:
	var out: Array[DropItem] = []
	for e: Array in data:
		out.append(DropItem.deserialize(e))
	return out


## The site's save record — every piece of live state a reload must
## rebuild. Terrain deltas aren't here; they live on the region's edit
## log (the write-side record) which the world replays as blocks stream.
func serialize() -> Dictionary:
	var pile_list: Array = []
	var seen_piles := {}
	var stale_piles: Array[Vector3i] = []
	for voxel: Vector3i in item_piles:
		# The map occasionally retains a pile a deferred free already
		# claimed — a stale key must never abort the save: drop it and
		# keep the record whole.
		var raw: Variant = item_piles[voxel]
		if not is_instance_valid(raw):
			stale_piles.append(voxel)
			continue
		var pile: ItemPile = raw
		seen_piles[pile] = true
		pile_list.append(
			{"voxel": _v3i_data(voxel), "items": _items_data(pile.items)}
		)
	for voxel: Vector3i in stale_piles:
		item_piles.erase(voxel)
		_index_remove(_pile_buckets, voxel)
		_sync_sim_packed(voxel)
	for raw_flight: Variant in _in_flight:
		# A falling pile is keyed to its landing voxel already — saved
		# as landed; restoring it there is the same end state.
		if not is_instance_valid(raw_flight):
			continue
		var pile := raw_flight as ItemPile
		if pile.merged:
			continue
		if not seen_piles.has(pile):
			pile_list.append(
				{
					"voxel": _v3i_data(pile.voxel_position),
					"items": _items_data(pile.items),
				}
			)
	var building_list: Array = []
	var seen_buildings := {}
	for cell: Vector3i in buildings:
		var building: Building = buildings[cell]
		if seen_buildings.has(building):
			continue
		seen_buildings[building] = true
		building_list.append(_building_data(building))
	var job_list: Array = []
	for job in jobs:
		if (
			job.desperate
			or not job.is_active()
			or job.type == ColonyJob.Type.FIREFIGHT
			or job.type == ColonyJob.Type.CLEAN
		):
			# Self-issued work re-derives from the unit's needs, done and
			# cancelled jobs are already out of the flow, and firefighting
			# and cleaning bills re-derive from the fires and mess lists.
			continue
		job_list.append(_job_data(job))
	var stockpile_list: Array = []
	for voxel: Vector3i in stockpiles:
		var zone: StockpileZone = stockpiles[voxel]
		stockpile_list.append(
			{
				"voxel": _v3i_data(voxel),
				"rejected": zone.rejected.keys(),
				"priority": int(zone.priority),
			}
		)
	var farm_list: Array = []
	var seen_farms := {}
	for cell: Vector3i in farms:
		var field: FarmField = farms[cell]
		if seen_farms.has(field):
			continue
		seen_farms[field] = true
		var cells: Array = []
		for c: Vector3i in field.cells:
			cells.append(_v3i_data(c))
		farm_list.append(
			{
				"species": String(field.species),
				"auto_chop": field.auto_chop,
				"auto_fertilize": field.auto_fertilize,
				"fertilize_target": field.fertilize_target,
				"cells": cells,
			}
		)
	var unit_list: Array = []
	for unit in units:
		var ud := unit.serialize()
		ud["area"] = areas.find(unit.allowed_area)
		unit_list.append(ud)
	var animal_list: Array = []
	for animal in animals:
		if not animal.dead:
			var ad := animal.serialize()
			ad["area"] = areas.find(animal.allowed_area)
			animal_list.append(ad)
	var area_list: Array = []
	for area in areas:
		area_list.append(area.serialize())
	var fert_list: Array = []
	for cell: Vector3i in fertilization:
		fert_list.append([cell.x, cell.y, cell.z, fertilization[cell]])
	var mark_list: Array = []
	for cell: Vector3i in fertilize_marks:
		var me := _v3i_data(cell)
		me.append(float(fertilize_marks[cell]))
		mark_list.append(me)
	var rock_spent_list: Array = []
	for cell: Vector3i in _rock_spent:
		rock_spent_list.append(_v3i_data(cell))
	var damage_list: Array = []
	for cell: Vector3i in _block_damage:
		var e := _v3i_data(cell)
		e.append(_block_damage[cell])
		damage_list.append(e)
	var fire_list: Array = []
	for cell: Vector3i in _fires:
		var fe := _v3i_data(cell)
		fe.append(float(_fires[cell][&"fuel"]))
		fire_list.append(fe)
	var home_list: Array = []
	for cell: Vector3i in home_cells:
		home_list.append(_v3i_data(cell))
	var mess_list: Array = []
	for cell: Vector3i in mess:
		var kinds := {}
		for kind: StringName in mess[cell]:
			kinds[String(kind)] = float(mess[cell][kind])
		mess_list.append({"voxel": _v3i_data(cell), "kinds": kinds})
	return {
		"needs_enabled": needs_enabled,
		"selected_speed": _selected_speed,
		"sleep_boost": sleep_boost,
		"paused": get_tree().paused,
		"scenario": String(scenario_id),
		"founded_msec": founded_msec,
		"units": unit_list,
		"animals": animal_list,
		"piles": pile_list,
		"buildings": building_list,
		"jobs": job_list,
		"stockpiles": stockpile_list,
		"areas": area_list,
		"farms": farm_list,
		"fertilization": fert_list,
		"fertilize_marks": mark_list,
		# Rain-soaked columns above ambient — the moisture layer's only
		# non-derivable state; tracked cells and body sizes rebuild
		# lazily from queries.
		"moisture": _soil_wet_list(),
		"rock_spent": rock_spent_list,
		"block_damage": damage_list,
		"plants": plants.serialize(),
		"forest": forest.serialize(),
		"grass": grass.serialize(),
		"flooring": flooring.serialize(),
		"weather": weather.serialize(),
		# The live water store as a delta against the reseeded flood —
		# empty while nothing has moved, so a settled map costs nothing.
		"water": (
			world.sim.water_serialize()
			if world != null and world.sim != null
			else {}
		),
		"fires": fire_list,
		"home_area": home_list,
		"auto_home": auto_home,
		# Mess survives — the bills don't; the next scan reposts them.
		"mess": mess_list,
	}


## Rebuilds the site from its save record — clears live state, then
## restores in dependency order: buildings (markers, ladders, orders),
## designations, decoration records, piles, jobs, and finally units
## whose bed links resolve into the restored buildings.
func deserialize(data: Dictionary) -> void:
	_clear_colony_state()
	# Water restores over the freshly re-seeded flood — the seed ran at
	# site install, so the saved delta lands on a deterministic base.
	if (
		world != null and world.sim != null
		and data.has("water")
	):
		world.sim.water_deserialize(data["water"])
	needs_enabled = bool(data.get("needs_enabled", true))
	# Main stages the world.json pick first — a payload without a
	# scenario key (pre-package saves) keeps that selection.
	scenario_id = StringName(data.get("scenario", scenario_id))
	# A pre-expectations save founds the colony at load — the grace
	# period it never got is the kindest honest default.
	founded_msec = int(data.get("founded_msec", game_msec()))
	for bd: Dictionary in data.get("buildings", []):
		_load_building(bd)
	for sd: Dictionary in data.get("stockpiles", []):
		var voxel := _v3i(sd["voxel"])
		var rejected := {}
		for m in sd.get("rejected", []):
			rejected[int(m)] = true
		var priority := int(sd.get("priority", int(StockpileZone.Priority.NORMAL)))
		# Contiguous cells with an identical filter are one zone — this
		# also keeps old per-tile saves working, grouped by signature.
		var zone := _stockpile_zone_for(
			voxel,
			StockpileZone.filter_signature(rejected) + "|" + str(priority)
		)
		zone.rejected = rejected
		zone.priority = priority
		zone.cells[voxel] = true
		stockpiles[voxel] = zone
		_index_add(_stockpile_buckets, voxel)
		if shelf_at(voxel) == null and compost_bin_at(voxel) == null:
			# A storage building's cell keeps its building marker — the
			# stockpile outline would overwrite the frame or the bin box.
			_add_marker(voxel, _stockpile_marker_material, _outline_mesh)
	for fd: Dictionary in data.get("farms", []):
		var field := FarmField.new()
		field.species = StringName(fd.get("species", ""))
		field.auto_chop = bool(fd.get("auto_chop", false))
		field.auto_fertilize = bool(fd.get("auto_fertilize", false))
		field.fertilize_target = float(fd.get("fertilize_target", 1.5))
		for c: Array in fd.get("cells", []):
			var cell := _v3i(c)
			field.cells[cell] = true
			farms[cell] = field
			_add_marker(cell, _farm_marker_material, _outline_mesh)
	for e: Array in data.get("fertilization", []):
		fertilization[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = float(e[3])
	for m: Array in data.get("moisture", []):
		_soil_wet[Vector2i(int(m[0]), int(m[1]))] = float(m[2])
	for me2: Array in data.get("fertilize_marks", []):
		var mark_cell := Vector3i(int(me2[0]), int(me2[1]), int(me2[2]))
		fertilize_marks[mark_cell] = float(me2[3])
		_add_fertilize_marker(mark_cell)
	for e: Array in data.get("block_damage", []):
		_block_damage[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = float(e[3])
	for r: Array in data.get("rock_spent", []):
		_rock_spent[_v3i(r)] = true
	plants.deserialize(data.get("plants", {}))
	forest.deserialize(data.get("forest", {}))
	grass.deserialize(data.get("grass", {}))
	flooring.deserialize(data.get("flooring", {}))
	weather.deserialize(data.get("weather", {}))
	# The home set lands before fires: a restored blaze reposts its
	# firefighting bill only while its cell is home.
	auto_home = bool(data.get("auto_home", true))
	for hc: Array in data.get("home_area", []):
		var home_voxel := _v3i(hc)
		home_cells[home_voxel] = true
		_index_add(_home_buckets, home_voxel)
		_add_home_marker(home_voxel)
	for e: Array in data.get("fires", []):
		var cell := _v3i(e)
		# Restored fires skip the saturation roll — they were already
		# burning when the save happened.
		var flam := _cell_flammability(cell)
		if flam > 0.0:
			_fires[cell] = {
				&"fuel": float(e[3]),
				&"flam": flam,
			}
			_add_fire_marker(cell)
			_post_firefight(cell)
	# Mess lands after home — off-home records are dropped by add_mess's
	# own gate, and the next scan posts the bills.
	for md: Dictionary in data.get("mess", []):
		for kind: Variant in md.get("kinds", {}):
			add_mess(_v3i(md["voxel"]), StringName(kind), float(md["kinds"][kind]))
	for ad2: Dictionary in data.get("areas", []):
		var area := AllowedArea.deserialize(ad2)
		areas.append(area)
		for cell: Vector3i in area.cells:
			_area_cells[cell] = area
			_add_area_marker(cell, area)
	for pd: Dictionary in data.get("piles", []):
		_load_pile(_v3i(pd["voxel"]), _items_from(pd.get("items", [])))
	for jd: Dictionary in data.get("jobs", []):
		_load_job(jd)
	for ud: Dictionary in data.get("units", []):
		_load_unit(ud)
	for ad: Dictionary in data.get("animals", []):
		_load_animal(ad)
	# Area links resolve by index now that the roster exists — a stale
	# index leaves the unit or animal unrestricted.
	for i in units.size():
		var ud2: Dictionary = data.get("units", [])[i]
		var index := int(ud2.get("area", -1))
		if index >= 0 and index < areas.size():
			units[i].allowed_area = areas[index]
	for i in animals.size():
		var ad3: Dictionary = data.get("animals", [])[i]
		var index2 := int(ad3.get("area", -1))
		if index2 >= 0 and index2 < areas.size():
			animals[i].allowed_area = areas[index2]
	# Animal links resolve now that the roster exists; a hunt whose
	# quarry index didn't survive cancels rather than hunting ghosts.
	for job: ColonyJob in _job_animal_links:
		var index: int = _job_animal_links[job]
		if index >= 0 and index < animals.size():
			job.animal = animals[index]
		else:
			job.state = ColonyJob.State.CANCELLED
			_unregister_job(job)
	_job_animal_links.clear()
	# Patient links resolve the same way — a medical job whose patient
	# didn't survive the save cancels.
	for job: ColonyJob in _job_patient_links:
		var index: int = _job_patient_links[job]
		if index >= 0 and index < units.size():
			job.patient = units[index]
		else:
			job.state = ColonyJob.State.CANCELLED
			_unregister_job(job)
	_job_patient_links.clear()
	# The world the cached partition described just changed wholesale.
	rooms.invalidate()
	_selected_speed = float(data.get("selected_speed", 1.0))
	sleep_boost = bool(data.get("sleep_boost", false))
	set_paused(bool(data.get("paused", false)))


## Wipes live colony state for a deserialize — every job off the board,
## every marker gone, every pile and unit freed, every zone emptied.
## The subsystems' own deserializes clear their records themselves.
func _clear_colony_state() -> void:
	for job in jobs:
		if job.is_active():
			_unregister_job(job)
	jobs.clear()
	_job_index.clear()
	_farm_jobs.clear()
	_fertilize_jobs.clear()
	_fires.clear()
	_firefight_at.clear()
	mess.clear()
	_clean_at.clear()
	for cell: Vector3i in _fire_markers:
		_fire_markers[cell].queue_free()
	_fire_markers.clear()
	fertilization.clear()
	fertilize_marks.clear()
	for cell: Vector3i in _fertilize_markers:
		_fertilize_markers[cell].queue_free()
	_fertilize_markers.clear()
	_rock_slots.clear()
	_rock_spent.clear()
	_block_damage.clear()
	for voxel: Vector3i in _designation_markers:
		_designation_markers[voxel].queue_free()
	_designation_markers.clear()
	_plan_voxels.clear()
	for key in _face_markers:
		_face_markers[key].queue_free()
	_face_markers.clear()
	var pile_voxels: Array = item_piles.keys()
	for pile: ItemPile in item_piles.values():
		pile.queue_free()
	for pile: ItemPile in _in_flight:
		pile.queue_free()
	item_piles.clear()
	_in_flight.clear()
	_pile_buckets.clear()
	if world.sim != null:
		for voxel: Vector3i in pile_voxels:
			world.sim.set_pile_fill(voxel, 0, 0)
	for cell: Vector3i in buildings:
		var building: Building = buildings[cell]
		if world.sim != null:
			if building.kind == Building.Kind.LADDER:
				world.sim.set_ladder(cell, false)
			elif building.kind == Building.Kind.DOOR:
				world.sim.set_door(cell, false)
			elif building.kind == Building.Kind.FENCE:
				world.sim.set_fence(cell, false)
			elif building.kind == Building.Kind.SPIKE_TRAP:
				world.sim.set_trap(cell, false)
			elif building.kind == Building.Kind.FLOODGATE:
				_apply_floodgate_edges(cell, 1.0)
			elif building.kind == Building.Kind.PUMP:
				world.sim.water_set_pump(
					cell + building.face_dir, cell - building.face_dir, 0
				)
	_soil_wet.clear()
	_moisture_cells.clear()
	_moist_body_cache.clear()
	buildings.clear()
	stockpiles.clear()
	_stockpile_buckets.clear()
	for cell: Vector3i in _area_markers:
		_area_markers[cell].queue_free()
	_area_markers.clear()
	areas.clear()
	_area_cells.clear()
	paint_area = null
	home_cells.clear()
	_home_buckets.clear()
	auto_home = true
	for cell: Vector3i in _home_markers:
		_home_markers[cell].queue_free()
	_home_markers.clear()
	farms.clear()
	for unit in units:
		unit.queue_free()
	units.clear()
	for animal in animals:
		animal.queue_free()
	animals.clear()
	_job_animal_links.clear()
	_sleeping.clear()


func _building_data(building: Building) -> Dictionary:
	var orders: Array = []
	for order in building.orders:
		orders.append(
			{
				"recipe": String(order.recipe),
				"condition": int(order.condition),
				"target": order.target,
				"done": order.done,
				"paused": order.paused,
				"unpause_at": order.unpause_at,
				"satisfied": order.satisfied,
				"count_stored_only": order.count_stored_only,
				"deliver_mode": int(order.deliver_mode),
				"deliver_target": (
					null
					if order.deliver_target == Vector3i.MAX
					else _v3i_data(order.deliver_target)
				),
				"ingredient_radius": order.ingredient_radius,
				"worker_index": order.worker_index,
				"skill_min": order.skill_min,
				"skill_max": order.skill_max,
				"rejected_materials": order.rejected_materials.keys(),
				"wear_min": order.wear_min,
				"wear_max": order.wear_max,
			}
		)
	var footprint: Array = []
	for cell in building.footprint:
		footprint.append(_v3i_data(cell))
	return {
		"kind": int(building.kind),
		"voxel": _v3i_data(building.voxel),
		"footprint": footprint,
		"block_id": building.block_id,
		"material": int(building.material),
		"spec": String(building.spec),
		"deconstructable": building.deconstructable,
		"components": _items_data(building.components),
		"orders": orders,
		# Campfire state — ignored by the other kinds.
		"fuel": building.fuel,
		"auto_refuel": building.auto_refuel,
		"refuel_fraction": building.refuel_fraction,
		# Floodgate state — the gate's open fraction; absent on old
		# saves loads as fully open.
		"open_fraction": building.open_fraction,
		# Bed state — whether it's an established medical facility.
		"medical": building.medical,
		# Grave state — the species resting in it; "" while it waits.
		"buried": String(building.buried),
		# Art subject — the species a carved work depicts; "" on
		# everything else.
		"depicts": String(building.depicts),
		# Integrity — omitted means pristine; a damaged build carries
		# its remaining hit points so a repair bill survives the save.
		"hp": building.hp,
		# Craft quality — the maker's roll on furniture and rec builds.
		"quality": building.quality,
		# Power infrastructure — a wall's embedded line, and a cooler's
		# cold-side bearing. `powered` isn't saved: the nets reflood on
		# the first tick after load.
		"conduit": building.conduit,
		"face_dir": (
			null if building.face_dir == Vector3i.ZERO
			else _v3i_data(building.face_dir)
		),
	}


func _load_building(bd: Dictionary) -> void:
	var building := Building.new(int(bd["kind"]), _v3i(bd["voxel"]))
	building.footprint.clear()
	for c: Array in bd.get("footprint", []):
		building.footprint.append(_v3i(c))
	building.block_id = int(bd.get("block_id", BlockRegistry.Block.AIR))
	building.material = int(bd.get("material", BlockRegistry.Resource_.NONE))
	building.spec = StringName(bd.get("spec", ""))
	building.deconstructable = bool(bd.get("deconstructable", true))
	building.components = _items_from(bd.get("components", []))
	for od: Dictionary in bd.get("orders", []):
		var order := WorksiteOrder.new()
		order.recipe = StringName(od.get("recipe", ""))
		order.condition = int(od.get("condition", 0))
		order.target = int(od.get("target", 1))
		order.done = int(od.get("done", 0))
		order.paused = bool(od.get("paused", false))
		order.unpause_at = int(od.get("unpause_at", -1))
		order.satisfied = bool(od.get("satisfied", false))
		order.count_stored_only = bool(od.get("count_stored_only", false))
		order.deliver_mode = int(od.get("deliver_mode", 0))
		var dt = od.get("deliver_target", null)
		order.deliver_target = _v3i(dt) if dt != null else Vector3i.MAX
		order.ingredient_radius = float(od.get("ingredient_radius", 0.0))
		order.worker_index = int(od.get("worker_index", -1))
		order.skill_min = int(od.get("skill_min", 0))
		order.skill_max = int(od.get("skill_max", 20))
		for m in od.get("rejected_materials", []):
			order.rejected_materials[int(m)] = true
		order.wear_min = float(od.get("wear_min", 0.0))
		order.wear_max = float(od.get("wear_max", 1.0))
		building.orders.append(order)
	building.fuel = float(bd.get("fuel", 0.0))
	building.auto_refuel = bool(bd.get("auto_refuel", true))
	building.refuel_fraction = float(bd.get("refuel_fraction", 0.3))
	building.open_fraction = clampf(
		float(bd.get("open_fraction", 1.0)), 0.0, 1.0
	)
	building.medical = bool(bd.get("medical", false))
	building.buried = Species.normalize(StringName(bd.get("buried", "")))
	building.depicts = StringName(bd.get("depicts", ""))
	# Integrity — 0 means "not saved", which registers as pristine.
	building.hp = float(bd.get("hp", 0.0))
	building.quality = float(bd.get("quality", 1.0))
	building.conduit = bool(bd.get("conduit", false))
	var fd = bd.get("face_dir", null)
	building.face_dir = _v3i(fd) if fd != null else Vector3i.ZERO
	register_building(building, false)
	if building.kind == Building.Kind.WALL:
		return
	# A marker first, then the kind's standing appearance — the same end
	# state _restore_worksite_marker settles into after a build.
	_add_marker(building.voxel, _craft_spot_marker_material, _outline_mesh)
	_restore_worksite_marker(building.voxel)


func _job_data(job: ColonyJob) -> Dictionary:
	var delivered: Array = []
	for form in job.delivered:
		delivered.append([int(form), int(job.delivered[form])])
	var extra: Array = []
	for cell in job.extra_voxels:
		extra.append(_v3i_data(cell))
	var order_index := -1
	if job.order != null:
		var building: Building = buildings.get(job.voxel_position)
		if building != null:
			order_index = building.orders.find(job.order)
	var repair_loose: Variant = null
	if job.repair_loose != null:
		repair_loose = []
		for m: int in job.repair_loose:
			repair_loose.append([m, int(job.repair_loose[m])])
	return {
		"type": int(job.type),
		"voxel": _v3i_data(job.voxel_position),
		"progress": job.progress,
		"block_id": job.block_id,
		"material": int(job.material),
		"build_spec": String(job.build_spec),
		"face_dir": (
			null if job.face_dir == Vector3i.ZERO
			else _v3i_data(job.face_dir)
		),
		"delivered": delivered,
		"components": _items_data(job.components),
		"recipe": String(job.recipe),
		"repair_loose": repair_loose,
		"species": String(job.species),
		"cut": job.cut,
		"fert_target": job.fertilize_target,
		"furniture_kind": int(job.furniture_kind),
		"extra_voxels": extra,
		"suspended": job.suspended,
		"posted_msec": job.posted_msec,
		"order": order_index,
		"animal": animals.find(job.animal) if job.animal != null else -1,
		"patient": units.find(job.patient) if job.patient != null else -1,
		"required_skill": job.required_skill,
		"home_override": job.home_override,
	}


func _load_job(jd: Dictionary) -> void:
	var job := ColonyJob.new(int(jd["type"]), _v3i(jd["voxel"]))
	job.progress = float(jd.get("progress", 0.0))
	job.block_id = int(jd.get("block_id", BlockRegistry.Block.DIRT))
	job.material = int(jd.get("material", BlockRegistry.Resource_.NONE))
	job.build_spec = StringName(jd.get("build_spec", ""))
	if job.build_spec == &"" and job.type == ColonyJob.Type.BUILD:
		# Saves from before spec-keyed builds recorded only the material
		# — the canonical wall spec for it fills the gap.
		job.build_spec = BlockRegistry.wall_spec_for(job.material)
	var face_data = jd.get("face_dir", null)
	if face_data != null:
		job.face_dir = _v3i(face_data)
	for pair: Array in jd.get("delivered", []):
		job.delivered[int(pair[0])] = int(pair[1])
	job.components = _items_from(jd.get("components", []))
	job.recipe = StringName(jd.get("recipe", ""))
	if job.type == ColonyJob.Type.FURNISH:
		# Legacy furnish order — the only kind ever posted was the bed
		# kit's. Furniture now builds in place through the craft path,
		# so the order converts to a bed recipe that a matching crate
		# (the migrated kit) or fresh planks can both satisfy.
		job.type = ColonyJob.Type.CRAFT
		job.recipe = &"bed"
	var repair_loose: Variant = jd.get("repair_loose", null)
	if repair_loose != null:
		job.repair_loose = {}
		for pair: Array in repair_loose:
			job.repair_loose[int(pair[0])] = int(pair[1])
	job.species = StringName(jd.get("species", ""))
	job.cut = bool(jd.get("cut", false))
	job.fertilize_target = float(jd.get("fert_target", 0.0))
	job.furniture_kind = int(jd.get("furniture_kind", 0))
	for e: Array in jd.get("extra_voxels", []):
		job.extra_voxels.append(_v3i(e))
	var order_index := int(jd.get("order", -1))
	if order_index >= 0:
		var building: Building = buildings.get(job.voxel_position)
		if building != null and order_index < building.orders.size():
			job.order = building.orders[order_index]
	job.required_skill = int(jd.get("required_skill", -1))
	job.home_override = bool(jd.get("home_override", false))
	# Animals load after jobs — the index resolves in the second pass at
	# the end of deserialize.
	var animal_index := int(jd.get("animal", -1))
	if animal_index >= 0:
		_job_animal_links[job] = animal_index
	# Units too — a tend/rescue's patient relinks after the roster loads.
	var patient_index := int(jd.get("patient", -1))
	if patient_index >= 0:
		_job_patient_links[job] = patient_index
	_register_job(job)
	if job.type == ColonyJob.Type.FERTILIZE:
		# The scan's cell index is per-cell bookkeeping, not saved state —
		# a restored fertilize job re-binds so the scan won't repost.
		_fertilize_jobs[job.voxel_position] = job
	job.posted_msec = int(jd.get("posted_msec", job.posted_msec))
	if world.sim != null:
		# The native board registered the job at load time — give its
		# real age back or the languish bonus a long-waiting job earned
		# evaporates every save/load.
		world.sim.job_set_posted(job.get_instance_id(), job.posted_msec)
	if bool(jd.get("suspended", false)):
		job.suspended = true
		if world.sim != null:
			world.sim.job_suspend(job.get_instance_id(), true)
	_restore_job_marker(job)


## Rebuilds the designation marker a restored job carries — the same
## look each designate_* puts down, keyed off the job type. Types that
## share a designation (SOW under its farm marker) or wear their marker
## on a building (a worksite's craft tint) handle themselves.
func _restore_job_marker(job: ColonyJob) -> void:
	match job.type:
		ColonyJob.Type.MINE, ColonyJob.Type.CHOP:
			_add_marker(job.voxel_position, _marker_material)
		ColonyJob.Type.CLEAR:
			_add_marker(job.voxel_position, _clear_marker_material)
		ColonyJob.Type.FORAGE:
			_add_marker(job.voxel_position, _forage_marker_material)
		ColonyJob.Type.BUILD:
			if job.face_dir != Vector3i.ZERO:
				_add_face_marker(
					job.voxel_position,
					Flooring.face_index(job.face_dir),
					_build_marker_material
				)
			else:
				_add_marker(
					job.voxel_position, _build_marker_material, null, true
				)
		ColonyJob.Type.FURNISH:
			_add_marker(
				job.voxel_position, _build_marker_material, null, true
			)
			for cell in job.extra_voxels:
				_add_marker(cell, _build_marker_material, null, true)
		ColonyJob.Type.DECONSTRUCT:
			if job.face_dir != Vector3i.ZERO:
				_add_face_marker(
					job.voxel_position,
					Flooring.face_index(job.face_dir),
					_deconstruct_marker_material
				)
			else:
				_add_marker(
					job.voxel_position,
					_deconstruct_marker_material,
					null,
					true
				)
		ColonyJob.Type.CRAFT:
			if job.order != null:
				# The worksite's own marker just switches to the
				# running look.
				_set_marker_appearance(
					job.voxel_position,
					_craft_job_marker_material,
					_worksite_job_mesh(job.voxel_position)
				)
			else:
				if not _designation_markers.has(job.voxel_position):
					_add_marker(
						job.voxel_position,
						_build_marker_material,
						null,
						true
					)
				# A furniture plan marks its whole footprint — every
				# cell is reserved.
				for cell in job.extra_voxels:
					if not _designation_markers.has(cell):
						_add_marker(cell, _build_marker_material, null, true)
		ColonyJob.Type.UNINSTALL:
			for cell in [job.voxel_position] + job.extra_voxels:
				_set_marker_appearance(
					cell, _deconstruct_marker_material, _marker_mesh
				)
		ColonyJob.Type.UNPACK:
			_add_marker(job.voxel_position, _marker_material)


## Recreates a landed pile — same registration as a deposit minus the
## fall, since the save's voxel is already the resting place.
func _load_pile(voxel_position: Vector3i, items: Array[DropItem]) -> void:
	if items.is_empty():
		return
	var existing: ItemPile = item_piles.get(voxel_position)
	if existing != null:
		existing.add_items(items, false)
		_sync_sim_packed(voxel_position)
		return
	var pile := ItemPile.create(voxel_position, world.sim == null)
	add_child(pile)
	item_piles[voxel_position] = pile
	_index_add(_pile_buckets, voxel_position)
	# Registration precedes the fill — add_items' fill_changed signal
	# re-syncs the sim through the pile lookup.
	pile.landed.connect(_on_pile_landed)
	pile.fill_changed.connect(_on_pile_fill_changed)
	pile.add_items(items, false)
	_sync_sim_packed(voxel_position)


func _load_unit(ud: Dictionary) -> Unit:
	var pos: Array = ud.get("position", [0, 0, 0])
	var unit := spawn_unit(_v3i(pos))
	unit.deserialize(ud, self)
	return unit


func _load_animal(ad: Dictionary) -> Animal:
	var pos: Array = ad.get("position", [0, 0, 0])
	var animal := spawn_animal(
		StringName(ad.get("species", "rabbit")), _v3i(pos)
	)
	# spawn_animal drops the body on the ground under the saved point —
	# restore the exact position so a mid-cliff save doesn't pop the
	# animal to the surface.
	var p := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	animal.global_position = p
	animal.deserialize(ad)
	return animal
