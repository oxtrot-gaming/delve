class_name DropItem
extends RefCounted

## One piece of loose material dropped when a block is mined.
##
## Mining yields items totalling 125% of the block's volume: soft material
## drops as a single loose item, hard material shatters into a random mix of
## boulders and cobbles topped up with a loose balance (gravel). Every item
## keeps the mined block's material class.
##
## Volumes are integer cubic centimetres — 1 m³ = 1,000,000 cm³ — so pile
## fill, splits and capacity math are exact: no epsilon anywhere.

enum Form {
	LOOSE, BOULDER, COBBLE, LOG, PLANK, BED, FRUIT, SEED, MEAL, CORPSE,
	SHEET, WIRE, COMPONENT, GARMENT, TOOL, CRATE, BLOCK
}

const CM3_PER_M3 := 1_000_000
const BLOCK_CM3 := CM3_PER_M3
const DROP_CM3 := BLOCK_CM3 * 5 / 4
const BOULDER_CM3 := 100_000
const COBBLE_CM3 := 10_000
## One dressed stone block — the stonecutter's bench output and the
## mason's unit of account. Half a cobble by volume: cutting a cobble
## (10 L) yields one block and 5 L of gravel, cutting a boulder
## (100 L) yields a dozen and 40 L.
const STONE_BLOCK_CM3 := 5_000
## One felled log; a log wall is two of them stood on end.
const LOG_CM3 := 500_000
## One plank: 20% of a log. Three planks and the rest sawdust make a log.
const PLANK_CM3 := LOG_CM3 / 5
const PLANKS_PER_LOG := 3
## One beaten sheet of metal — half a plank's bulk, which is why two
## sheets fill a plank's recipe slot wherever sheet substitutes.
const SHEET_CM3 := PLANK_CM3 / 2
## A coil of drawn wire — sized so a smelt-bench batch of raw metal
## draws into a handful of them.
const WIRE_CM3 := 2_500
## One simple machine component — gears, a cam, a spring — a fistful
## of parts that assemblies like the fabricator and the cooler want.
const COMPONENT_CM3 := 5_000
## One fruit item — a small handful of berries, an acorn, a grain head.
## Discrete, like a log: fruit never merges into bulk. Sized so a
## cooked meal (~0.01 m³) is a few fruits, not the ~50 kg the old
## 25-litre serving implied.
const FRUIT_CM3 := 2_500
## One seed packet — what an extract-seed order yields per fruit; small
## enough that two still mass less than the fruit they came from.
const SEED_CM3 := 1_000
## One cooked meal — a ~0.01 m³ serving, roughly a 1,600-calorie plate
## at the rescaled food density. Discrete: meals never merge into bulk.
const MEAL_CM3 := 10_000
## An uninstalled bed as a strapped kit — a single carryable item.
## LEGACY: bed kits are gone — furniture minifies into a CRATE whose
## volume is the shell plus exactly what the piece was built of. The
## constant stays so [method deserialize] can migrate old saves' kits.
const BED_KIT_CM3 := 400_000
## One garment — a folded piece of clothing or wearable kit, sized so a
## few fit a pile cell and a unit's load alike.
const GARMENT_CM3 := 6_000
## One hand tool — a pickaxe's or knife's bulk. Discrete, like a log:
## a tool never pours into bulk.
const TOOL_CM3 := 8_000
## "Effectively infinite" volume — returned for materials that can't build
## a wall, so uncommitted jobs keep fetching until a material commits.
const INF_CM3 := 1_000_000_000_000

## The materials that smelt into something useful — sheet stock and wire
## stock alike. Metals arrive as loose raw product and leave the bench
## as manufactured goods in these classes.
const METALS: Array = [
	BlockRegistry.Resource_.COPPER,
	BlockRegistry.Resource_.TIN,
	BlockRegistry.Resource_.IRON,
	BlockRegistry.Resource_.GOLD,
]

## The form each item can stand in for in a recipe input — a sheet of
## metal serves anywhere a wood plank would (a metalworker's bench, a
## heater housing, a game board), paying in volume. Substitution is
## one-way: nothing fills a sheet's slot but sheet. Want-forms resolve
## through [method want_form]; pins still apply — a recipe that asks
## for a wood plank *specifically* doesn't take the sheet.
const FORM_SUBSTITUTES: Dictionary = {
	Form.SHEET: Form.PLANK,
}


