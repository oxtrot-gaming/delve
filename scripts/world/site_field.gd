class_name SiteField
extends RefCounted

## The site's soil + water field — one raster pass at site install
## (DESIGN: Soils and hydrology).
##
## A FIELD_M-square window centred on the site anchor samples the real
## generator surface (regional heightfield + local noise), then runs a
## deliberately small hydrology model over it:
##
##   depression fill  → where rain that beats absorption pools
##   flow accumulation → where the overflow runs off
##   thresholds       → lake cells (standing fill), river cells
##                      (carved channels), wetland cells (saturated
##                      margins → peat country)
##
## Everything lands in packed integer rasters in voxel-y units, so the
## generators can install them like the regional grid and stay
## voxel-identical: DelveGenerator samples the same arrays with the
## same math. `basins` and `flow_next` are the runtime hooks — a
## regional weather event bumps a basin's `level`, and a player cut or
## dam re-spills through `flow_next`; neither ever rewrites the globe
## or the voxel grid's baseline.
##
## Soil rides the same pass: each cell carries a spec index resolved
## from the per-cell biome (classified off meso temperature and
## precipitation) with the wetland/shore/bed overrides applied, plus a
## climate-scaled depth. The generators do the fine-grained work —
## patch-noise picks inside the spec's weight table, slope thinning —
## per column, deterministically.

const FIELD_M := 4 ## metres per field cell — channels are 1–2 cells wide
const FIELD_SIDE := 384 ## 1536 m of playfield around the anchor
const EXTENT := FIELD_SIDE * FIELD_M

## water[i] == DRY → no surface water over the cell.
const DRY := -30000

const FLAG_WATER := 1 ## open water — water[i] is a valid surface level
const FLAG_RIVER := 2 ## a carved channel, not standing water
const FLAG_WET := 4 ## saturated ground, no open water — peat spec
const FLAG_SHORE := 8 ## water-adjacent dry ground — sandy spec

## Standing fill of this or more counts as open water; shallower dips
## read as saturated ground (wetland) instead of one-metre ponds
## scattered over every noise hollow.
const OPEN_WATER_DEPTH := 2
## A dip only ponds when it actually collects — catchment below this
## (≈ this many × 16 m² of drainage) infiltrates instead, leaving
## saturated ground rather than open water.
const LAKE_MIN_ACCUM := 150
## Fill below this counts as wetland ground, not a lake.
const WET_FILL_MIN := 1
## River channel cut (voxels): bed drops this far below grade.
const RIVER_CUT := 3
## Water surface sits this far below grade in a river cell — a 2 m
## channel of water in a 3 m trough.
const RIVER_WATER_DROP := 1
## Catchment-to-river numerator: cells needed upstream ≈
## RIVER_K / annual precipitation (cm). Wet maps run streams off tiny
## catchments, dry ones need a big basin.
const RIVER_K := 40000.0
const RIVER_MIN_CELLS := 120
const RIVER_MAX_CELLS := 4000
## Cells with a quarter or more of the river catchment but short of it
## drain visibly — a soggy swale, wetland ground without open water.
const SWALE_FRACTION := 4
## Open water under this many cells is raster noise — a puddle rendered
## as a sheer column — so it demotes to saturated ground instead.
const MIN_LAKE_CELLS := 4
## Annual water loss over open water — evaporation plus bed seepage —
## in metres. A basin holds a lake only when its catchment inflow
## (upstream cells × precipitation) covers its own area × this, so the
## same terrain lakes up under wet climates and stays dry under arid
## ones. A budget, not a flag — climate or level changes move the
## shoreline without re-deriving terrain.
const LAKE_LOSS_M := 1.2

var origin := Vector2i.ZERO ## voxel xz of cell (0,0)'s min corner
var side := FIELD_SIDE
var cell_m := FIELD_M

## Carve drop per cell (voxels below local terrain) — bilinear-blended
## by the generator, so dry cells must carry 0 (identity) and banks
## slope out of a channel over a cell's width.
var carve := PackedByteArray()
var water := PackedInt32Array() ## water surface level per cell, or DRY
var flags := PackedByteArray()
var soil := PackedByteArray() ## index into specs
## Soil depth in quarter-metres — spec base × climate × slope, fully
## resolved here so the generator only reads it.
var depth_q := PackedByteArray()
var specs: Array = [] ## resolved soil spec dictionaries
var flow_next := PackedInt32Array() ## downstream cell, -1 drains off-map
var accum := PackedInt32Array() ## contributing cells incl. self
## Spill level per cell — the flood fill's resolved surface. Water can
## never sit above it; kept so a player dam can re-fill to a new pour
## and a cut can lower one without re-deriving terrain.
var spill := PackedInt32Array()
var basins: Array = [] ## {cells, level, outlet} — the mutable records


