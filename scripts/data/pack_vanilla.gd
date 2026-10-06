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

const BIOMES: Array[Dictionary] = [
	{&"id": &"ocean", &"name": "Ocean",
		&"color": Color(0.10, 0.25, 0.44), &"settleable": false},
	{&"id": &"ice_cap", &"name": "Ice cap",
		&"color": Color(0.90, 0.94, 0.95), &"settleable": false},
	{&"id": &"tundra", &"name": "Tundra",
		&"color": Color(0.62, 0.60, 0.53)},
	{&"id": &"boreal_forest", &"name": "Boreal forest",
		&"color": Color(0.17, 0.36, 0.29)},
	{&"id": &"temperate_grassland", &"name": "Temperate grassland",
		&"color": Color(0.62, 0.66, 0.34)},
	{&"id": &"woodland_shrubland", &"name": "Woodland/shrubland",
		&"color": Color(0.46, 0.53, 0.31)},
	{&"id": &"temperate_seasonal_forest", &"name": "Temperate seasonal forest",
		&"color": Color(0.24, 0.49, 0.24)},
	{&"id": &"temperate_rain_forest", &"name": "Temperate rain forest",
		&"color": Color(0.13, 0.37, 0.22)},
	{&"id": &"subtropical_desert", &"name": "Subtropical desert",
		&"color": Color(0.82, 0.70, 0.45)},
	{&"id": &"tropical_seasonal_forest", &"name": "Tropical seasonal forest",
		&"color": Color(0.42, 0.62, 0.28)},
	{&"id": &"tropical_rain_forest", &"name": "Tropical rain forest",
		&"color": Color(0.10, 0.42, 0.20)},
]


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