## The form [param form] fills in a recipe — its own when the recipe
## wants it directly, else its substitute target (sheet → plank) when
## the recipe has no use for the real thing.
static func want_form_for(inputs: Dictionary, form: Form) -> int:
	if inputs.has(form):
		return int(form)
	return int(FORM_SUBSTITUTES.get(form, form))


## Every form that can fill [param form]'s recipe slot — itself plus
## any substitutes pointing at it (plank ← plank, sheet).
static func fill_forms(form: Form) -> Array:
	var out: Array = [int(form)]
	for sub: int in FORM_SUBSTITUTES:
		if FORM_SUBSTITUTES[sub] == int(form):
			out.append(sub)
	return out

## Boulder/cobble count ranges. Kept low enough that their combined volume
## always leaves room for a positive loose balance.
const MIN_BOULDERS := 3
const MAX_BOULDERS := 9
const MIN_COBBLES := 5
const MAX_COBBLES := 30

## Hunger restored per cm³ eaten, per material class — absent entries are
## inedible. The serving rescale shrank food items ~10×, so the density
## went up ~10× to compensate: a meal's worth of raw fruit (~0.01 m³)
## still restores a real meal. Meals are the exception: each carries its
## computed value in [member nutrition] — this entry is only a fallback.
const NUTRITION_PER_CM3: Dictionary = {
	BlockRegistry.Resource_.BERRY: 0.000045,
	# Raw grain eats leaner than berries — processing it is the cooking
	# chain's job when that exists.
	BlockRegistry.Resource_.GRAIN: 0.000035,
	# Fallback for a meal whose provenance was lost (old saves) — about
	# 75% over the raw berry rate, matching the prepare-meal bonus.
	BlockRegistry.Resource_.MEAL: 0.000079,
	# Raw meat eats about like berries — edible but grim (the "ate raw
	# food" thought carries that); cooking it is the kitchen's job.
	BlockRegistry.Resource_.MEAT: 0.000045,
}

## Campfire fuel, per material class — burn-seconds per cm³ for bulk
## fuels, with whole-item burn times in [constant FUEL_SECONDS_PER_ITEM]
## for discrete forms. Leaves and sawdust flash off fast; a split of
## branches carries a fire through a day; a log is the real fuel.
const FUEL_SECONDS_PER_CM3: Dictionary = {
	BlockRegistry.Resource_.LEAF: 0.0005,
	# Loose wood is sawdust and offcuts — same rate as leaves.
	BlockRegistry.Resource_.WOOD: 0.0005,
	BlockRegistry.Resource_.BRANCH: 0.0008,
	# 0.3 m³ of charcoal carries 50% more burn than the 600 s a whole
	# log gives — 900 s of the hottest fuel early colonies can make.
	BlockRegistry.Resource_.CHARCOAL: 0.003,
}
const FUEL_SECONDS_PER_ITEM: Dictionary = {
	Form.LOG: 600.0,
}

## Fruit material → the species a sprouting fruit becomes: oak acorns
## grow into oak saplings, berries into berry bushes — and a grain head
## rots into volunteer wheat, since the grain is the seed. The same map
## tells the extract-seed craft which species its packets carry. Kept on
## the item side so both [Forest] and [Plants] can ask without owning
## the map.
const FRUIT_SPECIES: Dictionary = {
	BlockRegistry.Resource_.ACORN: &"oak",
	BlockRegistry.Resource_.BERRY: &"berry_bush",
	BlockRegistry.Resource_.GRAIN: &"wheat",
	# A dried bundle doesn't sprout — but the extract-seed craft reads
	# the same map, so heal-all is farmable once any bundles exist.
	BlockRegistry.Resource_.MEDICINE: &"heal_all",
	# Cotton doesn't come out of the ground as a fruit, but the map's
	# other job — telling a recipe's SEED output its species — is what
	# the tailor's seed extraction needs.
	BlockRegistry.Resource_.COTTON: &"cotton",
}

