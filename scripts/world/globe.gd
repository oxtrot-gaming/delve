class_name WorldGlobe
extends RefCounted

## Macroscale planetary map: a Goldberg (m,0) hex/pent tiling of a sphere.
##
## The planet is moon-sized (radius ~1,737 km) and subdivided at class
## m = SUBDIVISION, giving 10m²+2 = 179,562 tiles: hexagons about 15.6 km
## across plus the unavoidable twelve pentagons. Each tile carries the
## large-scale features a site draws from — elevation, temperature,
## precipitation — while the tile graph provides neighbours for mesoscale
## edge-pinning and (later) off-site travel.
##
## Everything is deterministic from the world seed, so a globe is a pure
## function of the save's seed and never itself serialised. Mesoscale
## maps (MesoMap) resolve one tile into a flat ~100 m heightfield; the
## rectilinear site grid embeds into that plane approximately — exact
## hex/rectilinear coincidence is mathematically impossible and not
## attempted.

const SUBDIVISION := 134
const TILE_COUNT := SUBDIVISION * SUBDIVISION * 10 + 2
const RADIUS_M := 1_737_100.0
## Sea level is always 0 in [member height_m] — the raw noise terrain
## is rebased so the requested ocean fraction sits below zero.
const SEA_LEVEL_M := 0.0

## Worldgen sliders (PLAN item 39). Ranges match the new-game options:
## ocean coverage as a tile percentage in steps of five — 100% would be
## an unplayable water world, so it tops at 95 — plus planet-wide hot/
## cold and wet/dry biases centred on a balanced default.
const OCEAN_PCT_MIN := 0
const OCEAN_PCT_MAX := 95
const OCEAN_PCT_STEP := 5
const OCEAN_PCT_DEFAULT := 70
const TEMP_BIAS_MIN_C := -20.0
const TEMP_BIAS_MAX_C := 20.0
const MOIST_BIAS_MIN := -0.35
const MOIST_BIAS_MAX := 0.35

## Whittaker-style biome classification — the land bands are read off
## the canonical temperature × annual-precipitation diagram (piecewise
## thresholds approximating its curved regions). Sea biomes aren't in
## the diagram: below sea level it's OCEAN, except under a freezing
## mean temperature where it's ICE_CAP. A swamp can't come out of this
## table — that needs a drainage/riverine model — so low-drainage
## variants wait on it.
enum Biome {
	OCEAN,
	ICE_CAP,
	TUNDRA,
	BOREAL_FOREST,
	TEMPERATE_GRASSLAND, ## the diagram's grassland/desert
	WOODLAND_SHRUBLAND,
	TEMPERATE_SEASONAL_FOREST,
	TEMPERATE_RAIN_FOREST,
	SUBTROPICAL_DESERT,
	TROPICAL_SEASONAL_FOREST, ## includes savanna
	TROPICAL_RAIN_FOREST,
}

const BIOME_NAMES: Dictionary = {
	Biome.OCEAN: "Ocean",
	Biome.ICE_CAP: "Ice cap",
	Biome.TUNDRA: "Tundra",
	Biome.BOREAL_FOREST: "Boreal forest",
	Biome.TEMPERATE_GRASSLAND: "Temperate grassland",
	Biome.WOODLAND_SHRUBLAND: "Woodland/shrubland",
	Biome.TEMPERATE_SEASONAL_FOREST: "Temperate seasonal forest",
	Biome.TEMPERATE_RAIN_FOREST: "Temperate rain forest",
	Biome.SUBTROPICAL_DESERT: "Subtropical desert",
	Biome.TROPICAL_SEASONAL_FOREST: "Tropical seasonal forest",
	Biome.TROPICAL_RAIN_FOREST: "Tropical rain forest",
}

## Continent relief and the mesoscale detail heights are in metres; a
## voxel column is 1 m, but only the *local* slope feeds site terrain —
## a site's base height is rebased to its own anchor, so absolute
## planetary elevation never enters voxel y-space.

var world_seed := 0
## The worldgen options this globe was built with (see the constants
## above for the slider ranges).
var ocean_pct := OCEAN_PCT_DEFAULT
var temp_bias_c := 0.0
var moist_bias := 0.0
## The raw-noise height the chosen ocean fraction put the sea at —
## informative only; [member height_m] is already rebased to 0.
var sea_level_raw_m := 0.0

