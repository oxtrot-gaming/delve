class_name MesoMap
extends RefCounted

## Mesoscale map: the flat rectilinear heightfield that resolves one
## world tile for site placement.
##
## A tile (~15.6 km hex) is projected onto its tangent plane — curvature
## over that distance is negligible — and sampled at CELL_M spacing. The
## rim is pinned toward the mean of this tile's and the adjacent
## macroscale tile's elevation in that direction, so two neighbouring
## tiles' mesoscale maps meet at approximately the same height where a
## site crosses a hex boundary. That is the only coupling between the
## hex tiling and this rectilinear grid: approximate, at a distance, via
## the shared macro heights — exact coincidence is impossible and is
## deliberately not attempted.
##
## Off-site units travel abstractly over this heightfield; a microscale
## site only instantiates the voxel map under a small window of it.

const CELL_M := 100 # metres per cell — the user's ~100 m target
const SIDE := 160 # cells per side → a 16 km square patch over a ~15.6 km hex
const EXTENT_M := float(SIDE * CELL_M) # 16 km
const HALF_M := EXTENT_M * 0.5

## ~hex inradius (centre to edge midpoint) for a ~15.6 km-across tile —
## where the rim-pin blend reaches full strength.
const RIM_M := 7800.0

var tile := -1
# metres above sea level, row-major [z*SIDE + x], cell-centre values
# anchored on the tile centre (map coords are metres east/north of it).
var heights: PackedFloat32Array
# Per-cell climate, populated like the heightfield: the rim blends
# toward the mean of this tile's and the nearest-direction neighbour's
# macro values; temperature additionally follows the altitude lapse
# against the macro elevation the cell sits on.
var temp_c: PackedFloat32Array # °C, row-major
var precip_cm: PackedFloat32Array # cm/yr, row-major

# Tangent frame for the tile (unit vectors on the sphere's tangent plane).
var east: Vector3
var north: Vector3
var centre_dir: Vector3


## Deterministic generation for [param globe] tile [param t].
static func generate(globe: WorldGlobe, t: int) -> MesoMap:
	var map := MesoMap.new()
	map.tile = t
	map.centre_dir = globe.centers[t]

	# Tangent frame: north is the projected sphere-up, degenerate near
	# the poles — fall back to a stable orthogonal there.
	var up := Vector3.UP
	if absf(map.centre_dir.dot(up)) > 0.98:
		up = Vector3.FORWARD
	map.north = (up - map.centre_dir * map.centre_dir.dot(up)).normalized()
	map.east = map.north.cross(map.centre_dir).normalized()

	# Each neighbour's planar direction, for picking which macro tile
	# owns a rim direction when blending boundary values.
	var nbr_dirs := PackedVector3Array()
	var nbr_h := PackedFloat32Array()
	var nbr_t := PackedFloat32Array()
	var nbr_p := PackedFloat32Array()
	for k in globe.degree(t):
		var n := globe.neighbour_of(t, k)
		var rel := globe.centers[n] - map.centre_dir * globe.centers[n].dot(map.centre_dir)
		nbr_dirs.append(rel.normalized())
		nbr_h.append(globe.height_m[n])
		nbr_t.append(globe.temp_c[n])
		nbr_p.append(globe.precip[n])

	var detail := FastNoiseLite.new()
	detail.seed = globe.world_seed * 2654435761 + t
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 4
	detail.frequency = 0.00035 # ~3 km features
	var ridge := FastNoiseLite.new()
	ridge.seed = globe.world_seed * 2246822519 + t
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridge.frequency = 0.004 # ~250 m features

	var h0: float = globe.height_m[t]
	var t0: float = globe.temp_c[t]
	var p0: float = globe.precip[t]
	map.heights = PackedFloat32Array()
	map.heights.resize(SIDE * SIDE)
	map.temp_c = PackedFloat32Array()
	map.temp_c.resize(SIDE * SIDE)
	map.precip_cm = PackedFloat32Array()
	map.precip_cm.resize(SIDE * SIDE)
	for cz in SIDE:
		var z := cz * CELL_M + CELL_M * 0.5 - HALF_M
		for cx in SIDE:
			var x := cx * CELL_M + CELL_M * 0.5 - HALF_M
			var r := sqrt(x * x + z * z)
			# Rim blend: 0 inside ~70% of the hex, 1 at/behind the rim.
			var rf := clampf((r - 0.7 * RIM_M) / (0.3 * RIM_M), 0.0, 1.0)
			rf = rf * rf * (3.0 - 2.0 * rf)
			var best := 0
			var target := h0
			if rf > 0.0 and r > 0.0:
				# Nearest neighbour in this direction, by planar dot.
				var ux := x / r
				var uz := z / r
				var best_dot := -2.0
				for k in nbr_dirs.size():
					var nd := nbr_dirs[k]
					var dot := ux * nd.dot(map.east) + uz * nd.dot(map.north)
					if dot > best_dot:
						best_dot = dot
						best = k
				target = 0.5 * (h0 + nbr_h[best])
			var i := cz * SIDE + cx
			var d := 26.0 * detail.get_noise_2d(x, z) + 5.0 * ridge.get_noise_2d(x + 9137.0, z - 4171.0)
			var h := lerpf(h0 + d * (1.0 - rf), target, rf)
			map.heights[i] = h
			# Macro elevation the cell sits on (before meso detail) —
			# the lapse runs against that, so the detail heights cool
			# and warm their own cells.
			var h_macro := lerpf(h0, target, rf)
			var t_macro := lerpf(t0, 0.5 * (t0 + nbr_t[best]), rf)
			map.temp_c[i] = t_macro - 0.006 * (h - h_macro)
			map.precip_cm[i] = lerpf(p0, 0.5 * (p0 + nbr_p[best]), rf)
	return map


