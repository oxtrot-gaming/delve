class_name VanillaPack
extends RefCounted

## The baseline data package — temperate-tribal content for the stock
## planet. The species tables stay in their home files (the schema docs
## live beside them); this pack assembles the full section set:
## biomes + classification rules, animals, plants, trees, the worldgen
## species palette, and the ambient wildlife mix.
##
## Biome ids are package-local StringNames — `biome[tile]` stores the
## index into [member biomes], not an engine enum.


## The Whittaker table as ordered first-match rules — each rule's
## bounds are optional; upper bounds exclusive, lower inclusive. The
## ordering is load-bearing: ocean rules first (they only match under
## `ocean: true`), then the cold column, then the temperate band, then
## the tropical floor where the rain-forest line climbs with heat.
const BIOME_RULES: Array = [
	{&"biome": &"ice_cap", &"ocean": true, &"temp_max": 0.0},
	{&"biome": &"ocean", &"ocean": true},
	{&"biome": &"tundra", &"temp_max": -5.0},
	{&"biome": &"boreal_forest", &"temp_max": 5.0, &"precip_min": 40.0},
	{&"biome": &"tundra", &"temp_max": 5.0},
	{&"biome": &"temperate_grassland", &"temp_max": 18.0, &"precip_max": 30.0},
	{&"biome": &"woodland_shrubland", &"temp_max": 18.0, &"precip_max": 75.0},
	{&"biome": &"temperate_seasonal_forest", &"temp_max": 18.0, &"precip_max": 200.0},
	{&"biome": &"temperate_rain_forest", &"temp_max": 18.0},
	{&"biome": &"subtropical_desert", &"precip_max": 45.0},
	# The closed-canopy line: hotter climates need more rain.
	{&"biome": &"tropical_rain_forest", &"precip_min_slope": [160.0, 20.0, 8.0]},
	{&"biome": &"tropical_seasonal_forest"},
]

## Each biome's soil spec — see DataPackage.biome_soil. `topsoil` /
## `subsoil` are weight tables over the soil classes (topsoil: poor /
## soil / rich / clay / sand / peat; subsoil: clay / sand / frozen, the
## remainder being plain parent dirt); a seeded patch field resolves
## the weights into clumps. `depth_m` is the base soil column before
## slope and climate scaling. USDA orders inform the table (see the
## biome→soil correspondence notes) but never appear at runtime: a
## biome with several orders is a patchwork of the classes they imply.
const BIOMES: Array[Dictionary] = [
	{&"id": &"ocean", &"name": "Ocean",
		&"color": Color(0.10, 0.25, 0.44), &"settleable": false},
	{&"id": &"ice_cap", &"name": "Ice cap",
		&"color": Color(0.90, 0.94, 0.95), &"settleable": false},
	# Gelisol — thin poor topsoil over permafrost: hard but playable.
	{&"id": &"tundra", &"name": "Tundra",
		&"color": Color(0.62, 0.60, 0.53),
		&"soil": {
			&"topsoil": {&"poor": 3, &"soil": 1},
			&"subsoil": {&"frozen": 3, &"clay": 1},
			&"depth_m": 1.5,
		}},
	# Spodosol — acidic, leached, sandy lenses under the conifers.
	{&"id": &"boreal_forest", &"name": "Boreal forest",
		&"color": Color(0.17, 0.36, 0.29),
		&"soil": {
			&"topsoil": {&"poor": 2, &"soil": 3, &"rich": 1, &"sand": 1},
			&"subsoil": {&"clay": 1, &"none": 3},
			&"depth_m": 2.5,
		}},
	# Mollisol — the fertile prairie: soil and rich soil in large
	# clumps, roughly 2:1, and deep.
	{&"id": &"temperate_grassland", &"name": "Temperate grassland",
		&"color": Color(0.62, 0.66, 0.34),
		&"soil": {
			&"topsoil": {&"soil": 2, &"rich": 1},
			&"subsoil": {&"clay": 1, &"none": 2},
			&"depth_m": 3.5,
		}},
	# Inceptisol — modestly developed, ordinary ground.
	{&"id": &"woodland_shrubland", &"name": "Woodland/shrubland",
		&"color": Color(0.46, 0.53, 0.31),
		&"soil": {
			&"topsoil": {&"soil": 3, &"poor": 1},
			&"subsoil": {&"clay": 1, &"none": 2},
			&"depth_m": 2.5,
		}},
	# Alfisol/inceptisol — fertile forest floor, clay-rich B horizon.
	{&"id": &"temperate_seasonal_forest", &"name": "Temperate seasonal forest",
		&"color": Color(0.24, 0.49, 0.24),
		&"soil": {
			&"topsoil": {&"soil": 2, &"rich": 1, &"poor": 1},
			&"subsoil": {&"clay": 2, &"none": 2},
			&"depth_m": 3.0,
		}},
	# Spodosol/alfisol/inceptisol patchwork — mixed but deep and wet.
	{&"id": &"temperate_rain_forest", &"name": "Temperate rain forest",
		&"color": Color(0.13, 0.37, 0.22),
		&"soil": {
			&"topsoil": {&"soil": 2, &"poor": 1, &"rich": 1},
			&"subsoil": {&"clay": 2, &"none": 2},
			&"depth_m": 3.5,
		}},
	# Aridisol — sand and thin poor soil; clay still recoverable.
	{&"id": &"subtropical_desert", &"name": "Subtropical desert",
		&"color": Color(0.82, 0.70, 0.45),
		&"soil": {
			&"topsoil": {&"sand": 3, &"poor": 1},
			&"subsoil": {&"clay": 1, &"none": 2},
			&"depth_m": 1.5,
		}},
	# Alfisol/ultisol/aridisol transition — decent but patchy.
	{&"id": &"tropical_seasonal_forest", &"name": "Tropical seasonal forest",
		&"color": Color(0.42, 0.62, 0.28),
		&"soil": {
			&"topsoil": {&"soil": 2, &"poor": 1},
			&"subsoil": {&"clay": 2, &"none": 1},
			&"depth_m": 2.5,
		}},
	# Oxisol/ultisol — jungle on highly weathered ground: deep but
	# leached, poor topsoil over heavy clay.
	{&"id": &"tropical_rain_forest", &"name": "Tropical rain forest",
		&"color": Color(0.10, 0.42, 0.20),
		&"soil": {
			&"topsoil": {&"poor": 2, &"soil": 1},
			&"subsoil": {&"clay": 3, &"none": 1},
			&"depth_m": 4.0,
		}},
]