static func generate(
	meso: MesoMap, gen: WorldGenerator, anchor: Vector2i, pump := false
) -> SiteField:
	var f := SiteField.new()
	f.origin = anchor - Vector2i(EXTENT / 2, EXTENT / 2)
	var n := FIELD_SIDE * FIELD_SIDE
	var h := PackedInt32Array()
	h.resize(n)
	for cz in FIELD_SIDE:
		var vz := f.origin.y + cz * FIELD_M + FIELD_M / 2
		for cx in FIELD_SIDE:
			var vx := f.origin.x + cx * FIELD_M + FIELD_M / 2
			h[cz * FIELD_SIDE + cx] = gen.raw_height(vx, vz)
		if pump and cz % 32 == 31:
			await _pump_frame()

	var filled := PackedInt32Array()
	filled.resize(n)
	f.flow_next = PackedInt32Array()
	f.flow_next.resize(n)
	f.flow_next.fill(-1)
	var order := _flood_fill(h, filled, f.flow_next)
	f.spill = filled
	if pump:
		await _pump_frame()

	f.accum = PackedInt32Array()
	f.accum.resize(n)
	_accumulate(f.flow_next, order, f.accum)

	f.carve = PackedByteArray()
	f.carve.resize(n)
	f.water = PackedInt32Array()
	f.water.resize(n)
	f.water.fill(DRY)
	f.flags = PackedByteArray()
	f.flags.resize(n)
	f.soil = PackedByteArray()
	f.soil.resize(n)
	f.depth_q = PackedByteArray()
	f.depth_q.resize(n)

	# Spec table — resolve each distinct spec once; cells index it.
	var spec_index := {}
	var claim := func(spec: Dictionary) -> int:
		var key := str(spec)
		if not spec_index.has(key):
			spec_index[key] = f.specs.size()
			f.specs.append(spec)
		return spec_index[key]
	var wetland_idx: int = claim.call(_wetland_spec())
	var shore_idx: int = claim.call(_shore_spec())
	var bed_idx: int = claim.call({&"topsoil": {&"sand": 1}, &"subsoil": {}, &"depth_m": 1.0})

	# Per-cell: biome spec, water class, carve.
	var wet_flags := PackedByteArray()
	wet_flags.resize(n)
	for cz in FIELD_SIDE:
		for cx in FIELD_SIDE:
			var i := cz * FIELD_SIDE + cx
			var vx := f.origin.x + cx * FIELD_M + FIELD_M / 2
			var vz := f.origin.y + cz * FIELD_M + FIELD_M / 2
			var temp := meso.temp_at(float(vx - anchor.x), float(vz - anchor.y))
			var precip := meso.precip_at(float(vx - anchor.x), float(vz - anchor.y))
			var spec := DataPackage.biome_soil(
				WorldGlobe.classify(temp, precip, false)
			)
			if spec.is_empty():
				spec = DataPackage.DEFAULT_SOIL
			var depth := float(spec.get(&"depth_m", 3.0))
			var grad := 0.0
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var jx := clampi(cx + d.x, 0, FIELD_SIDE - 1)
				var jz := clampi(cz + d.y, 0, FIELD_SIDE - 1)
				grad = maxf(
					grad, absf(float(h[jz * FIELD_SIDE + jx] - h[i])) / FIELD_M
				)
			var slope_f := clampf(1.0 - 0.9 * grad, 0.2, 1.0)
			f.depth_q[i] = clampi(
				int(round(depth * _climate_f(temp, precip) * slope_f * 4.0)),
				0, 48
			)
			var water_m := filled[i] - h[i]
			if water_m >= OPEN_WATER_DEPTH and f.accum[i] >= LAKE_MIN_ACCUM:
				f.flags[i] |= FLAG_WATER
				f.water[i] = filled[i]
				f.soil[i] = bed_idx
			else:
				f.soil[i] = claim.call(spec)
			var thresh := clampi(
				int(RIVER_K / maxf(precip, 8.0)), RIVER_MIN_CELLS, RIVER_MAX_CELLS
			)
			if f.flags[i] & FLAG_WATER == 0 and f.accum[i] >= thresh:
				f.flags[i] |= FLAG_WATER | FLAG_RIVER
				f.carve[i] = RIVER_CUT
				# The surface caps at the lowest dry neighbour's ground:
				# on a slope the channel lip can sit above the downhill
				# bank, and water higher than dry land renders as a
				# perched wall. Stepped surfaces read as cascades.
				var cap := h[i] - RIVER_WATER_DROP
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						var jx := cx + dx
						var jz := cz + dz
						if (
							jx < 0 or jx >= FIELD_SIDE
							or jz < 0 or jz >= FIELD_SIDE
						):
							continue
						if f.flags[jz * FIELD_SIDE + jx] & FLAG_WATER == 0:
							cap = mini(cap, h[jz * FIELD_SIDE + jx])
				f.water[i] = cap
				f.soil[i] = bed_idx
			elif (
				f.flags[i] & FLAG_WATER == 0
				and (
					f.accum[i] >= thresh / SWALE_FRACTION
					or (
						water_m >= WET_FILL_MIN
						and f.accum[i] >= LAKE_MIN_ACCUM / 3
					)
				)
			):
				wet_flags[i] = 1
		if pump and cz % 32 == 31:
			await _pump_frame()

	# Basin margins: the gates decide whether a basin exists, not how
	# far its waterline reaches. Priority flood fills every neighbour of
	# a held cell to at least its level, so a still-submerged neighbour
	# of lake-level water is basin floor the core gates left dry —
	# flag it out to the real shoreline or the skin walls up against
	# ground sitting under its own datum. Shallow shelves count too:
	# a metre of water over bed is open water, not dry land. River
	# cells (datum below the spill, carved) don't seed growth — their
	# margins stay wetland or dry banks.
	var margin_q: Array[int] = []
	for cz in FIELD_SIDE:
		for cx in FIELD_SIDE:
			var i := cz * FIELD_SIDE + cx
			if f.flags[i] & FLAG_WATER and f.water[i] == filled[i]:
				margin_q.append(i)
	var qi := 0
	while qi < margin_q.size():
		var c := margin_q[qi]
		qi += 1
		var qx := c % FIELD_SIDE
		var qz := c / FIELD_SIDE
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var jx := qx + dx
				var jz := qz + dz
				if jx < 0 or jx >= FIELD_SIDE or jz < 0 or jz >= FIELD_SIDE:
					continue
				var j := jz * FIELD_SIDE + jx
				if f.flags[j] & FLAG_WATER or filled[j] - h[j] < 1:
					continue
				f.flags[j] |= FLAG_WATER
				f.water[j] = filled[j]
				f.soil[j] = bed_idx
				margin_q.append(j)

	# Wetland ring: saturated cells plus ground within a voxel of a
	# neighbour's water level — peat country.
	for cz in FIELD_SIDE:
		for cx in FIELD_SIDE:
			var i := cz * FIELD_SIDE + cx
			if f.flags[i] & FLAG_WATER:
				continue
			var wet := wet_flags[i] != 0
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var j := (cz + dz) * FIELD_SIDE + (cx + dx)
					if (
						dx == 0 and dz == 0
						or cx + dx < 0 or cx + dx >= FIELD_SIDE
						or cz + dz < 0 or cz + dz >= FIELD_SIDE
					):
						continue
					if f.water[j] != DRY and f.water[j] >= h[i]:
						wet = true
			if wet:
				f.flags[i] |= FLAG_WET
				f.soil[i] = wetland_idx

	# Shore ring: dry, not wetland, touching open water → sandy margin.
	for cz in FIELD_SIDE:
		for cx in FIELD_SIDE:
			var i := cz * FIELD_SIDE + cx
			if f.flags[i] & (FLAG_WATER | FLAG_WET):
				continue
			var near_water := false
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var jx := cx + dx
					var jz := cz + dz
					if jx < 0 or jx >= FIELD_SIDE or jz < 0 or jz >= FIELD_SIDE:
						continue
					if f.flags[jz * FIELD_SIDE + jx] & FLAG_WATER:
						near_water = true
			if near_water:
				f.flags[i] |= FLAG_SHORE
				f.soil[i] = shore_idx

	# Taper carved channels at the window rim — a river running off the
	# field fades out over its last cells instead of leaving a wall
	# where the raster ends (the generator clamps lookups at the edge).
	const FADE := 8
	for cz in FIELD_SIDE:
		for cx in FIELD_SIDE:
			var i := cz * FIELD_SIDE + cx
			if f.carve[i] == 0:
				continue
			var d := mini(
				mini(cx, FIELD_SIDE - 1 - cx), mini(cz, FIELD_SIDE - 1 - cz)
			)
			if d >= FADE:
				continue
			var scaled := int(f.carve[i]) * d / FADE
			f.carve[i] = scaled
			if scaled == 0:
				f.water[i] = DRY
				f.flags[i] &= ~FLAG_WATER
		if pump and cz % 32 == 31:
			await _pump_frame()

	# The lake budget threshold: a basin holds open water when
	# accum ÷ area ≥ loss ÷ precipitation. Precip comes off the site
	# centre's meso cell — basin-scale decisions use site climate.
	var precip_m := maxf(meso.precip_at(0.0, 0.0) / 100.0, 0.05)
	_extract_basins(f, h, filled, wetland_idx, LAKE_LOSS_M / precip_m)
	return f