## Organic decay, per material (and form where it matters) — game-days
## until the item is gone on average. Bulk ([enum Form.LOOSE]) stacks
## shed random quanta per sweep; every other form is a discrete item
## decaying whole at a per-tick chance. `compost` is the fraction of the
## decayed volume that survives as compost; `spawn` marks fruits whose
## disappearance may sprout a plant on soil. Planks are cured and absent
## on purpose, as is every mineral.
const DECAY_RULES: Array[Dictionary] = [
	{&"material": BlockRegistry.Resource_.ACORN, &"days": 10.0, &"spawn": true},
	{&"material": BlockRegistry.Resource_.BERRY, &"days": 10.0, &"spawn": true},
	{&"material": BlockRegistry.Resource_.SEED, &"days": 60.0},
	# Dry grain keeps better than fresh fruit but still rots eventually —
	# and a rotted grain head can volunteer-sprout wheat on soil, since
	# the grain is the seed.
	{
		&"material": BlockRegistry.Resource_.GRAIN, &"days": 30.0,
		&"spawn": true,
	},
	{
		&"material": BlockRegistry.Resource_.LEAF, &"days": 15.0,
		&"compost": 0.25,
	},
	# Loose wood is sawdust and offcuts — the same rule as leaves.
	{
		&"material": BlockRegistry.Resource_.WOOD, &"form": Form.LOOSE,
		&"days": 15.0, &"compost": 0.25,
	},
	{
		&"material": BlockRegistry.Resource_.BRANCH, &"days": 60.0,
		&"compost": 0.5,
	},
	{
		&"material": BlockRegistry.Resource_.WOOD, &"form": Form.LOG,
		&"days": 120.0, &"compost": 0.5,
	},
	{&"material": BlockRegistry.Resource_.COMPOST, &"days": 60.0},
	# A cooked meal keeps longer than raw fruit, but it still spoils.
	{&"material": BlockRegistry.Resource_.MEAL, &"days": 20.0},
	# Carcass and cuts rot fast — butchering scraps are the slaughter
	# floor's leavings and compost the quickest, which is also how the
	# unharvested share of a kill returns to the soil. Antler, tusk,
	# leather and bone are durable and absent on purpose.
	{
		&"material": BlockRegistry.Resource_.CORPSE, &"days": 3.0,
		&"compost": 0.3,
	},
	{
		&"material": BlockRegistry.Resource_.SCRAPS, &"days": 1.5,
		&"compost": 0.5,
	},
	{
		&"material": BlockRegistry.Resource_.MEAT, &"days": 4.0,
		&"compost": 0.2,
	},
	# Dried herbs keep for seasons, but not forever — no `spawn`: a dried
	# bundle doesn't volunteer into a new plant the way fresh fruit can.
	{
		&"material": BlockRegistry.Resource_.MEDICINE, &"days": 90.0,
		&"compost": 0.25,
	},
	# Raw cotton is an organic fibre — it rots like one. Woven cloth is
	# absent on purpose: it doesn't rot, it weathers (see WEATHER_RULES).
	{
		&"material": BlockRegistry.Resource_.COTTON, &"days": 20.0,
		&"compost": 0.25,
	},
]


## Outdoor weathering — the second decay axis (plan item 24), checked
## per landed pile against `Colony.sees_sky`: an item under any roof or
## overhang weathers nothing; one under open sky weathers at `days`
## alongside whatever organic decay it already has. Weathering destroys
## — it never composts and never sprouts, since it isn't rot. Wood in
## every form weathers, which gives *cured* planks and bed kits (organic
## decay's exemptions) their first reason to want a roof; food weathers
## at its organic lifetime, so an unroofed meal or fruit goes about
## twice as fast. Raw litter (leaf, branch) already rots on its own
## clock and minerals don't weather at all. Rain multiplies these
## rates when item 31 lands.
const WEATHER_RULES: Array[Dictionary] = [
	{&"material": BlockRegistry.Resource_.WOOD, &"days": 150.0},
	{&"material": BlockRegistry.Resource_.ACORN, &"days": 10.0},
	{&"material": BlockRegistry.Resource_.BERRY, &"days": 10.0},
	{&"material": BlockRegistry.Resource_.GRAIN, &"days": 30.0},
	{&"material": BlockRegistry.Resource_.SEED, &"days": 60.0},
	{&"material": BlockRegistry.Resource_.MEAL, &"days": 20.0},
	# Carcasses and offal degrade in the weather at their organic
	# lifetime — left exposed they last about half as long.
	{&"material": BlockRegistry.Resource_.CORPSE, &"days": 3.0},
	{&"material": BlockRegistry.Resource_.SCRAPS, &"days": 1.5},
	{&"material": BlockRegistry.Resource_.MEAT, &"days": 4.0},
	{&"material": BlockRegistry.Resource_.MEDICINE, &"days": 90.0},
	# Cloth doesn't rot, but the sun and rain take it apart on the same
	# clock as loose wood — stored outside it lasts a couple of seasons.
	# Material-keyed, so a cotton garment left out weathers too.
	{&"material": BlockRegistry.Resource_.CLOTH, &"days": 150.0},
]