## Height in metres at map-space metres (x, z) east/north of the tile
## centre. Bilinear; samples outside clamp to the border.
func height_at(x_m: float, z_m: float) -> float:
	return _bilerp(heights, x_m, z_m)


## Mean annual temperature in °C at map-space metres — the mesoscale
## value the site's weather takes as its annual mean.
func temp_at(x_m: float, z_m: float) -> float:
	return _bilerp(temp_c, x_m, z_m)


## Mean annual precipitation in cm at map-space metres.
func precip_at(x_m: float, z_m: float) -> float:
	return _bilerp(precip_cm, x_m, z_m)


## Shared bilinear sample over a SIDE×SIDE row-major field.
func _bilerp(field: PackedFloat32Array, x_m: float, z_m: float) -> float:
	var gx := clampf((x_m + HALF_M) / CELL_M - 0.5, 0.0, SIDE - 1.001)
	var gz := clampf((z_m + HALF_M) / CELL_M - 0.5, 0.0, SIDE - 1.001)
	var cx := int(gx)
	var cz := int(gz)
	var fx := gx - cx
	var fz := gz - cz
	var i00 := cz * SIDE + cx
	var top := lerpf(field[i00], field[i00 + 1], fx)
	var bot := lerpf(field[i00 + SIDE], field[i00 + SIDE + 1], fx)
	return lerpf(top, bot, fz)


## Integer heightfield for the voxel generators (WorldGenerator oracle
## and DelveGenerator native): one int per cell, in voxel units,
## rebased so [param anchor_voxel] columns sit at [param base_height].
## Only the local slope crosses into voxel space; the planet's absolute
## elevation stays a macroscale concern.
##
## The deviation from the anchor's height is damped toward it out to a
## ~½ km radius — a settled site rests on locally level ground (the
## colony lands where building is workable), while this map's own
## heights stay full-fidelity for off-site queries. Past the ramp the
## tile's real relief applies unreduced.
##
## Returns {grid, origin, step, size} — install via
## WorldGenerator.install_regional_grid.
func voxel_grid(anchor_voxel: Vector2i, base_height: int) -> Dictionary:
	var anchor_h := int(round(height_at(float(anchor_voxel.x), float(anchor_voxel.y))))
	var grid := PackedInt32Array()
	grid.resize(SIDE * SIDE)
	for cz in SIDE:
		# Cell centre's offset from the anchor in metres — the anchor
		# maps to this map's centre, so the offset is the map coord.
		var dz := cz * CELL_M + CELL_M * 0.5 - HALF_M
		for cx in SIDE:
			var dx := cx * CELL_M + CELL_M * 0.5 - HALF_M
			var ramp := clampf(sqrt(dx * dx + dz * dz) / 512.0, 0.0, 1.0)
			var h: float = anchor_h + (heights[cz * SIDE + cx] - anchor_h) * ramp
			grid[cz * SIDE + cx] = base_height + int(round(h - anchor_h))
	return {
		"grid": grid,
		"origin": anchor_voxel - Vector2i(int(HALF_M), int(HALF_M)) + Vector2i(CELL_M / 2, CELL_M / 2),
		"step": CELL_M,
		"size": SIDE,
	}