## Yields one frame so a generation running under a loading screen can
## repaint instead of freezing the window (see WorldGlobe._pump_frame).
static func _pump_frame() -> void:
	await (Engine.get_main_loop() as SceneTree).process_frame


## Priority-flood depression fill over the height raster. Border cells
## drain off the window; every interior cell rises to the lowest level
## it can spill at. Parents chain toward the pour cell — that IS the
## downstream direction, so `flow_next` comes out of the same pass.
## Heights are small ints, so a level-bucketed queue replaces a heap.
## Returns the pop order — a parent always pops before its children
## (a child is pushed at ≥ the parent's level, and FIFO breaks the
## equal-level tie), so reversing it is a downhill accumulation order.
static func _flood_fill(
	h: PackedInt32Array, filled: PackedInt32Array, parent: PackedInt32Array
) -> PackedInt32Array:
	var n := FIELD_SIDE * FIELD_SIDE
	var seen := PackedByteArray()
	seen.resize(n)
	var lo := h[0]
	var hi := h[0]
	for v in h:
		lo = mini(lo, v)
		hi = maxi(hi, v)
	# Bucket per level, border cells seeded at their own height.
	var buckets: Array = []
	buckets.resize(hi - lo + 1)
	for i in buckets.size():
		buckets[i] = PackedInt32Array()
	var order := PackedInt32Array()
	for cz in FIELD_SIDE:
		for cx in FIELD_SIDE:
			if cz != 0 and cz != FIELD_SIDE - 1 and cx != 0 and cx != FIELD_SIDE - 1:
				continue
			var i := cz * FIELD_SIDE + cx
			seen[i] = 1
			filled[i] = h[i]
			buckets[h[i] - lo].append(i)
	for level in range(buckets.size()):
		var qi := 0
		while qi < buckets[level].size():
			var c: int = buckets[level][qi]
			qi += 1
			order.append(c)
			var cx := c % FIELD_SIDE
			var cz := c / FIELD_SIDE
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dz == 0:
						continue
					var jx := cx + dx
					var jz := cz + dz
					if jx < 0 or jx >= FIELD_SIDE or jz < 0 or jz >= FIELD_SIDE:
						continue
					var j := jz * FIELD_SIDE + jx
					if seen[j]:
						continue
					seen[j] = 1
					filled[j] = maxi(h[j], filled[c])
					parent[j] = c
					buckets[filled[j] - lo].append(j)
	return order


