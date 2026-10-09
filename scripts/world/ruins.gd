class_name Ruins
extends RefCounted

## Ancient collapsed structures seeded when a site is settled — the
## standing dead's leavings: partial stone walls to shelter behind or
## pull apart for dressed blocks before the colony can cut its own,
## rubble underfoot, and the odd intact find. RimWorld's ruins play the
## same role: early shelter and early material, scattered where people
## lived before.
##
## Placement is deterministic — seeded from the world seed and site id
## — and writes into the region's edit log rather than the live terrain
## where it can: unloaded cells record their blocks and replay them as
## chunks stream, loaded cells place normally. Either way the ruin is
## ordinary terrain once it exists: mine it, build on it, flood it.
## Wall voxels also register as deconstructable buildings carrying the
## spec's components, so a teardown pays dressed stone without the
## stonecutter. [member Site.ruins_placed] makes the pass run once.

## Ruins per site — a handful of finds, not a dead city.
const RUIN_COUNT := [3, 6]
## Columns between ruin centres — they read as separate structures.
const RUIN_MIN_GAP := 14
## Columns a ruin's nearest edge keeps from the founding anchor — the
## landing clearing shouldn't have a skeleton fallen into it, and the
## scatter the player first works stays clear of rubble.
const ANCHOR_MIN_GAP := 24
## Margin inside the site bounds so no wall hangs off the edge.
const EDGE_MARGIN := 8
## Height spread (voxels) a ruin's footprint tolerates — the walls were
## built on levelled ground, not on a slope.
const MAX_RELIEF := 3
## A perimeter cell still stands at this rate; the rest collapsed or
## was carried off.
const WALL_STAY := 0.55
## A standing cell keeps a second course at this rate.
const TALL_CHANCE := 0.15
## Interior cells carry rubble at this rate.
const DEBRIS_CHANCE := 0.35
## Candidate spots tried per wanted ruin before giving up.
const TRIES_PER_RUIN := 60


## Lays the site's ruins: marks [param site] done so activation of a
## dormant site is a no-op, and skips ground the player already
## touched. [param gen] is the generator oracle (terrain height and
## water depth answer before chunks stream); [param world] writes
## loaded cells, [param region] records the rest.
static func place(
	site: Site,
	colony: Colony,
	world: VoxelWorld,
	region: Region,
	gen: WorldGenerator,
	world_seed: int
) -> void:
	if site.ruins_placed:
		return
	site.ruins_placed = true
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ (site.id * 0x9E3779B1) ^ 0x5F175
	var centres: Array[Vector2i] = []
	var wanted := rng.randi_range(RUIN_COUNT[0], RUIN_COUNT[1])
	var tries := 0
	while centres.size() < wanted and tries < wanted * TRIES_PER_RUIN:
		tries += 1
		var w := rng.randi_range(4, 9)
		var d := rng.randi_range(4, 8)
		var cx := rng.randi_range(
			site.bounds.position.x + EDGE_MARGIN,
			site.bounds.end.x - EDGE_MARGIN - w
		)
		var cz := rng.randi_range(
			site.bounds.position.y + EDGE_MARGIN,
			site.bounds.end.y - EDGE_MARGIN - d
		)
		var centre := Vector2i(cx + w / 2, cz + d / 2)
		if _too_close(centres, centre, Rect2i(cx, cz, w, d), site):
			continue
		var cells := _footprint_cells(cx, cz, w, d)
		if not _ground_ok(world, region, gen, colony, cells):
			continue
		centres.append(centre)
		_raise(colony, world, region, gen, rng, cells, cx, cz, w, d)
	DLog.log("ruins: %d placed on site %d" % [centres.size(), site.id])


## A ruin centre must stand apart from its neighbours, and its whole
## footprint must keep the anchor's clearing — [param rect] is the
## footprint, whose nearest column to the anchor does the measuring.
static func _too_close(
	centres: Array[Vector2i], centre: Vector2i, rect: Rect2i, site: Site
) -> bool:
	var anchor := Vector2i(site.anchor.x, site.anchor.z)
	var nearest: Vector2i = anchor.clamp(rect.position, rect.end - Vector2i.ONE)
	if Vector2(nearest).distance_to(Vector2(anchor)) < ANCHOR_MIN_GAP:
		return true
	for other in centres:
		if Vector2(other).distance_to(Vector2(centre)) < RUIN_MIN_GAP:
			return true
	return false