## The weathering rule covering [param item], or an empty Dictionary for
## materials the elements don't touch. A crate shields its contents —
## the packed items don't weather while they're inside it.
static func weather_rule(item: DropItem) -> Dictionary:
	if item.form == Form.CRATE:
		return {}
	for rule: Dictionary in WEATHER_RULES:
		if int(rule[&"material"]) != item.material:
			continue
		if rule.has(&"form") and int(rule[&"form"]) != item.form:
			continue
		return rule
	return {}


## The decay rule covering [param item], or an empty Dictionary for
## materials that never rot. A crate shields its contents the same way.
static func decay_rule(item: DropItem) -> Dictionary:
	if item.form == Form.CRATE:
		return {}
	for rule: Dictionary in DECAY_RULES:
		if int(rule[&"material"]) != item.material:
			continue
		if rule.has(&"form") and int(rule[&"form"]) != item.form:
			continue
		return rule
	return {}


## Every material a decay rule turns into compost — the compost bin's
## admission set: it takes what rots to compost, nothing else.
static func compostable_materials() -> Array[int]:
	var out: Array[int] = []
	for rule: Dictionary in DECAY_RULES:
		if not rule.has(&"compost"):
			continue
		var m := int(rule[&"material"])
		if not out.has(m):
			out.append(m)
	return out

## Apparel layers — RimWorld's model: garments occupy one or more body
## layers, and two worn garments can't share a layer. ON_SKIN is the
## layer against the body, SHELL the outermost cover, and UTILITY hangs
## off the clothes rather than covering the body — the belt lives there.
enum Layer { ON_SKIN, MIDDLE, SHELL, UTILITY }

## What a garment is — its `spec` key resolves here. `layers` lists the
## body layers it occupies (conflict: a unit can't wear two garments
## sharing one). `holsters` is how many tool slots the garment lends
## the wearer — the tool belt's two — and `carry_mult` scales the
## wearer's carry capacity, the backpack's job.
const APPAREL_SPECS: Dictionary = {
	# The ungated starting garment — shirt and trousers in one piece,
	# the tribal wear every fresh colonist can claim.
	&"tribalwear": {
		&"name": "Tribalwear",
		&"layers": [Layer.ON_SKIN],
	},
	&"tool_belt": {
		&"name": "Tool belt",
		&"layers": [Layer.UTILITY],
		&"holsters": 2,
	},
	&"backpack": {
		&"name": "Backpack",
		&"layers": [Layer.SHELL],
		&"carry_mult": 1.5,
	},
}