## Contributing-cell counts downstream along flow_next — reverse pop
## order puts every cell after its contributors.
static func _accumulate(
	flow_next: PackedInt32Array, order: PackedInt32Array, accum: PackedInt32Array
) -> void:
	accum.fill(1)
	for k in range(order.size() - 1, -1, -1):
		var c := order[k]
		var p := flow_next[c]
		if p >= 0:
			accum[p] += accum[c]


## Standing-water cells sharing a level, connected — the basin records
## the runtime mutates (level for floods, spill for player cuts).
## A basin only survives as open water on a budget: catchment inflow
## per unit area must cover [param keep_ratio] (loss ÷ precipitation).
## A carved channel pouring in counts too — the river's own catchment
## joins the inflow, so a creek can keep a spring pool but not a
## mega-lake. Rain-fed pans and raster-noise puddles demote to
## saturated ground — the wetland ring already ran, so demoted cells
## take the wet flag and spec directly.
static func _extract_basins(
	f: SiteField,
	h: PackedInt32Array,
	filled: PackedInt32Array,
	wet_idx: int,
	keep_ratio: float
) -> void:
	var n := FIELD_SIDE * FIELD_SIDE
	var seen := PackedByteArray()
	seen.resize(n)
	for i in n:
		if seen[i] or not f.flags[i] & FLAG_WATER or f.flags[i] & FLAG_RIVER:
			continue
		var cells := PackedInt32Array()
		var queue := [i]
		var max_acc := 0
		seen[i] = 1
		while not queue.is_empty():
			var c: int = queue.pop_back()
			cells.append(c)
			max_acc = maxi(max_acc, f.accum[c])
			var cx := c % FIELD_SIDE
			var cz := c / FIELD_SIDE
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var jx := cx + dx
					var jz := cz + dz
					if jx < 0 or jx >= FIELD_SIDE or jz < 0 or jz >= FIELD_SIDE:
						continue
					var j := jz * FIELD_SIDE + jx
					# A carved channel pouring in feeds the basin — its
					# catchment counts toward the inflow budget.
					if f.flags[j] & FLAG_RIVER and f.flow_next[j] == c:
						max_acc = maxi(max_acc, f.accum[j])
					elif (
						not seen[j]
						and f.flags[j] & FLAG_WATER
						and f.flags[j] & FLAG_RIVER == 0
						and filled[j] == filled[c]
					):
						seen[j] = 1
						queue.append(j)
		var keeps := (
			cells.size() >= MIN_LAKE_CELLS
			and float(max_acc) / cells.size() >= keep_ratio
		)
		if not keeps:
			for c in cells:
				f.flags[c] = (f.flags[c] & ~FLAG_WATER) | FLAG_WET
				f.water[c] = DRY
				f.soil[c] = wet_idx
				# Demotion re-opens the ground: a river neighbour's
				# capped surface was computed while this cell still held
				# water — re-cap it so the channel never sits above the
				# now-dry floor.
				var cx := c % FIELD_SIDE
				var cz := c / FIELD_SIDE
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						var jx := cx + dx
						var jz := cz + dz
						if (
							jx < 0 or jx >= FIELD_SIDE
							or jz < 0 or jz >= FIELD_SIDE
						):
							continue
						var j := jz * FIELD_SIDE + jx
						if f.flags[j] & FLAG_RIVER:
							f.water[j] = mini(f.water[j], h[c])
			continue
		# The pour cell: a member whose flow_next leaves the basin.
		var outlet := -1
		for c in cells:
			var p: int = f.flow_next[c]
			if p < 0 or f.flags[p] & FLAG_WATER == 0 or filled[p] < filled[c]:
				outlet = c
				break
		f.basins.append(
			{&"cells": cells, &"level": int(filled[cells[0]]), &"outlet": outlet}
		)


## Warm+wet deepens soil, cold or dry shallows it (per-cell meso
## climate). Warmth only helps when moisture feeds it — a hot arid
## cell stays thin, not deep.
static func _climate_f(temp: float, precip: float) -> float:
	var warmth := clampf(0.7 + 0.015 * temp, 0.5, 1.15)
	var moisture := clampf(0.6 + precip / 150.0, 0.6, 1.2)
	return clampf(warmth * moisture, 0.4, 1.4)


static func _wetland_spec() -> Dictionary:
	var s := DataPackage.wetland_soil()
	return s if not s.is_empty() else {
		&"topsoil": {&"peat": 3, &"poor": 1}, &"subsoil": {&"clay": 1}, &"depth_m": 2.0
	}


static func _shore_spec() -> Dictionary:
	var s := DataPackage.shore_soil()
	return s if not s.is_empty() else {
		&"topsoil": {&"sand": 3, &"poor": 1}, &"subsoil": {&"sand": 1}, &"depth_m": 1.5
	}