# Per-tile records (index = tile id).
var centers: PackedVector3Array # unit-sphere directions
var height_m: PackedFloat32Array # metres above sea level (negative = ocean)
var temp_c: PackedFloat32Array # baseline annual mean, °C
var precip: PackedFloat32Array # baseline annual precipitation, cm
var ocean: PackedByteArray
var biome: PackedByteArray # Biome per tile
# Flat neighbour table: neighbours[t*6+k], k < degree(t); -1 padding on
# the twelve pentagons. Ids < 2^18 so keys pack into one int64.
var neighbours: PackedInt32Array

var _icos_verts: PackedVector3Array
var _icos_faces: PackedInt32Array # 20 triples, CCW outward
var _icos_edges: PackedInt32Array # 30 sorted pairs
var _edge_index: Dictionary # pair key -> edge ordinal

const _PHI := 1.618033988749895
const _A := 0.5257311121191336
const _B := 0.8506508083520399


func _init(p_seed: int = 0, p_options: Dictionary = {}) -> void:
	world_seed = p_seed
	ocean_pct = clampi(
		int(p_options.get(&"ocean_pct", OCEAN_PCT_DEFAULT)),
		OCEAN_PCT_MIN, OCEAN_PCT_MAX
	)
	# Snap to the slider's step so a stray value still lands on a stop.
	ocean_pct = int(roundi(float(ocean_pct) / OCEAN_PCT_STEP) * OCEAN_PCT_STEP)
	temp_bias_c = clampf(
		float(p_options.get(&"temp_bias_c", 0.0)),
		TEMP_BIAS_MIN_C, TEMP_BIAS_MAX_C
	)
	moist_bias = clampf(
		float(p_options.get(&"moist_bias", 0.0)),
		MOIST_BIAS_MIN, MOIST_BIAS_MAX
	)


## Full generation: tiling topology, then macro fields. Runs once per
## world (a second or two of GDScript); the result is only ever read.
func generate() -> void:
	_build_tiling()
	_build_fields()


## The tile's biome name for UI.
func biome_name(tile: int) -> String:
	return String(BIOME_NAMES.get(biome[tile], "?"))


## Whittaker-diagram classification — the baseline temperature × annual
## precipitation bands, with the sea rule on top (sub-freezing ocean is
## ice cap). See the [enum Biome] comment for the model's limits.
static func classify(temp: float, precip_cm: float, is_ocean: bool) -> Biome:
	if is_ocean:
		return Biome.ICE_CAP if temp < 0.0 else Biome.OCEAN
	if temp < -5.0:
		# Cold at any rainfall — the diagram's tundra reaches all the
		# way down the dry side (polar desert).
		return Biome.TUNDRA
	if temp < 5.0:
		return Biome.BOREAL_FOREST if precip_cm >= 40.0 else Biome.TUNDRA
	if temp < 18.0:
		if precip_cm < 30.0:
			return Biome.TEMPERATE_GRASSLAND
		if precip_cm < 75.0:
			return Biome.WOODLAND_SHRUBLAND
		if precip_cm < 200.0:
			return Biome.TEMPERATE_SEASONAL_FOREST
		return Biome.TEMPERATE_RAIN_FOREST
	# Tropical: the rain-forest line climbs with temperature — hotter
	# climates need more rain to stay closed-canopy.
	if precip_cm < 45.0:
		return Biome.SUBTROPICAL_DESERT
	if precip_cm >= 160.0 + maxf(0.0, temp - 20.0) * 8.0:
		return Biome.TROPICAL_RAIN_FOREST
	return Biome.TROPICAL_SEASONAL_FOREST


func degree(tile: int) -> int:
	return 5 if tile < 12 else 6


## Tile id whose centre direction best matches [param dir]
## (unit vector). O(N); used rarely (site placement, lookup).
func tile_at(dir: Vector3) -> int:
	var d := dir.normalized()
	var best := -1
	var best_dot := -2.0
	for t in TILE_COUNT:
		var dot := centers[t].dot(d)
		if dot > best_dot:
			best_dot = dot
			best = t
	return best