## Wetland topsoil — cells the hydrology pass flags saturated resolve
## to peat regardless of the biome's own spec (histosol needs drainage
## context, not climate alone).
const WETLAND_SOIL: Dictionary = {
	&"topsoil": {&"peat": 3, &"poor": 1},
	&"subsoil": {&"clay": 1, &"none": 1},
	&"depth_m": 2.0,
}

## Dry ground touching open water — a sandy margin.
const SHORE_SOIL: Dictionary = {
	&"topsoil": {&"sand": 3, &"poor": 1},
	&"subsoil": {&"sand": 1, &"none": 1},
	&"depth_m": 1.5,
}


static func package() -> Dictionary:
	return {
		&"id": &"vanilla",
		&"name": "Temperate wilds",
		&"description": (
			"The stock planet: Whittaker biomes, familiar wildlife, "
			+ "and a temperate flora."
		),
		&"biomes": BIOMES,
		&"biome_rules": BIOME_RULES,
		&"wetland_soil": WETLAND_SOIL,
		&"shore_soil": SHORE_SOIL,
		&"animals": Species.SPECIES,
		&"plants": Plants.SPECIES,
		&"trees": Forest.SPECIES,
		# What the terrain generator seeds: sapling slots pick from the
		# tree list, bush slots roll the weighted mix — heal-all stays a
		# one-in-eight slot so a colony still farms it.
		&"worldgen": {
			&"saplings": [&"oak"],
			&"bushes": {&"berry_bush": 7, &"heal_all": 1},
		},
		# Ambient fauna — the opening scatter covers each diet and
		# temperament; the trickle weights prey.
		&"wildlife": {
			&"opening": [
				&"deer", &"deer", &"deer", &"rabbit", &"rabbit",
				&"boar", &"wolf", &"bear",
			],
			&"trickle": [
				&"deer", &"deer", &"rabbit", &"rabbit", &"boar", &"wolf",
			],
		},
	}
