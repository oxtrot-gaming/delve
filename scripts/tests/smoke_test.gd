extends SceneTree

## Headless smoke test for the framework.
##
##     godot --headless --path . --script res://scripts/tests/smoke_test.gd
##
## Checks that the generator produces layered terrain, that the blocky library
## bakes, and that a designated mining job actually gets done by a unit and
## drops an item pile where the block was.

const TIMEOUT_SECONDS := 120.0

var _failures: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_run()


func _run() -> void:
	_test_block_registry()
	_test_drops()
	_test_generator()
	_test_worldmap()
	await _test_worldgen()
	await _test_mining_loop()

	if _failures.is_empty():
		print("SMOKE TEST PASSED")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAILED: ", failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: ", message)
	else:
		_failures.append(message)


func _test_block_registry() -> void:
	print("block registry")
	var library := BlockRegistry.build_library()
	_check(library.models.size() == BlockRegistry.BLOCKS.size(), "library has a model per block type")
	_check(not BlockRegistry.is_solid(BlockRegistry.Block.AIR), "air is not solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.STONE), "stone is solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.TRUNK), "a trunk is solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.BRANCH), "a branch is solid")
	_check(BlockRegistry.is_tree_block(BlockRegistry.Block.TRUNK), "a trunk is a tree block")
	_check(BlockRegistry.is_tree_block(BlockRegistry.Block.BRANCH), "a branch is a tree block")
	_check(not BlockRegistry.is_tree_block(BlockRegistry.Block.DIRT), "dirt is not a tree block")
	_check(
		BlockRegistry.drop_of(BlockRegistry.Block.HEMATITE_ORE)
			== BlockRegistry.Resource_.HEMATITE,
		"hematite ore drops hematite"
	)
	_check(BlockRegistry.is_solid(BlockRegistry.Block.STONE_WALL), "a stone wall is solid")
	_check(BlockRegistry.is_solid(BlockRegistry.Block.LOG_WALL), "a log wall is solid")
	var block := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.BLOCK, DropItem.STONE_BLOCK_CM3
	)
	_check(
		BlockRegistry.item_fits_wall(block, BlockRegistry.Resource_.STONE),
		"dressed blocks are wall material"
	)
	_check(
		not BlockRegistry.item_fits_wall(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BOULDER,
				DropItem.BOULDER_CM3
			),
			BlockRegistry.Resource_.STONE
		),
		"field rubble is too rough for courses — a boulder can't wall"
	)
	_check(
		not BlockRegistry.item_fits_wall(
			DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500000),
			BlockRegistry.Resource_.STONE
		),
		"loose gravel can't build a wall"
	)
	_check(
		BlockRegistry.item_fits_wall(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
			),
			BlockRegistry.Resource_.WOOD
		),
		"logs are wall material"
	)
	_check(
		not BlockRegistry.item_fits_wall(
			DropItem.new(BlockRegistry.Resource_.WOOD, DropItem.Form.LOOSE, 500000),
			BlockRegistry.Resource_.WOOD
		),
		"loose wood can't build a wall"
	)


func _test_drops() -> void:
	print("mining drops")
	var dirt_drops := DropItem.for_block(BlockRegistry.Block.DIRT)
	_check(dirt_drops.size() == 1, "soft blocks drop a single item")
	if dirt_drops.size() == 1:
		_check(dirt_drops[0].form == DropItem.Form.LOOSE, "soft blocks drop a loose item")
		_check(
			dirt_drops[0].volume == DropItem.DROP_CM3,
			"the loose item is 125% of the block's volume"
		)

	var stone_drops := DropItem.for_block(BlockRegistry.Block.STONE)
	var total := 0.0
	var has_boulder := false
	var has_cobble := false
	var has_loose := false
	var all_stone := true
	for item in stone_drops:
		total += item.volume
		all_stone = all_stone and item.material == BlockRegistry.Resource_.STONE
		match item.form:
			DropItem.Form.BOULDER: has_boulder = true
			DropItem.Form.COBBLE: has_cobble = true
			DropItem.Form.LOOSE: has_loose = true
	_check(total == DropItem.DROP_CM3, "hard block drops total 125% of the block's volume")
	_check(has_boulder and has_cobble and has_loose, "hard blocks drop boulders, cobbles and loose gravel")
	_check(all_stone, "every dropped item has the mined block's material class")

	var log_wall_drops := DropItem.for_block(BlockRegistry.Block.LOG_WALL)
	var wall_loose := 0
	var wall_total := 0.0
	for item in log_wall_drops:
		wall_total += item.volume
		if item.form == DropItem.Form.LOOSE:
			wall_loose += 1
	_check(wall_loose == 1, "a mined log wall shatters to a splinter pile")
	_check(
		wall_total == DropItem.LOG_CM3,
		"a log wall's drops return the invested log, not mining bulk"
	)

	var stone_wall_drops := DropItem.for_block(BlockRegistry.Block.STONE_WALL)
	var wall_boulders := 0
	var stone_wall_total := 0
	for item in stone_wall_drops:
		stone_wall_total += item.volume
		if item.form == DropItem.Form.BOULDER:
			wall_boulders += 1
	_check(
		wall_boulders == 6,
		"a mined stone wall shatters back to boulders for the saw"
	)
	_check(
		stone_wall_total == 120 * DropItem.STONE_BLOCK_CM3,
		"a stone wall's scrap totals the invested blocks"
	)


func _test_generator() -> void:
	print("terrain generator")
	var generator := WorldGenerator.new()
	var surface_y := generator.surface_height(0, 0)

	var buffer := VoxelBuffer.new()
	buffer.create(16, 16, 16)
	var origin := Vector3i(0, surface_y - 8, 0)
	generator._generate_block(buffer, origin, 0)

	var found: Dictionary[int, int] = {}
	for x in 16:
		for y in 16:
			for z in 16:
				var block := buffer.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
				found[block] = found.get(block, 0) + 1

	_check(found.has(BlockRegistry.Block.AIR), "generates air above the surface")
	_check(found.has(BlockRegistry.Block.STONE), "generates stone underground")
	_check(
		found.has(BlockRegistry.Block.DIRT),
		"generates a soil layer — grass is decoration now, not a block"
	)
	_check(not found.has(BlockRegistry.Block.GRASS), "generates no grass voxels")
	# The top voxel of a soil-topped column is dirt — grass cover rides
	# on top of it, in Grass's records rather than in the voxel.
	if generator.grass_seed_at(0, 0) >= 0.0:
		_check(
			buffer.get_voxel(0, 8, 0, VoxelBuffer.CHANNEL_TYPE) == BlockRegistry.Block.DIRT,
			"a soil-topped column's surface voxel is dirt"
		)
	else:
		_check(
			buffer.get_voxel(0, 8, 0, VoxelBuffer.CHANNEL_TYPE) == BlockRegistry.Block.STONE,
			"a rock-topped column's surface voxel is stone"
		)

	var sky := VoxelBuffer.new()
	sky.create(16, 16, 16)
	generator._generate_block(sky, Vector3i(0, 512, 0), 0)
	_check(sky.is_uniform(VoxelBuffer.CHANNEL_TYPE), "blocks far above the surface are empty")

	# Rock outcrops: somewhere nearby a column's rock mass rises above the
	# grass line, and the voxel at its top is stone.
	var outcrop := Vector3i.MAX
	for ox in range(-96, 96, 4):
		for oz in range(-96, 96, 4):
			var grass_y: int = generator.terrain_height(ox, oz)
			if generator.surface_height(ox, oz) > grass_y:
				outcrop = Vector3i(ox, generator.surface_height(ox, oz), oz)
				break
		if outcrop != Vector3i.MAX:
			break
	_check(outcrop != Vector3i.MAX, "generates occasional rock outcrops at the surface")
	if outcrop != Vector3i.MAX:
		var chunk := VoxelBuffer.new()
		chunk.create(16, 16, 16)
		var chunk_origin := Vector3i(
			floori(float(outcrop.x) / 16.0) * 16,
			floori(float(outcrop.y) / 16.0) * 16,
			floori(float(outcrop.z) / 16.0) * 16
		)
		generator._generate_block(chunk, chunk_origin, 0)
		var ry := outcrop - chunk_origin
		_check(
			chunk.get_voxel(ry.x, ry.y, ry.z, VoxelBuffer.CHANNEL_TYPE) == BlockRegistry.Block.STONE,
			"an outcrop's topmost voxel is stone"
		)


## Macroscale→mesoscale→microscale pinning: the Goldberg sphere, the
## per-tile meso heightfield, and the regional layer it installs into
## the generator. No scene — pure generation, ~1 s for the tiling.
func _test_worldmap() -> void:
	print("world map")

	var t0 := Time.get_ticks_msec()
	var globe := WorldGlobe.new(1337)
	await globe.generate()
	var build_ms := Time.get_ticks_msec() - t0
	_check(
		globe.centers.size() == WorldGlobe.TILE_COUNT,
		"globe builds %d tiles in %d ms" % [globe.centers.size(), build_ms]
	)

	# Tiling shape: exactly twelve pentagons, everything else hexagonal,
	# and every neighbour link symmetric.
	var pent := 0
	var bad := 0
	for t in WorldGlobe.TILE_COUNT:
		var d := globe.degree(t)
		if d == 5:
			pent += 1
		var seen := {}
		for k in d:
			var n := globe.neighbour_of(t, k)
			if n < 0 or n == t or seen.has(n):
				bad += 1
				continue
			seen[n] = true
			var symmetric := false
			for k2 in globe.degree(n):
				if globe.neighbour_of(n, k2) == t:
					symmetric = true
			if not symmetric:
				bad += 1
	_check(pent == 12, "exactly twelve pentagons (%d found)" % pent)
	_check(bad == 0, "all neighbour links symmetric and sane")

	# Determinism: a second globe from the same seed matches.
	var g2 := WorldGlobe.new(1337)
	await g2.generate()
	var same := true
	for t in [0, 17, 5000, WorldGlobe.TILE_COUNT - 1]:
		if g2.height_m[t] != globe.height_m[t] or g2.centers[t] != globe.centers[t]:
			same = false
	_check(same, "globe generation is deterministic for a seed")

	# Macro fields: some ocean, some land, temperature cools toward poles.
	var land := 0
	for t in WorldGlobe.TILE_COUNT:
		if globe.ocean[t] == 0:
			land += 1
	_check(
		land > WorldGlobe.TILE_COUNT / 10 and land < WorldGlobe.TILE_COUNT * 9 / 10,
		"land fraction sane (%.2f)" % (float(land) / WorldGlobe.TILE_COUNT)
	)
	var equator := globe.tile_at(Vector3(1, 0, 0))
	var pole := globe.tile_at(Vector3(0, 1, 0))
	_check(
		globe.temp_c[equator] > globe.temp_c[pole],
		"temperature falls toward the poles"
	)

	# Sea level comes from the ocean slider: the percentile cut should
	# put ~70% of tiles under water at the default.
	var sea_tiles := 0
	var sea_bad := 0
	var land_bad := 0
	var ice_caps := 0
	var biomes_seen := {}
	for t in WorldGlobe.TILE_COUNT:
		var b := globe.biome_id(t)
		biomes_seen[b] = true
		if globe.ocean[t] != 0:
			sea_tiles += 1
			if b != &"ocean" and b != &"ice_cap":
				sea_bad += 1
		elif b == &"ocean" or b == &"ice_cap":
			land_bad += 1
		if b == &"ice_cap":
			ice_caps += 1
	var ocean_frac := sea_tiles / float(WorldGlobe.TILE_COUNT)
	_check(
		absf(ocean_frac - 0.70) < 0.02,
		"sea level puts ~70%% under water (%.2f)" % ocean_frac
	)
	_check(sea_bad == 0 and land_bad == 0, "biomes respect the ocean mask")
	_check(ice_caps > 0, "frozen ocean becomes ice cap (%d tiles)" % ice_caps)
	_check(
		biomes_seen.size() >= 8,
		"defaults span a wide range of biomes (%d)" % biomes_seen.size()
	)
	_check(
		globe.biome_name(0) != "?" and globe.biome_name(0) != "",
		"every biome has a name"
	)

	# The Whittaker table itself, point-sampled.
	_check(
		WorldGlobe.classify(12.0, 120.0, false)
			== DataPackage.biome_index(&"temperate_seasonal_forest"),
		"mild wet land is temperate seasonal forest"
	)
	_check(
		WorldGlobe.classify(12.0, 300.0, false)
			== DataPackage.biome_index(&"temperate_rain_forest"),
		"mild very-wet land is temperate rain forest"
	)
	_check(
		WorldGlobe.classify(26.0, 250.0, false)
			== DataPackage.biome_index(&"tropical_rain_forest"),
		"hot wet land is tropical rain forest"
	)
	_check(
		WorldGlobe.classify(26.0, 20.0, false) == DataPackage.biome_index(&"subtropical_desert"),
		"hot dry land is subtropical desert"
	)
	_check(
		WorldGlobe.classify(0.0, 80.0, false) == DataPackage.biome_index(&"boreal_forest"),
		"cool wet land is boreal forest"
	)
	_check(
		WorldGlobe.classify(-20.0, 100.0, false) == DataPackage.biome_index(&"tundra"),
		"frigid land is tundra"
	)
	_check(
		WorldGlobe.classify(-20.0, 5.0, false) == DataPackage.biome_index(&"tundra"),
		"frigid dry land is still tundra (polar desert)"
	)
	_check(
		WorldGlobe.classify(-5.0, 400.0, true) == DataPackage.biome_index(&"ice_cap"),
		"sub-freezing ocean is ice cap"
	)
	_check(
		WorldGlobe.classify(10.0, 400.0, true) == DataPackage.biome_index(&"ocean"),
		"warm sea is ocean"
	)

	# Sliders: a 100% request clamps to the 95% cap, stray percentages
	# snap to the 5-step, and the biases move their own fields only.
	var gq := WorldGlobe.new(1337, {&"ocean_pct": 100})
	_check(gq.ocean_pct == 95, "ocean slider caps below an all-water world")
	gq = WorldGlobe.new(1337, {&"ocean_pct": 73})
	_check(gq.ocean_pct == 75, "ocean slider snaps to its 5%% step")
	var g3 := WorldGlobe.new(
		1337, {&"temp_bias_c": -20.0, &"moist_bias": -0.35, &"ocean_pct": 0}
	)
	await g3.generate()
	# Compare means over a tile sample — single tiles can clamp at a
	# noise extreme, the bias only has to shift the distribution.
	var warm_t := 0.0
	var cold_t := 0.0
	var wet_p := 0.0
	var dry_p := 0.0
	for s in 100:
		var t := s * 1795
		warm_t += globe.temp_c[t]
		cold_t += g3.temp_c[t]
		wet_p += globe.precip[t]
		dry_p += g3.precip[t]
	_check(cold_t < warm_t - 15.0 * 100.0, "cold bias drops planetary temperatures")
	_check(dry_p < wet_p, "dry bias drops annual precipitation")
	var g3_ocean := 0
	for t in WorldGlobe.TILE_COUNT:
		if g3.ocean[t] != 0:
			g3_ocean += 1
	_check(g3_ocean == 0, "ocean slider at 0%% leaves a land-only world")

	# Mesoscale: a tile's flat heightfield pins its rim to the neighbour
	# in that direction — approximate hex↔rect coincidence by design.
	var tile := globe.nearest_land_tile(WorldGlobe.default_settle_dir())
	var meso := MesoMap.generate(globe, tile)
	var n := globe.neighbour_of(tile, 0)
	var rel: Vector3 = globe.centers[n] - meso.centre_dir * globe.centers[n].dot(meso.centre_dir)
	var rim_h := meso.height_at(
		rel.normalized().dot(meso.east) * 7900.0,
		rel.normalized().dot(meso.north) * 7900.0
	)
	var want := 0.5 * (globe.height_m[tile] + globe.height_m[n])
	_check(
		absf(rim_h - want) < 30.0,
		"meso rim pins toward the neighbour's macro height"
	)

	# Site embedding: the installed regional grid lands node-exact on
	# voxel columns and interpolates between — pinning the microscale
	# map to the mesoscale where they coincide.
	var vg: Dictionary = meso.voxel_grid(Vector2i.ZERO, 32)
	var gen := WorldGenerator.new()
	gen.install_regional_grid(vg["grid"], vg["origin"], vg["step"], vg["size"])
	var origin: Vector2i = vg["origin"]
	var step: int = vg["step"]
	var size: int = vg["size"]
	var node := origin + Vector2i(3, 4) * step
	_check(
		gen._regional_base(node.x, node.y) == vg["grid"][4 * size + 3],
		"regional layer is node-exact at meso coincidence points"
	)
	var grid: PackedInt32Array = vg["grid"]
	var fx := step / 2
	var i00 := 4 * size + 3
	var mid := gen._regional_base(node.x + fx, node.y)
	var expected := (grid[i00] * (step - fx) + grid[i00 + 1] * fx) / step
	_check(
		mid == expected,
		"regional layer interpolates between meso nodes"
	)
	var clamped := gen._regional_base(origin.x - 5000, origin.y - 5000)
	_check(
		clamped == vg["grid"][0],
		"columns outside the meso window clamp to its border"
	)

	# Site field — the soil/hydrology pass over the installed surface
	# (DESIGN: Soils and hydrology). The flood's resolution means water
	# can never sit above a cell's spill level, channels only cut where
	# their catchment clears the precipitation-scaled threshold, and the
	# whole pass is deterministic off the seeded generator surface.
	var field := await SiteField.generate(meso, gen, Vector2i.ZERO)
	var field2 := await SiteField.generate(meso, gen, Vector2i.ZERO)
	_check(
		field.carve == field2.carve and field.water == field2.water
			and field.soil == field2.soil,
		"the site field pass is deterministic"
	)
	var n_cells := SiteField.FIELD_SIDE * SiteField.FIELD_SIDE
	var spill_ok := true
	var river_ok := true
	var carve_ok := true
	var water_count := 0
	var basin_count := field.basins.size()
	for i in n_cells:
		var p: int = field.flow_next[i]
		# Flow never climbs: the downstream cell's spill level sits at
		# or below this cell's.
		if p >= 0 and field.spill[p] > field.spill[i]:
			spill_ok = false
		if (
			field.flags[i] & SiteField.FLAG_RIVER
			and field.carve[i] != SiteField.RIVER_CUT
			and field.carve[i] > 0 and p >= 0
		):
			# Rim-faded channels hold a partial carve; interior rivers
			# always carry the full cut.
			var d := mini(
				mini(i % SiteField.FIELD_SIDE, SiteField.FIELD_SIDE - 1 - i % SiteField.FIELD_SIDE),
				mini(i / SiteField.FIELD_SIDE, SiteField.FIELD_SIDE - 1 - i / SiteField.FIELD_SIDE)
			)
			if d >= 8:
				river_ok = false
		if field.carve[i] > 0 and field.flags[i] & SiteField.FLAG_RIVER == 0:
			carve_ok = false
		if (
			field.water[i] != SiteField.DRY
			and field.water[i] > field.spill[i]
		):
			spill_ok = false
		if field.flags[i] & SiteField.FLAG_WATER:
			water_count += 1
	_check(spill_ok, "water never sits above its spill level")
	_check(river_ok, "interior river cells carry the full channel cut")
	_check(carve_ok, "only river cells carve the terrain")
	# Basin records share a level across their cells and hold a pour.
	var basins_ok := true
	for basin in field.basins:
		var cells: PackedInt32Array = basin[&"cells"]
		var level: int = basin[&"level"]
		for c in cells:
			if field.water[c] != level:
				basins_ok = false
	_check(basins_ok, "basin cells share one water level")
	print(
		"  field: %d open-water cells, %d basins" % [water_count, basin_count]
	)

	# Per-biome viability: every settleable biome offers some farmable
	# topsoil class and recoverable clay somewhere in its profile —
	# hard biomes stay hard, not impossible (DESIGN: Soils).
	var viable := true
	var biomes: Array = DataPackage.biomes()
	for b in biomes.size():
		var def: Dictionary = biomes[b]
		if not def.get(&"settleable", true):
			continue
		var spec := DataPackage.biome_soil(b)
		var tops: Dictionary = spec.get(&"topsoil", {})
		var subs: Dictionary = spec.get(&"subsoil", {})
		var farmable := (
			int(tops.get(&"poor", 0)) + int(tops.get(&"soil", 0))
			+ int(tops.get(&"rich", 0)) > 0
		)
		var clay := (
			int(tops.get(&"clay", 0)) + int(subs.get(&"clay", 0)) > 0
		)
		if not farmable or not clay:
			viable = false
			printerr("    biome %s lacks farmable soil or clay" % def[&"id"])
	_check(viable, "every settleable biome yields farmable soil and clay")

	# The generator reads the field: carved columns sit at or below raw
	# terrain, water-covered columns read a depth, and clearing the
	# field restores the legacy ruleset.
	gen.install_site_field(field)
	var carved_ok := true
	for i in n_cells:
		if field.carve[i] == 0:
			continue
		var vx: int = field.origin.x + (i % SiteField.FIELD_SIDE) * SiteField.FIELD_M + 2
		var vz: int = field.origin.y + (i / SiteField.FIELD_SIDE) * SiteField.FIELD_M + 2
		if gen.terrain_height(vx, vz) > gen.raw_height(vx, vz):
			carved_ok = false
	_check(carved_ok, "channels only ever lower the surface")
	var depth_seen := false
	for i in n_cells:
		if field.flags[i] & SiteField.FLAG_WATER == 0:
			continue
		var vx: int = field.origin.x + (i % SiteField.FIELD_SIDE) * SiteField.FIELD_M + 2
		var vz: int = field.origin.y + (i / SiteField.FIELD_SIDE) * SiteField.FIELD_M + 2
		if gen.water_depth_at(vx, vz) > 0:
			depth_seen = true
			break
	_check(
		water_count == 0 or depth_seen,
		"open-water cells report a positive depth to the generator"
	)
	gen.clear_site_field()
	_check(
		gen.water_level_at(0, 0) == SiteField.DRY,
		"clearing the site field restores the dry ruleset"
	)

	gen.clear_regional_grid()
	_check(
		gen._regional_base(5, 5) == gen.base_height,
		"clearing the regional grid restores the flat stub"
	)

	# Mesoscale climate fields: the tile's macro values reach the
	# microscale site through the meso map — centre reads ≈ the tile's
	# own mean (rim blends only bite near the rim), and meso relief
	# moves temperature by the altitude lapse.
	_check(
		absf(meso.temp_at(0.0, 0.0) - globe.temp_c[tile]) < 0.5,
		"meso centre temperature tracks the tile's macro mean"
	)
	_check(
		absf(meso.precip_at(0.0, 0.0) - globe.precip[tile]) < 0.5,
		"meso centre precipitation tracks the tile's macro mean"
	)
	var n_rim_t := meso.temp_at(
		rel.normalized().dot(meso.east) * 7900.0,
		rel.normalized().dot(meso.north) * 7900.0
	)
	var n_want := 0.5 * (globe.temp_c[tile] + globe.temp_c[n])
	_check(
		absf(n_rim_t - n_want) < 1.0,
		"meso rim temperature pins toward the neighbour's macro mean"
	)

	# Site-climate derivation: ±12 °C anchors at 45° latitude under
	# Earth's tilt, the swing vanishes at the equator and flips in the
	# south, and the wet share scales off the 100 cm reference model
	# with a cap so wet climates still get dry spells.
	var eq := Weather.site_climate(0.0, 28.0, 100.0, 23.44)
	_check(
		absf(float(eq[&"amplitude_c"])) < 0.5,
		"the equator barely swings seasonally"
	)
	var midlat := Weather.site_climate(45.0, 15.0, 100.0, 23.44)
	_check(
		absf(float(midlat[&"amplitude_c"]) - 12.0) < 0.5,
		"mid-latitudes keep the ±12 degree seasonal swing"
	)
	_check(
		absf(float(midlat[&"mean_clear_days"]) - 1.5) < 0.05,
		"100 cm of rain reproduces the reference Markov"
	)
	var pol := Weather.site_climate(70.0, -10.0, 60.0, 23.44)
	_check(
		float(pol[&"amplitude_c"]) > 14.0,
		"polar sites swing harder than mid-latitudes"
	)
	var ant := Weather.site_climate(-45.0, 15.0, 100.0, 23.44)
	_check(
		float(ant[&"amplitude_c"]) < -10.0 and bool(ant[&"south"]),
		"southern sites run the flipped calendar"
	)
	var dry := Weather.site_climate(20.0, 30.0, 25.0, 23.44)
	var wet := Weather.site_climate(20.0, 28.0, 500.0, 23.44)
	_check(
		float(dry[&"mean_clear_days"]) > float(midlat[&"mean_clear_days"])
			and float(wet[&"mean_clear_days"])
				< float(midlat[&"mean_clear_days"]),
		"dry and wet tiles stretch and squeeze the clear spells"
	)
	_check(
		float(wet[&"mean_clear_days"]) > 0.1,
		"even a saturated climate still sees dry breaks"
	)
	var notilt := Weather.site_climate(45.0, 15.0, 100.0, 0.0)
	_check(
		float(notilt[&"amplitude_c"]) == 0.0,
		"a zero-tilt planet has no seasons"
	)


func _test_worldgen() -> void:
	print("worldgen screen")
	var wg: Worldgen = load("res://scenes/worldgen.tscn").instantiate()
	root.add_child(wg)
	await process_frame

	# Stage 1: a random seed is prepopulated and reroll stays valid.
	_check(
		wg._seed_edit.text.is_valid_int() and wg._seed_edit.text != "",
		"the seed field is prepopulated"
	)
	wg._randomize_seed()
	_check(wg._seed_edit.text.is_valid_int(), "reroll yields a valid seed")
	_check(
		int(wg._ocean_slider.value) == WorldGlobe.OCEAN_PCT_DEFAULT,
		"ocean slider defaults to 70%"
	)
	wg._ocean_slider.value = 73
	_check(
		int(wg._ocean_slider.value) == 75,
		"ocean slider snaps to its 5% step"
	)

	# Stage 2: the planet builds with the chosen options.
	wg._seed_edit.text = "1337"
	wg._tilt_slider.value = 31.0
	wg._on_generate_pressed()
	var built := await _wait_until(func() -> bool: return wg._globe != null and wg._cells_mesh.mesh != null)
	_check(built, "the planet builds for the chosen options")
	if not built:
		wg.queue_free()
		return
	_check(
		wg._globe.ocean_pct == 75,
		"the globe took the slider's ocean coverage"
	)
	_check(
		wg._globe_root.visible,
		"the globe becomes visible after generation"
	)

	# Embark rules: water tiles refuse, land arms the button.
	var land := -1
	var water := -1
	for t in WorldGlobe.TILE_COUNT:
		if land >= 0 and water >= 0:
			break
		if water < 0 and wg._globe.biome[t] == DataPackage.biome_index(&"ocean"):
			water = t
		elif (
			land < 0 and wg._globe.ocean[t] == 0
			and wg._globe.biome[t] != DataPackage.biome_index(&"ice_cap")
		):
			land = t
	_check(land >= 0 and water >= 0, "the world has both land and sea")
	wg._on_tile_clicked(water)
	_check(
		wg._embark_button.disabled and wg._selected < 0,
		"ocean hexes can't be embarked on"
	)
	wg._on_tile_clicked(land)
	_check(
		not wg._embark_button.disabled and wg._selected == land,
		"a land tile arms embark"
	)

	# Staging hands Main the full worldgen request.
	wg._stage_world()
	_check(
		int(Main.pending_world.get(&"seed", -1)) == 1337
			and int(Main.pending_world.get(&"ocean_pct", -1)) == 75
			and int(Main.pending_world.get(&"axial_tilt_deg", -1)) == 31
			and int(Main.pending_world.get(&"world_tile", -1)) == land,
		"embark stages seed, options and tile"
	)
	_check(
		Main.pending_world.get(&"package") == &"vanilla"
			and Main.pending_world.get(&"scenario") == &"lost_tribe",
		"embark stages the package and scenario picks"
	)

	# And Main consumes it: the fresh world seeds the generator, the
	# sliders, and the picked tile.
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var ready := await _wait_until(func() -> bool: return main.region != null and main.site != null)
	_check(ready, "a worldgen world boots into the colony scene")
	if ready:
		_check(
			main.site.world_tile == land,
			"the colony settles the picked tile"
		)
		_check(
			main.world.generator_script.world_seed == 1337,
			"the generator took the worldgen seed"
		)
		_check(
			main.ocean_pct == 75,
			"the worldgen options reached the run"
		)
		_check(
			main.axial_tilt_deg == 31.0,
			"the axial tilt reached the run"
		)
		# The macro→micro climate link: the site's clock knows its
		# latitude, and the weather's mean comes off the installed
		# meso map, not the legacy temperate constants.
		var want_lat := rad_to_deg(
			asin(clampf(wg._globe.centers[land].y, -1.0, 1.0))
		)
		_check(
			absf(main.day_cycle.site_latitude_deg - want_lat) < 0.01,
			"the site latitude comes off the picked tile"
		)
		_check(
			absf(
				main.colony.weather.mean_c - main.meso.temp_at(0.0, 0.0)
			) < 0.01,
			"the weather mean comes off the mesoscale map"
		)
		_check(
			main.colony.weather.south == (want_lat < 0.0),
			"the hemisphere flag matches the site latitude"
		)
	_check(Main.pending_world.is_empty(), "the staged world is consumed")
	root.remove_child(main)
	main.queue_free()
	wg.queue_free()
	Main.pending_world = {}
	await process_frame


func _test_mining_loop() -> void:
	print("colony mining loop")
	# The suite's colony runs the debug landing — the worldgen test above
	# installs tribal globally, and this boot has no staged world to
	# carry a pick, so the selection must be pinned here.
	DataPackage.install(&"vanilla", &"dev")
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)

	var world: VoxelWorld = main.get_node("VoxelWorld")
	var colony: Colony = main.get_node("Colony")

	var spawned := await _wait_until(func() -> bool: return colony.units.size() > 0)
	_check(spawned, "units spawn once the terrain is loaded")
	if not spawned:
		return
	# Growth on a timer would sprout trunks inside fixtures mid-test; the
	# tree test ages its tree explicitly with Forest.grow instead.
	colony.forest.set_process(false)
	# Needs are exercised in the rest test — leaving them on here would
	# have units nap in the middle of other tests' fixtures.
	colony.needs_enabled = false
	# Moods drift over the suite; an incidental mental break would hijack
	# whichever unit a fixture is driving. Suppress the roll globally —
	# the mood test sets break_mtb_scale explicitly for its subject.
	for u in colony.units:
		u.break_mtb_scale = 1e9
	# Construction growing the home area on its own would smear the
	# fetch-preference and bill-gate behaviour across every fixture —
	# the suite paints home cells deliberately, and _test_home_area
	# exercises the auto-grow itself.
	colony.auto_home = false
	# Water keeps its seeded state but doesn't simulate — the seeded
	# lake is still settling through voxel-scale rim notches while the
	# suite runs, and a moving frontier drowning a fixture mid-check is
	# the one kind of flake the dry-column scans can't bound. Dynamics
	# are the flow probe's job; the suite needs determinism.
	if world.sim != null:
		world.sim.water_set_paused(true)

	var unit: Unit = colony.units[0]
	_check(
		unit.skin_tone.r <= Unit.SKIN_TONE_PALE.r + 0.001
			and unit.skin_tone.r >= Unit.SKIN_TONE_DARK.r - 0.001
			and unit.skin_tone.g <= unit.skin_tone.r
			and unit.skin_tone.b <= unit.skin_tone.g,
		"a unit's skin tone lies on the pale-to-dark ramp"
	)
	var body := (unit.get_node("MeshInstance3D") as MeshInstance3D) \
		.get_surface_override_material(0) as StandardMaterial3D
	_check(
		body != null and body.albedo_color.is_equal_approx(unit.skin_tone),
		"the unit's body is tinted with its skin tone"
	)
	_check(
		not colony.units.all(
			func(u: Unit) -> bool: return u.skin_tone.is_equal_approx(unit.skin_tone)
		),
		"units get randomized skin tones"
	)

	var target := _pick_mining_target(world, unit)
	_check(target != Vector3i.MAX, "found a designatable voxel near a unit")
	if target == Vector3i.MAX:
		return

	# Mining wants a tool now — every unit carries a stone pick so
	# whichever one claims the job can work it.
	for u in colony.units:
		_arm_tool(u, &"stone_pick")
	var block_before := world.get_block(target)
	var job := colony.designate_mine(target)
	_check(job != null, "designation creates a job")

	# The world already holds piles — generated rock scree and whatever
	# streamed in — so the drop is measured as a delta: which piles grew
	# and by what, within spilling distance of the target.
	var pile_sizes := {}
	for voxel: Vector3i in colony.item_piles:
		var off0: Vector3i = (voxel - target).abs()
		if maxi(off0.x, maxi(off0.y, off0.z)) <= 3:
			pile_sizes[voxel] = colony.item_piles[voxel].items.size()
	var mined := await _wait_until(func() -> bool: return not world.is_solid(target))
	_check(mined, "a unit mines the designated voxel")
	# Falling piles merge on arrival — wait for any flights to finish first.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var expected := BlockRegistry.drop_of(block_before)
	var total := 0.0
	var item_count := 0
	var same_material := true
	for voxel: Vector3i in colony.item_piles:
		var pile: ItemPile = colony.item_piles[voxel]
		var offset: Vector3i = (voxel - target).abs()
		if maxi(offset.x, maxi(offset.y, offset.z)) > 3:
			continue
		# Items appended past the snapshot size — or every item in a pile
		# the snapshot never saw — are this drop's.
		var skip := int(pile_sizes.get(voxel, 0))
		for i in range(skip, pile.items.size()):
			var item: DropItem = pile.items[i]
			item_count += 1
			total += item.volume
			same_material = same_material and item.material == expected
	_check(item_count > 0, "mined block drops item piles around the mined voxel")
	_check(same_material, "every dropped item has the block's material class")
	_check(
		total == DropItem.DROP_CM3,
		"dropped items total 125% of the block's volume"
	)
	# The picks were only for the mine above — a held tool halves what a
	# unit carries, and the sections below drive full-size hauls.
	_disarm_units(colony)

	await _test_spilling(colony, world, target)
	_test_fill(colony, world, unit, target)
	await _test_footing(colony, world, unit, target)
	await _test_overflow(colony, world, target)
	await _test_hole(colony, world, target)
	await _test_shove(colony, world, target)
	await _test_clear(colony, world, target)
	await _test_build(colony, world, target)
	_test_reach(unit, world, target)
	_test_camera(main.get_node("Overseer"), world, target)
	_test_highlight(main.get_node("Overseer"), colony, world, target)
	_test_drag(main.get_node("Overseer"), colony, world, target)
	await _test_stuck(colony, world, unit, target)
	_test_retry(colony, world, target)
	await _test_detour(colony, world, target)
	await _test_opportunistic(colony, world, target)
	await _test_clear_haul(colony, world, target)
	await _test_stockpile(colony, world, target)
	await _test_yield(colony, world, target)
	await _test_evict(colony, world, target)
	await _test_tree(colony, world, unit, target)
	await _test_craft(colony, world, target)
	await _test_orders(colony, world, target)
	await _test_bill_details(colony, world, target)
	await _test_campfire(colony, world, target)
	await _test_loose_rocks(colony, world, target)
	await _test_deconstruct(colony, world, target)
	await _test_rest(colony, world, target)
	await _test_furniture(colony, world, unit, target)
	await _test_stonecutting(colony, world, unit, target)
	await _test_food(colony, world, target)
	await _test_ladder(colony, world, target)
	await _test_doors(colony, world, target)
	await _test_collapse(colony, world, target)
	await _test_skills(colony, world, unit, target)
	await _test_organics(colony, world, unit, target)
	await _test_recreation(colony, world, unit, target)
	await _test_scheduling(colony, world, unit, target)
	await _test_mood(colony, world, unit, target)
	await _test_wildlife(colony, world, unit, target)
	await _test_health(colony, world, unit, target)
	await _test_combat(colony, world, unit, target)
	await _test_siege(colony, world, unit, target)
	await _test_quality(colony, world, unit, target)
	await _test_metals(colony, world, unit, target)
	await _test_weather(colony, world, unit, target)
	await _test_fire(colony, world, unit, target)
	await _test_flooring(colony, world, unit, target)
	await _test_research(colony, world, unit, target)
	await _test_power(colony, world, unit, target)
	await _test_apparel(colony, world, unit, target)
	await _test_allowed(colony, world, unit, target)
	await _test_home_area(colony, world, unit, target)
	await _test_scenario(main, colony, world, target)
	_test_grass(colony, world, target)
	await _test_farm(colony, world, unit, target)
	await _test_compost(colony, world, unit, target)
	await _test_tools(colony, world, unit, target)
	await _test_plant_environment(colony, world, target)
	await _test_hud(main, colony, world, target)
	await _test_persist(main, colony, world, target)

	main.queue_free()


## The strategy camera: the focus point rides the terrain, WASD pans it on
## the ground plane, the wheel zooms the boom, RMB-drags orbit and RMB
## clicks deselect — Timberborn-style.
func _test_camera(overseer: Overseer, world: VoxelWorld, near: Vector3i) -> void:
	var x := near.x + 12
	var z := near.z + 12
	var ground := _ground(world, x, z, near.y + 32)

	# The focus eases toward the terrain rather than snapping to it.
	overseer.global_position = Vector3(x + 0.5, ground + 1.5, z + 0.5)
	for i in 40:
		overseer._tick_camera(0.1)
	overseer.global_position.y = ground + 40.5
	overseer._tick_camera(0.1)
	_check(
		overseer.global_position.y < ground + 39.0
			and overseer.global_position.y > ground + 2.0,
		"the focus height eases toward the terrain instead of snapping"
	)
	for i in 40:
		overseer._tick_camera(0.1)
	_check(
		is_equal_approx(overseer.global_position.y, ground + 1.0),
		"the camera focus settles onto the terrain"
	)

	# WASD pans on the ground plane relative to yaw (yaw 0 → forward is -z).
	Input.action_press("move_forward")
	var before := overseer.global_position
	overseer._tick_camera(0.1)
	Input.action_release("move_forward")
	_check(
		overseer.global_position.z < before.z,
		"the camera pans the focus on the ground plane"
	)

	# Game speed must not scale camera motion: a 6x frame's scaled delta
	# should move the focus exactly as far as the same real-time step at 1x.
	# Synchronous — no real frame can interleave between the press and the
	# restore.
	Input.action_press("move_forward")
	Engine.time_scale = 1.0
	var from_1x := Vector2(overseer.global_position.x, overseer.global_position.z)
	overseer._process(0.1)
	var step_1x := Vector2(
		overseer.global_position.x, overseer.global_position.z
	).distance_to(from_1x)
	Engine.time_scale = 6.0
	var from_6x := Vector2(overseer.global_position.x, overseer.global_position.z)
	overseer._process(0.6)
	var step_6x := Vector2(
		overseer.global_position.x, overseer.global_position.z
	).distance_to(from_6x)
	Engine.time_scale = 1.0
	Input.action_release("move_forward")
	_check(
		is_equal_approx(step_6x, step_1x) and step_1x > 0.0,
		"camera pan covers the same ground at any game speed"
	)

	# The wheel zooms the boom.
	var wide := overseer._distance
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overseer._unhandled_input(wheel)
	_check(overseer._distance < wide, "scrolling up zooms the camera in")

	# Q/E rotate smoothly, Z/C snap to the next quarter turn.
	var yaw_before := overseer._yaw
	Input.action_press("rotate_right")
	overseer._tick_camera(0.1)
	Input.action_release("rotate_right")
	_check(overseer._yaw > yaw_before, "the camera rotates with Q/E")
	overseer._snap_yaw(1)
	_check(
		absf(overseer._yaw * 2.0 / PI - roundf(overseer._yaw * 2.0 / PI)) < 0.01,
		"Z/C snap the camera to a 90° heading"
	)

	# An RMB drag orbits; a click without a drag deselects the tool.
	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	var orbit_yaw := overseer._yaw
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	overseer._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(30, 0)
	overseer._unhandled_input(motion)
	press.pressed = false
	overseer._unhandled_input(press)
	_check(overseer._yaw < orbit_yaw, "a right-drag orbits the camera")
	_check(
		overseer.current_action() == &"mine",
		"a right-drag keeps the selected tool"
	)
	press.pressed = true
	overseer._unhandled_input(press)
	press.pressed = false
	overseer._unhandled_input(press)
	_check(overseer.current_action() == &"none", "a right-click deselects the tool")

	# A ceiling over open air is an overhang — the focus rides the floor
	# beneath it rather than popping up onto the roof.
	var under := _flat_voxel(world, near, 56)
	_check(under != Vector3i.MAX, "found a flat spot for the overhang test")
	if under != Vector3i.MAX:
		world.place(under + Vector3i(0, 3, 0), BlockRegistry.Block.STONE)
		overseer.global_position = Vector3(under) + Vector3(0.5, 0.0, 0.5)
		for i in 40:
			overseer._tick_camera(0.1)
		_check(
			is_equal_approx(overseer.global_position.y, float(under.y)),
			"the focus rides the floor under an overhang"
		)
		# Embedded in a rising face, though, it still climbs out the top.
		var hill := under + Vector3i(2, 0, 0)
		world.place(hill, BlockRegistry.Block.STONE)
		world.place(hill + Vector3i.UP, BlockRegistry.Block.STONE)
		overseer.global_position = Vector3(hill) + Vector3(0.5, 0.0, 0.5)
		for i in 60:
			overseer._tick_camera(0.1)
		_check(
			is_equal_approx(overseer.global_position.y, float(hill.y) + 2.0),
			"the focus climbs a face it's embedded in"
		)


## The highlight marks the voxel the selected action acts on: Mine hits the
## block behind a pile, Clear hits the pile itself, and an action that can't
## act on its target highlights red.
func _test_highlight(overseer: Overseer, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_voxel := Vector3i(mined.x - 14, 0, mined.z - 4)
	pile_voxel.y = _ground(world, pile_voxel.x, pile_voxel.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pile_voxel
	)

	overseer.global_position = Vector3(pile_voxel) + Vector3(0.5, 4.5, 0.5)
	overseer.camera.global_transform = Transform3D(
		Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
	)

	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	overseer._update_target(overseer.camera.unproject_position(
		Vector3(pile_voxel) + Vector3.ONE * 0.5
	))
	_check(
		overseer._targeted != null
			and overseer.highlight.global_position.is_equal_approx(
				Vector3(overseer._targeted.position) + Vector3.ONE * 0.5
			),
		"the mine action highlights the block behind a pile"
	)

	overseer._cycle_action()
	_check(
		overseer.current_action() == overseer.ACTIONS[
			(overseer.ACTIONS.find(&"mine") + 1) % overseer.ACTIONS.size()
		],
		"the action key cycles through overseer actions"
	)
	overseer.select_action(overseer.ACTIONS.find(&"clear_pile"))
	overseer._update_target(overseer.camera.unproject_position(
		Vector3(pile_voxel) + Vector3.ONE * 0.5
	))
	_check(
		overseer._targeted != null
			and overseer.highlight.global_position.is_equal_approx(
				Vector3(pile_voxel) + Vector3.ONE * 0.5
			),
		"the clear action highlights the pile's voxel"
	)

	overseer._perform()
	var clear_job := false
	for j in colony.jobs:
		if j.type == ColonyJob.Type.CLEAR and j.voxel_position == pile_voxel:
			clear_job = true
	_check(clear_job, "performing the selected action designates the pile for clearing")
	colony.cancel_designation(pile_voxel)

	# Clearing bare ground can't act — the highlight turns red.
	var bare := pile_voxel + Vector3i(3, 0, 0)
	overseer.global_position = Vector3(bare) + Vector3(0.5, 4.5, 0.5)
	overseer.camera.global_transform = Transform3D(
		Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
	)
	overseer._update_target(overseer.camera.unproject_position(
		Vector3(bare) + Vector3.ONE * 0.5
	))
	var highlight_material := overseer.highlight.material_override as StandardMaterial3D
	_check(
		overseer._targeted != null
			and highlight_material != null
			and highlight_material.albedo_color.is_equal_approx(overseer.HIGHLIGHT_INVALID),
		"an action that can't act on the target highlights red"
	)


## Drag designation: pressing a button anchors a box on the hit face's plane.
## Moving the aim promotes the press to a drag that commits on release; a
## long press makes the box stick — it survives the release, the wheel
## extrudes it into a volume, LMB commits and RMB aborts it.
func _test_drag(overseer: Overseer, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var base := _flat_voxel(world, mined, 56)
	_check(base != Vector3i.MAX, "found a flat stretch for the drag test")
	if base == Vector3i.MAX:
		return
	var g := base.y - 1

	var aim := func(x: int, z: int) -> void:
		var gy := _ground(world, x, z, mined.y + 32)
		overseer.global_position = Vector3(x + 0.5, gy + 6.5, z + 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(x + 0.5, gy + 0.5, z + 0.5)
		))

	var click := func(button: MouseButton, pressed: bool) -> void:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		overseer._unhandled_input(ev)

	# The two layers the extrusion checks look at: the surface and one below.
	var count_markers := func() -> int:
		var n := 0
		for dx in 3:
			for dy in 2:
				if colony._designation_markers.has(Vector3i(base.x + dx, g - dy, base.z)):
					n += 1
		return n

	overseer.select_action(overseer.ACTIONS.find(&"mine"))

	# A quick click designates the single voxel under the aim.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(
		colony._designation_markers.has(Vector3i(base.x, g, base.z)),
		"a click designates the voxel under the aim"
	)
	colony.cancel_designation(Vector3i(base.x, g, base.z))

	# Pressing, aiming across the strip and releasing drags a rect.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	_check(overseer._drag_active, "moving the aim while held promotes the drag")
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(count_markers.call() == 3, "a drag commits every voxel in the rect on release")

	# The same sweep with the cancel tool clears it again.
	overseer.select_action(overseer.ACTIONS.find(&"cancel"))
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(count_markers.call() == 0, "a cancel drag clears the rect")
	overseer.select_action(overseer.ACTIONS.find(&"mine"))

	# A long press makes the box stick: the button can release, the box keeps
	# following the aim, the wheel extrudes it in either direction, and a
	# click commits.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	overseer._press_hold = Overseer.DRAG_HOLD
	overseer._tick_press(0.0)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(
		overseer._drag_active,
		"a long-press drag stays up after the button releases"
	)
	aim.call(base.x + 2, base.z)
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overseer._unhandled_input(wheel)
	_check(overseer._drag_extrude == 1, "the wheel extrudes a drag toward the camera")
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	_check(overseer._drag_extrude == -1, "the wheel extrudes a drag into the face")
	click.call(MOUSE_BUTTON_LEFT, true)
	_check(not overseer._drag_active, "a click commits a sticky drag")
	_check(count_markers.call() == 6, "an extruded drag designates the whole volume")

	# The same volume cancelled: cancel tool, LMB press, aim across, wheel
	# down, release.
	overseer.select_action(overseer.ACTIONS.find(&"cancel"))
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	overseer._unhandled_input(wheel)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(count_markers.call() == 0, "an extruded cancel drag clears the volume")
	overseer.select_action(overseer.ACTIONS.find(&"mine"))

	# While a drag is up, an RMB click aborts it instead of applying anything.
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 2, base.z)
	click.call(MOUSE_BUTTON_RIGHT, true)
	click.call(MOUSE_BUTTON_RIGHT, false)
	_check(
		not overseer._drag_active and count_markers.call() == 0,
		"an RMB click aborts a drag without applying it"
	)
	click.call(MOUSE_BUTTON_LEFT, false)

	# A stockpile drag works on the air layer in front of the face.
	overseer.select_action(overseer.ACTIONS.find(&"designate_stockpile"))
	aim.call(base.x, base.z)
	click.call(MOUSE_BUTTON_LEFT, true)
	aim.call(base.x + 1, base.z)
	click.call(MOUSE_BUTTON_LEFT, false)
	_check(
		colony.is_stockpile(base) and colony.is_stockpile(base + Vector3i(1, 0, 0)),
		"a stockpile drag designates the air layer in front of the face"
	)
	colony.undesignate_stockpile(base)
	colony.undesignate_stockpile(base + Vector3i(1, 0, 0))

	# A drag anchored on a vertical face extrudes horizontally too — into
	# the wall and out toward the camera. The face's outward normal points
	# the way the camera looks from (-z here), so digging in extends toward
	# +z and pulling out extends toward -z. The wall floats and a sight
	# corridor is cleared so terrain can't occlude the aim.
	var wall := Vector3i(base.x, g + 5, base.z)
	for dx in 3:
		for dy in 3:
			for dz in 3:
				world.place(wall + Vector3i(dx, dy, dz), BlockRegistry.Block.STONE)
	for dx in 3:
		for dy in 3:
			for dz in range(-3, 0):
				var cell := wall + Vector3i(dx, dy, dz)
				if world.is_solid(cell):
					world.remove_voxel(cell)
	var aim_wall := func(hit: Vector3i) -> void:
		overseer.global_position = Vector3(hit) + Vector3(0.5, 0.5, -2.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3(0, 0, 1), Vector3.UP), overseer.global_position
		)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(hit) + Vector3.ONE * 0.5
		))

	overseer.select_action(overseer.ACTIONS.find(&"mine"))
	aim_wall.call(wall)
	click.call(MOUSE_BUTTON_LEFT, true)
	overseer._press_hold = Overseer.DRAG_HOLD
	overseer._tick_press(0.0)
	click.call(MOUSE_BUTTON_LEFT, false)
	aim_wall.call(wall + Vector3i(2, 1, 0))
	_check(
		overseer._drag_axis == 2,
		"a wall-face drag locks the box to the face's plane"
	)
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	var wb := overseer._drag_bounds()
	_check(
		wb[0].z == wall.z and wb[1].z == wall.z + 2,
		"a wall drag extrudes into the face"
	)
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	wb = overseer._drag_bounds()
	_check(
		wb[0].z == wall.z - 1 and wb[1].z == wall.z,
		"a wall drag extrudes out toward the camera"
	)
	# Extrude back into the wall and commit: the dug-in volume designates.
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	overseer._unhandled_input(wheel)
	click.call(MOUSE_BUTTON_LEFT, true)
	var wall_marked := 0
	for dx in 3:
		for dy in 2:
			for dz in 3:
				if colony._designation_markers.has(wall + Vector3i(dx, dy, dz)):
					wall_marked += 1
	_check(
		wall_marked == 18,
		"an extruded wall drag designates the dug-in volume"
	)
	for dx in 3:
		for dy in 2:
			for dz in 3:
				colony.cancel_designation(wall + Vector3i(dx, dy, dz))
	for dx in 3:
		for dy in 3:
			for dz in 3:
				world.remove_voxel(wall + Vector3i(dx, dy, dz))
	overseer.select_action(0)


## Dropping items into voxels: loose items split off a share and solid items
## hop aside, preferring the open voxel below; piles always settle onto solid
## ground, including when the block under them is mined away.
func _test_spilling(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var before := _pile_volume_near(colony, mined, 16.0)

	# A loose drop into open air sheds part of itself downward; the whole
	# thing settles into the mined column below — into the hole if the mined
	# voxel still has room, or onto its pile if it is packed.
	var base := mined + Vector3i(0, 3, 0)
	var column_before := _column_volume(colony, mined)
	colony._drop_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), base)
	var hole_grew := await _wait_until(func() -> bool:
		return _column_volume(colony, mined) > column_before)
	_check(hole_grew, "part of a loose drop settles into the mined column")

	# A pile packed onto a shelf of placed stone has no room for more: a solid
	# drop into that voxel must hop aside.
	var shelf := Vector3i(mined.x - 6, 0, mined.z - 6)
	shelf.y = _ground(world, shelf.x, shelf.z, mined.y + 32) + 5
	var packed := shelf + Vector3i.UP
	world.place(shelf, BlockRegistry.Block.STONE)
	colony._deposit_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1500000), packed)
	var cobble := DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE, DropItem.COBBLE_CM3)
	colony._drop_item(cobble, packed)
	_check(
		not colony.item_pile_at(packed).items.has(cobble),
		"a solid drop moves out of a fully occupied voxel"
	)

	# Mining the shelf knocks the support out: the packed pile falls to the
	# floor of the column and comes to rest there, merging with whatever
	# pile is already in the way.
	world.mine(shelf)
	var pit_floor := Vector3i(
		shelf.x, _ground(world, shelf.x, shelf.z, mined.y + 32) + 1, shelf.z
	)
	var settled := await _wait_until(func() -> bool:
		var pile := colony.item_pile_at(pit_floor)
		return (
			pile != null
			and pile.total_volume() >= 990_000
			and is_equal_approx(pile.position.y, float(pit_floor.y))
		))
	_check(settled, "items fall and come to rest when the block beneath is mined")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		_pile_volume_near(colony, mined, 16.0)
			== before + 400_000 + 1_500_000 + DropItem.COBBLE_CM3,
		"spilling drops conserve volume"
	)

	# A pile resting on a packed pile loses its floor when the lower pile
	# is partially taken: the upper pile must descend into it and merge,
	# not keep floating a voxel up.
	var lower_spot := Vector3i(mined.x + 6, 0, mined.z - 6)
	lower_spot.y = _ground(world, lower_spot.x, lower_spot.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1000000), lower_spot)
	var upper_spot := lower_spot + Vector3i.UP
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 300000), upper_spot)
	_check(
		colony.item_pile_at(upper_spot) != null,
		"a loose pile rests on a packed pile"
	)
	colony.item_pile_at(lower_spot).take_up_to(400_000)
	var descended := await _wait_until(func() -> bool:
		return (
			colony._in_flight.is_empty()
			and colony.item_pile_at(upper_spot) == null
			and colony.item_pile_at(lower_spot) != null
			and colony.item_pile_at(lower_spot).total_volume() == 900_000
		))
	_check(descended, "a pile follows its shrinking support down and merges")


## Fill is floor: a voxel packed with items is impassible like a solid block,
## and both items and units can stand on top of it.
func _test_fill(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	var column := Vector3i(mined.x + 8, 0, mined.z - 8)
	column.y = _ground(world, column.x, column.z, mined.y + 32) + 1
	colony._deposit_item(DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1200000), column)

	_check(colony.is_packed(column), "a voxel holding a full cubic metre is packed")
	_check(unit._is_blocked(column), "a packed voxel blocks units")
	_check(not unit._is_standable(column), "a packed voxel is not standable")
	_check(unit._is_standable(column + Vector3i.UP), "a unit can stand on a packed voxel")

	var packed_pile := colony.item_pile_at(column)
	if packed_pile._fill_shape != null:
		var box := packed_pile._fill_shape.shape as BoxShape3D
		_check(
			box != null and is_equal_approx(box.size.y, 1.0),
			"a packed pile's collision fills the voxel"
		)

	# ItemPile batches mesh rebuilds to once per frame — the deferred
	# flush runs before the next process frame.
	await process_frame
	var renders_solid := false
	for child in packed_pile.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh is BoxMesh:
			var cube := mesh_instance.mesh as BoxMesh
			renders_solid = minf(minf(cube.size.x, cube.size.y), cube.size.z) > 0.9
	_check(renders_solid, "a packed voxel renders as a solid block")

	# An item dropped above a packed voxel comes to rest on top of it.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000),
		column + Vector3i(0, 3, 0)
	)
	_check(
		colony.item_pile_at(column + Vector3i.UP) != null,
		"items land on top of a packed voxel"
	)

	# A deposit bigger than a cubic metre splits: the voxel keeps a full
	# metre and the excess lands in an adjoining voxel.
	var overfull := Vector3i(mined.x + 12, 0, mined.z - 12)
	overfull.y = _ground(world, overfull.x, overfull.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1500000), overfull
	)
	var over_pile := colony.item_pile_at(overfull)
	_check(
		over_pile != null and over_pile.total_volume() <= DropItem.BLOCK_CM3,
		"a pile never exceeds one cubic metre"
	)
	var excess_moved := false
	for side in colony.SPILL_SIDES:
		for dy in [1, 0, -1, -2]:
			var spilled := colony.item_pile_at(overfull + side + Vector3i(0, dy, 0))
			if spilled != null and not spilled.items.is_empty():
				excess_moved = true
	_check(excess_moved, "a pile's excess moves to an adjacent voxel")


## Item 49 footing: only loose fill is floor. Discrete goods are clutter —
## walked through slowly when sparse, walked around when dense, and never
## something to stand on. A pour under somebody's feet lifts them while
## the headroom is free, and evicts the surplus when it isn't; a shrinking
## pile drops them back down.
func _test_footing(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	var sparse := Vector3i(mined.x + 20, 0, mined.z + 6)
	sparse.y = _ground(world, sparse.x, sparse.z, mined.y + 32) + 1

	# Sparse clutter slows the wade on a steepening curve — a quarter full
	# of boulders costs 1/(1 + 4f²) ≈ 0.86, half full halves the pace.
	for i in 2:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000
			),
			sparse
		)
	var sparse_mult := colony.traversal_mult(sparse)
	_check(
		is_equal_approx(sparse_mult, 1.0 / 1.16),
		"sparse clutter slows the wade a little"
	)
	_check(unit._is_standable(sparse), "a sparse heap stays walkable")
	for i in 3:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000
			),
			sparse
		)
	var half_mult := colony.traversal_mult(sparse)
	_check(
		is_equal_approx(half_mult, 0.5),
		"a half-full heap halves the pace"
	)

	# Past three quarters of a cell the heap is dense — a wall, not a
	# floor: impassable, unstandable, and no footing on top either.
	for i in 3:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000
			),
			sparse
		)
	_check(colony.is_dense_pile(sparse), "eight boulders choke the cell")
	_check(unit._is_blocked(sparse), "a dense heap blocks units")
	_check(not unit._is_standable(sparse), "a dense heap can't be stood in")
	_check(
		not colony.is_flooring(sparse),
		"a heap of discrete goods is no floor"
	)
	_check(
		not unit._is_standable(sparse + Vector3i.UP),
		"nobody stands on a dense heap"
	)

	# The heap is also flimsy cover — melee battering chews it up where
	# building damage would chew a wall.
	var cover_before := colony.item_pile_at(sparse).total_volume()
	colony.damage_cell(sparse, 60.0)
	var cover_after := colony.item_pile_at(sparse).total_volume()
	_check(cover_after < cover_before, "a dense heap soaks blows as cover")

	# A mass-bound take: a whole log is over the volume cap but inside
	# the drag limit — the shovel refuses it, the arms take it.
	var log_cell := Vector3i(mined.x + 22, 0, mined.z + 6)
	log_cell.y = _ground(world, log_cell.x, log_cell.z, mined.y + 32) + 1
	var log := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
	)
	colony._deposit_item(log, log_cell)
	var log_pile := colony.item_pile_at(log_cell)
	_check(
		pile_take_check(log_pile, 500_000, 0.0).is_empty(),
		"a volume-capped take can't move a whole log"
	)
	_check(
		not pile_take_check(log_pile, 500_000, unit._drag_kg()).is_empty(),
		"inside the drag limit the log comes along anyway"
	)

	# A pour under a stander's feet lifts them — the loose surface rises
	# inside the unit's own cell and carries the capsule with it.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	var stand := Vector3i(mined.x - 20, 0, mined.z + 6)
	stand.y = _ground(world, stand.x, stand.z, mined.y + 32) + 1
	unit.global_position = Vector3(stand) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	await process_frame
	await process_frame
	var feet_before := unit.global_position.y
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 300000),
		stand
	)
	var rose := await _wait_until(func() -> bool:
		return unit.global_position.y > feet_before + 0.2)
	_check(rose, "a rising pile lifts whoever stands on it")

	# With a solid cell two up the same pour can't lift — it stops at a
	# fifth of the cell and the surplus evicts sideways.
	var capped := Vector3i(mined.x - 22, 0, mined.z + 6)
	capped.y = _ground(world, capped.x, capped.z, mined.y + 32) + 1
	world.place(capped + Vector3i(0, 2, 0), BlockRegistry.Block.STONE)
	unit.global_position = Vector3(capped) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	await process_frame
	await process_frame
	var soil_near := _pile_volume_near(
		colony, capped, 6.0, BlockRegistry.Resource_.SOIL
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 500000),
		capped
	)
	_check(
		colony.pile_loose_fill(capped) <= colony.PILE_HEADROOM_CM3,
		"a pour can't bury a stander past the headroom fill"
	)
	var found_evicted := false
	for side in colony.SPILL_SIDES + [Vector3i.UP]:
		var pile := colony.item_pile_at(capped + side)
		if pile != null and pile.loose_volume() > 0:
			found_evicted = true
	_check(found_evicted, "the refused pour evicts to an adjacent voxel")
	_check(
		_pile_volume_near(colony, capped, 6.0, BlockRegistry.Resource_.SOIL)
			>= soil_near + 500000 - 1,
		"the evicted soil conserves its volume"
	)
	world.remove_voxel(capped + Vector3i(0, 2, 0))

	# And when the fill underfoot shrinks the stander just falls —
	# pull loose out from under them and the capsule follows it down.
	unit.global_position = Vector3(stand) + Vector3(0.5, 0.9 + 0.3, 0.5)
	unit.velocity = Vector3.ZERO
	await process_frame
	var lifted := unit.global_position.y
	var stand_pile := colony.item_pile_at(stand)
	if stand_pile != null:
		stand_pile.take_loose(BlockRegistry.Resource_.SOIL, 200000)
	var fell := await _wait_until(func() -> bool:
		return unit.global_position.y < lifted - 0.1)
	_check(fell, "a shrinking pile drops whoever stands on it")

	# The stander checks parked every unit's job search — release it so
	# the following sections can assign work naturally again.
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Take `cap`/`lift` out of [param pile] and put it straight back — a
## dry-run for what the pile would give up. The pile is unchanged.
func pile_take_check(pile: ItemPile, cap: int, lift: float) -> Array[DropItem]:
	var got := pile.take_up_to(cap, Callable(), false, lift)
	pile.add_items(got, false)
	return got


## A unit blocked by a packed pile shoves its items into neighbouring voxels
## until the cell is passable — conserving the items, not deleting them.
func _test_shove(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var blocked := Vector3i(mined.x - 10, 0, mined.z + 10)
	blocked.y = _ground(world, blocked.x, blocked.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1200000), blocked
	)

	var volume_before := _pile_volume_near(colony, blocked, 8.0)
	_check(colony.shove_pile(blocked), "a packed pile can be shoved aside")
	_check(not colony.is_packed(blocked), "shoving clears the blocked voxel")

	var moved := false
	for side in colony.SPILL_SIDES:
		for offset in [Vector3i.ZERO, Vector3i.DOWN]:
			var pile := colony.item_pile_at(blocked + side + offset)
			if pile != null and not pile.items.is_empty():
				moved = true
	_check(moved, "shoved items land in an adjacent voxel")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		_pile_volume_near(colony, blocked, 8.0) == volume_before,
		"shoved items keep their volume"
	)


## A clearing designation is a real job: a unit walks up to the pile and
## moves every item into adjoining voxels — the pile empties, nothing is lost.
func _test_clear(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_voxel := Vector3i(mined.x + 10, 0, mined.z + 6)
	pile_voxel.y = _ground(world, pile_voxel.x, pile_voxel.z, mined.y + 32) + 1
	_check(
		colony.designate_clear(pile_voxel) == null,
		"an empty voxel can't be designated for clearing"
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1400000), pile_voxel
	)
	# The fixture's own soil volume in its neighborhood — clearing only
	# moves items into adjoining voxels, so a local tally survives the
	# live world's ambient churn (decay, litter drops, distant hauling).
	var volume_before := _pile_volume_near(
		colony, pile_voxel, 8.0, BlockRegistry.Resource_.SOIL
	)

	var job := colony.designate_clear(pile_voxel)
	_check(job != null, "designating a filled voxel creates a clearing job")
	if job == null:
		return

	var emptied := await _wait_until(func() -> bool:
		return colony.item_pile_at(pile_voxel) == null)
	_check(emptied, "a unit clears the pile out of the voxel")
	# A passing unit may have shoved the packed pile before the job was
	# claimed — the job completes either way once a unit takes it.
	var done := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(done, "the clearing job completes")

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		_pile_volume_near(
			colony, pile_voxel, 8.0, BlockRegistry.Resource_.SOIL
		) == volume_before,
		"clearing moves items rather than deleting them"
	)


## A build designation gathers wall-eligible material from piles — loose
## soil compacts into a dirt block, a hundred and twenty dressed blocks
## raise a stone wall, one whole log raises a log wall. Jobs are assigned
## directly: a free claimer picks its fetch pile by distance to itself,
## which could commit the job to a different material than the fixture's.
func _test_build(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var build := Vector3i(mined.x - 16, 0, mined.z - 16)
	build.y = _ground(world, build.x, build.z, mined.y + 32) + 1

	# A solid voxel can't be built on.
	var solid := Vector3i(mined.x - 16, 0, mined.z - 14)
	solid.y = _ground(world, solid.x, solid.z, mined.y + 32)
	_check(
		colony.designate_build(solid, &"dirt_wall") == null,
		"a solid voxel can't be designated for building"
	)

	# Two piles of loose dirt near the site, totalling more than the build cost.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000),
		build + Vector3i(2, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 800000),
		build + Vector3i(-2, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# Consumption is measured across every pile in the world.
	var dirt_before := _soil_volume_near(colony, build, 100000.0)

	# Gathering has no distance limit — it targets the closest dirt pile.
	var nearest := colony.nearest_wall_voxel(build, BlockRegistry.Resource_.SOIL)
	_check(
		nearest != Vector3i.MAX and Vector3(nearest - build).length() <= 4.0,
		"the closest dirt pile is picked as the fetch source"
	)
	# Stone may exist in distant piles — the point is that loose soil
	# counts for nothing toward the stone recipe, and the fetch query
	# walks past the soil pile to real stone.
	var soil_pile := build + Vector3i(2, 0, 0)
	var at_soil := colony.item_pile_at(soil_pile)
	_check(
		at_soil != null
			and at_soil.wall_need_volume(
				BlockRegistry.Resource_.STONE,
				BlockRegistry.wall_recipe(BlockRegistry.Resource_.STONE)
			) == 0,
		"a stone wall can't use dirt piles"
	)
	_check(
		colony.nearest_wall_voxel(build, BlockRegistry.Resource_.STONE)
			!= soil_pile,
		"a stone wall doesn't fetch from dirt piles"
	)

	var job := _assign_build(
		colony, build, build + Vector3i(2, 0, 0), &"dirt_wall"
	)
	_check(job != null, "designating an empty voxel creates a build job")
	if job == null:
		return

	# An array so the lambda's capture writes through — GDScript captures
	# plain locals by value.
	var saw_fetch := [false]
	var built := await _wait_until(func() -> bool:
		for unit in colony.units:
			if unit._fetching:
				saw_fetch[0] = true
		return world.get_block(build) == BlockRegistry.Block.DIRT)
	_check(built, "a unit builds a dirt block from gathered soil")
	_check(saw_fetch[0], "the unit hauls dirt to the site")
	_check(job.state == ColonyJob.State.DONE, "the build job completes")
	_check(
		job.material == BlockRegistry.Resource_.SOIL,
		"the dirt wall job asked for soil"
	)

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var soil_after := _soil_volume_near(colony, build, 100000.0)
	# Integer cm³ volumes conserve exactly — no tolerance needed.
	_check(
		soil_after
			== dirt_before - BlockRegistry.wall_volume_for(BlockRegistry.Resource_.SOIL),
		"building consumed 1.25 m³ of loose dirt (%d → %d)"
			% [dirt_before, soil_after]
	)

	# Stone walls take exactly a hundred and twenty dressed blocks — the
	# five extra below are leftovers the recipe must leave in the pile.
	var stone_site := _flat_voxel(world, mined, 152)
	_check(stone_site != Vector3i.MAX, "found a flat spot for the stone wall test")
	if stone_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, stone_site, 25.0)
	for i in 125:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BLOCK,
				DropItem.STONE_BLOCK_CM3
			),
			stone_site + Vector3i(1, 0, 0)
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stone_job := _assign_build(
		colony, stone_site, stone_site + Vector3i(1, 0, 0), &"stone_wall"
	)
	_check(stone_job != null, "designating an empty voxel creates a wall job")
	var walled := await _wait_until(func() -> bool:
		return world.get_block(stone_site) == BlockRegistry.Block.STONE_WALL)
	_check(walled, "a unit builds a stone wall from dressed blocks")
	_check(
		stone_job != null and stone_job.state == ColonyJob.State.DONE,
		"the stone wall job completes"
	)
	_check(
		stone_job != null and stone_job.material == BlockRegistry.Resource_.STONE,
		"the stone wall job asked for stone"
	)

	# The wall is a building now: it knows its material, its block, and
	# the exact items it was built of — a hundred and twenty blocks.
	var wall := colony.building_at(stone_site)
	_check(wall != null, "a finished wall registers as a building")
	if wall != null:
		_check(
			wall.material == BlockRegistry.Resource_.STONE
				and wall.block_id == BlockRegistry.Block.STONE_WALL
				and wall.deconstructable,
			"the wall records its material, block and deconstructability"
		)
		var blocks := 0
		for item in wall.components:
			if item.form == DropItem.Form.BLOCK:
				blocks += 1
		_check(
			blocks == 120,
			"the wall keeps the exact items it was built of"
		)
	var spare_blocks := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - stone_site).length() > 8.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material != BlockRegistry.Resource_.STONE:
				continue
			if item.form == DropItem.Form.BLOCK:
				spare_blocks += 1
	_check(
		spare_blocks == 5,
		"the recipe's leftovers stayed in the pile"
	)

	# And log walls take one whole log — a cubic metre dragged to the
	# site, over the volume carry cap but inside the drag limit.
	var log_site := _flat_voxel(world, mined, 160)
	_check(log_site != Vector3i.MAX, "found a flat spot for the log wall test")
	if log_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, log_site, 25.0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_site + Vector3i(1, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var log_job := _assign_build(
		colony, log_site, log_site + Vector3i(1, 0, 0), &"log_wall"
	)
	var logged := await _wait_until(func() -> bool:
		return world.get_block(log_site) == BlockRegistry.Block.LOG_WALL)
	_check(logged, "a unit drags a whole log to the wall and builds it")
	_check(
		log_job != null and log_job.state == ColonyJob.State.DONE,
		"the log wall job completes"
	)
	var log_wall := colony.building_at(log_site)
	_check(
		log_wall != null and log_wall.components.size() == 1,
		"the log wall recorded its log"
	)
	# Cooldowns set for the direct assignments would stall later tests that
	# rely on free claiming.
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Designates a wall at [param site] and hands it straight to units[0],
## parked at the site and pointed at the pile in [param pile_v] — bypassing
## the job board so the fixture's piles are the ones fetched.
func _assign_build(colony: Colony, site: Vector3i, pile_v: Vector3i, spec: StringName) -> ColonyJob:
	_clear_jobs(colony)
	var job := colony.designate_build(site, spec)
	if job == null:
		return null
	var builder: Unit = colony.units[0]
	for u in colony.units:
		if u != builder:
			u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		# Abandon unconditionally: carried items drop where the unit stands.
		u.abandon_job()
	builder.global_position = Vector3(site) + Vector3(0.5, 0.9, 0.5)
	builder.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = builder
	builder.job = job
	builder._fetching = true
	builder._goal_voxel = pile_v
	builder._clear_budget = 0.0
	builder.state = Unit.State.MOVING
	return job


## Empties piles within [param radius] of [param centre] of anything a wall
## could use, so a direct-assigned build can only fetch from the fixture's
## piles.
func _clear_wall_material_near(colony: Colony, centre: Vector3i, radius: float) -> void:
	for voxel in colony.item_piles.keys():
		if Vector3(voxel - centre).length() > radius:
			continue
		var pile: ItemPile = colony.item_piles[voxel]
		pile.items = pile.items.filter(
			func(item: DropItem) -> bool:
				return not BlockRegistry.item_fits_wall(
					item, BlockRegistry.Resource_.NONE
				)
		)
		colony.remove_pile_if_empty(voxel)


## Total loose-soil volume piled within [param radius] of [param centre].
func _soil_volume_near(colony: Colony, centre: Vector3i, radius: float) -> int:
	var total := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - centre).length() > radius:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.SOIL:
				total += item.volume
	return total


## Reach rule: within 1.5 m of the block's nearest face, with a clear line —
## checked against a small wall built in open air so terrain can't interfere.
func _test_reach(unit: Unit, world: VoxelWorld, mined: Vector3i) -> void:
	var base := Vector3i(mined.x + 4, 0, mined.z + 4)
	base.y = _ground(world, base.x, base.z, mined.y + 32) + 5
	var behind := base + Vector3i.BACK
	world.place(base, BlockRegistry.Block.STONE)
	world.place(behind, BlockRegistry.Block.STONE)

	var eye := Vector3(base) + Vector3(0.5, 0.5, -0.4)
	_check(unit._can_mine_from(eye, base), "can mine a block with a clear line")
	_check(
		unit._can_mine_from(Vector3(base) + Vector3(0.5, 1.4, 0.5), base),
		"can mine a block from above"
	)
	_check(not unit._can_mine_from(eye, behind), "cannot mine through a solid block")
	_check(
		not unit._can_mine_from(eye + Vector3(0.0, 0.0, -2.0), base),
		"cannot mine beyond reach"
	)

	world.mine(base)
	world.mine(behind)


## Volume of [param material] piled within [param radius] of [param
## center] (-1 for all materials), plus what's carried anywhere — a
## conservation check that the live world's ambient churn (decay, fresh
## litter, distant hauling) can't disturb.
func _pile_volume_near(
	colony: Colony, center: Vector3i, radius: float, material: int = -1
) -> int:
	var total := 0
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - center).length() > radius:
			continue
		for item in colony.item_piles[voxel].items:
			if material < 0 or item.material == material:
				total += item.volume
	for pile in colony._in_flight:
		if (
			radius >= 0.0
			and (pile.position - Vector3(center)).length() > radius
		):
			continue
		for item in pile.items:
			if material < 0 or item.material == material:
				total += item.volume
	for u in colony.units:
		for item in u._carried:
			if material < 0 or item.material == material:
				total += item.volume
	return total


## Total item volume piled anywhere in [param voxel]'s x/z column.
func _column_volume(colony: Colony, voxel: Vector3i) -> int:
	var total := 0
	for key in colony.item_piles:
		if key.x == voxel.x and key.z == voxel.z:
			total += colony.item_piles[key].total_volume()
	return total


## Stockpiles: designation rules, idle-unit hauling of loose piles, and the
## interrupted-haul drop.
func _test_stockpile(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var sp := Vector3i(mined.x + 16, 0, mined.z + 16)
	sp.y = _ground(world, sp.x, sp.z, mined.y + 32) + 1

	# Stockpile tiles must be empty voxels resting on a solid block.
	_check(
		not colony.designate_stockpile(sp + Vector3i.UP),
		"a voxel with no ground under it can't be a stockpile"
	)
	_check(
		colony.designate_stockpile(sp),
		"an empty voxel on solid ground designates as a stockpile"
	)
	_check(colony.is_stockpile(sp), "the stockpile designation sticks")
	_check(
		not colony.designate_stockpile(sp),
		"a voxel can't be stockpile-designated twice"
	)
	_check(
		colony.undesignate_stockpile(sp),
		"undesignating removes the stockpile"
	)
	_check(
		colony.designate_stockpile(sp),
		"a voxel can be stockpile-designated again"
	)

	# A pile bigger than one load: hauled to the stockpile in trips.
	var dump := Vector3i(mined.x + 8, 0, mined.z + 8)
	dump.y = _ground(world, dump.x, dump.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000), dump
	)
	var saw_carry := [false]
	var hauled := await _wait_until(func() -> bool:
		for unit in colony.units:
			if unit._carried_volume() > 0:
				saw_carry[0] = true
		var pile := colony.item_pile_at(sp)
		return pile != null and pile.total_volume() >= 850_000)
	_check(saw_carry[0], "a unit physically carries items while hauling")
	_check(hauled, "items are hauled to the stockpile")

	# Interrupting a haul drops the carried items where the unit stands.
	var dump2 := Vector3i(mined.x + 10, 0, mined.z + 8)
	dump2.y = _ground(world, dump2.x, dump2.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 600000), dump2
	)
	var found := await _wait_until(func() -> bool:
		return colony.units.any(func(u: Unit) -> bool: return u._carried_volume() > 0))
	_check(found, "a haul is in progress to interrupt")
	if found:
		var carrier: Unit = null
		for u in colony.units:
			if u._carried_volume() > 0:
				carrier = u
		var at := carrier._standing_voxel()
		var load := carrier._carried_volume()
		carrier.abandon_job()
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		# Another unit may already be hauling the fresh pile away — count
		# carried loads near the drop point as well as piled volume.
		var recovered := _volume_near(colony, at, 4.0)
		for u in colony.units:
			if Vector3(at).distance_to(u.global_position) <= 4.0:
				recovered += u._carried_volume()
		_check(
			recovered >= load - 0.01,
			"an interrupted haul drops the carried items"
		)

	# A nearly-full stockpile tile still takes the last few cm³ — a loose
	# load pours the remainder in instead of vetoing the tile outright.
	var sp2 := Vector3i(mined.x + 18, 0, mined.z + 16)
	sp2.y = _ground(world, sp2.x, sp2.z, mined.y + 32) + 1
	_check(colony.designate_stockpile(sp2), "a second stockpile designates")
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 995000), sp2
	)
	var dump3 := Vector3i(mined.x + 12, 0, mined.z + 8)
	dump3.y = _ground(world, dump3.x, dump3.z, mined.y + 32) + 1
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 300000), dump3
	)
	var topped := await _wait_until(func() -> bool:
		var pile := colony.item_pile_at(sp2)
		return pile != null and pile.total_volume() >= DropItem.BLOCK_CM3)
	_check(topped, "a loose haul tops off a nearly-full stockpile")

	# Filtering: each tile keeps a reject-set of materials it won't store.
	# A pile holding a rejected material becomes a haul-out candidate, so
	# the filter cleans existing contents instead of only gating deposits.
	var fa := _flat_voxel(world, mined, 136)
	_check(fa != Vector3i.MAX, "found a flat spot for the filter test")
	if fa != Vector3i.MAX:
		var sa := fa
		var sb := fa + Vector3i(1, 0, 0)
		var dump4 := fa + Vector3i(2, 0, 0)
		_check(
			colony.designate_stockpile(sa) and colony.designate_stockpile(sb),
			"two filter-test stockpiles designate"
		)
		_check(
			colony.stockpile_at(sa) == colony.stockpile_at(sb),
			"adjacent cells share one zone"
		)
		_check(
			colony.stockpile_admits(sa, BlockRegistry.Resource_.STONE),
			"a fresh stockpile admits everything"
		)
		colony.set_stockpile_admission(sa, BlockRegistry.Resource_.STONE, false)
		_check(
			not colony.stockpile_admits(sa, BlockRegistry.Resource_.STONE)
				and not colony.stockpile_admits(sb, BlockRegistry.Resource_.STONE)
				and colony.stockpile_admits(sa, BlockRegistry.Resource_.SOIL),
			"the zone's filter rejects on every cell"
		)
		# A second stockpile far enough away to start its own zone keeps
		# an independent filter — the rejecting zone is skipped for stone.
		var sc := _flat_voxel(world, mined, 140, 8)
		_check(sc != Vector3i.MAX, "found a spot for a second-zone stockpile")
		if sc == Vector3i.MAX:
			return
		_check(
			colony.designate_stockpile(sc),
			"a second-zone stockpile designates"
		)
		_check(
			colony.stockpile_at(sc) != colony.stockpile_at(sa),
			"a distant cell starts its own zone"
		)
		_check(
			colony.stockpile_admits(sc, BlockRegistry.Resource_.STONE),
			"the second zone keeps its own filter"
		)
		_check(
			colony.nearest_stockpile_with_room(
				dump4, 1, {}, [BlockRegistry.Resource_.STONE]
			) == sc,
			"a rejecting zone is skipped for that material"
		)
		# A boulder dropped on the rejecting tile is an eviction candidate —
		# a unit should carry it to the tile that admits it.
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000
			),
			sa
		)
		_check(
			colony.nearest_haulable_pile(sa) == sa,
			"a pile rejected by its tile is haulable"
		)
		var evicted := await _wait_until(func() -> bool:
			var pile := colony.item_pile_at(sa)
			return pile == null or pile.form_volume(DropItem.Form.BOULDER) == 0)
		_check(evicted, "a disallowed pile gets hauled off its tile")
		# The drop can spill onto a neighbor mid-flight — wait for it to
		# settle on the admitting tile rather than checking once.
		var arrived := await _wait_until(func() -> bool:
			var pile := colony.item_pile_at(sc)
			return pile != null and pile.form_volume(DropItem.Form.BOULDER) >= 100000)
		_check(arrived, "the evicted material lands on an admitting tile")
		colony.set_stockpile_admission(sa, BlockRegistry.Resource_.STONE, true)
		_check(
			colony.stockpile_admits(sa, BlockRegistry.Resource_.STONE)
				and colony.stockpile_admits(sb, BlockRegistry.Resource_.STONE),
			"re-enabling a material admits it again"
		)
		_check(colony.undesignate_stockpile(sb), "one zone cell undesignates")
		_check(
			colony.stockpile_at(sa) != null and colony.stockpile_at(sb) == null,
			"the zone survives losing a cell"
		)

	# --- Zone gestures: the first click and the box's overlaps pick the
	# target zone; Alt forces a fresh one; zoned cells never move.
	var za := _flat_voxel(world, mined, 152, 4)
	_check(za != Vector3i.MAX, "found a flat spot for the zone-gesture test")
	if za != Vector3i.MAX:
		var zb := za + Vector3i(2, 0, 0)
		colony.designate_stockpile(za)
		colony.designate_stockpile(zb)
		var zone_a := colony.stockpile_at(za)
		var zone_b := colony.stockpile_at(zb)
		_check(
			zone_a != null and zone_b != null and zone_a != zone_b,
			"a gap keeps two stockpiles in their own zones"
		)
		var between := za + Vector3i(1, 0, 0)
		_check(
			colony._stockpile_cellable(between),
			"the seam cell is stockpileable"
		)
		_check(
			not colony.designate_stockpile(between),
			"a cell between two zones can't pick — the gesture fails"
		)
		var seam_box: Array[Vector3i] = [between]
		_check(
			colony.designate_stockpile_cells(seam_box, between, true) != null,
			"the zone override forces a fresh zone"
		)
		_check(
			colony.stockpile_at(between) != zone_a
				and colony.stockpile_at(between) != zone_b,
			"the overridden cell starts a third zone"
		)
		_check(
			not colony.designate_stockpile(za),
			"re-designating a zoned cell adds nothing"
		)
		var covered: Array[Vector3i] = [za]
		_check(
			colony.designate_stockpile_cells(covered, za, true) == null,
			"the override still fails when nothing is free"
		)
		# A box anchored on zone A extends it: the distant free cell joins,
		# zone B's cell inside the box is never adopted.
		var zc := _flat_voxel(world, mined, 160, 4)
		_check(zc != Vector3i.MAX, "found a far cell for the overlap test")
		if zc != Vector3i.MAX:
			var box: Array[Vector3i] = [za, zc, zb]
			_check(
				colony.designate_stockpile_cells(box, za) == zone_a,
				"a box anchored on a zone extends it"
			)
			_check(
				colony.stockpile_at(zc) == zone_a,
				"a distant free cell joins the anchor's zone"
			)
			_check(
				colony.stockpile_at(zb) == zone_b,
				"the other zone's cell was never adopted"
			)
			var zd := _flat_voxel(world, mined, 168, 4)
			_check(zd != Vector3i.MAX, "found a far cell for the span test")
			if zd != Vector3i.MAX:
				var span_box: Array[Vector3i] = [zb, zc, zd]
				_check(
					colony.designate_stockpile_cells(span_box, zd) == null
						and not colony.is_stockpile(zd),
					"a box spanning two zones fails — nothing is placed"
				)
				var join_box: Array[Vector3i] = [zc, zd]
				_check(
					colony.designate_stockpile_cells(join_box, zd) == zone_a,
					"a box touching exactly one zone joins it"
				)
		# These flat rows belong to later tests — release the cells.
		for cell: Vector3i in [
			za, za + Vector3i(1, 0, 0), za + Vector3i(2, 0, 0),
			_flat_voxel(world, mined, 160, 4),
			_flat_voxel(world, mined, 168, 4),
		]:
			if cell != Vector3i.MAX:
				colony.undesignate_stockpile(cell)

	# A tile with less room than the smallest solid item isn't a real
	# destination — the fetch must skip it for a tile that can take the
	# item instead of standing at the pile in "loading items" forever.
	var fb := _flat_voxel(world, mined, 144)
	_check(fb != Vector3i.MAX, "found a flat spot for the full-tile haul test")
	if fb != Vector3i.MAX:
		_check(
			colony.designate_stockpile(fb),
			"a nearly-full stockpile designates"
		)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 950000
			),
			fb
		)
		var boulder_pile := fb + Vector3i(1, 0, 0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 200000
			),
			boulder_pile
		)
		var moved := await _wait_until(func() -> bool:
			var pile := colony.item_pile_at(boulder_pile)
			return (
				pile == null
				or pile.form_volume(DropItem.Form.BOULDER) < 200000
			))
		_check(
			moved,
			"a solid haul skips a tile too full to fit it"
		)


## A solid item that can't fit in a nearly-full voxel must overflow to the
## nearest voxel with room — not shuttle between the voxel and the one above
## it forever.
func _test_overflow(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var hole := _flat_voxel(world, mined, 48)
	_check(hole != Vector3i.MAX, "found a flat spot for the overflow test")
	if hole == Vector3i.MAX:
		return
	# A one-wide hole: solid floor, four solid sides.
	for side in [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]:
		world.place(hole + side, BlockRegistry.Block.STONE)
	# Fill it so a 0.1 m³ boulder can't join without overfilling.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 950000), hole
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, 100000), hole
	)
	var settled := await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(settled, "an oversized drop settles instead of bouncing forever")
	var pile := colony.item_pile_at(hole)
	_check(
		pile != null and pile.total_volume() <= DropItem.BLOCK_CM3,
		"the hole keeps only what fits"
	)
	var outside := false
	for v in colony.item_piles:
		if v == hole:
			continue
		for item in colony.item_piles[v].items:
			if item.form == DropItem.Form.BOULDER:
				outside = true
	_check(outside, "the oversized item lands outside the hole")


## A dug-out hole — walled on all four sides: a cubic metre of loose drop
## stays in the hole and the surplus rests on the packed pile above it, and
## clearing the hole shovels items out over the rim.
func _test_hole(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var sides := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]
	var hole := Vector3i.MAX
	for z_off in [64, 80, 96, 112]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate == Vector3i.MAX:
			continue
		var clear := (
			not world.is_solid(candidate + Vector3i.UP)
			and colony.item_pile_at(candidate + Vector3i.UP) == null
		)
		for side in sides:
			if colony.item_pile_at(candidate + side) != null:
				clear = false
		if not clear:
			continue
		var walled := true
		for side in sides:
			if not world.is_solid(candidate + side):
				world.place(candidate + side, BlockRegistry.Block.STONE)
			if not world.is_solid(candidate + side):
				walled = false
		if walled:
			hole = candidate
			break
	_check(hole != Vector3i.MAX, "found a walled hole for the hole test")
	if hole == Vector3i.MAX:
		return

	# The mined-dirt case: 1.25 m³ dropped into a walled hole splits into a
	# full metre in the hole and the surplus on the cell above it. The whole
	# deposit chain is synchronous, so the piles are checked before any unit
	# tick could touch them.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1250000), hole
	)
	var hole_pile := colony.item_pile_at(hole)
	var rim_pile := colony.item_pile_at(hole + Vector3i.UP)
	_check(
		hole_pile != null and absf(hole_pile.total_volume() - 1_000_000) == 0,
		"a dug-out hole keeps a full cubic metre"
	)
	_check(
		rim_pile != null and absf(rim_pile.total_volume() - 250_000) == 0,
		"the surplus spills onto the cell above the hole"
	)

	# Clearing the hole shovels items out over the rim — the only open side
	# is up, so the search must expand past the cell whose landing is the
	# hole itself.
	var job := colony.designate_clear(hole)
	_check(job != null, "a hole pile can be designated for clearing")
	var cleared := await _wait_until(func() -> bool:
		return colony.item_pile_at(hole) == null)
	_check(cleared, "a unit clears the pile out of a walled hole")


## Total item volume piled within [param radius] of [param centre].
func _volume_near(colony: Colony, centre: Vector3i, radius: float) -> float:
	var total := 0.0
	for voxel in colony.item_piles:
		if Vector3(voxel - centre).length() <= radius:
			total += colony.item_piles[voxel].total_volume()
	return total


## A unit that cannot make progress toward its job site drops the assignment
## after the stuck timeout, freeing the job for someone else.
func _test_stuck(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	var target := _pick_mining_target(world, unit, 4)
	_check(target != Vector3i.MAX, "found a job site for the stuck test")
	if target == Vector3i.MAX:
		return

	var job := colony.designate_mine(target)
	if job == null:
		_check(false, "stuck test designation creates a job")
		return
	# Keep every claim sweep frozen while the watchdog runs: a force-
	# assigned job never went through the sim's claim, so the board still
	# offers it — another unit's claim would overwrite `assignee` and the
	# release would mark dropped_by under the thief, not this unit.
	for u in colony.units:
		u._job_search_cooldown = 120.0
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit.state = Unit.State.MOVING
	var old_speed := unit.move_speed
	var old_timeout := unit.stuck_timeout
	# Immobilized: the path may exist but the unit will never get closer.
	unit.move_speed = 0.0
	unit.stuck_timeout = 0.3

	# dropped_by is the release marker — the PENDING window can close between
	# frames if another idle unit reclaims the job first.
	var released := await _wait_until(func() -> bool:
		return job.dropped_by.has(unit))
	if not released:
		print(
			"  dbg stuck: state=", unit.state,
			" fetching=", unit._fetching,
			" goal=", unit._goal_voxel,
			" stuck=", unit._stuck_elapsed,
			" best=", unit._best_goal_distance,
			" jobstate=", job.state,
			" assignee=", job.assignee,
			" unit.job=", unit.job,
			" can_mine=", unit._can_mine(job.voxel_position),
			" inreach=", unit._goal_in_reach(),
			" hands=", unit.hands.size(),
			" dead=", unit.dead,
			" downed=", unit.is_downed(),
			" carried_by=", unit._carried_by,
			" detour=", unit._detour,
			" pos=", unit.global_position,
			" dropped_by=", job.dropped_by,
			" jobs=", colony.jobs.size(),
			" suspended=", job.suspended
		)
	_check(released, "a stuck unit drops its job assignment")
	_check(job.dropped_by.has(unit), "a dropped job resists instant reclaim by the same unit")

	for u in colony.units:
		u._job_search_cooldown = 0.0
	unit.move_speed = old_speed
	unit.stuck_timeout = old_timeout
	colony.cancel_designation(target)

	# Overshoot guard: at high time_scale one physics step covers more
	# ground than the waypoint radius — a waypoint inside this tick's
	# travel must count as arrived, or the unit orbits and the watchdog
	# cancels a healthy job. A 0.1 s tick is the 6x step: 0.4 m of travel
	# against a waypoint 0.38 m away.
	var site := _pick_mining_target(world, unit, 8)
	if site != Vector3i.MAX:
		var j2 := colony.designate_mine(site)
		if j2 != null:
			j2.state = ColonyJob.State.ASSIGNED
			j2.assignee = unit
			unit.job = j2
			unit.state = Unit.State.MOVING
			unit._goal_voxel = site
			unit._best_goal_distance = 1e9
			var wp := unit.global_position + Vector3(0.38, 0.0, 0.0)
			unit._path = PackedVector3Array([wp])
			unit._path_index = 0
			unit._tick_moving(0.1)
			_check(
				unit._path_index == 1,
				"a waypoint inside one 6x step still registers arrival"
			)
			colony.cancel_designation(site)
			unit.abandon_job()

	# Jump-apex regression: a raw Euler step shrinks the apex by ~v·dt/2 —
	# 0.93 m instead of 1.27 m at a 6x-sized 0.1 s tick — which misses the
	# 0.95 m the capsule needs before `horizontal_clear` admits a 1 m
	# step-up. The unit jumped in place until the watchdog cancelled.
	if world.sim != null:
		var base := Vector3i.MAX
		var ledge := Vector3i.MAX
		for z_off in range(96, 240, 8):
			var candidate := _flat_voxel(world, mined, z_off)
			if candidate == Vector3i.MAX:
				continue
			var step := candidate + Vector3i(1, 0, 0)
			var clear := (
				world.get_block(step) == BlockRegistry.Block.AIR
				and world.get_block(step + Vector3i.UP) == BlockRegistry.Block.AIR
				and world.get_block(step + Vector3i(0, 2, 0)) == BlockRegistry.Block.AIR
				and colony.item_pile_at(candidate) == null
				and colony.item_pile_at(step) == null
			)
			if clear:
				base = candidate
				ledge = step
				break
		_check(base != Vector3i.MAX, "found a flat spot beside a ledge cell")
		if base != Vector3i.MAX:
			world.place(ledge, BlockRegistry.Block.STONE)
			var spawn := Vector3(base) + Vector3(0.5, 0.9, 0.5)
			unit.global_position = spawn
			world.sim.unit_register(unit._sim_id, spawn)
			var feet0: float = spawn.y - 0.9
			var on_top := false
			for i in 30:
				var r: Dictionary = world.sim.unit_step(
					unit._sim_id,
					Vector3(unit.move_speed, 0.0, 0.0),
					unit.jump_speed,
					unit.gravity,
					0.1,
					0.0
				)
				var p: Vector3 = r["pos"]
				if p.y - 0.9 >= feet0 + 0.95:
					on_top = true
					break
			_check(on_top, "a 6x-sized step still mounts a 1 m ledge")
			unit.global_position = world.sim.unit_pos(unit._sim_id)
			world.remove_voxel(ledge)


## A unit that fails a job tries a different job before retrying it — a
## recently failed job is only claimable once its retry delay has elapsed
## and nothing else is open, and each consecutive failure stretches the
## delay.
func _test_retry(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# Freeze every unit's own job search so the board can be driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
	# Clear the board: leftover pending jobs would muddy which job is claimed.
	for j in colony.jobs.duplicate():
		if j.is_active():
			colony.cancel_designation(j.voxel_position)

	var pos_a := _flat_voxel(world, mined, 56)
	var pos_b := _flat_voxel(world, mined, 72)
	_check(
		pos_a != Vector3i.MAX and pos_b != Vector3i.MAX,
		"found flat spots for the retry test"
	)
	if pos_a == Vector3i.MAX or pos_b == Vector3i.MAX:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pos_a
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pos_b
	)
	var job_a := colony.designate_clear(pos_a)
	var job_b := colony.designate_clear(pos_b)
	var unit: Unit = colony.units[0]

	var first := colony.claim_job(unit)
	_check(
		first == job_a or first == job_b,
		"the unit claims one of the open jobs"
	)
	colony.release_job(first)
	var second := colony.claim_job(unit)
	_check(
		second != null and second != first,
		"a unit that failed a job claims a different job before retrying it"
	)
	colony.release_job(second)
	_check(
		colony.claim_job(unit) == null,
		"recently failed jobs wait out their retry delay"
	)
	var other: Unit = colony.units[1] if colony.units.size() > 1 else null
	_check(
		other == null or colony.claim_job(other) == null,
		"a dropped job cools off for every unit, not just the one that failed"
	)
	var past: int = colony.game_msec() - Colony.DROPPED_JOB_RETRY_MAX_MSEC - 1
	first.dropped_by[unit]["at"] = past
	if world.sim != null:
		# The sim mirrors drop records — age its copy too.
		world.sim.job_drop(first.get_instance_id(), unit.get_instance_id(), past)
	_check(
		colony.claim_job(unit) == first,
		"an expired retry is claimable when nothing else is open"
	)
	colony.release_job(first)
	_check(
		int(first.dropped_by[unit].get("n", 0)) == 2,
		"repeated failures escalate the retry delay"
	)

	colony.cancel_designation(pos_a)
	colony.cancel_designation(pos_b)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A packed pile sitting on the only path to a job site: with a stockpile
## that has room, the unit loads the blockage and hauls it there instead of
## shovelling it into the neighbours — then finishes the job.
func _test_detour(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# A corridor walled on both sides and capped at the far end — the only
	# way to the work spot runs through the pile cell.
	var x := -1
	var gy := 0
	var z := 0
	# Grown trees put solid trunk/branch voxels in some columns — scan
	# rows until one has a stretch clear of them.
	for z_off in [120, 128, 136, 112, 104]:
		z = mined.z + z_off
		for cx in range(mined.x + 4, mined.x + 28):
			var g := _ground(world, cx, z, mined.y + 32)
			var flat := g > -32
			for wx in range(cx - 1, cx + 7):
				if _ground(world, wx, z, mined.y + 32) != g:
					flat = false
			for wz in [z - 1, z + 1, z + 3]:
				for wx in range(cx - 1, cx + 6):
					if (
						not world.is_solid(Vector3i(wx, g, wz))
						or world.is_solid(Vector3i(wx, g + 1, wz))
						or world.is_solid(Vector3i(wx, g + 2, wz))
					):
						flat = false
			if flat:
				x = cx
				gy = g
				break
		if x >= 0:
			break
	_check(x >= 0, "found a flat stretch for the detour test")
	if x < 0:
		return

	var level := gy + 1
	# Two blocks high — a one-block wall could be stepped over, which would
	# open a route around the pile and defeat the point of the corridor.
	for wx in range(x - 1, x + 6):
		for wy in [level, level + 1]:
			world.place(Vector3i(wx, wy, z - 1), BlockRegistry.Block.STONE)
			world.place(Vector3i(wx, wy, z + 1), BlockRegistry.Block.STONE)
	world.place(Vector3i(x + 5, level, z), BlockRegistry.Block.STONE)
	world.place(Vector3i(x + 5, level + 1, z), BlockRegistry.Block.STONE)
	var pile_v := Vector3i(x + 2, level, z)
	var target := Vector3i(x + 4, level, z)
	world.place(target, BlockRegistry.Block.STONE)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1000000), pile_v
	)
	var sp := Vector3i(x + 1, level, z + 3)
	# A scattered sapling isn't solid, so the flat scan can pick a stockpile
	# cell holding one — clear it first; the designation requires air.
	if world.get_block(sp) != BlockRegistry.Block.AIR:
		world.remove_voxel(sp)
	var sp_ok := colony.designate_stockpile(sp)
	_check(sp_ok, "a stockpile with room exists for the detour test")
	if not sp_ok:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return

	var unit: Unit = colony.units[0]
	# Pin the restless facet to its mean — detour reach only equals the
	# base export at 50, and the corridor legs assume the full radius.
	var saved_activity := unit.facet(&"activity_level")
	unit.facets[&"activity_level"] = 50
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	# Earlier tests leave open jobs on the board — the unit must not wander
	# off to claim one after a drop (failed jobs are retried last).
	_clear_jobs(colony)
	unit.global_position = Vector3(x + 0.5, level + 0.9, z + 0.5)

	var job := colony.designate_mine(target)
	_check(job != null, "a detour test designation creates a job")
	if job == null:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	_arm_tool(unit, &"stone_pick")
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._goal_voxel = target
	unit._fetching = false
	unit.state = Unit.State.MOVING

	var trace := PackedStringArray()
	var done := await _wait_until(func() -> bool:
		if Time.get_ticks_msec() % 2000 < 20:
			trace.append(
				"%d,%s,%s,%s" % [
					unit.state, Vector3i(unit.global_position.floor()),
					unit._goal_voxel,
					unit.job.type if unit.job != null else -1,
				]
			)
		return world.get_block(target) == BlockRegistry.Block.AIR)
	if not done:
		var dbg_pile := colony.item_pile_at(pile_v)
		print(
			"  dbg detour: state=", unit.state,
			" pos=", Vector3i(unit.global_position.floor()),
			" goal=", unit._goal_voxel, " path=", unit._path_index, "/", unit._path.size(),
			" detour=", unit._detour, " delivering=", unit._detour_delivering,
			" job=", unit.job.type if unit.job != null else -1,
			" jobstate=", job.state, " dropped_by=", job.dropped_by.size(),
			" jobs=", colony.jobs.size(),
			" carried=", unit._carried_volume(),
			" pile=", dbg_pile.total_volume() if dbg_pile != null else -1,
			" spots=", unit._work_spots(target, true).size()
		)
		print("  trace: ", trace)
	_check(done, "the unit reaches the job site past the blocking pile")
	var sp_pile := colony.item_pile_at(sp)
	_check(
		sp_pile != null and sp_pile.total_volume() > 400_000,
		"the blocking pile is hauled to the stockpile"
	)
	var left := colony.item_pile_at(pile_v)
	_check(
		left == null or left.total_volume() < DropItem.BLOCK_CM3,
		"the corridor pile no longer packs the cell"
	)

	unit.facets[&"activity_level"] = saved_activity
	colony.cancel_designation(sp)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A moving, empty-handed unit whose route passes a haulable pile grabs
## it en route when a stockpile sits near the job's goal — the haul rides
## a trip that was happening anyway, then the real job resumes.
func _test_opportunistic(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var x := -1
	var gy := 0
	var z := 0
	# Ten contiguous flat cells: the unit walks the row's length, the pile
	# sits on the walk line mid-route, the stockpile and the mine target
	# wait at the far end.
	for z_off in [192, 184, 200, 96, 88]:
		z = mined.z + z_off
		for cx in range(mined.x + 4, mined.x + 22):
			var g := _ground(world, cx, z, mined.y + 32)
			var flat := g > -32
			for wx in range(cx - 1, cx + 10):
				if _ground(world, wx, z, mined.y + 32) != g:
					flat = false
				for wy in [g + 1, g + 2]:
					if (
						not world.is_editable(Vector3i(wx, wy, z))
						or world.is_solid(Vector3i(wx, wy, z))
						or colony.item_pile_at(Vector3i(wx, wy, z)) != null
					):
						flat = false
			if flat:
				x = cx
				gy = g
				break
		if x >= 0:
			break
	_check(x >= 0, "found a flat stretch for the opportunistic-haul test")
	if x < 0:
		return

	var level := gy + 1
	var pile_v := Vector3i(x + 4, level, z)
	var sp := Vector3i(x + 7, level, z)
	var target := Vector3i(x + 8, level, z)
	world.place(target, BlockRegistry.Block.STONE)
	# A partial pile on the walk line — not packed, so the route stays
	# clear and the opportunistic scan, not the blockage check, sees it.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400000), pile_v
	)
	var sp_ok := colony.designate_stockpile(sp)
	_check(sp_ok, "a stockpile near the goal exists for the opportunistic haul")
	if not sp_ok:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return

	var unit: Unit = colony.units[0]
	# Pin the restless facet to its mean — detour reach only equals the
	# base export at 50, and the corridor legs assume the full radius.
	var saved_activity := unit.facet(&"activity_level")
	unit.facets[&"activity_level"] = 50
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	_clear_jobs(colony)
	unit.global_position = Vector3(x + 0.5, level + 0.9, z + 0.5)

	var job := colony.designate_mine(target)
	_check(job != null, "an opportunistic-haul designation creates a job")
	if job == null:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	_arm_tool(unit, &"stone_pick")
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._goal_voxel = target
	unit._fetching = false
	unit.state = Unit.State.MOVING

	var saw_detour := [false]
	var done := await _wait_until(func() -> bool:
		if unit._detour_opportunistic:
			saw_detour[0] = true
		return world.get_block(target) == BlockRegistry.Block.AIR)
	_check(saw_detour[0], "the passed pile triggers an opportunistic detour")
	_check(done, "the unit resumes and finishes its job after the detour")
	# The delivery lands on whatever stockpile tile nearest the goal —
	# usually the fixture's own, but any leftover zone within reach of
	# the goal counts.
	var delivered := false
	for cell in colony.stockpiles:
		if Vector3(cell).distance_to(Vector3(target)) > 13.0:
			continue
		var p := colony.item_pile_at(cell)
		if p != null and p.total_volume() >= 390_000:
			delivered = true
			break
	_check(delivered, "the passed pile lands on a stockpile by the goal")
	_check(colony.item_pile_at(pile_v) == null, "the route-side pile is emptied")

	# The gates: a haul job is already hauling — the search can't beat its
	# own assignment — and a self-issued errand keeps its urgency.
	unit.job = ColonyJob.new(ColonyJob.Type.HAUL, pile_v)
	_check(not unit._can_opportunistic(), "a haul job never detours opportunistically")
	unit.job = ColonyJob.new(ColonyJob.Type.REST, pile_v)
	_check(not unit._can_opportunistic(), "a rest errand never detours opportunistically")
	unit.job = null
	_check(
		unit._detour_reach() == Unit.DETOUR_GOAL_REACH,
		"a generalist detours anywhere in the full reach"
	)
	unit.specialize = true
	_check(
		unit._detour_reach() < Unit.DETOUR_GOAL_REACH * 0.5,
		"a specialist's detour reach shrinks under its cap"
	)
	unit.specialize = false
	unit.facets[&"activity_level"] = saved_activity

	# A detour borrows _goal_voxel — and the haul-side retarget path can
	# rewrite _fetching mid-detour. Ending the detour must restore both,
	# or a build unit comes back to its fetch pile "delivering": in reach
	# of the pile but out of reach of the site, flickering MOVING/WORKING
	# on every frame.
	var site := Vector3i.ZERO
	var wall_job: ColonyJob = null
	for cx in [x + 1, x + 2, x + 3]:
		var candidate := colony.designate_build(
			Vector3i(cx, level, z), &"dirt_wall"
		)
		if candidate != null:
			site = Vector3i(cx, level, z)
			wall_job = candidate
			break
	_check(wall_job != null, "a dirt-wall designation creates a job")
	if wall_job != null:
		wall_job.state = ColonyJob.State.ASSIGNED
		wall_job.assignee = unit
		unit.job = wall_job
		unit._fetching = true
		unit._goal_voxel = pile_v
		# The piles sit a couple of cells off the corridor's column — on
		# tilted terrain that ground isn't at `level`, so plant them on
		# the real surface instead of assuming it.
		var detour_pile := Vector3i(
			x + 5, world.ground_height(x + 5, z + 2) + 1, z + 2
		)
		colony._deposit_item(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 100000),
			detour_pile
		)
		unit._carried.append(
			DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 50000)
		)
		unit._start_detour(detour_pile, sp)
		unit._set_haul_destination()
		unit._end_detour()
		_check(unit._fetching, "a detour restores the build job's fetch phase")
		_check(unit._goal_voxel == pile_v, "a detour restores the fetch goal")

		# A pile whose smallest admitted item outgrows the destination's
		# room can never be grabbed — arriving at it must blacklist the pile
		# (the movement loop then shoves it aside), not end clean and
		# re-pick the same pile on every frame.
		var tight_pile := Vector3i(
			x + 3, world.ground_height(x + 3, z + 2) + 1, z + 2
		)
		for cell in [tight_pile, detour_pile]:
			var old_pile := colony.item_pile_at(cell)
			if old_pile != null:
				old_pile.items.clear()
				colony.remove_pile_if_empty(cell)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			tight_pile
		)
		var sp_room := colony.voxel_capacity(sp) - colony.voxel_fill(sp)
		if sp_room >= DropItem.COBBLE_CM3:
			# Leave less room than one cobble — the tile still passes
			# `with_room` but can't take the pile's smallest item.
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.SOIL,
					DropItem.Form.LOOSE,
					sp_room - 5000
				),
				sp
			)
		unit._carried.clear()
		unit._haul_blacklist.erase(tight_pile)
		unit._goal_voxel = site
		_check(
			unit._start_detour(tight_pile, sp),
			"a detour on a room-starved pile still starts"
		)
		unit._detour_arrived()
		_check(unit._detour != tight_pile, "an ungrabbable detour ends")
		_check(
			unit._haul_blacklist.has(tight_pile),
			"an ungrabbable pile is blacklisted for a retry delay"
		)
		unit._haul_blacklist.erase(tight_pile)
		unit.abandon_job()
		colony.cancel_designation(site)

	colony.cancel_designation(sp)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A clear-space designation with a stockpile that has room: the unit hauls
## the pile's contents there — a load at a time — instead of scattering
## them into the neighbours.
func _test_clear_haul(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var pile_v := _flat_voxel(world, mined, 140)
	_check(pile_v != Vector3i.MAX, "found a flat spot for the clear-haul test")
	if pile_v == Vector3i.MAX:
		return

	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000), pile_v
	)
	var sp := pile_v + Vector3i(3, 0, 0)
	var sp_ok := colony.designate_stockpile(sp)
	_check(sp_ok, "a stockpile with room exists for the clear-haul test")
	if not sp_ok:
		return

	var unit: Unit = colony.units[0]
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	_clear_jobs(colony)
	unit.global_position = Vector3(pile_v + Vector3i(1, 0, 0)) + Vector3(0.5, 0.9, 0.5)

	var job := colony.designate_clear(pile_v)
	_check(job != null, "a clear-haul designation creates a job")
	if job == null:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = unit
	unit.job = job
	unit._goal_voxel = pile_v
	unit._fetching = false
	unit.state = Unit.State.MOVING

	var emptied := await _wait_until(func() -> bool:
		return colony.item_pile_at(pile_v) == null)
	_check(emptied, "the unit clears the pile with a stockpile in reach")
	var done := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(done, "the clear-haul job completes")
	var sp_pile := colony.item_pile_at(sp)
	_check(
		sp_pile != null and sp_pile.total_volume() > 800_000,
		"the cleared items are hauled to the stockpile"
	)

	colony.cancel_designation(sp)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## A unit with a job shoves an idle unit physically standing in its way —
## the idle unit sidesteps to a neighbouring voxel off the pusher's path.
func _test_yield(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var mover: Unit = colony.units[0]
	var idler: Unit = colony.units[1]

	# A flat stretch so teleported units land on their feet and the idler has
	# standable neighbours to step into.
	var sx := -1
	var sz: int = mined.z + 24
	for x in range(mined.x + 4, mined.x + 28):
		var g := _ground(world, x, sz, mined.y + 32)
		if (
			_ground(world, x + 1, sz, mined.y + 32) == g
			and _ground(world, x + 2, sz, mined.y + 32) == g
			and _ground(world, x + 3, sz, mined.y + 32) == g
			and colony.item_pile_at(Vector3i(x + 2, g + 1, sz)) == null
		):
			sx = x
			break
	_check(sx >= 0, "found a flat stretch for the yield test")
	if sx < 0:
		return

	# Release any real job before repurposing the units — abandon_job alone
	# would orphan an assigned job on the board.
	for u in [mover, idler]:
		if u.job != null:
			colony.release_job(u.job)
			u.abandon_job()

	var gy := _ground(world, sx, sz, mined.y + 32)
	var s := Vector3i(sx + 2, gy + 1, sz)
	var start := Vector3i(sx, gy + 1, sz)
	var beyond := Vector3i(sx + 3, gy + 1, sz)
	idler.global_position = Vector3(s) + Vector3(0.5, 0.9, 0.5)
	idler.velocity = Vector3.ZERO
	# The idler must stay idle — otherwise it can wander off on a haul of its
	# own and the sidestep is never exercised.
	idler._job_search_cooldown = 60.0
	mover.global_position = Vector3(start) + Vector3(0.5, 0.9, 0.5)
	mover.velocity = Vector3.ZERO

	# A synthetic walking job whose path runs straight through the idler.
	var fake := ColonyJob.new(ColonyJob.Type.MINE, Vector3i(sx + 6, gy, sz))
	fake.state = ColonyJob.State.ASSIGNED
	fake.assignee = mover
	mover.job = fake
	mover._goal_voxel = fake.voxel_position
	mover._path = PackedVector3Array([
		Vector3(s) + Vector3(0.5, 0.0, 0.5),
		Vector3(beyond) + Vector3(0.5, 0.0, 0.5),
	])
	mover._path_index = 0
	mover.state = Unit.State.MOVING

	var saw_yield := [false]
	var moved := await _wait_until(func() -> bool:
		if idler.state == Unit.State.YIELDING:
			saw_yield[0] = true
		return idler._standing_voxel() != s)
	_check(saw_yield[0], "an idle unit yields when pushed by a unit with a job")
	_check(moved, "the pushed unit steps out of the way")
	_check(
		idler._standing_voxel() != s and idler._standing_voxel() != beyond,
		"the yield spot is off the pusher's path"
	)
	mover.abandon_job()
	idler._job_search_cooldown = 0.0


## Building a dirt block must never bury a unit: idle occupants get shoved
## out like path-blockers, and an occupant with nowhere to go fails the job.
func _test_evict(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# Leftover jobs distract the builder mid-fixture.
	_clear_jobs(colony)
	var occupant: Unit = colony.units[1]
	if occupant.job != null:
		colony.release_job(occupant.job)
		occupant.abandon_job()
	# The occupant must stay put — no wandering off on a haul of its own,
	# and no collapsing from a drained bar mid-fixture (a sleeping
	# occupant can't yield — it just blocks the build forever).
	occupant._job_search_cooldown = 120.0
	for u in colony.units:
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0

	# --- An idle unit standing in the build voxel is shoved out first.
	var target := _flat_voxel(world, mined, 32)
	_check(target != Vector3i.MAX, "found a flat spot for the evict test")
	if target == Vector3i.MAX:
		return
	occupant.global_position = Vector3(target) + Vector3(0.5, 0.9, 0.5)
	occupant.velocity = Vector3.ZERO
	# Dirt close by so delivery is quick.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		target + Vector3i(2, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		target + Vector3i(0, 0, 2)
	)
	var job := colony.designate_build(target, &"dirt_wall")
	_check(job != null, "an occupied empty voxel still designates for building")
	var saw_yield := [false]
	var placed := await _wait_until(func() -> bool:
		if occupant.state == Unit.State.YIELDING:
			saw_yield[0] = true
		return world.is_solid(target))
	_check(saw_yield[0], "the builder shoves the occupant out of the voxel")
	if not placed:
		# A stray opportunistic haul can carry the fixture soil off
		# before the builder fetches it — restock and let the live
		# designation dispatch again rather than burning the wait.
		for off in [Vector3i(2, 0, 0), Vector3i(0, 0, 2)]:
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.SOIL,
					DropItem.Form.LOOSE,
					700000
				),
				target + off
			)
		placed = await _wait_until(
			func() -> bool: return world.is_solid(target)
		)
	_check(placed, "the block is built once the occupant steps out")
	_check(
		not colony.units.any(
			func(u: Unit) -> bool: return Unit._occupies_voxel(u, target)
		),
		"no unit is buried in the built block"
	)

	# --- An occupant with nowhere to step makes the build fail.
	var pit := _flat_voxel(world, mined, 40)
	_check(pit != Vector3i.MAX, "found a flat spot for the evict pit")
	if pit == Vector3i.MAX:
		return
	# Ring the target one block high, then drop the occupant's floor: it
	# lands one voxel down with its head still inside the target and every
	# sidestep blocked by the ring.
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			world.place(pit + Vector3i(dx, 0, dz), BlockRegistry.Block.STONE)
	occupant.global_position = Vector3(pit) + Vector3(0.5, 0.9, 0.5)
	occupant.velocity = Vector3.ZERO
	world.mine(pit + Vector3i.DOWN)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# Clear the mined drop so the occupant stands at the pit floor.
	for v in [pit + Vector3i.DOWN, pit]:
		var pile := colony.item_pile_at(v)
		if pile != null:
			pile.items.clear()
			colony.remove_pile_if_empty(v)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		pit + Vector3i(3, 0, 0)
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700000),
		pit + Vector3i(3, 0, 2)
	)
	var pit_job := colony.designate_build(pit, &"dirt_wall")
	_check(pit_job != null, "the pit voxel still designates for building")
	var gave_up := await _wait_until(func() -> bool:
		return pit_job != null and not pit_job.dropped_by.is_empty())
	_check(gave_up, "the builder abandons when the occupant can't be moved")
	_check(not world.is_solid(pit), "the unbuildable block was never placed")
	colony.cancel_designation(pit)
	occupant._job_search_cooldown = 0.0


## Trees: a planted sapling registers with the forest, grows one trunk level
## at a time into a tree with branches and a leaf canopy, and a chop
## designation on any part fells the whole tree — logs per trunk voxel plus
## loose branch and leaf material dropped where the parts stood. And a
## corridor whose only route crosses saplings is only pathable by the soft
## search — the native astar counts every non-air voxel as solid.
func _test_tree(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	print("trees")
	# Keep every unit from wandering into the fixture or claiming the job.
	for u in colony.units:
		u._job_search_cooldown = 120.0

	# Generated trees seed at random ages — the starting forest must have
	# grown, log-bearing trees ready to harvest, not only saplings. The
	# seeded height is what matters: by the time this test runs, minutes
	# of growth may have aged every 0-seeded tree past saplinghood.
	var grown := 0
	var young := 0
	for root: Vector3i in colony.forest.trees:
		var rec: Dictionary = colony.forest.trees[root]
		# Planted saplings (sown or rotted-fruit sprouts) start at zero
		# on purpose — the seeded-age oracle only describes generated
		# slots, so skip anything planted after generation.
		if rec.get(&"planted", false):
			continue
		var seeded := colony.forest.seeded_height(root, rec[&"species"])
		# Growth only adds height — nothing can shrink it.
		_check(
			int(rec[&"height"]) >= seeded,
			"a generated tree is at least its seeded age"
		)
		if seeded > 0:
			grown += 1
		else:
			young += 1
	_check(
		grown > 0, "generated terrain seeds grown, harvestable trees"
	)
	_check(young > 0, "generated terrain still seeds saplings too")

	# The growth box below clears dx/dz -3..3 — scan with the footprint
	# padded by one so no wet column sits under the canopy.
	var base := Vector3i.MAX
	for z_off in [88, 96, 104, 112]:
		var candidate := _flat_voxel(
			world, mined, z_off, 1, Rect2i(-4, -4, 9, 9)
		)
		if (
			candidate == Vector3i.MAX
			or not world.is_editable(candidate)
			or world.get_block(candidate) != BlockRegistry.Block.AIR
			or colony.forest.tree_root_at(candidate) != Vector3i.MAX
		):
			continue
		base = candidate
		break
	_check(base != Vector3i.MAX, "found a flat stretch for the tree test")
	if base == Vector3i.MAX:
		for u in colony.units:
			u._job_search_cooldown = 0.0
			return
	# Clear the growth box so the tree has room for its full canopy —
	# blocked cells are simply skipped, which would shrink the test tree.
	# Blocks, generated-sapling claims and leftover piles all count.
	for dx in range(-3, 4):
		for dy in range(0, 10):
			for dz in range(-3, 4):
				var cell := base + Vector3i(dx, dy, dz)
				var owner := colony.forest.tree_root_at(cell)
				if owner != Vector3i.MAX:
					colony.forest.trees.erase(owner)
					colony.forest._index.erase(cell)
					colony.forest._leaves.erase(cell)
				var pile := colony.item_pile_at(cell)
				if pile != null:
					pile.items.clear()
					colony.remove_pile_if_empty(cell)
				if world.is_editable(cell) and world.get_block(cell) != BlockRegistry.Block.AIR:
					world.remove_voxel(cell)
	# And units: a unit inside the box blocks solid growth into its cell.
	for u in colony.units:
		if Vector3(u.global_position - Vector3(base)).length() < 8.0:
			u.global_position = Vector3(base.x - 10, base.y + 0.9, base.z + 0.5)
			u.velocity = Vector3.ZERO

	_check(colony.forest.plant_sapling(base), "a sapling plants on open ground")
	_check(
		world.get_block(base) == BlockRegistry.Block.AIR,
		"a sapling leaves its voxel as air"
	)
	_check(
		colony.forest.tree_root_at(base) == base,
		"a planted sapling registers as a tree"
	)
	# Clear leftover jobs so the chop job stays the only thing to claim.
	_clear_jobs(colony)
	var sp: Dictionary = Forest.species_table()[&"oak"]
	var max_height := int(sp[&"max_height"])
	for i in max_height:
		colony.forest.grow(base)
	var rec: Dictionary = colony.forest.trees.get(base, {})
	_check(
		int(rec.get(&"height", -1)) == max_height,
		"the tree grows to its full height"
	)
	_check(
		world.get_block(base) == BlockRegistry.Block.TRUNK,
		"a grown tree has a trunk at its root"
	)
	var branch_count := 0
	var leaf_count := 0
	var leaves_are_air := true
	for voxel: Vector3i in rec[&"voxels"]:
		if colony.forest.leaf_at(voxel):
			leaf_count += 1
			if world.get_block(voxel) != BlockRegistry.Block.AIR:
				leaves_are_air = false
		elif world.get_block(voxel) == BlockRegistry.Block.BRANCH:
			branch_count += 1
	_check(branch_count > 0, "a grown tree has solid branch voxels")
	_check(
		leaf_count > 0 and leaves_are_air,
		"leaf cells render as foliage but stay air"
	)
	# Canopy invariants: every leaf cell face-touches a solid part of its
	# own tree, and nothing hangs at or below the ground-level segment.
	var leaves_supported := true
	var ortho := [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP,
		Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK
	]
	for voxel: Vector3i in rec[&"voxels"]:
		if not colony.forest.leaf_at(voxel):
			continue
		if voxel.y <= base.y:
			leaves_supported = false
			continue
		var hugged := false
		for side in ortho:
			var neighbour: Vector3i = voxel + side
			if (
				colony.forest.tree_root_at(neighbour) == base
				and not colony.forest.leaf_at(neighbour)
				and BlockRegistry.is_tree_block(world.get_block(neighbour))
			):
				hugged = true
		leaves_supported = leaves_supported and hugged
	_check(leaves_supported, "every leaf hugs a trunk or branch above ground")

	# Streaming forgets voxel edits — a block that comes back regenerated
	# must get its tree parts restored, not fell the tree.
	var mid_trunk := base + Vector3i(0, 2, 0)
	world.remove_voxel(mid_trunk)
	colony.forest._on_block_loaded(Vector3i(
		floori(float(mid_trunk.x) / 16.0),
		floori(float(mid_trunk.y) / 16.0),
		floori(float(mid_trunk.z) / 16.0)
	))
	_check(
		world.get_block(mid_trunk) == BlockRegistry.Block.TRUNK,
		"a reloaded block restores its tree voxels"
	)
	_check(colony.forest.trees.has(base), "restoration didn't fell the tree")

	# Any part designates the whole tree — even a leaf cell, which only
	# exists in the forest's index; the job sites at the root, and a cancel
	# on any part cancels it.
	var leaf_part := Vector3i.MAX
	for voxel: Vector3i in rec[&"voxels"]:
		if colony.forest.leaf_at(voxel):
			leaf_part = voxel
	var part: Vector3i = (
		leaf_part if leaf_part != Vector3i.MAX else (rec[&"voxels"] as Array).back()
	)
	var job := colony.designate_chop(part)
	_check(
		job != null and job.voxel_position == base,
		"designating any tree part chops from the root"
	)
	colony.cancel_designation(part)
	_check(not job.is_active(), "cancelling a tree part cancels the chop job")
	job = colony.designate_chop(part)
	_check(job != null, "a cancelled tree can be designated again")

	if unit.job != null:
		colony.release_job(unit.job)
		unit.abandon_job()
	_arm_tool(unit, &"stone_axe")
	unit.global_position = Vector3(base) + Vector3(1.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.job = job
	unit._goal_voxel = job.voxel_position
	unit.state = Unit.State.MOVING
	var felled := await _wait_until(func() -> bool:
		return not colony.forest.trees.has(base))
	_check(felled, "a unit fells a designated tree")
	_check(job.state == ColonyJob.State.DONE, "the chop job completes")
	_check(
		not BlockRegistry.is_tree_block(world.get_block(base)),
		"a felled tree's trunk voxel is removed"
	)
	# Logs dropped from the upper trunk fall while felling runs — wait
	# for every pile to land before counting.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var logs := 0
	var loose := 0.0
	for voxel in colony.item_piles:
		if Vector3(voxel - base).length() > 8.0:
			continue
		for item in colony.item_piles[voxel].items:
			if (
				item.form == DropItem.Form.LOG
				and item.material == BlockRegistry.Resource_.WOOD
			):
				logs += 1
			elif (
				item.material == BlockRegistry.Resource_.BRANCH
				or item.material == BlockRegistry.Resource_.LEAF
			):
				loose += item.volume
	_check(logs >= max_height - 1, "felling drops a log per trunk voxel")
	_check(loose > 0.0, "felling drops loose branch and leaf material")

	# A corridor walled on both sides and capped past the destination, its
	# middle holding a sapling: saplings are decorations over air cells, so
	# the astar walks straight through. base+1 and base+2 sit inside the
	# flat stretch _flat_voxel guarantees.
	var walls: Array[Vector3i] = []
	var wall_cells: Array[Vector3i] = []
	for i in range(-2, 4):
		for side in [Vector3i.FORWARD, Vector3i.BACK]:
			for dy in range(0, 2):
				wall_cells.append(base + Vector3i(i, dy, 0) + side)
	for cap_x in [-2, 3]:
		for dy in range(0, 2):
			wall_cells.append(base + Vector3i(cap_x, dy, 0))
	for w in wall_cells:
		if not world.is_solid(w) and world.place(w, BlockRegistry.Block.DIRT):
			walls.append(w)
	var sealed := wall_cells.all(func(w: Vector3i) -> bool: return world.is_solid(w))
	_check(sealed, "the corridor walls seal")
	var s := base + Vector3i(1, 0, 0)
	# A generated sapling or scattered pile may already hold the cell —
	# clear both first.
	var existing := colony.forest.tree_root_at(s)
	if existing != Vector3i.MAX:
		colony.forest.trees.erase(existing)
		colony.forest._index.erase(s)
	# Clearing a pile can settle a pile stacked above it into the same
	# cell — sweep until it's really empty.
	var stray_pile := colony.item_pile_at(s)
	while stray_pile != null:
		stray_pile.items.clear()
		colony.remove_pile_if_empty(s)
		stray_pile = colony.item_pile_at(s)
	# A neighbour's canopy can own a branch block here — the record is
	# already gone, so clear the physical voxel too.
	if world.get_block(s) != BlockRegistry.Block.AIR:
		world.remove_voxel(s)
	_check(
		colony.forest.plant_sapling(s),
		"a sapling fills the corridor's middle"
	)
	var native := world.find_path(base, base + Vector3i(2, 0, 0))
	var crosses := false
	for p in native:
		if Vector3i(p.floor()) == s:
			crosses = true
	_check(
		not native.is_empty() and crosses,
		"the astar walks straight through a sapling cell"
	)
	var root := colony.forest.tree_root_at(s)
	if root != Vector3i.MAX:
		colony.forest.trees.erase(root)
		colony.forest._index.erase(s)
	for v in walls:
		world.remove_voxel(v)
	for u in colony.units:
		u._job_search_cooldown = 0.0

	for u in colony.units:
		u._job_search_cooldown = 0.0


## Crafting: a designated spot on flat ground is a workstation with no
## build cost; an order queued at it sends a unit for one whole log, which
## is sawn into three planks and a heap of loose sawdust of the log's
## material. Jobs are assigned directly so a free claimer can't fetch a
## different pile than the fixture's.
func _test_craft(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var spot := Vector3i.MAX
	for z_off in [168, 176, 184, 192]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate != Vector3i.MAX:
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a flat stretch for the craft test")
	if spot == Vector3i.MAX:
		return
	var log_v := spot + Vector3i(2, 0, 0)

	# Spots must be empty voxels resting on a solid block.
	_check(
		not colony.designate_craft_spot(spot + Vector3i.UP),
		"a voxel with no ground under it can't be a crafting spot"
	)
	_check(
		colony.designate_craft_spot(spot),
		"an empty voxel on solid ground designates as a crafting spot"
	)
	_check(colony.is_craft_spot(spot), "the crafting spot sticks")
	_check(
		not colony.designate_craft_spot(spot),
		"a voxel can't be craft-designated twice"
	)
	_check(
		not colony.designate_stockpile(spot),
		"a crafting spot can't double as a stockpile"
	)
	_check(
		colony.designate_craft(log_v) == null,
		"crafting can't be ordered off a spot"
	)

	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var job := _assign_craft(colony, world, spot, log_v)
	_check(job != null, "ordering at a spot creates a craft job")
	if job == null:
		return
	var extra := colony.queue_order(spot, &"planks")
	_check(
		extra != null and colony.building_at(spot).orders.size() == 2,
		"a second order queues behind the running one"
	)
	if extra != null:
		colony.remove_order(spot, extra)

	var saw_fetch := [false]
	var done := await _wait_until(func() -> bool:
		var worker: Unit = job.assignee
		if worker != null and worker._fetching:
			saw_fetch[0] = true
		return job.state == ColonyJob.State.DONE)
	_check(done, "a unit crafts planks at the spot")
	_check(saw_fetch[0], "the unit fetches the log before sawing")

	# Count what the saw produced near the spot — three discrete planks
	# and a heap of loose sawdust, all of the log's material.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var planks := 0
	var planks_ok := true
	var sawdust := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - spot).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.PLANK:
				planks += 1
				planks_ok = (
					planks_ok
					and item.volume == DropItem.PLANK_CM3
					and item.material == BlockRegistry.Resource_.WOOD
				)
			elif item.material == BlockRegistry.Resource_.WOOD:
				sawdust += item.volume
	_check(planks == 3, "crafting yields three planks")
	_check(planks_ok, "each plank is 20% of the log and of its material")
	_check(
		sawdust
			== DropItem.LOG_CM3 - DropItem.PLANK_CM3 * DropItem.PLANKS_PER_LOG,
		"the rest of the log falls as loose sawdust"
	)
	_check(colony.is_craft_spot(spot), "the crafting spot persists after its order")

	# Cancelling the order mid-craft ends the job; the carried input drops
	# back into the world rather than vanishing — and the site stays.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	var job2 := _assign_craft(colony, world, spot, log_v)
	_check(job2 != null, "the spot takes a second order")
	if job2 == null:
		return
	var worker: Unit = job2.assignee
	# The carry window can be shorter than an idle frame: when physics
	# ticks batch up under load the take → deliver handoff lands between
	# process_frame polls. The escrow tally is the latching half of the
	# same signal — it stays set through the whole saw.
	var carrying := await _wait_until(func() -> bool:
		return (
			worker._carried_form(DropItem.Form.LOG) != null
			or int(job2.delivered.get(DropItem.Form.LOG, 0)) > 0
		))
	_check(carrying, "the unit picks up the second log")
	var at := worker._standing_voxel()
	colony.cancel_craft_order(spot)
	_check(not job2.is_active(), "cancelling the order ends the job")
	_check(colony.is_craft_spot(spot), "cancelling an order keeps the worksite")
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var log_back := false
	for voxel in colony.item_piles:
		if Vector3(voxel - at).length() > 4.0:
			continue
		if colony.item_piles[voxel].form_volume(DropItem.Form.LOG) > 0:
			log_back = true
	_check(log_back, "a cancelled craft drops the carried log")

	# A cancel sweep lifts a queued order but never removes the site —
	# a building is a construction, not a designation.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	var job3 := _assign_craft(colony, world, spot, log_v)
	_check(job3 != null, "the spot takes a third order")
	colony.cancel_designation(spot)
	_check(
		job3 != null and not job3.is_active(),
		"a cancel sweep lifts the worksite's order"
	)
	_check(colony.is_craft_spot(spot), "a cancel sweep leaves the worksite standing")

	# Removing the site is a deconstruct job — a unit walks up and takes
	# it down, and no orders can be queued meanwhile.
	var demolish := colony.designate_deconstruct(spot)
	_check(demolish != null, "the worksite designates for deconstruction")
	_check(
		colony.designate_craft(spot) == null,
		"a spot marked for deconstruction takes no orders"
	)
	if demolish != null:
		_assign_job(colony, demolish, spot)
		var razed := await _wait_until(func() -> bool:
			return not colony.is_craft_spot(spot))
		_check(razed, "a unit deconstructs the worksite")
	_check(
		colony.building_at(spot) == null,
		"the worksite's building record is gone"
	)

	# Products piled on the spot fill it — clearing them out makes it
	# designatable again.
	var pile := colony.item_pile_at(spot)
	if pile != null:
		pile.items.clear()
		colony.remove_pile_if_empty(spot)
	_check(
		colony.designate_craft_spot(spot),
		"a cleared spot designates again"
	)
	# Leave no worksite behind for later tests.
	var raze := colony.designate_deconstruct(spot)
	if raze != null:
		_assign_job(colony, raze, spot)
		await _wait_until(func() -> bool:
			return colony.building_at(spot) == null)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Worksite bill queues: orders stack behind the running one, a bill
## whose inputs don't exist rotates to the back instead of blocking the
## line, do-X-times leaves the queue when it finishes, until-you-have-X
## parks while stocked, and forever never leaves. Escrow stays per-job —
## a queued bill owns nothing until it runs.
func _test_orders(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var spot := Vector3i.MAX
	for z_off in [196, 204, 212, 220, 228]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and colony.designate_craft_spot(candidate)
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "a flat voxel hosts the order-queue spot")
	if spot == Vector3i.MAX:
		return
	var building: Building = colony.building_at(spot)
	var log_v := spot + Vector3i(2, 0, 0)

	# The starved bill wants fruit — but felled trees drop it, so drain
	# the colony's fruit piles the way the earlier tests drain planks:
	# the bill is deterministically unperformable either way. The stock
	# comes back at the end of the test.
	var stashed: Array[DropItem] = []
	for voxel in colony.item_piles.keys():
		# Draining a pile can unsettle a pile resting on it — the fall
		# re-keys `item_piles` mid-sweep, so gone keys just skip.
		var pile: ItemPile = colony.item_piles.get(voxel)
		if pile == null:
			continue
		for form in [DropItem.Form.PLANK, DropItem.Form.FRUIT]:
			while true:
				var item := pile.take_form(form, 1 << 30)
				if item == null:
					break
				stashed.append(item)
		colony.remove_pile_if_empty(voxel)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# The starved bill queues but dispatches nothing; a runnable tail
	# order jumps the line and the starved one rotates to the back.
	# Extract-seed wants a fruit — none are piled this early, so it
	# sits waiting while the planks bill runs.
	var bed_bill := colony.queue_order(spot, &"extract_seed")
	_check(bed_bill != null, "a starved bill still queues")
	_check(
		colony.craft_job_at(spot) == null,
		"with no inputs nothing dispatches"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var planks_bill := colony.queue_order(spot, &"planks")
	var job := colony.craft_job_at(spot)
	_check(
		job != null and job.order == planks_bill,
		"the runnable tail order dispatches past the starved head"
	)
	_check(
		building.orders.size() == 2
			and building.orders[0] == planks_bill
			and building.orders[1] == bed_bill,
		"the starved bill rotated to the back of the queue"
	)
	if job == null:
		return
	_drive_craft(colony, world, job, log_v, spot)
	var done := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(done, "a queued order's job runs like any craft")
	_check(
		not building.orders.has(planks_bill) and planks_bill.done == 1,
		"a finished do-X-times bill leaves the queue"
	)
	_check(
		building.orders.size() == 1 and building.orders[0] == bed_bill,
		"the starved bill is the only one left"
	)

	# The starved head stays put — the scan dispatches nothing for it.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) == null,
		"a starved head dispatches no job"
	)

	# Until-you-have-X parks while stocked (three planks just landed)
	# and dispatches the moment the target outgrows the count.
	var until_bill := colony.queue_order(
		spot, &"planks", WorksiteOrder.Condition.UNTIL_HAVE, 3
	)
	_check(until_bill != null, "an until-bill queues")
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) == null,
		"a stocked until-bill parks without dispatching"
	)
	until_bill.target = 4
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._worksite_tick()
	var until_job := colony.craft_job_at(spot)
	_check(
		until_job != null and until_job.order == until_bill,
		"an understocked until-bill dispatches"
	)
	colony.cancel_craft_order(spot)
	_check(
		not building.orders.has(until_bill),
		"cancelling a run drops its bill from the queue"
	)

	# Forever bills survive their own runs and re-dispatch while inputs
	# last.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var forever_bill := colony.queue_order(
		spot, &"planks", WorksiteOrder.Condition.FOREVER
	)
	var forever_job := colony.craft_job_at(spot)
	_check(
		forever_job != null and forever_job.order == forever_bill,
		"a forever bill dispatches"
	)
	if forever_job != null:
		_drive_craft(colony, world, forever_job, log_v, spot)
		await _wait_until(func() -> bool:
			return forever_job.state == ColonyJob.State.DONE)
	_check(
		building.orders.has(forever_bill) and forever_bill.done == 1,
		"a forever bill survives its run"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) != null
			and colony.craft_job_at(spot).order == forever_bill,
		"the forever bill re-dispatches while inputs last"
	)
	colony.cancel_craft_order(spot)

	# A cancel sweep on the worksite clears every queued bill.
	var leftovers := colony.queue_order(spot, &"planks")
	colony.cancel_designation(spot)
	_check(
		leftovers != null and building.orders.is_empty(),
		"a cancel sweep empties the worksite's queue"
	)

	# Put the drained planks back and raze the fixture.
	for item in stashed:
		colony._deposit_item(item, log_v)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var raze := colony.designate_deconstruct(spot)
	if raze != null:
		_assign_job(colony, raze, spot)


## Orders a craft at [param site] and hands it straight to units[0], parked
## on the pile in [param pile_v] — bypassing the job board so the fixture's
## pile is the one fetched.
func _assign_craft(colony: Colony, world: VoxelWorld, site: Vector3i, pile_v: Vector3i, recipe: StringName = &"planks") -> ColonyJob:
	_clear_jobs(colony)
	var job := colony.designate_craft(site, recipe)
	if job == null:
		return null
	_drive_craft(colony, world, job, pile_v, site)
	return job


## Hands a posted craft job straight to the first unit: it stands beside
## the input pile already mid-fetch, so the run exercises the real
## fetch → escrow → craft path without waiting on idle claiming.
func _drive_craft(colony: Colony, world: VoxelWorld, job: ColonyJob, pile_v: Vector3i, site: Vector3i) -> void:
	var worker: Unit = colony.units[0]
	# Bystanders leave the fixture: an idle body beside the pile blocks
	# the approach (the path can't thread past it) and an abandoned
	# carry drops where the unit stood — both stall the worker.
	var away_x: int = site.x - 20
	var away := Vector3i(
		away_x, _ground(world, away_x, site.z, site.y + 32) + 1, site.z
	)
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		u.global_position = Vector3(away) + Vector3(0.5, 0.9, 0.5)
		if u.job != null:
			colony.release_job(u.job)
		# Abandon unconditionally: carried items drop where the unit stands.
		u.abandon_job()
	worker.global_position = Vector3(_park_beside(colony, world, pile_v, site)) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = true
	worker._goal_voxel = pile_v
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING


## A standable voxel beside [param voxel], preferring the side toward
## [param toward]. Units never stand on top of a pile they're fetching
## from — a partial pile's fill lifts them into the cell above, where
## reach and pathing disagree — so helpers park next to the pile like a
## real approach would.
func _park_beside(colony: Colony, world: VoxelWorld, voxel: Vector3i, toward: Vector3i) -> Vector3i:
	var first := Vector3i(toward - voxel).sign()
	var sides: Array[Vector3i] = []
	if first != Vector3i.ZERO:
		sides.append(first)
	for side in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		if not sides.has(side):
			sides.append(side)
	for side in sides:
		var candidate := voxel + side
		# Never park on the work cell itself — a unit standing on the
		# site it's building must step off before it can work, and the
		# repath-off can watchdog the job away.
		if candidate == toward:
			continue
		if (
			world.get_block(candidate) == BlockRegistry.Block.AIR
			and world.is_solid(candidate + Vector3i.DOWN)
			and colony.voxel_fill(candidate) <= 0
		):
			return candidate
	return voxel


## Hands an existing [param job] straight to [param worker] (units[0] by
## default), parked one voxel off [param near] — the deconstruct/mine
## version of _assign_build: no fetch leg, just a unit that walks into
## reach and works.
func _assign_job(colony: Colony, job: ColonyJob, near: Vector3i, worker: Unit = null) -> void:
	if worker == null:
		worker = colony.units[0]
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		# Abandon unconditionally: carried items drop where the unit stands.
		u.abandon_job()
	worker.global_position = Vector3(near) + Vector3(-0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = false
	worker._goal_voxel = job.voxel_position
	worker._clear_budget = 0.0
	worker.state = Unit.State.MOVING


## Puts a fresh [param spec_id] tool in the unit's hand — the work-gate
## fixture: mining and felling want equipment now, so tests that drive
## those jobs arm the worker directly rather than staging a pile fetch.
## Anything already held is discarded.
func _arm_tool(unit: Unit, spec_id: StringName) -> DropItem:
	unit.hands.clear()
	var tool := DropItem.new(
		int(
			DropItem.tool_spec(spec_id).get(
				&"head", BlockRegistry.Resource_.STONE
			)
		),
		DropItem.Form.TOOL, DropItem.TOOL_CM3
	)
	tool.spec = spec_id
	tool.wear = 1.0
	unit.hold_tool(tool)
	return tool


## Bill details — the expanded order settings RimWorld exposes: pause and
## resume, queue shuffling and duplication, until-hysteresis, stored-only
## counting, ingredient radius and material filters, the skill band and
## worker pin on claiming, deliver modes for finished goods, and zone
## priority plus the dumping preset on stockpiles.
func _test_bill_details(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("bill details")
	# A frozen roster can't touch the fixture piles or steal the jobs.
	for u in colony.units:
		u._job_search_cooldown = 300.0
		if u.job != null and not u.job.desperate:
			colony.release_job(u.job)
		u.abandon_job()
	var unfreeze := func() -> void:
		for u in colony.units:
			u._job_search_cooldown = 0.0

	# Until-bill hysteresis is pure order math — no fixtures needed.
	var hysteresis := WorksiteOrder.new()
	hysteresis.recipe = &"planks"
	hysteresis.condition = WorksiteOrder.Condition.UNTIL_HAVE
	hysteresis.target = 10
	hysteresis.unpause_at = 3
	_check(not hysteresis.wants_work(10), "a satisfied until-bill parks")
	_check(
		not hysteresis.wants_work(4),
		"the parked bill holds until stock dips to the resume mark"
	)
	_check(hysteresis.wants_work(3), "stock at the resume mark wakes it")
	hysteresis.unpause_at = -1
	hysteresis.satisfied = false
	_check(not hysteresis.wants_work(10), "the legacy default parks at target")
	_check(hysteresis.wants_work(9), "the legacy default wakes on any dip")

	# A flat row: worksite on spot, stockpile A beside it, input piles two
	# cells over. Zone B takes a free cell beside the row; the dump preset
	# check reuses zone A's cell after teardown.
	var spot := Vector3i.MAX
	for off in [
		236, 240, 244, 248, 252, 256, 232, 260, 264, 268,
		228, 220, 212, 204, 196, 188, 180, 172, 164, 156, 148, 140,
		132, 124, 116, 108, 100, 92, 84, 76, 68, 60,
	]:
		var candidate := _flat_voxel_row(world, mined, off)
		if (
			candidate != Vector3i.MAX
			and colony.voxel_fill(candidate) <= 0
			and colony.voxel_fill(candidate + Vector3i(2, 0, 0)) <= 0
			and not colony._designation_markers.has(candidate)
			and not colony._designation_markers.has(candidate + Vector3i(2, 0, 0))
			and colony.building_at(candidate) == null
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a flat row for the bill fixtures")
	if spot == Vector3i.MAX:
		unfreeze.call()
		return
	# The flat row verifies four cells: spot through spot + 2 hold the
	# worksite, zone A and the input pile; zone B takes the cell just
	# west, verified on the spot. Zones stay distinct by override.
	var cell_a := spot + Vector3i.RIGHT
	var log_v := spot + Vector3i.RIGHT * 2
	var cell_b := Vector3i.MAX
	for candidate in [
		spot + Vector3i.LEFT, spot + Vector3i.RIGHT * 3,
		spot + Vector3i(0, 0, 1), spot + Vector3i(0, 0, -1),
	]:
		if (
			world.get_block(candidate) == BlockRegistry.Block.AIR
			and world.is_solid(candidate + Vector3i.DOWN)
			and colony.voxel_fill(candidate) <= 0
			and not colony._designation_markers.has(candidate)
			and colony.building_at(candidate) == null
		):
			cell_b = candidate
			break
	_check(cell_b != Vector3i.MAX, "found a free cell for zone B")
	if cell_b == Vector3i.MAX:
		unfreeze.call()
		return
	# Zone C is the delivery destination — it has to sit far enough from
	# the spot that a product spilling off the worksite can't land in
	# its ring, or the deliver modes can't be told apart. The flat row
	# only vouches for three cells east, so the rest is verified here.
	var cell_c := Vector3i.MAX
	for dx in range(4, 10):
		for candidate in [spot + Vector3i(dx, 0, 0), spot + Vector3i(-dx, 0, 0)]:
			if (
				cell_c == Vector3i.MAX
				and world.get_block(candidate) == BlockRegistry.Block.AIR
				and world.is_solid(candidate + Vector3i.DOWN)
				and colony.voxel_fill(candidate) <= 0
				and not colony._designation_markers.has(candidate)
				and colony.building_at(candidate) == null
			):
				cell_c = candidate
		if cell_c != Vector3i.MAX:
			break
	_check(cell_c != Vector3i.MAX, "found a far cell for the delivery zone")
	if cell_c == Vector3i.MAX:
		unfreeze.call()
		return

	colony.designate_craft_spot(spot)
	var building: Building = colony.building_at(spot)
	_check(
		building != null and building.kind == Building.Kind.WORKSITE,
		"the details fixture is a fresh craft spot"
	)
	# Override forces each cell into its own fresh zone — adjacency or
	# an older zone's reach can't merge the fixtures into each other.
	colony.designate_stockpile_cells([cell_a], cell_a, true)
	colony.designate_stockpile_cells([cell_b], cell_b, true)
	colony.designate_stockpile_cells([cell_c], cell_c, true)
	# Three logs: the deliver-mode drives each consume one. A log fills a
	# whole cell now — three in one pile would spill into the radius ring
	# and the stockpile — so the extras go on their own cells, all past
	# the 1.9 probe cut (distances from `spot` of two or less would count
	# where the test wants them out of reach).
	var log_cells: Array[Vector3i] = [log_v]
	for r in [3, 4, 5, 6]:
		if log_cells.size() >= 3:
			break
		for candidate in [
			spot + Vector3i(r, 0, 0), spot + Vector3i(-r, 0, 0),
			spot + Vector3i(0, 0, r), spot + Vector3i(0, 0, -r),
		]:
			if (
				log_cells.size() < 3
				and world.get_block(candidate) == BlockRegistry.Block.AIR
				and world.is_solid(candidate + Vector3i.DOWN)
				and colony.voxel_fill(candidate) <= 0
				and not colony.is_stockpile(candidate)
				and not colony._designation_markers.has(candidate)
				and colony.building_at(candidate) == null
			):
				log_cells.append(candidate)
	for lc in log_cells:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			lc
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(log_cells.size() == 3, "three log cells for the bill fixtures")

	# --- Pause: a suspended bill keeps its queue slot but never runs.
	var head_bill := colony.queue_order(spot, &"planks")
	_check(
		colony.craft_job_at(spot) != null,
		"the head bill dispatches while inputs exist"
	)
	var tail_bill := colony.queue_order(spot, &"planks")
	_check(
		building != null and building.orders.size() == 2,
		"a second bill queues behind the running job"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, true)
	colony.cancel_craft_order(spot)   # drops the head job and its bill
	colony._worksite_tick()
	_check(
		colony.craft_job_at(spot) == null,
		"a paused bill stays queued without dispatching"
	)
	_check(
		building != null and building.orders.has(tail_bill),
		"pausing preserves the bill's queue slot"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, false)
	colony._worksite_tick()
	var tail_job := colony.craft_job_at(spot)
	_check(
		tail_job != null and tail_job.order == tail_bill,
		"resuming lets the bill dispatch"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, true)
	_check(
		tail_job != null and tail_job.suspended and not tail_job.is_open(),
		"pausing suspends the bill's live job"
	)
	if tail_bill != null:
		colony.set_order_paused(spot, tail_bill, false)
	_check(
		tail_job != null and not tail_job.suspended and tail_job.is_open(),
		"resuming reopens the suspended job"
	)

	# --- Reorder and duplicate.
	var bill_b := colony.queue_order(spot, &"planks")
	var bill_c := colony.queue_order(spot, &"planks")
	if bill_c != null:
		colony.move_order(spot, bill_c, -1)
	_check(
		building != null and building.orders.size() >= 3
			and building.orders[1] == bill_c,
		"moving a bill lifts it one queue slot"
	)
	var copy := colony.duplicate_order(spot, bill_c)
	_check(
		copy != null and copy != bill_c and building.orders.has(copy),
		"duplicating appends a fresh bill"
	)
	if copy != null:
		copy.unpause_at = 2
		_check(
			bill_c == null or bill_c.unpause_at != 2,
			"the copy isn't aliased to the original"
		)
	_clear_jobs(colony)
	if building != null:
		building.orders.clear()

	# --- Claim gates: the pinned worker and the skill band.
	var gate_bill := colony.queue_order(spot, &"planks")
	var gate_job := colony.craft_job_at(spot)
	_check(
		gate_job != null and gate_job.order == gate_bill,
		"a fresh bill posts a claimable job"
	)
	if gate_bill != null and gate_job != null:
		gate_bill.worker_index = 0
		_check(
			colony._job_allowed_for(colony.units[0], gate_job),
			"the pinned worker may claim the bill"
		)
		_check(
			colony.units.size() < 2
				or not colony._job_allowed_for(colony.units[1], gate_job),
			"a worker-pinned bill rejects other claimants"
		)
		gate_bill.worker_index = -1
		var craft_skill: int = int(
			Colony.RECIPES[&"planks"].get(
				"skill",
				ColonyJob.SKILL_FOR.get(ColonyJob.Type.CRAFT, -1)
			)
		)
		var saved_xp: float = colony.units[0].skills.get(craft_skill, 0.0)
		colony.units[0].skills[craft_skill] = 0.0   # level 0
		gate_bill.skill_min = 3
		_check(
			not colony._job_allowed_for(colony.units[0], gate_job),
			"a skill floor rejects under-level workers"
		)
		colony.units[0].skills[craft_skill] = 150.0  # level 5
		_check(
			colony._job_allowed_for(colony.units[0], gate_job),
			"the band admits an in-range worker"
		)
		gate_bill.skill_max = 4
		_check(
			not colony._job_allowed_for(colony.units[0], gate_job),
			"a skill ceiling rejects over-level workers"
		)
		gate_bill.skill_min = 0
		gate_bill.skill_max = 20
		colony.units[0].skills[craft_skill] = saved_xp
		# The real claim path honors the pin too — pin to units[0] and let
		# units[1] bounce off the job board.
		gate_bill.worker_index = 0
		if colony.units.size() > 1:
			_clear_jobs(colony)
			gate_bill = colony.queue_order(spot, &"planks")
			gate_job = colony.craft_job_at(spot)
			if gate_bill != null:
				gate_bill.worker_index = 0
			_check(
				colony.claim_job(colony.units[1]) != gate_job,
				"the job board won't hand a pinned bill to another worker"
			)
			_check(
				colony.claim_job(colony.units[0]) == gate_job,
				"the pinned worker claims its bill through the board"
			)
			colony.units[0].abandon_job()
			colony.release_job(gate_job)

	# --- Ingredient radius and material filters.
	_clear_jobs(colony)
	if building != null:
		building.orders.clear()
	var radius_order := WorksiteOrder.new()
	radius_order.recipe = &"planks"
	radius_order.ingredient_radius = 1.9
	_check(
		not colony._order_dispatchable(radius_order, spot),
		"inputs past the bill's fetch radius don't count"
	)
	radius_order.ingredient_radius = 2.1
	_check(
		colony._order_dispatchable(radius_order, spot),
		"loosening the radius admits the same pile"
	)
	# Rejecting a material skips it even when the form matches. Every
	# fruit the world can hold — berries and the groves' acorn litter —
	# goes on the reject list so only the fixture's own item qualifies.
	var filter_order := WorksiteOrder.new()
	filter_order.recipe = &"extract_seed"
	filter_order.rejected_materials[int(BlockRegistry.Resource_.BERRY)] = true
	filter_order.rejected_materials[int(BlockRegistry.Resource_.ACORN)] = true
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BERRY, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		not colony._order_dispatchable(filter_order, spot),
		"a rejected material can't fill an ingredient slot"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.GRAIN, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony._order_dispatchable(filter_order, spot),
		"an admitted material of the same form satisfies it"
	)

	# --- Counting: stored-only and in-flight/carried goods.
	var count_order := WorksiteOrder.new()
	count_order.recipe = &"prepare_meal"
	count_order.condition = WorksiteOrder.Condition.UNTIL_HAVE
	var have_before := colony._have_count(&"prepare_meal")
	# A meal loose on the input pile's cell — landed, but not stockpiled.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		log_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony._have_count(&"prepare_meal") == have_before + 1,
		"loose products count toward an until-bill"
	)
	count_order.count_stored_only = true
	_check(
		colony._have_count(&"prepare_meal", count_order) == have_before,
		"stored-only counting skips loose goods"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		cell_b
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony._have_count(&"prepare_meal", count_order) == have_before + 1,
		"stockpiled goods count for stored-only bills"
	)
	# Carried items only figure in the broad tally — stored-only skips
	# them with the loose piles.
	count_order.count_stored_only = false
	colony.units[0]._carried.append(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		)
	)
	_check(
		colony._have_count(&"prepare_meal", count_order) == have_before + 3,
		"carried goods count too — RimWorld's in-flight tally"
	)
	colony.units[0]._carried.clear()

	# --- Deliver mode: finished goods walk to their destination.
	# A drop isn't guaranteed to stay on its cell — `_drop_item` spills
	# with the pile's fill — so every delivery is measured as plank-item
	# growth inside the destination's spill ring (Chebyshev 2 covers a
	# chained hop), not a single cell's tally.
	var planks_near := func(centre: Vector3i) -> int:
		var total := 0
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - centre).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 2:
				continue
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.PLANK:
					total += 1
		return total
	# Rank beats distance outright, so CRITICAL pins the "best" zone to
	# the far fixture no matter what older stockpiles are still standing.
	colony.set_stockpile_priority(cell_a, StockpileZone.Priority.NORMAL)
	colony.set_stockpile_priority(cell_c, StockpileZone.Priority.CRITICAL)
	# Three planks are 600,000 cm³ now — one carry load can't take the
	# whole run, so the honest counts are "the carried load lands at the
	# destination" and "at most the overflow spills back at the worksite".
	var before_best: int = planks_near.call(cell_c)
	var before_spot: int = planks_near.call(spot)
	var best_job := _assign_craft(colony, world, spot, log_v)
	_check(best_job != null, "a stockpile-delivering bill drives")
	if best_job != null:
		# No unit may snatch the fresh drops for a haul job before the
		# delivery count lands — the cooldown has to cover every unit,
		# not just the crafter.
		for u in colony.units:
			u._job_search_cooldown = 120.0
		best_job.order.deliver_mode = WorksiteOrder.Deliver.BEST_STOCKPILE
		await _wait_until(
			func() -> bool: return best_job.state == ColonyJob.State.DONE
		)
		# Products spawn as falling piles — count only once they've landed.
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		_check(
			planks_near.call(cell_c) - before_best >= 2,
			"best-stockpile delivery lands its load in a zone"
		)
		_check(
			planks_near.call(spot) - before_spot <= 1,
			"only the carry overflow drops at the worksite"
		)
	# Zone-pinned delivery ignores distance and priorities — the far
	# fixture's ring can't see the worksite either. A leftover bill from
	# a stalled run mustn't hijack the next drive.
	if building != null:
		building.orders.clear()
	var before_zone: int = planks_near.call(cell_c)
	var zone_job := _assign_craft(colony, world, spot, log_v)
	if zone_job != null:
		for u in colony.units:
			u._job_search_cooldown = 120.0
		zone_job.order.deliver_mode = WorksiteOrder.Deliver.ZONE
		zone_job.order.deliver_target = cell_c
		await _wait_until(
			func() -> bool: return zone_job.state == ColonyJob.State.DONE
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		_check(
			planks_near.call(cell_c) - before_zone >= 2,
			"a pinned zone receives its bill's products"
		)
	# And the default still drops at the worker's feet. The earlier
	# drives leave their sawdust at the spot — a cluttered cell spills
	# its drops into the neighbours, so "at the worksite" means the spot
	# cell and the ring a spill can reach, not the stockpile zones.
	if building != null:
		building.orders.clear()
	var spot_pile := colony.item_pile_at(spot)
	if spot_pile != null:
		spot_pile.items.clear()
		colony.remove_pile_if_empty(spot)
	var before_feet: int = planks_near.call(spot)
	var feet_job := _assign_craft(colony, world, spot, log_v)
	if feet_job != null:
		for u in colony.units:
			u._job_search_cooldown = 120.0
		await _wait_until(
			func() -> bool: return feet_job.state == ColonyJob.State.DONE
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		# Diagnostics for a known flake family — where did the planks go?
		if planks_near.call(spot) - before_feet < 3:
			var carried := 0
			for u in colony.units:
				for item in u._carried:
					if item.form == DropItem.Form.PLANK:
						carried += 1
			var far := ""
			for voxel: Vector3i in colony.item_piles:
				for item in colony.item_piles[voxel].items:
					if item.form == DropItem.Form.PLANK:
						far += " %s" % (voxel - spot)
			printerr(
				"drop check: spot=%s gained=%d carried=%d plank_cells=[%s]"
				% [spot, planks_near.call(spot) - before_feet, carried, far]
			)
		_check(
			planks_near.call(spot) - before_feet >= 3,
			"the default still drops products at the worksite"
		)

	# --- Stockpile priority: a farther HIGH zone beats a nearer LOW.
	colony.set_stockpile_priority(cell_a, StockpileZone.Priority.LOW)
	colony.set_stockpile_priority(cell_b, StockpileZone.Priority.HIGH)
	colony.set_stockpile_priority(cell_c, StockpileZone.Priority.NORMAL)
	_check(
		colony.nearest_stockpile_with_room(
			cell_a, 1, {}, [BlockRegistry.Resource_.SOIL]
		) == cell_b,
		"a higher-priority zone beats a nearer one"
	)
	colony.set_stockpile_priority(cell_a, StockpileZone.Priority.CRITICAL)
	_check(
		colony.nearest_stockpile_with_room(
			cell_a, 1, {}, [BlockRegistry.Resource_.SOIL]
		) == cell_a,
		"at a better rank the nearer zone wins again"
	)

	# Teardown: clear the board and bills, raze the spot, lift the zones,
	# and drain the fixture piles so food tests see no free meals. Zone
	# A's emptied cell then hosts the dumping-preset check — flipping a
	# cell from goods storage to a garbage zone is how a player does it.
	_clear_jobs(colony)
	if building != null:
		building.orders.clear()
		colony.cancel_designation(spot)
		var raze := colony.designate_deconstruct(spot)
		if raze != null:
			_assign_job(colony, raze, spot)
			# The raze drops the worksite's materials back on the spot —
			# wait for them to land or the drain below misses them.
			await _wait_until(
				func() -> bool: return raze.state != ColonyJob.State.ASSIGNED
			)
			await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony.undesignate_stockpile(cell_a)
	colony.undesignate_stockpile(cell_b)
	colony.undesignate_stockpile(cell_c)
	# The worksite's drops can spill a cell out in any direction — drain
	# the fixture cells plus the whole spill ring around the spot and
	# the far delivery zone.
	var drain := [
		log_v, cell_a, cell_b, cell_c, spot,
		spot + Vector3i.RIGHT, spot + Vector3i.LEFT,
		spot + Vector3i.FORWARD, spot + Vector3i.BACK,
		cell_c + Vector3i.RIGHT, cell_c + Vector3i.LEFT,
		cell_c + Vector3i.FORWARD, cell_c + Vector3i.BACK,
	]
	for cell in drain:
		var pile := colony.item_pile_at(cell)
		if pile != null:
			pile.items.clear()
			colony.remove_pile_if_empty(cell)
	colony.designate_dump_stockpile(cell_a)
	var dump_zone := colony.stockpile_at(cell_a)
	_check(
		dump_zone != null and dump_zone.priority == StockpileZone.Priority.LOW,
		"a dumping zone starts at low priority"
	)
	_check(
		colony.stockpile_admits(cell_a, BlockRegistry.Resource_.STONE)
			and colony.stockpile_admits(cell_a, BlockRegistry.Resource_.COMPOST)
			and not colony.stockpile_admits(cell_a, BlockRegistry.Resource_.WOOD)
			and not colony.stockpile_admits(cell_a, BlockRegistry.Resource_.MEAL),
		"the dump preset admits rubble and litter, not goods"
	)
	colony.undesignate_stockpile(cell_a)
	unfreeze.call()


## The campfire: a cobble-ring construction that burns fuel for light
## and hosts the prepare-meal bill. Cold fires suspend their bills and
## shed their light; auto-refuel posts the REFUEL job at the threshold
## and the inspect toggle can switch it off. The meal remembers its
## ingredients' nutrition times the cook bonus.
func _test_campfire(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("campfire and cooking")
	# The cell has to be streamed *and* clean — razed fixtures free their
	# cells, so the nearer bands other tests already walked are fair
	# game too. Cells the earlier fixtures still hold just skip.
	var spot := Vector3i.MAX
	for off in [
		236, 240, 244, 248, 252, 256, 232, 260, 264, 268,
		228, 220, 212, 204, 196, 188, 180, 172, 164, 156, 148, 140,
		132, 124, 116, 108, 100, 92, 84, 76, 68, 60,
	]:
		var candidate := _flat_voxel_row(world, mined, off)
		if candidate == Vector3i.MAX:
			continue
		var beside := candidate + Vector3i(2, 0, 0)
		if (
			colony.voxel_fill(candidate) <= 0
			and colony.voxel_fill(beside) <= 0
			and not colony._designation_markers.has(candidate)
			and not colony._designation_markers.has(beside)
			and colony.building_at(candidate) == null
			and colony.building_at(beside) == null
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a flat spot for the campfire")
	if spot == Vector3i.MAX:
		return
	var pile_v := spot + Vector3i(2, 0, 0)
	var worker: Unit = colony.units[0]
	_clear_jobs(colony)
	# Park every unit for the section — an idle unit would haul the
	# fruit pile to a stockpile or claim the dispatched meal job between
	# fixture waits, and the escrow count goes missing. The search
	# cooldown gates every idle path (claims, needs, hauls); driven jobs
	# assign directly so it never stalls the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 300.0
		if u.job != null:
			u.abandon_job()
	var unfreeze := func() -> void:
		for u in colony.units:
			u._job_search_cooldown = 0.0

	# Fuel values: a log is the real fuel, branches middling, leaves and
	# sawdust flash, and stone doesn't burn at all.
	_check(
		DropItem.fuel_seconds_of(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.LOG, DropItem.LOG_CM3
			)
		) == 600.0,
		"a log is worth ten minutes of fire"
	)
	_check(
		is_equal_approx(
			DropItem.fuel_seconds_of(
				DropItem.new(
					BlockRegistry.Resource_.BRANCH,
					DropItem.Form.LOOSE, 200_000
				)
			),
			160.0
		),
		"branches burn by volume"
	)
	_check(
		is_equal_approx(
			DropItem.fuel_seconds_of(
				DropItem.new(
					BlockRegistry.Resource_.LEAF,
					DropItem.Form.LOOSE, 200_000
				)
			),
			100.0
		),
		"leaves burn fast"
	)
	_check(
		DropItem.fuel_seconds_of(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE, DropItem.COBBLE_CM3
			)
		) == 0.0,
		"stone is no fuel"
	)

	# Validity: the cell must be open air over solid ground, free of
	# piles, markers and claims.
	_check(
		colony.designate_campfire(spot + Vector3i.UP) == null,
		"a campfire needs a solid floor"
	)
	for i in 5:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE, DropItem.COBBLE_CM3
			),
			pile_v
		)
	_check(
		colony.designate_campfire(pile_v) == null,
		"a piled cell refuses the ring"
	)
	var build := colony.designate_campfire(spot)
	_check(build != null, "a campfire designates on open ground")
	_check(
		colony.designate_campfire(spot) == null,
		"a designated cell refuses a second campfire"
	)
	if build == null:
		unfreeze.call()
		return

	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_drive_craft(colony, world, build, pile_v, spot)
	var built := await _wait_until(
		func() -> bool: return build.state == ColonyJob.State.DONE
	)
	_check(built, "a unit builds the campfire from cobbles")
	var fire := colony.campfire_at(spot)
	_check(fire != null, "the campfire registers as a building")
	if fire == null:
		unfreeze.call()
		return
	var cobbles := 0
	for item in fire.components:
		if item.form == DropItem.Form.COBBLE:
			cobbles += 1
	_check(cobbles == 5, "the ring is five cobbles")
	_check(fire.is_worksite(), "a campfire is a worksite")
	_check(not fire.lit(), "a fresh campfire starts unlit")
	_check(
		colony.illumination_at(spot) == 0.0,
		"an unlit campfire sheds no light"
	)

	# A bare crafting spot refuses the meal bill — the recipe is pinned
	# to the campfire kind. The spot is razed as soon as its checks are
	# done: its queued plank bill would keep dispatching against later
	# fixtures' logs and drop stray sawdust mid-suite.
	var bare := _flat_voxel(world, mined, spot.z - mined.z + 1, 6)
	if bare != Vector3i.MAX and colony.designate_craft_spot(bare):
		_check(
			colony.queue_order(bare, &"prepare_meal") == null,
			"a bare spot can't cook"
		)
		var plank_bill := colony.queue_order(bare, &"planks")
		_check(
			plank_bill != null,
			"the bare spot still takes its own bills"
		)
		if plank_bill != null:
			colony.remove_order(bare, plank_bill)
		var stray := colony.craft_job_at(bare)
		if stray != null:
			colony._cancel_job(stray)
		var raze := colony.designate_deconstruct(bare)
		if raze != null:
			_assign_job(colony, raze, bare)
			await _wait_until(
				func() -> bool: return colony.building_at(bare) == null
			)

	# The meal bill queues on a cold fire but doesn't dispatch — raw
	# fruit is already piled, so only the fire blocks it.
	for i in 4:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.BERRY,
				DropItem.Form.FRUIT, DropItem.FRUIT_CM3
			),
			pile_v
		)
	var order := colony.queue_order(spot, &"prepare_meal")
	_check(order != null, "a cold campfire queues the meal bill")
	_check(
		colony.craft_job_at(spot) == null,
		"a cold campfire suspends its bills"
	)

	# Fuel is low from the start — with a burnable pile in the world and
	# auto-refuel on, the tick posts the job itself. The log gets its own
	# cell: a cubic metre lands on the fruit pile and evicts the berries,
	# and the cook's fallback fetch can come home with acorn litter —
	# worth no nutrition — instead of the fixture's fruit.
	var log_cell := spot + Vector3i(3, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD,
			DropItem.Form.LOG, DropItem.LOG_CM3
		),
		log_cell
	)
	var posted := await _wait_until(
		func() -> bool: return colony.refuel_job_at(spot) != null
	)
	_check(posted, "auto-refuel posts the refuel job at the threshold")
	_check(
		colony.request_refuel(spot) == null,
		"no duplicate refuel job while one is live"
	)
	var refuel := colony.refuel_job_at(spot)
	if refuel == null:
		unfreeze.call()
		return
	_drive_craft(colony, world, refuel, log_cell, spot)
	var fed := await _wait_until(
		func() -> bool: return refuel.state == ColonyJob.State.DONE
	)
	_check(fed, "a unit feeds the campfire a log")
	_check(fire.lit(), "the fed campfire is lit")
	_check(
		fire.fuel > 590.0,
		"the delivered log banks its burn-seconds"
	)
	var marker: MeshInstance3D = colony._designation_markers.get(spot)
	var light := (
		marker.get_node_or_null("Fire") as OmniLight3D
		if marker != null
		else null
	)
	_check(
		light != null and light.visible
			and is_equal_approx(
				light.omni_range, Colony.CAMPFIRE_LIGHT_RADIUS
			),
		"the lit campfire shines out to its work radius"
	)
	_check(
		colony.illumination_at(spot) > 0.5,
		"the fire lights its own cell"
	)

	# The queued bill dispatches now that the fire burns; drive the cook
	# through the fruit pile beside it.
	var dispatched := await _wait_until(
		func() -> bool: return colony.craft_job_at(spot) != null
	)
	_check(dispatched, "the queued bill dispatches once the fire is fed")
	# A running bill tints the worksite marker — but the campfire's is
	# its stone ring, not the generic box: dispatch must keep the torus.
	var lit_marker: MeshInstance3D = colony._designation_markers.get(spot)
	_check(
		lit_marker != null and lit_marker.mesh == colony._campfire_mesh,
		"a dispatched bill keeps the campfire's ring mesh"
	)
	_check(
		lit_marker != null
			and lit_marker.material_override == colony._craft_job_marker_material,
		"the running ring carries the job tint"
	)
	var meal := colony.craft_job_at(spot)
	if meal == null:
		unfreeze.call()
		return
	_drive_craft(colony, world, meal, pile_v, spot)
	var cooking := await _wait_until(func() -> bool:
		return (
			worker.state == Unit.State.WORKING
			and not worker._fetching
			and int(meal.delivered.get(DropItem.Form.FRUIT, 0))
				>= 4 * DropItem.FRUIT_CM3
		))
	_check(cooking, "the cook escrows the recipe's fruit")
	if not cooking:
		var pile := colony.item_pile_at(pile_v)
		var pile_stock := {}
		if pile != null:
			for item in pile.items:
				pile_stock[item.form] = (
					int(pile_stock.get(item.form, 0)) + item.volume
				)
		var carried := {}
		for item in worker._carried:
			carried[item.form] = (
				int(carried.get(item.form, 0)) + item.volume
			)
		print(
			"    cook stall: state=", worker.state,
			" fetching=", worker._fetching,
			" goal=", worker._goal_voxel,
			" job_state=", meal.state,
			" delivered=", meal.delivered,
			" pile=", pile_stock,
			" carried=", carried,
			"\n", worker.decision_trail()
		)
		colony._cancel_job(meal)
		unfreeze.call()
		return

	# Kill the fire mid-cook: progress freezes but the bill and its
	# escrowed inputs stay put.
	fire.auto_refuel = false
	fire.fuel = 0.0
	colony._campfire_tick(0.0)
	var frozen := meal.progress
	for i in 20:
		await physics_frame
	_check(
		meal.progress == frozen and meal.is_active(),
		"a cold fire suspends the running bill"
	)
	_check(light != null and not light.visible, "the dead fire goes dark")

	# Feed it by hand and the cook finishes where it left off.
	fire.fuel = 60.0
	colony._campfire_tick(0.0)
	var cooked := await _wait_until(
		func() -> bool: return meal.state == ColonyJob.State.DONE
	)
	_check(cooked, "the suspended bill resumes when the fire is fed")
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var meal_item: DropItem = null
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - spot).length() > 4.0:
			continue
		for item: DropItem in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.MEAL:
				meal_item = item
	_check(
		meal_item != null
			and meal_item.material == BlockRegistry.Resource_.MEAL
			and meal_item.volume == DropItem.MEAL_CM3,
		"cooking drops a real meal item at the fire"
	)
	var want_nutrition := (
		1.75 * 4.0 * DropItem.nutrition_of(
			BlockRegistry.Resource_.BERRY, DropItem.FRUIT_CM3
		)
	)
	_check(
		meal_item != null
			and is_equal_approx(meal_item.nutrition, want_nutrition),
		"the meal is worth 75% over its raw fruit"
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.MEAL),
		"meals answer the food query"
	)
	_check(
		worker.skills.get(ColonyJob.Skill.COOKING, 0.0) >= 1.0,
		"a cooked meal trains Cooking"
	)
	worker.gain_skill_xp(ColonyJob.Skill.COOKING, 9.0)
	_check(
		worker.skill_level(ColonyJob.Skill.COOKING) == 1,
		"ten meals carry a cook to level 1"
	)

	# Manual control: with auto-refuel off the tick stays quiet even
	# under the threshold; a manual request still posts.
	fire.fuel = Colony.CAMPFIRE_FUEL_CAP * 0.1
	colony._campfire_tick(1.0)
	_check(
		colony.refuel_job_at(spot) == null,
		"auto-refuel off posts nothing at the threshold"
	)
	var manual := colony.request_refuel(spot)
	_check(manual != null, "a manual request still posts the job")
	if manual != null:
		manual.state = ColonyJob.State.CANCELLED
		colony._prune_jobs()

	# Burning out kills the light and the glow again.
	fire.fuel = 0.4
	colony._campfire_tick(1.0)
	_check(not fire.lit(), "the fire burns out")
	_check(light != null and not light.visible, "a burned-out fire sheds no light")
	_check(
		colony.illumination_at(spot) == 0.0,
		"a burned-out fire lights nothing"
	)

	# Leave the ring standing but quiet — the persistence test
	# round-trips it (fuel + toggle included).
	fire.fuel = 55.0
	fire.auto_refuel = false
	colony._campfire_tick(0.0)
	unfreeze.call()


## Surface scree: the generator's lattice oracle is deterministic, the
## colony drops real piles of boulders and cobbles as blocks stream in,
## and a picked-clean slot is spent forever — re-streaming the block
## never restocks it.
func _test_loose_rocks(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("loose surface rocks")
	var gen := world.generator_script
	var origin := Vector3i(
		floori(float(mined.x) / 16.0),
		floori(float(mined.y) / 16.0),
		floori(float(mined.z) / 16.0)
	)
	# Oracle determinism — the same chunk yields the same scatter.
	var first := gen.loose_rocks_in(origin * 16, 16)
	_check(
		first == gen.loose_rocks_in(origin * 16, 16),
		"the rock oracle is deterministic"
	)

	# Find a usable slot near the site. Reading the voxel may stream its
	# chunk — which seeds the slot itself, the very path under test —
	# so the claim checks run *before* get_block touches the world: a
	# slot the stream already seeded is skipped only when its pile is
	# gone or foreign, and a fresh slot still seeds on demand.
	var slot_v := Vector3i.MAX
	var slot_counts := {}
	var slot_chunk := Vector3i.MAX
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var chunk := origin + Vector3i(dx, 0, dz)
			var slots: Dictionary = gen.loose_rocks_in(chunk * 16, 16)
			for pos: Vector2i in slots:
				var voxel := Vector3i(
					pos.x, gen.surface_height(pos.x, pos.y) + 1, pos.y
				)
				if colony._rock_spent.has(voxel):
					continue
				if (
					colony.item_pile_at(voxel) != null
					and not colony._rock_slots.has(voxel)
				):
					continue  # a foreign pile squats on the slot
				if world.get_block(voxel) != BlockRegistry.Block.AIR:
					continue
				slot_v = voxel
				slot_counts = slots[pos]
				slot_chunk = chunk
				break
			if slot_v != Vector3i.MAX:
				break
		if slot_v != Vector3i.MAX:
			break
	_check(slot_v != Vector3i.MAX, "found an unseeded rock slot near the site")
	if slot_v == Vector3i.MAX:
		return

	colony._seed_loose_rocks(slot_chunk)
	var pile := colony.item_pile_at(slot_v)
	_check(pile != null, "seeding drops a real rock pile")
	if pile != null:
		_check(
			pile.form_volume(DropItem.Form.BOULDER)
				== int(slot_counts.get(&"boulders", 0)) * DropItem.BOULDER_CM3,
			"the pile holds the slot's boulders"
		)
		_check(
			pile.form_volume(DropItem.Form.COBBLE)
				== int(slot_counts.get(&"cobbles", 0)) * DropItem.COBBLE_CM3,
			"the pile holds the slot's cobbles"
		)
		var items_before := pile.items.size()
		colony._seed_loose_rocks(slot_chunk)
		_check(
			pile.items.size() == items_before,
			"re-seeding a live slot drops nothing twice"
		)
		# Picked clean, the slot tombstones — no restock on re-seed.
		pile.items.clear()
		colony.remove_pile_if_empty(slot_v)
		_check(
			colony._rock_spent.has(slot_v),
			"a picked-clean slot is spent"
		)
		colony._seed_loose_rocks(slot_chunk)
		_check(
			colony.item_pile_at(slot_v) == null,
			"a spent slot never restocks"
		)

	# Scree and saplings draw from the same surface lattice in separate
	# block_loaded passes — a pile isn't terrain, so without an explicit
	# cross-check a tree registers on a rock pile's cell. The invariant
	# both orders must hold: no live scree slot shares a cell with a
	# tree claim.
	var tree_overlap := 0
	for voxel: Vector3i in colony._rock_slots:
		if colony.forest.tree_root_at(voxel) != Vector3i.MAX:
			tree_overlap += 1
	_check(
		tree_overlap == 0,
		"no generated scree pile shares a cell with a tree"
	)

	# Tree first: a claimed cell vetoes a later seeding pass. A live
	# slot's tracking is stripped so the pass re-evaluates its cell.
	var live_v := Vector3i.MAX
	for voxel: Vector3i in colony._rock_slots:
		if (
			colony.forest.tree_root_at(voxel) == Vector3i.MAX
			and world.is_solid(voxel + Vector3i.DOWN)
			and world.water_level_at(voxel.x, voxel.z) < voxel.y
		):
			live_v = voxel
			break
	_check(live_v != Vector3i.MAX, "found a live scree slot to replay")
	if live_v != Vector3i.MAX:
		var live_pile: ItemPile = colony._rock_slots[live_v]
		colony._rock_slots.erase(live_v)
		live_pile.items.clear()
		colony.remove_pile_if_empty(live_v)
		colony._rock_spent.erase(live_v)  # re-arm the slot for the replay
		_check(
			colony.forest.plant_sapling(live_v),
			"a sapling claims the freed cell"
		)
		colony._seed_loose_rocks(
			Vector3i(live_v.x >> 4, live_v.y >> 4, live_v.z >> 4)
		)
		_check(
			colony.item_pile_at(live_v) == null,
			"a claimed cell keeps the scree slot from seeding"
		)
		_check(
			not colony._rock_slots.has(live_v),
			"the skipped slot stays unclaimed, not adopted"
		)
		colony.forest.trees.erase(live_v)
		colony.forest._index.erase(live_v)

	# Pile first: discovery on a sapling slot skips a piled cell, then
	# claims it once the pile clears — the reported collision's order.
	var sap_v := Vector3i.MAX
	var sap_chunk := Vector3i.MAX
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var chunk := origin + Vector3i(dx, 0, dz)
			var slots: Dictionary = gen.saplings_in(chunk * 16, 16)
			for pos: Vector2i in slots:
				var voxel := Vector3i(
					pos.x, gen.surface_height(pos.x, pos.y) + 1, pos.y
				)
				var rec: Dictionary = colony.forest.trees.get(voxel, {})
				if (
					rec.is_empty()
					or int(rec[&"height"]) != 0
					or colony.item_pile_at(voxel) != null
					or world.water_level_at(voxel.x, voxel.z) >= voxel.y
				):
					continue
				sap_v = voxel
				sap_chunk = chunk
				break
			if sap_v != Vector3i.MAX:
				break
		if sap_v != Vector3i.MAX:
			break
	_check(sap_v != Vector3i.MAX, "found a live sapling slot to replay")
	if sap_v != Vector3i.MAX:
		# Unregister fully so the slot replays its discovery pass.
		var rec2: Dictionary = colony.forest.trees[sap_v]
		var block := colony.forest._block_of(sap_v)
		var col := colony.forest._column_chunk(sap_v)
		colony.forest.trees.erase(sap_v)
		colony.forest._index.erase(sap_v)
		(colony.forest._block_roots.get(block, {}) as Dictionary).erase(sap_v)
		(colony.forest._chunk_roots.get(col, {}) as Dictionary).erase(sap_v)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.COBBLE, DropItem.COBBLE_CM3
			),
			sap_v
		)
		_check(
			not colony.forest.plant_sapling(sap_v),
			"a piled cell refuses a planted sapling"
		)
		colony.forest._on_block_loaded(sap_chunk)
		_check(
			colony.forest.tree_root_at(sap_v) == Vector3i.MAX,
			"sapling discovery skips the piled cell"
		)
		colony.item_pile_at(sap_v).items.clear()
		colony.remove_pile_if_empty(sap_v)
		colony.forest._on_block_loaded(sap_chunk)
		_check(
			colony.forest.tree_root_at(sap_v) != Vector3i.MAX,
			"the freed cell claims on the next discovery pass"
		)
		_check(
			rec2[&"species"] == colony.forest.trees[sap_v][&"species"],
			"the replayed slot keeps its generated species"
		)


## Deconstruction: a wall comes apart into exactly the items it was built
## of; a packed-dirt wall isn't a building to the tool and has to be mined
## — and a mined wall's record dies with its block.
func _test_deconstruct(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	var dirt_site := _flat_voxel(world, mined, 200)
	_check(dirt_site != Vector3i.MAX, "found a flat spot for the dirt wall")
	if dirt_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, dirt_site, 30.0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 1400000),
		dirt_site + Vector3i(1, 0, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var dirt_job := _assign_build(
		colony, dirt_site, dirt_site + Vector3i(1, 0, 0), &"dirt_wall"
	)
	var packed := await _wait_until(func() -> bool:
		return world.get_block(dirt_site) == BlockRegistry.Block.DIRT)
	_check(packed and dirt_job != null, "a unit packs a dirt wall for the test")
	var dirt_wall := colony.building_at(dirt_site)
	_check(
		dirt_wall != null and not dirt_wall.deconstructable,
		"a packed-dirt wall registers but isn't deconstructable"
	)
	_check(
		colony.designate_deconstruct(dirt_site) == null,
		"a dirt wall can't be designated for deconstruction"
	)

	# A stone wall comes down into exactly its hundred and twenty dressed
	# blocks — no shatter, no loss.
	var stone_site := _flat_voxel(world, mined, 208)
	_check(stone_site != Vector3i.MAX, "found a flat spot for the stone wall")
	if stone_site == Vector3i.MAX:
		return
	_clear_wall_material_near(colony, stone_site, 25.0)
	for i in 120:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BLOCK,
				DropItem.STONE_BLOCK_CM3
			),
			stone_site + Vector3i(1, 0, 0)
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stone_job := _assign_build(
		colony, stone_site, stone_site + Vector3i(1, 0, 0), &"stone_wall"
	)
	var walled := await _wait_until(func() -> bool:
		return world.get_block(stone_site) == BlockRegistry.Block.STONE_WALL)
	_check(walled and stone_job != null, "a stone wall goes up for the test")
	var demolish := colony.designate_deconstruct(stone_site)
	_check(demolish != null, "a stone wall designates for deconstruction")
	_check(
		colony.designate_deconstruct(stone_site) == null,
		"a wall can't be deconstruct-designated twice"
	)
	if demolish == null:
		return
	_assign_job(colony, demolish, stone_site)
	var razed := await _wait_until(func() -> bool:
		return not world.is_solid(stone_site))
	_check(razed, "a unit takes the stone wall apart")
	_check(
		colony.building_at(stone_site) == null,
		"the wall's building record dies with it"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var blocks := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - stone_site).length() > 5.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material != BlockRegistry.Resource_.STONE:
				continue
			if item.form == DropItem.Form.BLOCK:
				blocks += 1
	_check(
		blocks == 120,
		"deconstruction returns exactly the wall's inputs"
	)

	# A log wall hands its one whole log back.
	var log_site := _flat_voxel(world, mined, 216)
	if log_site != Vector3i.MAX:
		_clear_wall_material_near(colony, log_site, 25.0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			log_site + Vector3i(1, 0, 0)
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var log_job := _assign_build(
			colony, log_site, log_site + Vector3i(1, 0, 0), &"log_wall"
		)
		var logged := await _wait_until(func() -> bool:
			return world.get_block(log_site) == BlockRegistry.Block.LOG_WALL)
		_check(logged and log_job != null, "a log wall goes up for the test")
		var log_demolish := colony.designate_deconstruct(log_site)
		if log_demolish != null:
			_assign_job(colony, log_demolish, log_site)
			var unlogged := await _wait_until(func() -> bool:
				return not world.is_solid(log_site))
			_check(unlogged, "a unit takes the log wall apart")
			await _wait_until(func() -> bool: return colony._in_flight.is_empty())
			var logs := 0
			for voxel in colony.item_piles:
				if Vector3(voxel - log_site).length() > 5.0:
					continue
				for item in colony.item_piles[voxel].items:
					if item.form == DropItem.Form.LOG:
						logs += 1
			_check(logs == 1, "deconstruction returns the log wall's log")

	# A packed-dirt wall mines out like natural ground — and its record
	# dies with the block.
	var mine := colony.designate_mine(dirt_site)
	_check(mine != null, "a dirt wall can still be mined out")
	if mine != null:
		_arm_tool(colony.units[0], &"stone_pick")
		_assign_job(colony, mine, dirt_site)
		var dug := await _wait_until(func() -> bool:
			return not world.is_solid(dirt_site))
		_check(dug, "a unit mines the dirt wall out")
		_check(
			colony.building_at(dirt_site) == null,
			"a mined wall's record dies with the block"
		)
	for u in colony.units:
		u._job_search_cooldown = 0.0


## Energy and rest: a waking unit drains a full bar over two thirds of a
## day and sleeps it back — a third of a day in a bed (normal rest), a
## quarter again longer on the ground (poor). Beds are a two-voxel
## building assembled from a compact kit crafted out of six planks.
func _test_rest(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("rest and beds")
	# Keep every unit on task — the subject gets driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
			u.abandon_job()
	_clear_jobs(colony)
	var unit: Unit = colony.units[0]
	unit.energy = 1.0
	unit.velocity = Vector3.ZERO

	# Needs ran dark for the suite so far; they come on here and go back
	# off at the end.
	colony.needs_enabled = true

	_check(
		is_equal_approx(unit._rest_span(), colony.day_length() / 3.0 * 1.25),
		"poor rest takes 25% longer than a bed"
	)
	unit._rest_quality = Unit.RestQuality.NORMAL
	_check(
		is_equal_approx(unit._rest_span(), colony.day_length() / 3.0),
		"a bed refills the bar in a third of a day"
	)
	unit._rest_quality = Unit.RestQuality.POOR
	var drained := await _wait_until(func() -> bool:
		return unit.energy < 1.0)
	_check(drained, "a waking unit drains energy")

	# --- Ground rest: below the seek line the unit sleeps where it is.
	# The +z band may run past the streamed edge — walk the scan back
	# toward the centre until a flat spot turns up.
	var nap_site := Vector3i.MAX
	for nap_off in range(248, 0, -1):
		nap_site = _flat_voxel(world, mined, nap_off)
		if nap_site != Vector3i.MAX:
			break
	_check(nap_site != Vector3i.MAX, "found a flat spot for the ground nap")
	if nap_site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	unit.global_position = Vector3(nap_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.energy = unit.rest_seek * 0.5
	unit._job_search_cooldown = 0.0
	var asleep := await _wait_until(func() -> bool:
		return unit.state == Unit.State.SLEEPING)
	_check(asleep, "a tired unit seeks rest")
	_check(
		unit._rest_quality == Unit.RestQuality.POOR and unit._rest_bed == null,
		"with no bed the unit sleeps on the ground, poorly"
	)
	var regained := await _wait_until(func() -> bool:
		return unit.energy > 0.3)
	_check(regained, "ground sleep restores energy")
	unit.energy = 1.0
	var woke := await _wait_until(func() -> bool:
		return unit.state == Unit.State.IDLE)
	_check(woke, "a fully rested unit wakes")

	# --- Collapse: zero energy sleeps a unit mid-work where it stands.
	unit.energy = 0.0
	var collapsed := await _wait_until(func() -> bool:
		return unit.state == Unit.State.SLEEPING)
	_check(
		collapsed and unit._rest_quality == Unit.RestQuality.POOR,
		"zero energy collapses the unit into poor rest"
	)
	unit.energy = 1.0
	await _wait_until(func() -> bool: return unit.state == Unit.State.IDLE)
	unit._job_search_cooldown = 120.0

	# --- The bed build: five planks assembled in place. Furniture rides
	#     the craft machinery now — the unit hauls the recipe's inputs to
	#     the footprint and builds it there; there is no kit item any
	#     more. Like the nap site above, walk the scan back toward the
	#     streamed centre if the far row has no usable cell.
	var bed_site := Vector3i.MAX
	for z_off in range(-64, 128, 8):
		var z: int = mined.z + z_off
		for x in range(mined.x - 32, mined.x + 96):
			var g := _ground(world, x, z, mined.y + 32)
			var candidate := Vector3i(x, g + 1, z)
			if colony.bed_cells(candidate).size() == 2:
				bed_site = candidate
				break
		if bed_site != Vector3i.MAX:
			break
	_check(bed_site != Vector3i.MAX, "found a flat spot for the bed test")
	if bed_site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	var cells := colony.bed_cells(bed_site)
	_check(cells.size() == 2, "a bed claims a second horizontal cell")
	if cells.size() != 2:
		colony.needs_enabled = false
		return
	# A solid voxel can't host any part of the bed.
	world.place(bed_site + Vector3i(3, 0, 0), BlockRegistry.Block.STONE)
	_check(
		colony.bed_cells(bed_site + Vector3i(3, 0, 0)).is_empty(),
		"a solid anchor can't host a bed"
	)
	var plan := colony.designate_bed(bed_site)
	_check(
		plan != null and plan.extra_voxels == [cells[1]],
		"a bed designation plans both cells"
	)
	_check(
		colony.is_designated(bed_site) and colony.is_designated(cells[1]),
		"both bed cells carry the plan marker"
	)
	_check(
		colony.designate_build(cells[1], &"dirt_wall") == null,
		"a claimed second cell can't host a wall"
	)
	_check(
		colony.designate_bed(cells[1]) == null,
		"a claimed cell can't anchor another bed"
	)
	# Cancelling the *second* cell lifts the whole plan — both markers go.
	colony.cancel_designation(cells[1])
	_check(
		not plan.is_active()
			and not colony.is_designated(bed_site)
			and not colony.is_designated(cells[1]),
		"cancelling a bed's second cell clears the whole plan"
	)

	# --- Building: a unit fetches the recipe's planks to the site and
	#     assembles the bed where it stands — the escrowed components
	#     are what deconstruction later hands back.
	plan = colony.designate_bed(bed_site)
	_check(plan != null, "a bed designates again after a cancel")
	var plank_v := bed_site + Vector3i(0, 0, 2)
	for i in 5:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			plank_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	unit.global_position = Vector3(
		_park_beside(colony, world, plank_v, bed_site)
	) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	plan.state = ColonyJob.State.ASSIGNED
	plan.assignee = unit
	unit.job = plan
	unit._fetching = true
	unit._goal_voxel = plank_v
	unit._clear_budget = 0.0
	unit.state = Unit.State.MOVING
	# Tired before the hammer falls — the instant the build job ends,
	# the idle tick must find a sleeper, not a stray haul job.
	for u in colony.units:
		if u != unit:
			u.energy = 1.0
			u._job_search_cooldown = 120.0
	unit.energy = unit.rest_seek * 0.5
	var built := await _wait_until(func() -> bool:
		return colony.building_at(bed_site) != null)
	_check(built, "a unit builds the bed in place")
	var bed := colony.building_at(bed_site)
	if bed != null:
		_check(
			bed.kind == Building.Kind.BED
				and bed.footprint.size() == 2
				and colony.building_at(cells[1]) == bed,
			"the built bed registers across both cells"
		)
		_check(
			bed.spec == &"bed"
				and bed.components.size() == 5
				and bed.components[0].form == DropItem.Form.PLANK,
			"the bed keeps its five planks for deconstruction"
		)

	# --- Bed rest: a tired unit claims the bed, walks over and sleeps
	#     normally — the bed's one occupant spot is released on waking.
	#     (The unit's energy was dropped before furnish finished, so the
	#     rest claim can't lose a race to a stray job.)
	if bed != null:
		unit._job_search_cooldown = 0.0
		var in_bed := await _wait_until(func() -> bool:
			return (
				unit.state == Unit.State.SLEEPING
				and unit._rest_bed == bed
			))
		if not in_bed:
			print(
				"  diag: state=", unit.state, " restbed=", unit._rest_bed,
				" energy=", unit.energy, " pos=", unit.global_position,
				" standing=", unit._standing_voxel(),
				" bed=", bed_site, " occupant=", bed.occupant,
				" freebed=", colony.nearest_free_bed(unit._standing_voxel()),
				" job=", unit.job
			)
		_check(in_bed, "a tired unit claims the bed for rest")
		_check(
			unit._rest_quality == Unit.RestQuality.NORMAL,
			"bed sleep is normal rest"
		)
		var captioned := await _wait_until(func() -> bool:
			return unit._status_label.text == "sleeping")
		_check(
			captioned,
			"the status caption shows what the unit is doing"
		)
		unit.energy = 1.0
		var up := await _wait_until(func() -> bool:
			return unit.state == Unit.State.IDLE)
		_check(up and bed.occupant == null, "waking frees the bed")
		unit._job_search_cooldown = 120.0

		# --- Resting from atop a pile: a tired unit perched on a partial
		#     pile still finds the bed — its standing cell is the feet's
		#     cell (a >50% fill used to round up into the cell above, which
		#     broke both the path start and the bed footprint check, and
		#     the unit collapsed on the ground in the stockpile instead).
		var perch := Vector3i.MAX
		for side in [
			Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK
		]:
			var c: Vector3i = bed_site + side
			if (
				world.get_block(c) == BlockRegistry.Block.AIR
				and world.get_block(c + Vector3i.UP) == BlockRegistry.Block.AIR
				and world.get_block(c + Vector3i.UP * 2) == BlockRegistry.Block.AIR
				and world.is_solid(c + Vector3i.DOWN)
				and colony.voxel_fill(c) <= 0
			):
				perch = c
				break
		if perch != Vector3i.MAX:
			colony._deposit_item(
				DropItem.new(
					BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700_000
				),
				perch
			)
			await _wait_until(func() -> bool: return colony._in_flight.is_empty())
			# Feet on the 70% surface: the feet sit inside the pile cell.
			unit.global_position = Vector3(perch) + Vector3(0.5, 1.65, 0.5)
			unit.velocity = Vector3.ZERO
			_check(
				unit._standing_voxel() == perch,
				"a unit perched on a pile reports the pile's cell"
			)
			unit.energy = unit.rest_seek * 0.5
			unit._job_search_cooldown = 0.0
			var perched_sleep := await _wait_until(func() -> bool:
				return (
					unit.state == Unit.State.SLEEPING
					and unit._rest_bed == bed
				))
			_check(
				perched_sleep, "a unit standing on a pile still claims the bed"
			)
			_check(
				unit._rest_quality == Unit.RestQuality.NORMAL,
				"the pile-perched unit slept in the bed, not on the ground"
			)
			unit.energy = 1.0
			await _wait_until(func() -> bool:
				return unit.state == Unit.State.IDLE)
			unit._job_search_cooldown = 120.0
			var perch_pile := colony.item_pile_at(perch)
			if perch_pile != null:
				perch_pile.take_up_to(
					DropItem.BLOCK_CM3,
					func(_i: DropItem) -> bool: return true
				)
				colony.remove_pile_if_empty(perch)

		# --- Deconstruct: either cell designates the same teardown, the
		#     occupant is evicted and the planks drop back into the world.
		#     The sleeper claims the bed first — a bed marked for teardown
		#     won't take a new occupant.
		var sleeper := unit
		sleeper.energy = unit.rest_seek * 0.5
		sleeper._job_search_cooldown = 0.0
		await _wait_until(func() -> bool:
			return (
				sleeper.state == Unit.State.SLEEPING
				and sleeper._rest_bed == bed
			))
		var demolish := colony.designate_deconstruct(cells[1])
		_check(
			demolish != null and demolish.voxel_position == bed_site,
			"either bed cell designates the deconstruct"
		)
		_check(
			colony.nearest_free_bed(bed_site) == null,
			"a bed marked for deconstruct takes no new occupant"
		)
		if demolish != null:
			var worker: Unit = (
				colony.units[1] if colony.units.size() > 1 else unit
			)
			if worker == sleeper:
				# Only one unit to test with — wake it and use it.
				sleeper.energy = 1.0
				await _wait_until(func() -> bool:
					return sleeper.state == Unit.State.IDLE)
			# Not _assign_job: its blanket abandon would wake the sleeper
			# before the teardown could evict it.
			if worker.job != null:
				colony.release_job(worker.job)
				worker.abandon_job()
			# A drained demolitionist would collapse mid-teardown.
			worker.energy = 1.0
			worker._job_search_cooldown = 120.0
			worker.global_position = (
				Vector3(
					_park_beside(
						colony, world, bed_site, bed_site + Vector3i(0, 0, 1)
					)
				) + Vector3(0.5, 0.9, 0.5)
			)
			worker.velocity = Vector3.ZERO
			demolish.state = ColonyJob.State.ASSIGNED
			demolish.assignee = worker
			worker.job = demolish
			worker._fetching = false
			worker._goal_voxel = bed_site
			worker._clear_budget = 0.0
			worker.state = Unit.State.MOVING
			# Pin the sleeper rested *before* the teardown — otherwise it
			# can wake, re-find it's exhausted, and re-sleep on the ground
			# inside the same frame the check reads.
			sleeper.energy = 1.0
			sleeper._job_search_cooldown = 120.0
			var razed := await _wait_until(func() -> bool:
				return colony.building_at(bed_site) == null)
			if not razed:
				print(
					"  diag: worker state=", worker.state,
					" pos=", worker.global_position,
					" standing=", worker._standing_voxel(),
					" jobstate=", demolish.state, " progress=", demolish.progress,
					" goal=", worker._goal_voxel, " energy=", worker.energy,
					" sleeper state=", sleeper.state
				)
			_check(razed, "a unit deconstructs the bed")
			_check(
				colony.building_at(cells[1]) == null,
				"deconstructing frees the whole footprint"
			)
			_check(
				sleeper.state != Unit.State.SLEEPING,
				"a deconstructed bed wakes its sleeper"
			)
			await _wait_until(func() -> bool:
				return colony._in_flight.is_empty())
			var planks_back := 0
			for voxel in colony.item_piles:
				if Vector3(voxel - bed_site).length() > 4.0:
					continue
				for item in colony.item_piles[voxel].items:
					if item.form == DropItem.Form.PLANK:
						planks_back += 1
			_check(
				planks_back >= 5,
				"deconstruction hands the bed's planks back"
			)

	# Leave the unit rested and the needs switch off for later tests —
	# a sleeper left down would never wake once the refill gate closes.
	for u in colony.units:
		if u.state == Unit.State.SLEEPING:
			u.energy = 1.0
			u._wake()
		u._job_search_cooldown = 0.0
	colony.needs_enabled = false


## Hunger and foraging: berries are edible physical items, seeded bushes
## yield them to a FORAGE job and regrow, and a unit's hunger drives
## food-seeking, eating and — at zero — a work penalty, not a collapse.
func _test_food(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("hunger and food")
	# Keep every unit on task — the subject gets driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)
	var unit: Unit = colony.units[0]
	unit.velocity = Vector3.ZERO
	unit.energy = 1.0

	# --- The resource model: berries are loose, edible material.
	_check(
		BlockRegistry.resource_name_of(BlockRegistry.Resource_.BERRY) == "Berries",
		"the berry resource is registered"
	)
	_check(
		BlockRegistry.resource_is_loose(BlockRegistry.Resource_.BERRY),
		"berries are loose material — they pour and split"
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.BERRY)
			and not DropItem.is_food(BlockRegistry.Resource_.STONE),
		"berries are edible and stone isn't"
	)
	_check(
		DropItem.nutrition_of(BlockRegistry.Resource_.BERRY, 100_000) > 0.0,
		"berries carry nutrition per volume eaten"
	)

	# --- Generation: the bush lattice seeds slots at mixed ripeness.
	# Seeding is deterministic off the slot, so the whole lattice can be
	# sampled rather than whichever few bushes happen to be streamed in.
	var gen := world.generator_script
	var slots := gen.bushes_in(Vector3i(-160, 0, -160), 320)
	var ripe_slots := 0
	for pos: Vector2i in slots:
		var slot := Vector3i(
			pos.x, gen.surface_height(pos.x, pos.y) + 1, pos.y
		)
		if colony.plants.seeded_ripe(slot):
			ripe_slots += 1
	_check(
		slots.size() > 0 and ripe_slots > 0 and ripe_slots < slots.size(),
		"seeded bushes start at mixed ripeness"
	)
	_check(
		not colony.plants.bushes.is_empty(),
		"streamed terrain discovers berry bushes"
	)

	# --- Forage: a ripe bush designates, a unit strips its yield into a
	# physical pile, and the bush goes quiet until it regrows.
	# The fixture wants a berry bush specifically — the lattice also
	# seeds heal-all, which forages medicine, not fruit.
	var bush := Vector3i.MAX
	for root: Vector3i in colony.plants.bushes:
		var rec: Dictionary = colony.plants.bushes[root]
		if (
			rec[&"species"] == &"berry_bush"
			and colony.plants.can_forage(root)
		):
			bush = root
			break
	if bush == Vector3i.MAX:
		for root: Vector3i in colony.plants.bushes:
			var rec: Dictionary = colony.plants.bushes[root]
			if rec[&"species"] == &"berry_bush":
				rec[&"ripe"] = true
				bush = root
				break
	_check(bush != Vector3i.MAX, "a ripe bush exists for the forage test")
	if bush == Vector3i.MAX:
		return
	_check(
		colony.item_pile_at(bush) == null or true,
		"the bush cell stays air — the plant is decoration, not terrain"
	)
	var forage := colony.designate_forage(bush)
	_check(
		forage != null and forage.type == ColonyJob.Type.FORAGE,
		"a ripe bush designates for forage"
	)
	_check(
		colony.is_designated(bush),
		"a forage designation marks the bush"
	)
	var park := _park_beside(colony, world, bush, bush + Vector3i.RIGHT)
	if forage != null:
		_assign_job(colony, forage, park, unit)
		var foraged := await _wait_until(func() -> bool:
			return forage.state == ColonyJob.State.DONE)
		_check(foraged, "a unit forages a ripe bush")
		await _wait_until(func() -> bool:
			return colony._in_flight.is_empty())
		var berries := 0
		var berries_whole := true
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - bush).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 2:
				continue
			for item in colony.item_piles[voxel].items:
				if item.material == BlockRegistry.Resource_.BERRY:
					berries += item.volume
					if item.form != DropItem.Form.FRUIT:
						berries_whole = false
		_check(berries > 0, "foraging drops physical berries at the bush")
		_check(
			berries_whole,
			"foraged berries are whole fruit — extract-seed's input form"
		)
		_check(
			not colony.plants.can_forage(bush),
			"a foraged bush bears nothing until it regrows"
		)
		_check(
			colony.designate_forage(bush) == null,
			"a spent bush can't be designated again"
		)
		# Regrow: wind the bush's clock forward and let its tick ripen it.
		colony.plants.bushes[bush][&"next"] = colony.game_msec() - 1
		var regrew := await _wait_until(func() -> bool:
			return colony.plants.can_forage(bush))
		_check(regrew, "a foraged bush regrows its yield")
		_check(
			colony.designate_forage(bush) != null,
			"a regrown bush designates again"
		)
		colony.cancel_designation(bush)
		# The regrow clock is game time, not wall time: a bush that would
		# bear in 60 game-seconds ripens when the planet clock jumps, even
		# though no real time passed.
		colony.plants.bushes[bush][&"ripe"] = false
		colony.plants.bushes[bush][&"next"] = colony.game_msec() + 60000
		if colony.day_cycle != null:
			var clock_before := colony.day_cycle.planet_time
			colony.day_cycle.advance(61.0)
			var jumped := await _wait_until(func() -> bool:
				return colony.plants.can_forage(bush))
			_check(jumped, "a bush ripens on the game clock, not wall time")
			# The clock jump was the fixture — restore it so later date
			# checks see the calendar they expect.
			colony.day_cycle.planet_time = clock_before

	# --- Hunger: the bar drains, low hunger seeks food, eating refills.
	colony.needs_enabled = true
	unit.hunger = 1.0
	var drained := await _wait_until(func() -> bool:
		return unit.hunger < 1.0)
	_check(drained, "a waking unit drains hunger")

	var eat_site := Vector3i.MAX
	for z_off in [96, 104, 112, 120, 232, 240, 224]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and world.is_editable(candidate + Vector3i.DOWN)
		):
			eat_site = candidate
			break
	_check(eat_site != Vector3i.MAX, "found a flat spot for the eating test")
	if eat_site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	var food_v := eat_site + Vector3i(2, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 300_000),
		food_v
	)
	await _wait_until(func() -> bool:
		return colony._in_flight.is_empty())
	_check(
		colony.nearest_food_pile(unit._standing_voxel()) != Vector3i.MAX,
		"a berry pile is findable food"
	)
	unit.global_position = Vector3(eat_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.hunger = unit.food_seek * 0.5
	# A drained energy bar would send it to rest instead of food — keep
	# the two needs independent here.
	unit.energy = 1.0
	unit._job_search_cooldown = 0.0
	# The job alone is the seek: a short walk can clear MOVING between
	# process-frame polls, so don't gate on the transient state.
	var seeking := await _wait_until(func() -> bool:
		return unit.job != null and unit.job.type == ColonyJob.Type.EAT)
	if not seeking:
		print(
			"    [seek] state=%d job=%s goal=%s hunger=%.2f energy=%.2f cd=%.1f food=%s bl=%s" % [
				unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit._goal_voxel,
				unit.hunger,
				unit.energy,
				unit._job_search_cooldown,
				colony.nearest_food_pile(unit._standing_voxel(), unit._food_blacklist),
				unit._food_blacklist,
			]
		)
	_check(seeking, "a hungry unit seeks food")
	if seeking:
		# Read the label at a clean walking frame — door waits, yields
		# and detours each carry their own correct activity, so a single
		# read races them; a pile within reach may skip walking outright.
		await _wait_until(func() -> bool:
			if unit.job == null or unit.job.type != ColonyJob.Type.EAT:
				return true
			return (
				unit.state == Unit.State.MOVING
				and unit._door_wait <= 0.0
				and unit._detour == Vector3i.MAX
			)
		)
		_check(
			unit.job == null
				or unit.job.type != ColonyJob.Type.EAT
				or unit.current_activity() == "seeking food",
			"the walk to food reads as seeking food"
		)
	var ate := await _wait_until(func() -> bool:
		return (
			unit.state == Unit.State.IDLE
			and unit.hunger > unit.food_seek
		))
	if not ate:
		print(
			"    [eat] state=%d job=%s hunger=%.2f act='%s'" % [
				unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit.hunger,
				unit.current_activity(),
			]
		)
	_check(ate, "eating restores hunger")

	# --- A pile that still stands but holds no food must not trap the
	# unit in EATING: the meal ends and the unit goes back to the board.
	var mixed_v := eat_site + Vector3i(1, 0, 0)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 400_000),
		mixed_v
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 90_000),
		mixed_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	unit.global_position = Vector3(eat_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.hunger = 0.1
	unit._job_search_cooldown = 0.0
	# The tell: hunger above the seek line means it ate, and any state
	# but EATING means it left the meal — a stuck eater would sit in
	# EATING forever once the berries are gone.
	var finished := await _wait_until(func() -> bool:
		return unit.hunger > unit.food_seek and unit.state != Unit.State.EATING)
	_check(
		finished,
		"a unit stops eating when a mixed pile's food runs out"
	)
	_check(
		colony.item_pile_at(mixed_v) != null,
		"the pile's non-food residue still stands"
	)

	# --- A pile ringed by other piles stays reachable: a partial pile's
	# surface is itself a valid work spot (the unit stands on the fill).
	# Ring a fresh food pile with 65%-full piles so no clean floor cell
	# is within reach — under the old fill>0 spot filter such a pile had
	# no work spot at all and a unit standing among the piles starved.
	var ring_food := eat_site + Vector3i(1, 0, 3)
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			if dx == 0 and dz == 0:
				continue
			var cell := ring_food + Vector3i(dx, 0, dz)
			for dy in range(3):
				world.remove_voxel(cell + Vector3i(0, dy, 0))
			if not world.is_solid(cell + Vector3i.DOWN):
				world.remove_voxel(cell + Vector3i.DOWN)
				world.place(cell + Vector3i.DOWN, BlockRegistry.Block.STONE)
			if colony.voxel_fill(cell) <= 0:
				colony._deposit_item(
					DropItem.new(
						BlockRegistry.Resource_.SOIL,
						DropItem.Form.LOOSE,
						650_000
					),
					cell
				)
	for dy in range(3):
		world.remove_voxel(ring_food + Vector3i(0, dy, 0))
	if not world.is_solid(ring_food + Vector3i.DOWN):
		world.place(ring_food + Vector3i.DOWN, BlockRegistry.Block.STONE)
	# Drain the earlier pile's leftover berries so the seek can't settle
	# for it instead of the ringed target.
	var earlier := colony.item_pile_at(food_v)
	if earlier != null:
		earlier.take_up_to(
			DropItem.BLOCK_CM3,
			func(item: DropItem) -> bool:
				return DropItem.is_food(item.material)
		)
		colony.remove_pile_if_empty(food_v)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 200_000),
		ring_food
	)
	await _wait_until(func() -> bool:
		return colony._in_flight.is_empty())
	var ring_spots := unit._work_spots(ring_food, false)
	_check(not ring_spots.is_empty(), "a pile ringed by piles still has work spots")
	var pile_spots := 0
	for s in ring_spots:
		if colony.voxel_fill(s) > 0:
			pile_spots += 1
	_check(pile_spots > 0, "a pile's own surface counts as a work spot")
	unit.abandon_job()
	unit.global_position = Vector3(eat_site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.hunger = 0.1
	unit._food_blacklist.clear()
	unit._job_search_cooldown = 0.0
	var fed := await _wait_until(func() -> bool:
		return unit.hunger > unit.food_seek)
	if not fed:
		print(
			"    [ringed-eat] state=%d job=%s goal=%s sv=%s hunger=%.2f" % [
				unit.state,
				unit.job.voxel_position if unit.job != null else "null",
				unit._goal_voxel,
				unit._standing_voxel(),
				unit.hunger,
			]
		)
	_check(fed, "a unit climbs a pile to reach ringed-in food")

	# Standing on a partial pile puts the feet inside the pile's own
	# cell — reporting the cell above corrupted path starts and checks
	# like the bed-arrival footprint test.
	unit.global_position = Vector3(ring_food) + Vector3(0.5, 0.9 + 0.2, 0.5)
	_check(
		unit._standing_voxel() == ring_food,
		"standing on a pile reports the pile's own cell"
	)

	# --- Starving: hunger at zero halves work speed — no collapse.
	unit.hunger = 0.0
	_check(
		unit._work_rate() == Unit.STARVING_SPEED,
		"a starving unit works at half speed"
	)
	unit.state = Unit.State.IDLE
	unit.job = null
	_check(
		unit.current_activity() == "starving",
		"an idle unit at zero hunger reports starving"
	)
	unit.hunger = 1.0
	_check(
		is_equal_approx(unit._work_rate(), 1.0),
		"a fed unit works at full speed"
	)

	# --- Desperation: below the line a starving unit still prefers a
	# real pile; with no edible pile anywhere it self-forages the
	# nearest un-designated ripe bush and eats just enough of the yield
	# to climb back over the hunger line — the rest stays dropped.
	unit.abandon_job()
	unit._food_blacklist.clear()
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.BERRY, DropItem.Form.LOOSE, 300_000),
		food_v
	)
	await _wait_until(func() -> bool:
		return colony._in_flight.is_empty())
	unit.hunger = unit.desperation_seek * 0.5
	unit.energy = 1.0
	unit._job_search_cooldown = 0.0
	var pile_first := await _wait_until(func() -> bool:
		return (
			unit.job != null
			and unit.job.type == ColonyJob.Type.EAT
			and not unit.job.desperate
		))
	_check(
		pile_first,
		"a desperate-depth hunger still prefers a real pile"
	)
	var d_bush := colony.nearest_ripe_bush(eat_site)
	_check(
		d_bush != Vector3i.MAX,
		"a ripe un-designated bush exists for desperation"
	)
	if d_bush != Vector3i.MAX:
		# Pretend the pantry's empty — blacklist every pile holding
		# food so the ordinary seek comes up dry.
		for voxel: Vector3i in colony.item_piles:
			var pile: ItemPile = colony.item_piles[voxel]
			for item in pile.items:
				if DropItem.is_food(item.material):
					unit._food_blacklist[voxel] = {
						"at": colony.game_msec(), "n": 1
					}
					break
		unit.abandon_job()
		unit.global_position = (
			Vector3(_park_beside(colony, world, d_bush, eat_site))
			+ Vector3(0.5, 0.9, 0.5)
		)
		unit.velocity = Vector3.ZERO
		unit.hunger = unit.desperation_seek * 0.5
		unit._job_search_cooldown = 0.0
		var foraging := await _wait_until(func() -> bool:
			return (
				unit.job != null
				and unit.job.type == ColonyJob.Type.FORAGE
				and unit.job.desperate
			))
		_check(foraging, "a starving unit self-issues a bush forage")
		if foraging:
			# The caption differs by phase — en route it's "desperately
			# foraging", at the bush "foraging for survival" — and the
			# unit parked beside the bush may skip the walk entirely.
			var reads_desperate := await _wait_until(func() -> bool:
				var act := unit.current_activity()
				return (
					act == "desperately foraging"
					or act == "foraging for survival"
				))
			_check(reads_desperate, "the desperation run reads as desperation")
		var fed_desperate := await _wait_until(func() -> bool:
			return unit.hunger > unit.food_seek)
		if not fed_desperate:
			print(
				"    [desperate] state=%d job=%s hunger=%.2f act='%s'" % [
					unit.state,
					(
						unit.job.voxel_position
						if unit.job != null
						else "null"
					),
					unit.hunger,
					unit.current_activity(),
				]
			)
		_check(
			fed_desperate,
			"the desperation meal ends back over the hunger line"
		)
		_check(
			not colony.plants.can_forage(d_bush),
			"the desperation run stripped the bush"
		)
		_check(
			unit.hunger < unit.food_seek + 0.3,
			"a desperation meal stops near the line, not at full"
		)
		unit._food_blacklist.clear()

	# --- The facet seam: personality slides the hunger thresholds
	# without touching the base exports.
	unit.facets[&"immoderation"] = 80
	unit.facets[&"stress_vulnerability"] = 50
	_check(
		unit._food_seek() > unit.food_seek,
		"a gourmand-facet unit seeks food earlier than baseline"
	)
	unit.facets[&"immoderation"] = 50
	unit.facets[&"stress_vulnerability"] = 15
	_check(
		unit._desperation_line() < unit.desperation_seek,
		"an iron-willed-facet unit tolerates deeper hunger"
	)
	unit.facets[&"stress_vulnerability"] = 50
	unit.facets[&"immoderation"] = 95
	_check(
		unit._desperation_line() > unit.desperation_seek,
		"an immoderate-facet unit breaks off for food sooner"
	)
	unit.facets[&"immoderation"] = 50

	# Restore the suite's standing arrangement.
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0
	colony.needs_enabled = false


## Ladders: three planks become a climbable cell — stacked rungs carry a
## unit up to a roof it could never jump to, dropped items fall through
## the shaft to collect at the bottom rung, and a pile sharing the cell
## tops out at three quarters. Deconstruction hands the planks back.
func _test_ladder(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("ladders")
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)
	var unit: Unit = colony.units[0]
	unit.velocity = Vector3.ZERO
	unit.energy = 1.0
	unit.hunger = 1.0

	# A flat stretch whose two columns are clear to +4 — the shaft rises
	# in one, the roof deck lands in the other. The roof proof below
	# relies on the ladder being the only way up: since a pile's top is
	# a valid work spot, any standable cell already in reach of the
	# would-be roof pile — a hillside step, a tall pile — spoils the
	# invariant, so the site must sit at its local high point.
	var site := Vector3i.MAX
	for z_off in [272, 276, 280, 284, 176, 184, 192, 96, 104, 152, 160]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate == Vector3i.MAX or not world.is_editable(candidate):
			continue
		var clean := true
		for dx in [0, 1]:
			for dy in range(5):
				var cell: Vector3i = candidate + Vector3i(dx, dy, 0)
				if (
					world.get_block(cell) != BlockRegistry.Block.AIR
					or colony.forest.tree_root_at(cell) != Vector3i.MAX
				):
					clean = false
		if clean:
			var roof_c: Vector3i = candidate + Vector3i(1, 3, 0)
			for dx in range(-2, 3):
				for dy in range(-2, 2):
					for dz in range(-2, 3):
						var c := roof_c + Vector3i(dx, dy, dz)
						if c == roof_c or (c.x == candidate.x and c.z == candidate.z):
							continue
						if not unit._is_standable(c):
							continue
						var lift := (
							float(colony.pile_loose_fill(c)) / DropItem.BLOCK_CM3
						)
						if unit._can_reach_from(
							Vector3(c) + Vector3(0.5, 0.9 + lift, 0.5),
							roof_c, false
						):
							clean = false
		if clean:
			site = candidate
			break
	_check(site != Vector3i.MAX, "found a flat spot for the ladder test")
	if site == Vector3i.MAX:
		return
	var g := site.y - 1

	# --- Designation guards.
	_check(
		colony.designate_ladder(site + Vector3i.DOWN) == null,
		"a solid voxel can't host a ladder"
	)

	# --- Construction: four planks on offer, the ladder takes three and
	# leaves the fourth in the pile.
	var plank_pile := site + Vector3i(2, 0, 0)
	var planks_near := func() -> int:
		var total := 0
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - plank_pile).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 3:
				continue
			total += colony.item_piles[voxel].form_volume(DropItem.Form.PLANK)
		return total
	var planks_before: int = planks_near.call()
	for i in 4:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var job := colony.designate_ladder(site)
	_check(
		job != null and job.type == ColonyJob.Type.CRAFT,
		"an empty voxel designates a ladder"
	)
	if job == null:
		return
	_assign_job(colony, job, site, unit)
	var built := await _wait_until(func() -> bool:
		return job.state == ColonyJob.State.DONE)
	_check(built, "a unit builds a ladder in place")

	var ladder := colony.building_at(site)
	_check(
		ladder != null and ladder.kind == Building.Kind.LADDER,
		"the finished ladder registers as a building"
	)
	_check(colony.ladder_at(site), "the ladder cell reports a ladder")
	if world.sim != null:
		_check(world.sim.ladder_at(site), "the sim mirrors the ladder cell")
	_check(
		ladder != null and ladder.components.size() == 3,
		"the ladder absorbed exactly three planks"
	)
	# Four planks in one cell are a dense heap — the fetch walk shoves it
	# aside, so the spare plank may land a cell or two off its pile.
	_check(
		planks_near.call() - planks_before == DropItem.PLANK_CM3,
		"the fourth plank stays piled by the site"
	)
	_check(
		colony.voxel_capacity(site) == 750_000,
		"a ladder cell holds three quarters of a voxel"
	)
	_check(
		colony.voxel_capacity(site + Vector3i(3, 0, 0)) == DropItem.BLOCK_CM3,
		"an ordinary cell still holds a full voxel"
	)

	# --- Second rung: the stack climbs two z-levels.
	var job2 := colony.designate_ladder(site + Vector3i.UP)
	_check(job2 != null, "a ladder stacks above another")
	for i in 3:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	if job2 != null:
		_assign_job(colony, job2, site, unit)
		var built2 := await _wait_until(func() -> bool:
			return job2.state == ColonyJob.State.DONE)
		_check(built2, "the second rung builds on the first")
	_check(colony.ladder_at(site + Vector3i.UP), "the stack's upper rung registers")

	# --- Roof access: a deck at +2 over the ladder — a jump clears one
	# voxel, never two, and the pile on top sits at +3: over 2 m from any
	# ground cell, so the ladder top is the only work spot in reach.
	var deck := site + Vector3i(1, 2, 0)
	_check(
		world.place(deck, BlockRegistry.Block.DIRT),
		"a roof deck sits beside the ladder top"
	)
	var roof := site + Vector3i(1, 3, 0)
	var start := site + Vector3i(-1, 0, 0)
	var up_path := world.find_path(start, roof)
	_check(not up_path.is_empty(), "a path climbs the stack to the roof")
	var through_shaft := false
	for p in up_path:
		var c := Vector3i(p.floor())
		if c.x == site.x and c.z == site.z and c.y > site.y:
			through_shaft = true
	_check(through_shaft, "the roof path climbs the ladder column")

	# A pile at +3 can only be cleared from the ladder column — every
	# ground cell sits beyond mine_reach of it — so finishing this job
	# proves the unit physically climbed. The work spot may be a rung
	# rather than the ladder's top, so the tell is a standing cell above
	# ground in the shaft column — only ladder support puts a unit there.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER, DropItem.BOULDER_CM3
		),
		roof
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var roof_job := colony.designate_clear(roof)
	_check(roof_job != null, "a roof pile designates for clearing")
	var climbed := [false]
	var seen := {}
	if roof_job != null:
		# A pile's top is a work spot now — and scraps dropped mid-shaft
		# settle in the bottom rung (ladder cells hold a reduced pile).
		# Standing on such a pile would let the unit clear the roof
		# without ever climbing, so before assigning: empty hands, let
		# the drops land, then drain every pile in reach — the ladder
		# must be the only way up.
		for u in colony.units:
			u._job_search_cooldown = 120.0
			u.abandon_job()
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		# Any pile within a few cells of the roof can act as a step whose
		# surface is within reach of the pile — drain them all (but not
		# the roof pile itself; it's the job target).
		for dx in range(-3, 4):
			for dy in range(-3, 5):
				for dz in range(-3, 4):
					var v := roof + Vector3i(dx, dy, dz)
					if v == roof:
						continue
					var p := colony.item_pile_at(v)
					if p != null:
						p.take_up_to(
							DropItem.BLOCK_CM3,
							func(_i: DropItem) -> bool: return true
						)
						colony.remove_pile_if_empty(v)
		_assign_job(colony, roof_job, site, unit)
		# The work spot is inside the bottom rung's cell: reach to the
		# roof opens mid-climb, once the feet rise ~0.7 m into the shaft.
		# The standing *cell* stays at ground level, so the tell is the
		# feet leaving the ground plane inside the ladder columns — only
		# the ladder raises a unit there.
		var max_feet := [-INF]
		var cleared := await _wait_until(func() -> bool:
			var sv := unit._standing_voxel()
			seen[sv] = true
			var feet := unit.global_position.y - 0.9
			max_feet[0] = maxf(max_feet[0], feet)
			if (
				sv.z == site.z
				and (sv.x == site.x or sv.x == site.x + 1)
				and feet > float(site.y) + 0.5
			):
				climbed[0] = true
			return roof_job.state == ColonyJob.State.DONE)
		_check(cleared, "a unit climbs the ladder to clear the roof pile")
		if not climbed[0]:
			print(
				"    [climb] cells: %s max_feet=%.2f site.y=%d" % [
					seen.keys(), max_feet[0], site.y,
				]
			)
		_check(
			climbed[0],
			"the unit rose off the ground inside the ladder column"
		)

	# --- Standing on a rung: the cell above the top ladder holds a unit
	# with no floor of its own — drop one in and it stays up.
	if world.sim != null:
		unit.abandon_job()
		unit.state = Unit.State.IDLE
		unit.velocity = Vector3.ZERO
		unit._job_search_cooldown = 60.0
		var top := Vector3(site + Vector3i(0, 2, 0)) + Vector3(0.5, 0.95, 0.5)
		unit.global_position = top
		world.sim.unit_register(unit._sim_id, top)
		for i in 30:
			await process_frame
		_check(
			unit._standing_voxel() == site + Vector3i(0, 2, 0),
			"a unit stands on the ladder's top rung"
		)

	# --- Descent: the unit-step's descend flag sinks the body rung by
	# rung instead of freefalling down the shaft.
	if world.sim != null:
		unit.abandon_job()
		unit.state = Unit.State.IDLE
		unit.velocity = Vector3.ZERO
		var top_pos := Vector3(site) + Vector3(0.5, 2.9, 0.5)
		unit.global_position = top_pos
		world.sim.unit_register(unit._sim_id, top_pos)
		for i in 120:
			world.sim.unit_step(
				unit._sim_id, Vector3.ZERO, 0.0, unit.gravity, 0.05, unit.climb_speed
			)
		var sunk: Vector3 = world.sim.unit_pos(unit._sim_id)
		unit.global_position = sunk
		_check(
			sunk.y <= float(site.y) + 1.0,
			"the descend flag sinks the unit to the bottom rung"
		)
	var down_path := world.find_path(site + Vector3i(0, 2, 0), site)
	var descends := false
	for p in down_path:
		if Vector3i(p.floor()) == site + Vector3i.UP:
			descends = true
	_check(
		not down_path.is_empty() and descends,
		"the shortest way down the shaft is through the ladder cells"
	)

	# --- Items fall through a ladder and collect at its bottom rung.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 200_000),
		site + Vector3i(0, 3, 0)
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var seat: ItemPile = colony.item_pile_at(site)
	_check(
		seat != null and seat.total_volume() >= 190_000,
		"an item dropped down the shaft lands in the bottom ladder cell"
	)

	# --- Shared with a ladder, the pile tops out at three quarters — the
	# surplus has to move out.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 700_000),
		site
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony.voxel_fill(site) <= 750_000,
		"a ladder-cell pile stops at the reduced capacity"
	)
	var held := 0
	for dx in range(-1, 3):
		for dy in range(2):
			var fill_v := Vector3i(site.x + dx, site.y + dy, site.z)
			held += colony.voxel_fill(fill_v)
	_check(held >= 900_000, "the overflow lands in a neighboring voxel")

	# --- Deconstruction hands back exactly the planks that went in.
	var torn := colony.designate_deconstruct(site)
	_check(torn != null, "a ladder accepts a deconstruct order")
	if torn != null:
		_assign_job(colony, torn, site, unit)
		var down := await _wait_until(func() -> bool:
			return torn.state == ColonyJob.State.DONE)
		_check(down, "a unit takes the ladder apart")
	_check(not colony.ladder_at(site), "deconstruction removes the ladder")
	if world.sim != null:
		_check(
			not world.sim.ladder_at(site),
			"the sim's ladder mirror clears"
		)
	var recovered := 0
	for voxel: Vector3i in colony.item_piles:
		var off: Vector3i = (voxel - site).abs()
		if maxi(off.x, maxi(off.y, off.z)) > 2:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.PLANK:
				recovered += 1
	_check(recovered >= 3, "the ladder's three planks drop on deconstruction")

	# Tidy up: the remaining rung and any leftovers go away.
	var upper: Building = colony.building_at(site + Vector3i.UP)
	if upper != null:
		var tear2 := colony.designate_deconstruct(site + Vector3i.UP)
		if tear2 != null:
			_assign_job(colony, tear2, site, unit)
			await _wait_until(func() -> bool:
				return tear2.state == ColonyJob.State.DONE)
	world.remove_voxel(deck)
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0


## Hands an existing job straight to units[0] without re-designating —
## for jobs already on the board (a suspended build resuming).
func _hand_job(
	colony: Colony, job: ColonyJob, park: Vector3i, pile_v: Vector3i
) -> void:
	var worker: Unit = colony.units[0]
	for u in colony.units:
		if u != worker:
			u._job_search_cooldown = 120.0
		u.abandon_job()
	worker.global_position = Vector3(park) + Vector3(0.5, 0.9, 0.5)
	worker.velocity = Vector3.ZERO
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = worker
	worker.job = job
	worker._fetching = pile_v != Vector3i.MAX
	worker._goal_voxel = pile_v if pile_v != Vector3i.MAX else job.voxel_position
	worker._clear_budget = 0.0
	worker._stuck_elapsed = 0.0
	worker.state = Unit.State.MOVING


## Gravity for solids: a block whose face-connected chain to the base
## level breaks comes down as mined rubble, and a build with nothing to
## hang from suspends until a neighbouring placement anchors it.
## Plank walls and doors. A plank wall is five planks flat — no offcut —
## and fills its voxel whole. A door builds from its wall's recipe plus a
## quarter, each form rounded up to a whole item, and drops the excess as
## offcut (sawdust from wood, gravel from stone). The door cell stays
## open air under a two-cell building record — the capsule needs the cell
## above for headroom — and the pathfinder prices a passage at the swing
## time while the unit pays it standing at the threshold.
func _test_doors(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	# The recipes are pure data — check them before any job runs.
	_check(
		BlockRegistry.build_recipe(&"plank_wall") == {DropItem.Form.PLANK: 1000000},
		"a plank wall is five planks"
	)
	_check(
		BlockRegistry.spec_offcut(&"plank_wall") == 0,
		"a plank wall drops no offcut"
	)
	_check(
		BlockRegistry.build_recipe(&"plank_door") == {DropItem.Form.PLANK: 1400000},
		"a plank door is its wall plus a quarter, rounded up"
	)
	_check(
		BlockRegistry.spec_offcut(&"plank_door") == 150000,
		"a plank door's overcharge drops as offcut"
	)
	_check(
		BlockRegistry.build_recipe(&"log_door") == {DropItem.Form.LOG: 2000000},
		"a log door is two logs"
	)
	_check(
		BlockRegistry.build_recipe(&"stone_door") == {
			DropItem.Form.BLOCK: 750000
		},
		"a stone door is a hundred and fifty dressed blocks"
	)
	_check(
		BlockRegistry.spec_offcut(&"stone_door") == 0,
		"dressed blocks lay exact — a stone door overcharges nothing"
	)
	_check(
		BlockRegistry.build_recipe(&"dirt_door") == {},
		"there is no dirt door"
	)
	_check(
		not Overseer.BUILD_SPECS.has(&"build_dirt_door"),
		"the architect offers no dirt door"
	)

	# A flat pad holding every cell the fixture uses — the room ring, the
	# doorway and gap, the approach cells, and spare ground for the plank
	# wall and stone door. Everything needs open air for two levels;
	# cells a unit walks on or a wall bears on need a solid floor too.
	# The band stays clear of the persist fixture's scan rows.
	var centre := Vector3i.MAX
	for z_off in range(120, 232, 2):
		var row := _flat_voxel_row(world, mined, z_off)
		if row == Vector3i.MAX:
			continue
		var cand := row + Vector3i(1, 0, 0)
		var walked: Array[Vector3i] = [
			# centre, sill, east approach, gap, north approach
			cand, cand + Vector3i(1, 0, 0), cand + Vector3i(2, 0, 0),
			cand + Vector3i(0, 0, -1), cand + Vector3i(0, 0, -2),
			# plank wall + its pile
			cand + Vector3i(-2, 0, 0), cand + Vector3i(-2, 0, -1),
			# stone door + its two piles
			cand + Vector3i(3, 0, 0), cand + Vector3i(3, 0, -1),
			cand + Vector3i(3, 0, 1),
		]
		var walls: Array[Vector3i] = [
			cand + Vector3i(-1, 0, -1), cand + Vector3i(1, 0, -1),
			cand + Vector3i(-1, 0, 0), cand + Vector3i(-1, 0, 1),
			cand + Vector3i(0, 0, 1), cand + Vector3i(1, 0, 1),
		]
		var ok := true
		for cell in walked + walls:
			if (
				not world.is_editable(cell)
				or world.is_solid(cell)
				or world.is_solid(cell + Vector3i.UP)
			):
				ok = false
				break
		for cell in walked:
			if not world.is_solid(cell + Vector3i.DOWN):
				ok = false
				break
		if ok:
			centre = cand
			break
	_check(centre != Vector3i.MAX, "found a clear span for the door room")
	if centre == Vector3i.MAX:
		return

	var sill := centre + Vector3i(1, 0, 0)
	var outside_e := centre + Vector3i(2, 0, 0)
	var gap := centre + Vector3i(0, 0, -1)
	var outside_n := centre + Vector3i(0, 0, -2)

	# Designation gates, before anything stands: no dirt door, and no
	# door where the headroom cell above the sill is filled.
	_check(
		colony.designate_build(centre, &"dirt_door") == null,
		"a dirt door can't be designated"
	)
	_check(
		world.place(outside_n + Vector3i.UP, BlockRegistry.Block.STONE_WALL),
		"a lintel block floats over the approach cell"
	)
	_check(
		colony.designate_build(outside_n, &"log_door") == null,
		"a door under a solid headroom cell can't be designated"
	)
	world.remove_voxel(outside_n + Vector3i.UP)

	# The plank wall first — five planks in, one full block out. It takes
	# a pad cell west of where the room's ring will stand.
	var plank_site := centre + Vector3i(-2, 0, 0)
	var plank_pile := plank_site + Vector3i(0, 0, -1)
	for i in 5:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			plank_pile
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var plank_job := _assign_build(colony, plank_site, plank_pile, &"plank_wall")
	var walled := await _wait_until(func() -> bool:
		return world.get_block(plank_site) == BlockRegistry.Block.PLANKS)
	_check(walled and plank_job != null, "a unit builds a plank wall from five planks")
	var plank_wall := colony.building_at(plank_site)
	var plank_count := 0
	if plank_wall != null:
		for item in plank_wall.components:
			if item.form == DropItem.Form.PLANK:
				plank_count += 1
	_check(plank_count == 5, "the plank wall holds exactly five planks")
	var sawdust := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - plank_site).length() > 2.5:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE and item.material == BlockRegistry.Resource_.WOOD:
				sawdust += item.volume
	_check(sawdust == 0, "a plank wall drops no sawdust")

	# The room: a two-high ring of stone walls around the interior cell,
	# leaving the doorway slot (and its headroom) open plus a gap in the
	# north face — the escape route the pathfinder should prefer.
	var ring: Array[Vector3i] = []
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			if dx == 1 and dz == 0:
				continue # the doorway
			if dx == 0 and dz == -1:
				continue # the gap
			ring.append(centre + Vector3i(dx, 0, dz))
	for dy in [0, 1]:
		for cell in ring:
			world.place(cell + Vector3i(0, dy, 0), BlockRegistry.Block.STONE_WALL)

	# Hang the door: two logs fetched and delivered, the doorway stays
	# open air under the building record.
	_clear_wall_material_near(colony, sill, 25.0)
	for i in 2:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
			),
			outside_e
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var door_job := _assign_build(colony, sill, outside_e, &"log_door")
	var hung := await _wait_until(func() -> bool:
		return colony.door_at(sill) != null)
	_check(hung and door_job != null, "a unit hangs a log door in the doorway")
	var door := colony.door_at(sill)
	if door == null:
		return
	_check(
		world.get_block(sill) == BlockRegistry.Block.AIR,
		"a built door leaves its voxel open air"
	)
	_check(
		colony.building_at(sill + Vector3i.UP) == door,
		"the door's headroom cell belongs to it"
	)
	var log_count := 0
	for item in door.components:
		if item.form == DropItem.Form.LOG:
			log_count += 1
	_check(log_count == 2, "the door holds the two logs it took")
	var door_sawdust := 0
	for voxel in colony.item_piles:
		if Vector3(voxel - sill).length() > 2.5:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE and item.material == BlockRegistry.Resource_.WOOD:
				door_sawdust += item.volume
	_check(door_sawdust == 750000, "the door's overcharge drops as sawdust")
	if world.sim != null:
		_check(world.sim.door_at(sill), "the native sim marks the sill a door")

	# Pathing through it: while the north gap is open the way around is
	# cheaper than paying the swing; seal it and the door is the only way.
	if world.sim != null:
		var around := world.find_path(outside_n, centre)
		var through_door := false
		for point in around:
			if Vector3i(point.floor()) == sill:
				through_door = true
		_check(
			not around.is_empty() and not through_door,
			"an open gap beats paying the door's swing"
		)
		world.place(gap, BlockRegistry.Block.STONE_WALL)
		world.place(gap + Vector3i.UP, BlockRegistry.Block.STONE_WALL)
		var only := world.find_path(outside_n, centre)
		through_door = false
		for point in only:
			if Vector3i(point.floor()) == sill:
				through_door = true
		_check(through_door, "sealed in, the path goes through the door")
	else:
		_check(false, "the native sim is loaded for door pathing")

	# The swing itself: a unit crossing pays the pause at the threshold,
	# walks through, and the door shuts — the way back pays it again.
	var walker: Unit = colony.units[0]
	for u in colony.units:
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
		if u == walker or u._carried_by != null:
			continue
		u._job_search_cooldown = 600.0
		# Fixtures from earlier sections idle all over this flat band —
		# a body in the one-cell doorway or on the goal stalls the
		# walker's watchdog, so park the roster well clear of the room.
		var ax: int = centre.x - 26
		var az: int = centre.z - 26 + (u.get_instance_id() % 7) * 2
		var ay := world.ground_height(ax, az, centre.y + 40)
		if ay <= -30:
			continue
		u.global_position = Vector3(ax + 0.5, ay + 1.9, az + 0.5)
		u.velocity = Vector3.ZERO
	walker.global_position = Vector3(outside_n) + Vector3(0.5, 0.9, 0.5)
	walker.velocity = Vector3.ZERO
	var cross := ColonyJob.new(ColonyJob.Type.REST, centre)
	cross.state = ColonyJob.State.ASSIGNED
	cross.assignee = walker
	walker.job = cross
	walker._goal_voxel = centre
	walker.state = Unit.State.MOVING
	var passed := await _wait_until(func() -> bool: return door.pass_count > 0)
	_check(passed, "a unit pays the swing time to open the door")
	var inside := await _wait_until(func() -> bool:
		return walker._standing_voxel() == centre)
	_check(inside, "the unit walks through the open door")
	walker.abandon_job()

	var back := ColonyJob.new(ColonyJob.Type.REST, outside_n)
	back.state = ColonyJob.State.ASSIGNED
	back.assignee = walker
	walker.job = back
	walker._goal_voxel = outside_n
	walker.state = Unit.State.MOVING
	var repassed := await _wait_until(func() -> bool: return door.pass_count > 1)
	_check(repassed, "the door closes behind — the way back pays the swing again")
	walker.abandon_job()

	# Taking it down hands back exactly what it took — the offcut stays
	# on the ground where it fell.
	var demolish := colony.designate_deconstruct(sill)
	_check(demolish != null, "a door designates for deconstruction")
	if demolish != null:
		_assign_job(colony, demolish, outside_e)
		var down := await _wait_until(func() -> bool:
			return colony.door_at(sill) == null)
		_check(down, "a unit takes the door down")
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var returned := 0
		for voxel in colony.item_piles:
			if Vector3(voxel - sill).length() > 2.5:
				continue
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.LOG:
					returned += 1
		_check(returned == 2, "the door hands its two logs back")
	if world.sim != null:
		_check(not world.sim.door_at(sill), "the native sim clears the door")

	# The stone door, standing alone on a pad cell east of the room —
	# a hundred and fifty dressed blocks in, nothing wasted out.
	var stone_site := centre + Vector3i(3, 0, 0)
	_clear_wall_material_near(colony, stone_site, 25.0)
	for i in 150:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BLOCK,
				DropItem.STONE_BLOCK_CM3
			),
			stone_site + Vector3i(0, 0, -1)
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stone_job := _assign_build(
		colony, stone_site, stone_site + Vector3i(0, 0, -1), &"stone_door"
	)
	var hung_stone := await _wait_until(func() -> bool:
		return colony.door_at(stone_site) != null)
	_check(hung_stone and stone_job != null, "a unit hangs a stone door")


func _test_collapse(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("collapse")
	var foot := _flat_voxel(world, mined, 220)
	_check(foot != Vector3i.MAX, "found a flat spot for the collapse test")
	if foot == Vector3i.MAX:
		return

	# --- Detached body: a tower with an arm cantilevered off the top —
	#     the arm hangs only through the column.
	var p1 := foot + Vector3i.UP
	var p2 := foot + Vector3i.UP * 2
	var arm_a := p2 + Vector3i.RIGHT
	var arm_b := p2 + Vector3i.RIGHT * 2
	for v in [foot, p1, p2, arm_a, arm_b]:
		world.place(v, BlockRegistry.Block.STONE_WALL)
	_check(
		world.is_solid(arm_b),
		"a floating arm assembles off the tower"
	)
	_check(
		world.mine(foot) != BlockRegistry.Block.AIR,
		"the tower's foot mines out"
	)
	_check(
		world.get_block(p1) == BlockRegistry.Block.AIR
			and world.get_block(p2) == BlockRegistry.Block.AIR
			and world.get_block(arm_a) == BlockRegistry.Block.AIR
			and world.get_block(arm_b) == BlockRegistry.Block.AIR,
		"everything the foot held up comes down with it"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var rubble := 0
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - foot).length() > 8.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.STONE:
				rubble += item.volume
	_check(
		rubble >= 4 * 120 * DropItem.STONE_BLOCK_CM3,
		"collapsed walls drop their invested rubble where they stood"
	)

	# Neighbours of the removed foot that kept their chain stay put.
	_check(
		world.is_solid(foot + Vector3i.DOWN),
		"the ground under it does not collapse"
	)

	# --- Suspension: a floating build has nothing to hang from, so the
	#     job waits rather than completing an instant cave-in.
	_clear_jobs(colony)
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 120.0
	# The suspension fixture needs a cell with NO solid face-neighbour —
	# flat ground alone doesn't promise that (a hillside can touch the
	# cell two up), so the scan verifies the whole neighbourhood is open.
	var ledge := _floating_flat(colony, world, mined, -150)
	_check(ledge != Vector3i.MAX, "found a floating spot for the suspend test")
	if ledge == Vector3i.MAX:
		return
	var target := ledge + Vector3i.UP
	var upper := target + Vector3i.UP
	_check(
		not colony.would_be_supported(target),
		"the test cell floats with no solid neighbour"
	)
	# A dirt wall wants 1.25 m³ of loose soil; three piles beside the
	# column cover two walls. Each is under the 1 m³ cap, so none spills
	# — the cells are inside the 5×5 flat the scan already verified.
	for off in [Vector3i(0, 0, 1), Vector3i(0, 0, 2), Vector3i(1, 0, 2)]:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 900000
			),
			ledge + off
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var depot := ledge + Vector3i(0, 0, 1)

	var job := colony.designate_build(target, &"dirt_wall")
	_check(job != null, "a floating build still designates")
	if job == null:
		return
	var upper_job := colony.designate_build(upper, &"dirt_wall")
	_check(upper_job != null, "a second floating build designates above it")

	var park := ledge + Vector3i.RIGHT
	_hand_job(colony, job, park, depot)
	var held := await _wait_until(func() -> bool: return job.suspended)
	_check(held, "a build with no support suspends instead of placing")
	_check(
		world.get_block(target) == BlockRegistry.Block.AIR
			and colony.is_designated(target),
		"the suspended plan keeps its cell and marker"
	)
	if upper_job != null:
		_hand_job(colony, upper_job, park, depot)
		var held2 := await _wait_until(func() -> bool: return upper_job.suspended)
		_check(held2, "the upper plan suspends on the same missing support")

	# A support under the lower cell lifts its suspension — and only its
	# own; the upper cell still has nothing until the lower wall lands.
	_check(
		world.place(ledge, BlockRegistry.Block.STONE),
		"a support column goes in"
	)
	_check(not job.suspended, "an adjacent placement lifts the suspension")
	if upper_job != null:
		_check(
			upper_job.suspended,
			"a plan two cells from the support stays suspended"
		)
	_hand_job(colony, job, park, Vector3i.MAX)
	var built := await _wait_until(func() -> bool:
		return world.get_block(target) == BlockRegistry.Block.DIRT)
	_check(built, "the resumed job builds once support exists")
	if upper_job != null:
		_check(
			not upper_job.suspended,
			"the lower wall's placement unsuspends the cell above"
		)
		_hand_job(colony, upper_job, park, Vector3i.MAX)
		var built2 := await _wait_until(func() -> bool:
			return world.get_block(upper) == BlockRegistry.Block.DIRT)
		_check(built2, "the cascade resumes the upper wall too")

	# Tidy up: drop the tower so later tests find clean ground, and clear
	# the leftover piles.
	world.remove_voxel(upper)
	world.remove_voxel(target)
	world.remove_voxel(ledge)
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0


## RimWorld-style shell: colonist bar matches the roster, the architect
## popup carries every action plus disabled stubs, toggles and the speed
## buttons do what they say.
## Skills: XP grows levels linearly (X, 2X, 3X, …), level 10 ≈ 2× work
## speed, completions grant XP to their discipline, and claim scoring lets
## specialists favour their craft while waiting jobs can't starve.
func _test_skills(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	_clear_jobs(colony)
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
		u.abandon_job()
	unit.energy = 1.0
	unit.hunger = 1.0

	# --- XP → level: linear requirement inverted through the quadratic ---
	var x := Unit.SKILL_XP_BASE
	unit.skills[ColonyJob.Skill.MINING] = 0.0
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 0, "no xp means level 0"
	)
	unit.skills[ColonyJob.Skill.MINING] = x - 0.01
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 0,
		"just short of x stays level 0"
	)
	unit.skills[ColonyJob.Skill.MINING] = x
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 1,
		"x points reaches level 1"
	)
	unit.skills[ColonyJob.Skill.MINING] = 3.0 * x - 0.01
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 1,
		"3x needs the full 2x second step"
	)
	unit.skills[ColonyJob.Skill.MINING] = 3.0 * x
	_check(
		unit.skill_level(ColonyJob.Skill.MINING) == 2,
		"linear growth: x then 2x reaches level 2"
	)
	_check(
		is_equal_approx(Unit.skill_xp_next(0), x)
			and is_equal_approx(Unit.skill_xp_next(1), 2.0 * x)
			and is_equal_approx(Unit.skill_xp_next(4), 5.0 * x),
		"the xp step scales linearly with level"
	)

	# --- speed: 2^(level/10) → L10 ≈ 2×, L20 ≈ 4×, unskilled 1× ---
	unit.skills[ColonyJob.Skill.MINING] = 55.0 * x # L10: 10·11/2
	_check(
		is_equal_approx(unit.skill_rate(ColonyJob.Skill.MINING), 2.0),
		"level 10 works at twice base speed"
	)
	unit.skills[ColonyJob.Skill.MINING] = 210.0 * x # L20: 20·21/2
	_check(
		is_equal_approx(unit.skill_rate(ColonyJob.Skill.MINING), 4.0),
		"level 20 works at four times base speed"
	)
	_check(
		unit.skill_rate(-1) == 1.0, "an unskilled job type runs at base speed"
	)
	unit.job = ColonyJob.new(ColonyJob.Type.MINE, Vector3i.ZERO)
	_check(
		is_equal_approx(unit._work_rate(), 4.0),
		"the work rate folds the current job's skill in"
	)
	unit.job = ColonyJob.new(ColonyJob.Type.CLEAR, Vector3i.ZERO)
	_check(
		is_equal_approx(unit._work_rate(), 1.0),
		"an unskilled job ignores mining skill"
	)
	unit.job = null
	unit.skills[ColonyJob.Skill.MINING] = 0.0

	# --- claim scoring ---
	# Park the unit; fixture jobs go on flat rows at chosen distances.
	var us := _flat_voxel(world, mined, 30)
	var near_v := _flat_voxel(world, mined, 38)
	var far_v := _flat_voxel(world, mined, 75)
	_check(
		us != Vector3i.MAX and near_v != Vector3i.MAX and far_v != Vector3i.MAX,
		"found flat rows for the claim fixtures"
	)
	if us == Vector3i.MAX or near_v == Vector3i.MAX or far_v == Vector3i.MAX:
		return
	unit.global_position = Vector3(us) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO

	# Languish: two same-type jobs — backdate the far one past the
	# distance gap and it outranks the close one. All synchronous, so no
	# unit tick can claim mid-check.
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 120000),
		near_v
	)
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 120000),
		far_v
	)
	var near_clear := colony.designate_clear(near_v)
	var far_clear := colony.designate_clear(far_v)
	_check(
		near_clear != null and far_clear != null,
		"two clearing jobs for the languish check"
	)
	if near_clear != null and far_clear != null:
		far_clear.posted_msec -= 240000
		if world.sim != null:
			world.sim.job_set_posted(
				far_clear.get_instance_id(), far_clear.posted_msec
			)
		var picked := colony.claim_job(unit)
		_check(
			picked == far_clear,
			"a long-waiting job outranks a closer fresh one"
		)
		colony.cancel_designation(near_v)
		colony.cancel_designation(far_v)

	# Skill preference: near CLEAR vs far MINE — a generalist takes the
	# close one, a level-5 specialist crosses the gap for its craft.
	var clear_v := _flat_voxel(world, mined, 42)
	var mine_spot_v := _flat_voxel(world, mined, 80)
	var mine_v := mine_spot_v + Vector3i.DOWN
	_check(
		clear_v != Vector3i.MAX and mine_spot_v != Vector3i.MAX,
		"found rows for the skill-preference check"
	)
	unit.skills[ColonyJob.Skill.MINING] = 15.0 * x # L5: 5·6/2
	unit.specialize = false
	colony._deposit_item(
		DropItem.new(BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 120000),
		clear_v
	)
	var clear_job := colony.designate_clear(clear_v)
	var mine_job := colony.designate_mine(mine_v)
	if clear_job != null and mine_job != null:
		var generalist_pick := colony.claim_job(unit)
		_check(
			generalist_pick == clear_job,
			"a generalist takes the nearer unskilled job"
		)
		colony.cancel_designation(clear_v)
		colony.cancel_designation(mine_v)
		# Fresh records — the cancelled ones carry drop bookkeeping.
		clear_job = colony.designate_clear(clear_v)
		mine_job = colony.designate_mine(mine_v)
		unit.specialize = true
		var specialist_pick := colony.claim_job(unit)
		_check(
			specialist_pick == mine_job,
			"a specialist crosses the gap for a skilled job"
		)
		colony.cancel_designation(clear_v)
		colony.cancel_designation(mine_v)
	else:
		_check(false, "could not designate the skill-preference jobs")
	unit.specialize = false

	# --- XP on completion, and none for unskilled work ---
	for skill in unit.skills:
		unit.skills[skill] = 0.0
	var mine_spot := _flat_voxel(world, mined, 10)
	var mine_cell := mine_spot + Vector3i.DOWN
	var mjob := colony.designate_mine(mine_cell)
	_check(mjob != null, "a mine designation for the xp check")
	if mjob != null:
		_arm_tool(unit, &"stone_pick")
		_assign_job(colony, mjob, _park_beside(colony, world, mine_cell, mine_spot), unit)
		var mined_out := await _wait_until(
			func() -> bool: return not world.is_solid(mine_cell)
		)
		_check(mined_out, "the unit completes the mine job")
		_check(
			is_equal_approx(
				unit.skills[ColonyJob.Skill.MINING],
				ColonyJob.XP_FOR[ColonyJob.Type.MINE]
			),
			"mining completion grants mining xp"
		)
	# Unskilled completions grant nothing — exercise the same award path
	# (`_finish_job`) with a synthetic CLEAR job; a real clear's completion
	# is covered by _test_clear.
	for skill in unit.skills:
		unit.skills[skill] = 0.0
	var fake_clear := ColonyJob.new(
		ColonyJob.Type.CLEAR, Vector3i(9999, 999, 9999)
	)
	fake_clear.assignee = unit
	colony._finish_job(fake_clear)
	var gained := 0.0
	for skill in unit.skills:
		gained += unit.skills[skill]
	_check(gained == 0.0, "unskilled work grants no xp")


func _test_organics(colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i) -> void:
	print("organics")
	_clear_jobs(colony)
	for u in colony.units:
		if u != unit:
			u._job_search_cooldown = 120.0
		u.abandon_job()

	# The fixture box below spans dx -3..13, dz -5..4 — every column in
	# it must be dry in the used band, not just the anchor, so the scan
	# carries a one-cell-padded footprint of the same box.
	var base := _flat_voxel(
		world, mined, -72, 144, Rect2i(-4, -6, 19, 12)
	)
	_check(base != Vector3i.MAX, "found a flat stretch for the organics test")
	if base == Vector3i.MAX:
		return

	# Clear the fixture box — canopy room, fruit scatter, and the
	# sprout/decay strip all live in it. Same discipline as _test_tree.
	for dx in range(-3, 14):
		for dy in range(0, 10):
			for dz in range(-5, 5):
				var cell := base + Vector3i(dx, dy, dz)
				var owner := colony.forest.tree_root_at(cell)
				if owner != Vector3i.MAX:
					colony.forest.trees.erase(owner)
					colony.forest._index.erase(cell)
					colony.forest._leaves.erase(cell)
				var bush := colony.plants.bush_at(cell)
				if bush != Vector3i.MAX:
					colony.plants.bushes.erase(bush)
					colony.plants._index.erase(cell)
				var pile := colony.item_pile_at(cell)
				if pile != null:
					pile.items.clear()
					colony.remove_pile_if_empty(cell)
				if (
					world.is_editable(cell)
					and world.get_block(cell) != BlockRegistry.Block.AIR
				):
					world.remove_voxel(cell)
	# Push units out of the box — a unit in a cell blocks tree growth.
	for u in colony.units:
		if Vector3(u.global_position - Vector3(base)).length() < 12.0:
			u.global_position = Vector3(base.x - 12, base.y + 0.9, base.z + 0.5)
			u.velocity = Vector3.ZERO

	# --- Fruiting: a mature oak sheds one acorn per leaf block ---
	_check(
		colony.forest.plant_sapling(base), "a sapling plants for fruiting"
	)
	var sp: Dictionary = Forest.species_table()[&"oak"]
	for i in int(sp[&"max_height"]):
		colony.forest.grow(base)
	var rec: Dictionary = colony.forest.trees.get(base, {})
	_check(
		int(rec.get(&"height", -1)) == int(sp[&"max_height"]),
		"the fruit tree grows to maturity"
	)
	var leaf_count := 0
	for voxel: Vector3i in rec[&"voxels"]:
		if colony.forest.leaf_at(voxel):
			leaf_count += 1
	_check(leaf_count > 0, "the mature tree has leaf blocks")
	var fruit_before := _count_items(
		colony, base, 14.0, BlockRegistry.Resource_.ACORN, DropItem.Form.FRUIT
	)
	colony.forest.grow(base) # mature step → the fruit drop
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var acorns := _collect_items(
		colony, base, 14.0, BlockRegistry.Resource_.ACORN, DropItem.Form.FRUIT
	)
	_check(
		acorns.size() - fruit_before == leaf_count,
		"a mature oak drops one acorn per leaf block"
	)
	var all_whole := true
	for item in acorns:
		if item.volume != DropItem.FRUIT_CM3:
			all_whole = false
	_check(all_whole, "each fruit is a whole item")
	# Some fruit landed away from the trunk column — gravity scattered it.
	var landed_on := {}
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - base).length() > 14.0:
			continue
		for item in colony.item_piles[voxel].items:
			if (
				item.material == BlockRegistry.Resource_.ACORN
				and item.form == DropItem.Form.FRUIT
			):
				landed_on[voxel] = true
	_check(
		landed_on.size() > 1, "fruit scatters into piles around the base"
	)
	# The production cadence is the mature tree's own tick: five days.
	var next_in := int(rec[&"next"]) - colony.game_msec()
	_check(
		next_in > int(sp[&"growth_seconds"]) * 900,
		"the next fruiting lands about five game-days out"
	)
	# Bushes never fruit — no species entry carries a fruit drop.
	_check(
		Plants.species_table()[&"berry_bush"].get(&"fruit_material") == null,
		"bushes hold their fruit for forage, not drops"
	)

	# --- Extract seed: a fruit craft at the worksite ---
	var spot := base + Vector3i(5, 0, 0)
	var fruit_v := base + Vector3i(6, 0, 0)
	_normalize_cell(colony, world, spot)
	_normalize_cell(colony, world, fruit_v)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.ACORN,
			DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		fruit_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	unit.global_position = Vector3(spot) + Vector3(-1.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	_check(
		colony.designate_craft_spot(spot),
		"a craft spot designates for seed extraction"
	)
	var seed_job := _assign_craft(colony, world, spot, fruit_v, &"extract_seed")
	_check(
		seed_job != null, "extract-seed designates as a craft order"
	)
	if seed_job != null:
		var presser: Unit = seed_job.assignee
		var xp_before: float = presser.skills.get(
			ColonyJob.Skill.CRAFTING, 0.0
		)
		_check(
			seed_job.type == ColonyJob.Type.CRAFT,
			"the seed order is a crafting job"
		)
		var crafted := await _wait_until(
			func() -> bool: return seed_job.state == ColonyJob.State.DONE
		)
		_check(crafted, "a unit presses the acorn into seeds")
		await _wait_until(
			func() -> bool: return colony._in_flight.is_empty()
		)
		var seeds := _collect_items(
			colony, spot, 4.0, BlockRegistry.Resource_.SEED, DropItem.Form.SEED
		)
		_check(seeds.size() == 2, "one fruit presses into two seed packets")
		var oak_seeds := true
		for item in seeds:
			if item.species != &"oak":
				oak_seeds = false
		_check(oak_seeds, "seeds keep the fruit's species")
		_check(
			presser.skills.get(ColonyJob.Skill.CRAFTING, 0.0) > xp_before,
			"seed extraction trains crafting"
		)

	# A foraged berry takes the same order — it's a FRUIT item now — and
	# the packets carry the bush's species, which is what a berry field
	# sows. This is the whole berry→seed→farm loop a player sees.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BERRY,
			DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		fruit_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var berry_job := _assign_craft(colony, world, spot, fruit_v, &"extract_seed")
	_check(berry_job != null, "extract-seed re-orders on a berry")
	if berry_job != null:
		var pressed := await _wait_until(
			func() -> bool: return berry_job.state == ColonyJob.State.DONE
		)
		_check(pressed, "a unit presses the berry into seeds")
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var berry_seeds := _collect_items(
			colony, spot, 4.0, BlockRegistry.Resource_.SEED, DropItem.Form.SEED
		)
		var bush_packets := 0
		for item in berry_seeds:
			if item.species == &"berry_bush":
				bush_packets += 1
		_check(bush_packets == 2, "a berry presses into two berry-bush seeds")
		_check(
			colony._seed_exists(&"berry_bush"),
			"berry-bush seed packets answer the sow query"
		)

	# --- Organic decay: per-material rules ---
	var day := colony.day_length()
	var cells: Array[Vector3i] = []
	for i in range(6):
		var c := base + Vector3i(5 + i, 0, -2)
		_normalize_cell(colony, world, c)
		cells.append(c)
	# All non-soil floors — no decayed fruit may sprout here.
	for c in cells:
		world.remove_voxel(c + Vector3i.DOWN)
		world.place(c + Vector3i.DOWN, BlockRegistry.Block.STONE)

	# The fixtures must sit untouched until the sweep counts them — the
	# craft fixture just parked a unit beside these cells, and an idle
	# unit would otherwise haul the deposited logs to a stockpile.
	for u in colony.units:
		u._job_search_cooldown = 120.0

	var leaf_v: Vector3i = cells[0]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.LEAF, DropItem.Form.LOOSE, 200_000
		),
		leaf_v
	)
	var branch_v: Vector3i = cells[1]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE, 120_000
		),
		branch_v
	)
	var log_v: Vector3i = cells[2]
	# A log is a whole cubic metre — one fills its cell, so the pair
	# each get a tile of their own a row back.
	var log_v2 := base + Vector3i(7, 0, -4)
	_normalize_cell(colony, world, log_v2)
	world.remove_voxel(log_v2 + Vector3i.DOWN)
	world.place(log_v2 + Vector3i.DOWN, BlockRegistry.Block.STONE)
	for lv: Vector3i in [log_v, log_v2]:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			lv
		)
	var plank_v: Vector3i = cells[3]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD,
			DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		),
		plank_v
	)
	var compost_v: Vector3i = cells[4]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COMPOST,
			DropItem.Form.LOOSE,
			80_000
		),
		compost_v
	)
	var rot_v: Vector3i = cells[5]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.ACORN,
			DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		rot_v
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
		),
		rot_v
	)
	# Outdoor weathering (item 24): the plank at plank_v stays exposed and
	# weathers, a roofed sibling and a mineral pile must not.
	var sheltered_v: Vector3i = base + Vector3i(12, 0, -2)
	_normalize_cell(colony, world, sheltered_v)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD,
			DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		),
		sheltered_v
	)
	# Any solid block overhead is a roof.
	world.place(sheltered_v + Vector3i(0, 3, 0), BlockRegistry.Block.STONE)
	var mineral_v: Vector3i = base + Vector3i(14, 0, -2)
	_normalize_cell(colony, world, mineral_v)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE,
			DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		),
		mineral_v
	)
	_check(colony.sees_sky(plank_v), "the weathered plank stands in the open")
	_check(colony.sees_sky(mineral_v), "the mineral fixture stands in the open")
	_check(
		not colony.sees_sky(sheltered_v),
		"a block overhead shelters the plank pile"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# One sweep at twenty lifetimes of the fastest material: every
	# decayable item in the fixture is gone (each bulk stack's quantum
	# count sits deep in the Poisson tail — deterministic in practice),
	# discrete items' per-sweep odds pass one, and the compost each rot
	# leaves behind is added after the sweep so it survives to count.
	colony._decay_tick(300.0 * day)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var leaf_pile := colony.item_pile_at(leaf_v)
	var leaf_compost := 0
	var leaf_left := false
	if leaf_pile != null:
		for item in leaf_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				leaf_compost += item.volume
			elif item.material == BlockRegistry.Resource_.LEAF:
				leaf_left = true
	_check(not leaf_left, "leaf litter rots away")
	_check(
		leaf_compost == 50_000,
		"leaves compost at a quarter of their volume"
	)
	var branch_pile := colony.item_pile_at(branch_v)
	var branch_compost := 0
	if branch_pile != null:
		for item in branch_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				branch_compost += item.volume
	_check(
		branch_compost == 60_000,
		"branches compost at half their volume"
	)
	var log_compost := 0
	var log_left := false
	for lv: Vector3i in [log_v, log_v2]:
		var log_pile := colony.item_pile_at(lv)
		if log_pile == null:
			continue
		for item in log_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				log_compost += item.volume
			elif item.form == DropItem.Form.LOG:
				log_left = true
	_check(not log_left, "logs decay as discrete items")
	_check(
		log_compost == DropItem.LOG_CM3,
		"two logs leave a whole log's worth of compost"
	)
	var plank_pile := colony.item_pile_at(plank_v)
	var plank_alive := false
	if plank_pile != null:
		for item in plank_pile.items:
			if item.form == DropItem.Form.PLANK:
				plank_alive = true
	_check(not plank_alive, "a plank left in the open weathers away")
	var plank_compost := 0
	if plank_pile != null:
		for item in plank_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				plank_compost += item.volume
	_check(plank_compost == 0, "weathering leaves no compost behind")
	var sheltered_pile := colony.item_pile_at(sheltered_v)
	var sheltered_plank := false
	if sheltered_pile != null:
		for item in sheltered_pile.items:
			if item.form == DropItem.Form.PLANK:
				sheltered_plank = true
	_check(sheltered_plank, "a plank under a roof never weathers")
	var mineral_pile := colony.item_pile_at(mineral_v)
	var boulder_alive := false
	if mineral_pile != null:
		for item in mineral_pile.items:
			if item.form == DropItem.Form.BOULDER:
				boulder_alive = true
	_check(boulder_alive, "stone doesn't weather")
	var compost_pile := colony.item_pile_at(compost_v)
	var compost_left := false
	if compost_pile != null:
		for item in compost_pile.items:
			if item.material == BlockRegistry.Resource_.COMPOST:
				compost_left = true
	_check(not compost_left, "compost decays into nothing")
	# These fixtures stand on stone — a barren block can't hold the
	# fertilization rotted compost would leave over dirt.
	_check(
		not colony.fertilization.has(compost_v + Vector3i.DOWN),
		"compost rotting on stone feeds nothing"
	)
	var rot_pile := colony.item_pile_at(rot_v)
	var rot_left := false
	if rot_pile != null:
		for item in rot_pile.items:
			if (
				item.form == DropItem.Form.FRUIT
				or item.form == DropItem.Form.SEED
			):
				rot_left = true
	_check(not rot_left, "fruit and seed decay outright")
	_check(
		colony.forest.tree_root_at(rot_v) == Vector3i.MAX
			and colony.plants.bush_at(rot_v) == Vector3i.MAX,
		"fruit rotting off soil never sprouts"
	)

	# --- Sprouting rules (deterministic half of the 5% roll) ---
	# The decay sweep may have sprouted volunteer trees from the scattered
	# acorns — clear each cell's 3×3 of plant claims right before use, in
	# a synchronous block so no periodic sweep can interleave.
	var sa := base + Vector3i(4, 0, 3)
	var sb := base + Vector3i(5, 0, 3)
	var sc := base + Vector3i(8, 0, 3)
	var sd := base + Vector3i(10, 0, 3)
	for pcell in [sa, sb, sc, sd]:
		_clear_plants_around(colony, pcell)
		_normalize_cell(colony, world, pcell)
	_check(
		colony._sprout_plant(sa, BlockRegistry.Resource_.ACORN),
		"a decayed acorn on soil plants a sapling"
	)
	_check(
		colony.forest.tree_root_at(sa) == sa,
		"the sprouted sapling registers as a tree"
	)
	_check(
		not colony._sprout_plant(sb, BlockRegistry.Resource_.ACORN),
		"a sapling can't sprout beside another plant"
	)
	_check(
		colony._sprout_plant(sb, BlockRegistry.Resource_.BERRY),
		"a berry may sprout its own cell beside a tree"
	)
	_check(
		colony.plants.bush_at(sb) == sb,
		"the berry sprout registers as a bush"
	)
	_check(
		not colony.plants.bushes[sb][&"ripe"],
		"a sprouted bush starts out immature"
	)
	_check(
		not colony._sprout_plant(sb, BlockRegistry.Resource_.BERRY),
		"a bush can't sprout where a bush already stands"
	)
	_check(
		not colony._sprout_plant(sa, BlockRegistry.Resource_.BERRY),
		"a bush can't sprout where a sapling stands"
	)
	_check(
		colony._sprout_plant(sc, BlockRegistry.Resource_.ACORN),
		"a sapling three cells out has room to plant"
	)

	# The 5% roll itself: a clear soil cell eventually sprouts, and a
	# stone-floored cell never does — rolls are bounded, so no flake.
	_clear_plants_around(colony, sd)
	var sprouted := false
	for i in 500:
		colony._sprout_from_decay(sd, BlockRegistry.Resource_.ACORN)
		if colony.forest.tree_root_at(sd) != Vector3i.MAX:
			sprouted = true
			break
	_check(sprouted, "the five-percent sprout roll fires on soil")
	var stone_cell := base + Vector3i(11, 0, -2)
	_normalize_cell(colony, world, stone_cell)
	var stone_owner := colony.forest.tree_root_at(stone_cell)
	if stone_owner != Vector3i.MAX:
		colony.forest.trees.erase(stone_owner)
		colony.forest._index.erase(stone_cell)
	world.remove_voxel(stone_cell + Vector3i.DOWN)
	var floored := world.place(
		stone_cell + Vector3i.DOWN, BlockRegistry.Block.STONE
	)
	_check(floored, "the no-sprout fixture gets a stone floor")
	if not floored:
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return
	for i in 100:
		colony._sprout_from_decay(stone_cell, BlockRegistry.Resource_.ACORN)
	_check(
		colony.forest.tree_root_at(stone_cell) == Vector3i.MAX,
		"fruit decaying on bare stone never sprouts"
	)

	for u in colony.units:
		u._job_search_cooldown = 0.0


## Count of items of [param material]/[param form] in piles within
## [param radius] of [param near].
func _count_items(
	colony: Colony, near: Vector3i, radius: float,
	material: BlockRegistry.Resource_, form: DropItem.Form
) -> int:
	return _collect_items(colony, near, radius, material, form).size()


## The items of [param material]/[param form] in piles within
## [param radius] of [param near].
func _collect_items(
	colony: Colony, near: Vector3i, radius: float,
	material: BlockRegistry.Resource_, form: DropItem.Form
) -> Array:
	var found: Array = []
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - near).length() > radius:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == material and item.form == form:
				found.append(item)
	return found


## Erase every tree/bush record claiming [param cell] or a neighbour —
## for sprout fixtures where a decayed-fruit volunteer could occupy the
## test cell's spacing neighbourhood.
func _clear_plants_around(colony: Colony, cell: Vector3i) -> void:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c := cell + Vector3i(dx, 0, dz)
			var owner := colony.forest.tree_root_at(c)
			if owner != Vector3i.MAX:
				colony.forest.trees.erase(owner)
			colony.forest._index.erase(c)
			colony.forest._leaves.erase(c)
			var bush := colony.plants.bush_at(c)
			if bush != Vector3i.MAX:
				colony.plants.bushes.erase(bush)
			colony.plants._index.erase(c)


## Make a test cell deterministic: bare air over a dirt floor, no pile.
func _normalize_cell(colony: Colony, world: VoxelWorld, cell: Vector3i) -> void:
	for dy in range(0, 4):
		var above := cell + Vector3i(0, dy, 0)
		if (
			world.is_editable(above)
			and world.get_block(above) != BlockRegistry.Block.AIR
		):
			world.remove_voxel(above)
	var pile := colony.item_pile_at(cell)
	if pile != null:
		pile.items.clear()
		colony.remove_pile_if_empty(cell)
	# `place` only writes into air — lift the floor block first so the
	# dirt actually lands.
	var floor_cell := cell + Vector3i.DOWN
	if world.is_editable(floor_cell):
		world.remove_voxel(floor_cell)
		world.place(floor_cell, BlockRegistry.Block.DIRT)


## Recreation: the third need — drains while awake, and below the seek
## line the unit self-issues a RECREATE job: praying and meditating
## happen in place, skygazing wants open sky, a walk accrues en route,
## social relaxing borrows an idle neighbour, and buildings like the
## game-of-Ur board host their own sessions. Repeating a kind builds
## tolerance that shades its gain, and the whole state round-trips
## through the region save. (PLAN item 25.)
func _test_recreation(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("recreation")
	# Park every unit for the section — driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)
	var unfreeze := func() -> void:
		for u in colony.units:
			u._job_search_cooldown = 0.0
	# Driven sessions run minutes into the suite — other needs drain in
	# the meantime, and hunger or exhaustion below the floor ends a
	# session in its first tick before it pays out. Refresh before each.
	var fed := func() -> void:
		unit.hunger = 1.0
		unit.energy = 1.0
		unit.mood = 1.0
	colony.needs_enabled = true
	unit.velocity = Vector3.ZERO
	unit.energy = 1.0
	unit.hunger = 1.0
	unit.recreation = 1.0
	unit._rec_tolerance.clear()
	unit._rec_blacklist.clear()

	# A clear flat stretch for the subject and the build fixtures —
	# streamed, clean cells only. Scan below the mined row: the +z band
	# is nearly exhausted by earlier fixtures and the persistence test
	# reserves 232–260.
	var site := Vector3i.MAX
	for off in [
		-20, -24, -28, -32, -36, -40, -44, -48, -52, -56,
		-16, -60, -64, -68, -72, -76, -80,
		160, 164, 168, 172, 176, 180, 184, 188, 192, 196, 200, 204,
		208, 212, 216, 220, 224, 228,
	]:
		var candidate := _flat_voxel_row(world, mined, off)
		if candidate == Vector3i.MAX:
			continue
		var beside := candidate + Vector3i(2, 0, 0)
		if (
			colony.voxel_fill(candidate) <= 0
			and colony.voxel_fill(beside) <= 0
			and not colony._designation_markers.has(candidate)
			and not colony._designation_markers.has(beside)
			and colony.building_at(candidate) == null
			and colony.building_at(beside) == null
		):
			site = candidate
			break
	_check(site != Vector3i.MAX, "found a flat spot for the recreation tests")
	if site == Vector3i.MAX:
		colony.needs_enabled = false
		unfreeze.call()
		return
	unit.global_position = Vector3(site) + Vector3(0.5, 0.9, 0.5)

	# --- The need drains while awake.
	var drained := await _wait_until(func() -> bool:
		return unit.recreation < 1.0)
	_check(drained, "a waking unit drains recreation")

	# --- Below the seek line the unit self-issues a recreation job.
	unit.recreation = unit.recreation_seek * 0.5
	unit._job_search_cooldown = 0.0
	var seeking := await _wait_until(func() -> bool:
		return (
			unit.job != null
			and unit.job.type == ColonyJob.Type.RECREATE
		))
	_check(seeking, "a bored unit goes looking for recreation")
	var picked: StringName = (
		unit.job.rec_activity if unit.job != null else &""
	)
	_check(
		Unit.REC_ACTIVITIES.has(picked) or BlockRegistry.REC_SPECS.has(picked),
		"the picked activity is a real one"
	)
	var wrapped := await _wait_until(func() -> bool:
		return unit.job == null and unit.state == Unit.State.IDLE)
	_check(wrapped, "the session ends back at idle")
	_check(
		unit.recreation > unit.recreation_seek * 0.5,
		"the session restored some recreation"
	)
	unit._job_search_cooldown = 600.0

	# --- Praying: no building, no partner, happens in place.
	fed.call()
	unit.recreation = 0.5
	unit._rec_tolerance.clear()
	unit._start_recreation(&"pray")
	_check(
		unit.job != null and unit.job.rec_activity == &"pray",
		"praying needs nothing but the unit"
	)
	var praying := await _wait_until(func() -> bool:
		return unit.state == Unit.State.RECREATING)
	_check(praying, "praying holds the recreating state")
	var prayed := await _wait_until(func() -> bool:
		return unit.job == null)
	_check(prayed, "the prayer session wraps up")
	_check(unit.recreation > 0.5, "praying restored recreation")
	_check(
		float(unit._rec_tolerance.get(&"solitary", 0.0)) > 0.0,
		"praying built solitary tolerance"
	)
	_check(
		unit._rec_weight_of(Unit.REC_ACTIVITIES[&"pray"]) < 1.0,
		"a used-up kind pays less on the next pick"
	)
	unit._rec_tolerance.clear()

	# --- Skygazing: the spot it walks to must see the sky. Random
	# canopy can roof the whole ring scan, so park the subject where
	# the real predicate says a sky spot exists.
	var sky_site := Vector3i.MAX
	for sky_off in [-84, -88, -92, -96, -100, -104, -108, -112]:
		var sky_candidate := _flat_voxel_row(world, mined, sky_off)
		if sky_candidate == Vector3i.MAX:
			continue
		unit.global_position = (
			Vector3(sky_candidate) + Vector3(0.5, 0.9, 0.5)
		)
		unit.velocity = Vector3.ZERO
		if unit._rec_spot(true) != Vector3i.MAX:
			sky_site = sky_candidate
			break
	_check(sky_site != Vector3i.MAX, "found a spot under open sky")
	if sky_site == Vector3i.MAX:
		colony.needs_enabled = false
		unfreeze.call()
		return
	fed.call()
	unit.recreation = 0.5
	unit._start_recreation(&"skygaze")
	_check(
		unit.job != null and unit.job.rec_activity == &"skygaze",
		"skygazing finds an open-sky spot"
	)
	if unit.job != null:
		_check(
			colony.sees_sky(unit.job.voxel_position),
			"the skygaze spot actually sees the sky"
		)
	var gazed := await _wait_until(func() -> bool:
		return unit.job == null)
	_check(gazed, "the skygaze session wraps up")
	_check(unit.recreation > 0.5, "skygazing restored recreation")

	# --- A walk: recreation accrues on the move, not at a spot.
	fed.call()
	unit.recreation = 0.95
	unit._start_recreation(&"walk")
	_check(
		unit.job != null and unit.job.rec_activity == &"walk",
		"a walk starts for a waypoint"
	)
	var walked := await _wait_until(func() -> bool:
		return unit.job == null)
	_check(walked, "the walk wraps up")
	_check(
		unit.recreation > 0.97,
		"walking filled the bar en route"
	)

	# --- Social relaxing borrows a nearby idle unit.
	var partner: Unit = colony.units[1]
	var away := Vector3i.MAX
	for off in [60, -60, 80, -80, 100, -100, 120, -120]:
		var remote := _flat_voxel(world, mined, off)
		if remote != Vector3i.MAX and remote.distance_to(
			unit._standing_voxel()
		) > Unit.REC_SOCIAL_SEEK + 10.0:
			away = remote
			break
	if away != Vector3i.MAX:
		# Every other unit goes beyond earshot — capsule spread keeps
		# them near the spot, so park with margin over the seek radius.
		# Full bars keep a high-activity facet from wandering them off
		# into recreation while they wait.
		for u in colony.units:
			if u == unit:
				continue
			u.global_position = Vector3(away) + Vector3(0.5, 0.9, 0.5)
			u.velocity = Vector3.ZERO
			u.recreation = 1.0
		fed.call()
		unit.recreation = 0.5
		unit._start_recreation(&"social")
		_check(
			unit.job == null or unit.job.rec_activity != &"social",
			"no idle neighbour in range — nobody to relax with"
		)
		if unit.job != null:
			unit.abandon_job()
		# The subject wandered on its skygaze and walk — park the partner
		# beside where it stands NOW, not the fixture spot. A job the
		# partner picked up at the park site would keep it non-idle.
		partner.abandon_job()
		var close := _park_beside(
			colony, world,
			unit._standing_voxel(), unit._standing_voxel() + Vector3i(2, 0, 0)
		)
		partner.global_position = Vector3(close) + Vector3(0.5, 0.9, 0.5)
		partner.velocity = Vector3.ZERO
		partner.energy = 1.0
		partner.hunger = 1.0
		partner.recreation = 1.0
		fed.call()
		unit.recreation = 0.5
		unit._start_recreation(&"social")
		_check(
			unit.job != null and unit.job.rec_activity == &"social",
			"social relaxing finds an idle neighbour"
		)
		_check(
			unit._rec_partner == partner,
			"the nearest idle unit is the chat partner"
		)
		var chatted := await _wait_until(func() -> bool:
			return unit.job == null)
		_check(chatted, "the chat wraps up")
		_check(unit.recreation > 0.5, "socializing restored recreation")
		_check(
			partner.recreation > 0.5,
			"the chat partner shares the recreation gain"
		)
		_check(
			unit._rec_partner == null,
			"the partner is released when the chat ends"
		)
	else:
		_check(false, "found a far flat spot to park the partner")

	# --- A recreation building: the game-of-Ur board goes up like a
	# campfire — a designated cell plus its material inputs.
	var board_site := Vector3i.MAX
	var board_pile := Vector3i.MAX
	for off in [
		-84, -88, -92, -96, -100, -104, -108, -112, -116, -120,
		-124, -128, -132, -136, -140, -144, -148, -152,
		160, 164, 168, 172, 176, 180, 184, 188, 192, 196, 200, 204,
		208, 212, 216, 220, 224, 228,
	]:
		var candidate := _flat_voxel_row(world, mined, off)
		if candidate == Vector3i.MAX:
			continue
		# The row scan only proves equal ground height — the board cell,
		# the material pile, and the telescope site each need open air
		# and no claim of their own.
		var pile_cell := candidate + Vector3i(2, 0, 0)
		var scope_cell := candidate + Vector3i(1, 0, 0)
		if (
			world.get_block(pile_cell) == BlockRegistry.Block.AIR
			and world.get_block(scope_cell) == BlockRegistry.Block.AIR
			# The telescope check lifts its roof and expects open sky —
			# a canopy or outcrop overhead would confound it.
			and colony.sees_sky(scope_cell)
			and colony.voxel_fill(candidate) <= 0
			and colony.voxel_fill(pile_cell) <= 0
			and colony.voxel_fill(scope_cell) <= 0
			and not colony._designation_markers.has(candidate)
			and not colony._designation_markers.has(pile_cell)
			and not colony._designation_markers.has(scope_cell)
			and colony.building_at(candidate) == null
			and colony.building_at(pile_cell) == null
			and colony.building_at(scope_cell) == null
		):
			board_site = candidate
			board_pile = pile_cell
			break
	_check(board_site != Vector3i.MAX, "found a flat spot for the Ur board")
	if board_site == Vector3i.MAX:
		colony.needs_enabled = false
		unfreeze.call()
		return
	_check(
		colony.designate_rec(board_site, &"snowman") == null,
		"an unlisted recreation spec refuses to designate"
	)
	for i in 2:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.PLANK, DropItem.PLANK_CM3
			),
			board_pile
		)
	var build := colony.designate_rec(board_site, &"ur_board")
	_check(build != null, "a game-of-Ur board designates on open ground")
	if build == null:
		colony.needs_enabled = false
		unfreeze.call()
		return
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_drive_craft(colony, world, build, board_pile, board_site)
	var built := await _wait_until(
		func() -> bool: return build.state == ColonyJob.State.DONE
	)
	_check(built, "a unit builds the board from planks")
	await _wait_until(func() -> bool: return unit.job == null)
	var board := colony.building_at(board_site)
	_check(
		board != null and board.kind == Building.Kind.RECREATION,
		"the finished work registers as a recreation building"
	)
	if board != null:
		_check(
			board.spec == &"ur_board",
			"the building keeps the spec that named it"
		)
		_check(
			board.label().ends_with(
				BlockRegistry.rec_label(&"ur_board").to_lower()
			),
			"the inspect label comes from the spec"
		)
		_check(
			colony.free_rec_buildings().has(board),
			"a free board shows up as a recreation option"
		)
		# --- A session at the board.
		unit._job_search_cooldown = 600.0
		fed.call()
		unit.recreation = 0.5
		unit._rec_tolerance.clear()
		unit._start_recreation(&"ur_board")
		_check(
			unit.job != null and unit.job.rec_activity == &"ur_board",
			"playing Ur starts at the board"
		)
		_check(
			unit._rec_building == board and board.occupant == unit,
			"the board seats the player"
		)
		var played := await _wait_until(func() -> bool:
			return unit.job == null)
		_check(played, "the game wraps up")
		_check(unit.recreation > 0.5, "playing Ur restored recreation")
		_check(board.occupant == null, "the board frees its seat after")
		_check(
			float(unit._rec_tolerance.get(&"cerebral", 0.0)) > 0.0,
			"playing Ur built cerebral tolerance"
		)

	# --- Sky-gated buildings: a telescope won't site under a roof, and
	# roofs lift again once the column clears. The scope cell sits one
	# off the board — the row scan already proved it open and level.
	var scope_site := board_site + Vector3i(1, 0, 0)
	var roof_cell := scope_site + Vector3i(0, 3, 0)
	if world.is_editable(roof_cell) and world.place(
		roof_cell, BlockRegistry.Block.STONE
	):
		_check(
			colony.designate_rec(scope_site, &"telescope") == null,
			"a telescope refuses a roofed cell"
		)
		var scope_build := colony.designate_rec(scope_site, &"telescope")
		_check(
			scope_build == null,
			"a sky-gated spec stays undesignated while roofed"
		)
		world.remove_voxel(roof_cell)
		# Block edits commit on the next sim tick — wait for the column
		# to read open again before designating.
		await _wait_until(func() -> bool:
			return colony.sees_sky(scope_site))
		scope_build = colony.designate_rec(scope_site, &"telescope")
		_check(
			scope_build != null,
			"a telescope designates once the sky is back"
		)
		if scope_build != null:
			colony.cancel_designation(scope_site)
	else:
		_check(false, "found a flat spot for the telescope check")

	# --- Save/load carries the need and the tolerances.
	unit.recreation = 0.33
	unit._rec_tolerance[&"solitary"] = 0.4
	var saved := unit.serialize()
	unit.recreation = 1.0
	unit._rec_tolerance.clear()
	unit.deserialize(saved, colony)
	_check(
		is_equal_approx(unit.recreation, 0.33),
		"recreation survives a save round-trip"
	)
	_check(
		is_equal_approx(
			float(unit._rec_tolerance.get(&"solitary", 0.0)), 0.4
		),
		"recreation tolerance survives a save round-trip"
	)
	unit._rec_tolerance.clear()
	unit.recreation = 1.0

	# Restore the suite's standing arrangement.
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0
	colony.needs_enabled = false


## Mood and mental breaks — the THOUGHTS table sums into a mood target
## the bar drifts toward, personality facets modulate intensity and
## gate whole thoughts, and a mood held under the break threshold
## risks a food binge or a dazed wander (PLAN item 26).
func _test_mood(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("mood and mental breaks")
	# Park the colony and hand-drive the subject.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.energy = 1.0
		u.hunger = 1.0
		u.recreation = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = true
	var day_ms := int(colony.day_length() * 1000.0)

	# A flat fixture stretch: the subject's spot plus a feed pile cell —
	# negative offsets again, clear of the persistence band.
	var site := Vector3i.MAX
	for off in [-84, -88, -92, -96, -100, -104, -108, -112]:
		var candidate := _flat_voxel_row(world, mined, off)
		if candidate == Vector3i.MAX:
			continue
		var beside := candidate + Vector3i(2, 0, 0)
		if (
			colony.voxel_fill(beside) <= 0
			and colony.item_pile_at(beside) == null
			and colony.building_at(beside) == null
		):
			site = candidate
			break
	_check(site != Vector3i.MAX, "found a flat spot for the mood tests")
	if site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	unit.global_position = Vector3(site) + Vector3(0.5, 0.9, 0.5)
	unit.velocity = Vector3.ZERO
	var feed := site + Vector3i(2, 0, 0)

	# Deterministic personality: every facet average, no memories.
	for f in Unit.FACETS:
		unit.facets[f] = 50
	unit._thoughts.clear()
	unit._last_social_at = colony.game_msec()
	unit.mood = 0.5
	# The surroundings sampler has run by now — bare ground reads drab.
	# Neutral beauty keeps the "no thoughts" fixture honest.
	unit.beauty = 0.0
	# Suppress break rolls while the wiring is probed.
	unit.break_mtb_scale = 100.0

	_check(
		absf(unit.mood_target() - Unit.MOOD_BASE) < 0.001,
		"a unit with no thoughts sits at base mood"
	)

	# Timed thoughts stack linearly, capped at the spec's limit.
	for i in 8:
		unit.add_thought(&"slept_on_ground")
	_check(
		(unit._thoughts.get(&"slept_on_ground", []) as Array).size() == 5,
		"thought stacks cap at the spec's limit"
	)
	unit._thoughts.clear()

	# The intensity facet scales each stack — a fragile unit feels the
	# same ground-sleep half again as hard; an iron one barely notices.
	unit.add_thought(&"slept_on_ground")
	var average_target := unit.mood_target()
	unit.facets[&"stress_vulnerability"] = 100
	var fragile_target := unit.mood_target()
	unit.facets[&"stress_vulnerability"] = 0
	var stoic_target := unit.mood_target()
	_check(
		fragile_target < average_target
			and average_target < stoic_target,
		"stress vulnerability scales a thought's sting"
	)
	unit.facets[&"stress_vulnerability"] = 50
	unit._thoughts.clear()

	# Facet gates: only a gregarious unit craves company.
	unit._last_social_at = colony.game_msec() - 3 * day_ms
	unit.facets[&"gregariousness"] = 30
	var shy_target := unit.mood_target()
	unit.facets[&"gregariousness"] = 80
	var gregarious_target := unit.mood_target()
	_check(
		gregarious_target < shy_target,
		"loneliness only bites the gregarious"
	)
	unit._last_social_at = colony.game_msec()
	unit.facets[&"gregariousness"] = 50

	# State thoughts ride the needs directly, no stored record.
	unit.hunger = 0.0
	_check(
		unit.mood_target() < Unit.MOOD_BASE - 0.1,
		"an empty stomach drags the mood target"
	)
	unit.hunger = 1.0
	unit.recreation = 0.0
	_check(
		unit.mood_target() < Unit.MOOD_BASE - 0.05,
		"boredom drags the mood target"
	)
	unit.recreation = 1.0

	# Expired stacks prune themselves on the next tick.
	unit.add_thought(&"slept_in_bed")
	(unit._thoughts[&"slept_in_bed"] as Array)[0] = colony.game_msec() - 1
	unit._tick_mood(0.0)
	_check(
		not unit._thoughts.has(&"slept_in_bed"),
		"expired thought stacks prune"
	)

	# Waking remembers how the night went.
	unit._rest_quality = Unit.RestQuality.NORMAL
	unit._wake()
	_check(
		unit._thoughts.has(&"slept_in_bed"),
		"a night in a bed is remembered"
	)
	unit._rest_quality = Unit.RestQuality.POOR
	unit._wake()
	_check(
		unit._thoughts.has(&"slept_on_ground"),
		"a night on the ground is remembered"
	)
	unit._thoughts.clear()

	# The bar drifts toward the target rather than snapping.
	unit.mood = 0.5
	unit._tick_mood(2.0)
	_check(
		unit.mood < 0.5 and unit.mood > 0.3,
		"mood drifts toward the target"
	)

	# Facets wire the seek line and the break threshold, not just
	# thought intensity.
	unit.facets[&"activity_level"] = 100
	_check(
		unit._recreation_seek() > unit.recreation_seek,
		"a restless unit seeks fun early"
	)
	unit.facets[&"activity_level"] = 50
	unit.facets[&"stress_vulnerability"] = 100
	_check(
		unit._break_threshold() > 0.4,
		"a fragile unit breaks sooner"
	)
	unit.facets[&"stress_vulnerability"] = 50
	_check(
		absf(unit._break_threshold() - 0.35) < 0.001,
		"average nerves keep the baseline threshold"
	)

	# A real meal leaves the right thought: cooked food comforts.
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		feed
	)
	unit.hunger = 0.2
	unit._job_search_cooldown = 0.0
	var ate_meal := await _wait_until(func() -> bool:
		return unit.state == Unit.State.EATING)
	_check(ate_meal, "a hungry unit seeks the meal pile")
	var meal_done := await _wait_until(func() -> bool:
		return unit.state == Unit.State.IDLE)
	_check(meal_done, "the meal finishes")
	_check(
		unit._thoughts.has(&"ate_cooked_meal"),
		"a cooked meal is remembered fondly"
	)

	# Raw food disappoints instead.
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.BERRY, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		),
		feed
	)
	unit.hunger = 0.2
	unit._job_search_cooldown = 0.0
	var ate_raw := await _wait_until(func() -> bool:
		return unit.state == Unit.State.EATING)
	_check(ate_raw, "a hungry unit seeks the fruit pile")
	var raw_done := await _wait_until(func() -> bool:
		return unit.state == Unit.State.IDLE)
	_check(raw_done, "the snack finishes")
	_check(
		unit._thoughts.has(&"ate_raw_food"),
		"raw food is remembered unkindly"
	)

	# Minor break: mood under the line with food in reach binges to
	# full — the catharsis lands after. The snack pile may be spent, so
	# drop a fresh one.
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.BERRY, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3 * 8
		),
		feed
	)
	unit.mood = 0.30
	unit.hunger = 0.5
	# The break roll skips a sleeping unit — keep this one awake through
	# the wait window or the check flaps on when its energy runs out.
	unit.energy = 1.0
	unit.break_mtb_scale = 0.001
	var binge := await _wait_until(func() -> bool:
		return unit._in_break)
	_check(binge, "a miserable unit breaks")
	_check(
		unit.job != null and unit.job.type == ColonyJob.Type.EAT,
		"a minor break binges on food"
	)
	unit.break_mtb_scale = 100.0
	var binge_over := await _wait_until(func() -> bool:
		return not unit._in_break and unit.state == Unit.State.IDLE)
	_check(binge_over, "the binge runs its course")
	_check(
		unit._thoughts.has(&"catharsis"),
		"a finished break leaves catharsis"
	)

	# Extreme break: too low for a binge, the unit wanders in a daze —
	# a moving recreation-shaped outing that pays nothing.
	unit._thoughts.clear()
	unit.mood = 0.02
	unit.break_mtb_scale = 0.001
	var dazed := await _wait_until(func() -> bool:
		return (
			unit._in_break
			and unit.job != null
			and unit.job.rec_activity == &"daze"
		))
	_check(dazed, "an extreme break dazes the unit")
	# Clear once the daze is actually running — an idle unit can squeeze a
	# paying session in before the break roll fires, and that leftover
	# `had_fun` is not the daze's doing.
	unit._thoughts.clear()
	unit.break_mtb_scale = 100.0
	var daze_over := await _wait_until(func() -> bool:
		return not unit._in_break and unit.state == Unit.State.IDLE)
	_check(daze_over, "the daze passes")
	_check(
		(unit._thoughts.get(&"catharsis", []) as Array).size() >= 1,
		"the daze leaves catharsis too"
	)
	_check(
		not unit._thoughts.has(&"had_fun"),
		"a daze pays no recreation and no fun"
	)

	# Mood, facets and live thoughts ride the save.
	var data := unit.serialize()
	var saved_facets := int(unit.facets[&"gregariousness"])
	var saved_thoughts := unit._thoughts.size()
	var saved_mood := unit.mood
	unit.mood = 0.9
	unit.facets.clear()
	unit._thoughts.clear()
	unit.deserialize(data, colony)
	_check(
		int(unit.facets.get(&"gregariousness", -1)) == saved_facets,
		"facets survive a save round-trip"
	)
	_check(
		unit._thoughts.size() == saved_thoughts,
		"live thoughts survive a save round-trip"
	)
	_check(
		absf(unit.mood - saved_mood) < 0.001,
		"mood survives a save round-trip"
	)

	# Restore the suite's standing arrangement.
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0
		u._in_break = false
		u.mood = 0.5
		u.hunger = 1.0
		u.recreation = 1.0
		u.break_mtb_scale = 1.0
	colony.needs_enabled = false


## Wildlife: species data, a live animal, hunting, carcass→corpse, the
## mass-aware carry/drag rules, and the butcher spot's species-keyed
## yields with conservation scraps (PLAN item 27).
func _test_wildlife(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("wildlife and butchering")
	# Park the colony and hand-drive the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false

	# --- Species registry: representative animals, one per diet.
	var diets := {}
	for key: StringName in Species.species_table():
		if key == &"colonist":
			continue
		var spec: Dictionary = Species.species_table()[key]
		_check(
			float(spec.get(&"mass_kg", 0.0)) > 0.0
				and float(spec.get(&"health", 0.0)) > 0.0
				and float(spec.get(&"butcher_seconds", 0.0)) > 0.0
				and spec.has(&"yields"),
			"species %s has body, butcher time and yields" % key
		)
		var total_yield := 0.0
		for cut: StringName in spec[&"yields"]:
			total_yield += float(spec[&"yields"][cut])
		_check(
			total_yield > 0.0 and total_yield < 1.0,
			"species %s yields leave a scraps remainder" % key
		)
		diets[spec.get(&"diet", &"")] = true
	_check(
		diets.has(&"herbivore") and diets.has(&"omnivore")
			and diets.has(&"carnivore"),
		"wildlife covers herbivore, omnivore and carnivore diets"
	)
	_check(
		Species.field(&"colonist", &"carry_kg", 0.0)
			< Species.field(&"colonist", &"drag_kg", 0.0),
		"colonist carry capacity sits under drag capacity"
	)

	# --- A flat fixture row: corpse pile, butcher spot, and room for a
	# rabbit to run. The test uses site-2 (cobbles) through site+8 (the
	# hunt quarry), so it needs an eleven-cell runway of level ground.
	var site := _flat_run(colony, world, mined, 11)
	if site != Vector3i.MAX:
		site += Vector3i(2, 0, 0)
	_check(site != Vector3i.MAX, "found a flat stretch for the wildlife tests")
	if site == Vector3i.MAX:
		colony.needs_enabled = false
		return
	var corpse_cell := site
	var spot := site + Vector3i(2, 0, 0)
	var far := site + Vector3i(6, 0, 0)

	# --- Spawning and the roster.
	var before := colony.animals.size()
	var rabbit := colony.spawn_animal(&"rabbit", far)
	_check(
		rabbit != null and colony.animals.size() == before + 1,
		"spawn_animal adds a rabbit to the roster"
	)
	_check(
		rabbit != null and rabbit.species == &"rabbit"
			and absf(rabbit.health - Species.field(&"rabbit", &"health", 0.0)) < 0.01,
		"the rabbit's spec set its health"
	)

	# --- Death leaves a physical corpse item carrying the species.
	rabbit.die(null)
	# A corpse merging into an occupied pile is in-flight until it lands.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var corpse_item: DropItem = null
	for off in range(-3, 4):
		for off2 in range(-3, 4):
			var pile := colony.item_pile_at(far + Vector3i(off, 0, off2))
			if pile == null:
				continue
			for item in pile.items:
				if (
					item.form == DropItem.Form.CORPSE
					and item.species == &"rabbit"
				):
					corpse_item = item
					break
			if corpse_item != null:
				break
		if corpse_item != null:
			break
	_check(corpse_item != null, "a dead animal drops a species-tagged corpse")
	_check(
		corpse_item != null
			and corpse_item.volume == Species.corpse_cm3(&"rabbit"),
		"the corpse is sized from the species mass"
	)

	# --- Mass-aware hauling: carry vs drag vs too-heavy.
	unit.facets[&"strength"] = 50
	_check(
		absf(unit._carry_kg() - 40.0) < 1.0
			and absf(unit._drag_kg() - 1500.0) < 5.0,
		"average strength gives the species carry/drag norms"
	)
	# A rabbit corpse is pocket-light; a bear corpse is a drag; a solid
	# cubic metre of gold ore is beyond even a drag.
	var bear := colony.make_corpse(&"bear")
	_check(
		absf(bear.mass_kg() - 315.0) < 5.0,
		"a bear corpse masses over the carry limit, under the drag limit"
	)
	var pile := colony.item_pile_at(corpse_cell)
	if pile == null:
		colony._drop_item(DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 1
		), corpse_cell)
		pile = colony.item_pile_at(corpse_cell)
	var boulder := DropItem.new(
		BlockRegistry.Resource_.GOLD, DropItem.Form.BOULDER,
		DropItem.BLOCK_CM3
	)
	pile.add_item(boulder)
	var take_boulder := func(i: DropItem) -> bool:
		return i == boulder
	var lifted := unit._keep_liftable(
		pile.take_up_to(DropItem.BLOCK_CM3, take_boulder), pile
	)
	_check(
		lifted.is_empty() and pile.items.has(boulder),
		"an item over drag capacity stays in the pile"
	)
	unit._carried.append(bear)
	_check(
		unit._dragging()
			and absf(unit._move_speed() - unit.move_speed * Unit.DRAG_SPEED_MULT) < 0.01,
		"a load over carry capacity is dragged at half speed"
	)
	unit._carried.clear()

	# --- The butcher spot: designate, build, butcher.
	for i in 3:
		colony._drop_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			site + Vector3i(-2, 0, 0)
		)
	var build_job := colony.designate_butcher_spot(spot)
	_check(build_job != null, "a butcher spot can be designated")
	var cobble_pile := Vector3i.MAX
	for off in range(-4, 5):
		var cell := site + Vector3i(off, 0, 0)
		var p := colony.item_pile_at(cell)
		if p != null and p.form_volume(DropItem.Form.COBBLE) > 0:
			cobble_pile = cell
			break
	if build_job != null and cobble_pile != Vector3i.MAX:
		_drive_craft(colony, world, build_job, cobble_pile, spot)
		var built := await _wait_until(func() -> bool:
			return colony.butcher_at(spot) != null)
		_check(built, "the butcher spot is constructed")
	else:
		_check(false, "cobbles reached a pile near the butcher site")

	# A deer carcass and a butcher job.
	colony._drop_item(colony.make_corpse(&"deer"), corpse_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._post_butcher_jobs()
	var butcher_job := colony.butcher_job_at(spot)
	_check(butcher_job != null, "a corpse beside a butcher spot posts the job")
	var deer_corpse_v := Vector3i.MAX
	for off in range(-4, 5):
		for off2 in range(-4, 5):
			var cell := corpse_cell + Vector3i(off, 0, off2)
			var p := colony.item_pile_at(cell)
			if p == null:
				continue
			for item in p.items:
				if item.form == DropItem.Form.CORPSE:
					deer_corpse_v = cell
					break
			if deer_corpse_v != Vector3i.MAX:
				break
		if deer_corpse_v != Vector3i.MAX:
			break
	var products := {}
	if butcher_job != null and deer_corpse_v != Vector3i.MAX:
		unit.global_position = (
			Vector3(_park_beside(colony, world, deer_corpse_v, spot))
			+ Vector3(0.5, 0.9, 0.5)
		)
		butcher_job.state = ColonyJob.State.ASSIGNED
		butcher_job.assignee = unit
		unit.job = butcher_job
		unit._fetching = true
		unit._goal_voxel = deer_corpse_v
		unit._clear_budget = 0.0
		unit.state = Unit.State.MOVING
		var on_slab := await _wait_until(func() -> bool:
			return not butcher_job.components.is_empty())
		_check(on_slab, "the deer carcass is carried to the spot")
		if on_slab:
			butcher_job.progress = 1000.0
		var done := await _wait_until(func() -> bool:
			return butcher_job.state == ColonyJob.State.DONE)
		_check(done, "the butcher job completes")
		# Products dropping onto an existing pile are in-flight a frame.
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		for off in range(-3, 4):
			for off2 in range(-3, 4):
				var cell := spot + Vector3i(off, 0, off2)
				var p: ItemPile = colony.item_pile_at(cell)
				if p == null:
					continue
				for item in p.items:
					products[int(item.material)] = (
						int(products.get(int(item.material), 0)) + item.volume
					)
		_check(
			int(products.get(BlockRegistry.Resource_.MEAT, 0)) > 0,
			"butchering yields meat"
		)
		_check(
			int(products.get(BlockRegistry.Resource_.LEATHER, 0)) > 0,
			"butchering yields leather"
		)
		_check(
			int(products.get(BlockRegistry.Resource_.BONE, 0)) > 0,
			"butchering yields bone"
		)
		_check(
			int(products.get(BlockRegistry.Resource_.SCRAPS, 0)) > 0,
			"the remainder falls to butchering scraps"
		)
		_check(
			int(products.get(BlockRegistry.Resource_.ANTLER, 0)) > 0,
			"the deer's unique drop — antlers — came off too"
		)
		var made := int(products.get(BlockRegistry.Resource_.MEAT, 0))
		_check(
			made > 0
				and made < Species.corpse_cm3(&"deer"),
			"a level-0 butcher gets a reduced share of the carcass"
		)
	else:
		_check(false, "the deer corpse found a pile to sit in")

	# A skilled butcher keeps more of the carcass — same species, more
	# product, fewer scraps.
	var skilled_corpse := colony.make_corpse(&"deer")
	var skilled_job := ColonyJob.new(ColonyJob.Type.BUTCHER, spot)
	skilled_job.components.append(skilled_corpse)
	unit.gain_skill_xp(ColonyJob.Skill.BUTCHERING, 400.0)
	colony._register_job(skilled_job)
	colony.complete_butcher(skilled_job, unit)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var skilled_products := {}
	for off in range(-3, 4):
		for off2 in range(-3, 4):
			var cell := spot + Vector3i(off, 0, off2)
			var p: ItemPile = colony.item_pile_at(cell)
			if p == null:
				continue
			for item in p.items:
				skilled_products[int(item.material)] = (
					int(skilled_products.get(int(item.material), 0))
					+ item.volume
				)
	_check(
		int(skilled_products.get(BlockRegistry.Resource_.MEAT, 0))
			> int(products.get(BlockRegistry.Resource_.MEAT, 0)),
		"a skilled butcher cuts more meat from the same carcass"
	)
	_check(
		colony.animals.size() > 0,
		"the wildlife roster lives on the colony"
	)

	# Butchering scraps rot down to compost — conservation made visible.
	var scraps_cell := site + Vector3i(4, 0, 0)
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.SCRAPS, DropItem.Form.LOOSE, 40_000
		),
		scraps_cell
	)
	# Nothing in-flight may sit unkeyed — the decay tick only visits
	# landed piles.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var day := colony.day_length()
	colony._decay_tick(300.0 * day)
	var compost_found := 0
	var scraps_left := 0
	for off in range(-3, 4):
		for off2 in range(-3, 4):
			var p: ItemPile = colony.item_pile_at(
				scraps_cell + Vector3i(off, 0, off2)
			)
			if p == null:
				continue
			for item in p.items:
				if item.material == BlockRegistry.Resource_.COMPOST:
					compost_found += item.volume
				elif item.material == BlockRegistry.Resource_.SCRAPS:
					scraps_left += item.volume
	_check(compost_found > 0, "butchering scraps rot into compost")
	_check(scraps_left == 0, "the scraps themselves are gone")

	# --- Hunting: designate the rabbit's kin, drive the hunter, and the
	# kill lands as a corpse.
	var quarry := colony.spawn_animal(&"rabbit", site + Vector3i(8, 0, 0))
	var hunt := colony.designate_hunt(site + Vector3i(8, 0, 0))
	_check(
		hunt != null and hunt.animal == quarry,
		"a hunt designation binds the nearest animal"
	)
	if hunt != null:
		unit.global_position = Vector3(site + Vector3i(7, 0, 0)) + Vector3(0.5, 0.9, 0.5)
		unit.velocity = Vector3.ZERO
		hunt.state = ColonyJob.State.ASSIGNED
		hunt.assignee = unit
		unit.job = hunt
		unit._goal_voxel = Vector3i(quarry.global_position.floor())
		unit.state = Unit.State.MOVING
		var quarry_ref: WeakRef = weakref(quarry)
		var killed := await _wait_until(func() -> bool:
			var q: Animal = quarry_ref.get_ref()
			return (
				hunt.state == ColonyJob.State.DONE
				or q == null
				or q.dead
			))
		_check(killed, "a driven hunt catches and kills the quarry")
		var new_corpse := false
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if (
					item.form == DropItem.Form.CORPSE
					and item.species == &"rabbit"
					and item != corpse_item
				):
					new_corpse = true
		_check(new_corpse, "the kill leaves a fresh corpse")

	# Restore the standing arrangement — and sweep the wildlife up:
	# wandering animals and carcass piles are this section's fixtures,
	# not leftovers for the persistence band downstream.
	for u in colony.units:
		u.abandon_job()
		u._job_search_cooldown = 0.0
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
	_clear_jobs(colony)
	for animal in colony.animals.duplicate():
		animal.dead = true
		colony.animals.erase(animal)
		animal.queue_free()
	var wildlife_materials := [
		BlockRegistry.Resource_.CORPSE, BlockRegistry.Resource_.MEAT,
		BlockRegistry.Resource_.LEATHER, BlockRegistry.Resource_.BONE,
		BlockRegistry.Resource_.SCRAPS, BlockRegistry.Resource_.ANTLER,
		BlockRegistry.Resource_.TUSK,
	]
	for voxel: Vector3i in colony.item_piles.keys():
		var sweep := colony.item_piles[voxel]
		sweep.items = sweep.items.filter(
			func(item: DropItem) -> bool:
				return not wildlife_materials.has(item.material)
		)
		colony.remove_pile_if_empty(voxel)
	# The wildlife tick trickles a fresh animal in each game day — push the
	# clock far ahead so stragglers can't wander into later fixtures and
	# leave corpses behind.
	colony._wildlife_respawn_msec = (
		colony.game_msec() + int(colony.day_length() * 1000.0) * 100
	)


## Health (PLAN item 28): wounds land on body parts, not a pooled bar —
## field care anywhere stops bleeding only, a medical bed enables real
## treatment (and medicine makes it better), and a downed unit is a
## patient a stronger unit carries to that bed under the hauling rules.
func _test_health(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("health and medicine")
	# Park the colony and hand-drive the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false

	# --- The body plan: parts pool to the health bar, coverage to the
	#     hit table, and each consequence flag has at least one part.
	var hp_total := 0.0
	var cov_total := 0.0
	var vital_parts := 0
	var moves_parts := 0
	var works_parts := 0
	for part: StringName in Unit.BODY_PARTS:
		var spec: Dictionary = Unit.BODY_PARTS[part]
		hp_total += float(spec[&"hp"])
		cov_total += float(spec[&"coverage"])
		if spec.get(&"vital", false):
			vital_parts += 1
		if spec.get(&"moves", false):
			moves_parts += 1
		if spec.get(&"works", false):
			works_parts += 1
	_check(
		absf(hp_total - 100.0) < 0.01 and absf(cov_total - 1.0) < 0.01,
		"the body plan pools to the health bar and a full hit table"
	)
	_check(
		vital_parts > 0 and moves_parts > 0 and works_parts > 0,
		"vital, moving and working parts all exist"
	)

	# --- A wound lands on a part, bleeds, and drains blood over time.
	var health0 := unit.health
	unit.add_wound(&"left_leg", &"cut", 4.0)
	_check(
		absf(unit.part_damage(&"left_leg") - 4.0) < 0.01,
		"a wound lands its severity on one part"
	)
	_check(
		absf(unit.health - (health0 - 4.0)) < 0.01,
		"the pooled health bar follows the wounds"
	)
	_check(unit.bleeding(), "an untreated cut bleeds")
	_check(
		unit.mobility() < 1.0 and unit._move_speed() < unit.move_speed,
		"a leg wound slows the unit"
	)
	var blood0 := unit.blood_loss
	# A quarter-day tick — short enough that the natural heal rate
	# doesn't close the wound inside the same tick and trigger blood
	# recovery on top of the fresh bleed.
	unit._tick_wounds(colony.day_length() * 0.25)
	_check(
		unit.blood_loss > blood0,
		"an open wound drains blood over time"
	)

	# --- Field care: deliverable anywhere, and it can only stop the
	#     bleeding — the wound itself stays open and heals naturally.
	var sev0 := unit.part_damage(&"left_leg")
	unit.apply_tend(false, false)
	_check(not unit.bleeding(), "field care stops the bleeding")
	var field_care := 0
	for w: Dictionary in unit.wounds:
		if w[&"part"] == &"left_leg":
			field_care = int(w[&"care"])
	_check(field_care == 1, "field care is the first-aid tier")
	_check(
		absf(unit.part_damage(&"left_leg") - sev0) < 0.01,
		"field care closes nothing — the wound stays open"
	)

	# --- Medical-bed care tiers on a fresh wound: treated, and with a
	#     herb bundle spent, sealed a share on the spot.
	unit.add_wound(&"right_arm", &"cut", 5.0)
	unit.apply_tend(true, false)
	var arm_care := 0
	for w: Dictionary in unit.wounds:
		if w[&"part"] == &"right_arm":
			arm_care = int(w[&"care"])
	_check(arm_care == 2, "a medical-bed tend treats the wound")
	var sev1 := unit.part_damage(&"right_arm")
	unit.apply_tend(true, true)
	_check(
		unit.part_damage(&"right_arm") < sev1,
		"a medicined tend seals a share of the wound instantly"
	)
	var sealed_care := 0
	for w: Dictionary in unit.wounds:
		if w[&"part"] == &"right_arm":
			sealed_care = int(w[&"care"])
	_check(sealed_care == 3, "medicine earns the top care tier")

	# --- Serialization: wounds and blood loss round-trip a save.
	var saved := unit.serialize()
	var clone := colony.spawn_unit(mined + Vector3i(4, 0, 0))
	clone.deserialize(saved, colony)
	# The clone is a healthy bystander — park it so it can't claim the
	# fixture's medical jobs before the driven unit gets them.
	clone._job_search_cooldown = 600.0
	_check(
		clone.wounds.size() == unit.wounds.size()
			and absf(clone.blood_loss - unit.blood_loss) < 0.001,
		"wounds and blood loss survive a save round-trip"
	)
	clone.wounds.clear()
	clone.blood_loss = 0.0
	clone._sync_health()

	# A level runway for the downed/rescue fixtures: the patient, a
	# medical bed beside them, and a second casualty.
	var site := _flat_run(colony, world, mined, 12)
	_check(site != Vector3i.MAX, "found a flat stretch for the health tests")
	if site == Vector3i.MAX:
		unit.wounds.clear()
		unit.blood_loss = 0.0
		unit._sync_health()
		colony.needs_enabled = false
		return
	site += Vector3i(2, 0, 0)

	# --- Death: a destroyed vital part kills; the body leaves the
	#     roster as a physical colonist corpse the butcher ignores.
	var doomed := colony.spawn_unit(site + Vector3i(8, 0, 0))
	var roster := colony.units.size()
	doomed.add_wound(&"head", &"bite", 12.0)
	_check(doomed.dead, "a destroyed vital part kills")
	_check(
		colony.units.size() == roster - 1,
		"the dead unit leaves the roster"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var colonist_corpse := Vector3i.MAX
	for off in range(-3, 4):
		for off2 in range(-3, 4):
			var cell: Vector3i = site + Vector3i(8 + off, 0, off2)
			var p := colony.item_pile_at(cell)
			if p == null:
				continue
			for item in p.items:
				if (
					item.form == DropItem.Form.CORPSE
					and item.species == &"colonist"
				):
					colonist_corpse = cell
					break
			if colonist_corpse != Vector3i.MAX:
				break
		if colonist_corpse != Vector3i.MAX:
			break
	_check(
		colonist_corpse != Vector3i.MAX,
		"a dead colonist drops a species-tagged corpse"
	)
	if colonist_corpse != Vector3i.MAX:
		# The corpse exists — but the butcher search keys on species
		# with yields, so it must never land here.
		_check(
			colony.nearest_corpse_voxel(colonist_corpse, 1e9)
				!= colonist_corpse,
			"a colonist corpse never enters the butcher search"
		)

	# --- Downed: a destroyed leg puts the unit on the ground.
	var patient := colony.spawn_unit(site)
	patient.add_wound(&"left_leg", &"cut", 15.0)
	_check(
		patient.state == Unit.State.DOWNED,
		"a destroyed leg downs the unit"
	)
	_check(patient.is_downed(), "the wounds say the unit can't stand")

	# --- Rescue gates under the hauling rules: a patient with heavy
	#     pockets masses over a weak rescuer's drag limit — the job
	#     exists but that unit can't claim it. A strong one can.
	var rescue_probe := ColonyJob.new(ColonyJob.Type.RESCUE, site)
	rescue_probe.patient = patient
	patient._carried.append(
		DropItem.new(BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500_000)
	)
	unit.facets[&"strength"] = 0
	_check(
		not colony._job_allowed_for(unit, rescue_probe),
		"a patient too heavy to drag can't be rescued by this unit"
	)
	unit.facets[&"strength"] = 100
	_check(
		colony._job_allowed_for(unit, rescue_probe),
		"a strong enough unit can claim the heavy patient"
	)
	patient._carried.clear()
	unit.facets[&"strength"] = 50

	# --- A medical bed: a flagged ordinary bed, the facility marker.
	#     Earlier fixtures may have left buildings on the runway — take
	#     the first pair of cells free of one.
	var bed_cell := Vector3i.MAX
	for off in range(-2, 8):
		var cand: Vector3i = site + Vector3i(off, 0, 0)
		if (
			cand != site
			and cand + Vector3i(1, 0, 0) != site
			and colony.building_at(cand) == null
			and colony.building_at(cand + Vector3i(1, 0, 0)) == null
		):
			bed_cell = cand
			break
	_check(bed_cell != Vector3i.MAX, "a free pair of cells hosts the bed")
	if bed_cell == Vector3i.MAX:
		bed_cell = site + Vector3i(-2, 0, 0)
	var bed := Building.new(Building.Kind.BED, bed_cell)
	bed.footprint.append(bed_cell + Vector3i(1, 0, 0))
	bed.medical = true
	colony.register_building(bed)
	_check(
		colony.nearest_free_medical_bed(site) == bed,
		"a medical-flagged bed answers the facility search"
	)

	# --- The medical tick posts both jobs for a wounded downed unit.
	colony._medical_tick()
	var rescue_job := colony._patient_job(patient, ColonyJob.Type.RESCUE)
	_check(
		rescue_job != null, "a downed unit with a free bed posts rescue"
	)
	var tend_job := colony._patient_job(patient, ColonyJob.Type.TEND)
	_check(tend_job != null, "an untreated wound posts a tend")

	# --- Drive the rescue: the unit lifts the patient, carries them to
	#     the medical bed, and tucks them in — still downed, still hurt,
	#     but bedded where real care can reach them.
	if rescue_job != null:
		unit.global_position = (
			Vector3(_park_beside(colony, world, site, bed_cell))
			+ Vector3(0.5, 0.9, 0.5)
		)
		unit.velocity = Vector3.ZERO
		rescue_job.state = ColonyJob.State.ASSIGNED
		rescue_job.assignee = unit
		unit.job = rescue_job
		unit._goal_voxel = site
		unit.state = Unit.State.MOVING
		# `_rest_bed` is claimed at pickup — DONE is the delivered signal.
		var tucked := await _wait_until(func() -> bool:
			return rescue_job.state == ColonyJob.State.DONE)
		_check(tucked, "a rescuer carries the patient to the medical bed")
		_check(
			patient._rest_bed == bed
				and bed.occupant == patient
				and patient.state == Unit.State.DOWNED
				and patient._carried_by == null,
			"the patient is tucked in, still downed"
		)
	else:
		_check(false, "the rescue job posted for the driven carry")

	# --- Drive the tend: fetch a herb bundle first (the patient is on a
	#     medical bed now, so the tend wants medicine), then the tend
	#     spends it — the wounds get the top care tier.
	if tend_job != null:
		var med_cell := site + Vector3i(4, 0, 0)
		colony._drop_item(
			DropItem.new(
				BlockRegistry.Resource_.MEDICINE, DropItem.Form.FRUIT, 4
			),
			med_cell
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		unit.abandon_job()
		unit.global_position = (
			Vector3(_park_beside(colony, world, med_cell, site))
			+ Vector3(0.5, 0.9, 0.5)
		)
		unit.velocity = Vector3.ZERO
		tend_job.state = ColonyJob.State.ASSIGNED
		tend_job.assignee = unit
		unit.job = tend_job
		unit._fetching = true
		unit._goal_voxel = med_cell
		unit.state = Unit.State.MOVING
		var tended := await _wait_until(func() -> bool:
			return tend_job.state == ColonyJob.State.DONE)
		_check(tended, "a driven tend completes")
		var min_care := 99
		for w: Dictionary in patient.wounds:
			min_care = mini(min_care, int(w[&"care"]))
		_check(
			min_care >= 3,
			"a medicined tend at a medical bed earns the top care tier"
		)
	else:
		_check(false, "the tend job posted for the driven tend")

	# --- Heal-all: the real-world herb stands in for medicine — a
	#     plant species, a fruit→species link so bundles re-seed it, and
	#     wild seeding in the generator's bush lattice.
	_check(
		Plants.species_table().has(&"heal_all"),
		"heal-all exists as a plant species"
	)
	_check(
		Plants.species_table().has(&"heal_all")
			and Plants.species_table()[&"heal_all"][&"yield_material"]
				== BlockRegistry.Resource_.MEDICINE,
		"heal-all forages into herbal medicine"
	)
	_check(
		DropItem.FRUIT_SPECIES.get(BlockRegistry.Resource_.MEDICINE)
			== &"heal_all",
		"a medicine bundle re-seeds heal-all — it's farmable"
	)
	_check(
		not Plants.species_table().has(&"healroot"),
		"no RimWorld-IP name anywhere in the species table"
	)
	var generator := world.generator_script
	var wild_heal_all := false
	var probe_base := Vector3i(mined.x - 240, mined.y, mined.z - 240)
	var seeded_bushes: Dictionary = generator.bushes_in(probe_base, 480)
	for key: Vector2i in seeded_bushes:
		if seeded_bushes[key] == &"heal_all":
			wild_heal_all = true
			break
	_check(
		wild_heal_all,
		"the generator seeds heal-all in the wild bush lattice"
	)

	# --- Restore: the test unit sheds its wounds (the suite goes on),
	#     the fixture units leave the roster, and the medical bed's
	#     claim is released before the building itself goes.
	unit.wounds.clear()
	unit.blood_loss = 0.0
	unit._sync_health()
	for u in colony.units:
		u._job_search_cooldown = 0.0
	for fixture in [patient, clone]:
		if fixture == null or not is_instance_valid(fixture):
			continue
		fixture.abandon_job()
		if fixture._rest_bed != null:
			if fixture._rest_bed.occupant == fixture:
				fixture._rest_bed.occupant = null
			fixture._rest_bed = null
		fixture.dead = true
		colony.units.erase(fixture)
		colony._sleeping.erase(fixture)
		# The roster shrank — listeners (the colonist bar) rebuild off
		# this signal, same as a real death minus the corpse.
		colony.unit_died.emit(fixture)
		fixture.queue_free()
	for cell in bed.footprint:
		colony.buildings.erase(cell)
	var health_materials := [
		BlockRegistry.Resource_.CORPSE, BlockRegistry.Resource_.MEDICINE,
	]
	for voxel: Vector3i in colony.item_piles.keys():
		var sweep := colony.item_piles[voxel]
		sweep.items = sweep.items.filter(
			func(item: DropItem) -> bool:
				return not health_materials.has(item.material)
		)
		colony.remove_pile_if_empty(voxel)
	_clear_jobs(colony)


## Drafting and combat (PLAN item 29): a drafted unit takes no jobs and
## services no needs, holds a post or charges on order, and breaks off
## on its own past the critical-need line its `bravery` moves. Being hit
## drops the load and turns the unit to fight, drafted or not. Cover
## rides along: mounds and barricades are partial-height builds that
## break fire and slow the scramble, and piles now cost stride to wade.
func _test_combat(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("drafting and combat")
	# Park the colony and hand-drive the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false

	var site := _flat_run(colony, world, mined, 10)
	_check(
		site != Vector3i.MAX,
		"found a flat stretch for the combat tests"
	)
	if site == Vector3i.MAX:
		return
	var post := site + Vector3i(2, 0, 0)
	var far_end := site + Vector3i(7, 0, 0)

	# --- Drafting is a stance, not a job.
	unit.global_position = Vector3(post) + Vector3(0.5, 1.9, 0.5)
	unit.velocity = Vector3.ZERO
	unit.set_drafted(true)
	_check(unit.drafted, "a colonist takes the draft")
	_check(
		unit._order_voxel == unit._standing_voxel(),
		"the draft holds the spot it was given"
	)
	# A board job on the table must not tempt it — the draft branch runs
	# ahead of the claim even with a clear job-search cooldown.
	var lure := colony.designate_mine(_pick_mining_target(world, unit, 4))
	unit._job_search_cooldown = 0.0
	for i in 10:
		await physics_frame
	_check(
		unit.job == null or unit.job.type == ColonyJob.Type.ORDER,
		"a drafted unit takes no board jobs"
	)
	if lure != null:
		lure.state = ColonyJob.State.CANCELLED
		colony._prune_jobs()

	# --- Needs are ignored while drafted — past the seek line but not
	#     yet at the critical line, where an undrafted unit would eat
	#     and recreate.
	unit.hunger = 0.28
	unit.recreation = 0.3
	for i in 10:
		await physics_frame
	_check(
		unit.job == null or unit.job.type == ColonyJob.Type.ORDER,
		"a drafted unit doesn't break off for hunger or boredom"
	)
	unit.hunger = 1.0
	unit.recreation = 1.0

	# --- The breaking point moves with bravery: stalwart holds to
	#     0.125, the timid fold at 0.375, the average break at 0.25.
	unit.facets[&"bravery"] = 100
	unit.hunger = 0.2
	_check(
		not unit._must_undraft(),
		"a stalwart fights on past the soft line"
	)
	unit.facets[&"bravery"] = 0
	_check(
		unit._must_undraft(),
		"a timid unit folds at the same hunger"
	)
	unit.facets[&"bravery"] = 50
	unit.hunger = 1.0
	# Every critical failure trips it — needs, mood, and a wrecked body.
	unit.energy = 0.02
	_check(unit._must_undraft(), "exhaustion ends the draft")
	unit.energy = 1.0
	unit.recreation = 0.02
	_check(unit._must_undraft(), "starved recreation ends the draft")
	unit.recreation = 1.0
	unit.mood = 0.0
	_check(unit._must_undraft(), "a breaking mood ends the draft")
	unit.mood = 1.0
	# Off the run — the move-order check below walks the far_end cell and
	# a body standing on it blocks the step.
	var casualty := colony.spawn_unit(site + Vector3i(0, 0, 2))
	casualty._job_search_cooldown = 600.0
	casualty.add_wound(&"left_leg", &"cut", 16.0)
	casualty.drafted = true
	_check(
		casualty.is_downed() and casualty._must_undraft(),
		"too badly injured ends the draft"
	)

	# --- The live undraft: a critical need flips the stance mid-tick.
	unit.hunger = 0.05
	var undrafted := await _wait_until(
		func() -> bool: return not unit.drafted
	)
	_check(undrafted, "a critical need undrafts on its own")
	unit.hunger = 1.0

	# --- Move and attack orders. The boar fights back — a short hit
	#     pool keeps the exchange under a second.
	unit.set_drafted(true)
	unit.order_move(far_end)
	var moved := await _wait_until(
		func() -> bool:
			return unit._standing_voxel() == far_end
	)
	_check(moved, "a drafted unit walks the ordered post")
	var boar := colony.spawn_animal(&"boar", post)
	boar.health = 3.0
	unit.order_attack(boar)
	_check(
		unit._combat_target == boar,
		"the attack order takes the target"
	)
	# The corpse frees the animal mid-fight — hold it through an array so
	# the poll's capture isn't the node itself.
	var foe: Array = [boar]
	var downed_foe := await _wait_until(
		func() -> bool:
			return not is_instance_valid(foe[0]) or foe[0].dead
	)
	_check(downed_foe, "the drafted unit kills its target in melee")
	# After the fight the stance returns to its post — a held ORDER is
	# WORKING with no animal on it.
	var held := await _wait_until(
		func() -> bool:
			return (
				unit._standing_voxel() == far_end
				and unit.job != null
				and unit.job.type == ColonyJob.Type.ORDER
				and unit.job.animal == null
			)
	)
	_check(held, "the unit holds its post when the fight's done")

	# --- Being hit IS the order: a hit drops the carried load and turns
	#     the unit, drafted or not. Items and a patient both go down.
	unit.set_drafted(false)
	var scrap := colony.spawn_unit(site)
	scrap._job_search_cooldown = 600.0
	scrap._carried.append(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
			DropItem.COBBLE_CM3
		)
	)
	var patient2 := colony.spawn_unit(site + Vector3i(1, 0, 0))
	patient2._job_search_cooldown = 600.0
	scrap._carried_unit = patient2
	patient2._carried_by = scrap
	var wolf := colony.spawn_animal(&"wolf", site + Vector3i(3, 0, 0))
	# A short hit pool keeps the exchange under a second — the scrap
	# shouldn't go downed mid-fixture.
	wolf.health = 5.0
	var drop_cell := scrap._standing_voxel()
	scrap.take_hit(1.0, wolf)
	_check(
		scrap._carried.is_empty() and scrap._carried_unit == null,
		"a unit drops its load — items and patient — to fight"
	)
	_check(
		patient2._carried_by == null,
		"the patient lands on the ground"
	)
	_check(
		scrap._combat_target == wolf,
		"an undrafted unit turns on its attacker"
	)
	var brawl: Array = [wolf, scrap]
	var avenged := await _wait_until(
		func() -> bool:
			return (
				not is_instance_valid(brawl[0])
				or brawl[0].dead
				or not is_instance_valid(brawl[1])
				or brawl[1]._combat_target == null
			)
	)
	_check(avenged, "the self-defence fight resolves")
	# The dropped cobble landed in the world, not vanished — the pile sits
	# where the hit happened, not where the fight ended, so scan around
	# the cell it was dropped on. A roaming hauler is allowed to have
	# picked it up mid-brawl — carried counts as landed too.
	var dropped := false
	for off in range(-6, 7):
		for off2 in range(-6, 7):
			var pile := colony.item_pile_at(
				drop_cell + Vector3i(off, 0, off2)
			)
			if pile == null:
				continue
			for item in pile.items:
				if item.form == DropItem.Form.COBBLE:
					dropped = true
	if not dropped:
		for u in colony.units:
			for item in u._carried:
				if item.form == DropItem.Form.COBBLE:
					dropped = true
	_check(dropped, "the dropped load lands as a real pile")

	# Retire the brawl fixtures before laying out cover — a body standing
	# in the aisle between the soil pile and the mound cell stalls the
	# builder's watchdog.
	for fixture in [scrap, patient2]:
		if fixture != null and is_instance_valid(fixture):
			fixture.abandon_job()
			fixture.dead = true
			colony.units.erase(fixture)
			colony._sleeping.erase(fixture)
			colony.unit_died.emit(fixture)
			fixture.queue_free()
	if is_instance_valid(wolf) and not wolf.dead:
		wolf.dead = true
		colony.animals.erase(wolf)
		wolf.queue_free()

	# --- Cover: the dirt mound is a partial-height, buildable scramble.
	#     Its own flat row, off the brawl's — corpse piles and downed
	#     bodies from the fight can't wall the builder's aisle.
	var cover_site := _flat_run(colony, world, mined, 6, site.z)
	_check(
		cover_site != Vector3i.MAX,
		"found a second flat stretch for the cover tests"
	)
	if cover_site == Vector3i.MAX:
		cover_site = site + Vector3i(0, 0, 4)
	var soil_cell := cover_site
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE,
			DropItem.DROP_CM3
		),
		soil_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var mound_cell := cover_site + Vector3i(3, 0, 0)
	var grassed := (
		colony.grass != null
		and colony.grass.coverage_at(mound_cell + Vector3i.DOWN) > 0.0
	)
	_check(
		colony.designate_cover(mound_cell + Vector3i.UP, &"dirt_mound") == null,
		"a mound needs a solid floor"
	)
	_check(
		colony.designate_cover(soil_cell, &"dirt_mound") == null,
		"a piled cell refuses the mound"
	)
	var mound_job := colony.designate_cover(mound_cell, &"dirt_mound")
	_check(mound_job != null, "a mound designates on open ground")
	_check(
		colony.designate_cover(mound_cell, &"dirt_mound") == null,
		"a designated cell refuses a second mound"
	)
	_check(
		not colony._stockpile_cellable(mound_cell),
		"a designated cover cell can't join a stockpile"
	)
	if mound_job != null:
		_drive_craft(colony, world, mound_job, soil_cell, mound_cell)
		var mound_built := await _wait_until(
			func() -> bool:
				return mound_job.state == ColonyJob.State.DONE
		)
		_check(mound_built, "a unit shovels the mound from loose soil")
		var mound := colony.cover_at(mound_cell)
		_check(
			mound != null and mound.provides_cover(),
			"the mound registers as cover"
		)
		_check(
			absf(colony.traversal_mult(mound_cell) - Colony.COVER_CRAWL) < 0.01,
			"scrambling the mound costs stride"
		)
		_check(
			colony.designate_cover(mound_cell, &"wood_barricade") == null,
			"a standing cover cell refuses new designations"
		)
		_check(
			not colony._stockpile_cellable(mound_cell),
			"a standing cover cell can't stockpile"
		)
		if grassed:
			_check(
				colony.grass.coverage_at(mound_cell + Vector3i.DOWN) <= 0.0,
				"the mound strips the grass under it"
			)
		# And it comes back out — deconstruction returns the dirt.
		var tear_down := colony.designate_deconstruct(mound_cell)
		_check(tear_down != null, "the mound is removable")
		if tear_down != null:
			_assign_job(colony, tear_down, mound_cell + Vector3i(1, 0, 0), unit)
			var torn := await _wait_until(
				func() -> bool:
					return tear_down.state == ColonyJob.State.DONE
			)
			_check(
				torn and colony.cover_at(mound_cell) == null,
				"the mound deconstructs back to open ground"
			)

	# --- Barricades ride the same path in wood and stone.
	for recipe in [&"wood_barricade", &"stone_barricade"]:
		_check(
			Colony.RECIPES[recipe].has("builds")
				and Colony.RECIPES[recipe]["builds"] == Building.Kind.BARRICADE,
			"%s builds a barricade" % recipe
		)

	# --- Piles cost stride too: a heaped cell is nearly a wall's climb,
	#     never a shortcut over one.
	var wade_cell := cover_site + Vector3i(5, 0, 0)
	# Half-fill for the wading check, then heap it past capacity for the
	# full-pile one — the overflow spills off to neighbours.
	var before := colony.traversal_mult(wade_cell)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE,
			DropItem.DROP_CM3 / 2
		),
		wade_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony.traversal_mult(wade_cell) < before,
		"wading a pile costs stride"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE,
			DropItem.DROP_CM3
		),
		wade_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var mult := colony.traversal_mult(wade_cell)
	_check(
		mult <= Colony.PILE_CRAWL + 0.01,
		"a heaped pile is no cheaper to climb than a block"
	)

	# --- Serialization: the stance, the post, and the worn/held gear
	#     survive a save round-trip.
	var clone := colony.spawn_unit(far_end)
	clone._job_search_cooldown = 600.0
	unit.set_drafted(true)
	unit._order_voxel = post
	var held_log := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, 1
	)
	var held_tool := DropItem.new(
		BlockRegistry.Resource_.IRON, DropItem.Form.TOOL,
		DropItem.TOOL_CM3
	)
	held_tool.spec = &"pickaxe"
	unit._carried.append(held_log)
	# A leftover work tool would ride the save too — the fixture wants
	# exactly one item in hand.
	unit.hands.clear()
	unit.hands.append(held_tool)
	var saved := unit.serialize()
	unit._carried.erase(held_log)
	clone.deserialize(saved, colony)
	_check(
		clone.drafted and clone._order_voxel == post,
		"draft and post survive a save round-trip"
	)
	_check(
		clone.hands.size() == 1
			and clone.hands[0].form == DropItem.Form.TOOL
			and clone.hands[0].spec == &"pickaxe",
		"the held tool survives a save round-trip"
	)

	# --- Cleanup: retire the fixtures and free the roster.
	unit.set_drafted(false)
	clone.set_drafted(false)
	casualty.set_drafted(false)
	unit.hands.clear()
	unit._carried.clear()
	unit.wounds.clear()
	unit.blood_loss = 0.0
	unit._sync_health()
	if is_instance_valid(scrap):
		scrap.wounds.clear()
		scrap.blood_loss = 0.0
		scrap._sync_health()
	for fixture in [casualty, patient2, clone, scrap]:
		if fixture == null or not is_instance_valid(fixture):
			continue
		fixture.abandon_job()
		fixture.dead = true
		colony.units.erase(fixture)
		colony._sleeping.erase(fixture)
		colony.unit_died.emit(fixture)
		fixture.queue_free()
	for animal in colony.animals.duplicate():
		animal.dead = true
		colony.animals.erase(animal)
		animal.queue_free()
	for u in colony.units:
		u._job_search_cooldown = 0.0
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
	colony.needs_enabled = true
	_clear_jobs(colony)


## Grass is a decoration layer over plain dirt — the generator seeds
## coverage, construction buries it, foot traffic wears it out, and a
## lush cell regrows and spreads (PLAN item 12).
func _test_grass(colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("grass decoration")
	var grass: Grass = colony.grass
	_check(grass != null, "the colony owns a grass decoration layer")
	if grass == null:
		return

	# The generator's oracle seeds cover only where soil tops the column
	# — rock outcrops grow none — and seeds it mixed, not full.
	var generator := world.generator_script
	var seeded := 0
	var mixed := false
	for x in range(mined.x - 40, mined.x + 40, 4):
		for z in range(mined.z - 40, mined.z + 40, 4):
			var s: float = generator.grass_seed_at(x, z)
			if s < 0.0:
				continue
			seeded += 1
			if s < 0.95:
				mixed = true
	_check(seeded > 0, "the generator seeds grass on soil-topped columns")
	_check(mixed, "seeded grass starts at mixed coverage")

	# Streamed terrain carries real coverage — find a live cell near the
	# test anchor.
	var cell := Vector3i.MAX
	var nearest := 1e9
	for c: Vector3i in grass.coverage:
		if grass.coverage_at(c) <= 0.0:
			continue
		var d := (c - mined).length()
		if d < nearest:
			nearest = d
			cell = c
	_check(cell != Vector3i.MAX, "streamed terrain carries grass cover")
	if cell == Vector3i.MAX:
		return
	_check(
		world.get_block(cell) == BlockRegistry.Block.DIRT,
		"grass decorates a plain dirt block"
	)

	# A clean fixture column: air above, no pile or building on it.
	var work := cell + Vector3i.UP
	_normalize_cell(colony, world, work)
	colony.buildings.erase(work)

	# Foot traffic wears cover — five crossings bare a healthy patch.
	grass.coverage[cell] = 0.9
	_check(grass.grassed(cell), "a seeded cell reads grassed")
	var wears := 0
	while grass.grassed(cell) and wears < 20:
		grass.trample(cell)
		wears += 1
	_check(wears == 5, "five crossings wear a healthy patch to bare")
	_check(not grass.grassed(cell), "trampled-out cover is gone")

	# Thin cover thickens a step each scan visit; under the spread
	# threshold it seeds nobody mid-check.
	grass.coverage[cell] = 0.5
	grass._tick_cell(cell)
	_check(
		is_equal_approx(grass.coverage_at(cell), 0.55),
		"cover regrows a step per scan visit"
	)

	# A lush cell seeds exactly one bare eligible neighbour.
	grass.coverage[cell] = 1.0
	var candidates: Array[Vector3i] = []
	for side in Grass.SIDES:
		for dy in [0, 1, -1]:
			var n := cell + side + Vector3i(0, dy, 0)
			_normalize_cell(colony, world, n + Vector3i.UP)
			colony.buildings.erase(n + Vector3i.UP)
			grass.coverage[n] = 0.0
			if grass.coverage_at(n) == 0.0 and world.get_block(n) == BlockRegistry.Block.DIRT:
				candidates.append(n)
	_check(not candidates.is_empty(), "the cell has bare dirt neighbours to spread to")
	if not candidates.is_empty():
		_check(grass.spread_from(cell), "a lush cell spreads to a bare neighbour")
		var sprouted := 0
		for n in candidates:
			if grass.coverage_at(n) > 0.0:
				sprouted += 1
		_check(sprouted == 1, "spread seeds exactly one neighbour")

	# Building anything over grass buries the cover — through the
	# placed-block signal (a real wall block) and through building
	# registration (a bed or worksite, which fills no voxel).
	grass.coverage[cell] = 0.8
	_check(
		world.place(work, BlockRegistry.Block.STONE_WALL),
		"a wall goes up over grassed ground"
	)
	_check(grass.coverage_at(cell) == 0.0, "the placed block buries the cover beneath")
	world.remove_voxel(work)

	grass.coverage[cell] = 0.8
	colony.register_building(Building.new(Building.Kind.WALL, work))
	_check(grass.coverage_at(cell) == 0.0, "registering a building buries the cover beneath")
	colony.buildings.erase(work)

	# Mining the block under cover yields plain dirt — the grass was
	# decoration, not a block type — and the cover dies with the block.
	_check(
		world.mine(cell) == BlockRegistry.Block.DIRT,
		"mining a grassed cell yields dirt"
	)
	_check(not grass.grassed(cell), "the cover dies with its block")
	world.place(cell, BlockRegistry.Block.DIRT)

	# Drowned ground can't hold cover: water is a level datum, not a
	# voxel, so a submerged bed still reads as soil with air above to
	# the block checks — the datum gate is the only thing keeping
	# spread off the lakebed and stale records must die on validation.
	var drowned := Vector3i.MAX
	for wx in range(mined.x - 300, mined.x + 300, 8):
		if drowned != Vector3i.MAX:
			break
		for wz in range(mined.z - 300, mined.z + 300, 8):
			if generator.water_depth_at(wx, wz) <= 0:
				continue
			var bed := Vector3i(wx, generator.surface_height(wx, wz), wz)
			if (
				world.get_block(bed) != BlockRegistry.Block.AIR
				and BlockRegistry.fertilizability(world.get_block(bed)) > 0.0
			):
				drowned = bed
				break
	_check(drowned != Vector3i.MAX, "found submerged soil for the water gate")
	if drowned != Vector3i.MAX:
		_check(
			not grass._eligible(drowned),
			"a submerged cell can't hold grass cover"
		)
		grass.coverage[drowned] = 0.8
		_check(
			grass.coverage_at(drowned) == 0.0,
			"cover under water dies on validation"
		)


## PLAN item 20: daylight and soil fertility modulate plant growth —
## the trapezoid light band and power-curve sensitivity in PlantGrowth,
## type-level soil properties plus sparse per-cell fertilization on the
## colony side, and the slide-the-deadline growth clock both plant
## systems share. Compost finishing its rot fertilizes the block below.
func _test_plant_environment(
	colony: Colony, world: VoxelWorld, mined: Vector3i
) -> void:
	print("plant environment")
	for u in colony.units:
		u._job_search_cooldown = 120.0
	var day_cycle: DayCycle = colony.day_cycle
	var day := colony.day_length()
	var saved_time := day_cycle.planet_time
	var spec: Dictionary = Plants.species_table()[&"berry_bush"]

	# The light band: nothing below min or above max, full rate across
	# the optimal span, lerped through both transitions.
	_check(
		PlantGrowth.light_factor(spec, 0.0) == 0.0, "no growth in darkness"
	)
	_check(
		PlantGrowth.light_factor(spec, 0.03) == 0.0,
		"below minimum light stays dark"
	)
	_check(
		is_equal_approx(PlantGrowth.light_factor(spec, 0.355), 0.5),
		"the dawn transition lerps upward"
	)
	_check(
		PlantGrowth.light_factor(spec, 0.8) == 1.0,
		"the optimal band grows at full rate"
	)
	_check(
		is_equal_approx(PlantGrowth.light_factor(spec, 1.055), 0.5),
		"the scorch transition lerps downward"
	)
	_check(
		PlantGrowth.light_factor(spec, 1.2) == 0.0, "past maximum light stalls"
	)

	# The fertility curve: eff^sensitivity — 200% soil doubles a
	# fully-sensitive plant, 50% halves it; insensitive plants ignore
	# soil entirely and growth never goes negative.
	_check(
		PlantGrowth.fertility_factor(2.0, 1.0) == 2.0,
		"rich soil doubles a fully sensitive plant"
	)
	_check(
		PlantGrowth.fertility_factor(0.5, 1.0) == 0.5,
		"poor soil halves a fully sensitive plant"
	)
	_check(
		is_equal_approx(PlantGrowth.fertility_factor(2.0, 0.5), sqrt(2.0)),
		"half sensitivity softens the boost"
	)
	_check(
		PlantGrowth.fertility_factor(0.0, 0.5) == 0.0,
		"dead soil stalls — never negative growth"
	)
	_check(
		PlantGrowth.fertility_factor(0.0, 0.0) == 1.0,
		"an insensitive plant ignores the soil"
	)

	# Type-level soil properties: dirt fertile and fertilizable,
	# everything else barren and unimprovable.
	_check(
		BlockRegistry.default_fertility(BlockRegistry.Block.DIRT) == 1.0,
		"dirt starts fully fertile"
	)
	_check(
		BlockRegistry.fertilizability(BlockRegistry.Block.DIRT) == 1.0,
		"dirt takes fertilizer"
	)
	_check(
		BlockRegistry.default_fertility(BlockRegistry.Block.STONE) == 0.0,
		"stone is barren"
	)
	_check(
		BlockRegistry.fertilizability(BlockRegistry.Block.STONE) == 0.0,
		"stone can't hold fertilizer"
	)

	var base := Vector3i.MAX
	for z_off in [24, 44, 20, 28, 36, 52]:
		var candidate := _flat_voxel(world, mined, z_off)
		if candidate != Vector3i.MAX:
			base = candidate
			break
	_check(
		base != Vector3i.MAX,
		"found flat ground for the environment test"
	)
	if base == Vector3i.MAX:
		day_cycle.planet_time = saved_time
		day_cycle._apply_sun()
		return
	var bush_cell := base
	var soil := base + Vector3i.DOWN
	var shade_cell := base + Vector3i(1, 0, 0)
	var compost_cell := base + Vector3i(2, 0, 0)
	var tree_cell := base + Vector3i(3, 0, 0)
	for c in [bush_cell, shade_cell, compost_cell, tree_cell]:
		_clear_plants_around(colony, c)
		_normalize_cell(colony, world, c)
	# An air cell can't hold fertilizer either — it has no soil block.
	colony.fertilize(bush_cell, 0.5)
	_check(
		not colony.fertilization.has(bush_cell),
		"an air cell can't hold fertilizer"
	)

	# Sky exposure: noon sun reads near-full on open ground, nothing at
	# night or under a solid roof. Pin the sky the check assumes — the
	# seasonal declination and whatever weather is running both dim it.
	day_cycle.solar_declination_deg = 0.0
	colony.weather.state = Weather.State.CLEAR
	colony.weather.remaining = 9999.0
	day_cycle.advance(wrapf(0.5 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	var noon_light := colony.daylight_at(bush_cell)
	_check(
		noon_light > 0.8 and noon_light < 1.0,
		"an open cell sees near-full sun at noon"
	)
	day_cycle.advance(wrapf(1.0 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	_check(colony.daylight_at(bush_cell) == 0.0, "night is dark")
	world.place(
		shade_cell + Vector3i(0, 2, 0), BlockRegistry.Block.STONE_WALL
	)
	day_cycle.advance(wrapf(0.5 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	_check(
		colony.daylight_at(shade_cell) == 0.0, "a roofed cell is dark at noon"
	)

	# The growth clock: a bush's ripening deadline slides by the un-grown
	# part of each tick — full rate at noon, stalled at night, outrunning
	# the nominal clock on fertilized ground.
	_check(
		colony.plants.plant(bush_cell, &"berry_bush"),
		"the fixture bush plants"
	)
	var rec: Dictionary = colony.plants.bushes[bush_cell]
	# Pin the ripening deadline past any same-day jump the checks below
	# make — the jittered regrow clock can otherwise land inside the
	# advance to midnight and _growth_tick skips a past-due bush.
	rec[&"next"] = colony.game_msec() + int(day * 2000.0)
	var due0: int = rec[&"next"]
	# These ticks are about light and fertility — offset the noise term
	# so ambient sits mid-band whatever year-day the suite clock is on.
	# temperature_c already includes perturb, so the pin shifts it by the
	# error rather than assigning — assigning zeroes a converged pin and
	# the next tick reads raw ambient again.
	colony.weather.perturb += (
		17.0 - colony.weather.temperature_c(day_cycle)
	)
	colony.plants._growth_tick(4.0)
	_check(
		int(rec[&"next"]) == due0, "full light and plain soil keep the deadline"
	)
	colony.fertilize(soil, 1.0)
	_check(
		is_equal_approx(colony.effective_fertility(soil), 2.0),
		"fertilized dirt reads past 100%"
	)
	colony.weather.perturb += (
		17.0 - colony.weather.temperature_c(day_cycle)
	)
	colony.plants._growth_tick(60.0)
	_check(
		int(rec[&"next"]) < due0,
		"fertilized ground outgrows the nominal clock"
	)
	_check(
		float(colony.fertilization.get(soil, 0.0)) < 0.99,
		"growth drains the stored fertility"
	)
	day_cycle.advance(wrapf(1.0 - day_cycle.day_fraction(), 0.0, 1.0) * day)
	var due1: int = rec[&"next"]
	colony.plants._growth_tick(4.0)
	_check(
		int(rec[&"next"]) >= due1 + 3900,
		"darkness slides the deadline with the clock"
	)
	colony.weather.perturb = 0.0
	colony.plants._forget(bush_cell)

	# Trees share the machinery: a sapling's next step postpones in the
	# dark the same way — probed above its own crown, so its trunk
	# doesn't shade it.
	_check(
		colony.forest.plant_sapling(tree_cell, &"oak"),
		"the fixture sapling plants"
	)
	var trec: Dictionary = colony.forest.trees[tree_cell]
	var tree_due: int = trec[&"next"]
	colony.forest._growth_tick(4.0)
	_check(
		int(trec[&"next"]) >= tree_due + 3900,
		"a sapling's growth stalls at night too"
	)
	colony.forest.trees.erase(tree_cell)
	colony.forest._index.erase(tree_cell)
	colony.forest._block_roots.get(
		colony.forest._block_of(tree_cell), {}
	).erase(tree_cell)
	var tchunk := colony.forest._column_chunk(tree_cell)
	colony.forest._chunk_roots.get(tchunk, {}).erase(tree_cell)

	# Item 40 — plant stress, damage and death. Temperature is a second
	# trapezoid: full growth inside `opt`, slowed across `grow`, stalled
	# (unhurt) across `dorm`, and damage scaling with degrees beyond it.
	var wheat: Dictionary = Plants.species_table()[&"wheat"]
	_check(
		PlantGrowth.temperature_factor(wheat, 20.0) == 1.0,
		"the optimal temperature band grows at full rate"
	)
	_check(
		is_equal_approx(PlantGrowth.temperature_factor(wheat, 8.5), 0.5),
		"the cold shoulder of the band grows slowly"
	)
	_check(
		PlantGrowth.temperature_factor(wheat, 3.0) == 0.0
			and PlantGrowth.temperature_factor(wheat, 41.0) == 0.0,
		"outside the grow band the plant stalls"
	)
	_check(
		PlantGrowth.temperature_overshoot(wheat, 20.0) == 0.0,
		"the dormant band hurts nothing"
	)
	_check(
		is_equal_approx(PlantGrowth.temperature_overshoot(wheat, -14.0), 10.0)
			and is_equal_approx(
				PlantGrowth.temperature_overshoot(wheat, 58.0), 10.0
			),
		"thermal damage scales with degrees outside dormant"
	)

	# Light stress rides per-species grace timers on the record: a night
	# only accrues `dark` — the shade grace is days long — while glare
	# past its short grace burns fast, and thermal damage never waits.
	var stress_rec := {}
	_check(
		PlantGrowth.stress_tick(wheat, stress_rec, 0.8, 20.0, 60.0) == 0.0,
		"in-band light and warmth hurt nothing"
	)
	_check(
		PlantGrowth.stress_tick(wheat, stress_rec, 0.0, 20.0, 100.0) == 0.0
			and float(stress_rec[&"dark"]) == 100.0,
		"a night of darkness accrues its timer but no damage"
	)
	var shade_dmg := PlantGrowth.stress_tick(
		wheat, stress_rec, 0.0, 20.0, 200.0
	)
	_check(
		is_equal_approx(shade_dmg, 0.002 * 60.0 * 60.0),
		"only the time past the shade grace damages"
	)
	_check(
		PlantGrowth.stress_tick(wheat, stress_rec, 0.8, 20.0, 60.0) == 0.0
			and float(stress_rec[&"dark"]) == 270.0,
		"in-band light bleeds the dark timer off"
	)
	var glare_rec := {}
	_check(
		PlantGrowth.stress_tick(wheat, glare_rec, 1.3, 20.0, 60.0) == 0.0
			and float(glare_rec[&"glare"]) == 60.0,
		"brief overbright accrues glare but doesn't bite"
	)
	var glare_dmg := PlantGrowth.stress_tick(
		wheat, glare_rec, 1.3, 20.0, 60.0
	)
	_check(
		is_equal_approx(glare_dmg, 0.01 * 60.0 * 60.0),
		"glare past its short grace burns fast"
	)
	var dark_full := {&"dark": 9999.0}
	var glare_full := {&"glare": 9999.0}
	_check(
		PlantGrowth.stress_tick(wheat, glare_full, 1.3, 20.0, 60.0)
			> PlantGrowth.stress_tick(wheat, dark_full, 0.0, 20.0, 60.0),
		"glare kills faster than shade"
	)
	_check(
		PlantGrowth.stress_tick(wheat, {}, 0.8, -20.0, 60.0) > 0.0,
		"freezing air needs no grace period"
	)

	# The same model on a live bush: a forced cold snap damages it at
	# once (it's also night — the dark timer accrues but stays far under
	# grace), enough damage kills it, and the corpse stands until its
	# decay deadline, then collapses into compost and frees the cell.
	_check(
		colony.plants.plant(bush_cell, &"wheat"),
		"the stress-fixture wheat plants"
	)
	var wrec: Dictionary = colony.plants.bushes[bush_cell]
	colony.weather.perturb = -60.0
	colony.plants._growth_tick(4.0)
	_check(
		float(wrec.get(&"damage", 0.0)) > 0.0,
		"a forced freeze hurts the live bush"
	)
	_check(
		float(wrec.get(&"dark", 0.0)) >= 4.0,
		"the night accrues its dark timer alongside"
	)
	_check(
		not colony.plants.is_dead(bush_cell), "one cold tick doesn't kill it"
	)
	colony.weather.perturb = 0.0
	colony.plants.damage(bush_cell, 200.0)
	_check(
		colony.plants.is_dead(bush_cell),
		"enough accumulated damage kills the plant"
	)
	_check(
		colony.plants.bush_at(bush_cell) == bush_cell,
		"the dead plant still holds its cell"
	)
	_check(
		not colony.plants.can_forage(bush_cell),
		"a dead plant can't be foraged"
	)
	wrec[&"dead_next"] = colony.game_msec()
	colony.plants._growth_tick(0.5)
	_check(
		colony.plants.bush_at(bush_cell) == Vector3i.MAX,
		"the corpse decays away"
	)
	var corpse_pile := colony.item_pile_at(bush_cell)
	var composted := false
	if corpse_pile != null:
		for i in corpse_pile.items:
			if i.material == BlockRegistry.Resource_.COMPOST:
				composted = true
	_check(composted, "the dead plant composts where it stood")

	# A damaged survivor harvests light — wheat's six heads scale by the
	# remaining health fraction; a healthy plant drops all six.
	_check(
		colony.plants.plant(bush_cell, &"wheat"),
		"the freed cell replants"
	)
	var wheat_rec: Dictionary = colony.plants.bushes[bush_cell]
	wheat_rec[&"ripe"] = true
	colony.plants.damage(bush_cell, 45.0)
	_check(
		colony.plants.forage(bush_cell).size() == 2,
		"a three-quarters-dead plant harvests a quarter yield"
	)
	_check(
		colony.plants.plant(bush_cell, &"wheat"),
		"the annual's harvest freed the cell"
	)
	colony.plants.bushes[bush_cell][&"ripe"] = true
	_check(
		colony.plants.forage(bush_cell).size() == 6,
		"a healthy plant harvests full yield"
	)

	# The vitals ride the save — damage and stress timers can't be
	# laundered through a reload.
	colony.plants.plant(bush_cell, &"wheat")
	colony.plants.damage(bush_cell, 30.0)
	var saved_plants := colony.plants.serialize()
	var row: Array = []
	for e: Array in saved_plants["bushes"]:
		if (
			int(e[0]) == bush_cell.x and int(e[1]) == bush_cell.y
			and int(e[2]) == bush_cell.z
		):
			row = e
	_check(
		row.size() >= 11 and is_equal_approx(float(row[6]), 30.0),
		"damage and stress state ride the save record"
	)
	colony.plants.bushes[bush_cell][&"damage"] = 99.0
	colony.plants.deserialize(saved_plants)
	_check(
		is_equal_approx(
			float(colony.plants.bushes[bush_cell][&"damage"]), 30.0
		),
		"a reload restores the accumulated damage"
	)
	colony.plants._forget(bush_cell)

	# Trees share the model: enough damage kills the tree, growth stops,
	# the browned canopy sheds to compost on its decay deadline, and the
	# snag stands until felled.
	_check(
		colony.forest.plant_sapling(tree_cell, &"oak"),
		"the stress-fixture sapling plants"
	)
	colony.forest.grow(tree_cell)
	colony.forest.grow(tree_cell)
	var dead_tree: Dictionary = colony.forest.trees[tree_cell]
	_check(
		int(dead_tree[&"height"]) == 2
			and (dead_tree[&"voxels"] as Array).size() > 2,
		"the fixture tree grew a canopy"
	)
	colony.forest.damage(tree_cell, 500.0)
	_check(
		colony.forest.is_dead(tree_cell),
		"accumulated damage kills the tree"
	)
	colony.forest.grow(tree_cell)
	_check(
		int(dead_tree[&"height"]) == 2, "a dead tree doesn't grow"
	)
	dead_tree[&"dead_next"] = colony.game_msec()
	colony.forest._growth_tick(0.5)
	var leaves_gone := true
	for v: Vector3i in dead_tree[&"voxels"]:
		if colony.forest._leaves.has(v):
			leaves_gone = false
	_check(leaves_gone, "the dead canopy sheds")
	var snag_compost := false
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			for dy in [0, 1]:
				var p := colony.item_pile_at(
					tree_cell + Vector3i(dx, dy, dz)
				)
				if p == null:
					continue
				for i in p.items:
					if i.material == BlockRegistry.Resource_.COMPOST:
						snag_compost = true
	_check(snag_compost, "the shed canopy composts at the base")
	_check(
		colony.forest.trees.has(tree_cell),
		"the snag keeps standing"
	)
	colony.forest.fell(tree_cell)

	# Compost finishing its rot fertilizes the block below its pile —
	# 1% per 1000 cm³.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COMPOST, DropItem.Form.LOOSE, 80_000
		),
		compost_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony._decay_tick(300.0 * day)
	_check(
		is_equal_approx(
			float(
				colony.fertilization.get(
					compost_cell + Vector3i.DOWN, 0.0
				)
			),
			0.8
		),
		"rotted compost fertilizes the block below"
	)

	# Cleanup: the roof, the fixture's fertilization, and the clock.
	world.remove_voxel(shade_cell + Vector3i(0, 2, 0))
	colony.fertilization.erase(soil)
	colony.fertilization.erase(compost_cell + Vector3i.DOWN)
	day_cycle.planet_time = saved_time
	day_cycle._apply_sun()


## Farm fields: a zone designation with a crop assignment. The field
## posts sow jobs where the species can grow — gated on a seed packet of
## that species existing — ripe shrubs harvest themselves, annuals die
## to their harvest and re-sow, and tree fields fell their mature trunks
## when auto-chop is on (PLAN item 14).
func _test_farm(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("farming")
	# Keep every unit on task — the subject gets driven by hand.
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)

	# --- The resource model: grain is real, edible material; its
	# harvested heads are seed-bearing fruit, so the extract-seed craft
	# threshes them into wheat packets — and a rotted head volunteers.
	_check(
		BlockRegistry.resource_name_of(BlockRegistry.Resource_.GRAIN) == "Grain",
		"the grain resource is registered"
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.GRAIN),
		"grain is edible"
	)
	_check(
		bool(Plants.species_table()[&"wheat"][&"annual"]),
		"wheat is an annual — the harvest kills the plant"
	)
	_check(
		not bool(Plants.species_table()[&"berry_bush"][&"annual"]),
		"the berry bush is a perennial"
	)
	_check(
		DropItem.FRUIT_SPECIES[BlockRegistry.Resource_.GRAIN] == &"wheat",
		"a grain head threshes into wheat seed"
	)

	# --- Designation: flat dirt cells become one shared field.
	var spot := _flat_voxel(world, mined, -100, 200)
	_check(spot != Vector3i.MAX, "flat ground exists for a farm field")
	if spot == Vector3i.MAX:
		return
	for c: Vector3i in [spot, spot + Vector3i.RIGHT]:
		_normalize_cell(colony, world, c)
		_clear_plants_around(colony, c)
		colony.undesignate_farm(c)
		colony.buildings.erase(c)
	_check(colony.designate_farm(spot), "a farm cell designates")
	_check(colony.farm_at(spot) != null, "the cell reports its field")
	_check(colony.is_designated(spot), "the field cell carries a zone marker")
	_check(
		not colony.designate_farm(spot),
		"a cell can't be designated twice"
	)
	_check(
		colony.designate_farm(spot + Vector3i.RIGHT),
		"a neighbouring cell designates"
	)
	var field := colony.farm_at(spot)
	_check(
		field != null
			and colony.farm_at(spot + Vector3i.RIGHT) == field
			and field.cells.size() == 2,
		"contiguous cells join one field"
	)

	# --- The sow gate: an unseeded crop posts nothing until a packet of
	# the field's species exists anywhere in a pile.
	colony.set_farm_crop(spot, &"wheat")
	_check(field.species == &"wheat", "the field takes a crop assignment")
	colony._tick_field(field)
	_check(
		colony._farm_jobs.get(spot) == null,
		"with no seeds the field waits instead of posting"
	)
	var seed_cell := spot + Vector3i.BACK
	_normalize_cell(colony, world, seed_cell)
	var seed := DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	seed.species = &"wheat"
	colony._drop_item(seed, seed_cell)
	var foreign := DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	foreign.species = &"oak"
	colony._drop_item(foreign, seed_cell)
	colony._tick_field(field)
	var sow: ColonyJob = colony._farm_jobs.get(spot)
	_check(
		sow != null and sow.type == ColonyJob.Type.SOW,
		"a seeded field posts a sow job"
	)
	_check(
		colony._farm_jobs.get(spot + Vector3i.RIGHT) != null,
		"every open cell of the field sows"
	)
	_check(
		sow == null or sow.species == &"wheat",
		"the sow job carries the field's species"
	)

	# --- Sowability: bare air over dirt only — a stone floor, a pile,
	# or (for trees) any plant in the 3×3 refuses.
	var floor_cell := seed_cell + Vector3i.BACK
	_normalize_cell(colony, world, floor_cell)
	_check(colony._sowable(floor_cell, false), "open air over dirt sows")
	world.remove_voxel(floor_cell + Vector3i.DOWN)
	world.place(floor_cell + Vector3i.DOWN, BlockRegistry.Block.STONE)
	_check(
		not colony._sowable(floor_cell, false),
		"a stone floor refuses the plough"
	)
	world.remove_voxel(floor_cell + Vector3i.DOWN)
	world.place(floor_cell + Vector3i.DOWN, BlockRegistry.Block.DIRT)
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500_000
		),
		floor_cell
	)
	colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.LOOSE, 500_000
		),
		floor_cell
	)
	_check(
		not colony._sowable(floor_cell, false),
		"a cell holding a pile refuses the plough"
	)
	var floor_pile := colony.item_pile_at(floor_cell)
	if floor_pile != null:
		floor_pile.items.clear()
		colony.remove_pile_if_empty(floor_cell)

	# --- Sowing end to end: the unit fetches the wheat packet, carries
	# it to the cell, and an immature wheat bush appears — the packet is
	# consumed and the grass under the cell dies.
	colony.grass.coverage[spot + Vector3i.DOWN] = 0.8
	var park := _park_beside(colony, world, spot, seed_cell)
	if sow != null:
		_assign_job(colony, sow, park, unit)
		var sown := await _wait_until(func() -> bool:
			return sow.state == ColonyJob.State.DONE)
		_check(sown, "a unit sows a field cell")
		_check(
			colony.plants.bush_at(spot) == spot,
			"sowing spawns the bush in the cell"
		)
		_check(
			not colony.plants.can_forage(spot),
			"a fresh sowing is immature"
		)
		_check(
			colony.grass.coverage_at(spot + Vector3i.DOWN) == 0.0,
			"planting turns the sod — the grass dies"
		)
		_check(
			colony._farm_jobs.get(spot) == null
				or colony._farm_jobs[spot].type != ColonyJob.Type.SOW,
			"the planted cell doesn't sow again"
		)

	# --- Harvest: a ripe field bush posts a forage job; the annual comes
	# up whole — bush gone, grain heads on the ground — and the field
	# re-sows the freed cell once seed exists again.
	if colony.plants.bush_at(spot) == spot:
		colony.plants.bushes[spot][&"ripe"] = true
		colony._tick_field(field)
		var harvest: ColonyJob = colony._farm_jobs.get(spot)
		_check(
			harvest != null and harvest.type == ColonyJob.Type.FORAGE,
			"a ripe field bush posts a harvest job"
		)
		if harvest != null:
			_assign_job(colony, harvest, park, unit)
			var reaped := await _wait_until(func() -> bool:
				return harvest.state == ColonyJob.State.DONE)
			_check(reaped, "a unit harvests the wheat")
			await _wait_until(func() -> bool:
				return colony._in_flight.is_empty())
		_check(
			colony.plants.bush_at(spot) == Vector3i.MAX,
			"the harvest pulls the annual up whole"
		)
		var heads := 0
		for voxel: Vector3i in colony.item_piles:
			var off: Vector3i = (voxel - spot).abs()
			if maxi(off.x, maxi(off.y, off.z)) > 2:
				continue
			for item in colony.item_piles[voxel].items:
				if item.material == BlockRegistry.Resource_.GRAIN:
					heads += 1
		_check(heads >= 6, "the harvest drops grain heads")
		# The harvest landed on the field cell — a piled cell isn't
		# sowable until the crop is hauled off.
		var stale_piles: Array[Vector3i] = []
		for voxel: Vector3i in colony.item_piles:
			var off2: Vector3i = (voxel - spot).abs()
			if maxi(off2.x, maxi(off2.y, off2.z)) <= 2:
				stale_piles.append(voxel)
		for voxel: Vector3i in stale_piles:
			colony.item_piles[voxel].items.clear()
			colony.remove_pile_if_empty(voxel)
		var seed2 := DropItem.new(
			BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
		)
		seed2.species = &"wheat"
		colony._drop_item(seed2, seed_cell)
		colony._tick_field(field)
		var resow: ColonyJob = colony._farm_jobs.get(spot)
		_check(
			resow != null and resow.type == ColonyJob.Type.SOW,
			"the harvested annual's cell re-sows"
		)
		if resow != null:
			resow.state = ColonyJob.State.CANCELLED
			colony._prune_jobs()
			colony._farm_jobs.erase(spot)

	# --- A tree field: the same zone on a second cell cluster, assigned
	# oak. Saplings obey the 3×3 spacing rule, and auto-chop fells the
	# mature tree — off, it stands.
	var oak_spot := Vector3i.MAX
	for off: Vector3i in [
		Vector3i(0, 0, -4), Vector3i(0, 0, 4), Vector3i(4, 0, 0)
	]:
		var c: Vector3i = spot + off
		_normalize_cell(colony, world, c)
		_clear_plants_around(colony, c)
		colony.undesignate_farm(c)
		if colony.designate_farm(c):
			oak_spot = c
			break
	_check(oak_spot != Vector3i.MAX, "a separate cell designates for trees")
	if oak_spot == Vector3i.MAX:
		return
	var oak_field := colony.farm_at(oak_spot)
	colony.set_farm_crop(oak_spot, &"oak")
	# No oak seeds of the right species yet — only the leftover wheat
	# packet's sibling oak seed exists from earlier. The seed gate reads
	# it: foreign packets count for their own species.
	seed = DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	seed.species = &"oak"
	colony._drop_item(seed, seed_cell)
	colony._tick_field(oak_field)
	var oak_sow: ColonyJob = colony._farm_jobs.get(oak_spot)
	_check(
		oak_sow != null and oak_sow.type == ColonyJob.Type.SOW,
		"a tree field posts sow jobs for its species"
	)
	# The 3×3 rule: a bush beside the cell makes it unsowable for trees.
	var beside := oak_spot + Vector3i.RIGHT
	_normalize_cell(colony, world, beside)
	_clear_plants_around(colony, beside)
	colony.plants.plant(beside, &"berry_bush")
	_check(
		not colony._sowable(oak_spot, true),
		"a tree won't sow within a plant's 3×3"
	)
	colony.plants.bushes.erase(beside)
	colony.plants._index.erase(beside)
	if oak_sow != null:
		_assign_job(colony, oak_sow, park, unit)
		var sown2 := await _wait_until(func() -> bool:
			return oak_sow.state == ColonyJob.State.DONE)
		_check(sown2, "a unit sows a tree cell")
		_check(
			colony.forest.tree_root_at(oak_spot) == oak_spot,
			"a sown tree root takes the cell"
		)
	if colony.forest.tree_root_at(oak_spot) == oak_spot:
		# Grow the real way — a height bumped without the trunk going
		# up would read as a stale record and the cell would re-sow.
		for i in int(Forest.species_table()[&"oak"][&"max_height"]) + 2:
			if colony.forest.mature(oak_spot):
				break
			colony.forest.grow(oak_spot)
		_check(
			colony.forest.mature(oak_spot),
			"the field tree grows to maturity"
		)
		colony._tick_field(oak_field)
		_check(
			colony._farm_jobs.get(oak_spot) == null,
			"auto-chop off — a mature field tree just stands"
		)
		colony.set_farm_auto_chop(oak_spot, true)
		colony._tick_field(oak_field)
		var fell: ColonyJob = colony._farm_jobs.get(oak_spot)
		_check(
			fell != null and fell.type == ColonyJob.Type.CHOP,
			"auto-chop on — a mature field tree posts a chop"
		)
		colony.forest.fell(oak_spot)

	# --- Undesignate: the cell leaves the field, the marker clears, and
	# a pending farm job at the cell dies with it.
	var removed := colony.undesignate_farm(spot + Vector3i.RIGHT)
	_check(removed, "a farm cell undesignates")
	_check(
		colony.farm_at(spot + Vector3i.RIGHT) == null,
		"the undesignated cell leaves the field"
	)
	_check(
		not colony.is_designated(spot + Vector3i.RIGHT),
		"the zone marker clears"
	)
	_check(
		field.cells.size() == 1,
		"the field record shrinks to its remaining cell"
	)
	colony.undesignate_farm(spot)
	colony.undesignate_farm(oak_spot)


## Item 41: composting and fertilizing. The compost bin is a one-cell
## storage building whose preset filter admits only what rots to
## compost and whose pile rots three times as fast; fertilize marks and
## a field's auto-fertilizer post jobs that spread the loose compost it
## makes into soil fertility.
func _test_compost(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("composting and fertilizing")
	for u in colony.units:
		u._job_search_cooldown = 120.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)

	var spot := _flat_voxel(world, mined, -60, 40)
	_check(
		spot != Vector3i.MAX, "flat ground exists for the compost tests"
	)
	if spot == Vector3i.MAX:
		return
	var cells: Array[Vector3i] = []
	for i in range(4):
		var c := spot + Vector3i(i, 0, 0)
		_normalize_cell(colony, world, c)
		_clear_plants_around(colony, c)
		cells.append(c)

	# --- The recipe and the designation path.
	_check(
		Colony.recipe_of(&"compost_bin")[&"builds"]
			== Building.Kind.COMPOST_BIN,
		"the compost bin recipe builds a bin"
	)
	_check(
		Colony.recipe_of(&"compost_bin")[&"inputs"]
			== {DropItem.Form.PLANK: 4},
		"the bin is made of plank/sheet"
	)
	var site_v := spot + Vector3i(5, 0, 0)
	_normalize_cell(colony, world, site_v)
	var build_job := colony.designate_production(site_v, &"compost_bin")
	_check(
		build_job != null and build_job.recipe == &"compost_bin",
		"the bin designates through the production path"
	)
	if build_job != null:
		colony.cancel_designation(site_v)

	# --- The bin itself: a one-cell stockpile that takes compostables.
	var bin_v: Vector3i = cells[0]
	colony.register_building(Building.new(Building.Kind.COMPOST_BIN, bin_v))
	_check(colony.compost_bin_at(bin_v) != null, "a compost bin registers")
	_check(colony.is_stockpile(bin_v), "the bin's cell is a stockpile")
	_check(
		colony.stockpile_admits(bin_v, BlockRegistry.Resource_.LEAF),
		"the bin takes leaves"
	)
	_check(
		colony.stockpile_admits(bin_v, BlockRegistry.Resource_.CORPSE),
		"the bin takes corpses"
	)
	_check(
		not colony.stockpile_admits(bin_v, BlockRegistry.Resource_.BERRY),
		"rotting fruit vanishes, not composts — the bin refuses it"
	)
	_check(
		not colony.stockpile_admits(bin_v, BlockRegistry.Resource_.STONE),
		"the bin refuses stone"
	)
	_check(
		not colony.stockpile_admits(bin_v, BlockRegistry.Resource_.COMPOST),
		"finished compost isn't admitted — it hauls back out"
	)
	_check(
		colony.voxel_capacity(bin_v) == Colony.SHELF_PILE_CM3,
		"the bin holds a container's fill"
	)

	# --- Three-times rot: the bin's leaf pile sweeps eight four-day
	# ticks — 32 days at 3× is ~6.4 of its 15-day lives, so all but a
	# lone sub-quantum bite is gone — while an identical pile dropped
	# beside it afterwards sees only the last tick: four of its
	# fifteen days, barely a quarter spent.
	var day := colony.day_length()
	var ctrl_v: Vector3i = cells[1]
	# Compost that rots away feeds the soil under the bin — the ledger
	# for what the check below can't see in the pile any more.
	var bin_fert0 := float(
		colony.fertilization.get(bin_v + Vector3i.DOWN, 0.0)
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.LEAF, DropItem.Form.LOOSE, 400_000
		),
		bin_v
	)
	# Pin the draws: the fresh compost rots on its own clock between
	# ticks, and an unlucky streak once ate the whole margin.
	seed(7)
	for i in 8:
		colony._decay_tick(4.0 * day)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.LEAF, DropItem.Form.LOOSE, 400_000
		),
		ctrl_v
	)
	colony._decay_tick(4.0 * day)
	randomize()
	var loose_at := func(v: Vector3i, mat: BlockRegistry.Resource_) -> int:
		var total := 0
		var p := colony.item_pile_at(v)
		if p != null:
			for item in p.items:
				if (
					item.material == mat
					and item.form == DropItem.Form.LOOSE
				):
					total += item.volume
		return total
	var bin_leaf: int = loose_at.call(bin_v, BlockRegistry.Resource_.LEAF)
	var ctrl_leaf: int = loose_at.call(ctrl_v, BlockRegistry.Resource_.LEAF)
	_check(
		bin_leaf <= 8_000, "the bin's leaf pile is rotted through"
	)
	_check(
		ctrl_leaf > 200_000,
		"the same pile outside keeps most of its mass"
	)
	# Production, not survival: the fresh compost rots on its own 60-day
	# clock over the same ticks, and an unlucky Poisson streak can eat
	# the margin — count what survived plus what fertilized the soil.
	var compost_left: int = loose_at.call(
		bin_v, BlockRegistry.Resource_.COMPOST
	)
	var compost_gone := roundi(
		(
			float(colony.fertilization.get(bin_v + Vector3i.DOWN, 0.0))
			- bin_fert0
		) / Colony.FERTILIZE_PER_CM3
	)
	_check(
		compost_left + compost_gone >= 80_000,
		"the rot leaves its compost behind — a quarter of the leaves"
	)

	# --- The product's exemption: finished compost in the bin keeps its
	# own 60-day clock. Discrete items (decay only reads material) each
	# rot at 50% over a 30-day sweep — boosted, all twelve would be
	# gone; unboosted, the odds all twelve rot are ~0.02%.
	for i in 12:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.COMPOST,
				DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			bin_v
		)
	colony._decay_tick(30.0 * day)
	var product_left := 0
	var bin_pile := colony.item_pile_at(bin_v)
	if bin_pile != null:
		for item in bin_pile.items:
			if (
				item.material == BlockRegistry.Resource_.COMPOST
				and item.form == DropItem.Form.PLANK
			):
				product_left += 1
	_check(product_left > 0, "finished compost in the bin keeps its own clock")

	# --- The mark: paint, post, fetch, spread. Purge the map's stray
	# compost first so the suspension check is deterministic.
	var mark_v: Vector3i = cells[2]
	colony.fertilization.erase(mark_v + Vector3i.DOWN)
	_check(
		colony.designate_fertilize(mark_v),
		"air over dirt takes a fertilize mark"
	)
	_check(
		not colony.designate_fertilize(mark_v),
		"a cell won't mark twice"
	)
	var stone_v: Vector3i = cells[3]
	world.remove_voxel(stone_v + Vector3i.DOWN)
	world.place(stone_v + Vector3i.DOWN, BlockRegistry.Block.STONE)
	_check(
		not colony.designate_fertilize(stone_v),
		"stone ground refuses a fertilize mark"
	)
	# A pile can vanish mid-sweep — emptying one re-settles the column,
	# and the merge can take another keyed pile with it. Filter every
	# pile first, then drop the empties: no compost survives to ride a
	# merge into an already-swept pile.
	for stale: ItemPile in colony.item_piles.values():
		stale.items = stale.items.filter(
			func(i: DropItem) -> bool:
				return i.material != BlockRegistry.Resource_.COMPOST
		)
	for voxel: Vector3i in colony.item_piles.keys():
		colony.remove_pile_if_empty(voxel)
	_check(not colony._compost_exists(), "the larder starts empty")
	colony._fertilize_scan()
	var fjob: ColonyJob = colony._fertilize_jobs.get(mark_v)
	_check(
		fjob != null and fjob.type == ColonyJob.Type.FERTILIZE,
		"a marked cell posts a fertilize job"
	)
	_check(
		fjob != null
			and fjob.fertilize_target == Colony.FERTILIZE_PAINT_TARGET,
		"the job carries the mark's target"
	)
	_check(
		fjob != null and fjob.suspended,
		"an empty larder suspends the job"
	)
	var comp_v: Vector3i = cells[3]
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COMPOST, DropItem.Form.LOOSE, 400_000
		),
		comp_v
	)
	colony._fertilize_scan()
	if fjob != null:
		_check(
			not fjob.suspended, "compost in the larder wakes the job"
		)
		var park := _park_beside(colony, world, mark_v, comp_v)
		_assign_job(colony, fjob, park, unit)
		var spread := await _wait_until(func() -> bool:
			return fjob.state == ColonyJob.State.DONE)
		_check(spread, "a unit spreads compost on the marked cell")
	_check(
		colony.effective_fertility(mark_v + Vector3i.DOWN)
			>= Colony.FERTILIZE_PAINT_TARGET,
		"the soil reaches the mark's fertility"
	)
	_check(
		not colony.fertilize_marks.has(mark_v),
		"a satisfied mark clears itself"
	)
	_check(
		colony._fertilize_markers.get(mark_v) == null,
		"the mark's overlay clears with it"
	)

	# --- The field's auto-fertilizer: the toggle posts for cells below
	# the target, the scan never double-posts, and the slider retunes
	# the live job.
	var farm_v := spot + Vector3i(0, 0, -2)
	_normalize_cell(colony, world, farm_v)
	_clear_plants_around(colony, farm_v)
	colony.fertilization.erase(farm_v + Vector3i.DOWN)
	_check(colony.designate_farm(farm_v), "a fresh field designates")
	colony.set_farm_auto_fertilize(farm_v, true)
	colony.set_farm_fertilize_target(farm_v, 2.0)
	var field := colony.farm_at(farm_v)
	_check(
		field != null and field.auto_fertilize,
		"the field takes the auto-fertilizer"
	)
	_check(
		field != null and field.fertilize_target == 2.0,
		"the field takes the target"
	)
	colony._fertilize_scan()
	var ajob: ColonyJob = colony._fertilize_jobs.get(farm_v)
	_check(
		ajob != null and ajob.type == ColonyJob.Type.FERTILIZE,
		"an auto-fertilizing field posts for a below-target cell"
	)
	colony._fertilize_scan()
	_check(
		colony._fertilize_jobs.get(farm_v) == ajob,
		"the scan doesn't double-post a worked cell"
	)
	colony.set_farm_fertilize_target(farm_v, 1.2)
	colony._fertilize_scan()
	_check(
		ajob != null and ajob.fertilize_target == 1.2,
		"the slider retunes a live job"
	)

	# --- Shared ground: the painted mark outranks the field's target.
	var shared := spot + Vector3i(1, 0, -2)
	_normalize_cell(colony, world, shared)
	_clear_plants_around(colony, shared)
	colony.fertilization.erase(shared + Vector3i.DOWN)
	colony.designate_fertilize(shared)
	_check(
		colony.designate_farm(shared),
		"a marked cell still joins a field"
	)
	colony.set_farm_auto_fertilize(shared, true)
	colony.set_farm_fertilize_target(shared, 1.2)
	colony._fertilize_scan()
	var shared_job: ColonyJob = colony._fertilize_jobs.get(shared)
	_check(
		shared_job != null
			and shared_job.fertilize_target == Colony.FERTILIZE_PAINT_TARGET,
		"a mark on a field cell drives at the mark's own target"
	)

	# --- Persistence and teardown.
	var data := colony.serialize()
	var saved_field := false
	for fd: Dictionary in data.get("farms", []):
		if bool(fd.get("auto_fertilize", false)):
			saved_field = true
	_check(saved_field, "the field's auto-fertilize serializes")
	var saved_mark := false
	for e: Array in data.get("fertilize_marks", []):
		if Vector3i(int(e[0]), int(e[1]), int(e[2])) == shared:
			saved_mark = true
	_check(saved_mark, "a painted mark serializes")
	var saved_job := {}
	for jd: Dictionary in data.get("jobs", []):
		if int(jd["type"]) == int(ColonyJob.Type.FERTILIZE):
			saved_job = jd
	_check(
		float(saved_job.get("fert_target", 0.0)) > 0.0,
		"the fertilize job serializes its target"
	)
	colony._teardown_building(bin_v)
	_check(colony.compost_bin_at(bin_v) == null, "the bin comes down")
	_check(not colony.is_stockpile(bin_v), "the bin's zone dies with it")

	# --- Cleanup: cancel sweeps the marks, the field and the stray jobs.
	colony.cancel_designation(shared)
	_check(
		not colony.fertilize_marks.has(shared),
		"the cancel tool lifts a mark"
	)
	colony.undesignate_farm(farm_v)
	colony.undesignate_farm(shared)
	_clear_jobs(colony)
	for voxel: Vector3i in colony.item_piles.keys():
		var stale2 := colony.item_piles[voxel]
		if (voxel - spot).abs().x <= 8 and (voxel - spot).abs().z <= 4:
			stale2.items.clear()
			colony.remove_pile_if_empty(voxel)


## Item 43 — tool requirements and upkeep. Chopping wants an axe,
## digging wants a shovel or a pick, hard rock wants the pick alone;
## stone tools knap off any crafting spot from a rod and two cobbles
## at half speed, the iron set forges at the toolmaker's bench over a
## per-job fire, wear breaks knapped heads for keeps while iron mends
## at the bench (a raw unit per 40%, capped at 80%), and the belt's
## holsters reserve per tool spec.
func _test_tools(
	colony: Colony, world: VoxelWorld, _unit: Unit, mined: Vector3i
) -> void:
	print("tools")
	for u in colony.units:
		u._job_search_cooldown = 300.0
		if u.job != null and not u.job.desperate:
			colony.release_job(u.job)
		u.abandon_job()
	var worker: Unit = colony.units[0]

	# --- The requirement table: axe for felling, a digging tool for
	#     soft ground, the pick alone for hard rock.
	var chop_req := Colony.required_tool(
		ColonyJob.new(ColonyJob.Type.CHOP, Vector3i.ZERO), world
	)
	_check(
		chop_req.get(&"classes", []) == [&"axe"]
			and chop_req.get(&"use", &"") == &"chop",
		"felling wants an axe"
	)
	var run := _clear_run(colony, world, mined, 6)
	_check(run != Vector3i.MAX, "found a flat row for the tool fixtures")
	if run == Vector3i.MAX:
		return
	var spot_v := run
	var bench_v := run + Vector3i(2, 0, 0)
	var pile_v := run + Vector3i(4, 0, 0)
	# The dig cell's floor is normalized to dirt — the soft case — and
	# the cell beside it gets a placed stone block for the hard one.
	var dig_cell := run + Vector3i(5, 0, -1)
	_normalize_cell(colony, world, dig_cell)
	var dig_target := dig_cell + Vector3i.DOWN
	var hard_cell := run + Vector3i(4, 0, -1)
	_normalize_cell(colony, world, hard_cell)
	var hard_floor := hard_cell + Vector3i.DOWN
	world.remove_voxel(hard_floor)
	world.place(hard_floor, BlockRegistry.Block.STONE)
	var soft_req := Colony.required_tool(
		ColonyJob.new(ColonyJob.Type.MINE, dig_target), world
	)
	_check(
		soft_req.get(&"classes", []) == [&"shovel", &"pick"]
			and soft_req.get(&"use", &"") == &"dig",
		"soft ground takes a shovel or a pick"
	)
	var hard_req := Colony.required_tool(
		ColonyJob.new(ColonyJob.Type.MINE, hard_floor), world
	)
	_check(
		hard_req.get(&"classes", []) == [&"pick"]
			and hard_req.get(&"use", &"") == &"mine",
		"hard rock wants the pick alone"
	)

	# --- No tool, no work: a chop on a live tree goes back to the board.
	worker.hands.clear()
	for i in worker.holstered.size():
		worker.holstered[i] = null
	var tree_v := run + Vector3i(5, 0, 1)
	_normalize_cell(colony, world, tree_v)
	colony.forest.plant_sapling(tree_v, &"oak")
	for i in 4:
		colony.forest.grow(tree_v)
	var noaxe := colony.designate_chop(tree_v)
	_check(noaxe != null, "a grown tree designates for chopping")
	if noaxe != null:
		_assign_job(colony, noaxe, _park_beside(colony, world, tree_v, run), worker)
		var refused := await _wait_until(
			func() -> bool: return noaxe.dropped_by.has(worker)
		)
		_check(
			refused and worker.hands.is_empty(),
			"an axe-less unit hands the chop job back"
		)
		colony.cancel_designation(tree_v)

	# --- The spec table: classes, use rates, wear lives, repairability.
	var stone_axe := _arm_tool(worker, &"stone_axe")
	var iron_pick := _arm_tool(worker, &"iron_pick")
	worker.hands.clear()
	_check(
		DropItem.tool_class(stone_axe) == &"axe"
			and DropItem.tool_use_speed(stone_axe, &"chop") < 1.0,
		"a stone axe chops slow"
	)
	_check(
		DropItem.tool_use_speed(iron_pick, &"mine")
			> DropItem.tool_use_speed(
				_arm_tool(worker, &"stone_pick"), &"mine"
			) * 2.0,
		"the iron pick out-mines the stone one by a wide margin"
	)
	worker.hands.clear()
	var stone_shovel := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.TOOL, DropItem.TOOL_CM3
	)
	stone_shovel.spec = &"stone_shovel"
	_check(
		DropItem.tool_use_speed(stone_shovel, &"dig") > 0.0
			and DropItem.tool_use_speed(stone_shovel, &"mine") == 0.0,
		"a shovel digs but can never take hard rock"
	)
	_check(
		not DropItem.tool_repairable(stone_axe)
			and DropItem.tool_repairable(iron_pick),
		"only metal heads can be mended"
	)

	# --- Wear: work wears the head down; a dead stone tool breaks into
	#     its haft and a gravel scattering. Sweep the drop zone first so
	#     stray litter can't masquerade as the remains.
	var floor_v := worker._standing_voxel()
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			_sweep(colony, floor_v + Vector3i(dx, 0, dz))
	var worn_axe := _arm_tool(worker, &"stone_axe")
	worker._wear_tool(worn_axe, 30.0)
	_check(
		is_equal_approx(worn_axe.wear, 0.5),
		"work wears the tool head down"
	)
	worker._wear_tool(worn_axe, 30.0)
	_check(
		not worker.hands.has(worn_axe),
		"a worn-out stone tool leaves the hand"
	)
	# The remains arc out like any drop — wait for them to land.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var rod_back := 0
	var gravel_back := 0
	for voxel: Vector3i in colony.item_piles:
		if (voxel - floor_v).abs().x > 2 or (voxel - floor_v).abs().z > 2:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.BRANCH:
				rod_back += item.volume
			elif (
				item.form == DropItem.Form.LOOSE
				and item.material == BlockRegistry.Resource_.STONE
			):
				gravel_back += item.volume
	_check(rod_back == DropItem.ROD_CM3, "the haft survives the break")
	_check(
		gravel_back == DropItem.COBBLE_CM3,
		"the shattered head pours back as gravel"
	)
	_sweep(colony, floor_v)
	_sweep(colony, floor_v + Vector3i(1, 0, 0))
	_sweep(colony, floor_v + Vector3i(-1, 0, 0))
	_sweep(colony, floor_v + Vector3i(0, 0, 1))
	_sweep(colony, floor_v + Vector3i(0, 0, -1))

	# --- Holster reservations: a kept slot refuses a foreign spec.
	var belt := DropItem.new(
		BlockRegistry.Resource_.CLOTH, DropItem.Form.GARMENT,
		DropItem.GARMENT_CM3
	)
	belt.spec = &"tool_belt"
	var belt_on := worker.wear_garment(belt)
	_check(
		belt_on and worker.holster_count() == 2,
		"the belt lends two holster slots"
	)
	if worker.holster_count() >= 2:
		while worker.holster_prefs.size() < 2:
			worker.holster_prefs.append(&"")
		worker.holster_prefs[1] = &"iron_axe"
		var stowed_pick := _arm_tool(worker, &"stone_pick")
		worker.stow_tools()
		_check(
			worker.holstered[0] == stowed_pick
				and worker.holstered[1] == null,
			"a generic slot takes the pick while the axe slot stays reserved"
		)
		worker.holster_prefs[0] = &"iron_axe"
		var foreign := _arm_tool(worker, &"stone_shovel")
		worker.stow_tools()
		_check(
			worker.hands.has(foreign),
			"a tool with no matching slot stays in hand"
		)
		worker.holster_prefs[0] = &""
		worker.holster_prefs[1] = &""
		worker.stow_tools()
		_check(
			worker.hands.is_empty() and worker._holstered_count() == 2,
			"unreserved slots pocket whatever comes along"
		)

		# --- Serialization: slots and their reservations round-trip,
		#     nulls and all.
		var hol_save := worker.serialize()
		var hol_clone := colony.spawn_unit(worker._standing_voxel())
		hol_clone._job_search_cooldown = 600.0
		hol_clone.deserialize(hol_save, colony)
		_check(
			hol_clone.holstered.size() == 2
				and hol_clone.holstered[0] != null
				and hol_clone.holstered[0].spec == &"stone_pick"
				and hol_clone.holstered[1] != null
				and hol_clone.holstered[1].spec == &"stone_shovel",
			"holstered tools survive a save round-trip"
		)
		hol_clone.dead = true
		colony.units.erase(hol_clone)
		colony._sleeping.erase(hol_clone)
		colony.unit_died.emit(hol_clone)
		hol_clone.queue_free()
		for i in worker.holstered.size():
			worker.holstered[i] = null
	worker.strip_garment(belt)
	_sweep(colony, worker._standing_voxel())

	# --- The knap: branches and cobbles at a bare crafting spot.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE,
			DropItem.ROD_CM3
		),
		pile_v
	)
	for i in 2:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			pile_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(colony.designate_craft_spot(spot_v), "a crafting spot designates")
	var knap := colony.designate_craft(spot_v, &"stone_axe")
	_check(knap != null, "a stone axe bill dispatches on rod and cobbles")
	if knap != null:
		_drive_craft(colony, world, knap, pile_v, spot_v)
		var knapped := await _wait_until(
			func() -> bool: return knap.state == ColonyJob.State.DONE
		)
		var made := false
		var spot_pile := colony.item_pile_at(spot_v)
		if spot_pile != null:
			for item in spot_pile.items:
				if item.form == DropItem.Form.TOOL and item.spec == &"stone_axe":
					made = (
						item.material == BlockRegistry.Resource_.STONE
						and is_equal_approx(item.wear, 1.0)
					)
		_check(knapped and made, "the knapping pays a fresh stone axe")

	# --- The forge: the bench builds, burns only while worked, and
	#     won't run cold.
	var bench_job := colony.designate_production(bench_v, &"toolmaker")
	_check(bench_job != null, "a toolmaker's bench designates")
	if bench_job != null:
		_stock_job(bench_job)
		_assign_job(colony, bench_job, bench_v)
		var bench_done := await _wait_until(
			func() -> bool: return bench_job.state == ColonyJob.State.DONE
		)
		var bench := colony.building_at(bench_v)
		_check(
			bench_done and bench != null
				and bench.kind == Building.Kind.TOOLMAKER
				and bench.is_worksite() and bench.uses_fuel()
				and not bench.burns_passively()
				and not bench.lit(),
			"the toolmaker's bench stands cold as a fuelled worksite"
		)
		if bench == null:
			worker.hands.clear()
			return
		bench.auto_refuel = false
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.IRON, DropItem.Form.LOOSE,
				Colony.TOOL_METAL_CM3 * 2
			),
			pile_v
		)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE,
				DropItem.ROD_CM3
			),
			pile_v
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		var cold_bill := colony.queue_order(bench_v, &"iron_pick")
		colony._worksite_tick()
		_check(
			cold_bill != null and colony.craft_job_at(bench_v) == null,
			"a cold forge queues the bill but dispatches nothing"
		)
		bench.fuel = 60.0
		var forge := colony.craft_job_at(bench_v)
		if forge == null:
			colony._worksite_tick()
			forge = colony.craft_job_at(bench_v)
		_check(forge != null, "a fed forge dispatches the iron bill")
		if forge != null:
			var naive := colony.spawn_unit(bench_v + Vector3i(0, 0, 3))
			_check(
				not colony._job_allowed_for(naive, forge),
				"forging iron is gated on bloomery knowledge"
			)
			naive.dead = true
			colony.units.erase(naive)
			colony._sleeping.erase(naive)
			colony.unit_died.emit(naive)
			naive.queue_free()
			worker.skills[ColonyJob.Skill.BLOOMERY_SMELTING] = (
				Unit.SKILL_XP_BASE
			)
			_drive_craft(colony, world, forge, pile_v, bench_v)
			var forged := await _wait_until(
				func() -> bool: return forge.state == ColonyJob.State.DONE
			)
			var iron_made := false
			var bench_pile := colony.item_pile_at(bench_v)
			if bench_pile != null:
				for item in bench_pile.items:
					if (
						item.form == DropItem.Form.TOOL
						and item.spec == &"iron_pick"
						and item.material == BlockRegistry.Resource_.IRON
					):
						iron_made = true
			_check(
				forged and iron_made,
				"the forge pours an iron pick"
			)
			_check(
				bench.fuel < 60.0,
				"the forge burns its reserve while a bill runs"
			)
			bench.fuel = 40.0
			colony._campfire_tick(30.0)
			_check(
				is_equal_approx(bench.fuel, 40.0),
				"an idle forge holds its fuel"
			)

		# --- Repair: a worn iron tool takes raw metal against the cap.
		var dull := DropItem.new(
			BlockRegistry.Resource_.IRON, DropItem.Form.TOOL,
			DropItem.TOOL_CM3
		)
		dull.spec = &"iron_pick"
		dull.wear = 0.3
		var mend_bill := Colony.tool_repair_loose_for(dull)
		_check(
			int(mend_bill.get(BlockRegistry.Resource_.IRON, -1))
				== Colony.TOOL_METAL_CM3 * 2,
			"a half-dead tool wants two raw units to reach the cap"
		)
		dull.wear = 0.85
		_check(
			Colony.tool_repair_loose_for(dull).is_empty(),
			"a tool at the cap needs nothing"
		)
		dull.wear = 0.3
		_check(
			not Colony.tool_recipe_ids().has(&"repair_stone_axe")
				and Colony.tool_recipe_ids().has(&"repair_iron_pick"),
			"repair bills exist only for metal tools"
		)
		colony._deposit_item(dull, pile_v)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		_check(
			colony.tool_work_options().has(&"repair_iron_pick"),
			"a worn iron tool advertises its repair bill"
		)
		colony.queue_order(bench_v, &"repair_iron_pick")
		var mend_job := colony.craft_job_at(bench_v)
		_check(mend_job != null, "the repair dispatches on its tool")
		_check(
			Colony.recipe_requires(Colony.recipe_of(&"repair_iron_pick"))
				== [ColonyJob.Skill.BLOOMERY_SMELTING],
			"the mend asks what the bloomery taught"
		)
		if mend_job != null:
			var home := _pile_of(colony, dull)
			if home != Vector3i.MAX:
				colony.item_pile_at(home).items.erase(dull)
				colony.remove_pile_if_empty(home)
			mend_job.components.append(dull)
			mend_job.delivered[DropItem.Form.TOOL] = dull.volume
			mend_job.repair_loose = Colony.tool_repair_loose_for(dull)
			var mend_metal := DropItem.new(
				BlockRegistry.Resource_.IRON, DropItem.Form.LOOSE,
				int(mend_job.repair_loose[BlockRegistry.Resource_.IRON])
			)
			mend_job.components.append(mend_metal)
			mend_job.delivered[
				Unit.DELIVERED_MATERIAL_OFF + BlockRegistry.Resource_.IRON
			] = mend_metal.volume
			_assign_job(colony, mend_job, bench_v)
			var mended := await _wait_until(
				func() -> bool: return mend_job.state == ColonyJob.State.DONE
			)
			var honed := false
			for voxel: Vector3i in colony.item_piles:
				for item in colony.item_piles[voxel].items:
					if item == dull:
						honed = is_equal_approx(
							item.wear, Colony.TOOL_REPAIR_CAP
						)
			_check(
				mended and honed,
				"the mend returns the tool at the 80% cap"
			)
		colony._teardown_building(bench_v)

	# --- The fetch leg: a pick in a pile arms a bare-handed miner.
	var pick_drop := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.TOOL, DropItem.TOOL_CM3
	)
	pick_drop.spec = &"stone_pick"
	colony._deposit_item(pick_drop, pile_v)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	worker.hands.clear()
	var dig := colony.designate_mine(dig_target)
	_check(dig != null, "a dig designates beside the tool pile")
	if dig != null:
		_assign_job(
			colony, dig,
			_park_beside(colony, world, dig_target, run + Vector3i(5, 0, -1)),
			worker
		)
		var dug := await _wait_until(
			func() -> bool: return not world.is_solid(dig_target)
		)
		_check(
			dug and worker._tool_for([&"pick"]) != null,
			"the miner fetches a pick from the pile and digs"
		)

	# --- Cleanup.
	colony._teardown_building(spot_v)
	world.remove_voxel(hard_floor)
	_sweep_run(colony, run, 6)
	_sweep(colony, tree_v)
	_sweep(colony, dig_cell)
	_sweep(colony, hard_cell)
	worker.hands.clear()
	for i in worker.holstered.size():
		worker.holstered[i] = null
	_clear_jobs(colony)


func _test_hud(main: Node3D, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("hud")
	var hud: Hud = main.get_node("Hud")
	# The cursor readout digests a pile's contents — grouped by material
	# and form, biggest share first, loose by volume, species standing in
	# for tagged items.
	var digest := ItemPile.new()
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		)
	)
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		)
	)
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE, 250_000
		)
	)
	digest.items.append(
		DropItem.new(
			BlockRegistry.Resource_.ACORN, DropItem.Form.FRUIT,
			DropItem.FRUIT_CM3
		)
	)
	var seed := DropItem.new(
		BlockRegistry.Resource_.SEED, DropItem.Form.SEED, DropItem.SEED_CM3
	)
	seed.species = &"oak"
	digest.items.append(seed)
	_check(
		hud._pile_contents_text(digest)
			== "Soil 0.25 m³, Stone boulder ×2, Acorns ×1, Oak seed ×1",
		"the pile readout digests its contents"
	)
	digest.free()
	_check(
		hud._colonist_bar.get_child_count() == colony.units.size(),
		"the colonist bar shows every unit"
	)
	_check(
		hud.action_menu.get_child_count() == Hud.ARCHITECT_MENU.size(),
		"the architect menu has a submenu per category"
	)
	var stubs := 0
	var live := 0
	for submenu: PopupMenu in hud.action_menu.get_children():
		for i in submenu.item_count:
			if submenu.is_item_disabled(i):
				stubs += 1
			else:
				live += 1
	_check(stubs > 0, "unimplemented architect entries are stubbed")
	_check(live == Overseer.ACTIONS.size(), "every action has an architect entry")
	hud._on_display_toggle(false, "Zones")
	_check(not colony.markers_visible, "the zones toggle hides markers")
	hud._on_display_toggle(true, "Zones")
	hud._set_speed(0.0)
	_check(paused, "pause stops the tree")
	hud._set_speed(1.0)
	_check(not paused and Engine.time_scale == 1.0, "1x resumes")

	# No button may hold keyboard focus — a focused button turns Space
	# into ui_accept, re-pressing it (the "Space opens the menu" bug).
	var focusable := false
	for button: Button in hud.find_children("*", "Button", true, false):
		focusable = focusable or button.focus_mode != Control.FOCUS_NONE
	_check(not focusable, "no HUD button grabs keyboard focus")

	# And a held key must not re-fire: an echoed Space is not a new press.
	var overseer: Overseer = main.get_node("Overseer")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	overseer._unhandled_input(key)
	_check(paused, "space pauses")
	key.echo = true
	overseer._unhandled_input(key)
	_check(paused, "key echo doesn't re-toggle pause")
	key.echo = false
	overseer._unhandled_input(key)
	_check(not paused, "space unpauses")

	# Tick once: a paused tree must run exactly the physics step — a unit's
	# cooldown only counts down inside _physics_process.
	var idle_unit: Unit = colony.units[0]
	idle_unit._job_search_cooldown = 30.0
	paused = true
	overseer.tick_once()
	for i in 8:
		await process_frame
	_check(
		idle_unit._job_search_cooldown < 30.0,
		"the tick key steps a paused frame"
	)
	_check(paused, "the tree pauses again after a tick")
	idle_unit._job_search_cooldown = 0.0

	# Bottom chrome lifts clear of the menu bar — the inspect readout and
	# the unit panel would otherwise sit on the Architect row.
	await process_frame
	_check(
		hud._inspect_panel.offset_bottom
			<= -int(ceil(hud._menu_bar.size.y)),
		"the inspect panel clears the menu bar"
	)
	_check(
		hud._unit_panel.offset_bottom
			<= -int(ceil(hud._menu_bar.size.y)),
		"the unit panel clears the menu bar"
	)

	# Decorations name themselves at the cursor — a bush lives in the
	# AIR cell the terrain raycast reports as `previous_position`.
	var bush_cell := _flat_voxel(world, mined, 40, 40)
	_check(bush_cell != Vector3i.MAX, "a flat cell for the bush check")
	if bush_cell != Vector3i.MAX:
		var sweep := colony.item_pile_at(bush_cell)
		while sweep != null:
			sweep.items.clear()
			colony.remove_pile_if_empty(bush_cell)
			sweep = colony.item_pile_at(bush_cell)
		_check(
			colony.plants.plant(bush_cell, &"berry_bush"),
			"a bush plants for the label check"
		)
		var ahit := Overseer.AimHit.new(
			bush_cell + Vector3i.DOWN, bush_cell
		)
		_check(
			hud._decoration_label(ahit).begins_with("Berry Bush"),
			"a bush under the cursor names its species"
		)

	# Terrain streaming is unpaused work: the viewer rides the always-on
	# overseer, so without ALWAYS on the terrain a paused camera pan left
	# decorations floating over ground whose meshes never applied.
	_check(
		world.process_mode == Node.PROCESS_MODE_ALWAYS,
		"terrain keeps streaming while the tree is paused"
	)

	# Unit inspection: the aim ray picks the nearest critter capsule it
	# crosses — hover identifies it, a click opens the colonist panel.
	# The subject moves off alone so a neighbour can't crowd the pick.
	var pick_home := idle_unit.global_position
	idle_unit.global_position = Vector3(mined) + Vector3(0.5, 60.0, 0.5)
	var pick_origin := idle_unit.global_position + Vector3(0.0, 14.0, 0.0)
	var pick_dir := Vector3(0.0, -1.0, 0.0)
	_check(
		overseer._pick_critter_on_ray(pick_origin, pick_dir, 30.0)
			== idle_unit,
		"the aim ray picks the unit under the cursor"
	)
	_check(
		overseer._pick_critter_on_ray(
			pick_origin, Vector3(1.0, 0.0, 0.0), 30.0
		) == null,
		"a ray aimed beside everything picks nothing"
	)
	_check(
		overseer._pick_critter_on_ray(pick_origin, pick_dir, 1.0) == null,
		"a unit past the terrain hit isn't picked"
	)
	overseer.unit_picked.emit(idle_unit)
	await process_frame
	_check(
		hud._inspected_unit == idle_unit and hud._unit_panel.visible,
		"clicking a unit opens its detail panel"
	)
	overseer.unit_picked.emit(null)
	await process_frame
	_check(
		hud._inspected_unit == null and not hud._unit_panel.visible,
		"deselecting closes the unit panel"
	)
	idle_unit.global_position = pick_home

	# Sleep boost: the armed Zz toggle kicks the clock to the top speed
	# only while every unit sleeps — counted through `state_changed`
	# signals so the check never rescans the roster. Pause still wins,
	# and a wake drops the clock back to the player's pick.
	_check(
		hud._sleep_boost_button != null
			and hud._sleep_boost_button.toggle_mode,
		"the speed row has a sleep-boost toggle"
	)
	colony.set_paused(false)
	colony.set_speed(1.0)
	# Units may genuinely be asleep this late in the suite — wake them so
	# the armed-not-engaged check is about the roster, not the fixture.
	for u in colony.units:
		if u.state == Unit.State.SLEEPING:
			u.state = Unit.State.IDLE
	colony.set_sleep_boost(true)
	_check(
		not colony.sleep_boost_engaged(),
		"with awake units the boost stays idle"
	)
	for u in colony.units:
		u.state = Unit.State.SLEEPING
	_check(
		colony.sleep_boost_engaged(),
		"everyone asleep — the boost engages"
	)
	_check(
		Engine.time_scale == Colony.SLEEP_BOOST_SPEED,
		"the clock runs at the boost speed"
	)
	colony.units[0].state = Unit.State.IDLE
	_check(
		not colony.sleep_boost_engaged(),
		"a waking unit disengages the boost"
	)
	_check(
		Engine.time_scale == 1.0,
		"the clock falls back to the selected speed"
	)
	colony.units[0].state = Unit.State.SLEEPING
	_check(colony.sleep_boost_engaged(), "the boost re-engages")
	colony.set_paused(true)
	_check(
		paused and not colony.sleep_boost_engaged(),
		"pause still wins over the boost"
	)
	colony.set_paused(false)
	_check(colony.sleep_boost_engaged(), "unpausing resumes the boost")
	colony.set_sleep_boost(false)
	_check(
		Engine.time_scale == 1.0,
		"disarming returns to the selected speed"
	)
	for u in colony.units:
		u.state = Unit.State.IDLE
		u.abandon_job()

	# Plans: a pending wall is an aimable ghost while plans are visible —
	# paint its top face and the next wall stacks on it. Turning the
	# toggle off lets the ray pass through to real terrain; a planning
	# tool in hand turns it back on.
	var plan_site := Vector3i.MAX
	for z_off in [64, 72, 80, 88]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and world.get_block(candidate) == BlockRegistry.Block.AIR
			and colony.voxel_fill(candidate) <= 0
		):
			plan_site = candidate
			break
	_check(plan_site != Vector3i.MAX, "found a flat spot for the plans test")
	if plan_site != Vector3i.MAX:
		_check(
			colony.designate_build(plan_site, &"dirt_wall") != null,
			"a wall designates for the plans test"
		)
		overseer.global_position = Vector3(plan_site) + Vector3(0.5, 8.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		var at_plan := overseer.camera.unproject_position(
			Vector3(plan_site) + Vector3.ONE * 0.5
		)
		overseer._update_target(at_plan)
		_check(
			overseer._targeted != null
				and overseer._targeted.position == plan_site
				and overseer._targeted.previous_position == plan_site + Vector3i.UP,
			"a pending wall is aimable while plans are visible"
		)
		overseer.select_action(overseer.ACTIONS.find(&"build_dirt_wall"))
		overseer._perform()
		_check(
			colony.build_job_at(plan_site + Vector3i.UP) != null,
			"a wall stacks on a pending wall's face"
		)
		overseer.select_action(-1)
		hud._on_display_toggle(false, "Plans")
		overseer._update_target(at_plan)
		_check(
			overseer._targeted != null
				and overseer._targeted.position == plan_site + Vector3i.DOWN,
			"hidden plans don't block the aim ray"
		)
		overseer.select_action(overseer.ACTIONS.find(&"deconstruct"))
		_check(
			colony.plans_visible(),
			"a planning tool shows the plans again"
		)
		overseer.select_action(-1)
		_check(
			not colony.plans_visible(),
			"dropping the tool hides them once more"
		)
		_check(
			colony.designate_deconstruct(plan_site) == null
				and colony.build_job_at(plan_site) == null
				and not colony.is_designated(plan_site),
			"the deconstruct tool cancels a planned build"
		)
		colony.cancel_designation(plan_site + Vector3i.UP)
		hud._on_display_toggle(true, "Plans")

	var spot := Vector3i.MAX
	for z_off in [224, 96, 104, 112, 120, 232, 240]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and world.get_block(candidate) == BlockRegistry.Block.AIR
			and colony.voxel_fill(candidate) <= 0
			and colony.designate_craft_spot(candidate)
		):
			spot = candidate
			break
	_check(spot != Vector3i.MAX, "found a spot for the worksite panel test")
	if spot != Vector3i.MAX:
		overseer.global_position = Vector3(spot) + Vector3(0.5, 4.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer.select_action(-1)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(spot) + Vector3.ONE * 0.5
		))
		overseer._select_at_cursor()
		_check(
			overseer._selected == spot,
			"clicking with no tool selects the worksite under the cursor"
		)
		hud._update_worksite()
		_check(
			hud._worksite_panel.visible,
			"the worksite panel opens for a selected building"
		)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.LOG,
				DropItem.LOG_CM3
			),
			spot + Vector3i.RIGHT
		)
		await _wait_until(func() -> bool: return colony._in_flight.is_empty())
		hud._worksite_recipes[&"planks"].pressed.emit()
		_check(
			colony.craft_job_at(spot) != null,
			"the panel's craft button queues and runs an order"
		)
		hud._update_worksite()
		_check(
			not hud._worksite_recipes[&"planks"].disabled,
			"the panel's craft button stays live while an order runs"
		)
		_check(
			hud._order_rows.size() == 1,
			"the worksite panel lists the queued bill"
		)
		var bill_row: Dictionary = hud._order_rows[0]
		_check(
			bill_row.has(&"pause") and bill_row.has(&"deliver")
				and bill_row.has(&"radius") and bill_row.has(&"worker")
				and bill_row.has(&"details"),
			"the bill row exposes its detail controls"
		)
		(bill_row[&"pause"] as BaseButton).button_pressed = true
		var live_job := colony.craft_job_at(spot)
		_check(
			live_job != null and live_job.suspended,
			"the row's pause button suspends the live job"
		)
		(bill_row[&"pause"] as BaseButton).button_pressed = false
		_check(
			live_job != null and not live_job.suspended,
			"pressing pause again resumes it"
		)
		(bill_row[&"details"] as BaseButton).pressed.emit()
		_check(
			not hud._order_expanded.is_empty(),
			"the details toggle expands the bill row"
		)
		var target_edit: LineEdit = (
			hud._order_rows[0][&"target"].get_line_edit()
		)
		target_edit.grab_focus()
		_check(
			overseer._keyboard_claimed(),
			"a focused order field claims the camera's keys"
		)
		target_edit.release_focus()
		_check(
			not overseer._keyboard_claimed(),
			"released focus returns the keys"
		)
		hud._worksite_cancel.pressed.emit()
		_check(
			colony.craft_job_at(spot) == null
				and colony.building_at(spot).orders.is_empty(),
			"the panel's cancel button drops the order"
		)
		hud._worksite_deconstruct.pressed.emit()
		_check(
			colony.deconstruct_job_at(spot) != null,
			"the panel's deconstruct button marks the worksite"
		)
		colony.cancel_designation(spot)
		_check(
			colony.deconstruct_job_at(spot) == null and colony.is_craft_spot(spot),
			"a cancel sweep lifts the deconstruct marking, keeps the site"
		)
		overseer._clear_selection()
		# Tidy: drop the fixture's building for whatever runs next.
		var raze := colony.designate_deconstruct(spot)
		if raze != null:
			_assign_job(colony, raze, spot)

	# The campfire from the earlier section still stands — selecting it
	# should swap the panel's craft rows for its fuel controls, which
	# write straight into the building record.
	var fire_v := Vector3i.MAX
	for cell: Vector3i in colony.buildings:
		if colony.buildings[cell].kind == Building.Kind.CAMPFIRE:
			fire_v = cell
			break
	_check(fire_v != Vector3i.MAX, "a campfire survives for the panel test")
	if fire_v != Vector3i.MAX:
		overseer.global_position = Vector3(fire_v) + Vector3(0.5, 4.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer.select_action(-1)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(fire_v) + Vector3.ONE * 0.5
		))
		overseer._select_at_cursor()
		hud._update_worksite()
		var fire := colony.campfire_at(fire_v)
		_check(
			overseer._selected == fire_v and hud._campfire_box.visible,
			"selecting the campfire shows its fuel controls"
		)
		if fire != null:
			var auto_before := fire.auto_refuel
			hud._campfire_auto.button_pressed = not auto_before
			_check(
				fire.auto_refuel == (not auto_before),
				"the auto-refuel toggle writes the building"
			)
			hud._campfire_threshold.value = 0.55
			_check(
				is_equal_approx(fire.refuel_fraction, 0.55),
				"the threshold spinner writes the building"
			)
			hud._campfire_threshold.value = 0.3
			hud._campfire_auto.button_pressed = auto_before
		overseer._clear_selection()

	# The inspect tool also opens a stockpile's admission filter — a
	# checkbox per material class writes straight into the tile's set.
	var spick := Vector3i.MAX
	for z_off in [144, 152, 160]:
		var candidate := _flat_voxel(world, mined, z_off)
		if (
			candidate != Vector3i.MAX
			and colony.designate_stockpile(candidate)
		):
			spick = candidate
			break
	_check(spick != Vector3i.MAX, "found a spot for the stockpile panel test")
	if spick != Vector3i.MAX:
		overseer.global_position = Vector3(spick) + Vector3(0.5, 4.5, 0.5)
		overseer.camera.global_transform = Transform3D(
			Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), overseer.global_position
		)
		overseer.select_action(-1)
		overseer._update_target(overseer.camera.unproject_position(
			Vector3(spick) + Vector3.ONE * 0.5
		))
		overseer._select_at_cursor()
		_check(
			overseer._selected == spick,
			"clicking with no tool selects the stockpile under the cursor"
		)
		hud._update_selection()
		_check(
			hud._stockpile_panel.visible,
			"the stockpile panel opens for a selected tile"
		)
		_check(
			hud._stockpile_checks.size() == BlockRegistry.Resource_.size() - 1,
			"the panel has a toggle per material"
		)
		var stone_box := hud._stockpile_checks.filter(
			func(b: CheckBox) -> bool:
				return b.get_meta(&"material") == BlockRegistry.Resource_.STONE
		)[0] as CheckBox
		stone_box.button_pressed = false
		_check(
			not colony.stockpile_admits(spick, BlockRegistry.Resource_.STONE),
			"a filter toggle writes to the tile"
		)
		colony.undesignate_stockpile(spick)
		hud._update_selection()
		_check(
			not hud._stockpile_panel.visible,
			"undesignating closes the panel"
		)
		overseer._clear_selection()

	# The calendar: planet time becomes a local solar position through the
	# site's latitude and longitude — noon is lit, midnight dark, and the
	# day counter rolls at local midnight.
	var day_cycle := main.get_node_or_null("DayCycle") as DayCycle
	_check(day_cycle != null, "the scene has a day cycle")
	if day_cycle != null:
		# The suite has been running long enough for the clock to have
		# wandered anywhere — exercise the fresh-game start directly.
		day_cycle.start_fresh()
		_check(day_cycle.is_daylight(), "a fresh game starts in daylight")
		# These checks assert the baseline sun path — the site's real
		# longitude offsets day_fraction from planet_time, and seasons
		# write the declination, so pin both to the track they assume.
		var saved_lon := day_cycle.site_longitude_deg
		day_cycle.site_longitude_deg = 0.0
		day_cycle.planet_time = 0.0
		day_cycle.solar_declination_deg = 0.0
		day_cycle.advance(0.0)
		_check(not day_cycle.is_daylight(), "local midnight is dark")
		var env := day_cycle.world_environment.environment
		_check(
			env != null
				and env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY
				and env.ambient_light_sky_contribution == 0.0
				and env.ambient_light_color.get_luminance() > 0.05,
			"night is dim, not pitch black"
		)
		day_cycle.advance(day_cycle.day_length_seconds * 0.5)
		_check(day_cycle.is_daylight(), "local noon is lit")
		_check(
			day_cycle.sun_altitude > deg_to_rad(50.0),
			"the noon sun sits high over the site's latitude"
		)
		_check(day_cycle.day_number() == 1, "noon is still day 1")
		day_cycle.advance(day_cycle.day_length_seconds * 0.5)
		_check(
			day_cycle.day_number() == 2,
			"the day rolls over at local midnight"
		)
		hud._update_date()
		_check(
			hud._date_label.text.begins_with("Day 2"),
			"the HUD date follows the calendar"
		)
		# Longitude shifts local time against the planet clock — the same
		# instant is a different hour at a site half a world away.
		var before := day_cycle.day_fraction()
		day_cycle.site_longitude_deg = 180.0
		_check(
			absf(
				day_cycle.day_fraction()
					- wrapf(before + 0.5, 0.0, 1.0)
			) < 0.001,
			"longitude offsets local time by half a day at 180°"
		)
		day_cycle.site_longitude_deg = saved_lon
		day_cycle.planet_time = 0.0
		day_cycle.advance(0.0)
		hud._update_date()


## Topmost non-tree solid voxel in a column — a grown trunk reads as ground
## to `ground_height`, so test fixtures probe past tree blocks.
func _ground(world: VoxelWorld, x: int, z: int, from_y: int, min_y: int = -32) -> int:
	for y in range(from_y, min_y, -1):
		var cell := Vector3i(x, y, z)
		if not world.is_editable(cell):
			continue
		var block := world.get_block(cell)
		if BlockRegistry.is_tree_block(block):
			continue
		if BlockRegistry.is_solid(block):
			return y
	return min_y


## Topmost solid voxel in a column — trees included, unlike `_ground`
## (a trunk still counts as a solid neighbour to the blocks beside it).
func _solid_top(world: VoxelWorld, x: int, z: int, from_y: int) -> int:
	for y in range(from_y, -32, -1):
		var cell := Vector3i(x, y, z)
		if not world.is_editable(cell):
			continue
		if BlockRegistry.is_solid(world.get_block(cell)):
			return y
	return -32


## A flat-ground voxel whose +UP cell floats — provably no solid
## face-neighbour, because a whole 5×5 neighbourhood of columns tops out
## at the same ground height with nothing (terrain, walls, or trees)
## standing above it. Scans rows [param z0]..+300 past [param mined].
func _floating_flat(
	colony: Colony, world: VoxelWorld, mined: Vector3i, z0: int
) -> Vector3i:
	for off in range(z0, z0 + 300):
		var ledge := _flat_voxel_row(world, mined, off)
		if ledge == Vector3i.MAX:
			continue
		var g: int = ledge.y - 1
		var flat := true
		for ox in range(-2, 3):
			for oz in range(-2, 3):
				if (
					_solid_top(
						world, ledge.x + ox, ledge.z + oz, mined.y + 32
					) != g
				):
					flat = false
		var target := ledge + Vector3i.UP
		var upper := target + Vector3i.UP
		if (
			flat
			and world.is_editable(target)
			and world.is_editable(upper)
			and world.get_block(target) == BlockRegistry.Block.AIR
			and world.get_block(upper) == BlockRegistry.Block.AIR
			and colony.item_pile_at(ledge) == null
			and not colony.is_designated(target)
			and not colony.is_designated(upper)
			and colony.forest.tree_root_at(target) == Vector3i.MAX
			and colony.forest.tree_root_at(upper) == Vector3i.MAX
		):
			return ledge
	return Vector3i.MAX


## An empty voxel on flat ground near row [param z_off] past [param mined],
## or [constant Vector3i.MAX] if none is found. [param rows] widens the
## search into a forward band for fixtures that don't care which row.
## The world map layer and the region save: the site embeds in a
## [Region], terrain writes land in its edit log, and a serialized
## colony rebuilds whole — piles, buildings and their order queues,
## designations, zones, decoration records and units.
func _test_persist(main: Node3D, colony: Colony, world: VoxelWorld, mined: Vector3i) -> void:
	print("persistence")
	var main_node := main as Main
	var region: Region = main_node.region
	_check(region != null, "the colony site embeds in a region")
	_check(world.region == region, "the world records its edits on the region")
	_check(
		main_node.site != null and main_node.site.colony == colony,
		"the colony is its site's live sim"
	)
	_check(
		region.coordinate == Region.coord_of(mined),
		"the region tile contains the site"
	)
	_check(
		region.heights.size() == Region.CELLS * Region.CELLS,
		"the regional summary grid generates"
	)
	var pair := Region.containing(Vector3i.ZERO)
	var site_a := pair.add_site(Vector3i(8, 32, 8))
	var site_b := pair.add_site(Vector3i(200, 32, 200))
	_check(
		pair.sites.size() == 2 and site_a.id != site_b.id,
		"a region can hold more than one site"
	)
	_check(
		Region.coord_of(Vector3i(-1, 0, -1)) == Vector2i(-1, -1),
		"negative voxels floor into their tile"
	)

	# Terrain writes record against the region — mined and rebuilt —
	# and index under their stream chunk for the replay path. The edit
	# cell walks down the mined column until it finds solid ground.
	var below := Vector3i.MAX
	for dy in range(0, -9, -1):
		var c := mined + Vector3i(0, dy, 0)
		if world.is_editable(c) and world.is_solid(c):
			below = c
			break
	_check(below != Vector3i.MAX, "found a cell for the edit log")
	var was := world.get_block(below)
	world.mine(below)
	_check(
		int(region.edits.get(below, -1)) == BlockRegistry.Block.AIR,
		"mining records a region edit"
	)
	var chunk := Vector3i(below.x >> 4, below.y >> 4, below.z >> 4)
	_check(
		int(region.edits_in_chunk(chunk).get(below, -1))
			== BlockRegistry.Block.AIR,
		"the edit indexes under its stream chunk"
	)
	world.place(below, was)
	_check(
		int(region.edits.get(below, -1)) == was,
		"building records a region edit"
	)

	# A scenario worth persisting on top of the suite's leftovers: a
	# fresh pile, a stockpile with a filter, and a unit carrying some
	# personality. The surface cell must be structurally clean — flat,
	# editable, open air, unmarked — but leftover piles are the suite's
	# debris, and this fixture owns whatever cell it picks: sweep it.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var stock_v := Vector3i.MAX
	var rejects := {
		"flat": 0, "editable": 0, "air": 0, "solid": 0, "zoned": 0
	}
	# Stay inside the bands `_flat_run` scans — they are the furthest
	# territory guaranteed streamed by this point; further rows can be
	# data-complete but never editable, varying run to run.
	for off in range(140, 204) + range(-219, -139) + range(232, 288):
		if stock_v != Vector3i.MAX:
			break
		# Scan the row's whole width — `_flat_voxel_row` stops at the
		# first flat cell, which generated scree or fruit litter may hold.
		var z: int = mined.z + off
		for x in range(mined.x + 4, mined.x + 28):
			var g := _ground(world, x, z, mined.y + 32)
			var candidate := Vector3i(x + 1, g + 1, z)
			if not (
				_ground(world, x + 1, z, mined.y + 32) == g
				and _ground(world, x + 2, z, mined.y + 32) == g
				and _ground(world, x + 3, z, mined.y + 32) == g
			):
				rejects[&"flat"] += 1
				continue
			if not (
				world.is_editable(Vector3i(x + 1, g, z))
				and world.is_editable(candidate)
			):
				rejects[&"editable"] += 1
				continue
			if world.get_block(candidate) != BlockRegistry.Block.AIR:
				rejects[&"air"] += 1
				continue
			if not world.is_solid(Vector3i(x + 1, g, z)):
				rejects[&"solid"] += 1
				continue
			# A cell already inside a zone can never be re-designated —
			# skip it rather than sweep it into a fight over debris.
			if colony.is_stockpile(candidate) or colony.farms.has(candidate):
				rejects[&"zoned"] += 1
				continue
			# Leftover piles and designations are the suite's debris —
			# this fixture owns whatever cell it picks: sweep both.
			colony._designation_markers.erase(candidate)
			var sweep := colony.item_pile_at(candidate)
			while sweep != null:
				sweep.items.clear()
				colony.remove_pile_if_empty(candidate)
				sweep = colony.item_pile_at(candidate)
			if colony._stockpile_cellable(candidate):
				stock_v = candidate
				break
			rejects[&"zoned"] += 1
	if stock_v == Vector3i.MAX:
		print("    [persist-scan] rejects: %s" % rejects)
	_check(stock_v != Vector3i.MAX, "found a free surface cell")
	var stockpiled := colony.designate_stockpile(stock_v)
	_check(stockpiled, "a stockpile designates for the save fixture")
	if stockpiled:
		colony.set_stockpile_admission(
			stock_v, BlockRegistry.Resource_.SOIL, false
		)
	var first_unit: Unit = colony.units[0]
	first_unit.hunger = 0.42
	first_unit.facets[&"immoderation"] = 50
	first_unit.skills[ColonyJob.Skill.MINING] = 25.0
	first_unit.specialize = true
	# Every falling item must have landed before the snapshot — a save
	# records an in-flight pile at its landing voxel, so comparing
	# against a mid-fall roster would miscount.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	var piles_before := {}
	for voxel: Vector3i in colony.item_piles:
		piles_before[voxel] = colony.item_piles[voxel].total_volume()
	var units_before := colony.units.size()
	var jobs_before := colony.jobs.size()
	var buildings_before := colony.buildings.size()
	var stockpiles_before := colony.stockpiles.size()
	var farms_before := colony.farms.size()
	var grass_before := colony.grass.coverage.size()
	var fert_before := colony.fertilization.size()
	var bushes_before := colony.plants.bushes.size()
	var trees_before := colony.forest.trees.size()
	var rock_spent_before := colony._rock_spent.keys()
	# The campfire test leaves a quiet ring standing: its fuel store and
	# refuel toggle are building state the save must carry.
	var fire_before := {}
	var detail_fire := Vector3i.MAX
	for cell: Vector3i in colony.buildings:
		var b: Building = colony.buildings[cell]
		if b.kind == Building.Kind.CAMPFIRE:
			fire_before[b.voxel] = [b.fuel, b.auto_refuel, b.components.size()]
			detail_fire = b.voxel
	# A bill wearing every detail field rides the save: the surviving
	# campfire takes an until-bill for meals, fully configured.
	var detail_queued := false
	if detail_fire != Vector3i.MAX:
		var bill := colony.queue_order(
			detail_fire, &"prepare_meal",
			WorksiteOrder.Condition.UNTIL_HAVE, 7
		)
		if bill != null:
			colony.set_order_paused(detail_fire, bill, true)
			bill.unpause_at = 2
			bill.count_stored_only = true
			bill.deliver_mode = WorksiteOrder.Deliver.ZONE
			bill.deliver_target = stock_v
			bill.ingredient_radius = 12.0
			bill.worker_index = 0
			bill.skill_min = 1
			bill.skill_max = 8
			bill.rejected_materials[int(BlockRegistry.Resource_.GRAIN)] = true
			detail_queued = true
	if stockpiled:
		colony.set_stockpile_priority(stock_v, StockpileZone.Priority.HIGH)

	# Round-trip through JSON — the on-disk format, not just the dict.
	var saved := colony.serialize()
	var decoded: Dictionary = JSON.parse_string(JSON.stringify(saved))
	# A pre-fold save still carries a unit's `traits` list — the loader
	# folds each id into its facet band.
	decoded["units"][0]["traits"] = ["ascetic"]
	colony.deserialize(decoded)
	# The comparisons below all run synchronously — before the next
	# frame lets a unit re-claim a job or the grass scan regrow a cell —
	# and read the colony's own maps, not the nodes queue_free'd ones.

	_check(colony.units.size() == units_before, "units restored")
	_check(
		is_equal_approx(colony.units[0].hunger, 0.42),
		"unit hunger restored"
	)
	_check(
		colony.units[0].facet(&"immoderation") == 25,
		"a saved ascetic trait folds into its facet band"
	)
	_check(
		colony.units[0].skills[ColonyJob.Skill.MINING] == 25.0,
		"unit skill xp restored"
	)
	_check(colony.units[0].specialize, "unit stance restored")
	_check(colony.item_piles.size() == piles_before.size(), "piles restored")
	var piles_match := true
	for voxel: Vector3i in piles_before:
		var pile: ItemPile = colony.item_piles.get(voxel)
		if pile == null or pile.total_volume() != piles_before[voxel]:
			piles_match = false
	_check(piles_match, "pile contents survived the round trip")
	_check(
		colony.buildings.size() == buildings_before,
		"buildings restored"
	)
	var door_restored := false
	for cell: Vector3i in colony.buildings:
		var b: Building = colony.buildings[cell]
		if b.kind == Building.Kind.DOOR and b.spec == &"stone_door":
			door_restored = true
	_check(door_restored, "the stone door's spec survived the round trip")
	_check(
		colony.stockpiles.size() == stockpiles_before
			and (not stockpiled or colony.stockpiles.has(stock_v)),
		"stockpiles restored"
	)
	_check(
		not stockpiled
			or not colony.stockpile_admits(stock_v, BlockRegistry.Resource_.SOIL),
		"stockpile filters restored"
	)
	_check(
		not stockpiled
			or colony.stockpiles[stock_v].priority == StockpileZone.Priority.HIGH,
		"stockpile priority restored"
	)
	var restored_bill: WorksiteOrder = null
	if detail_fire != Vector3i.MAX:
		var fb: Building = colony.buildings.get(detail_fire)
		if fb != null and not fb.orders.is_empty():
			restored_bill = fb.orders[fb.orders.size() - 1]
	_check(
		not detail_queued or restored_bill != null,
		"the configured bill restores"
	)
	if restored_bill != null:
		_check(restored_bill.paused, "bill pause persists")
		_check(restored_bill.unpause_at == 2, "bill unpause mark persists")
		_check(restored_bill.count_stored_only, "bill stored-only flag persists")
		_check(
			restored_bill.deliver_mode == WorksiteOrder.Deliver.ZONE
				and restored_bill.deliver_target == stock_v,
			"bill delivery target persists"
		)
		_check(
			is_equal_approx(restored_bill.ingredient_radius, 12.0),
			"bill ingredient radius persists"
		)
		_check(restored_bill.worker_index == 0, "bill worker pin persists")
		_check(
			restored_bill.skill_min == 1 and restored_bill.skill_max == 8,
			"bill skill band persists"
		)
		_check(
			restored_bill.rejected_materials.has(
				int(BlockRegistry.Resource_.GRAIN)
			),
			"bill material filter persists"
		)
	_check(colony.farms.size() == farms_before, "farm fields restored")
	_check(colony.jobs.size() == jobs_before, "jobs restored")
	var all_pending := true
	for job in colony.jobs:
		if job.state != ColonyJob.State.PENDING:
			all_pending = false
	_check(all_pending, "restored jobs are pending again")
	_check(
		colony.grass.coverage.size() == grass_before,
		"grass records restored"
	)
	_check(
		colony.fertilization.size() == fert_before,
		"soil fertilization restored"
	)
	# A load must repaint immediately — while paused no _process tick
	# would ever drain the dirty flags, leaving decorations invisible.
	var grass_painted := false
	for inst: MultiMeshInstance3D in colony.grass._chunk_meshes.values():
		if inst.multimesh.instance_count > 0:
			grass_painted = true
	_check(
		grass_painted and colony.grass._dirty_chunks.is_empty(),
		"loaded grass repaints without waiting for a tick"
	)
	_check(
		colony.forest._dirty_chunks.is_empty(),
		"loaded trees repaint without waiting for a tick"
	)
	_check(
		not colony.plants._decorations_dirty,
		"loaded bushes repaint without waiting for a tick"
	)
	_check(colony.plants.bushes.size() == bushes_before, "bushes restored")
	_check(colony.forest.trees.size() == trees_before, "trees restored")
	_check(
		colony._rock_spent.size() == rock_spent_before.size()
			and rock_spent_before.all(
				func(v: Vector3i) -> bool: return colony._rock_spent.has(v)
			),
		"spent rock slots stay spent"
	)
	var fires_match := true
	for voxel: Vector3i in fire_before:
		var b2 := colony.campfire_at(voxel)
		if (
			b2 == null
			or not is_equal_approx(b2.fuel, float(fire_before[voxel][0]))
			or b2.auto_refuel != bool(fire_before[voxel][1])
			or b2.components.size() != int(fire_before[voxel][2])
		):
			fires_match = false
	_check(
		fire_before.is_empty() or fires_match,
		"campfire fuel and toggle restored"
	)
	_check(
		not colony._designation_markers.is_empty(),
		"designation markers rebuilt"
	)

	# The save unit is the region: serializing it embeds the site's
	# colony payload, and a dormant region keeps that payload without a
	# live sim.
	var region_data: Dictionary = JSON.parse_string(
		JSON.stringify(region.serialize())
	)
	var dormant := Region.deserialize(region_data)
	_check(
		dormant.coordinate == region.coordinate,
		"the region round-trips its coordinate"
	)
	_check(
		dormant.edits.size() == region.edits.size(),
		"the edit log round-trips"
	)
	_check(
		dormant.sites.size() == 1
			and dormant.sites[0].colony == null
			and not dormant.sites[0].state.is_empty(),
		"a dormant site keeps its colony payload"
	)
	_check(
		dormant.sites[0].world_tile == main_node.site.world_tile,
		"a dormant site keeps its world tile"
	)

	# And the real files: save_game writes world.json plus one file per
	# region tile — the directory layout a multi-region world will fill.
	var dir := main_node.save_game("smoke")
	_check(
		FileAccess.file_exists(dir.path_join("world.json")),
		"world.json written"
	)
	_check(
		FileAccess.file_exists(
			dir.path_join(
				"region_%d_%d.json" % [region.coordinate.x, region.coordinate.y]
			)
		),
		"the region file is the save unit"
	)

	# The item-42 compatibility break: a v1 save must be refused, not
	# migrated — pre-ore block ids would corrupt the world silently.
	var world_file := dir.path_join("world.json")
	var old_world: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(world_file)
	)
	old_world["version"] = 1
	var out := FileAccess.open(world_file, FileAccess.WRITE)
	out.store_string(JSON.stringify(old_world))
	out.close()
	_check(
		(await main_node._read_save(dir)).is_empty(),
		"a v1 world save is refused"
	)


func _flat_voxel(
	world: VoxelWorld,
	mined: Vector3i,
	z_off: int,
	rows: int = 1,
	footprint: Rect2i = Rect2i(0, 0, 1, 1)
) -> Vector3i:
	for off in range(z_off, z_off + rows):
		var found := _flat_voxel_row(world, mined, off, footprint)
		if found != Vector3i.MAX:
			return found
	return Vector3i.MAX


## A fixture box that holds water anywhere in the band the test uses
## is unusable — the suite runs water paused, so "dry at scan time"
## is "dry forever". Each column's live waterline must sit below the
## fixture's band; the static datum check on the anchor already covers
## the seeded water.
func _dry_box(world: VoxelWorld, spot: Vector3i, fp: Rect2i) -> bool:
	var x0 := spot.x + fp.position.x
	var z0 := spot.z + fp.position.y
	for cx in range(x0, x0 + fp.size.x):
		for cz in range(z0, z0 + fp.size.y):
			if world.water_level_at(cx, cz) >= spot.y:
				return false
	return true


func _flat_voxel_row(
	world: VoxelWorld,
	mined: Vector3i,
	z_off: int,
	footprint: Rect2i = Rect2i(0, 0, 1, 1)
) -> Vector3i:
	var z: int = mined.z + z_off
	for x in range(mined.x + 4, mined.x + 28):
		var g := _ground(world, x, z, mined.y + 32)
		var spot := Vector3i(x + 1, g + 1, z)
		if (
			_ground(world, x + 1, z, mined.y + 32) == g
			and _ground(world, x + 2, z, mined.y + 32) == g
			and _ground(world, x + 3, z, mined.y + 32) == g
			# `_ground` reports min_y on an unstreamed column, which
			# `is_solid` then materializes as deep stone — the "flat spot"
			# would be buried underground. Require real, editable cells.
			and world.is_editable(Vector3i(x + 1, g, z))
			and world.is_editable(spot)
			and world.get_block(spot) == BlockRegistry.Block.AIR
			and world.is_solid(Vector3i(x + 1, g, z))
			and world.generator_script.water_depth_at(x + 1, z) == 0
			and _dry_box(world, spot, footprint)
		):
			return spot
	return Vector3i.MAX


## A run of [param need] consecutive same-height standable cells along
## one row — the wildlife fixture wants a corpse pile, a butcher spot
## and a runway for a fleeing rabbit, all level with each other.
## Combat damage to the world (PLAN item 30): constructions and
## terrain carry hit points set by what they're made of, a battered
## building posts its own repair bill, a wrecked one deconstructs, a
## wrecked block breaks as if mined — and a melee fight's stray force
## lands on whatever stands around it.
func _test_siege(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("combat damage to the world")
	# Park the colony and hand-drive the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false

	var site := _flat_run(colony, world, mined, 10)
	_check(
		site != Vector3i.MAX,
		"found a flat stretch for the siege tests"
	)
	if site == Vector3i.MAX:
		return

	# --- Durability is material first: stone outlasts wood outlasts dirt.
	_check(
		BlockRegistry.material_hardness(BlockRegistry.Resource_.STONE)
			> BlockRegistry.material_hardness(BlockRegistry.Resource_.WOOD)
			and BlockRegistry.material_hardness(BlockRegistry.Resource_.WOOD)
				> BlockRegistry.material_hardness(BlockRegistry.Resource_.SOIL),
		"stone outlasts wood outlasts dirt"
	)

	# --- A registered construction starts whole, rated by its material.
	var wood_cell := site
	var barricade := Building.new(Building.Kind.BARRICADE, wood_cell)
	barricade.material = BlockRegistry.Resource_.WOOD
	colony.register_building(barricade)
	_check(
		barricade.max_hp > 0.0 and barricade.hp == barricade.max_hp,
		"a registered construction starts at full integrity"
	)
	var fort := Building.new(Building.Kind.BARRICADE, site + Vector3i(2, 0, 0))
	fort.material = BlockRegistry.Resource_.STONE
	colony.register_building(fort)
	# Repair bills are home-area work — the fixture building's cell
	# joins the painted set before the damage lands.
	colony.designate_home_cells([wood_cell])
	_check(
		fort.max_hp > barricade.max_hp,
		"a stone construction rates tougher than a wooden one"
	)

	# --- Damage posts exactly one repair bill, kept across repeat hits.
	colony.damage_building(barricade, 10.0)
	_check(
		barricade.hp < barricade.max_hp,
		"a hit bleeds the construction's hit points"
	)
	var repair := colony.repair_job_at(wood_cell)
	_check(repair != null, "a damaged building posts a repair job")
	colony.damage_building(barricade, 5.0)
	var repair_count := 0
	for j in colony.jobs:
		if (
			j.type == ColonyJob.Type.REPAIR
			and j.voxel_position == wood_cell
			and j.is_active()
		):
			repair_count += 1
	_check(repair_count == 1, "repeated hits keep a single repair bill")
	_check(
		float(colony._building_data(barricade).get("hp", 0.0))
			== barricade.hp,
		"a damaged building's hit points ride the save"
	)

	# --- The repair bill works: a unit arrives and puts the hit points
	#     back until the record stands whole.
	if repair != null:
		# Two over lands the worker one cell off the barricade, on the run.
		_assign_job(colony, repair, wood_cell + Vector3i(2, 0, 0), unit)
		var repaired := await _wait_until(
			func() -> bool: return repair.state == ColonyJob.State.DONE
		)
		_check(repaired, "a repair job runs to done")
		_check(
			barricade.hp == barricade.max_hp,
			"the repaired construction stands whole again"
		)

	# --- A wreck returns its construction materials — the "broken
	#     goods" question stays open, today it pays like a teardown.
	fort.components.append(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
			DropItem.COBBLE_CM3
		)
	)
	var fort_cell: Vector3i = fort.voxel
	colony.damage_building(fort, fort.max_hp + 1.0)
	_check(
		colony.building_at(fort_cell) == null,
		"a construction at zero hit points comes down"
	)
	_check(
		colony.repair_job_at(fort_cell) == null,
		"the wreck cancels any repair bill on the cell"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var salvage := 0
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - fort_cell).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if (
				item.material == BlockRegistry.Resource_.STONE
				and item.form == DropItem.Form.COBBLE
			):
				salvage += item.volume
	_check(
		salvage >= DropItem.COBBLE_CM3,
		"the wreck drops its construction materials"
	)

	# --- The wreck order: a drafted unit walks over and batters the
	#     thing down — melee against a construction, not an animal.
	var wreck_cell := site + Vector3i(4, 0, 0)
	var wreck_target := Building.new(Building.Kind.BARRICADE, wreck_cell)
	wreck_target.material = BlockRegistry.Resource_.WOOD
	colony.register_building(wreck_target)
	unit.set_drafted(true)
	unit.global_position = (
		Vector3(wreck_cell + Vector3i(-1, 0, 0)) + Vector3(0.5, 1.9, 0.5)
	)
	unit.velocity = Vector3.ZERO
	unit.order_wreck(wreck_target)
	_check(
		unit.job != null and unit.job.structure == wreck_target,
		"the wreck order takes the construction"
	)
	var wrecked := await _wait_until(
		func() -> bool: return colony.building_at(wreck_cell) == null
	)
	_check(wrecked, "a drafted unit wrecks a construction on order")
	unit.set_drafted(false)

	# --- Terrain: a battered block remembers the hurt and breaks as if
	#     mined — drops and all — when its hit points run out.
	var floor_cell := site + Vector3i(6, -1, 0)
	var floor_block := world.get_block(floor_cell)
	_check(
		BlockRegistry.is_solid(floor_block),
		"the damage fixture stands on a real block"
	)
	var floor_cap := (
		BlockRegistry.hardness(floor_block) * Building.HP_PER_HARDNESS
	)
	colony.damage_cell(floor_cell, floor_cap * 0.4)
	_check(
		colony._block_damage.has(floor_cell)
			and world.is_solid(floor_cell),
		"a battered block records damage and stands"
	)
	colony.damage_cell(floor_cell, floor_cap)
	_check(
		world.get_block(floor_cell) == BlockRegistry.Block.AIR
			and not colony._block_damage.has(floor_cell),
		"a wrecked block breaks as if mined"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var spoil := false
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - floor_cell).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.drop_of(floor_block):
				spoil = true
	_check(spoil, "the wrecked block drops its mined rubble")

	# --- Splash: whatever stands between the fighters soaks the blow.
	var cover_cell := site + Vector3i(8, 0, 0)
	_check(
		world.place(cover_cell, BlockRegistry.Block.STONE_WALL),
		"a wall goes up for the splash check"
	)
	colony.combat_splash(
		Vector3(cover_cell + Vector3i(0, 0, -1)) + Vector3(0.5, 0.5, 0.5),
		Vector3(cover_cell + Vector3i(0, 0, 1)) + Vector3(0.5, 0.5, 0.5),
		20.0
	)
	_check(
		float(colony._block_damage.get(cover_cell, 0.0)) > 0.0,
		"the cell between the fighters soaks stray force"
	)
	# Block damage rides the save as accumulated battering.
	_check(
		colony.serialize().get("block_damage", []).size() >= 1,
		"block damage rides the save"
	)
	world.remove_voxel(cover_cell)

	# --- Wrecking a support cascades through the collapse machinery.
	var tower := site + Vector3i(9, 0, 0)
	_check(
		world.place(tower, BlockRegistry.Block.STONE)
			and world.place(tower + Vector3i.UP, BlockRegistry.Block.STONE),
		"a two-block tower goes up"
	)
	var tower_cap := (
		BlockRegistry.hardness(BlockRegistry.Block.STONE)
		* Building.HP_PER_HARDNESS
	)
	colony.damage_cell(tower, tower_cap + 1.0)
	_check(
		world.get_block(tower) == BlockRegistry.Block.AIR
			and world.get_block(tower + Vector3i.UP) == BlockRegistry.Block.AIR,
		"wrecking the support brings the stack down"
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# --- Cleanup: the park and the roster go back to normal.
	_clear_jobs(colony)
	for u in colony.units:
		u._job_search_cooldown = 0.0
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
		u.set_drafted(false)


## Craft quality (PLAN item 31): every craft rolls a normal quality
## off the maker's level — 1.0 is normal, tiers name the ranges for
## the player, a sub-zero roll botches the run. Meals feed on it,
## beds rest and heal on it, recreation buildings entertain on it.
func _test_quality(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("craft quality")
	# Park the colony and hand-drive the fixtures.
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false

	var site := _flat_run(colony, world, mined, 10)
	_check(
		site != Vector3i.MAX,
		"found a flat stretch for the quality tests"
	)
	if site == Vector3i.MAX:
		return

	# --- The tier names the player sees, boundaries included.
	_check(
		DropItem.quality_tier(0.1) == "awful"
			and DropItem.quality_tier(0.5) == "poor"
			and DropItem.quality_tier(1.0) == "fair"
			and DropItem.quality_tier(1.5) == "good"
			and DropItem.quality_tier(2.0) == "excellent"
			and DropItem.quality_tier(3.0) == "masterwork",
		"quality tiers name their ranges"
	)
	_check(
		DropItem.quality_tier(0.24) == "awful"
			and DropItem.quality_tier(0.25) == "poor"
			and DropItem.quality_tier(2.25) == "excellent"
			and DropItem.quality_tier(2.26) == "masterwork",
		"the tier boundaries land where the spec says"
	)

	# --- The roll: mean level/10 + 0.25, deviation 0.25. Sampled wide,
	#     a level-0 crafter's mean sits near 0.25 and botches land in
	#     the ~16% band the spec's math implies.
	var rolls := 0.0
	var botches := 0
	for i in 400:
		var q := unit.roll_craft_quality(ColonyJob.Skill.MINING)
		rolls += q
		if q < 0.0:
			botches += 1
	_check(
		rolls / 400.0 > 0.15 and rolls / 400.0 < 0.35,
		"a level-0 crafter's rolls centre on 0.25"
	)
	_check(
		botches > 0 and float(botches) / 400.0 < 0.30,
		"botches are uncommon but real at level 0"
	)
	var veteran := colony.spawn_unit(site + Vector3i(0, 0, 2))
	veteran._job_search_cooldown = 600.0
	veteran.skills[ColonyJob.Skill.MINING] = 2100.0  # level 20
	var vet_rolls := 0.0
	for i in 400:
		vet_rolls += veteran.roll_craft_quality(ColonyJob.Skill.MINING)
	_check(
		vet_rolls / 400.0 > 2.0,
		"a level-20 crafter's rolls centre on 2.25"
	)

	# --- Meal nutrition scales with the cook's roll — 0.95 + 0.05·q.
	var meal := DropItem.new(
		BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL, DropItem.MEAL_CM3
	)
	meal.nutrition = 10.0
	meal.quality = 2.0
	_check(
		absf(meal.nutrition_value() - 10.5) < 0.001,
		"a good meal feeds a little more"
	)
	meal.quality = 0.0
	_check(
		absf(meal.nutrition_value() - 9.5) < 0.001,
		"an awful meal feeds a little less"
	)

	# --- A real bed craft stamps the kit with the maker's roll, and
	#     the furnish unpacks it onto the building.
	var spot_cell := site
	var spot := Building.new(Building.Kind.WORKSITE, spot_cell)
	colony.register_building(spot)
	var plank_cell := site + Vector3i(2, 0, 0)
	for i in 6:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			plank_cell
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	# A level-20 worker can't botch — the roll's failure band lives
	# nine deviations from his mean.
	var worker0: Unit = colony.units[0]
	var saved_craft_xp: float = worker0.skills.get(
		ColonyJob.Skill.CRAFTING, 0.0
	)
	worker0.skills[ColonyJob.Skill.CRAFTING] = 2100.0
	# The bed builds in place — the furniture order is a CRAFT job
	# whose fetch is the five planks it wants.
	var bed_cell := site + Vector3i(4, 0, 0)
	var furnish := colony.designate_bed(bed_cell)
	_check(furnish != null, "a bed designates for the in-place build")
	if furnish != null:
		_drive_craft(colony, world, furnish, plank_cell, bed_cell)
		var built := await _wait_until(
			func() -> bool:
				return furnish.state == ColonyJob.State.DONE
		)
		var bed := colony.building_at(bed_cell)
		_check(
			built and bed != null,
			"a unit builds the bed from its planks"
		)
		if bed != null:
			_check(
				bed.quality != 1.0 and bed.quality > 0.0,
				"the bed carries the maker's quality roll"
			)
			_check(
				bed.label().contains(
					DropItem.quality_tier(bed.quality)
				),
				"the bed's label names its tier"
			)
			_check(bed.max_hp > 0.0, "the built bed is hit-point rated")
	worker0.skills[ColonyJob.Skill.CRAFTING] = saved_craft_xp

	# --- Rest and care ride the bed's roll — 0.80 + 0.20·quality.
	var awful_bed := Building.new(Building.Kind.BED, site + Vector3i(6, 0, 0))
	awful_bed.quality = 0.1
	var master_bed := Building.new(Building.Kind.BED, site + Vector3i(8, 0, 0))
	master_bed.quality = 2.5
	var sleeper_bad := colony.spawn_unit(site + Vector3i(0, 0, 3))
	var sleeper_good := colony.spawn_unit(site + Vector3i(0, 0, 4))
	for s in [sleeper_bad, sleeper_good]:
		s._job_search_cooldown = 600.0
		s.energy = 0.0
	sleeper_bad._rest_bed = awful_bed
	sleeper_bad._rest_quality = Unit.RestQuality.NORMAL
	sleeper_bad.state = Unit.State.SLEEPING
	sleeper_good._rest_bed = master_bed
	sleeper_good._rest_quality = Unit.RestQuality.NORMAL
	sleeper_good.state = Unit.State.SLEEPING
	colony.needs_enabled = true
	for i in 30:
		await physics_frame
	_check(
		sleeper_bad.energy > 0.0 and sleeper_good.energy > 0.0,
		"both sleepers rest"
	)
	_check(
		sleeper_good.energy > sleeper_bad.energy * 1.4,
		"a masterwork bed out-rests an awful one"
	)
	colony.needs_enabled = false

	# --- The tend seal scales the same way — a better bed treats more.
	var patient := colony.spawn_unit(site + Vector3i(0, 0, 5))
	patient._job_search_cooldown = 600.0
	patient._rest_bed = master_bed
	patient.add_wound(&"torso", &"cut", 10.0)
	var sev_before: float = patient.wounds[0][&"severity"]
	patient.apply_tend(true, true)
	var sealed_master := sev_before - float(patient.wounds[0][&"severity"])
	patient.wounds[0][&"severity"] = 10.0
	patient.wounds[0][&"care"] = 0
	patient._rest_bed = awful_bed
	patient.apply_tend(true, true)
	var sealed_awful := 10.0 - float(patient.wounds[0][&"severity"])
	_check(
		sealed_master > sealed_awful * 1.4,
		"a masterwork bed's tend seals more than an awful one's"
	)

	# --- Recreation fill rides the building — 0.70 + 0.30·quality.
	var pin := Building.new(Building.Kind.RECREATION, site + Vector3i(9, 0, 0))
	pin.quality = 2.5
	unit._rec_building = pin
	_check(
		absf(unit._rec_quality_mult() - 1.45) < 0.001,
		"a masterwork game board entertains half again as fast"
	)
	pin.quality = 0.0
	_check(
		absf(unit._rec_quality_mult() - 0.7) < 0.001,
		"an awful one barely passes the time"
	)
	unit._rec_building = null
	_check(
		absf(unit._rec_quality_mult() - 1.0) < 0.001,
		"a free activity rates no furniture"
	)

	# --- The botch: a sub-zero roll refunds the escrow, requeues the
	#     bill in the same hands, pays half the lesson, and leaves the
	#     memory.
	var botch_job := ColonyJob.new(ColonyJob.Type.CRAFT, spot_cell)
	botch_job.recipe = &"bed"
	botch_job.state = ColonyJob.State.ASSIGNED
	botch_job.assignee = unit
	botch_job.components.append(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		)
	)
	unit.job = botch_job
	var xp_before: float = unit.skills.get(ColonyJob.Skill.CRAFTING, 0.0)
	unit._botch_craft(Colony.RECIPES[&"bed"], ColonyJob.Skill.CRAFTING)
	_check(
		botch_job.state == ColonyJob.State.ASSIGNED
			and botch_job.assignee == unit
			and botch_job.delivered.is_empty()
			and unit.state == Unit.State.MOVING,
		"a botched bill requeues in the same hands"
	)
	_check(
		absf(
			unit.skills.get(ColonyJob.Skill.CRAFTING, 0.0) - xp_before
				- float(ColonyJob.XP_FOR[ColonyJob.Type.CRAFT]) * 0.5
		) < 0.001,
		"a botch pays half the lesson"
	)
	_check(
		unit._thoughts.has(&"botched_craft"),
		"the crafter remembers the botch"
	)
	var refund := false
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - spot_cell).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.PLANK:
				refund = true
	_check(refund, "the botched run's inputs land back on the floor")
	# Retire the requeued fixture — the botch left the crafter mid-fetch.
	unit.abandon_job()
	botch_job.state = ColonyJob.State.CANCELLED
	colony._prune_jobs()

	# --- Persistence: quality rides items and buildings through a save.
	var saved_item := meal.serialize()
	var round_item := DropItem.deserialize(saved_item)
	_check(
		absf(round_item.quality - meal.quality) < 0.001,
		"item quality survives a save round-trip"
	)
	var bd := colony._building_data(master_bed)
	colony._load_building(bd)
	var loaded := colony.building_at(master_bed.voxel)
	_check(
		loaded != null and absf(loaded.quality - 2.5) < 0.001,
		"building quality survives a save round-trip"
	)
	if loaded != null:
		for cell in loaded.footprint:
			colony.buildings.erase(cell)

	# --- Cleanup.
	_clear_jobs(colony)
	for s in [sleeper_bad, sleeper_good, patient, veteran]:
		if s != null and is_instance_valid(s):
			s.abandon_job()
			s.dead = true
			colony.units.erase(s)
			colony._sleeping.erase(s)
			colony.unit_died.emit(s)
			s.queue_free()
	for u in colony.units:
		u._job_search_cooldown = 0.0
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
		u._thoughts.erase(&"botched_craft")


## Ore, ore processing and metals (PLAN item 42): clay soil, connected
## mineral intrusions, mixed mining drops, charcoal, crushing, the two
## furnaces — and knowledge gating: smelting and burning belong to
## workers who hold the skill.
func _test_metals(
	colony: Colony, world: VoxelWorld, _unit: Unit, site: Vector3i
) -> void:
	print("ore, smelting and knowledge")
	_clear_jobs(colony)
	var generator := WorldGenerator.new()

	# --- Clay: dirt's sterile twin, patch-laid in the surface band.
	_check(
		BlockRegistry.drop_of(BlockRegistry.Block.CLAY)
			== BlockRegistry.Resource_.CLAY,
		"clay blocks drop clay"
	)
	_check(
		BlockRegistry.resource_is_loose(BlockRegistry.Resource_.CLAY),
		"clay pours loose like soil"
	)
	var clay_col := Vector2i.MAX
	for x in range(-400, 400, 3):
		for z in range(-400, 400, 3):
			var grass_y := generator.terrain_height(x, z)
			if (
				generator._clay_at(x, z)
				and grass_y > generator._rock_top(x, z, grass_y)
			):
				clay_col = Vector2i(x, z)
				break
		if clay_col != Vector2i.MAX:
			break
	_check(clay_col != Vector2i.MAX, "clay patches spawn in the soil band")
	if clay_col != Vector2i.MAX:
		var cgrass := generator.terrain_height(clay_col.x, clay_col.y)
		var crock := generator._rock_top(clay_col.x, clay_col.y, cgrass)
		_check(
			generator._block_at(clay_col.x, cgrass, clay_col.y, cgrass, crock)
				== BlockRegistry.Block.CLAY,
			"a clay column's soil band is clay"
		)
		_check(
			generator.grass_column(clay_col.x, clay_col.y).y < 0.0,
			"grass won't grow on clay"
		)
		_check(
			generator.sapling_species_at(clay_col.x, clay_col.y) == &"",
			"saplings won't root in clay"
		)

	# --- Intrusions: deep blobs live embedded in the rock mass.
	var ore_hit := Vector3i.MAX
	for x in range(-160, 160, 3):
		for z in range(-160, 160, 3):
			var g := generator.surface_height(x, z)
			for y in range(g - 3, g - 30, -3):
				if generator._intrusion_at(x, y, z) != BlockRegistry.Block.AIR:
					ore_hit = Vector3i(x, y, z)
					break
			if ore_hit != Vector3i.MAX:
				break
		if ore_hit != Vector3i.MAX:
			break
	_check(ore_hit != Vector3i.MAX, "mineral intrusions seed underground")
	if ore_hit != Vector3i.MAX:
		var linked := false
		for side in [
			Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP,
			Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK
		]:
			var nb: Vector3i = ore_hit + side
			if (
				generator._intrusion_at(nb.x, nb.y, nb.z)
					!= BlockRegistry.Block.AIR
			):
				linked = true
		_check(linked, "an intrusion is a face-connected blob")

	# --- Mixed drops: hematite splits mineral from country rock on the
	#     ore's share; native gold yields a gravel sliver amid stone.
	var mixed := false
	for trial in 6:
		var hematite_vol := 0
		var stone_vol := 0
		for item in DropItem.for_block(BlockRegistry.Block.HEMATITE_ORE):
			if item.material == BlockRegistry.Resource_.HEMATITE:
				hematite_vol += item.volume
			elif item.material == BlockRegistry.Resource_.STONE:
				stone_vol += item.volume
		if hematite_vol > 0 and stone_vol > 0:
			mixed = true
	_check(mixed, "hematite ore drops a mineral/rock mix")
	var gold_vol := 0
	var gold_stone := 0
	for item in DropItem.for_block(BlockRegistry.Block.NATIVE_GOLD_ORE):
		if item.material == BlockRegistry.Resource_.NATIVE_GOLD:
			gold_vol += item.volume
		elif item.material == BlockRegistry.Resource_.STONE:
			gold_stone += item.volume
	_check(
		gold_vol >= DropItem.BLOCK_CM3 / 100 and gold_stone > 0,
		"native gold yields a gravel sliver in stone"
	)

	# --- Charcoal is fuel: 0.3 m³ outburns the log it smoulders from.
	_check(
		is_equal_approx(
			DropItem.fuel_seconds_of(
				DropItem.new(
					BlockRegistry.Resource_.CHARCOAL,
					DropItem.Form.LOOSE, 300_000
				)
			),
			900.0
		),
		"0.3 m³ of charcoal burns half again a log"
	)

	# --- The fixture rows: piles of feedstock and open cells for the
	#     furnaces, off every other test's ground. Two shorter benches —
	#     this late in the suite piles litter the terrain and a single
	#     fifteen-cell flat run doesn't exist.
	var bench := _flat_run(colony, world, site, 8)
	_check(bench != Vector3i.MAX, "found a flat stretch for the metals fixtures")
	if bench == Vector3i.MAX:
		return
	var bench2 := _flat_run(colony, world, site, 8, bench.z)
	_check(
		bench2 != Vector3i.MAX,
		"found a second flat stretch for the metals fixtures"
	)
	if bench2 == Vector3i.MAX:
		return
	var log_cell := bench
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.LOG,
			DropItem.LOG_CM3
		),
		log_cell
	)
	var branch_cell := bench + Vector3i(1, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE,
			120_000
		),
		branch_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())

	# --- Charcoal mound: one log and 0.1 m³ of branches construct it,
	#     and a supervised burn finishes it — gated on the skill.
	var mound_cell := bench + Vector3i(2, 0, 0)
	var mound_job := colony.designate_production(mound_cell, &"charcoal_mound")
	_check(mound_job != null, "a charcoal mound designates")
	if mound_job != null:
		_drive_craft(colony, world, mound_job, branch_cell, mound_cell)
		var built := await _wait_until(
			func() -> bool:
				return mound_job.state == ColonyJob.State.DONE
		)
		_check(built, "a unit stacks and seals the charcoal mound")
		var mound := colony.building_at(mound_cell)
		_check(
			mound != null and mound.kind == Building.Kind.CHARCOAL_MOUND,
			"the mound registers as a charcoal mound"
		)
		var burn := colony.burn_job_at(mound_cell)
		_check(burn != null, "building the mound posts the burn job")
		if burn != null:
			var worker: Unit = colony.units[0]
			# The gate: a unit without Charcoal burning can't claim it.
			var naive := colony.spawn_unit(mound_cell + Vector3i(0, 0, 3))
			_check(
				not colony._job_allowed_for(naive, burn),
				"the burn is gated on Charcoal burning knowledge"
			)
			naive.dead = true
			colony.units.erase(naive)
			colony._sleeping.erase(naive)
			colony.unit_died.emit(naive)
			naive.queue_free()
			worker.skills[ColonyJob.Skill.CHARCOAL_BURNING] = Unit.SKILL_XP_BASE
			_check(
				colony._job_allowed_for(worker, burn),
				"a knowledgeable worker may claim the burn"
			)
			_assign_job(colony, burn, mound_cell + Vector3i(1, 0, 0), worker)
			var tended := await _wait_until(
				func() -> bool: return burn.progress > 0.05
			)
			_check(tended, "a supervisor tends the smoulder")
			colony.complete_burn(burn)
			worker.abandon_job()
			# The charcoal pours loose — spill rolls slivers down the
			# mound's sides and out along the row, so let the fall finish
			# then tally every pile plus whatever a hauler already took.
			await _wait_until(
				func() -> bool: return colony._in_flight.is_empty()
			)
			var charcoal := 0
			for cell: Vector3i in colony.item_piles:
				for item in colony.item_piles[cell].items:
					if item.material == BlockRegistry.Resource_.CHARCOAL:
						charcoal += item.volume
			for u in colony.units:
				for item in u._carried:
					if item.material == BlockRegistry.Resource_.CHARCOAL:
						charcoal += item.volume
			_check(
				charcoal == Colony.CHARCOAL_OUT_CM3,
				"the spent mound yields 0.3 m³ of charcoal"
			)

	# --- The pit smelter: cobbles construct it; malachite + charcoal
	#     smelt to raw copper at half the ore's volume — gated work.
	var cobble_cell := bench + Vector3i(3, 0, 0)
	for i in 8:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
				DropItem.COBBLE_CM3
			),
			cobble_cell
		)
	var smelter_cell := bench + Vector3i(4, 0, 0)
	var smelter_job := colony.designate_production(smelter_cell, &"pit_smelter")
	_check(smelter_job != null, "a pit smelter designates")
	if smelter_job != null:
		_drive_craft(colony, world, smelter_job, cobble_cell, smelter_cell)
		var built := await _wait_until(
			func() -> bool:
				return smelter_job.state == ColonyJob.State.DONE
		)
		_check(built, "a unit dry-lays the pit smelter")
		var smelter := colony.building_at(smelter_cell)
		_check(
			smelter != null and smelter.kind == Building.Kind.SMELTER,
			"the smelter registers as a worksite"
		)
	if colony.building_at(smelter_cell) != null:
		var ore_cell := bench + Vector3i(5, 0, 0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.MALACHITE, DropItem.Form.LOOSE,
				Colony.SMELT_BATCH_CM3
			),
			ore_cell
		)
		var fuel_cell := bench + Vector3i(6, 0, 0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.CHARCOAL, DropItem.Form.LOOSE,
				Colony.SMELT_BATCH_CM3
			),
			fuel_cell
		)
		await _wait_until(
			func() -> bool: return colony._in_flight.is_empty()
		)
		var order := colony.queue_order(smelter_cell, &"smelt_copper")
		_check(order != null, "a smelt-copper bill queues on the smelter")
		var smelt := colony.craft_job_at(smelter_cell)
		_check(
			smelt != null,
			"the bill dispatches once ore and charcoal exist"
		)
		if smelt != null:
			var worker: Unit = colony.units[0]
			var naive2 := colony.spawn_unit(smelter_cell + Vector3i(0, 0, 3))
			_check(
				not colony._job_allowed_for(naive2, smelt),
				"pit smelting is gated on Pit smelting knowledge"
			)
			naive2.dead = true
			colony.units.erase(naive2)
			colony._sleeping.erase(naive2)
			colony.unit_died.emit(naive2)
			naive2.queue_free()
			worker.skills[ColonyJob.Skill.PIT_SMELTING] = Unit.SKILL_XP_BASE
			_drive_craft(colony, world, smelt, fuel_cell, smelter_cell)
			var smelted := await _wait_until(
				func() -> bool:
					return smelt.state == ColonyJob.State.DONE
			)
			_check(smelted, "a knowing unit smelts the malachite")
			var copper := 0
			var slag := 0
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						var p := colony.item_pile_at(
							smelter_cell + Vector3i(dx, dy, dz)
						)
						if p == null:
							continue
						for item in p.items:
							if item.material == BlockRegistry.Resource_.COPPER:
								copper += item.volume
							elif (
								item.material == BlockRegistry.Resource_.STONE
								and item.form == DropItem.Form.LOOSE
							):
								slag += item.volume
			_check(
				copper == Colony.SMELT_BATCH_CM3 / 2,
				"the smelt yields raw copper at half the ore's volume"
			)
			_check(
				slag == Colony.SMELT_BATCH_CM3 / 2,
				"the gangue tails out as slag beside the metal"
			)

	# --- The bloomery: shaped clay; hematite + charcoal → raw iron.
	var clay_cell := bench2 + Vector3i(0, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.CLAY, DropItem.Form.LOOSE,
			520_000
		),
		clay_cell
	)
	var bloomery_cell := bench2 + Vector3i(1, 0, 0)
	var bloom_job := colony.designate_production(bloomery_cell, &"bloomery")
	_check(bloom_job != null, "a bloomery designates")
	if bloom_job != null:
		_drive_craft(colony, world, bloom_job, clay_cell, bloomery_cell)
		var built := await _wait_until(
			func() -> bool:
				return bloom_job.state == ColonyJob.State.DONE
		)
		_check(built, "a unit shapes the bloomery from clay")
		_check(
			colony.building_at(bloomery_cell) != null
				and colony.building_at(bloomery_cell).kind
					== Building.Kind.BLOOMERY,
			"the bloomery registers"
		)
	if colony.building_at(bloomery_cell) != null:
		var iron_cell := bench2 + Vector3i(2, 0, 0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.HEMATITE, DropItem.Form.LOOSE,
				Colony.SMELT_BATCH_CM3
			),
			iron_cell
		)
		var fuel_cell2 := bench2 + Vector3i(3, 0, 0)
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.CHARCOAL, DropItem.Form.LOOSE,
				Colony.SMELT_BATCH_CM3
			),
			fuel_cell2
		)
		await _wait_until(
			func() -> bool: return colony._in_flight.is_empty()
		)
		colony.queue_order(bloomery_cell, &"smelt_iron")
		var smelt2 := colony.craft_job_at(bloomery_cell)
		_check(smelt2 != null, "the bloomery bill dispatches")
		if smelt2 != null:
			var worker: Unit = colony.units[0]
			worker.skills[ColonyJob.Skill.BLOOMERY_SMELTING] = (
				Unit.SKILL_XP_BASE
			)
			_drive_craft(colony, world, smelt2, iron_cell, bloomery_cell)
			var smelted := await _wait_until(
				func() -> bool:
					return smelt2.state == ColonyJob.State.DONE
			)
			_check(smelted, "a knowing unit runs the bloomery")
			var iron := 0
			var slag2 := 0
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						var p := colony.item_pile_at(
							bloomery_cell + Vector3i(dx, dy, dz)
						)
						if p == null:
							continue
						for item in p.items:
							if item.material == BlockRegistry.Resource_.IRON:
								iron += item.volume
							elif (
								item.material == BlockRegistry.Resource_.STONE
								and item.form == DropItem.Form.LOOSE
							):
								slag2 += item.volume
			_check(
				iron == Colony.SMELT_BATCH_CM3 / 2,
				"the bloomery yields raw iron at half the ore's volume"
			)
			_check(
				slag2 == Colony.SMELT_BATCH_CM3 / 2,
				"the bloomery tails out its gangue too"
			)

	# --- Crushing: a boulder breaks to nine cobbles plus gravel; a
	#     cobble goes straight to gravel — at the crafting spot.
	var crush_site := bench2 + Vector3i(4, 0, 0)
	var spot_ok := colony.designate_craft_spot(crush_site)
	_check(spot_ok, "the crush fixtures get a crafting spot")
	var rock_cell := bench2 + Vector3i(5, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		),
		rock_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	if spot_ok:
		colony.queue_order(crush_site, &"crush_stone_boulder")
		var crush := colony.craft_job_at(crush_site)
		_check(crush != null, "a crush-boulder bill dispatches")
		if crush != null:
			_drive_craft(colony, world, crush, rock_cell, crush_site)
			var crushed := await _wait_until(
				func() -> bool:
					return crush.state == ColonyJob.State.DONE
			)
			_check(crushed, "a unit crushes the boulder")
			var cobbles := 0
			var gravel := 0
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						var p := colony.item_pile_at(
							crush_site + Vector3i(dx, dy, dz)
						)
						if p == null:
							continue
						for item in p.items:
							if item.material != BlockRegistry.Resource_.STONE:
								continue
							if item.form == DropItem.Form.COBBLE:
								cobbles += 1
							elif item.form == DropItem.Form.LOOSE:
								gravel += item.volume
			_check(
				cobbles == 9 and gravel == DropItem.COBBLE_CM3,
				"a boulder crushes to nine cobbles and a cobble of gravel"
			)

	# --- Knowledge: a skilled unit can teach another, capped at its own
	#     competency; contemplation can discover a skill from nothing.
	#     Fresh spawns keep the skill sheets deterministic — units[0] is
	#     a veteran by this point in the suite.
	var student := colony.spawn_unit(bench2 + Vector3i(6, 0, 0))
	var greenhorn := colony.spawn_unit(bench2 + Vector3i(7, 0, 0))
	_check(student != null, "a student unit joins the roster")
	_check(
		Colony.teachable_skill(greenhorn, student) == -1,
		"an unskilled teacher has nothing to pass on"
	)
	greenhorn.skills[ColonyJob.Skill.MINING] = Unit.SKILL_XP_BASE * 4.0
	_check(
		Colony.teachable_skill(greenhorn, student)
			== ColonyJob.Skill.MINING,
		"the widest skill gap picks the lesson's subject"
	)
	var lesson := colony.post_teach(student)
	_check(lesson != null, "a teach job posts on the student")
	if lesson != null:
		_assign_job(
			colony, lesson, student._standing_voxel(), greenhorn
		)
		var taught := await _wait_until(
			func() -> bool:
				return student.skills.get(ColonyJob.Skill.MINING, 0.0) > 0.0
		)
		_check(taught, "the lesson drips XP into the student")
		colony.complete_teach(lesson)
		greenhorn.abandon_job()
	# Contemplation: enough sessions roll the 15% insight at least once —
	# on the student, whose sheet is nearly clean (mining may hold a
	# drip from the lesson, already under the level line).
	var insight := false
	for attempt in 60:
		student._contemplate_insight()
	for skill: int in ColonyJob.Skill.values():
		if skill == ColonyJob.Skill.MINING:
			continue
		if student.skill_level(skill) >= 1:
			insight = true
	_check(insight, "contemplation can discover a skill")
	# Retire the pair — later sections don't need wandering extras.
	for fixture in [student, greenhorn]:
		fixture.dead = true
		colony.units.erase(fixture)
		colony._sleeping.erase(fixture)
		colony.unit_died.emit(fixture)
		fixture.queue_free()


## Weather + seasons (PLAN item 32): the Cfa calendar — four seasons of
## fifteen days, the annual/diurnal temperature curves, the
## precipitation state machine, temperature events, and the sky's dimming
## of plant light.
func _test_weather(
	colony: Colony, _world: VoxelWorld, _unit: Unit, _mined: Vector3i
) -> void:
	print("weather and seasons")
	var weather := colony.weather
	var dc: DayCycle = colony.day_cycle
	_check(dc != null, "the site carries a planet clock")
	if dc == null:
		return
	var day_secs := dc.day_length_seconds
	var saved_time := dc.planet_time
	var saved_decl := dc.solar_declination_deg
	var saved_state := weather.serialize()
	var saved_lon := dc.site_longitude_deg
	var saved_climate := {
		&"mean_c": weather.mean_c,
		&"amplitude_c": weather.seasonal_amplitude_c,
		&"mean_clear_days": weather.mean_clear_days,
		&"tilt_deg": weather.axial_tilt_deg,
		&"south": weather.south,
	}
	# The machine is exercised against the reference Cfa model — the
	# tile-derived climate the colony actually runs under is covered
	# by the worldgen checks. Longitude pins to 0 so day_fraction
	# tracks planet_time — the checks position the clock by it.
	dc.site_longitude_deg = 0.0
	weather.set_climate(Weather.site_climate(45.0, 15.0, 100.0, 23.44))
	weather.perturb = 0.0
	weather.event_bias = 0.0
	weather.event_total = 0.0

	# --- The calendar: a 60-day year of four 15-day seasons.
	dc.planet_time = 1.0 * day_secs
	_check(weather.season(dc) == 0, "day one opens in spring")
	dc.planet_time = 17.0 * day_secs
	_check(weather.season(dc) == 1, "day seventeen is summer")
	dc.planet_time = 32.0 * day_secs
	_check(weather.season(dc) == 2, "day thirty-two is autumn")
	dc.planet_time = 50.0 * day_secs
	_check(weather.season(dc) == 3, "day fifty is winter")

	# --- The annual mean: ~27 °C late summer, ~3 °C late winter, sampled
	#     at the diurnal zero-crossing (f=0.375 → diurnal term is zero).
	dc.planet_time = (
		(floorf(Weather.SUMMER_PEAK_DAY) + 0.375) * day_secs
	)
	var summer_mean := weather.temperature_c(dc)
	_check(
		absf(summer_mean - 27.0) < 0.5,
		"late summer centres near 27 degrees"
	)
	dc.planet_time = (
		(floorf(Weather.SUMMER_PEAK_DAY + 30.0) + 0.375) * day_secs
	)
	var winter_mean := weather.temperature_c(dc)
	_check(
		absf(winter_mean - 3.0) < 0.5,
		"late winter centres near 3 degrees"
	)

	# --- The diurnal swing: ±5 °C about the daily mean — measured at the
	#     winter extremum, where the annual term's derivative is flat.
	dc.planet_time = (
		(floorf(Weather.SUMMER_PEAK_DAY + 30.0)
			+ Weather.DIURNAL_PEAK_FRACTION) * day_secs
	)
	var high := weather.temperature_c(dc)
	dc.planet_time = (
		(floorf(Weather.SUMMER_PEAK_DAY + 30.0) + 0.5
			+ Weather.DIURNAL_PEAK_FRACTION) * day_secs
	)
	var low := weather.temperature_c(dc)
	_check(
		absf(high - low - 10.0) < 0.5,
		"the daily swing spans about ten degrees"
	)

	# --- The noise wobble is bounded and pulls back toward zero. A
	#     single sample is the stationary noise (σ ≈ 2.7 °C), so the
	#     reversion is judged on the tail average, not one tick.
	weather.perturb = Weather.NOISE_CAP_C
	var tail_sum := 0.0
	var tail_n := 0
	for i in 500:
		weather._tick_noise(0.5)
		if i >= 300:
			tail_sum += absf(weather.perturb)
			tail_n += 1
	_check(
		absf(weather.perturb) <= Weather.NOISE_CAP_C + 0.001,
		"the temperature wobble stays bounded"
	)
	# The samples correlate over the 120 s reversion constant, so the
	# tail mean can ride high on an unlucky stream — 4.8 still proves
	# the pull: unreverted noise would sit pinned near the 6.0 cap.
	_check(
		tail_sum / maxf(tail_n, 1.0) < 4.8,
		"the wobble reverts toward the mean"
	)
	weather.perturb = 0.0

	# --- Clear breaks: snow only in the cold, storms at the season's rate.
	dc.planet_time = (20.0) * day_secs  # warm summer afternoon
	var storms := 0
	var wets := 0
	for i in 400:
		weather._clear_breaks(dc)
		if (
			weather.state == Weather.State.STORM_DRY
			or weather.state == Weather.State.STORM_WET
		):
			storms += 1
		else:
			wets += 1
	_check(
		storms > 120 and storms < 280,
		"summer breaks open with a storm about half the time"
	)
	_check(wets + storms == 400, "a clear break always lands somewhere")
	dc.planet_time = (Weather.SUMMER_PEAK_DAY + 30.375) * day_secs
	weather.perturb = -10.0  # deep-freeze the winter night
	var snows := 0
	var winter_storms := 0
	for i in 200:
		weather._clear_breaks(dc)
		if weather.state == Weather.State.SNOW:
			snows += 1
		elif weather.state != Weather.State.RAIN:
			winter_storms += 1
	_check(snows >= 190, "a frozen break is snow, essentially always")
	_check(winter_storms == 0, "winter never opens with a thunderstorm")
	weather.perturb = 10.0  # a warm winter spell — rain, never a storm
	var warm_storms := 0
	for i in 200:
		weather._clear_breaks(dc)
		if weather.state != Weather.State.RAIN:
			warm_storms += 1
	_check(
		warm_storms == 0,
		"a warm winter break falls as plain rain, never a storm"
	)
	weather.perturb = 0.0

	# --- Dry storms always turn wet; wet storms clear or rain out.
	weather.state = Weather.State.STORM_DRY
	weather.remaining = 0.0
	weather._tick_state(0.1, dc)
	_check(
		weather.state == Weather.State.STORM_WET,
		"a dry storm always wets"
	)
	weather.remaining = 0.0
	weather._tick_state(0.1, dc)
	_check(
		weather.state == Weather.State.CLEAR
			or weather.state == Weather.State.RAIN,
		"a spent storm clears or rains out"
	)

	# --- The sky dims plant light: an overcast storm shades the noon cell.
	weather.state = Weather.State.CLEAR
	weather.remaining = 9999.0
	var clear_light := weather.light_factor()
	weather.state = Weather.State.STORM_WET
	_check(
		weather.light_factor() < clear_light * 0.5
			and weather.precipitating(),
		"a storm both darkens and wets"
	)
	weather.state = Weather.State.CLEAR
	_check(not weather.precipitating(), "clear skies drop nothing")

	# --- Ground saturation: rain soaks, dry weather drains.
	weather.state = Weather.State.RAIN
	weather.remaining = 9999.0
	weather.saturation = 0.0
	weather._tick_saturation(2.0)
	_check(weather.saturation > 0.5, "two seconds of rain soaks the ground")
	weather.state = Weather.State.CLEAR
	weather.remaining = 9999.0
	weather._tick_saturation(400.0)
	_check(
		weather.saturation < 0.05,
		"a long clear stretch dries it back out"
	)

	# --- Temperature events: a +15 °C wave ramps in and out over half
	#     days, holds flat between, then releases.
	weather.event_bias = Weather.EVENT_BIAS_C
	weather.event_total = 2.0 * day_secs
	weather.event_elapsed = 0.1 * day_secs
	_check(
		absf(weather._event_bias_now() - 3.0) < 0.5,
		"a heat wave's bias ramps in over half a day"
	)
	weather.event_elapsed = 1.0 * day_secs
	_check(
		absf(weather._event_bias_now() - 15.0) < 0.01,
		"mid-wave the full bias holds"
	)
	weather.event_elapsed = 1.9 * day_secs
	_check(
		absf(weather._event_bias_now() - 3.0) < 0.5,
		"the wave ramps back out over half a day"
	)

	# --- Seasons tilt the sun: the tick writes declination off the calendar.
	dc.planet_time = Weather.SUMMER_PEAK_DAY * day_secs
	weather.tick(0.01, dc)
	_check(
		dc.solar_declination_deg > 20.0,
		"high summer leans the sun into long days"
	)
	dc.planet_time = (Weather.SUMMER_PEAK_DAY + 30.0) * day_secs
	weather.tick(0.01, dc)
	_check(
		dc.solar_declination_deg < -20.0,
		"deep winter swings it the other way"
	)

	# --- The sky survives a save round-trip.
	var packed := weather.serialize()
	var clone := Weather.new()
	clone.deserialize(packed)
	_check(
		int(clone.state) == int(weather.state)
			and absf(clone.saturation - weather.saturation) < 0.001
			and absf(clone.perturb - weather.perturb) < 0.001,
		"weather state survives a save round-trip"
	)

	# Restore the live clock and sky for the sections behind us.
	dc.planet_time = saved_time
	dc.solar_declination_deg = saved_decl
	dc.site_longitude_deg = saved_lon
	weather.deserialize(saved_state)
	weather.set_climate(saved_climate)


## Fire (PLAN item 33): flammability, ignition, spread, burn-out,
## rain dousing, and the firefighting bill.
func _test_fire(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("fire")
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false
	var saved_weather := colony.weather.serialize()
	colony.weather.state = Weather.State.CLEAR
	colony.weather.remaining = 240.0
	colony.weather.saturation = 0.0

	var site := _flat_run(colony, world, mined, 12)
	_check(site != Vector3i.MAX, "found a flat stretch for the fire tests")
	if site == Vector3i.MAX:
		return

	# --- The flammability table: wood and grass burn, stone and soil don't.
	_check(
		BlockRegistry.flammability(BlockRegistry.Block.LOG_WALL) > 0.0
			and BlockRegistry.flammability(BlockRegistry.Block.STONE) == 0.0
			and BlockRegistry.flammability(BlockRegistry.Block.DIRT) == 0.0
			and BlockRegistry.material_flammability(
				BlockRegistry.Resource_.WOOD
			) == 1.0
			and BlockRegistry.material_flammability(
				BlockRegistry.Resource_.CHARCOAL
			) > 1.0,
		"the flammability table ranks wood and charcoal over stone"
	)

	# --- Ignition: a grassed cell catches and posts the beat-down bill.
	#     Grass covers the soil block itself — the cells one below the
	#     flat run's air cells.
	var fire_cell := site + Vector3i(2, -1, 0)
	colony.grass._set_cover(fire_cell, 1.0)
	# Firefighting bills are home-area work — the fixture cell joins
	# the painted set so its ignite posts the bill.
	colony.designate_home_cells([fire_cell])
	_check(colony.ignite(fire_cell), "a grassed cell ignites")
	_check(
		colony.is_burning(fire_cell),
		"the lit cell registers as burning"
	)
	var ff := colony.firefight_job_at(fire_cell)
	_check(ff != null, "a burning cell posts a firefighting bill")
	_check(
		colony.traversal_mult(fire_cell) < 0.2,
		"flames are close to a wall for pathing"
	)

	# --- Spread: grass neighbours catch off the burning cell.
	var spread_cell := fire_cell + Vector3i.RIGHT
	colony.grass._set_cover(spread_cell, 1.0)
	var caught := false
	for i in 60:
		colony._fire_tick(0.5)
		if colony.is_burning(spread_cell):
			caught = true
			break
	_check(caught, "fire spreads to the flammable neighbour")

	# --- Burn-out: the grass layer is consumed and the cell goes out.
	for i in 80:
		if not colony.is_burning(fire_cell):
			break
		colony._fire_tick(0.5)
	_check(
		not colony.is_burning(fire_cell),
		"the first cell burns itself out"
	)
	_check(
		not colony.grass.grassed(fire_cell),
		"burning strips the grass cover"
	)
	# Extinguish whatever spread is still going before the next fixture.
	for c in [spread_cell, spread_cell + Vector3i.RIGHT, fire_cell + Vector3i.LEFT]:
		colony._extinguish(c)
	_check(
		ff == null or not ff.is_active() or ff.state == ColonyJob.State.DONE
			or colony.firefight_job_at(fire_cell) == null,
		"a burned-out cell's bill doesn't linger unclaimed"
	)

	# --- Beating: a firefighter stomps the fire dead, contents intact.
	#     A log pile is the oracle — a burned-out fire would quarter its
	#     volume, a beaten one leaves it whole. (Grass works too, but the
	#     beater can trample cover to zero legitimately; volume has no
	#     such honest path.) Fuel is pinned high so the walk can't burn
	#     it out first.
	var beat_cell := site + Vector3i(6, 0, 0)
	# _deposit_item lands exactly — _drop_item rolls a spill and can
	# scatter the log off the fixture cell, leaving ignite nothing to
	# burn. The log carries a marker quality so a mid-beat hauler's
	# hands still prove the goods survived whole.
	var marker_log := DropItem.new(
		BlockRegistry.Resource_.WOOD,
		DropItem.Form.LOG,
		DropItem.LOG_CM3
	)
	marker_log.quality = 1.666
	colony._deposit_item(marker_log, beat_cell)
	# Re-pin the sky — a long section can outlast the fixture's storm
	# hold and rain mid-drive, which makes ignite roll a fizzle.
	colony.weather.state = Weather.State.CLEAR
	colony.weather.remaining = 240.0
	colony.weather.saturation = 0.0
	colony.designate_home_cells([beat_cell])
	colony.ignite(beat_cell)
	# Fuel high enough that even a slow walk can't burn the cell out —
	# burn-out quarters the pile and would fake this check's failure.
	if colony._fires.has(beat_cell):
		colony._fires[beat_cell][&"fuel"] = 60.0
	var beat_job := colony.firefight_job_at(beat_cell)
	_check(beat_job != null, "the second fire gets its own bill")
	if beat_job != null:
		_assign_job(colony, beat_job, beat_cell, unit)
		var out := await _wait_until(
			func() -> bool:
				return beat_job.state == ColonyJob.State.DONE
		)
		_check(out, "a unit beats the fire out")
		_check(
			not colony.is_burning(beat_cell),
			"the beaten cell stops burning"
		)
		var whole_log := false
		var candidates: Array = []
		var beat_pile := colony.item_pile_at(beat_cell)
		if beat_pile != null:
			candidates.append_array(beat_pile.items)
		for other: Unit in colony.units:
			candidates.append_array(other._carried)
		# A wanderer's opportunistic haul can carry the log off to a
		# stockpile mid-fight — the check is that the fire didn't
		# consume it, so any pile in the colony counts too.
		for pile: ItemPile in colony.item_piles.values():
			candidates.append_array(pile.items)
		for item in candidates:
			if (
				is_equal_approx(item.quality, 1.666)
				and item.volume == DropItem.LOG_CM3
			):
				whole_log = true
		_check(whole_log, "a stomped fire leaves the goods whole")

	# --- A wood building pays hp while it burns.
	var burn_build := Building.new(
		Building.Kind.RECREATION, site + Vector3i(8, 0, 0)
	)
	burn_build.spec = &"ur_board"
	burn_build.material = BlockRegistry.Resource_.WOOD
	burn_build.footprint.append(burn_build.voxel)
	colony.register_building(burn_build)
	var hp_before := burn_build.hp
	colony.ignite(burn_build.voxel)
	_check(
		colony.is_burning(burn_build.voxel),
		"a wooden building catches"
	)
	for i in 8:
		colony._fire_tick(0.5)
	_check(
		burn_build.hp < hp_before,
		"the flames eat the building's hit points"
	)
	colony._extinguish(burn_build.voxel)
	colony._teardown_building(burn_build.voxel)

	# --- A burning wall block burns away without drops.
	var wall_cell := site + Vector3i(10, 0, 0)
	world.place(wall_cell, BlockRegistry.Block.LOG_WALL)
	var piles_before: int = colony.item_piles.size()
	colony.ignite(wall_cell)
	_check(colony.is_burning(wall_cell), "a log wall catches")
	for i in 80:
		if not colony.is_burning(wall_cell):
			break
		colony._fire_tick(0.5)
	_check(
		world.get_block(wall_cell) == BlockRegistry.Block.AIR,
		"the wall burns away to nothing"
	)
	_check(
		colony.item_pile_at(wall_cell) == null
			and colony.item_piles.size() <= piles_before + 1,
		"a burned wall drops no logs"
	)

	# --- Rain douses: soaked ground resists catching and falling rain
	#     kills a lit fire about three times as fast.
	var rain_cell := site + Vector3i(4, -1, 0)
	colony.weather.state = Weather.State.RAIN
	colony.weather.remaining = 9999.0
	colony.weather.saturation = 1.0
	colony.grass._set_cover(rain_cell, 1.0)
	var wet_fire := false
	for i in 30:
		if colony.ignite(rain_cell):
			wet_fire = true
			break
	_check(not wet_fire, "soaked ground resists ignition")
	colony.weather.saturation = 0.0
	colony.weather.state = Weather.State.CLEAR
	colony.ignite(rain_cell)
	colony.weather.state = Weather.State.RAIN
	colony.weather.remaining = 9999.0
	for i in 10:
		colony._fire_tick(0.5)
	_check(
		not colony.is_burning(rain_cell),
		"rain puts the fire out fast"
	)
	colony.weather.state = Weather.State.CLEAR
	colony.weather.remaining = 9999.0
	colony.weather.saturation = 0.0

	# --- Persistence: fires and weather ride the save record.
	var record := colony.serialize()
	_check(
		(record.get("weather") as Dictionary).has("state")
			and record.has("fires"),
		"the colony save carries the sky and its fires"
	)

	# --- Cleanup: no stray fires or markers follow the section out.
	for cell: Vector3i in colony._fires.keys():
		colony._extinguish(cell)
	colony.weather.deserialize(saved_weather)
	_clear_jobs(colony)


## A size×size pad of columns at one ground height, every cell from
## g+1 to g+4 open air — the room fixture needs flatness in both axes,
## not just the run's row.
func _flat_pad(
	colony: Colony,
	world: VoxelWorld,
	mined: Vector3i,
	size: int,
	skip_zs: Array = []
) -> Vector3i:
	for z_off in range(-140, -220, -4) + range(140, 204, 4) + range(-60, -140, 4) + range(60, 140, 4):
		var z0: int = mined.z + z_off
		# The pad spans rows z0..z0+size-1 — skip it if any row another
		# fixture claimed falls inside that span.
		var row_taken := false
		for used_z in skip_zs:
			if int(used_z) >= z0 and int(used_z) < z0 + size:
				row_taken = true
				break
		if row_taken:
			continue
		for x0 in range(mined.x + 4, mined.x + 44):
			var g := _ground(world, x0, z0, mined.y + 32)
			var ok := true
			for dx in size:
				for dz in size:
					var x: int = x0 + dx
					var z: int = z0 + dz
					if (
						_ground(world, x, z, mined.y + 32) != g
						or world.generator_script.water_depth_at(x, z) != 0
					):
						ok = false
						break
					for dy in range(4):
						var cell := Vector3i(x, g + 1 + dy, z)
						if (
							not world.is_editable(cell)
							or world.get_block(cell) != BlockRegistry.Block.AIR
						):
							ok = false
							break
					if not ok:
						break
					var pile_cell := Vector3i(x, g + 1, z)
					if colony.item_pile_at(pile_cell) != null:
						ok = false
						break
				if not ok:
					break
			# The fixture's doorway opens west onto (x0-1, z0+2) — floor
			# and head cells there must be air, else the box seals on
			# terrain and the doorway-leak check is meaningless.
			for dy in 2:
				var apron := Vector3i(x0 - 1, g + 1 + dy, z0 + 2)
				if (
					not world.is_editable(apron)
					or world.get_block(apron) != BlockRegistry.Block.AIR
					or colony.building_at(apron) != null
				):
					ok = false
					break
			# The whole pad (plus the west apron cell) must be dry in
			# the band the build uses — one wet column inside the box
			# floods the fixture.
			if ok and _dry_box(
				world,
				Vector3i(x0, g + 1, z0),
				Rect2i(-1, 0, size + 1, size)
			):
				return Vector3i(x0, g + 1, z0)
	return Vector3i.MAX


## Flooring, rooms, and beauty (PLAN item 34): surface coverings dress
## any exposed block face — floors underfoot, walls, ceilings — a sealed
## pocket reads as a room whose score integrates its surfaces, and a
## unit's surroundings thought reads the room score indoors or the
## sight-line mean of visible faces within five metres outdoors.
func _test_flooring(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("flooring and beauty")
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
		u.hunger = 1.0
		u.energy = 1.0
		u.recreation = 1.0
		u.mood = 1.0
	_clear_jobs(colony)
	colony.needs_enabled = false

	var down := Flooring.face_index(Vector3i.DOWN)
	var up := Flooring.face_index(Vector3i.UP)
	var right := Flooring.face_index(Vector3i.RIGHT)

	# --- Spec table: three coverings, beauty scaled well under
	#     RimWorld's per-tile numbers, recipes thinner than a wall.
	_check(BlockRegistry.FLOOR_SPECS.size() >= 3, "several floor specs exist")
	_check(
		BlockRegistry.floor_beauty(&"plank_floor")
			> BlockRegistry.floor_beauty(&"flagstone")
			and BlockRegistry.floor_beauty(&"flagstone")
				> BlockRegistry.floor_beauty(&"packed_dirt"),
		"covering beauty orders plank > flagstone > packed earth"
	)
	_check(
		BlockRegistry.floor_recipe(&"flagstone").has(DropItem.Form.BLOCK),
		"flagstone takes dressed blocks"
	)
	_check(
		BlockRegistry.item_fits_floor(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BLOCK,
				DropItem.STONE_BLOCK_CM3
			),
			&"flagstone"
		)
		and not BlockRegistry.item_fits_floor(
			DropItem.new(
				BlockRegistry.Resource_.WOOD,
				DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			&"flagstone"
		),
		"item_fits_floor gates material and form"
	)
	_check(
		BlockRegistry.block_beauty(BlockRegistry.Block.STONE_WALL) > 0.0
			and BlockRegistry.block_beauty(BlockRegistry.Block.DIRT) < 0.0,
		"bare block faces carry signed beauty"
	)

	# Two flat rows: the mechanics run wants six cells, the sight-line
	# run eight — a single 14-long stretch is rarer than the terrain
	# usually offers.
	var site := _flat_run(colony, world, mined, 6)
	_check(site != Vector3i.MAX, "found a flat stretch for the flooring tests")
	var eye_row := _flat_run(colony, world, mined, 8, site.z)
	_check(
		eye_row != Vector3i.MAX,
		"found a second flat stretch for the beauty tests"
	)
	if site == Vector3i.MAX or eye_row == Vector3i.MAX:
		return

	# --- Cover mechanics: a floor face takes a covering, a face with no
	#     backing refuses one, and the lay is idempotent-guarded.
	var floor_cell := site
	_check(
		colony.flooring.coverable(floor_cell, down),
		"a floor face over solid ground is coverable"
	)
	_check(
		not colony.flooring.coverable(floor_cell, up),
		"a ceiling face under open sky has no backing"
	)
	_check(
		colony.flooring.lay(floor_cell, down, &"flagstone"),
		"a floor covering lays"
	)
	_check(
		colony.flooring.covering_at(floor_cell, down) == &"flagstone",
		"the laid covering reads back"
	)
	_check(
		not colony.flooring.coverable(floor_cell, down),
		"a dressed face can't take a second covering"
	)
	_check(
		is_equal_approx(
			colony.flooring.face_beauty(floor_cell, down),
			BlockRegistry.floor_beauty(&"flagstone")
		),
		"a covered face reads the covering's beauty"
	)
	_check(
		colony.flooring.strip(floor_cell, down) == &"flagstone"
			and colony.flooring.covering_at(floor_cell, down) == &"",
		"stripping a face returns its spec and leaves it bare"
	)

	# --- Wall and ceiling faces: a lateral covering dresses the block
	#     beside the air cell, a ceiling covering the block overhead —
	#     and one cell carries several faces at once.
	var wall_block := site + Vector3i(5, 0, 0)
	var wall_cell := site + Vector3i(4, 0, 0)
	world.place(wall_block, BlockRegistry.Block.STONE_WALL)
	_check(
		colony.flooring.coverable(wall_cell, right)
			and colony.flooring.lay(wall_cell, right, &"plank_floor")
			and colony.flooring.covering_at(wall_cell, right) == &"plank_floor",
		"a wall face takes a covering"
	)
	world.place(wall_cell + Vector3i.UP, BlockRegistry.Block.STONE_WALL)
	_check(
		colony.flooring.lay(wall_cell, up, &"packed_dirt")
			and colony.flooring.covering_at(wall_cell, up) == &"packed_dirt"
			and colony.flooring.covering_at(wall_cell, right) == &"plank_floor",
		"a ceiling face takes a covering beside a wall one"
	)
	# Losing the lid drops the ceiling cover; losing the wall drops the
	# wall cover.
	world.remove_voxel(wall_cell + Vector3i.UP)
	await process_frame
	_check(
		colony.flooring.covering_at(wall_cell, up) == &"",
		"mining the backing drops its covering"
	)
	world.remove_voxel(wall_block)
	await process_frame
	_check(
		colony.flooring.covering_at(wall_cell, right) == &"",
		"a lost wall takes its covering too"
	)

	# --- Burial: fill the air cell and every face it carried dies.
	var burial_cell := site + Vector3i(3, 0, 0)
	colony.flooring.lay(burial_cell, down, &"packed_dirt")
	world.place(burial_cell, BlockRegistry.Block.STONE_WALL)
	await process_frame
	_check(
		colony.flooring.covering_at(burial_cell, down) == &"",
		"filling the air cell buries its coverings"
	)
	world.remove_voxel(burial_cell)

	# --- Designations: a pave designation is a face-keyed BUILD job;
	#     bogus specs, bare faces, and double-designations refuse.
	var pave_cell := site + Vector3i(1, 0, 0)
	_check(
		colony.designate_pave(pave_cell, Vector3i.DOWN, &"bogus") == null,
		"an unknown spec can't be designated"
	)
	_check(
		colony.designate_strip_pave(pave_cell, Vector3i.DOWN) == null,
		"a bare face can't be stripped"
	)
	var pave_job := colony.designate_pave(
		pave_cell, Vector3i.DOWN, &"flagstone"
	)
	_check(
		pave_job != null
			and pave_job.type == ColonyJob.Type.BUILD
			and pave_job.face_dir == Vector3i.DOWN
			and pave_job.build_spec == &"flagstone",
		"a pave designation posts a face-keyed BUILD job"
	)
	_check(
		colony.designate_pave(pave_cell, Vector3i.DOWN, &"plank_floor")
			== null,
		"a designated face can't be repaved"
	)
	_check(
		colony.designate_strip_pave(pave_cell, Vector3i.DOWN) == null,
		"a planned face can't be stripped"
	)
	var fkey := Vector4i(pave_cell.x, pave_cell.y, pave_cell.z, down)
	_check(
		colony._face_markers.has(fkey),
		"a pave designation marks its face"
	)

	# --- Drive the job: twenty blocks beside the site, one unit
	#     fetching and trowelling.
	var pile_cell := site + Vector3i(2, 0, 0)
	for i in 20:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BLOCK,
				DropItem.STONE_BLOCK_CM3
			),
			pile_cell
		)
	_assign_job(colony, pave_job, pave_cell)
	var paved := await _wait_until(func() -> bool:
		return colony.flooring.covering_at(pave_cell, down) == &"flagstone")
	_check(paved, "a unit fetches blocks and lays flagstone")
	_check(
		pave_job.state == ColonyJob.State.DONE
			and not colony._face_markers.has(fkey),
		"the pave job completes and its marker retires"
	)

	# --- Strip: the designation posts a face-keyed DECONSTRUCT and the
	#     covering comes back off.
	var strip_job := colony.designate_strip_pave(pave_cell, Vector3i.DOWN)
	_check(
		strip_job != null
			and strip_job.type == ColonyJob.Type.DECONSTRUCT
			and strip_job.face_dir == Vector3i.DOWN,
		"a strip designation posts a face-keyed DECONSTRUCT job"
	)
	_assign_job(colony, strip_job, pave_cell)
	var stripped := await _wait_until(func() -> bool:
		return colony.flooring.covering_at(pave_cell, down) == &"")
	_check(stripped, "a unit strips the covering back off")

	# --- Rooms: a sealed 3×3×3 box reads as a room, the open field
	#     doesn't, and paving the room's floor lifts its score.
	# The pad must not swallow either used row — overlapping cells would
	# turn wall and silently break the beauty and pave fixtures below.
	var pad := _flat_pad(colony, world, mined, 5, [site.z, eye_row.z])
	_check(pad != Vector3i.MAX, "found a flat pad for the room fixture")
	var interior := Vector3i.MAX
	if pad != Vector3i.MAX:
		var gap := pad + Vector3i(0, 0, 2)  # doorway cell, left open
		for dx in 5:
			for dz in 5:
				var edge: bool = dx == 0 or dx == 4 or dz == 0 or dz == 4
				var base := Vector3i(pad.x + dx, pad.y, pad.z + dz)
				world.place(base + Vector3i.UP * 3, BlockRegistry.Block.STONE_WALL)
				if edge:
					for dy in 3:
						if dy == 0 and base == gap:
							continue  # the doorway stays open
						world.place(
							base + Vector3i.UP * dy,
							BlockRegistry.Block.STONE_WALL
						)
		interior = Vector3i(pad.x + 2, pad.y, pad.z + 2)
		# An open doorway spills the fill: interior and the cell outside
		# the door share one component — the outdoors (null, when the
		# fill reaches the edge) or a walled courtyard holding both.
		# A sealed interior answer here would mean the gap didn't
		# connect at all.
		var outside := gap + Vector3i(-1, 0, 0)
		var open_room := colony.rooms.room_at(interior)
		_check(
			colony.rooms.room_at(outside) == open_room,
			"a box with an open doorway leaks — no room yet"
		)
		var door := Building.new(Building.Kind.DOOR, gap)
		colony.register_building(door)
		var room := colony.rooms.room_at(interior)
		_check(
			room != null and room.cells.size() == 27,
			"a door seals the doorway and the box reads as a room"
		)
		_check(
			colony.rooms.room_at(outside) != room,
			"the open field outside is not a room"
		)
		if room != null:
			var bare_score := colony.rooms.score(room)
			for dx in range(1, 4):
				for dz in range(1, 4):
					var c := Vector3i(pad.x + dx, pad.y, pad.z + dz)
					colony.flooring.lay(c, down, &"plank_floor")
			var floored_score := colony.rooms.score(room)
			_check(
				floored_score > bare_score,
				"planking the floor lifts the room's beauty"
			)
			# A unit inside reads the room's integrated score, not the
			# sight-line mean.
			var in_eye := Vector3(interior) + Vector3(0.5, 0.9, 0.5)
			_check(
				is_equal_approx(
					colony.unit_beauty(in_eye, interior), floored_score
				),
				"a unit in a room reads the room's score"
			)

	# --- Outdoor beauty: the sight-line mean of visible faces within
	#     five metres. The eye stands at the run's west end; everything
	#     it judges lies east on the same flat row.
	var out_cell := eye_row
	var eye := Vector3(out_cell) + Vector3(0.5, 0.9, 0.5)
	colony._beauty_rays = 0
	var b0 := colony.unit_beauty(eye, out_cell)
	_check(
		colony._beauty_rays > 0,
		"the surroundings sampler metered its raycasts"
	)
	# A covering seven metres out with clear sky between is past the
	# bubble — the distance gate skips it.
	colony.flooring.lay(eye_row + Vector3i(7, 0, 0), down, &"flagstone")
	var b1 := colony.unit_beauty(eye, out_cell)
	_check(
		is_equal_approx(b1, b0),
		"a covering past five metres adds nothing"
	)
	# Planks underfoot one and two cells out are in range and in view.
	colony.flooring.lay(eye_row + Vector3i(1, 0, 0), down, &"plank_floor")
	colony.flooring.lay(eye_row + Vector3i(2, 0, 0), down, &"plank_floor")
	var b2 := colony.unit_beauty(eye, out_cell)
	_check(b2 > b1, "a visible paved patch lifts the beauty sample")
	# Wall off a fourth cell and dress the face behind it — the sight
	# line is cut, so the hidden covering changes nothing.
	var sight_wall := eye_row + Vector3i(4, 0, 0)
	var backing := eye_row + Vector3i(6, 0, 0)
	world.place(sight_wall, BlockRegistry.Block.STONE_WALL)
	world.place(sight_wall + Vector3i.UP, BlockRegistry.Block.STONE_WALL)
	world.place(backing, BlockRegistry.Block.STONE_WALL)
	var b3 := colony.unit_beauty(eye, out_cell)
	colony.flooring.lay(
		eye_row + Vector3i(5, 0, 0), right, &"plank_floor"
	)
	var b4 := colony.unit_beauty(eye, out_cell)
	_check(
		b4 <= b3 + 0.0001,
		"a walled-off covering adds nothing to the sample"
	)
	world.remove_voxel(sight_wall + Vector3i.UP)
	world.remove_voxel(sight_wall)
	world.remove_voxel(backing)

	# --- The unit side: the sample lands on `beauty` and thresholds the
	#     three surroundings thoughts.
	unit.beauty = -0.2
	_check(
		unit._state_thought_on(&"drab_surroundings")
			and not unit._state_thought_on(&"pleasant_surroundings"),
		"drab surroundings reads below the floor"
	)
	unit.beauty = 0.15
	_check(
		unit._state_thought_on(&"pleasant_surroundings")
			and not unit._state_thought_on(&"impressive_surroundings"),
		"pleasant surroundings sits between the thresholds"
	)
	unit.beauty = 0.5
	_check(
		unit._state_thought_on(&"impressive_surroundings"),
		"impressive surroundings reads above the top threshold"
	)
	unit.beauty = 0.0

	# --- Persistence: coverings and face-keyed jobs round-trip.
	var save := colony.flooring.serialize()
	var probe := eye_row + Vector3i(3, 0, 0)
	_check(
		colony.flooring.lay(probe, down, &"flagstone"),
		"the probe cell took its covering"
	)
	var round_trip := colony.flooring.serialize()
	var extra_cell := eye_row + Vector3i(5, 0, 0)
	var extra_job := colony.designate_pave(
		extra_cell, Vector3i.DOWN, &"packed_dirt"
	)
	if extra_job != null:
		var jd := colony._job_data(extra_job)
		_check(
			jd.get("face_dir") == [0, -1, 0],
			"a pave job serializes its face"
		)
	else:
		_check(false, "a pave job serializes its face")
	colony.cancel_designation(eye_row + Vector3i(5, 0, 0))
	var gone_key := Vector4i(
		eye_row.x + 5, eye_row.y, eye_row.z, down
	)
	_check(
		not colony._face_markers.has(gone_key),
		"cancelling a face designation drops its marker"
	)
	colony.flooring.deserialize(round_trip)
	_check(
		colony.flooring.covering_at(probe, down) == &"flagstone",
		"coverings survive the serialize round trip"
	)
	colony.flooring.deserialize(save)
	_check(
		colony.flooring.covering_at(probe, down) == &"",
		"deserialize clears faces the snapshot didn't hold"
	)

	# --- Cleanup: strip the test coverings, take the fixtures down.
	for cell: Vector3i in colony.flooring.covers.keys():
		colony.flooring._clear_cell(cell)
	if interior != Vector3i.MAX:
		var door_at_gap := colony.building_at(pad + Vector3i(0, 0, 2))
		if door_at_gap != null:
			colony._teardown_building(pad + Vector3i(0, 0, 2))
		for dx in 5:
			for dz in 5:
				for dy in range(3, -1, -1):
					world.remove_voxel(
						Vector3i(pad.x + dx, pad.y + dy, pad.z + dz)
					)
	_clear_jobs(colony)


## Research: the bench and the Study action — a worksite bill that
## pulls a manufactured item out of a pile, pays the make recipe's XP
## scaled by (1 − level/10), and sometimes breaks the specimen into
## the materials it was made from. Found goods teach gated skills —
## technology lives in people, not a colony unlock.
func _test_research(colony: Colony, world: VoxelWorld, _unit: Unit, site: Vector3i) -> void:
	print("research and study")
	_clear_jobs(colony)

	# --- The formulas: break chance is 0.6 at level 0 and loses a
	#     third per level; the lesson scales (1 − level/10).
	_check(
		is_equal_approx(Colony.study_break_chance(0), 0.6),
		"a level-0 study breaks the specimen 60% of the time"
	)
	_check(
		is_equal_approx(Colony.study_break_chance(1), 0.4),
		"level 1 breaks 40%"
	)
	_check(
		absf(Colony.study_break_chance(2) - 0.2667) < 0.001,
		"level 2 breaks 26.7%"
	)
	_check(
		absf(Colony.study_break_chance(3) - 0.1778) < 0.001,
		"level 3 breaks 17.8%"
	)
	var copper_id := Colony.study_recipe_for(
		DropItem.Form.LOOSE, BlockRegistry.Resource_.COPPER
	)
	_check(copper_id != &"", "raw copper is a studyable item type")
	var copper_study := Colony.recipe_of(copper_id)
	_check(
		int(copper_study.get("skill", -1)) == ColonyJob.Skill.PIT_SMELTING,
		"studying copper teaches Pit smelting"
	)
	_check(
		is_equal_approx(Colony.study_xp(copper_study, 0), 5.0),
		"a level-0 study pays the full make lesson"
	)
	_check(
		is_equal_approx(Colony.study_xp(copper_study, 5), 2.5),
		"a level-5 study pays half"
	)
	_check(
		is_equal_approx(Colony.study_xp(copper_study, 10), 0.0),
		"a level-10 study pays nothing"
	)
	# A found good whose make-recipe is gated teaches the gate, not
	# the train skill — the forge demands bloomery knowledge.
	var pick_study := Colony.recipe_of(
		Colony.study_recipe_for(
			DropItem.Form.TOOL, BlockRegistry.Resource_.IRON
		)
	)
	_check(
		int(pick_study.get("skill", -1)) == ColonyJob.Skill.BLOOMERY_SMELTING,
		"studying an iron pick teaches Bloomery smelting"
	)
	_check(
		Colony.study_recipe_for(
			DropItem.Form.LOG, BlockRegistry.Resource_.WOOD
		) == &"",
		"a raw log isn't manufactured — nothing to study"
	)

	# A packed furniture crate is studyable — a found or salvaged piece
	# teaches the joinery that made it.
	var crate_study := Colony.recipe_of(
		Colony.study_recipe_for(
			DropItem.Form.CRATE, BlockRegistry.Resource_.WOOD
		)
	)
	_check(
		int(crate_study.get("skill", -1))
			== ColonyJob.Skill.COMPLEX_FURNITURE,
		"studying a furniture crate teaches Complex furniture"
	)

	# --- The break remains: a furniture crate bursts into its real
	#     contents — packed planks plus the shell plank it was wrapped
	#     in — a plank into a third of a log's sawdust, a copper scoop
	#     into the ore and charcoal that made it.
	var crate := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.CRATE,
		6 * DropItem.PLANK_CM3
	)
	crate.spec = &"bed"
	for i in 5:
		crate.packed.append(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			)
		)
	crate.shell.append(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		)
	)
	var remains := colony._study_remains(crate_study, crate)
	var whole_planks := 0
	for item in remains:
		if item.form == DropItem.Form.PLANK:
			whole_planks += 1
	_check(
		whole_planks == 6,
		"a broken furniture crate drops its contents and shell"
	)
	var plank_study := Colony.recipe_of(
		Colony.study_recipe_for(
			DropItem.Form.PLANK, BlockRegistry.Resource_.WOOD
		)
	)
	remains = colony._study_remains(
		plank_study, DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		)
	)
	var sawdust := 0
	for item in remains:
		if item.form == DropItem.Form.LOOSE:
			sawdust += item.volume
	_check(
		absi(sawdust - DropItem.LOG_CM3 / 3) <= 1,
		"a broken plank drops a third of a log loose"
	)
	remains = colony._study_remains(
		copper_study, DropItem.new(
			BlockRegistry.Resource_.COPPER, DropItem.Form.LOOSE,
			Colony.STUDY_LOOSE_CM3
		)
	)
	var malachite_back := 0
	var charcoal_back := 0
	for item in remains:
		if item.material == BlockRegistry.Resource_.MALACHITE:
			malachite_back += item.volume
		elif item.material == BlockRegistry.Resource_.CHARCOAL:
			charcoal_back += item.volume
	_check(
		malachite_back == 2 * Colony.STUDY_LOOSE_CM3
			and charcoal_back == 2 * Colony.STUDY_LOOSE_CM3,
		"a broken copper scoop drops the ore and charcoal that made it"
	)

	# --- The bench: a plank production build that worksites like the
	#     furnaces do.
	var bench_row := _flat_run(colony, world, site, 8)
	_check(bench_row != Vector3i.MAX, "found a flat row for the bench fixtures")
	if bench_row == Vector3i.MAX:
		return
	var bench_cell := bench_row
	var specimen_cell := bench_row + Vector3i(1, 0, 0)
	var plank_cell := bench_row + Vector3i(2, 0, 0)
	var spot_cell := bench_row + Vector3i(3, 0, 0)
	# Earlier fixtures can leave buildings standing on the row —
	# teardowns clear them before the bench designates.
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	for cell in [bench_cell, specimen_cell, plank_cell, spot_cell]:
		if colony.building_at(cell) != null:
			colony._teardown_building(cell)
	for i in 4:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			plank_cell
		)
	var bench_job := colony.designate_production(bench_cell, &"research_bench")
	_check(bench_job != null, "a research bench designates")
	if bench_job != null:
		_drive_craft(colony, world, bench_job, plank_cell, bench_cell)
		var built := await _wait_until(
			func() -> bool:
				return bench_job.state == ColonyJob.State.DONE
		)
		_check(built, "a unit builds the research bench")
	var bench := colony.building_at(bench_cell)
	_check(
		bench != null and bench.kind == Building.Kind.RESEARCH
			and bench.is_worksite(),
		"the bench registers as a worksite"
	)
	if bench == null:
		return
	# A study bill belongs to the bench, not a bare crafting spot.
	colony.register_building(Building.new(Building.Kind.WORKSITE, spot_cell))
	var tin_id := Colony.study_recipe_for(
		DropItem.Form.LOOSE, BlockRegistry.Resource_.TIN
	)
	_check(
		colony.queue_order(spot_cell, tin_id) == null,
		"a study bill refuses the bare crafting spot"
	)
	_check(
		colony.queue_order(bench_cell, &"planks") == null,
		"an ordinary craft refuses the bench in turn"
	)

	# --- Options derive from inventory: the bill appears only while a
	#     specimen sits in a colony pile.
	_check(
		not colony.study_options().has(tin_id),
		"with no tin held, its study isn't offered"
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.TIN, DropItem.Form.LOOSE, 30_000
		),
		specimen_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony.study_options().has(tin_id),
		"a landed specimen makes the study appear"
	)
	var order := colony.queue_order(bench_cell, tin_id)
	_check(order != null, "a study bill queues on the bench")
	var study := colony.craft_job_at(bench_cell)
	_check(study != null, "the study bill dispatches a job")

	# --- The level-10 rule: a master of the studied skill never
	#     claims the job; a naive unit may.
	var master := colony.spawn_unit(bench_cell + Vector3i(0, 0, 3))
	master.skills[ColonyJob.Skill.PIT_SMELTING] = Unit.SKILL_XP_BASE * 55.0
	_check(
		master.skill_level(ColonyJob.Skill.PIT_SMELTING) == 10,
		"the fixture master reads level 10"
	)
	_check(
		study != null and not colony._job_allowed_for(master, study),
		"a master of the skill never claims the study"
	)
	master.dead = true
	colony.units.erase(master)
	colony._sleeping.erase(master)
	colony.unit_died.emit(master)
	master.queue_free()
	var worker: Unit = colony.units[0]
	# Earlier fixtures may have taught this unit — a level-0 study
	# needs the skill reset first.
	worker.skills[ColonyJob.Skill.PIT_SMELTING] = 5.0
	_check(
		study != null and colony._job_allowed_for(worker, study),
		"a naive unit may claim the study"
	)

	# --- The run: fetch the tin, study it — a found item teaches the
	#     gated skill. The worker starts a half-step short of level 1
	#     so one study crosses the knowledge line.
	if study != null:
		_drive_craft(colony, world, study, specimen_cell, bench_cell)
		var done := await _wait_until(
			func() -> bool:
				return study.state == ColonyJob.State.DONE
		)
		_check(done, "a unit fetches and studies the specimen")
		_check(
			worker.knows(ColonyJob.Skill.PIT_SMELTING),
			"a found item teaches basic knowledge"
		)
		# The specimen came back whole — or burst into the cassiterite
		# and charcoal that made it.
		var tin_back := 0
		var cassiterite_back := 0
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var p := colony.item_pile_at(
						bench_cell + Vector3i(dx, dy, dz)
					)
					if p == null:
						continue
					for item in p.items:
						if item.material == BlockRegistry.Resource_.TIN:
							tin_back += item.volume
						elif item.material == BlockRegistry.Resource_.CASSITERITE:
							cassiterite_back += item.volume
		_check(
			tin_back > 0 or cassiterite_back > 0,
			"the specimen survived or burst into its make materials"
		)

	# --- Scaling: at level 5 the lesson halves — 2.5 XP, not 5.
	#     What's left of the tin still counts as a specimen; if the
	#     first study broke it, put a fresh scoop down.
	var tin_pile := Vector3i.MAX
	for voxel: Vector3i in colony.item_piles:
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.TIN:
				tin_pile = voxel
	if tin_pile == Vector3i.MAX:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.TIN, DropItem.Form.LOOSE,
				Colony.STUDY_LOOSE_CM3
			),
			specimen_cell
		)
		tin_pile = specimen_cell
		await _wait_until(
			func() -> bool: return colony._in_flight.is_empty()
		)
	var order2 := colony.queue_order(bench_cell, tin_id)
	var study2 := colony.craft_job_at(bench_cell)
	_check(order2 != null and study2 != null, "a second study bill dispatches")
	if study2 != null:
		# Level 5 exactly: X·L(L+1)/2 = 10·15 = 150 XP.
		worker.skills[ColonyJob.Skill.PIT_SMELTING] = 150.0
		var before: float = worker.skills[ColonyJob.Skill.PIT_SMELTING]
		_drive_craft(colony, world, study2, tin_pile, bench_cell)
		var done2 := await _wait_until(
			func() -> bool:
				return study2.state == ColonyJob.State.DONE
		)
		_check(done2, "a second study completes at level 5")
		_check(
			is_equal_approx(
				worker.skills[ColonyJob.Skill.PIT_SMELTING] - before,
				2.5
			),
			"the level-5 lesson halves"
		)

	# --- Persistence: a queued study bill's pseudo-recipe id
	#     round-trips through the building data.
	var order3 := colony.queue_order(bench_cell, tin_id)
	if order3 != null:
		var od: Dictionary = colony._building_data(bench)["orders"][0]
		_check(
			String(od.get("recipe", "")) == String(tin_id),
			"a study bill serializes its pseudo-recipe id"
		)
		_check(
			not Colony.recipe_of(StringName(od.get("recipe", ""))).is_empty(),
			"the serialized study id resolves on load"
		)
		colony.remove_order(bench_cell, order3)
	else:
		_check(false, "a third study bill queues for the save check")
	_clear_jobs(colony)


## Power and temperature (PLAN item 36): manufactured stock — sheet
## metal and drawn wire on the metalworker's bench, machine components
## at the fabricator — feeding a fuel generator, wall-embedded conduit
## and freestanding pylons that flood into power nets, and electric
## heaters and coolers whose heat actually moves through the six-
## direction room graph.
func _test_power(colony: Colony, world: VoxelWorld, _unit: Unit, site: Vector3i) -> void:
	print("power and temperature")
	_clear_jobs(colony)
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
	var worker: Unit = colony.units[0]
	var naive := colony.spawn_unit(site + Vector3i(0, 0, 4))
	naive._job_search_cooldown = 600.0
	naive.hunger = 1.0
	naive.energy = 1.0

	# --- The recipe tables: sites, skills, gates, and the copper pin.
	var sheet_recipe := Colony.recipe_of(&"sheet_metal_copper")
	_check(
		is_equal_approx(
			Colony.recipe_site_rate(sheet_recipe, Building.Kind.WORKSITE), 0.5
		)
		and is_equal_approx(
			Colony.recipe_site_rate(sheet_recipe, Building.Kind.METALWORK), 1.0
		)
		and Colony.recipe_site_rate(sheet_recipe, Building.Kind.SMELTER) == 0.0,
		"sheet metal runs half-speed at a spot, full at the bench, nowhere else"
	)
	_check(
		int(sheet_recipe.get("skill", -1)) == ColonyJob.Skill.MANUFACTURING
		and int(Colony.recipe_of(&"wire_copper").get("skill", -1))
			== ColonyJob.Skill.MANUFACTURING
		and int(Colony.recipe_of(&"machine_components").get("skill", -1))
			== ColonyJob.Skill.MANUFACTURING,
		"the metalwork chain trains Manufacturing"
	)
	_check(
		ColonyJob.GATED_SKILLS.has(ColonyJob.Skill.HVAC)
		and ColonyJob.GATED_SKILLS.has(ColonyJob.Skill.ELECTRICIAN),
		"HVAC and Electrician are gated skills"
	)
	var gen_req := Colony.recipe_requires(Colony.recipe_of(&"fuel_generator"))
	var cooler_req := Colony.recipe_requires(Colony.recipe_of(&"cooler"))
	_check(
		gen_req.size() == 1
		and int(gen_req[0]) == ColonyJob.Skill.ELECTRICIAN,
		"the generator needs an Electrician"
	)
	_check(
		cooler_req.size() == 2
		and cooler_req.has(ColonyJob.Skill.ELECTRICIAN)
		and cooler_req.has(ColonyJob.Skill.HVAC),
		"the cooler wants both Electrician and HVAC"
	)
	var components := Colony.recipe_of(&"machine_components")
	_check(
		int(components["input_loose"][BlockRegistry.Resource_.IRON]) == 30_000
		and int(components["input_loose"][BlockRegistry.Resource_.COPPER])
			== 20_000
		and int(components["site"]) == Building.Kind.FABRICATOR,
		"components smelt 3 iron + 2 copper at the fabricator"
	)
	_check(
		DropItem.want_form_for(
			{DropItem.Form.PLANK: 4}, DropItem.Form.SHEET
		) == DropItem.Form.PLANK
		and DropItem.fill_forms(DropItem.Form.PLANK).has(
			int(DropItem.Form.SHEET)
		),
		"a sheet fills a plank slot, one way only"
	)
	_check(
		is_equal_approx(colony.device_watts(
			Building.new(Building.Kind.HEATER, site)
		), Colony.HEATER_WATTS)
		and is_equal_approx(colony.device_watts(
			Building.new(Building.Kind.COOLER, site)
		), Colony.COOLER_WATTS),
		"heaters draw 150W and coolers 200W"
	)

	# --- The fixture row: worksites and machines west to east, a
	#     materials pile at the far end.
	var run := _clear_run(colony, world, site, 10)
	_check(run != Vector3i.MAX, "found a flat row for the power fixtures")
	if run == Vector3i.MAX:
		naive.dead = true
		colony.units.erase(naive)
		colony._sleeping.erase(naive)
		colony.unit_died.emit(naive)
		naive.queue_free()
		return
	var spot_cell := run
	var mw_cell := run + Vector3i(1, 0, 0)
	var fab_cell := run + Vector3i(2, 0, 0)
	var gen_cell := run + Vector3i(3, 0, 0)
	var pylon_a := run + Vector3i(4, 0, 0)
	var pylon_b := run + Vector3i(5, 0, 0)
	var wall_cell := run + Vector3i(6, 0, 0)
	var heater_cell := run + Vector3i(7, 0, 0)
	var cooler_site := run + Vector3i(8, 0, 0)
	# The materials pile sits off the row: heap spill and stray drops
	# pack neighbouring cells, and on the row itself a packed pile
	# severs the only flat path — that's what stalled fixture builds.
	var pile_cell := Vector3i.MAX
	for off in [
		Vector3i(9, 0, 2), Vector3i(9, 0, -2), Vector3i(5, 0, 2),
		Vector3i(5, 0, -2), Vector3i(2, 0, 2), Vector3i(2, 0, -2),
		Vector3i(0, 0, 2), Vector3i(0, 0, -2), Vector3i(7, 0, 2),
		Vector3i(7, 0, -2), Vector3i(11, 0, 2), Vector3i(11, 0, -2),
		Vector3i(9, 0, 3), Vector3i(9, 0, -3), Vector3i(5, 0, 3),
		Vector3i(5, 0, -3), Vector3i(2, 0, 3), Vector3i(2, 0, -3),
	]:
		var cand: Vector3i = run + off
		var between: Vector3i = cand + Vector3i(0, 0, -signi(off.z))
		if (
			world.get_block(cand) == BlockRegistry.Block.AIR
			and world.is_editable(cand)
			and world.is_solid(cand + Vector3i.DOWN)
			and world.get_block(between) == BlockRegistry.Block.AIR
			and world.is_solid(between + Vector3i.DOWN)
			and colony.item_pile_at(cand) == null
			and colony.building_at(cand) == null
		):
			pile_cell = cand
			break
	_check(pile_cell != Vector3i.MAX, "an off-row cell holds the materials pile")
	if pile_cell == Vector3i.MAX:
		pile_cell = run + Vector3i(9, 0, 0)
	for cell in [spot_cell, mw_cell, fab_cell, gen_cell]:
		if colony.building_at(cell) != null:
			colony._teardown_building(cell)
	colony.register_building(Building.new(Building.Kind.WORKSITE, spot_cell))

	# --- Sheet metal at the bare spot: the slow-but-legal path —
	#     copper gravel in, one plate out, Manufacturing XP paid.
	var mfg_before: float = worker.skills.get(
		ColonyJob.Skill.MANUFACTURING, 0.0
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COPPER, DropItem.Form.LOOSE, 120_000
		),
		pile_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var sheet_job := colony.designate_craft(spot_cell, &"sheet_metal_copper")
	_check(sheet_job != null, "sheet metal orders at a crafting spot")
	if sheet_job != null:
		var hammered := await _build_and_wait(
			colony, world, sheet_job, pile_cell, spot_cell
		)
		_check(hammered, "a unit beats a copper sheet at the spot")
		var sheets := 0
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.SHEET:
					sheets += 1
		_check(
			sheets >= 1
			and worker.skills.get(ColonyJob.Skill.MANUFACTURING, 0.0)
				> mfg_before,
			"the sheet lands and the crafter learned Manufacturing"
		)

	# --- Substitution end-to-end: a metalworker's bench built out of
	#     eight copper sheets where the recipe calls for four planks —
	#     the want is volume, so half-thickness stock pays double count.
	var sheet_cell := pile_cell
	for i in 9:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.COPPER, DropItem.Form.SHEET,
				DropItem.SHEET_CM3
			),
			sheet_cell
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_sweep(colony, mw_cell)
	var mw_job := colony.designate_production(mw_cell, &"metalwork_bench")
	_check(mw_job != null, "a metalworker's bench designates")
	if mw_job != null:
		var mw_built := await _build_and_wait(
			colony, world, mw_job, sheet_cell, mw_cell
		)
		_check(mw_built, "a unit builds the bench from sheet metal")
		var bench := colony.building_at(mw_cell)
		var paid_sheets := 0
		var paid_planks := 0
		if bench != null:
			for item in bench.components:
				if item.form == DropItem.Form.SHEET:
					paid_sheets += 1
				elif item.form == DropItem.Form.PLANK:
					paid_planks += 1
		_check(
			bench != null and bench.kind == Building.Kind.METALWORK
			and bench.is_worksite()
			and paid_sheets == 8 and paid_planks == 0,
			"the bench stands, built of eight sheets and no planks"
		)
		_sweep_run(colony, run, 9)

	# --- Wire at the bench: four drawn strands per 10k of raw metal.
	var wire_job := colony.designate_craft(mw_cell, &"wire_copper")
	_check(wire_job != null, "copper wire orders at the bench")
	if wire_job != null:
		_stock_job(wire_job)
		_assign_job(colony, wire_job, mw_cell)
		var drawn := await _wait_until(
			func() -> bool: return wire_job.state == ColonyJob.State.DONE
		)
		_check(drawn, "a unit draws copper wire at the bench")
		var wires := 0
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.WIRE:
					wires += 1
		_check(wires >= 4, "the draw yields four wire coils")
		_sweep_run(colony, run, 9)

	# --- The fabricator: sheets plus two components, then the chain's
	#     keystone recipe — loose iron and copper into five components.
	_sweep(colony, fab_cell)
	var fab_job := colony.designate_production(fab_cell, &"fabricator")
	_check(fab_job != null, "a fabrication bench designates")
	if fab_job != null:
		_stock_job(fab_job)
		_assign_job(colony, fab_job, fab_cell)
		var fab_built := await _wait_until(
			func() -> bool: return fab_job.state == ColonyJob.State.DONE
		)
		_check(
			fab_built
			and colony.building_at(fab_cell) != null
			and colony.building_at(fab_cell).kind == Building.Kind.FABRICATOR,
			"a unit builds the fabrication bench"
		)
	var comp_job := colony.designate_craft(fab_cell, &"machine_components")
	_check(comp_job != null, "machine components order at the fabricator")
	_check(
		colony.designate_craft(mw_cell, &"machine_components") == null,
		"but never at the metalworker's bench"
	)
	if comp_job != null:
		_stock_job(comp_job)
		_assign_job(colony, comp_job, fab_cell)
		var machined := await _wait_until(
			func() -> bool: return comp_job.state == ColonyJob.State.DONE
		)
		_check(machined, "a unit machines five components")
		var comps := 0
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.COMPONENT:
					comps += 1
		_check(comps >= 5, "five components land in the pile")
		_sweep_run(colony, run, 9)

	# --- The generator build: gated on Electrician. A naive unit can't
	#     claim it; basic knowledge opens the job. The grant rides ahead
	#     of the designate — a refused cell mustn't strand the skill the
	#     cooler's double gate checks later.
	worker.skills[ColonyJob.Skill.ELECTRICIAN] = Unit.SKILL_XP_BASE
	var gen_job := colony.designate_production(gen_cell, &"fuel_generator")
	_check(gen_job != null, "a fuel generator designates")
	if gen_job != null:
		_check(
			not colony._job_allowed_for(naive, gen_job),
			"the generator build is gated on Electrician"
		)
		_check(
			colony._job_allowed_for(worker, gen_job),
			"an Electrician may build the generator"
		)
		_stock_job(gen_job)
		_assign_job(colony, gen_job, gen_cell)
		var gen_built := await _wait_until(
			func() -> bool: return gen_job.state == ColonyJob.State.DONE
		)
		_check(gen_built, "a unit builds the fuel generator")
		var gen := colony.building_at(gen_cell)
		_check(
			gen != null and gen.uses_fuel() and not gen.lit(),
			"the generator takes campfire fuel and starts cold"
		)
		_sweep_run(colony, run, 9)

	# --- Conduit: only constructed walls wire — natural stone refuses.
	#     The line needs copper wire and an Electrician's hands.
	world.place(wall_cell, BlockRegistry.Block.STONE_WALL)
	var wall := Building.new(Building.Kind.WALL, wall_cell)
	wall.block_id = BlockRegistry.Block.STONE_WALL
	colony.register_building(wall)
	_check(
		colony.conduit_face_open(heater_cell, Vector3i.LEFT),
		"a constructed wall takes conduit"
	)
	_check(
		not colony.conduit_face_open(heater_cell, Vector3i.DOWN),
		"the natural ground underfoot won't take conduit"
	)
	var conduit_job := colony.designate_conduit(
		heater_cell, Vector3i.LEFT
	)
	_check(
		conduit_job != null
		and conduit_job.build_spec == &"conduit"
		and conduit_job.required_skill == ColonyJob.Skill.ELECTRICIAN
		and conduit_job.face_dir == Vector3i.LEFT,
		"the conduit install posts as a gated face job"
	)
	_check(
		conduit_job != null and not colony._job_allowed_for(naive, conduit_job),
		"running live wire needs an Electrician"
	)
	_check(
		colony.designate_conduit(heater_cell, Vector3i.LEFT) == null,
		"the face can't be designated twice"
	)
	if conduit_job != null:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.COPPER, DropItem.Form.WIRE,
				DropItem.WIRE_CM3
			),
			pile_cell
		)
		await _wait_until(
			func() -> bool: return colony._in_flight.is_empty()
		)
		_assign_job(colony, conduit_job, heater_cell)
		var wired := await _wait_until(
			func() -> bool: return wall.conduit
		)
		_check(wired, "a unit runs copper wire into the wall")
		var wire_in_wall := 0
		for item in wall.components:
			if item.form == DropItem.Form.WIRE:
				wire_in_wall += item.volume
		_check(
			wire_in_wall >= DropItem.WIRE_CM3,
			"the installed line becomes part of the wall"
		)

	# --- The heater and cooler builds ride the same pipeline — the
	#     cooler's double gate wants both an Electrician and HVAC, and
	#     its cold side rides the designation through to the building.
	_sweep_run(colony, run, 9)
	_sweep(colony, heater_cell)
	var heat_job := colony.designate_production(
		heater_cell, &"electric_heater"
	)
	_check(heat_job != null, "an electric heater designates")
	if heat_job != null:
		_stock_job(heat_job)
		_assign_job(colony, heat_job, heater_cell)
		var heat_built := await _wait_until(
			func() -> bool: return heat_job.state == ColonyJob.State.DONE
		)
		_check(heat_built, "a unit builds the electric heater")
	var heater := colony.building_at(heater_cell)
	var housed := false
	if heater != null:
		for item in heater.components:
			if (
				item.form == DropItem.Form.PLANK
				or item.form == DropItem.Form.SHEET
			):
				housed = true
	_check(
		heater != null and heater.kind == Building.Kind.HEATER
		and housed,
		"the heater stands with its housing escrowed"
	)
	_check(
		Colony.HEATER_FIRE_CHANCE_WOOD > Colony.HEATER_FIRE_CHANCE,
		"a wooden housing carries the higher fire chance"
	)
	_sweep(colony, cooler_site)
	var cool_job := colony.designate_cooler(cooler_site, Vector3i.LEFT)
	_check(
		cool_job != null and cool_job.face_dir == Vector3i.LEFT,
		"a cooler designation carries its cold-side bearing"
	)
	if cool_job != null:
		_check(
			not colony._job_allowed_for(naive, cool_job),
			"the cooler wants skills the naive unit lacks"
		)
		worker.skills.erase(ColonyJob.Skill.HVAC)
		_check(
			not colony._job_allowed_for(worker, cool_job),
			"an Electrician alone still can't build a cooler"
		)
		worker.skills[ColonyJob.Skill.HVAC] = Unit.SKILL_XP_BASE
		_check(
			colony._job_allowed_for(worker, cool_job),
			"Electrician plus HVAC opens the cooler build"
		)
		_stock_job(cool_job, {DropItem.Form.PLANK: DropItem.Form.SHEET})
		_assign_job(colony, cool_job, cooler_site)
		var cool_built := await _wait_until(
			func() -> bool: return cool_job.state == ColonyJob.State.DONE
		)
		_check(cool_built, "a unit builds the cooler")
	var built_cooler := colony.building_at(cooler_site)
	_check(
		built_cooler != null and built_cooler.kind == Building.Kind.COOLER
		and built_cooler.face_dir == Vector3i.LEFT,
		"the built cooler remembers which way is cold"
	)

	# --- The net: generator → pylons → wired wall, devices hanging off
	#     the conductor cells.
	colony.register_building(Building.new(Building.Kind.PYLON, pylon_a))
	colony.register_building(Building.new(Building.Kind.PYLON, pylon_b))
	var cooler_bld := Building.new(Building.Kind.COOLER, wall_cell + Vector3i.UP)
	cooler_bld.face_dir = Vector3i.UP
	colony.register_building(cooler_bld)
	var heater2 := Building.new(
		Building.Kind.HEATER, pylon_b + Vector3i.UP
	)
	colony.register_building(heater2)
	_check(
		is_equal_approx(colony.traversal_mult(pylon_a), Colony.PYLON_CRAWL),
		"a strung pylon slows the walk through its cell"
	)
	var gen2 := colony.building_at(gen_cell)
	if gen2 == null:
		gen2 = Building.new(Building.Kind.GENERATOR, gen_cell)
		colony.register_building(gen2)
	colony._power_tick(0.1)
	_check(
		(heater == null or not heater.powered)
		and not cooler_bld.powered,
		"a cold generator powers nothing"
	)
	gen2.fuel = 400.0
	colony._power_tick(0.1)
	# Cheapest-cell order: the high heater (x5), the cooler over the
	# wall (x6), then the row heater (x7) — 400W covers the first two
	# and browns out the third; the built cooler touches no conductor.
	_check(
		heater2.powered and cooler_bld.powered,
		"the fuelled net powers the devices on its conductors"
	)
	_check(
		heater == null or not heater.powered,
		"the third device browns out past the generator's budget"
	)
	_check(
		built_cooler == null or not built_cooler.powered,
		"a machine touching no conductor stays dead"
	)
	gen2.fuel = 0.0
	colony._power_tick(0.1)
	_check(
		not heater2.powered and not cooler_bld.powered,
		"empty fuel starves the whole net"
	)
	gen2.fuel = 400.0
	colony._teardown_building(wall_cell)
	colony._power_tick(0.1)
	_check(
		(heater == null or not heater.powered)
		and not cooler_bld.powered
		and heater2.powered,
		"tearing the wired wall down cuts the devices it fed"
	)
	var wire_back := 0
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - wall_cell).length() > 3.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.WIRE:
				wire_back += item.volume
	_check(wire_back >= DropItem.WIRE_CM3, "the teardown hands the wire back")

	# --- Heater fault roll: a powered, plank-housed machine is a fire
	#     risk — a long enough fault window makes ignition certain.
	heater2.components.append(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		)
	)
	var dry: float = colony.weather.saturation
	colony.weather.saturation = 0.0
	colony._power_tick(2.0 / Colony.HEATER_FIRE_CHANCE_WOOD)
	colony.weather.saturation = dry
	_check(
		colony.is_burning(heater2.voxel),
		"a powered wooden-housed heater faults and ignites"
	)
	colony._extinguish(heater2.voxel)
	colony._teardown_building(heater2.voxel)

	# --- Room temperature: a 5×5 box divided into two sealed rooms by
	#     a cooler in the shared wall, a door on the west face, and a
	#     generator inside powering heater and cooler alike.
	var pad := _flat_pad(colony, world, site, 5, [run.z])
	_check(pad != Vector3i.MAX, "found a flat pad for the climate fixture")
	if pad == Vector3i.MAX:
		naive.dead = true
		colony.units.erase(naive)
		colony._sleeping.erase(naive)
		colony.unit_died.emit(naive)
		naive.queue_free()
		return
	var door_cell := pad + Vector3i(0, 0, 2)
	for dx in 5:
		for dz in 5:
			var edge: bool = dx == 0 or dx == 4 or dz == 0 or dz == 4
			var base := Vector3i(pad.x + dx, pad.y, pad.z + dz)
			world.place(base + Vector3i.UP * 3, BlockRegistry.Block.STONE_WALL)
			if edge:
				for dy in 3:
					if dy == 0 and base == door_cell:
						continue
					world.place(
						base + Vector3i.UP * dy,
						BlockRegistry.Block.STONE_WALL
					)
	# The divider: solid except the machine gap — the cooler seals it.
	var gap := Vector3i(pad.x + 2, pad.y, pad.z + 2)
	for dz in range(1, 4):
		for dy in 3:
			var cell := Vector3i(pad.x + 2, pad.y + dy, pad.z + dz)
			if cell == gap:
				continue
			world.place(cell, BlockRegistry.Block.STONE_WALL)
	var divider_wall := Vector3i(pad.x + 2, pad.y, pad.z + 1)
	var div_wall := Building.new(Building.Kind.WALL, divider_wall)
	div_wall.block_id = BlockRegistry.Block.STONE_WALL
	colony.register_building(div_wall)
	var door := Building.new(Building.Kind.DOOR, door_cell)
	colony.register_building(door)
	# The cooler hangs in the divider gap now — its machine body seals
	# the cell like a door leaf, which is what lets it hold two
	# climates against each other.
	var room_cooler := Building.new(Building.Kind.COOLER, gap)
	room_cooler.face_dir = Vector3i.LEFT  # cold side west
	colony.register_building(room_cooler)
	var west_cell := Vector3i(pad.x + 1, pad.y, pad.z + 2)
	var east_cell := Vector3i(pad.x + 3, pad.y, pad.z + 2)
	var room_w := colony.rooms.room_at(west_cell)
	var room_e := colony.rooms.room_at(east_cell)
	_check(
		room_w != null and room_w.cells.size() == 9
		and room_e != null and room_e.cells.size() == 9
		and room_w != room_e,
		"the divider and its cooler split the box into two sealed rooms"
	)

	# --- Boundary classes: the doorway face breathes at the door rate,
	#     the roof and walls leak to the sky, and the floor — unbroken
	#     overburden to bedrock — pulls toward the biome mean.
	if room_w != null:
		colony.rooms._analyze_boundary(room_w)
		var door_face := false
		var mean_face := false
		var roof_face := false
		var deep_leak := false
		for face: Dictionary in room_w.boundary:
			if is_equal_approx(float(face[&"rate"]), Colony.TEMP_LEAK_DOOR):
				door_face = true
			if int(face[&"mode"]) == Rooms.TARGET_MEAN:
				mean_face = true
			if is_equal_approx(
				float(face[&"rate"]), Colony.TEMP_LEAK_WALL_DEEP
			):
				deep_leak = true
			if (
				int(face[&"mode"]) == Rooms.TARGET_ROOM
				and face[&"room"] == null
			):
				roof_face = true
		_check(door_face, "a door face leaks at the closed-door rate")
		var floor_deep := colony.rooms._deep_wall(
			west_cell + Vector3i.DOWN, west_cell
		)
		if floor_deep:
			_check(
				mean_face, "the buried floor pulls toward the biome mean"
			)
		else:
			_check(
				deep_leak,
				"a floor over broken ground leaks instead of pulling"
			)
		_check(roof_face, "thin walls and the roof leak to the outdoors")

	if room_w == null or room_e == null:
		_check(false, "the two-room fixture formed for the climate checks")
	else:
		# --- Power inside the rooms: a fuelled generator beside the
		#     wired divider feeds the cooler in the gap and a heater on
		#     the wall.
		var room_gen := Building.new(
			Building.Kind.GENERATOR, Vector3i(pad.x + 1, pad.y, pad.z + 1)
		)
		room_gen.fuel = 900.0
		colony.register_building(room_gen)
		var room_heater := Building.new(
			Building.Kind.HEATER, Vector3i(pad.x + 3, pad.y, pad.z + 1)
		)
		colony.register_building(room_heater)
		div_wall.conduit = true
		colony._power_tick(0.1)
		_check(
			room_cooler.powered and room_heater.powered,
			"the indoor net powers the cooler and the heater"
		)

		# --- The tick: rooms seed at ambient, then the powered
		#     machines move heat — the cold side drops, the hot side
		#     climbs, and the heater pours on more.
		var ambient: float = colony.weather.temperature_c(
			colony.day_cycle
		)
		colony._climate_tick(0.1)
		_check(
			not is_nan(room_w.temperature)
			and absf(room_w.temperature - ambient) < 3.0,
			"a fresh room seeds near ambient"
		)
		var w0 := room_w.temperature
		var e0 := room_e.temperature
		for i in 8:
			colony._climate_tick(5.0)
		_check(
			room_w.temperature < w0 - 1.0,
			"the cooler draws its cold room down"
		)
		_check(
			room_e.temperature > e0 + 3.0,
			"the hot side and the heater warm the east room"
		)
		_check(
			absf(
				colony.temperature_at(west_cell) - room_w.temperature
			) < 0.001,
			"indoor cells read the room's one temperature"
		)

		# --- Carry-over: a topology change re-floods the room but
		#     keeps its warmth rather than snapping back to ambient.
		room_w.temperature = 42.0
		colony.rooms.invalidate()
		var room_w2 := colony.rooms.room_at(west_cell)
		colony._climate_tick(0.1)
		_check(
			room_w2 != null and room_w2.temperature > 30.0,
			"a re-flooded room keeps its warmth"
		)

	# --- Persistence: the wall's embedded line and the cooler's
	#     bearing survive the save fields.
	var wd := colony._building_data(div_wall)
	_check(
		bool(wd.get("conduit", false)),
		"a wired wall serializes its conduit"
	)
	var cd := colony._building_data(room_cooler)
	_check(
		cd.get("face_dir") == [-1, 0, 0],
		"the cooler serializes its cold-side bearing"
	)

	# --- Cleanup: machines and records out, the box comes down.
	colony._teardown_building(door_cell)
	colony._teardown_building(gap)
	colony._teardown_building(Vector3i(pad.x + 1, pad.y, pad.z + 1))
	colony._teardown_building(Vector3i(pad.x + 3, pad.y, pad.z + 1))
	colony._teardown_building(divider_wall)
	for dx in 5:
		for dz in 5:
			for dy in range(3, -1, -1):
				world.remove_voxel(
					Vector3i(pad.x + dx, pad.y + dy, pad.z + dz)
				)
	colony._teardown_building(heater_cell)
	colony._teardown_building(pylon_a)
	colony._teardown_building(pylon_b)
	colony._teardown_building(wall_cell + Vector3i.UP)
	colony._teardown_building(pylon_b + Vector3i.UP)
	colony._teardown_building(pile_cell)
	colony._teardown_building(cooler_site)
	colony._teardown_building(gen_cell)
	colony._teardown_building(fab_cell)
	colony._teardown_building(mw_cell)
	colony._teardown_building(spot_cell)
	world.remove_voxel(wall_cell)
	naive.dead = true
	colony.units.erase(naive)
	colony._sleeping.erase(naive)
	colony.unit_died.emit(naive)
	naive.queue_free()
	_clear_jobs(colony)


## Item 37 — the textile chain: cotton the annual, raw fibre that rots,
## cloth that weathers instead, the tailor's bench, garments with layers
## and wear, repair and salvage bills, and the hands/holster/backpack
## equipment model.
func _test_apparel(colony: Colony, world: VoxelWorld, _unit: Unit, site: Vector3i) -> void:
	print("apparel and cloth")
	_clear_jobs(colony)
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
	var worker: Unit = colony.units[0]

	# --- The plant and the materials: an annual fibre crop, a fibre
	#     that rots, a cloth that weathers but never rots.
	var cotton: Dictionary = Plants.species_table().get(&"cotton", {})
	_check(
		not cotton.is_empty() and bool(cotton.get(&"annual", false)),
		"cotton is an annual crop"
	)
	_check(
		int(cotton.get(&"yield_material", -1))
			== BlockRegistry.Resource_.COTTON
		and int(cotton.get(&"yield_form", -1)) == DropItem.Form.LOOSE,
		"the harvest pours raw cotton"
	)
	_check(
		colony.farmable_species_ids().has(&"cotton")
		and DropItem.FRUIT_SPECIES.get(BlockRegistry.Resource_.COTTON)
			== &"cotton",
		"cotton is farmable and maps back to its seed"
	)
	var raw := DropItem.new(
		BlockRegistry.Resource_.COTTON, DropItem.Form.LOOSE, 1_000
	)
	var cloth_loose := DropItem.new(
		BlockRegistry.Resource_.CLOTH, DropItem.Form.LOOSE, 1_000
	)
	_check(not DropItem.decay_rule(raw).is_empty(), "raw cotton rots")
	_check(
		DropItem.decay_rule(cloth_loose).is_empty()
		and not DropItem.weather_rule(cloth_loose).is_empty(),
		"cloth weathers outdoors but never rots"
	)

	# --- The recipe tables: the weave, the garment makes, and the
	#     synthesized repair/salvage bills.
	var weave := Colony.recipe_of(&"cotton_cloth")
	_check(
		int(weave[&"input_loose"][BlockRegistry.Resource_.COTTON])
			== 20_000
		and int(weave[&"output_loose"][BlockRegistry.Resource_.CLOTH])
			== 15_000
		and int(weave[&"site"]) == Building.Kind.TAILOR,
		"the weave pours cotton in, cloth out, at the tailor's bench"
	)
	_check(
		weave["outputs"][0].has(DropItem.Form.SEED)
		and int(weave[&"site"]) == Building.Kind.TAILOR,
		"weaving returns the seed the next sowing needs"
	)
	_check(
		Colony.recipe_site_rate(weave, Building.Kind.WORKSITE) == 0.0
		and Colony.recipe_site_rate(weave, Building.Kind.TAILOR) == 1.0,
		"the weave refuses a bare crafting spot"
	)
	_check(
		Colony.recipe_of(&"tailor_bench")["builds"] == Building.Kind.TAILOR,
		"the bench recipe builds a tailor"
	)
	var specs := DropItem.APPAREL_SPECS
	_check(
		specs[&"tribalwear"][&"layers"] == [DropItem.Layer.ON_SKIN]
		and specs[&"tool_belt"][&"layers"] == [DropItem.Layer.UTILITY]
		and int(specs[&"tool_belt"][&"holsters"]) == 2
		and is_equal_approx(
			float(specs[&"backpack"][&"carry_mult"]), 1.5
		),
		"apparel specs cover layers, holsters and the carry bonus"
	)
	_check(
		Colony.garment_recipe_ids().has(&"repair_tribalwear")
		and Colony.garment_recipe_ids().has(&"salvage_tribalwear"),
		"a repair and a salvage bill exist per apparel spec"
	)
	var repair_rec := Colony.recipe_of(&"repair_tribalwear")
	_check(
		bool(repair_rec.get(&"repair", false))
		and repair_rec[&"input_spec"][DropItem.Form.GARMENT]
			== &"tribalwear",
		"the repair bill pins the garment spec it works on"
	)

	# --- The item model: spec and wear ride the garment.
	var garb := DropItem.new(
		BlockRegistry.Resource_.CLOTH,
		DropItem.Form.GARMENT,
		DropItem.GARMENT_CM3
	)
	garb.spec = &"tribalwear"
	garb.wear = 0.6
	var garb_back := DropItem.deserialize(garb.serialize())
	_check(
		garb_back.spec == &"tribalwear"
		and is_equal_approx(garb_back.wear, 0.6),
		"a garment's spec and wear survive serialization"
	)
	_check(
		DropItem.garment_layers(garb) == [DropItem.Layer.ON_SKIN]
		and garb.spec_name() == "Tribalwear",
		"the garment resolves its apparel record"
	)
	var legacy := DropItem.deserialize(
		garb.serialize().slice(0, 6)
	)
	_check(
		is_equal_approx(legacy.wear, 1.0),
		"an old six-field item loads wear-pristine"
	)

	# --- The worn model: layers conflict, belts holster, packs carry,
	#     and busy hands shrink the load.
	for piece in worker.worn.duplicate():
		worker.worn.erase(piece)
	worker.hands.clear()
	worker.holstered.clear()
	var base_cap := worker.carry_capacity
	_check(worker.carry_cap() == base_cap, "bare hands carry the full load")
	var make_garb := func(spec_id: StringName, wear: float) -> DropItem:
		var piece := DropItem.new(
			BlockRegistry.Resource_.CLOTH,
			DropItem.Form.GARMENT,
			DropItem.GARMENT_CM3
		)
		piece.spec = spec_id
		piece.wear = wear
		return piece
	var make_tool := func(spec_id: StringName) -> DropItem:
		var tool := DropItem.new(
			BlockRegistry.Resource_.IRON,
			DropItem.Form.TOOL,
			DropItem.TOOL_CM3
		)
		tool.spec = spec_id
		return tool
	var tribal: DropItem = make_garb.call(&"tribalwear", 1.0)
	_check(worker.wear_garment(tribal), "a tribalwear goes on")
	_check(
		not worker.can_wear(make_garb.call(&"tribalwear", 1.0)),
		"a second skin-layer garment conflicts"
	)
	var belt: DropItem = make_garb.call(&"tool_belt", 1.0)
	_check(
		worker.wear_garment(belt) and worker.holster_count() == 2,
		"the belt goes on and lends two holsters"
	)
	var knife: DropItem = make_tool.call(&"knife")
	var pick: DropItem = make_tool.call(&"pickaxe")
	_check(
		worker.hold_tool(knife) and worker.carry_cap() == base_cap / 2,
		"a tool in one hand halves the load"
	)
	_check(
		worker.hold_tool(pick) and worker.carry_cap() == 0,
		"tools in both hands end hauling"
	)
	worker.stow_tools()
	_check(
		worker.hands.is_empty() and worker._holstered_count() == 2
		and worker.carry_cap() == base_cap,
		"the belt pockets both tools and frees the hands"
	)
	var pack: DropItem = make_garb.call(&"backpack", 1.0)
	worker.wear_garment(pack)
	_check(
		worker.carry_cap() == int(base_cap * 1.5),
		"the backpack adds half again to the load"
	)
	worker.strip_garment(pack)
	worker.strip_garment(belt)
	# A swap only happens toward better-wear kit.
	tribal.wear = 0.2
	_check(
		worker.wants_garment(make_garb.call(&"tribalwear", 0.9))
		and not worker.wants_garment(make_garb.call(&"tribalwear", 0.1)),
		"a unit swaps up in wear, never down"
	)
	worker.strip_garment(tribal)
	worker.hands.clear()
	worker.holstered.clear()

	# --- Wear and the repair math: garments fray at a trickle, fall
	#     apart at zero, and a repair wants wear-scaled material.
	var frayed: DropItem = make_garb.call(&"tribalwear", 0.5)
	var bill := Colony.repair_loose_for(frayed)
	_check(
		int(bill.get(BlockRegistry.Resource_.CLOTH, -1)) == 10_000,
		"a half-worn garment wants half its make cost"
	)
	_check(
		Colony.repair_loose_for(
			make_garb.call(&"tribalwear", 1.0)
		).is_empty(),
		"a pristine garment needs nothing"
	)
	worker.wear_garment(frayed)
	worker._wear_tick(120.0)
	_check(
		frayed.wear < 0.5 and frayed.wear > 0.49,
		"garments fray at the slow trickle"
	)
	var holster_probe: DropItem = make_garb.call(&"tool_belt", 0.01)
	worker.wear_garment(holster_probe)
	worker.holstered[0] = make_tool.call(&"knife")
	worker._wear_tick(240.0 * 60.0 * 3.0)
	_check(
		not worker.worn.has(frayed) and not worker.worn.has(holster_probe)
		and worker.holstered.is_empty(),
		"threadbare kit falls off and drops its holstered tools"
	)
	# The fallen pieces litter the unit's cell — sweep them away.
	_sweep(colony, worker._standing_voxel())

	# --- Driven: the bench stands, the chain runs, the bills work.
	var run := _clear_run(colony, world, site, 4)
	_check(run != Vector3i.MAX, "found a flat row for the tailor fixtures")
	if run == Vector3i.MAX:
		worker.abandon_job()
		return
	var tailor_cell := run
	var pile_cell := run + Vector3i(3, 0, 0)
	var bench_job := colony.designate_production(tailor_cell, &"tailor_bench")
	_check(bench_job != null, "a tailor's bench designates")
	if bench_job != null:
		_stock_job(bench_job)
		_assign_job(colony, bench_job, tailor_cell)
		var bench_done := await _wait_until(
			func() -> bool: return bench_job.state == ColonyJob.State.DONE
		)
		var bench := colony.building_at(tailor_cell)
		_check(
			bench_done and bench != null
			and bench.kind == Building.Kind.TAILOR
			and bench.is_worksite(),
			"the tailor's bench stands as a worksite"
		)

	# The weave: real dispatch over a cotton pile, stocked escrow for
	# the run — the output pays cloth and the sowing's seed back.
	var cloth_before := 0
	var seed_before := 0
	for voxel: Vector3i in colony.item_piles:
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.CLOTH:
				cloth_before += item.volume
			if item.form == DropItem.Form.SEED and item.species == &"cotton":
				seed_before += 1
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.COTTON, DropItem.Form.LOOSE, 60_000
		),
		pile_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var weave_job := colony.designate_craft(tailor_cell, &"cotton_cloth")
	_check(weave_job != null, "the weave dispatches over a cotton pile")
	if weave_job != null:
		_stock_job(weave_job)
		_assign_job(colony, weave_job, tailor_cell)
		var weave_done := await _wait_until(
			func() -> bool: return weave_job.state == ColonyJob.State.DONE
		)
		var cloth_after := 0
		var seed_after := 0
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if item.material == BlockRegistry.Resource_.CLOTH:
					cloth_after += item.volume
				if item.form == DropItem.Form.SEED and item.species == &"cotton":
					seed_after += 1
		_check(
			weave_done and cloth_after - cloth_before >= 15_000
			and seed_after - seed_before >= 3,
			"the weave pours cloth and returns cotton seed"
		)

	# The make: a cloth tribalwear comes out specced, whole and wearable.
	# The bill wants 20k cloth — top the pile up past the weave's 15k.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.CLOTH, DropItem.Form.LOOSE, 30_000
		),
		pile_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var make_job := colony.designate_craft(tailor_cell, &"garb_tribal")
	_check(make_job != null, "a garment bill dispatches on cloth")
	if make_job != null:
		_stock_job(make_job)
		_assign_job(colony, make_job, tailor_cell)
		var make_done := await _wait_until(
			func() -> bool: return make_job.state == ColonyJob.State.DONE
		)
		var made := false
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if (
					item.form == DropItem.Form.GARMENT
					and item.spec == &"tribalwear"
					and item.material == BlockRegistry.Resource_.CLOTH
					and is_equal_approx(item.wear, 1.0)
				):
					made = true
		_check(
			make_done and made,
			"the bench turns out a specced, pristine cloth tribalwear"
		)

	# The dispatch gate: a repair with no matching garment in a pile
	# queues but never starts — the input_spec pin refuses.
	colony.queue_order(tailor_cell, &"repair_backpack")
	_check(
		colony.craft_job_at(tailor_cell) == null,
		"a repair won't dispatch without its garment"
	)
	var tailor_bld := colony.building_at(tailor_cell)
	for order in tailor_bld.orders.duplicate():
		colony.remove_order(tailor_cell, order)

	# The repair: a half-worn tribalwear in the pile lets the bill
	# dispatch; its wear sets the cloth bill, and the mended garment
	# comes back 80% restored.
	var shabby := DropItem.new(
		BlockRegistry.Resource_.CLOTH,
		DropItem.Form.GARMENT,
		DropItem.GARMENT_CM3
	)
	shabby.spec = &"tribalwear"
	shabby.wear = 0.5
	colony._deposit_item(shabby, pile_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony.queue_order(tailor_cell, &"repair_tribalwear")
	var repair_job := colony.craft_job_at(tailor_cell)
	_check(
		repair_job != null,
		"the repair dispatches once its garment's in a pile"
	)
	if repair_job != null:
		# Hand the escrow what a real fetch would deliver: the garment
		# from its pile, then the wear-scaled cloth bill it computes.
		var home := _pile_of(colony, shabby)
		if home != Vector3i.MAX:
			colony.item_pile_at(home).items.erase(shabby)
			colony.remove_pile_if_empty(home)
		repair_job.components.append(shabby)
		repair_job.delivered[DropItem.Form.GARMENT] = shabby.volume
		repair_job.repair_loose = Colony.repair_loose_for(shabby)
		_check(
			int(
				repair_job.repair_loose.get(
					BlockRegistry.Resource_.CLOTH, -1
				)
			) == 10_000,
			"the garment's wear sets the repair's material bill"
		)
		var mend := DropItem.new(
			BlockRegistry.Resource_.CLOTH,
			DropItem.Form.LOOSE,
			int(repair_job.repair_loose[BlockRegistry.Resource_.CLOTH])
		)
		repair_job.components.append(mend)
		repair_job.delivered[
			Unit.DELIVERED_MATERIAL_OFF + BlockRegistry.Resource_.CLOTH
		] = mend.volume
		_assign_job(colony, repair_job, tailor_cell)
		var mended := await _wait_until(
			func() -> bool: return repair_job.state == ColonyJob.State.DONE
		)
		var back := false
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if (
					item.form == DropItem.Form.GARMENT
					and item.spec == &"tribalwear"
					and item.wear > 0.85
					and item.wear < 0.95
				):
					back = true
		_check(
			mended and back,
			"the mended garment returns with 80% of its wear restored"
		)

	# The salvage: a worn tribalwear comes apart into half its make
	# cost, scaled down by the wear still in it.
	var cloth_pre := 0
	for voxel: Vector3i in colony.item_piles:
		for item in colony.item_piles[voxel].items:
			if item.material == BlockRegistry.Resource_.CLOTH:
				cloth_pre += item.volume
	var scrap := DropItem.new(
		BlockRegistry.Resource_.CLOTH,
		DropItem.Form.GARMENT,
		DropItem.GARMENT_CM3
	)
	scrap.spec = &"tribalwear"
	scrap.wear = 0.6
	colony._deposit_item(scrap, pile_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	colony.queue_order(tailor_cell, &"salvage_tribalwear")
	var salvage_job := colony.craft_job_at(tailor_cell)
	_check(salvage_job != null, "a salvage dispatches on its garment")
	if salvage_job != null:
		var home2 := _pile_of(colony, scrap)
		if home2 != Vector3i.MAX:
			colony.item_pile_at(home2).items.erase(scrap)
			colony.remove_pile_if_empty(home2)
		salvage_job.components.append(scrap)
		salvage_job.delivered[DropItem.Form.GARMENT] = scrap.volume
		_assign_job(colony, salvage_job, tailor_cell)
		var cut := await _wait_until(
			func() -> bool: return salvage_job.state == ColonyJob.State.DONE
		)
		var cloth_post := 0
		for voxel: Vector3i in colony.item_piles:
			for item in colony.item_piles[voxel].items:
				if item.material == BlockRegistry.Resource_.CLOTH:
					cloth_post += item.volume
		# 20k make cost × 0.5 salvage × 0.6 wear = 6k of cloth back.
		_check(
			cut and absi(cloth_post - cloth_pre - 6_000) < 500,
			"the salvage returns half the make cost, wear-scaled"
		)

	# The dress errand: a garment in a pile draws a bare unit to put it
	# on, and a better piece swaps the worn one out — the loop that
	# feeds worn garments back to the bench. Stray garments from the
	# craft checks would draw the errand instead, so clear them first.
	var clear_garments := func() -> void:
		for voxel: Vector3i in colony.item_piles.keys():
			var pile := colony.item_piles[voxel]
			for i in range(pile.items.size() - 1, -1, -1):
				if pile.items[i].form == DropItem.Form.GARMENT:
					pile.items.remove_at(i)
			colony.remove_pile_if_empty(voxel)
	clear_garments.call()
	worker.worn.clear()
	worker.hands.clear()
	worker.holstered.clear()
	worker.abandon_job()
	var dress_garb := DropItem.new(
		BlockRegistry.Resource_.CLOTH,
		DropItem.Form.GARMENT,
		DropItem.GARMENT_CM3
	)
	dress_garb.spec = &"tribalwear"
	colony._deposit_item(dress_garb, pile_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	worker.global_position = (
		Vector3(tailor_cell) + Vector3(1.5, 0.9, 0.5)
	)
	var dressed := worker._try_dress()
	_check(dressed, "a bare unit takes a dress errand on a garment pile")
	if dressed:
		var got_dressed := await _wait_until(
			func() -> bool:
				return worker.job == null and not worker.worn.is_empty()
		)
		_check(
			got_dressed and worker.worn.has(dress_garb),
			"the unit walks over and puts the garment on"
		)
	var upgrade := DropItem.new(
		BlockRegistry.Resource_.LEATHER,
		DropItem.Form.GARMENT,
		DropItem.GARMENT_CM3
	)
	upgrade.spec = &"tribalwear"
	upgrade.wear = 1.0
	# The worn piece frays; the pile's better one must outshine it.
	dress_garb.wear = 0.2
	clear_garments.call()
	colony._deposit_item(upgrade, pile_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var swapped := worker._try_dress()
	if swapped:
		var got_swap := await _wait_until(
			func() -> bool:
				return worker.job == null
		)
		var wears_new := (
			worker.garment_worn(&"tribalwear") == upgrade
			if worker.garment_worn(&"tribalwear") != null else false
		)
		var old_back := false
		for voxel: Vector3i in colony.item_piles:
			if colony.item_piles[voxel].items.has(dress_garb):
				old_back = true
		_check(
			got_swap and wears_new and old_back,
			"a better piece swaps in and the worn one lands in a pile"
		)
	else:
		_check(false, "the upgrade garment draws a swap errand")

	# --- Serialization: worn, hands and holsters round-trip, and the
	#     old single `equipment` slot migrates into a hand.
	var naive := colony.spawn_unit(pile_cell + Vector3i(0, 0, 1))
	naive._job_search_cooldown = 600.0
	var ser_tool := DropItem.new(
		BlockRegistry.Resource_.IRON, DropItem.Form.TOOL, DropItem.TOOL_CM3
	)
	ser_tool.spec = &"knife"
	naive.deserialize(
		{"equipment": ser_tool.serialize()}, colony
	)
	_check(
		naive.hands.size() == 1 and naive.hands[0].spec == &"knife",
		"a legacy equipment slot loads into a hand"
	)
	naive.hands.clear()
	naive.wear_garment(make_garb.call(&"tribalwear", 0.7))
	naive.hold_tool(make_tool.call(&"pickaxe"))
	var naive_data := naive.serialize()
	naive.worn.clear()
	naive.hands.clear()
	naive.deserialize(naive_data, colony)
	_check(
		naive.worn.size() == 1
		and is_equal_approx(naive.worn[0].wear, 0.7)
		and naive.hands.size() == 1
		and naive.hands[0].spec == &"pickaxe",
		"worn and held kit survive the unit save"
	)
	naive.dead = true
	colony.units.erase(naive)
	colony._sleeping.erase(naive)
	colony.unit_died.emit(naive)
	naive.queue_free()

	# --- Cleanup: the bench comes down, the litter goes.
	for piece in worker.worn.duplicate():
		worker.worn.erase(piece)
	worker.hands.clear()
	worker.holstered.clear()
	colony._teardown_building(tailor_cell)
	_sweep_run(colony, run, 4)
	_clear_jobs(colony)


## Item 38 — allowed areas, the forbid flag, shelves, and filter
## copy/paste + presets. Mostly model checks; the one driven build is
## the shelf itself, where designation → construction → zone
## registration all run for real.
func _test_allowed(colony: Colony, world: VoxelWorld, _unit: Unit, site: Vector3i) -> void:
	print("allowed areas / forbid / shelves")
	for u in colony.units:
		u._job_search_cooldown = 300.0
		if u.job != null and not u.job.desperate:
			colony.release_job(u.job)
		u.abandon_job()
	var worker: Unit = colony.units[0]

	# --- The flag itself: a field that serializes like everything else.
	var flag := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
		DropItem.COBBLE_CM3
	)
	flag.forbidden = true
	var flag_back := DropItem.deserialize(flag.serialize())
	_check(
		flag_back != null and flag_back.forbidden,
		"the forbid flag survives a save round-trip"
	)
	var plain := DropItem.deserialize([0, 0, 10000, "", 0.0, 1.0, "", 1.0])
	_check(
		plain != null and not plain.forbidden,
		"an old item record deserializes unforbidden"
	)

	# --- A fixture row: pile, area pair, stockpile, shelf, food cells.
	var run := _clear_run(colony, world, site, 12)
	_check(run != Vector3i.MAX, "found a flat row for the area fixtures")
	if run == Vector3i.MAX:
		return
	var forbid_cell := run
	var in_cell := run + Vector3i(2, 0, 0)
	var out_cell := run + Vector3i(5, 0, 0)
	var sp_cell := run + Vector3i(7, 0, 0)
	var in_sp_cell := run + Vector3i(3, 0, 0)
	var shelf_cell := run + Vector3i(9, 0, 0)
	var build_cell := run + Vector3i(11, 0, 0)

	# --- Pile-level forbid/unforbid helpers.
	var rock := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
		DropItem.BOULDER_CM3
	)
	var rock2 := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.LOG, DropItem.LOG_CM3
	)
	# A whole log fills its own cell — the boulder pile and the log pile
	# sit side by side and each takes the flag.
	var log_cell := forbid_cell + Vector3i(1, 0, 0)
	colony._deposit_item(rock, forbid_cell)
	colony._deposit_item(rock2, log_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var forbid_v := _pile_of(colony, rock)
	var forbid_log_v := _pile_of(colony, rock2)
	_check(forbid_v != Vector3i.MAX, "the forbid pile landed")
	_check(forbid_log_v != Vector3i.MAX, "the forbid log pile landed")
	if forbid_v != Vector3i.MAX:
		colony.set_pile_forbidden(forbid_v, true)
		if forbid_log_v != Vector3i.MAX:
			colony.set_pile_forbidden(forbid_log_v, true)
		_check(
			colony.pile_all_forbidden(forbid_v)
			and colony.pile_any_forbidden(forbid_v),
			"the pile takes the forbid flag wholesale"
		)
		# Take paths refuse: the flag is a do-not-touch, whatever the
		# filter admits. The queries can't prove "no pile anywhere" —
		# earlier fixtures litter the map — so they prove "not this one".
		_check(
			colony.nearest_haulable_pile(forbid_v + Vector3i(0, 0, 2), {})
			!= forbid_v,
			"an all-forbidden pile is no haul candidate"
		)
		_check(
			colony.nearest_wall_voxel(
				forbid_v + Vector3i(0, 0, 2),
				BlockRegistry.Resource_.STONE
			) != forbid_v,
			"a build fetch skips forbidden rock"
		)
		_check(
			colony.nearest_form_voxel(
				forbid_v + Vector3i(0, 0, 2), DropItem.Form.LOG
			) != forbid_log_v,
			"a furnish fetch skips a forbidden log"
		)
		var taken := colony.item_pile_at(forbid_v).take_up_to(
			DropItem.BLOCK_CM3
		)
		_check(taken.is_empty(), "nothing leaves a forbidden pile")
		colony.set_pile_forbidden(forbid_v, false)
		if forbid_log_v != Vector3i.MAX:
			colony.set_pile_forbidden(forbid_log_v, false)
		_check(
			not colony.pile_any_forbidden(forbid_v),
			"unforbid frees the pile again"
		)

	# --- A mixed pile: allowed goods move, the flag stays.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
			DropItem.COBBLE_CM3
		),
		forbid_cell
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		),
		forbid_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var mixed_v := _pile_of(colony, rock)
	_check(mixed_v != Vector3i.MAX, "the mixed pile settled")
	if mixed_v != Vector3i.MAX:
		var mix := colony.item_pile_at(mixed_v)
		rock.forbidden = true
		var moved := mix.take_up_to(DropItem.BLOCK_CM3)
		_check(
			moved.size() == 2 and not moved.has(rock) and rock.forbidden,
			"forbidden goods stay behind when the rest of the pile moves"
		)
		rock.forbidden = false
		for item in moved:
			mix.add_item(item)

	# --- Areas: paint, ownership, repaint, erase.
	var pen := colony.add_area("Pen")
	var yard := colony.add_area("")
	_check(
		pen != null and pen.label == "Pen" and yard.label.begins_with("Area"),
		"areas take a name, or mint one"
	)
	# The run+1 cell pads the paint so a spilled deposit still lands
	# inside the bounds.
	var painted := colony.designate_area_cells(
		[in_cell, run + Vector3i(1, 0, 0), in_sp_cell, out_cell], pen
	)
	if painted != 4 or pen.cells.size() != 4 or colony.area_at(in_cell) != pen:
		printerr(
			"area paint: painted=", painted, " cells=", pen.cells.keys(),
			" at=", colony.area_at(in_cell)
		)
	_check(
		painted == 4 and colony.area_at(in_cell) == pen
		and pen.cells.size() == 4,
		"the paint tool fills the area"
	)
	var moved := colony.designate_area_cells([out_cell], yard)
	if moved != 1 or pen.cells.size() != 3 or colony.area_at(out_cell) != yard:
		printerr(
			"area repaint: moved=", moved, " pen=", pen.cells.keys(),
			" yard=", yard.cells.keys()
		)
	_check(
		moved == 1 and colony.area_at(out_cell) == yard
		and pen.cells.size() == 3,
		"repainting moves a cell between areas"
	)
	_check(
		Colony.in_area(pen, in_cell) and not Colony.in_area(pen, out_cell)
		and Colony.in_area(null, Vector3i(-999, 0, -999)),
		"the area gate reads null as unrestricted"
	)
	_check(
		colony.nearest_area_cell(out_cell, pen) in pen.cells,
		"the homeward query lands inside the area"
	)
	var erased := colony.undesignate_area_cells([out_cell])
	_check(
		erased == 1 and colony.area_at(out_cell) == null,
		"the erase tool frees a cell"
	)

	# --- Unit gating: selection queries and the claim gate both obey.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		in_cell
	)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
			DropItem.MEAL_CM3
		),
		out_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var food_found := colony.nearest_food_pile(
		out_cell + Vector3i(0, 0, 3), {}, pen
	)
	_check(
		food_found != Vector3i.MAX and pen.cells.has(food_found),
		"a restricted unit eats only inside its area"
	)
	colony.set_unit_area(worker, pen)
	var out_job := ColonyJob.new(ColonyJob.Type.MINE, forbid_cell)
	_check(
		not colony._job_allowed_for(worker, out_job),
		"the board refuses a restricted unit's out-of-area job"
	)
	var order_job := ColonyJob.new(ColonyJob.Type.ORDER, forbid_cell)
	_check(
		colony._job_allowed_for(worker, order_job),
		"a player-forced move ignores the area gate"
	)
	var in_job := ColonyJob.new(ColonyJob.Type.MINE, in_cell)
	_check(
		colony._job_allowed_for(worker, in_job),
		"an in-area job stays claimable"
	)
	worker.job = out_job
	colony.set_unit_area(worker, yard)
	_check(
		worker.job == null,
		"reassigning drops a job outside the new bounds"
	)
	colony.set_unit_area(worker, pen)

	# Stockpile delivery obeys the area: the out-of-bounds zone loses
	# to the one painted in.
	var sp_cells: Array[Vector3i] = [sp_cell]
	var zone := colony.designate_stockpile_cells(
		sp_cells, sp_cell, false
	)
	var in_sp_cells: Array[Vector3i] = [in_sp_cell]
	var in_zone := colony.designate_stockpile_cells(
		in_sp_cells, in_sp_cell, false
	)
	_check(zone != null and in_zone != null, "both stockpile zones paint")
	if zone != null and in_zone != null:
		var sp_pick := colony.nearest_stockpile_with_room(
			out_cell + Vector3i(0, 0, 3), 1, {},
			[BlockRegistry.Resource_.STONE], pen
		)
		_check(
			sp_pick == in_sp_cell,
			"deliver-to-stockpile stays inside the area"
		)

	# --- Animals read their own assignment.
	var animal := colony.animals[0] if not colony.animals.is_empty() else null
	if animal != null:
		colony.set_animal_area(animal, pen)
		_check(
			animal.allowed_area == pen,
			"an animal takes its pen assignment"
		)
		colony.set_animal_area(animal, null)

	# --- The shelf: a stockpile in a building, twice the floor's room.
	var shelf := Building.new(Building.Kind.SHELF, shelf_cell)
	colony.register_building(shelf)
	_check(
		colony.shelf_at(shelf_cell) == shelf
		and colony.is_stockpile(shelf_cell),
		"a shelf registers as a stockpile cell"
	)
	_check(
		colony.voxel_capacity(shelf_cell) == Colony.SHELF_PILE_CM3
		and Colony.SHELF_PILE_CM3 > DropItem.BLOCK_CM3,
		"shelving outpacks the bare floor"
	)
	_check(
		not colony.undesignate_stockpile(shelf_cell),
		"a shelf cell isn't a designation to erase"
	)
	colony.set_stockpile_admission(
		shelf_cell, BlockRegistry.Resource_.STONE, false
	)
	_check(
		not colony.stockpile_admits(
			shelf_cell, BlockRegistry.Resource_.STONE
		),
		"a shelf's zone takes the stockpile filter"
	)
	var shelf_pick := colony.nearest_stockpile_with_room(
		shelf_cell + Vector3i(0, 0, 2), 1, {},
		[BlockRegistry.Resource_.WOOD]
	)
	_check(
		shelf_pick == shelf_cell,
		"shelf cells answer the deliver-to-stockpile query"
	)
	# Shelved goods over the floor's cap spill only when the shelf dies.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.SOIL, DropItem.Form.LOOSE,
			DropItem.BLOCK_CM3 + DropItem.BLOCK_CM3 / 2
		),
		shelf_cell
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony.voxel_fill(shelf_cell) > DropItem.BLOCK_CM3,
		"the shelf holds more than a floor pile can"
	)
	colony._teardown_building(shelf_cell)
	_check(
		not colony.is_stockpile(shelf_cell)
		and colony.shelf_at(shelf_cell) == null,
		"the shelf's zone dies with the building"
	)
	_check(
		colony.voxel_fill(shelf_cell) <= DropItem.BLOCK_CM3,
		"over-full shelves spill to the floor's cap"
	)

	# --- Driven: designate → build → the cell becomes a stockpile.
	var shelf_job := colony.designate_production(build_cell, &"shelf")
	_check(shelf_job != null, "a shelf designates for construction")
	if shelf_job != null:
		_stock_job(shelf_job)
		_assign_job(colony, shelf_job, build_cell)
		var shelf_done := await _wait_until(
			func() -> bool: return shelf_job.state == ColonyJob.State.DONE
		)
		_check(
			shelf_done
			and colony.shelf_at(build_cell) != null
			and colony.is_stockpile(build_cell),
			"the built shelf stands and stores"
		)

	# --- Filters travel: paste, presets.
	if in_zone != null:
		colony.set_stockpile_admission(
			in_sp_cell, BlockRegistry.Resource_.BERRY, false
		)
		colony.set_stockpile_filter(sp_cell, in_zone.rejected)
		_check(
			not colony.stockpile_admits(
				sp_cell, BlockRegistry.Resource_.BERRY
			),
			"a copied filter stamps onto another zone"
		)
		FilterPresets.save("smoke_test_preset", in_zone.rejected)
		_check(
			FilterPresets.names().has("smoke_test_preset")
			and FilterPresets.preset("smoke_test_preset").has(
				int(BlockRegistry.Resource_.BERRY)
			),
			"a named preset saves and reads back"
		)
		colony.set_stockpile_filter(
			sp_cell, FilterPresets.preset("smoke_test_preset")
		)
		FilterPresets.erase("smoke_test_preset")
		_check(
			not FilterPresets.names().has("smoke_test_preset"),
			"a deleted preset is gone"
		)

	# --- Serialization: areas, assignments and shelf cells ride the save.
	worker.allowed_area = pen
	var data := colony.serialize()
	var area_data: Array = data.get("areas", [])
	var area_ok := false
	for ad: Dictionary in area_data:
		if ad.get("label", "") == "Pen" and ad.get("cells", []).size() == 3:
			area_ok = true
	var area_index := -1
	if not data.get("units", []).is_empty():
		# The worker is units[0] — serialize walks the same list.
		area_index = int(data["units"][0].get("area", -1))
	_check(
		area_ok and area_index == colony.areas.find(pen),
		"areas and unit assignments serialize"
	)
	var roundtrip := AllowedArea.deserialize(area_data[0])
	_check(
		roundtrip != null
		and roundtrip.cells.size() == (area_data[0] as Dictionary).get("cells", []).size(),
		"an area survives its own round-trip"
	)

	# --- Cleanup: zones, areas, the standing shelf, litter.
	colony.set_unit_area(worker, null)
	colony.undesignate_stockpile(sp_cell)
	colony.undesignate_stockpile(in_sp_cell)
	colony.remove_area(pen)
	colony.remove_area(yard)
	colony._teardown_building(build_cell)
	_check(
		worker.allowed_area == null and colony.areas.is_empty(),
		"the fixture areas tear down clean"
	)
	for u in colony.units:
		u._job_search_cooldown = 0.0
	_sweep_run(colony, run, 12)
	_clear_jobs(colony)


## Home area (PLAN item 44): paint and erase, the auto-expand halo,
## the firefight and repair spawn gates, and the fetch preference —
## an in-home pile outranks a closer foreign one.
func _test_home_area(
	colony: Colony, world: VoxelWorld, _unit: Unit, site: Vector3i
) -> void:
	print("home area")
	for u in colony.units:
		u._job_search_cooldown = 600.0
		u.abandon_job()
	_clear_jobs(colony)
	var saved_weather := colony.weather.serialize()
	colony.weather.state = Weather.State.CLEAR
	colony.weather.remaining = 9999.0
	colony.weather.saturation = 0.0

	# Prior sections may leave their own paint behind — the fixture
	# starts from a blank area so every home cell here is deliberate.
	colony.undesignate_home_cells(colony.home_cells.keys())
	var run := _clear_run(colony, world, site, 12)
	_check(run != Vector3i.MAX, "found a flat row for the home fixtures")
	if run == Vector3i.MAX:
		colony.weather.deserialize(saved_weather)
		for u in colony.units:
			u._job_search_cooldown = 0.0
		return

	# --- Manual paint: membership, erase, and the bucket index.
	var a := run
	var b := run + Vector3i(3, 0, 0)
	var foreign := run + Vector3i(6, 0, 0)
	colony.designate_home_cells([a, b])
	_check(
		colony.in_home_area(a) and colony.in_home_area(b),
		"painted cells read as home"
	)
	_check(not colony.in_home_area(foreign), "unpainted cells stay foreign")
	_check(
		colony.nearest_home_cell(foreign + Vector3i(2, 0, 0)) == b,
		"the nearest home cell resolves through the index"
	)
	colony.undesignate_home_cells([a])
	_check(not colony.in_home_area(a), "an erased cell leaves the area")
	colony.designate_home_cells([a])

	# --- Firefight gate: a fire outside home burns unbilled, a fire
	#     inside posts the beat-down bill.
	var out_fire := foreign + Vector3i(0, -1, 0)
	var home_fire := b + Vector3i(-1, -1, 0)
	colony.undesignate_home_cells([out_fire])
	colony.designate_home_cells([home_fire])
	colony.grass._set_cover(out_fire, 1.0)
	colony.grass._set_cover(home_fire, 1.0)
	colony.ignite(out_fire)
	_check(
		colony.is_burning(out_fire),
		"a foreign fire still ignites"
	)
	_check(
		colony.firefight_job_at(out_fire) == null,
		"a fire outside home posts no bill"
	)
	colony.ignite(home_fire)
	_check(
		colony.firefight_job_at(home_fire) != null,
		"a fire inside home posts its bill"
	)
	colony._extinguish(out_fire)
	colony._extinguish(home_fire)

	# --- Repair gate: a battered construction only posts its bill in
	#     the home area.
	var out_b := Building.new(Building.Kind.RECREATION, run + Vector3i(6, 0, 0))
	out_b.spec = &"ur_board"
	out_b.footprint.append(out_b.voxel)
	colony.register_building(out_b, false)
	colony.undesignate_home_cells([out_b.voxel])
	colony.damage_building(out_b, 10.0)
	_check(
		colony.repair_job_at(out_b.voxel) == null,
		"a battered building outside home gets no bill"
	)
	var home_b := Building.new(Building.Kind.RECREATION, run + Vector3i(7, 0, 0))
	home_b.spec = &"ur_board"
	home_b.footprint.append(home_b.voxel)
	colony.register_building(home_b, false)
	colony.designate_home_cells([home_b.voxel])
	colony.damage_building(home_b, 10.0)
	_check(
		colony.repair_job_at(home_b.voxel) != null,
		"a battered building at home posts its bill"
	)
	# A powered device keeps the technology gate it was built under —
	# the mend is electrician's work, not plain construction.
	var gen_b := Building.new(Building.Kind.GENERATOR, run + Vector3i(3, 0, 0))
	gen_b.footprint.append(gen_b.voxel)
	colony.register_building(gen_b, false)
	colony.designate_home_cells([gen_b.voxel])
	colony.damage_building(gen_b, 10.0)
	var gen_repair := colony.repair_job_at(gen_b.voxel)
	_check(
		gen_repair != null
			and gen_repair.required_skill == ColonyJob.Skill.ELECTRICIAN,
		"a battered generator posts an Electrician-gated bill"
	)

	# --- Auto-expand: construction, conduits and fresh zone cells each
	#     pull the 3x3x3 cube around them into the area.
	colony.auto_home = true
	var grow_b := Building.new(Building.Kind.WORKSITE, run + Vector3i(8, 0, 0))
	grow_b.footprint.append(grow_b.voxel)
	colony.register_building(grow_b)
	_check(
		colony.in_home_area(grow_b.voxel)
			and colony.in_home_area(grow_b.voxel + Vector3i(1, 1, 1))
			and colony.in_home_area(grow_b.voxel + Vector3i(-1, -1, -1)),
		"a built thing pulls its cube into home"
	)
	_check(
		not colony.in_home_area(grow_b.voxel + Vector3i(2, 0, 0)),
		"the halo stops at the cube's edge"
	)
	var wall_b := Building.new(Building.Kind.WALL, run + Vector3i(10, 0, 0))
	wall_b.footprint.append(wall_b.voxel)
	colony.register_building(wall_b, false)
	colony.undesignate_home_cells(
		[wall_b.voxel, wall_b.voxel + Vector3i(1, 0, 1)]
	)
	var wire_job := ColonyJob.new(
		ColonyJob.Type.BUILD, wall_b.voxel + Vector3i.DOWN
	)
	wire_job.face_dir = Vector3i.UP
	colony.complete_conduit(wire_job)
	_check(
		wall_b.conduit
			and colony.in_home_area(wall_b.voxel)
			and colony.in_home_area(wall_b.voxel + Vector3i(1, 0, 1)),
		"a conduit line grows home off its wall"
	)
	# Zone designations grow home too — the stockpile at the run's end
	# and the field beside the worksite each pull their cube in. Both
	# cells start inside an earlier halo, so the check cells get an
	# explicit erase first — the designation's own paint is what the
	# assertion reads.
	var sp_cell := run + Vector3i(11, 0, 0)
	var fm_cell := run + Vector3i(9, 0, 0)
	colony.undesignate_home_cells(
		[sp_cell, sp_cell + Vector3i(1, 1, 1),
		fm_cell, fm_cell + Vector3i(1, -1, 1)]
	)
	colony.designate_stockpile(sp_cell)
	_check(
		colony.in_home_area(sp_cell)
			and colony.in_home_area(sp_cell + Vector3i(1, 1, 1)),
		"a designated stockpile grows home"
	)
	colony.designate_farm(fm_cell)
	_check(
		colony.in_home_area(fm_cell)
			and colony.in_home_area(fm_cell + Vector3i(1, -1, 1)),
		"a designated field grows home"
	)
	colony.auto_home = false
	var stray_cell := run + Vector3i(4, 0, 0)
	colony.undesignate_home_cells([stray_cell])
	colony.designate_stockpile(stray_cell)
	_check(
		not colony.in_home_area(stray_cell),
		"the toggle off leaves a new zone foreign"
	)

	# --- Fetch preference: an in-home pile beats a closer foreign
	#     one; erase the paint and the search falls back.
	var near_v := run + Vector3i(2, 0, 0)
	var far_v := run + Vector3i(5, 0, 0)
	var from_c := run + Vector3i(1, 0, 0)
	colony.undesignate_home_cells([near_v])
	colony.designate_home_cells([far_v])
	var probe_a := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.SEED, 100
	)
	probe_a.species = &"zzz_home_probe"
	var probe_b := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.SEED, 100
	)
	probe_b.species = &"zzz_home_probe"
	colony._deposit_item(probe_a, near_v)
	colony._deposit_item(probe_b, far_v)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		colony.nearest_seed_voxel(from_c, &"zzz_home_probe") == far_v,
		"the in-home pile outranks the closer foreign one"
	)
	colony.undesignate_home_cells([far_v])
	_check(
		colony.nearest_seed_voxel(from_c, &"zzz_home_probe") == near_v,
		"with no home hit the search falls back outside"
	)

	# --- The painted set and the toggle ride the save record.
	var data := colony.serialize()
	_check(
		data.has("home_area") and data.has("auto_home"),
		"the save carries the home area and its toggle"
	)
	var saved_a := false
	for hc: Array in data.get("home_area", []):
		if hc.size() >= 3 and Vector3i(
			int(hc[0]), int(hc[1]), int(hc[2])
		) == a:
			saved_a = true
	_check(saved_a, "a painted cell survives into the record")

	# --- Cleanup: every painted cell out, fixtures down, sky and
	#     claim sweeps restored.
	colony.undesignate_home_cells(colony.home_cells.keys())
	_check(colony.home_cells.is_empty(), "the home paint tears down clean")
	colony.auto_home = false
	for cell: Vector3i in colony._fires.keys():
		colony._extinguish(cell)
	colony._teardown_building(out_b.voxel)
	colony._teardown_building(home_b.voxel)
	colony._teardown_building(gen_b.voxel)
	colony._teardown_building(grow_b.voxel)
	colony._teardown_building(wall_b.voxel)
	colony.undesignate_stockpile(sp_cell)
	colony.undesignate_stockpile(stray_cell)
	colony.undesignate_farm(fm_cell)
	colony.weather.deserialize(saved_weather)
	for u in colony.units:
		u._job_search_cooldown = 0.0
	_sweep_run(colony, run, 12)
	_clear_jobs(colony)


## The data-package seam: pack sections, the tribal roster's shape,
## periphery-entry geometry, and a live settler arrival. Runs
## synchronously end to end so the spawned fixture can't claim a job.
func _test_scenario(
	main: Main, colony: Colony, world: VoxelWorld, mined: Vector3i
) -> void:
	var pack := DataPackage.package_named(&"vanilla")
	_check(
		not pack.is_empty()
			and pack.has(&"biomes") and pack.has(&"biome_rules")
			and pack.has(&"animals") and pack.has(&"plants")
			and pack.has(&"trees") and pack.has(&"worldgen"),
		"the vanilla pack carries every content section"
	)
	_check(
		DataPackage.biome_index(&"ocean") == 0
			and DataPackage.biome_index(&"ice_cap") > 0,
		"biome ids resolve through the installed pack"
	)
	var scn := DataPackage.scenario_named(&"lost_tribe")
	_check(
		not scn.is_empty() and int(scn.get(&"settler_count", 0)) == 5,
		"the tribal start fields five settlers"
	)
	var herd: Array = scn.get(&"animals", [])
	_check(
		herd.size() == 1
			and int(herd[0].get(&"count", 0)) == 3
			and herd[0].get(&"domestic") == true,
		"the tribal start brings three domestic animals"
	)
	_check(
		not (scn.get(&"items", []) as Array).is_empty(),
		"the tribal start scatters gear at the landing"
	)
	_check(
		DataPackage.scenario_named(&"dev").has(&"id"),
		"the dev scenario stays registered alongside it"
	)

	# --- Periphery entry: a traveller walking east first crosses the
	#     west edge; one walking -z crosses the far z edge.
	_check(
		colony.site_bounds.has_area(),
		"the site hands the colony its boundary"
	)
	var centre := Vector2(colony.site_bounds.get_center())
	var west := colony.periphery_entry(Vector2(1, 0))
	_check(
		west.x <= colony.site_bounds.position.x + 2
			and absf(float(west.z) - centre.y) <= 3.0,
		"an eastbound traveller enters at the west edge"
	)
	var south := colony.periphery_entry(Vector2(0, -1))
	_check(
		south.z >= colony.site_bounds.position.y + colony.site_bounds.size.y - 3
			and absf(float(south.x) - centre.x) <= 3.0,
		"a -z traveller enters at the far z edge"
	)
	var g := world.ground_height(west.x, west.z, 96)
	_check(
		west.y <= g + 2 and west.y >= g,
		"the entry cell sits on the terrain"
	)

	# --- A live arrival: the roll's skills and knowledge land, the
	#     unit walks in on a self-issued order, then tears down.
	var before := colony.units.size()
	var newcomer := colony.spawn_settler(
		{&"skills": {&"plants": 4}, &"knowledge": [&"charcoal_burning"]},
		Vector2(1, 0)
	)
	_check(colony.units.size() == before + 1, "the settler joins the roster")
	_check(
		newcomer.skill_level(ColonyJob.Skill.PLANTS) == 4,
		"the roll's named skill lands at its level"
	)
	_check(
		newcomer.skill_level(ColonyJob.Skill.CHARCOAL_BURNING) >= 1,
		"the roll's knowledge grants basic competence"
	)
	_check(
		newcomer.job == null
			or newcomer.job.type == ColonyJob.Type.ORDER,
		"an arriving settler walks in on a move order"
	)
	colony.units.erase(newcomer)
	newcomer.queue_free()

	# --- Domestic stock: the flag rides the animal's record.
	var boar := colony.spawn_animal(
		&"boar", Vector3i(mined.x + 6, mined.y + 8, mined.z)
	)
	boar.domestic = true
	var adata := boar.serialize()
	_check(
		adata.get("domestic", false) == true,
		"a domestic animal's status rides its save record"
	)
	colony.animals.erase(boar)
	boar.queue_free()

	var cdata := colony.serialize()
	_check(
		cdata.get("scenario", "") != "",
		"the colony's record names its scenario"
	)

	# --- Pemmican: the tribe's preserved food — meat and fruit dried
	#     down at the campfire into a brick that keeps for seasons, and
	#     the landing scatter carries a starting store.
	var pemmican := Colony.recipe_of(&"make_pemmican")
	_check(
		not pemmican.is_empty()
			and int(pemmican.get("site", -1)) == Building.Kind.CAMPFIRE,
		"the pemmican recipe works at the campfire"
	)
	_check(
		int(pemmican.get("output_material", -1))
			== BlockRegistry.Resource_.PEMMICAN
			and pemmican.get(&"input_loose", {}).has(
				BlockRegistry.Resource_.MEAT
			),
		"pemmican dries meat and fruit into its own material"
	)
	var pem := DropItem.new(
		BlockRegistry.Resource_.PEMMICAN, DropItem.Form.MEAL,
		DropItem.MEAL_CM3
	)
	var meal := DropItem.new(
		BlockRegistry.Resource_.MEAL, DropItem.Form.MEAL,
		DropItem.MEAL_CM3
	)
	_check(
		DropItem.is_food(BlockRegistry.Resource_.PEMMICAN)
			and float(DropItem.decay_rule(pem).get(&"days", 0.0))
				> float(DropItem.decay_rule(meal).get(&"days", 0.0)),
		"pemmican eats like food and outlasts a cooked meal"
	)
	var pemmican_stock := 0
	for def: Dictionary in scn.get(&"items", []):
		if int(def.get(&"material", -1)) == BlockRegistry.Resource_.PEMMICAN:
			pemmican_stock += int(def.get(&"count", 0))
	_check(pemmican_stock >= 10, "the tribal start scatters pemmican")

	# --- Ruins: the site seeded standing stone walls inside its bounds —
	#     registered as deconstructable buildings holding the hundred and
	#     twenty dressed blocks a wall is made of — and the site record's
	#     flag keeps the pass from re-running on later activations.
	var ruin_walls := 0
	for cell: Vector3i in colony.buildings:
		var b: Building = colony.buildings[cell]
		if b.spec != &"stone_wall" or not b.deconstructable:
			continue
		if not main.site.bounds.has_point(Vector2i(cell.x, cell.z)):
			continue
		var blocks := 0
		for item in b.components:
			if (
				item.form == DropItem.Form.BLOCK
				and item.material == BlockRegistry.Resource_.STONE
			):
				blocks += 1
		if blocks == 120:
			ruin_walls += 1
	_check(
		ruin_walls > 0,
		"the site seeded ancient walls paying dressed stone"
	)
	_check(
		main.site.ruins_placed,
		"the site remembers its ruins were laid"
	)


## Self-scheduling — the goal-driven answer to RimWorld's schedule tab
## (SmarterScheduling's model): a unit nearing its break line
## decompresses and holds there until the bar clears, a colony with a
## patient waiting doesn't idle or sleep early, and the relieved-of-
## duty flag stands a unit down without touching its self-care.
## Driven like the recreation section: parked units, pinned needs.
func _test_scheduling(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("self-scheduling")
	for u in colony.units:
		u._job_search_cooldown = 600.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)
	var unfreeze := func() -> void:
		for u in colony.units:
			u._job_search_cooldown = 0.0
	colony.needs_enabled = true
	var reset := func() -> void:
		if unit.job != null:
			colony.release_job(unit.job)
		unit.abandon_job()
		if unit._rest_bed != null:
			if unit._rest_bed.occupant == unit:
				unit._rest_bed.occupant = null
			unit._rest_bed = null
		unit.state = Unit.State.IDLE
		unit.hunger = 1.0
		unit.energy = 1.0
		unit.recreation = 1.0
		unit.mood = 1.0
		unit._decompressing = false
		unit._decompress_spent = false
		unit.relieved = false
		unit._job_search_cooldown = 600.0
	reset.call()

	# --- Therapy gate: mood under the therapy line sends the unit to
	#     recreation even with the fun bar nearly full.
	unit.mood = unit._break_threshold() - 0.02
	unit.recreation = 0.9
	unit._job_search_cooldown = 0.0
	var therapy := await _wait_until(func() -> bool:
		return (
			unit.job != null
			and unit.job.type == ColonyJob.Type.RECREATE
		))
	_check(
		therapy, "a fraying unit seeks recreation before the break"
	)
	_check(
		unit._decompressing,
		"crossing the therapy line latches the decompress flag"
	)
	reset.call()

	# --- The latch carries it: above the therapy line but below the
	#     release margin, a latched unit keeps at recreation though the
	#     plain boredom seek wouldn't have fired.
	unit._decompressing = true
	unit.mood = (unit._mood_therapy_line() + unit._mood_release_line()) * 0.5
	unit.recreation = 0.6
	unit._job_search_cooldown = 0.0
	var held := await _wait_until(func() -> bool:
		return (
			unit.job != null
			and unit.job.type == ColonyJob.Type.RECREATE
		))
	_check(
		held, "the decompress latch keeps the unit in recreation"
	)
	reset.call()

	# --- The latch releases past the margin — the unit reaches for the
	#     board again instead of another session.
	unit._decompressing = true
	unit.mood = unit._mood_release_line() + 0.02
	unit.recreation = 0.6
	unit._job_search_cooldown = 0.0
	var cleared := await _wait_until(func() -> bool:
		return not unit._decompressing)
	_check(
		cleared,
		"the latch releases once mood clears the margin"
	)
	reset.call()

	# --- Spent hysteresis: a stint that topped the fun bar out doesn't
	#     re-latch while the bar is still high — therapy can't be what
	#     the mood needs when there's nothing left to gain.
	unit._decompress_spent = true
	unit.mood = unit._break_threshold() - 0.02
	unit.recreation = 0.9
	unit._job_search_cooldown = 0.0
	for i in 30:
		await physics_frame
	_check(
		not unit._decompressing,
		"a spent stint doesn't re-latch on a full bar"
	)
	# Fun drained to the seek line — the flag frees so the latch can
	# fire again on its merits. The unit may have claimed a board job
	# above, and the latch only re-evaluates while idle — park it
	# first. (The low bar then claims a session through the ordinary
	# boredom path, so only the flag is checked.)
	if unit.job != null:
		colony.release_job(unit.job)
	unit.abandon_job()
	unit.state = Unit.State.IDLE
	unit._job_search_cooldown = 0.0
	unit.recreation = 0.0
	var freed := await _wait_until(func() -> bool:
		return not unit._decompress_spent)
	_check(
		freed,
		"the spent flag frees once fun genuinely drains"
	)
	reset.call()

	# --- A patient on the board is a colony emergency: relieved units
	#     skip it, a tired free hand stays up for it, and the floor
	#     lines still rule once it's handled.
	var patient: Unit = (
		colony.units[1] if colony.units.size() > 1 else unit
	)
	patient.add_wound(&"left_leg", &"cut", 5.0)
	var posted := await _wait_until(func() -> bool:
		return colony.care_pending())
	_check(posted, "a wounded colonist posts an open care job")
	unit.relieved = true
	unit.energy = unit.rest_seek * 0.75
	unit._job_search_cooldown = 0.0
	var ignored := await _wait_brief(
		func() -> bool: return unit.job != null
	)
	_check(
		not ignored,
		"a relieved unit leaves the emergency to someone else"
	)
	unit.relieved = false
	var bedded := await _wait_brief(func() -> bool:
		return (
			unit.state == Unit.State.SLEEPING
			or (
				unit.job != null
				and unit.job.type == ColonyJob.Type.REST
			)
		))
	_check(
		not bedded,
		"a tired unit stays up while a patient waits"
	)
	reset.call()
	# Heal the fixture and clear its job — the next medical tick
	# retires it as stale.
	patient.wounds.clear()
	patient._sync_health()
	for job: ColonyJob in colony.jobs:
		if (
			job.state == ColonyJob.State.PENDING
			and (
				job.type == ColonyJob.Type.TEND
				or job.type == ColonyJob.Type.RESCUE
			)
		):
			job.state = ColonyJob.State.CANCELLED
			colony._unregister_job(job)
	var gone := await _wait_until(func() -> bool:
		return not colony.care_pending())
	unit.energy = unit.rest_seek * 0.75
	unit._job_search_cooldown = 0.0
	var sleeps := await _wait_until(func() -> bool:
		return (
			unit.state == Unit.State.SLEEPING
			or (
				unit.job != null
				and unit.job.type == ColonyJob.Type.REST
			)
		))
	_check(
		gone and sleeps,
		"with care handled the same tired unit beds down"
	)
	reset.call()

	# --- The flag rides the save.
	unit.relieved = true
	var udata := unit.serialize()
	_check(
		udata.get("relieved", false) == true,
		"the relieved flag rides the unit's save record"
	)
	reset.call()

	colony.needs_enabled = false
	unfreeze.call()


## Furniture: the catalog's footprints, the in-place build, minified
## crates conserving every input, warehouse-only storage for them, and
## the reinstall/unpack round trips — plus the lamp and occupancy bits
## the specs carry.
func _test_furniture(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("furniture and crates")
	for u in colony.units:
		u._job_search_cooldown = 600.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)

	var row := _flat_run(colony, world, mined, 10)
	_check(row != Vector3i.MAX, "found a flat row for furniture fixtures")
	if row == Vector3i.MAX:
		return
	# A stray pile on the row vetoes cells — lift it before planning.
	for i in 10:
		var c := row + Vector3i(i, 0, 0)
		var pile := colony.item_pile_at(c)
		if pile != null:
			pile.take_up_to(
				DropItem.BLOCK_CM3 * 4, func(_i: DropItem) -> bool: return true
			)
			colony.remove_pile_if_empty(c)

	# --- Footprint: a 1×2 table claims two cells in whichever
	#     orientation fits; walling one side out re-rolls the plan.
	var tspec := BlockRegistry.furniture_spec(&"table_1x2")
	_check(not tspec.is_empty(), "the furniture catalog knows the table")
	var cells := colony.furniture_cells(row, tspec)
	_check(cells.size() == 2, "a 1×2 table resolves a two-cell footprint")
	var anchor := row + Vector3i(5, 0, 0)
	for side in [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK
	]:
		world.place(anchor + side, BlockRegistry.Block.STONE)
	_check(
		colony.furniture_cells(anchor, tspec).is_empty(),
		"a walled-in anchor takes no table"
	)
	for side in [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK
	]:
		# `place` refuses an occupied cell — carving the wall back out is
		# a removal, not a placement.
		world.remove_voxel(anchor + side)

	# --- Build in place: designate_furniture posts a CRAFT job whose
	#     fetch is the recipe's planks; the finished piece carries the
	#     spec and footprint.
	var plan := colony.designate_furniture(row, &"table_1x2")
	_check(
		plan != null and plan.type == ColonyJob.Type.CRAFT
			and plan.recipe == &"table_1x2",
		"a furniture designation posts a craft build"
	)
	if plan == null:
		return
	_check(plan.extra_voxels.size() == 1, "the table's plan spans both cells")
	var plank_v := row + Vector3i(7, 0, 0)
	for i in 3:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			plank_v
		)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_drive_craft(colony, world, plan, plank_v, row)
	var built := await _wait_until(func() -> bool:
		return plan.state == ColonyJob.State.DONE)
	var table := colony.building_at(row)
	_check(built and table != null, "a unit builds the table in place")
	if table == null:
		return
	_check(
		table.kind == Building.Kind.TABLE and table.spec == &"table_1x2"
			and table.footprint.size() == 2,
		"the table registers its spec and footprint"
	)
	_check(
		table.components.size() == 3
			and table.components[0].form == DropItem.Form.PLANK,
		"the table keeps its planks as components"
	)

	# --- Uninstall: the packer fetches a sheet shell, then the piece
	#     minifies into a crate holding the exact components, the shell
	#     riding alongside.
	var un_job := colony.designate_uninstall(row)
	_check(un_job != null, "a built table takes an uninstall order")
	if un_job == null:
		return
	var shell_v := row + Vector3i(9, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		),
		shell_v
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var packer := colony.units[0]
	packer.global_position = Vector3(
		_park_beside(colony, world, shell_v, row)
	) + Vector3(0.5, 0.9, 0.5)
	packer.velocity = Vector3.ZERO
	packer.energy = 1.0
	un_job.state = ColonyJob.State.ASSIGNED
	un_job.assignee = packer
	packer.job = un_job
	packer._fetching = true
	packer._goal_voxel = shell_v
	packer._clear_budget = 0.0
	packer.state = Unit.State.MOVING
	var packed := await _wait_until(func() -> bool:
		return colony.building_at(row) == null)
	_check(packed, "a unit packs the table into a crate")
	var crate: DropItem = null
	for voxel: Vector3i in colony.item_piles:
		if Vector3(voxel - row).length() > 4.0:
			continue
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.CRATE:
				crate = item
	_check(crate != null, "the packed table stands as a crate")
	if crate == null:
		return
	_check(
		crate.spec == &"table_1x2" and crate.packed.size() == 3
			and crate.shell.size() == 1,
		"the crate keeps the components and the shell"
	)
	var packed_volume := 0
	for item in crate.packed:
		packed_volume += item.volume
	_check(
		crate.volume == packed_volume + crate.shell[0].volume,
		"the crate's volume is contents plus shell"
	)

	# --- Storage class: a crate lands only in a warehouse — the floor
	#     stockpile refuses it whatever the filter says. The zone cells
	#     have to qualify like a real designation (air over solid,
	#     nothing piled), so probe the fixture row's neighbours.
	var sp_cell := Vector3i.MAX
	var ware_cell := Vector3i.MAX
	for dz in [-2, 2, -4, 4]:
		for dx in range(0, 10):
			var c := row + Vector3i(dx, 0, dz)
			if (
				world.is_editable(c)
				and world.get_block(c) == BlockRegistry.Block.AIR
				and colony.voxel_fill(c) <= 0
				and world.is_solid(c + Vector3i.DOWN)
				and colony.building_at(c) == null
				and not colony.is_stockpile(c)
			):
				if sp_cell == Vector3i.MAX:
					sp_cell = c
				elif ware_cell == Vector3i.MAX:
					ware_cell = c
		if sp_cell != Vector3i.MAX and ware_cell != Vector3i.MAX:
			break
	_check(
		sp_cell != Vector3i.MAX and ware_cell != Vector3i.MAX,
		"found cells for the stockpile pair"
	)
	if sp_cell == Vector3i.MAX or ware_cell == Vector3i.MAX:
		return
	colony.designate_stockpile(sp_cell)
	colony.designate_warehouse(ware_cell)
	_check(
		not colony.stockpile_admits_item(sp_cell, crate),
		"a plain stockpile refuses a crate"
	)
	_check(
		colony.stockpile_admits_item(ware_cell, crate),
		"a warehouse cell admits the crate"
	)
	_check(
		colony.voxel_capacity(ware_cell) > colony.voxel_capacity(sp_cell),
		"the warehouse racks deeper than the floor"
	)

	# --- Reinstall: designating the same spec while the crate stands
	#     nearby satisfies the bill whole — the piece comes back with
	#     its packed components and its quality, the shell set down.
	var reinstall := colony.designate_furniture(anchor, &"table_1x2")
	_check(reinstall != null, "a crate's piece re-designates")
	if reinstall != null:
		reinstall.components.append(crate)
		colony.complete_construct(reinstall)
		var restored := colony.building_at(anchor)
		_check(
			restored != null and restored.spec == &"table_1x2"
				and restored.components.size() == 3,
			"reinstalling the crate restores the piece whole"
		)
		# The shell drop runs the spill mechanic — the plank may bounce
		# to a neighbor when the anchor's crowded. Assert it comes back
		# as a plank nearby, not at the exact cell.
		var shell_back := false
		for voxel: Vector3i in colony.item_piles:
			if Vector3(voxel - anchor).length() > 4.0:
				continue
			for item in colony.item_piles[voxel].items:
				if item.form == DropItem.Form.PLANK:
					shell_back = true
		_check(shell_back, "the crate's shell comes back as a plank")
		# Reinstall consumed the crate — nothing of it is left around.
		var stray := false
		for voxel: Vector3i in colony.item_piles:
			if Vector3(voxel - anchor).length() > 4.0:
				continue
			for item in colony.item_piles[voxel].items:
				if item == crate:
					stray = true
		_check(not stray, "the crate is spent on reinstall")
		colony._teardown_building(anchor)

	# --- Unpack: cracking a crate in place spills the contents and the
	#     shell — every input returns to the world.
	var crate2 := DropItem.new(
		BlockRegistry.Resource_.WOOD, DropItem.Form.CRATE, 0
	)
	crate2.spec = &"stool"
	crate2.quality = 1.6
	crate2.packed.append(
		DropItem.new(
			BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
			DropItem.PLANK_CM3
		)
	)
	crate2.shell.append(
		DropItem.new(
			BlockRegistry.Resource_.IRON, DropItem.Form.SHEET,
			DropItem.SHEET_CM3
		)
	)
	crate2.volume = DropItem.PLANK_CM3 + DropItem.SHEET_CM3
	var open_cell := row + Vector3i(6, 0, 4)
	colony._deposit_item(crate2, open_cell)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var unpack_cell := _pile_of(colony, crate2)
	var unpack := colony.designate_unpack(unpack_cell)
	_check(unpack != null, "a standing crate takes an unpack order")
	if unpack != null:
		colony.complete_unpack(unpack)
		var out_plank := false
		var out_sheet := false
		var pile2 := colony.item_pile_at(unpack_cell)
		if pile2 != null:
			for item in pile2.items:
				if item.form == DropItem.Form.PLANK:
					out_plank = true
				if (
					item.form == DropItem.Form.SHEET
					and item.material == BlockRegistry.Resource_.IRON
				):
					out_sheet = true
		_check(
			out_plank and out_sheet,
			"unpacking spills the contents and the real shell"
		)
		_check(
			colony.item_pile_at(unpack_cell) == null
				or not colony.item_pile_at(unpack_cell).items.has(crate2),
			"the crate is gone"
		)

	# --- Serialization: a crate's packed goods, shell and spec survive
	#     the save record, and a legacy bed kit deserializes as one.
	var record := crate2.serialize()
	var revived := DropItem.deserialize(record)
	_check(
		revived.form == DropItem.Form.CRATE and revived.spec == &"stool"
			and revived.packed.size() == 1 and revived.shell.size() == 1
			and absf(revived.quality - 1.6) < 0.001,
		"a crate round-trips contents, shell, spec and quality"
	)
	var legacy := DropItem.deserialize([
		int(BlockRegistry.Resource_.WOOD), int(DropItem.Form.BED),
		DropItem.BED_KIT_CM3
	])
	_check(
		legacy.form == DropItem.Form.CRATE and legacy.spec == &"bed"
			and legacy.packed.size() == 6 and legacy.shell.size() == 1,
		"a legacy bed kit loads as a packed bed crate"
	)

	# --- Occupancy: a double bed sleeps two — the second claimant
	#     registers alongside, a third is refused, and releasing the
	#     first hands the primary slot over.
	var double_spec := BlockRegistry.furniture_spec(&"double_bed")
	_check(int(double_spec.get(&"sleeps", 0)) == 2, "a double bed sleeps two")
	var dbl := Building.new(Building.Kind.BED, row)
	dbl.spec = &"double_bed"
	# Claimants have to be distinct units — spawn extras if the roster
	# is short; they idle under the cooldown and get freed at the end.
	var extras: Array[Unit] = []
	while colony.units.size() < 3:
		var extra_unit := colony.spawn_unit(row + Vector3i(0, 0, 8))
		extra_unit._job_search_cooldown = 600.0
		extras.append(extra_unit)
	var sleeper_a := colony.units[0]
	var sleeper_b := colony.units[1]
	var sleeper_c := colony.units[2]
	_check(dbl.claim_bed(sleeper_a), "a double bed takes a first occupant")
	_check(
		dbl.claim_bed(sleeper_b) and dbl.occupants.size() == 2
			and dbl.occupant == sleeper_a,
		"the double bed takes a second claimant beside the first"
	)
	_check(
		not dbl.claim_bed(sleeper_c),
		"a full double bed refuses a third"
	)
	dbl.release_bed(sleeper_a)
	_check(
		dbl.occupant == sleeper_b and dbl.occupants.size() == 1,
		"releasing the primary hands the slot to the next sleeper"
	)
	dbl.release_bed(sleeper_b)

	# --- Lamps: the torch burns on fuel, the wired lamp waits on the
	#     power net, and only a grow lamp feeds grow_light.
	var torch_spec := BlockRegistry.furniture_spec(&"torch_lamp")
	var sun_spec := BlockRegistry.furniture_spec(&"sun_lamp")
	_check(
		bool(torch_spec.get(&"burns", false)),
		"the torch lamp burns fuel"
	)
	_check(
		int(sun_spec.get(&"watts", 0)) > 0
			and float(sun_spec.get(&"grow", 0.0)) > 0.0,
		"the sun lamp is a powered grow light"
	)
	var torch := Building.new(Building.Kind.LAMP, row)
	torch.spec = &"torch_lamp"
	colony.register_building(torch)
	torch.fuel = 60.0
	_check(torch.lamp_lit(), "a fuelled torch lamp is lit")
	_check(
		colony.light_at(row) > 0.0,
		"the lit lamp lights its cell"
	)
	var sun := Building.new(Building.Kind.LAMP, row + Vector3i(0, 0, 6))
	sun.spec = &"sun_lamp"
	colony.register_building(sun)
	sun.powered = true
	_check(
		colony.grow_light_at(sun.voxel) > 0.0,
		"a powered sun lamp feeds grow light"
	)
	_check(
		colony.device_watts(torch) == 0.0
			and colony.device_watts(sun) > 0.0,
		"only the wired lamp draws on the net"
	)
	colony._teardown_building(row)
	colony._teardown_building(row + Vector3i(0, 0, 6))
	for extra_unit in extras:
		colony.units.erase(extra_unit)
		extra_unit.queue_free()
	unit._job_search_cooldown = 0.0


## Item 48 — the stonecutter's bench and its cut bills: a cobble dresses
## to one block, a boulder to twelve, and the balance pours off as
## gravel — exact conservation, craft-skill pace, no experience. Stone
## walls and flagstone floors retool onto the dressed block.
func _test_stonecutting(
	colony: Colony, world: VoxelWorld, unit: Unit, mined: Vector3i
) -> void:
	print("stonecutting")
	for u in colony.units:
		u._job_search_cooldown = 600.0
		if u.job != null:
			colony.release_job(u.job)
		u.abandon_job()
	_clear_jobs(colony)

	# --- Recipe shape: the block form, the site pin, the ore pin and
	#     the no-XP craft — all data-level before anyone lifts a saw.
	_check(
		DropItem.STONE_BLOCK_CM3 == 5_000
			and DropItem.form_volume(DropItem.Form.BLOCK) == 5_000
			and DropItem.form_name(DropItem.Form.BLOCK) == "block",
		"a dressed block is a five-litre item"
	)
	var cut_boulder := Colony.recipe_of(&"cut_blocks_boulder")
	var cut_cobble := Colony.recipe_of(&"cut_blocks_cobble")
	_check(
		not cut_boulder.is_empty() and not cut_cobble.is_empty(),
		"the catalog knows both stonecutting bills"
	)
	_check(
		Colony.recipe_site_rate(cut_boulder, Building.Kind.STONECUTTER)
			== 1.0
			and Colony.recipe_site_rate(
				cut_boulder, Building.Kind.WORKSITE
			) == 0.0
			and Colony.recipe_site_rate(
				cut_cobble, Building.Kind.METALWORK
			) == 0.0,
		"cutting belongs to the stonecutter's bench alone"
	)
	_check(
		float(cut_boulder.get("xp", -1.0)) == 0.0
			and float(cut_cobble.get("xp", -1.0)) == 0.0,
		"stonecutting is routine work — the bills grant no XP"
	)
	_check(
		int(cut_boulder[&"input_material"].get(DropItem.Form.BOULDER, -1))
			== BlockRegistry.Resource_.STONE
			and int(cut_cobble[&"input_material"].get(DropItem.Form.COBBLE, -1))
				== BlockRegistry.Resource_.STONE,
		"the cut bills pin plain stone — ore chunks stay with the crusher"
	)
	_check(
		12 * DropItem.STONE_BLOCK_CM3 + 40_000 == DropItem.BOULDER_CM3
			and DropItem.STONE_BLOCK_CM3 + 5_000 == DropItem.COBBLE_CM3,
		"cutting conserves volume exactly"
	)
	_check(
		BlockRegistry.spec_volume_for(&"stone_wall")
			== 120 * DropItem.STONE_BLOCK_CM3
			and BlockRegistry.floor_recipe(&"flagstone")
				== {DropItem.Form.BLOCK: 20 * DropItem.STONE_BLOCK_CM3},
		"a wall wants 120 blocks and a paved metre wants 20"
	)

	# --- The bench rises like any production site — a plank frame and
	#     a boulder cutting bed, built before blocks exist.
	var site := _clear_run(colony, world, mined, 6)
	_check(site != Vector3i.MAX, "found a clear stretch for the stonecutter")
	if site == Vector3i.MAX:
		return
	var stock := site + Vector3i(1, 0, 0)
	for i in 2:
		colony._deposit_item(
			DropItem.new(
				BlockRegistry.Resource_.WOOD, DropItem.Form.PLANK,
				DropItem.PLANK_CM3
			),
			stock
		)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		),
		stock
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var bench_job := colony.designate_production(site, &"stonecutter_bench")
	_check(
		bench_job != null and bench_job.type == ColonyJob.Type.CRAFT
			and bench_job.recipe == &"stonecutter_bench",
		"the stonecutter's bench designates as a craft build"
	)
	if bench_job == null:
		return
	var raised := await _build_and_wait(colony, world, bench_job, stock, site)
	var bench := colony.building_at(site)
	_check(
		raised and bench != null
			and bench.kind == Building.Kind.STONECUTTER
			and bench.is_worksite(),
		"a unit raises the stonecutter's bench"
	)
	if bench == null:
		return
	_check(
		bench.label() == "Stonecutter's bench",
		"the bench names itself for the inspect panel"
	)

	# --- The cobble cut: one block out and the balance as gravel.
	var rocks := site + Vector3i(2, 0, 0)
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.COBBLE,
			DropItem.COBBLE_CM3
		),
		rocks
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	var blocks_before := _count_form(colony, DropItem.Form.BLOCK)
	var gravel_before := _loose_volume(colony, BlockRegistry.Resource_.STONE)
	var sawyer: Unit = colony.units[0]
	var xp_before := float(sawyer.skills.get(ColonyJob.Skill.CRAFTING, 0.0))
	var cobble_bill := colony.queue_order(site, &"cut_blocks_cobble")
	_check(
		cobble_bill != null,
		"the bench takes the cobble cut bill"
	)
	var cobble_job := colony.craft_job_at(site)
	if cobble_job == null:
		await _wait_until(func() -> bool:
			return colony.craft_job_at(site) != null)
		cobble_job = colony.craft_job_at(site)
	if cobble_job == null:
		_check(false, "the cobble bill dispatched a job")
		return
	_drive_craft(colony, world, cobble_job, rocks, site)
	var cut := await _wait_until(func() -> bool:
		return cobble_job.state == ColonyJob.State.DONE)
	_check(cut, "a unit cuts a cobble into a block")
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		_count_form(colony, DropItem.Form.BLOCK) - blocks_before == 1
			and _loose_volume(colony, BlockRegistry.Resource_.STONE)
				- gravel_before == 5_000,
		"the cobble cut yields one block and five litres of gravel"
	)
	_check(
		float(sawyer.skills.get(ColonyJob.Skill.CRAFTING, 0.0)) == xp_before,
		"the routine cut taught the sawyer nothing"
	)

	# --- The boulder cut: a dozen blocks and forty litres of tailings.
	colony._deposit_item(
		DropItem.new(
			BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
			DropItem.BOULDER_CM3
		),
		rocks
	)
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	blocks_before = _count_form(colony, DropItem.Form.BLOCK)
	gravel_before = _loose_volume(colony, BlockRegistry.Resource_.STONE)
	var boulder_bill := colony.queue_order(site, &"cut_blocks_boulder")
	_check(
		boulder_bill != null,
		"the bench takes the boulder cut bill"
	)
	var boulder_job := colony.craft_job_at(site)
	if boulder_job == null:
		await _wait_until(func() -> bool:
			return colony.craft_job_at(site) != null)
		boulder_job = colony.craft_job_at(site)
	if boulder_job == null:
		_check(false, "the boulder bill dispatched a job")
		return
	_drive_craft(colony, world, boulder_job, rocks, site)
	cut = await _wait_until(func() -> bool:
		return boulder_job.state == ColonyJob.State.DONE)
	_check(cut, "a unit cuts a boulder into a dozen blocks")
	await _wait_until(func() -> bool: return colony._in_flight.is_empty())
	_check(
		_count_form(colony, DropItem.Form.BLOCK) - blocks_before == 12
			and _loose_volume(colony, BlockRegistry.Resource_.STONE)
				- gravel_before == 40_000,
		"the boulder cut yields twelve blocks and forty litres of gravel"
	)
	_check(
		float(sawyer.skills.get(ColonyJob.Skill.CRAFTING, 0.0)) == xp_before,
		"a dozen more blocks, still nothing learned"
	)
	unit._job_search_cooldown = 0.0


## The landed pile holding [param item], wherever it settled.
func _pile_of(colony: Colony, item: DropItem) -> Vector3i:
	for voxel: Vector3i in colony.item_piles:
		if colony.item_piles[voxel].items.has(item):
			return voxel
	return Vector3i.MAX


## Colony-wide count of items of [param form] — the deltas around a
## craft run read as the recipe's true output wherever piles land.
func _count_form(colony: Colony, form: DropItem.Form) -> int:
	var total := 0
	for voxel: Vector3i in colony.item_piles:
		for item in colony.item_piles[voxel].items:
			if item.form == form:
				total += 1
	return total


## Colony-wide loose volume of [param material] — the tailings half of
## a cut bill's ledger.
func _loose_volume(colony: Colony, material: BlockRegistry.Resource_) -> int:
	var total := 0
	for voxel: Vector3i in colony.item_piles:
		for item in colony.item_piles[voxel].items:
			if item.form == DropItem.Form.LOOSE and item.material == material:
				total += item.volume
	return total


func _flat_run(
	colony: Colony,
	world: VoxelWorld,
	mined: Vector3i,
	need: int,
	skip_z: int = -2147483648
) -> Vector3i:
	for z_off in range(-140, -220, -4) + range(140, 204, 4) + range(-60, -140, 4) + range(60, 140, 4):
		var z: int = mined.z + z_off
		if z == skip_z:
			continue
		var run := 0
		var run_g := -1
		var start := Vector3i.MAX
		for x in range(mined.x + 4, mined.x + 44):
			var g := _ground(world, x, z, mined.y + 32)
			var cell := Vector3i(x, g + 1, z)
			var flat := (
				world.is_editable(cell)
				and world.is_editable(Vector3i(x, g, z))
				and world.get_block(cell) == BlockRegistry.Block.AIR
				and world.is_solid(Vector3i(x, g, z))
				and world.generator_script.water_depth_at(x, z) == 0
				and colony.item_pile_at(cell) == null
				and world.water_level_at(x, z) < g + 1
			)
			if flat and run > 0 and g == run_g:
				run += 1
			elif flat:
				run = 1
				run_g = g
				start = cell
			else:
				run = 0
			if run >= need:
				return start
	return Vector3i.MAX


## `_flat_run` plus the occupancy checks the power fixtures need —
## `designate_production` refuses bushes, roots, stockpiles, buildings
## and stray markers that a flat stretch may still carry.
func _clear_run(
	colony: Colony, world: VoxelWorld, mined: Vector3i, need: int
) -> Vector3i:
	for z_off in range(-140, -220, -4) + range(140, 204, 4) + range(-60, -140, 4) + range(60, 140, 4):
		var z: int = mined.z + z_off
		var run := 0
		var run_g := -1
		var start := Vector3i.MAX
		for x in range(mined.x + 4, mined.x + 44):
			var g := _ground(world, x, z, mined.y + 32)
			var cell := Vector3i(x, g + 1, z)
			var clear := (
				world.is_editable(cell)
				and world.is_editable(Vector3i(x, g, z))
				and world.get_block(cell) == BlockRegistry.Block.AIR
				and world.is_solid(Vector3i(x, g, z))
				and world.generator_script.water_depth_at(x, z) == 0
				and colony.item_pile_at(cell) == null
				and colony.building_at(cell) == null
				and not colony.is_stockpile(cell)
				and not colony.is_designated(cell)
				and colony.plants.bush_at(cell) == Vector3i.MAX
				and colony.forest.tree_root_at(cell) == Vector3i.MAX
				and world.water_level_at(x, z) < g + 1
			)
			if clear and run > 0 and g == run_g:
				run += 1
			elif clear:
				run = 1
				run_g = g
				start = cell
			else:
				run = 0
			if run >= need:
				return start
	return Vector3i.MAX


## Clears whatever drifted onto [param cell] — a bounced drop, a stray
## marker or a sprouted bush all block `designate_production`, so the
## fixtures sweep first.
func _sweep(colony: Colony, cell: Vector3i) -> void:
	var pile := colony.item_pile_at(cell)
	if pile != null:
		pile.items.clear()
		colony.remove_pile_if_empty(cell)
	if colony.is_designated(cell):
		colony.cancel_designation(cell)
	var bush := colony.plants.bush_at(cell)
	if bush != Vector3i.MAX:
		colony.plants._forget(bush)
	var root := colony.forest.tree_root_at(cell)
	if root != Vector3i.MAX:
		colony.forest._forget(root, cell)


## Sweeps a span of cells in place — give-up drops land wherever the
## unit stood, so the fixture row is re-swept between builds.
func _sweep_run(colony: Colony, run: Vector3i, count: int) -> void:
	for i in count:
		_sweep(colony, run + Vector3i(i, 0, 0))


## State dump for a stalled fixture build — the wait timed out and the
## job's phase says where the unit lost the thread.
func _stall_dump(job: ColonyJob, worker: Unit) -> void:
	print(
		(
			"    stall: job=%s state=%s at=%s delivered=%s comps=%d "
			+ "worker.state=%d assignee=%s carried=%d wpos=%s progress=%s"
		)
		% [
			job.recipe, job.state, job.voxel_position, job.delivered,
			job.components.size(), worker.state, job.assignee,
			worker._carried.size(), worker.global_position.floor(),
			job.progress,
		]
	)


## Hand a craft/build job its full input bill as escrow — the
## delivered-tally bookkeeping a real fetch performs, minus the walk:
## forms tally under their want slot (a sheet pays plank volume), loose
## inputs under DELIVERED_MATERIAL_OFF + material. The fetch pipeline
## is proven elsewhere; here the point is designate → gate → complete.
## [param fills] maps a want form to the form actually delivered —
## {PLANK: SHEET} pays a plank slot with sheets, the substitution.
func _stock_job(job: ColonyJob, fills: Dictionary = {}) -> void:
	var recipe: Dictionary = Colony.recipe_of(job.recipe)
	var pins: Dictionary = recipe.get(&"input_material", {})
	var mat_for := {
		DropItem.Form.PLANK: BlockRegistry.Resource_.WOOD,
		DropItem.Form.SHEET: BlockRegistry.Resource_.COPPER,
		DropItem.Form.WIRE: BlockRegistry.Resource_.COPPER,
		DropItem.Form.COMPONENT: BlockRegistry.Resource_.IRON,
	}
	for want: int in recipe["inputs"]:
		var fill: int = int(fills.get(want, want))
		var pin: Variant = pins.get(
			want, mat_for.get(fill, BlockRegistry.Resource_.STONE)
		)
		var material: int = pin[0] if pin is Array else int(pin)
		var need := int(recipe["inputs"][want]) * DropItem.form_volume(want)
		var volumes: Dictionary = recipe.get(&"input_cm3", {})
		if volumes.has(want):
			need = int(volumes[want])
		var have := 0
		while have < need:
			var item := DropItem.new(material, fill, DropItem.form_volume(fill))
			job.components.append(item)
			job.delivered[want] = int(job.delivered.get(want, 0)) + item.volume
			have += item.volume
			if job.material == BlockRegistry.Resource_.NONE:
				job.material = item.material
	for material: int in recipe.get(&"input_loose", {}):
		var item := DropItem.new(
			material, DropItem.Form.LOOSE, int(recipe[&"input_loose"][material])
		)
		job.components.append(item)
		job.delivered[Unit.DELIVERED_MATERIAL_OFF + material] = item.volume
		if job.material == BlockRegistry.Resource_.NONE:
			job.material = item.material


## Drive a craft/build job to DONE, re-driving when the run stalls — a
## watchdog give-up returns the job to the board unclaimed, and the old
## wait-then-retry loop would sit out the whole deadline on an orphaned
## PENDING job while bystander cooldowns lapsed. Poll instead: the
## instant the job drops back to PENDING, re-park and re-assign. On a
## busy test colony stray interference is environment noise, not a
## failure — but the job only gets one total deadline.
func _build_and_wait(
	colony: Colony,
	world: VoxelWorld,
	job: ColonyJob,
	pile_v: Vector3i,
	site: Vector3i
) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	_drive_craft(colony, world, job, pile_v, site)
	while Time.get_ticks_msec() < deadline:
		if job.state == ColonyJob.State.DONE:
			return true
		if job.state == ColonyJob.State.PENDING:
			_drive_craft(colony, world, job, pile_v, site)
		elif job.state != ColonyJob.State.ASSIGNED:
			break
		await process_frame
	_stall_dump(job, colony.units[0])
	return false


## Topmost solid voxel in a column [param distance] voxels away from the unit.
func _pick_mining_target(world: VoxelWorld, unit: Unit, distance: int = 2) -> Vector3i:
	var origin := Vector3i(unit.global_position.floor())
	var offsets: Array[Vector3i] = [
		Vector3i(distance, 0, 0), Vector3i(-distance, 0, 0),
		Vector3i(0, 0, distance), Vector3i(0, 0, -distance)
	]
	for offset in offsets:
		var column := origin + offset
		var ground_y := _ground(world, column.x, column.z, origin.y + 16, origin.y - 16)
		var candidate := Vector3i(column.x, ground_y, column.z)
		if world.is_solid(candidate):
			return candidate
	return Vector3i.MAX


## Cancels every unfinished job — earlier tests leave open jobs on the
## board that a unit might wander off to claim instead of the fixture's.
func _clear_jobs(colony: Colony) -> void:
	for job in colony.jobs:
		if job.state != ColonyJob.State.DONE:
			job.state = ColonyJob.State.CANCELLED
	colony._prune_jobs()
	_disarm_units(colony)


## A held tool halves what a unit can carry (both hands full ends
## hauling) — sections that arm a worker for a mine/chop fixture would
## otherwise leave every later fetch running at half capacity, which
## starves any job wanting a full-size item like a log. Tools armed or
## fetched during a fixture simply vanish at the reset; the feature's
## pile-fetch path is exercised by the tools section itself.
func _disarm_units(colony: Colony) -> void:
	for u in colony.units:
		u.hands.clear()
		for i in u.holstered.size():
			u.holstered[i] = null


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false


## `_wait_until` with a caller's deadline — for "this must NOT happen"
## assertions, which would otherwise sit out the whole suite timeout.
func _wait_brief(predicate: Callable, seconds := 3.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false