## Nearest land tile to [param dir] — the default site placement picks
## a temperate-latitude, non-ocean tile.
func nearest_land_tile(dir: Vector3) -> int:
	var d := dir.normalized()
	var best := -1
	var best_dot := -2.0
	for t in TILE_COUNT:
		if ocean[t] != 0:
			continue
		var dot := centers[t].dot(d)
		if dot > best_dot:
			best_dot = dot
			best = t
	return best


func neighbour_of(tile: int, k: int) -> int:
	return neighbours[tile * 6 + k]


## Canonical reference direction for a fresh world: mid-northern
## latitude, where a default colony site is seeded until the world-map
## UI (item 39) makes settlement a player choice.
static func default_settle_dir() -> Vector3:
	return Vector3(0.55, 0.62, 0.55).normalized()


# --- Tiling -------------------------------------------------------------


func _build_tiling() -> void:
	var v := [
		Vector3(-_A, _B, 0), Vector3(_A, _B, 0), Vector3(-_A, -_B, 0), Vector3(_A, -_B, 0),
		Vector3(0, -_A, _B), Vector3(0, _A, _B), Vector3(0, -_A, -_B), Vector3(0, _A, -_B),
		Vector3(_B, 0, -_A), Vector3(_B, 0, _A), Vector3(-_B, 0, -_A), Vector3(-_B, 0, _A),
	]
	_icos_verts = PackedVector3Array(v)
	_build_icos_edges()
	_build_icos_faces()

	var m := SUBDIVISION
	var inner := (m - 1) * (m - 2) / 2 # interior vertices per face
	centers = PackedVector3Array()
	centers.resize(TILE_COUNT)
	# Edge keys are int64-friendly: ids fit in 18 bits.
	var edge_set := {}
	var face_base := 12 + 30 * (m - 1)

	# gid cache: (face, i, j) lattice point -> global tile id. k = m-i-j.
	var va: Vector3
	var vb: Vector3
	var vc: Vector3
	for f in 20:
		va = _icos_verts[_icos_faces[f * 3]]
		vb = _icos_verts[_icos_faces[f * 3 + 1]]
		vc = _icos_verts[_icos_faces[f * 3 + 2]]
		# Enumerate all (i,j) lattice points once into a grid so the two
		# triangle passes below resolve global ids in O(1).
		var grid := PackedInt32Array()
		grid.resize((m + 1) * (m + 2) / 2)
		for i in m + 1:
			for j in m + 1 - i:
				var id := _gid(f, i, j, m - i - j, face_base)
				grid[i * (m + 1) - i * (i - 1) / 2 + j] = id
				centers[id] = (va * i + vb * j + vc * (m - i - j)).normalized()

		# Upward triangles (i,j),(i+1,j),(i,j+1).
		for i in m:
			for j in m - i:
				_tri_edges(edge_set, grid[i * (m + 1) - i * (i - 1) / 2 + j], grid[(i + 1) * (m + 1) - (i + 1) * i / 2 + j], grid[i * (m + 1) - i * (i - 1) / 2 + j + 1])
		# Downward triangles (i+1,j),(i,j+1),(i+1,j+1).
		for i in m - 1:
			for j in m - 1 - i:
				_tri_edges(edge_set, grid[(i + 1) * (m + 1) - (i + 1) * i / 2 + j], grid[i * (m + 1) - i * (i - 1) / 2 + j + 1], grid[(i + 1) * (m + 1) - (i + 1) * i / 2 + j + 1])

	neighbours = PackedInt32Array()
	neighbours.resize(TILE_COUNT * 6)
	neighbours.fill(-1)
	var counts := PackedInt32Array()
	counts.resize(TILE_COUNT)
	for key in edge_set.keys():
		var a: int = key >> 18
		var b: int = key & 0x3FFFF
		neighbours[a * 6 + counts[a]] = b
		counts[a] += 1
		neighbours[b * 6 + counts[b]] = a
		counts[b] += 1