## What a TOOL-form item is — a spec the hand model resolves: display
## name, whether it wants both hands, the tool `class` a job's tool
## requirement names (axe, shovel, pick — holster reservations key on
## it too), the `head` material class the item's `material` field takes
## (it decides repairability: stone heads can't be mended), the `life`
## in hardness-units of work the head survives, and a work-rate
## multiplier per use — `chop` for felling, `dig` for soft ground,
## `mine` for hard rock. A spec lacking a use key can't do that work
## at all. Weapons are tools for this purpose when they exist; the
## same flag will mark the two-handers.
const TOOL_SPECS: Dictionary = {
	&"knife": {
		&"name": "Knife", &"two_handed": false, &"class": &"knife",
	},
	&"pickaxe": {
		&"name": "Pickaxe", &"two_handed": false, &"class": &"pick",
		&"head": BlockRegistry.Resource_.IRON,
		&"mine": 1.0, &"dig": 0.9, &"life": 800.0,
	},
	# The primitive set — lashing a cobble head to a stick. Half speed
	# or worse, short-lived, and gone for good when it wears out; the
	# pick on hard rock is bad enough to make the forge worth it.
	&"stone_axe": {
		&"name": "Stone axe", &"two_handed": false, &"class": &"axe",
		&"head": BlockRegistry.Resource_.STONE,
		&"chop": 0.5, &"life": 60.0,
	},
	&"stone_shovel": {
		&"name": "Stone shovel", &"two_handed": false, &"class": &"shovel",
		&"head": BlockRegistry.Resource_.STONE,
		&"dig": 0.6, &"life": 60.0,
	},
	&"stone_pick": {
		&"name": "Stone pick", &"two_handed": false, &"class": &"pick",
		&"head": BlockRegistry.Resource_.STONE,
		&"mine": 0.25, &"dig": 0.4, &"life": 40.0,
	},
	# The forged set — a rod haft and two units of raw iron, made at
	# the toolmaker's bench. Faster, far longer-lived, and repairable.
	&"iron_axe": {
		&"name": "Iron axe", &"two_handed": false, &"class": &"axe",
		&"head": BlockRegistry.Resource_.IRON,
		&"chop": 1.25, &"life": 800.0,
	},
	&"iron_shovel": {
		&"name": "Iron shovel", &"two_handed": false, &"class": &"shovel",
		&"head": BlockRegistry.Resource_.IRON,
		&"dig": 1.2, &"life": 800.0,
	},
	&"iron_pick": {
		&"name": "Iron pick", &"two_handed": false, &"class": &"pick",
		&"head": BlockRegistry.Resource_.IRON,
		&"mine": 1.25, &"dig": 0.9, &"life": 800.0,
	},
}

## The materials a tool haft can be lashed from — a branch is the
## common one, but a straight bone or antler serves. Loose, like all
## rods; the slot is volume-priced, not item-counted.
const ROD_MATERIALS: Array = [
	BlockRegistry.Resource_.BRANCH,
	BlockRegistry.Resource_.BONE,
	BlockRegistry.Resource_.ANTLER,
]
## One tool haft — a split and shaped armload of stick.
const ROD_CM3 := 4_000


## The material class this item is made of (soil, stone, iron, ...).
var material: BlockRegistry.Resource_
var form: Form
## Volume in cubic centimetres.
var volume: int
## The plant species this item came from — carried by seeds so farming
## can plant what the fruit promised. Empty for everything else.
var species: StringName = &""
## The manufactured good this item is — a key of [constant APPAREL_SPECS]
## for a garment, [constant TOOL_SPECS] for a tool. Empty for raw
## materials; a garment keeps it when worn so layering and holsters
## resolve without remembering what the item came from.
var spec: StringName = &""
## Garment condition — 1.0 pristine down to 0 worn through. Worn
## clothing loses it slowly over game-time; the tailor's bench spends
## material to buy it back (repair) or recovers what's left (salvage).
## Meaningless on anything but a garment, where it rides next to
## quality the way quality rides on material.
var wear := 1.0
## Explicit hunger restoration, overriding the per-material rate when
## set (non-negative). A cooked meal carries the value its ingredients
## summed to, times the cook bonus — the meal's provenance lives on the
## item itself since meal material has no ingredient memory.
var nutrition := -1.0
## Craft quality — 1.0 is normal/unrated; a rolled craft stamps the
## maker's skill into it. Only quality-bearing goods (meals, bed kits,
## future tools and apparel) read it; raw materials leave it at 1.0.
var quality := 1.0
## The player's forbid flag — a forbidden item stays where it lies but
## no colonist picks it: hauling, eating, crafting, dressing, sowing and
## every other selection path skip it. Stockpile filters don't un-forbid;
## a forbidden item in a stockpile just sits.
var forbidden := false
## A crate's contents — the exact component items the furniture was
## built of, quality and all, so uninstalling and reinstalling lose
## nothing. Empty on every other form.
var packed: Array[DropItem] = []
## The sheet goods the crate was wrapped in — the planks or metal
## sheets a packer fed the uninstall job. They ride alongside `packed`
## so reinstalling or unpacking hands back exactly what went in.
var shell: Array[DropItem] = []


## The sheet-material shell a minified crate is wrapped in — one plank
## or one metal sheet, paid at uninstall time and handed back when the
## crate is unpacked or installed. The crate's own volume is this plus
## the packed contents.
const CRATE_SHELL_CM3 := PLANK_CM3