## Every column the footprint covers, perimeter and interior alike.
static func _footprint_cells(
	cx: int, cz: int, w: int, d: int
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for z in range(cz, cz + d):
		for x in range(cx, cx + w):
			cells.append(Vector2i(x, z))
	return cells


## The ruin wants dry, flat, untouched ground: no open water anywhere
## under the walls, little relief, and — for sites the player already
## lives on — no recorded edits or standing construction in the
## footprint.
static func _ground_ok(
	world: VoxelWorld,
	region: Region,
	gen: WorldGenerator,
	colony: Colony,
	cells: Array[Vector2i]
) -> bool:
	var low := 1 << 30
	var high := -(1 << 30)
	for c in cells:
		if gen.water_depth_at(c.x, c.y) > 0:
			return false
		var h := gen.terrain_height(c.x, c.y)
		low = mini(low, h)
		high = maxi(high, h)
	if high - low > MAX_RELIEF:
		return false
	for c in cells:
		# A column the player has touched — dug, filled or built on —
		# isn't ancient ground; leave it alone.
		var base := gen.terrain_height(c.x, c.y)
		for y in range(base - MAX_RELIEF, base + MAX_RELIEF + 2):
			if region.edits.has(Vector3i(c.x, y, c.y)):
				return false
		var y := _standing_y(world, gen, c)
		if y < 0 or colony.building_at(Vector3i(c.x, y, c.y)) != null:
			return false
	return true


## The open-air voxel a wall or debris sits in at [param column]: the
## natural surface corrected for whatever the sim knows happened there
## — dug-out ground steps it down, built-up ground steps it up. -1 when
## the column is too disturbed to stand a ruin on.
static func _standing_y(
	world: VoxelWorld, gen: WorldGenerator, c: Vector2i
) -> int:
	var y := gen.terrain_height(c.x, c.y) + 1
	var moves := 0
	while moves <= MAX_RELIEF and world.is_solid(Vector3i(c.x, y, c.y)):
		y += 1
		moves += 1
	while moves <= MAX_RELIEF and not world.is_solid(
		Vector3i(c.x, y - 1, c.y)
	):
		y -= 1
		moves += 1
	return y if moves <= MAX_RELIEF else -1


## One structure: the perimeter ring partly fallen, a doorway gap or
## two, a few cells a course taller, rubble and dressed stone in the
## middle.
static func _raise(
	colony: Colony,
	world: VoxelWorld,
	region: Region,
	gen: WorldGenerator,
	rng: RandomNumberGenerator,
	cells: Array[Vector2i],
	cx: int,
	cz: int,
	w: int,
	d: int
) -> void:
	var gaps := {}
	for i in rng.randi_range(1, 2):
		gaps[_perimeter_cell(
			rng.randi_range(0, 2 * (w + d) - 5), w, d, cx, cz
		)] = true
	for c in cells:
		var base_y := _standing_y(world, gen, c)
		if base_y < 0:
			continue
		var base := Vector3i(c.x, base_y, c.y)
		var on_edge := (
			c.x == cx or c.x == cx + w - 1 or c.y == cz or c.y == cz + d - 1
		)
		if on_edge:
			if gaps.has(c) or rng.randf() > WALL_STAY:
				continue
			if _write_wall(world, region, base):
				_register_wall(colony, base)
				if rng.randf() < TALL_CHANCE:
					var top := base + Vector3i.UP
					if _write_wall(world, region, top):
						_register_wall(colony, top)
		elif rng.randf() < DEBRIS_CHANCE:
			_scatter_debris(colony, base, rng)


## The perimeter's [param i]th cell in ring order — the gaps key off
## global columns the same way the writer walks them.
static func _perimeter_cell(i: int, w: int, d: int, cx: int, cz: int) -> Vector2i:
	var p := 0
	for z in range(0, d):
		for x in range(0, w):
			if x == 0 or x == w - 1 or z == 0 or z == d - 1:
				if p == i:
					return Vector2i(cx + x, cz + z)
				p += 1
	return Vector2i(cx, cz)


## Writes a ruin wall voxel: through the live world when the cell is
## streamed (which records the edit itself), else straight into the
## region's edit log to replay when the chunk loads. Refuses ground
## that isn't open air or that a save already knows was edited.
static func _write_wall(
	world: VoxelWorld, region: Region, v: Vector3i
) -> bool:
	if world.is_solid(v):
		return false
	if world.is_editable(v):
		return world.place(v, BlockRegistry.Block.STONE_WALL)
	if region.edits.has(v):
		return false
	region.record_edit(v, BlockRegistry.Block.STONE_WALL)
	return true


## The wall voxel stands, so its record does too — a deconstructable
## stone wall carrying the same hundred and twenty dressed blocks a
## builder would have escrowed into it, so a teardown pays out exactly
## what the wall is made of, in haulable pieces.
static func _register_wall(colony: Colony, v: Vector3i) -> void:
	if colony.building_at(v) != null:
		return
	var building := Building.new(Building.Kind.WALL, v)
	building.spec = &"stone_wall"
	building.block_id = BlockRegistry.Block.STONE_WALL
	building.material = BlockRegistry.Resource_.STONE
	for i in 120:
		building.components.append(
			DropItem.new(
				BlockRegistry.Resource_.STONE,
				DropItem.Form.BLOCK,
				DropItem.STONE_BLOCK_CM3
			)
		)
	# grow_home=false — a ruin is landscape the colony finds, not
	# construction it claims; the home area belongs to the living.
	colony.register_building(building, false)


## What fell out of the walls: loose rubble, and the find that matters —
## a few dressed blocks ready to reuse. Everything lands forbidden —
## unclaimed goods the colony ignores until the player says otherwise,
## so a scatter of dressed stone near the landing doesn't hijack every
## fetch and haul query on the map.
static func _scatter_debris(
	colony: Colony, v: Vector3i, rng: RandomNumberGenerator
) -> void:
	var rubble := DropItem.new(
		BlockRegistry.Resource_.STONE,
		DropItem.Form.LOOSE,
		rng.randi_range(20_000, 120_000)
	)
	rubble.forbidden = true
	colony._drop_item(rubble, v)
	for i in rng.randi_range(0, 3):
		var block := DropItem.new(
			BlockRegistry.Resource_.STONE,
			DropItem.Form.BLOCK,
			DropItem.STONE_BLOCK_CM3
		)
		block.forbidden = true
		colony._drop_item(block, v)