## Global tile id for lattice point (i,j,k) on face f. Canonical ids:
## 0..11 icosa corners (pentagons), then 30·(m-1) edge-interior points,
## then 20·inner face-interior points.
func _gid(f: int, i: int, j: int, k: int, face_base: int) -> int:
	var m := SUBDIVISION
	var a := _icos_faces[f * 3]
	var b := _icos_faces[f * 3 + 1]
	var c := _icos_faces[f * 3 + 2]
	if i == m:
		return a
	if j == m:
		return b
	if k == m:
		return c
	if k == 0:
		# Edge A–B; point is i steps' weight on A, j on B.
		return _edge_gid(a, b, j if a < b else i)
	if i == 0:
		# Edge B–C; j weight on B, k on C.
		return _edge_gid(b, c, k if b < c else j)
	if j == 0:
		# Edge C–A; k weight on C, i on A.
		return _edge_gid(c, a, i if c < a else k)
	# Interior: count (i',j') pairs with j' < j, then i' < i in row j.
	return face_base + f * ((m - 1) * (m - 2) / 2) + _inner_index(i, j)


## Steps-from-canonical-endpoint resolution for an icosa edge point.
## (a,b) unordered endpoints, t_from is the weight on whichever endpoint
## the caller reports; we convert to steps from the min-indexed vertex.
func _edge_gid(a: int, b: int, t_from_min: int) -> int:
	var e: int = _edge_index[_pair_key(a, b)]
	# Edge points are numbered 1..m-1 from the lower-indexed endpoint.
	return 12 + e * (SUBDIVISION - 1) + (t_from_min - 1)


## Interior index of lattice point (i,j), i,j,k>0, within a face:
## rows j=1..m-2, columns i=1..m-1-j.
func _inner_index(i: int, j: int) -> int:
	var m := SUBDIVISION
	return (j - 1) * (m - 1) - (j - 1) * j / 2 + (i - 1)


func _tri_edges(edge_set: Dictionary, a: int, b: int, c: int) -> void:
	edge_set[_cell_key(a, b)] = true
	edge_set[_cell_key(b, c)] = true
	edge_set[_cell_key(a, c)] = true


static func _cell_key(a: int, b: int) -> int:
	return (a << 18 | b) if a < b else (b << 18 | a)


static func _pair_key(a: int, b: int) -> int:
	return (a << 4 | b) if a < b else (b << 4 | a)


func _build_icos_edges() -> void:
	# An icosahedron with the vertex coordinates above has edge length
	# 2·_A; keep every vertex pair at that distance.
	var e2 := 4.0 * _A * _A
	var pairs: Array[Vector2i] = []
	for a in 12:
		for b in range(a + 1, 12):
			if absf(_icos_verts[a].distance_squared_to(_icos_verts[b]) - e2) < 0.001:
				pairs.append(Vector2i(a, b))
	assert(pairs.size() == 30)
	pairs.sort()
	_icos_edges = PackedInt32Array()
	for p in pairs:
		_icos_edges.append(p.x)
		_icos_edges.append(p.y)
	for e in 30:
		_edge_index[_pair_key(_icos_edges[e * 2], _icos_edges[e * 2 + 1])] = e


func _build_icos_faces() -> void:
	# Each edge is shared by exactly two faces; the third vertex of a
	# face is a common neighbour of both edge endpoints.
	var adj := {}
	for e in 30:
		var a := _icos_edges[e * 2]
		var b := _icos_edges[e * 2 + 1]
		if not adj.has(a):
			adj[a] = []
		if not adj.has(b):
			adj[b] = []
		adj[a].append(b)
		adj[b].append(a)
	var seen := {}
	var faces := PackedInt32Array()
	for e in 30:
		var a := _icos_edges[e * 2]
		var b := _icos_edges[e * 2 + 1]
		for c in adj[a]:
			if c == b or not adj[b].has(c):
				continue
			var key := _pair_key3(a, b, c)
			if seen.has(key):
				continue
			seen[key] = true
			# Orient CCW when viewed from outside.
			var va := _icos_verts[a]
			var vb := _icos_verts[b]
			var vc := _icos_verts[c]
			if (vb - va).cross(vc - va).dot(va + vb + vc) > 0.0:
				faces.append_array([a, b, c])
			else:
				faces.append_array([a, c, b])
	assert(faces.size() == 60)
	_icos_faces = faces


static func _pair_key3(a: int, b: int, c: int) -> int:
	var v := [a, b, c]
	v.sort()
	return v[0] << 8 | v[1] << 4 | v[2]