## The player-facing tier name for a quality value — 1.0 is "fair",
## the unremarkable middle of the scale.
static func quality_tier(q: float) -> String:
	if q < 0.25:
		return "awful"
	if q < 0.75:
		return "poor"
	if q < 1.25:
		return "fair"
	if q < 1.75:
		return "good"
	if q <= 2.25:
		return "excellent"
	return "masterwork"


func _init(item_material: BlockRegistry.Resource_, item_form: Form, item_volume: int) -> void:
	material = item_material
	form = item_form
	volume = item_volume


## Serialized form: [material, form, volume_cm3, species, nutrition,
## quality, spec, wear, forbidden, packed, shell].
func serialize() -> Array:
	var packed_data: Array = []
	for item in packed:
		packed_data.append(item.serialize())
	var shell_data: Array = []
	for item in shell:
		shell_data.append(item.serialize())
	return [
		int(material), int(form), volume, String(species), nutrition,
		quality, String(spec), wear, forbidden, packed_data, shell_data
	]


static func deserialize(data: Array) -> DropItem:
	var item := DropItem.new(int(data[0]), int(data[1]), int(data[2]))
	item.species = StringName(data[3]) if data.size() > 3 else &""
	item.nutrition = float(data[4]) if data.size() > 4 else -1.0
	item.quality = float(data[5]) if data.size() > 5 else 1.0
	item.spec = StringName(data[6]) if data.size() > 6 else &""
	item.wear = float(data[7]) if data.size() > 7 else 1.0
	item.forbidden = bool(data[8]) if data.size() > 8 else false
	if data.size() > 9:
		for entry: Array in data[9]:
			var packed_item := deserialize(entry)
			if packed_item != null:
				item.packed.append(packed_item)
	if data.size() > 10:
		for entry: Array in data[10]:
			var shell_item := deserialize(entry)
			if shell_item != null:
				item.shell.append(shell_item)
	if item.form == Form.BED:
		# Legacy bed kit: it becomes a bed crate — the planks a fresh
		# bed wants packed inside, and the kit's strapping serves as
		# the shell.
		item.form = Form.CRATE
		item.spec = &"bed"
		item.shell.append(DropItem.new(item.material, Form.PLANK, PLANK_CM3))
		for i in 6:
			item.packed.append(
				DropItem.new(item.material, Form.PLANK, PLANK_CM3)
			)
		item.volume = CRATE_SHELL_CM3 + 6 * PLANK_CM3
	return item


## Display name for a form — the resources list's "log ×2" / "boulder ×4".
static func form_name(form: Form) -> String:
	match form:
		Form.LOOSE:
			return "loose"
		Form.BOULDER:
			return "boulder"
		Form.COBBLE:
			return "cobble"
		Form.LOG:
			return "log"
		Form.PLANK:
			return "plank"
		Form.BED:
			return "bed kit"
		Form.FRUIT:
			return "fruit"
		Form.SEED:
			return "seed"
		Form.MEAL:
			return "meal"
		Form.CORPSE:
			return "corpse"
		Form.SHEET:
			return "sheet"
		Form.WIRE:
			return "wire"
		Form.COMPONENT:
			return "component"
		Form.GARMENT:
			return "garment"
		Form.TOOL:
			return "tool"
		Form.CRATE:
			return "crate"
		Form.BLOCK:
			return "block"
	return "item"


## The canonical cm³ of one item of [param form] — what recipes count
## inputs in. Loose material has no standard size (it pours), so it
## returns 0; recipes take it by volume instead of count.
static func form_volume(form: Form) -> int:
	match form:
		Form.BOULDER:
			return BOULDER_CM3
		Form.COBBLE:
			return COBBLE_CM3
		Form.LOG:
			return LOG_CM3
		Form.PLANK:
			return PLANK_CM3
		Form.BED:
			return BED_KIT_CM3
		Form.FRUIT:
			return FRUIT_CM3
		Form.SEED:
			return SEED_CM3
		Form.MEAL:
			return MEAL_CM3
		Form.SHEET:
			return SHEET_CM3
		Form.WIRE:
			return WIRE_CM3
		Form.COMPONENT:
			return COMPONENT_CM3
		Form.GARMENT:
			return GARMENT_CM3
		Form.TOOL:
			return TOOL_CM3
		Form.BLOCK:
			return STONE_BLOCK_CM3
	return 0


