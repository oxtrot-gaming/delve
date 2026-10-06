class_name DataPackage
extends RefCounted

## The data-package registry (PLAN item 45). A playthrough's content
## definitions travel as one Dictionary per *pack* — the baseline
## package — plus one *scenario* record for the starting conditions.
## Built-ins register themselves at class load; a future file loader
## feeds the same dictionaries in from res:// or user:// JSON.
##
## Pack schema:
##   id          StringName key
##   name        display name for the selector
##   description one-line summary for the selector
##   biomes      ordered Array of {id, name, color, settleable} — the
##               biome id space; `biome[tile]` indices key into it
##   biome_rules ordered first-match classifier — each rule a Dict of
##               optional bounds {ocean, temp_max, temp_min, precip_max,
##               precip_min, precip_min_slope:[base,pivot,per_c]} plus
##               `biome` naming the id it assigns. Upper bounds are
##               exclusive, lower bounds inclusive.
##   animals     species table — Species.SPECIES shape
##   plants      Plants.SPECIES shape
##   trees       Forest.SPECIES shape
##   worldgen    {saplings: [tree ids], bushes: {id: weight}} — what
##               the terrain generator seeds
##   wildlife    {opening: [species], trickle: [species]} — the site's
##               ambient fauna mix
##
## Scenario schema:
##   id / name / description as above
##   package        owning pack id — a scenario only lists under its
##                  baseline package; absent means any pack
##   settler_count  roster size when `settlers` entries run out
##   settlers       per-settler override list: {skills: {name: level or
##                  [lo, hi]}, knowledge: [gated skill names]}
##   skill_range    [lo, hi] level band rolled on every *ungated* skill
##                  for every settler — background competence
##   knowledge      gated-skill ids every settler knows (level 1)
##   animals        [{species, count, domestic}] — the founding herd
##   items          [{material?, form, spec?, count? | cm3?}] — the
##                  starting goods scattered at the landing
##   entry          {kind: "periphery" | "centre"} — where a *newcomer*
##                  (post-embark arrival) enters the colony; periphery
##                  puts them where their travel bearing crosses the
##                  site boundary, other kinds may spawn them elsewhere
##
## Values may be engine objects (Color, enum ints) or plain data —
## strings and [r,g,b] arrays are normalised at install, so a JSON
## source slots in unchanged.

const VanillaPack := preload("res://scripts/data/pack_vanilla.gd")
const DevScenario := preload("res://scripts/data/scenario_dev.gd")
const TribalScenario := preload("res://scripts/data/scenario_tribal.gd")

static var _packages: Dictionary = {}
static var _scenarios: Dictionary = {}
static var _active_package: Dictionary = {}
static var _active_scenario: Dictionary = {}


static func _static_init() -> void:
	register_package(VanillaPack.package())
	register_scenario(DevScenario.scenario())
	register_scenario(TribalScenario.scenario())


## Registers a pack or scenario definition — duplicate ids replace.
## Normalisation happens here so every read path sees resolved values.
static func register_package(def: Dictionary) -> void:
	_packages[StringName(def.get(&"id", &""))] = _normalize_pack(def)


static func register_scenario(def: Dictionary) -> void:
	_scenarios[StringName(def.get(&"id", &""))] = _normalize_scenario(def)


static func package_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(_packages.keys())
	return out


static func scenario_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(_scenarios.keys())
	return out