# --- Macro fields -------------------------------------------------------


func _build_fields() -> void:
	var n := TILE_COUNT
	height_m = PackedFloat32Array()
	height_m.resize(n)
	temp_c = PackedFloat32Array()
	temp_c.resize(n)
	precip = PackedFloat32Array()
	precip.resize(n)
	ocean = PackedByteArray()
	ocean.resize(n)
	biome = PackedByteArray()
	biome.resize(n)

	# Continents: domain-warped fBm sampled on the unit sphere. The
	# warp keeps coastlines irregular instead of noise-round.
	var land := FastNoiseLite.new()
	land.seed = world_seed * 31 + 11
	land.noise_type = FastNoiseLite.TYPE_SIMPLEX
	land.fractal_type = FastNoiseLite.FRACTAL_FBM
	land.fractal_octaves = 5
	land.frequency = 1.4
	var warp := FastNoiseLite.new()
	warp.seed = world_seed * 31 + 12
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp.frequency = 2.2
	var moist := FastNoiseLite.new()
	moist.seed = world_seed * 31 + 13
	moist.noise_type = FastNoiseLite.TYPE_SIMPLEX
	moist.fractal_octaves = 3
	moist.frequency = 2.0
	var tnoise := FastNoiseLite.new()
	tnoise.seed = world_seed * 31 + 14
	tnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	tnoise.frequency = 4.0

	# Pass 1 — raw terrain heights, then the sea level that puts the
	# requested ocean fraction under water. Heights rebase so sea level
	# is 0: `height_m < 0` means ocean everywhere downstream.
	var raw := PackedFloat32Array()
	raw.resize(n)
	for t in n:
		var d := centers[t]
		var wx := d.x + 0.35 * warp.get_noise_3d(d.x, d.y, d.z)
		var wy := d.y + 0.35 * warp.get_noise_3d(d.y + 9.1, d.z + 3.7, d.x)
		var wz := d.z + 0.35 * warp.get_noise_3d(d.z + 4.3, d.x + 7.9, d.y)
		raw[t] = land.get_noise_3d(wx, wy, wz) * 4200.0 # ±4.2 km relief
	var sorted := raw.duplicate()
	sorted.sort()
	var cut := clampi(
		roundi(ocean_pct / 100.0 * n) - 1, 0, n - 1
	)
	sea_level_raw_m = sorted[cut]
	for t in n:
		height_m[t] = raw[t] - sea_level_raw_m
		ocean[t] = 1 if height_m[t] < SEA_LEVEL_M else 0

	# Pass 2 — climate. Temperature is latitude × altitude lapse ×
	# noise, shifted by the hot/cold slider: the lapse makes high
	# continents cold regardless of latitude, so mountains read tundra
	# in the tropics. Humidity is plain noise scaled to centimetres —
	# no circulation cells or orographic lifting yet (they wait on the
	# riverine model, as do low-drainage swamp variants).
	for t in n:
		var d := centers[t]
		var lat := asin(clampf(d.y, -1.0, 1.0))
		var h := height_m[t]
		# Equator ≈ +30 °C falling to ≈ -25 °C at the poles. The 1.5
		# exponent flattens the tropics and steepens the poles like a
		# real planet's profile — a linear ramp would freeze the ocean
		# poleward of ~40° and drown the map in ice caps. A 6 °C/km
		# lapse then cools high land (ocean sits at the sea surface).
		temp_c[t] = (
			30.0 - 55.0 * pow(absf(lat) / (PI * 0.5), 1.5)
			+ 8.0 * tnoise.get_noise_3d(d.x * 2.0, d.y * 2.0, d.z * 2.0)
			- 0.006 * maxf(h, 0.0)
			+ temp_bias_c
		)
		var m := clampf(
			0.5 + 0.5 * moist.get_noise_3d(d.x, d.y, d.z) + moist_bias,
			0.0, 1.0
		)
		# Moisture → annual cm: squaring keeps deserts dry — the
		# Whittaker bands sit far apart at the wet end.
		precip[t] = m * m * 550.0
		biome[t] = classify(temp_c[t], precip[t], ocean[t] != 0)