## The apparel-spec record for [param spec_id], or empty for an
## unknown or non-garment spec.
static func apparel_spec(spec_id: StringName) -> Dictionary:
	return APPAREL_SPECS.get(spec_id, {})


## The tool-spec record for [param spec_id], or empty.
static func tool_spec(spec_id: StringName) -> Dictionary:
	return TOOL_SPECS.get(spec_id, {})


## The body layers a garment item occupies — empty for a non-garment,
## which occupies nothing and conflicts with nothing.
static func garment_layers(item: DropItem) -> Array:
	return apparel_spec(item.spec).get(&"layers", [])


## How many tool holsters a garment lends its wearer — 0 for most.
static func garment_holsters(item: DropItem) -> int:
	return int(apparel_spec(item.spec).get(&"holsters", 0))


## The carry-capacity multiplier a garment lends — 1.0 for most.
static func garment_carry_mult(item: DropItem) -> float:
	return float(apparel_spec(item.spec).get(&"carry_mult", 1.0))


## True when [param item] is a tool — something a hand can hold.
## Weapons are tools for this purpose when they exist. (`is_tool`
## collides with `Script.is_tool()` — a class resource resolves the
## built-in before its own statics.)
static func is_tool_item(item: DropItem) -> bool:
	return item.form == Form.TOOL


## True when the tool wants both hands — today nothing does, but the
## flag's read everywhere hands are counted so the first two-hander
## lands as a spec change, not a refactor.
static func tool_two_handed(item: DropItem) -> bool:
	return bool(tool_spec(item.spec).get(&"two_handed", false))


## The tool's class — the slot a job's requirement and a holster's
## reservation both name. Empty for a non-tool.
static func tool_class(item: DropItem) -> StringName:
	return tool_spec(item.spec).get(&"class", &"")


## The work-rate multiplier the spec gives [param use] — `chop`,
## `dig` or `mine`. 0 when the spec can't do that work at all, which
## is also the requirement check: a shovel has no `mine` key, so it
## can never serve where hard rock wants a pick.
static func tool_use_speed(item: DropItem, use: StringName) -> float:
	return float(tool_spec(item.spec).get(use, 0.0))


## Hardness-units of work the tool's head survives — wear accrues one
## point per unit of job progress, so a 40-life pick outlasts about
## ten ore blocks. 0 for a spec that never wears.
static func tool_use_life(item: DropItem) -> float:
	return float(tool_spec(item.spec).get(&"life", 0.0))


## True when the tool's head is a metal that can be re-forged — iron
## tools mend at the toolmaker's bench; stone heads are firewood.
static func tool_repairable(item: DropItem) -> bool:
	return is_tool_item(item) and METALS.has(int(item.material))


## Display name for a garment, tool or crate — its spec's name, falling
## back to material-plus-form for unspecced items ("leather garment").
func spec_name() -> String:
	var record := apparel_spec(spec)
	if record.is_empty():
		record = tool_spec(spec)
	if record.is_empty() and form == Form.CRATE:
		record = BlockRegistry.furniture_spec(spec)
	if not record.is_empty():
		var label := String(record.get(&"name", record.get(&"label", spec)))
		return "crate — %s" % label if form == Form.CRATE else label
	return "%s %s" % [
		BlockRegistry.resource_name_of(material).to_lower(),
		form_name(form),
	]


## The item's mass in kilograms — volume through the material's bulk
## density. This is what hauling weighs: a unit's carry/drag capacities
## are kilograms, not cm³, so a loose shovel of feathers and one of
## gold ore stop being interchangeable.
func mass_kg() -> float:
	if form == Form.CRATE:
		# A crate weighs its shell plus everything packed inside — a
		# stone table in a wooden crate doesn't get lighter.
		var mass := 0.0
		for item in shell:
			mass += item.mass_kg()
		if shell.is_empty():
			mass = (
				float(CRATE_SHELL_CM3) / 1000.0
				* BlockRegistry.density_of(material)
			)
		for item in packed:
			mass += item.mass_kg()
		return mass
	return float(volume) / 1000.0 * BlockRegistry.density_of(material)


## True when items of [param material] can be eaten.
static func is_food(material: BlockRegistry.Resource_) -> bool:
	return NUTRITION_PER_CM3.has(material)