## The scenarios that belong to [param package_id] — one with no
## `package` key lists under any baseline.
static func scenario_ids_for(package_id: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _scenarios:
		var owner := StringName(_scenarios[id].get(&"package", &""))
		if owner == &"" or owner == package_id:
			out.append(id)
	return out


static func package_named(id: StringName) -> Dictionary:
	return _packages.get(id, {})


static func scenario_named(id: StringName) -> Dictionary:
	return _scenarios.get(id, {})


static func package_label(id: StringName) -> String:
	return String(_packages.get(id, {}).get(&"name", String(id)))


static func scenario_label(id: StringName) -> String:
	return String(_scenarios.get(id, {}).get(&"name", String(id)))


## Selects the pair a playthrough runs — the pack's tables are
## normalised and installed into the consumers (species, plants,
## forest); the scenario id is just remembered for embark.
## An empty id leaves the active selection alone — older saves carry
## no scenario key and still get the registered default on first read.
static func install(package_id: StringName, scenario_id: StringName) -> void:
	var pack: Dictionary = _packages.get(package_id, {})
	if not pack.is_empty():
		_active_package = pack
		Species.install(animals_table())
		Plants.install(plants_table())
		Forest.install(trees_table())
	elif package_id != StringName():
		push_error("unknown data package %s" % package_id)
	var scn: Dictionary = _scenarios.get(scenario_id, {})
	if not scn.is_empty():
		_active_scenario = scn
	elif scenario_id != StringName():
		push_error("unknown scenario %s" % scenario_id)


## The installed pack — bootstraps the vanilla default on first read so
## tooling and tests see a populated world without staging an embark.
static func package() -> Dictionary:
	if _active_package.is_empty():
		install(&"vanilla", &"dev")
	return _active_package


static func scenario() -> Dictionary:
	if _active_scenario.is_empty():
		install(&"vanilla", &"dev")
	return _active_scenario


## Whether a package or scenario id has been installed — the caller can
## stage a fresh pair without disturbing a running site.
static func package_id() -> StringName:
	return StringName(package().get(&"id", &""))


static func scenario_id() -> StringName:
	return StringName(scenario().get(&"id", &""))


# --- Section accessors ------------------------------------------------------


## The ordered biome defs — index in this list is the tile's biome id.
static func biomes() -> Array:
	return package().get(&"biomes", [])


static func biome_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for def: Dictionary in biomes():
		out.append(def[&"id"])
	return out


## Position of [param id] in the pack's biome order, or -1.
static func biome_index(id: StringName) -> int:
	for i in biomes().size():
		if biomes()[i][&"id"] == id:
			return i
	return -1


## The first-match classification rules WorldGlobe applies.
static func biome_rules() -> Array:
	return package().get(&"biome_rules", [])


## Normalised species tables — same shapes the old in-code SPECIES
## constants carried, so consumers read them unchanged.
static func animals_table() -> Dictionary:
	return package().get(&"animals", {})


static func plants_table() -> Dictionary:
	return package().get(&"plants", {})


static func trees_table() -> Dictionary:
	return package().get(&"trees", {})


## {saplings: [tree ids], bushes: {id: weight}} — the terrain
## generator's species palette.
static func worldgen() -> Dictionary:
	return package().get(&"worldgen", {})


## Ambient fauna mixes — the opening scatter and the respawn trickle.
static func wildlife_opening() -> Array:
	return package().get(&"wildlife", {}).get(&"opening", [])


static func wildlife_trickle() -> Array:
	return package().get(&"wildlife", {}).get(&"trickle", [])


# --- Normalisation ------------------------------------------------------------


## Deep-normalises a pack so every consumer sees the same value types
## whether the def was written in code or parsed from JSON.
static func _normalize_pack(pack: Dictionary) -> Dictionary:
	var out := pack.duplicate(true)
	for section in [&"animals", &"plants", &"trees"]:
		var table: Dictionary = out.get(section, {})
		for id in table:
			table[id] = _normalize_spec(table[id])
	for def: Dictionary in out.get(&"biomes", []):
		if def.has(&"color"):
			def[&"color"] = _color(def[&"color"])
	return out


static func _normalize_spec(def: Dictionary) -> Dictionary:
	var out := def.duplicate(true)
	for key in out.keys():
		var k: StringName = key
		match k:
			&"color", &"bush_color", &"ripe_color", &"leaf_color", \
			&"sapling_color", &"flower_color":
				out[k] = _color(out[k])
			&"material", &"yield_material", &"fruit_material", \
			&"output_material", &"head", &"drop":
				out[k] = _resource(out[k])
			&"trunk", &"branch", &"block":
				out[k] = _block_id(out[k])
	if out.has(&"extras"):
		for e: Dictionary in out[&"extras"]:
			e[&"material"] = _resource(e.get(&"material"))
	return out


## A scenario's skills/knowledge/items land on enum ids and int levels.
static func _normalize_scenario(scn: Dictionary) -> Dictionary:
	var out := scn.duplicate(true)
	for roll: Dictionary in out.get(&"settlers", []):
		roll[&"skills"] = _normalize_skills(roll.get(&"skills", {}))
		roll[&"knowledge"] = _normalize_skills_list(roll.get(&"knowledge", []))
	out[&"knowledge"] = _normalize_skills_list(out.get(&"knowledge", []))
	var items: Array = out.get(&"items", [])
	for i in items.size():
		items[i] = _normalize_item(items[i])
	return out


static func _normalize_skills(skills: Dictionary) -> Dictionary:
	var out := {}
	for name in skills:
		out[_skill_id(name)] = skills[name]
	return out


static func _normalize_skills_list(list: Array) -> Array:
	var out: Array = []
	for name in list:
		out.append(_skill_id(name))
	return out


static func _normalize_item(def: Dictionary) -> Dictionary:
	var out := def.duplicate(true)
	if out.has(&"material"):
		out[&"material"] = _resource(out[&"material"])
	if out.has(&"form"):
		out[&"form"] = _form_id(out[&"form"])
	return out


# --- Primitive resolvers ------------------------------------------------------


## Colours accept a Color, an [r,g,b] or [r,g,b,a] array, or a hex
## string — anything else falls back to mid-grey.
static func _color(v: Variant) -> Color:
	if v is Color:
		return v
	if v is Array and v.size() >= 3:
		return Color(
			float(v[0]), float(v[1]), float(v[2]),
			float(v[3]) if v.size() > 3 else 1.0
		)
	if v is String:
		return Color(v)
	return Color(0.5, 0.5, 0.5)


## A material id: a resolved enum int passes through; a name resolves
## against Resource_ case-insensitively.
static func _resource(v: Variant) -> int:
	if v is int:
		return v
	var name := String(v).to_upper()
	if BlockRegistry.Resource_.has(name):
		return BlockRegistry.Resource_[name]
	push_error("unknown material '%s'" % String(v))
	return BlockRegistry.Resource_.NONE


static func _block_id(v: Variant) -> int:
	if v is int:
		return v
	var name := String(v).to_upper()
	if BlockRegistry.Block.has(name):
		return BlockRegistry.Block[name]
	push_error("unknown block '%s'" % String(v))
	return BlockRegistry.Block.AIR


static func _form_id(v: Variant) -> int:
	if v is int:
		return v
	var name := String(v).to_upper()
	if DropItem.Form.has(name):
		return DropItem.Form[name]
	push_error("unknown item form '%s'" % String(v))
	return DropItem.Form.LOOSE


## A skill id — scenario files name them lowercase ("plants"); the
## ColonyJob.Skill enum carries them uppercase.
static func _skill_id(v: Variant) -> int:
	if v is int:
		return int(v)
	var name := String(v).to_upper()
	if ColonyJob.Skill.has(name):
		return ColonyJob.Skill[name]
	push_error("unknown skill '%s'" % String(v))
	return -1
