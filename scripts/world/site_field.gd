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


static func generate(meso: MesoMap, gen: WorldGenerator, anchor: Vector2i) -> SiteField:
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

	var filled := PackedInt32Array()
	filled.resize(n)
	f.flow_next = PackedInt32Array()
	f.flow_next.resize(n)
	f.flow_next.fill(-1)
	var order := _flood_fill(h, filled, f.flow_next)
	f.spill = filled

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
				f.water[i] = h[i] - RIVER_WATER_DROP
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

	_extract_basins(f, h, filled)
	return f


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
static func _extract_basins(
	f: SiteField, h: PackedInt32Array, filled: PackedInt32Array
) -> void:
	var n := FIELD_SIDE * FIELD_SIDE
	var seen := PackedByteArray()
	seen.resize(n)
	for i in n:
		if seen[i] or not f.flags[i] & FLAG_WATER or f.flags[i] & FLAG_RIVER:
			continue
		var cells := PackedInt32Array()
		var queue := [i]
		seen[i] = 1
		while not queue.is_empty():
			var c: int = queue.pop_back()
			cells.append(c)
			var cx := c % FIELD_SIDE
			var cz := c / FIELD_SIDE
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var jx := cx + dx
					var jz := cz + dz
					if jx < 0 or jx >= FIELD_SIDE or jz < 0 or jz >= FIELD_SIDE:
						continue
					var j := jz * FIELD_SIDE + jx
					if (
						not seen[j]
						and f.flags[j] & FLAG_WATER
						and f.flags[j] & FLAG_RIVER == 0
						and filled[j] == filled[c]
					):
						seen[j] = 1
						queue.append(j)
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