## Hunger restored by eating [param volume] cm³ of [param material].
static func nutrition_of(material: BlockRegistry.Resource_, volume: int) -> float:
	return float(NUTRITION_PER_CM3.get(material, 0.0)) * volume


## Hunger restored by eating this whole item — its explicit nutrition
## when one was computed (a cooked meal), else the material rate.
func nutrition_value() -> float:
	if nutrition >= 0.0:
		# A prepared meal's worth scales with the cook's craft —
		# 0.95 + 0.05·quality: masterwork is a bit richer, a botched
		# recipe a bit thinner.
		return nutrition * (0.95 + 0.05 * quality)
	return nutrition_of(material, volume)


## Burn-seconds of campfire fuel this item is worth — 0 for things that
## don't burn. Discrete fuels rate per item; bulk fuels per cm³. The
## campfire's fetch scores piles on this total: a half-dry leaf pile
## feeds a fire for a breath while one log carries it for days.
static func fuel_seconds_of(item: DropItem) -> float:
	var per_item := float(FUEL_SECONDS_PER_ITEM.get(item.form, 0.0))
	if per_item > 0.0:
		return per_item
	if item.form != Form.LOOSE:
		return 0.0
	return float(FUEL_SECONDS_PER_CM3.get(item.material, 0.0)) * item.volume


## The stack of items dropped when [param block_id] is mined. Empty for blocks
## with no drop.
static func for_block(block_id: int) -> Array[DropItem]:
	var drops: Array[DropItem] = []
	var material_class := BlockRegistry.drop_of(block_id)
	if material_class == BlockRegistry.Resource_.NONE:
		return drops

	# A log wall is its two logs stood on end — breaking one hands them
	# back, plus the usual loose 25% as splinters.
	if block_id == BlockRegistry.Block.LOG_WALL:
		drops.append(DropItem.new(material_class, Form.LOG, LOG_CM3))
		drops.append(DropItem.new(material_class, Form.LOG, LOG_CM3))
		drops.append(DropItem.new(material_class, Form.LOOSE, 250_000))
		return drops

	if BlockRegistry.resource_is_loose(material_class):
		drops.append(DropItem.new(material_class, Form.LOOSE, DROP_CM3))
		return drops

	var boulders := randi_range(MIN_BOULDERS, MAX_BOULDERS)
	var cobbles := randi_range(MIN_COBBLES, MAX_COBBLES)

	# Orebearing blocks split their yield between the intrusion mineral
	# and its country rock at the ore's `share` — a fraction of the mined
	# cubic metre (hematite 1:1 → 0.5 m³, native gold 1:99 → 0.01 m³).
	# Each boulder and cobble rolls which it is; the gravel then makes up
	# the balance so the voxel's total mineral yield stays on target —
	# a 1:99 voxel almost always drops only gold gravel amid the stone.
	var is_ore := BlockRegistry.is_ore(block_id)
	var mineral := material_class
	var host := material_class
	var share := 1.0
	if is_ore:
		var spec := BlockRegistry.ore_spec(block_id)
		mineral = spec[&"mineral"]
		host = spec[&"host"]
		share = float(spec[&"share"])

	var mineral_out := 0
	for i in boulders:
		var is_mineral := is_ore and randf() < share
		if is_mineral:
			mineral_out += BOULDER_CM3
		drops.append(DropItem.new(
			mineral if is_mineral else host, Form.BOULDER, BOULDER_CM3
		))
	for i in cobbles:
		var is_mineral := is_ore and randf() < share
		if is_mineral:
			mineral_out += COBBLE_CM3
		drops.append(DropItem.new(
			mineral if is_mineral else host, Form.COBBLE, COBBLE_CM3
		))
	var gravel := DROP_CM3 - boulders * BOULDER_CM3 - cobbles * COBBLE_CM3
	if gravel > 0:
		if not is_ore:
			drops.append(DropItem.new(material_class, Form.LOOSE, gravel))
			return drops
		var ore_gravel := clampi(
			int(round(share * BLOCK_CM3)) - mineral_out, 0, gravel
		)
		if ore_gravel > 0:
			drops.append(DropItem.new(mineral, Form.LOOSE, ore_gravel))
		if gravel - ore_gravel > 0:
			drops.append(DropItem.new(host, Form.LOOSE, gravel - ore_gravel))
	return drops
