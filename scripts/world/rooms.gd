class_name Rooms
extends RefCounted

## The room graph — PLAN item 23's deferred half, landed at the size
## item 34 needs. A room is a bounded flood-fill component of open
## cells: air voxels, including building cells that stay walkable.
## Solid blocks seal; a door building seals too — the cell stays open
## air in the world, but for room purposes a hung doorway is the wall
## segment it fills, matching RimWorld's closed-door rule. Beds,
## ladders, worksites and the like don't seal — units live among them.
##
## Detection is lazy and query-shaped: `room_at` floods from the asked
## cell only, caching every cell it visits — both what it found and the
## open cells that leaked to the map edge (outside, remembered so a
## dozen outdoor units don't each re-flood the same field). A flood
## that reaches an unloaded cell is outside by definition: the colony
## keeps its whole site loaded while it plays, and the loaded edge is
## the world edge. A flood past MAX_ROOM_CELLS gives up the same way —
## a cavern that size is a cavern, not a room.
##
## Two invalidations exist because they cost differently. Topology
## (`invalidate`) clears everything — called on block and door changes.
## Beauty (`invalidate_beauty`) only stales the cached scores — a
## covering or furnishing edit doesn't move walls.

## Flood cap — past this many open cells a component counts as the
## outdoors no matter how well it seems walled.
const MAX_ROOM_CELLS := 4096

## Cache cap — a leaked flood writes every visited cell into _room_of,
## and outdoors floods repeat per query until the map shape stabilizes;
## past this many cached cells the answer still caches, but only for the
## cell that was asked. Keeps the "many outdoor units" memo without an
## ever-growing null-entry table.
const MAX_CACHE_CELLS := 32768

const Blocks := BlockRegistry.Block


## One bounded component: the cells it spans and the lazily-recomputed
## beauty score. `beauty` is -INF while stale.
class Room:
	var cells: Dictionary = {}
	var beauty := -INF
	var beauty_stale := true
	## The one temperature the enclosed air holds — RimWorld's
	## uniform-room rule: the far corner reads what the tile beside the
	## heater does. NAN until the climate tick seeds it, so a room
	## born mid-winter starts at ambient rather than 0°.
	var temperature := NAN
	## Boundary thermal bookkeeping — rebuilt lazily like beauty.
	## Each entry is {rate, mode, room}: how much of the gap to the
	## face's target closes per second, what the target is
	## (TARGET_OUTDOOR / TARGET_MEAN / TARGET_ROOM), and the room a
	## TARGET_ROOM face sees.
	var boundary: Array = []
	var boundary_stale := true


## Boundary target modes — what a face's conductance pulls toward.
enum { TARGET_OUTDOOR, TARGET_MEAN, TARGET_ROOM }

## How deep into a wall a face probes for the space beyond — the
## two-layer cap plus a margin so a door-thick wall still finds its
## far side. Material never enters into it.
const WALL_PROBE := 4


var world: VoxelWorld
var colony: Colony

var _room_of: Dictionary = {}
var _rooms: Array[Room] = []

## Temperatures inherited across a topology change — cell → °C of the
## room it belonged to before `invalidate`. A room rebuilt over the
## same ground keeps its warmth rather than snapping to ambient.
var _carry_temp: Dictionary = {}

## Wall cells already classified as buried-or-not — the column walk
## and the exposure probe are the expensive parts of the boundary
## pass, so they memoize until the next invalidate.
var _deep_cache: Dictionary = {}


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony


## Whether [param cell] is open for room purposes: air, editable, and
## not claimed by a sealing building — a hung door leaf is the wall
## segment it fills (RimWorld's closed-door rule), and a cooler's
## machine body seals the gap it sits in, which is what lets it hold
## a cold room against a hot one.
func open_cell(cell: Vector3i) -> bool:
	if not world.is_editable(cell):
		return false
	if world.get_block(cell) != Blocks.AIR:
		return false
	var building := colony.building_at(cell)
	if building != null and (
		building.kind == Building.Kind.DOOR
		or building.kind == Building.Kind.COOLER
	):
		return false
	return true


## The room containing [param cell], or null when the cell isn't open
## or its component leaks to the loaded edge / past the size cap.
func room_at(cell: Vector3i) -> Room:
	if _room_of.has(cell):
		return _room_of[cell]
	if not open_cell(cell):
		return null
	var queue: Array[Vector3i] = [cell]
	var visited: Dictionary = {cell: true}
	var leaked := false
	while not queue.is_empty():
		var at: Vector3i = queue.pop_back()
		if visited.size() > MAX_ROOM_CELLS:
			leaked = true
			break
		for dir in Flooring.FACE_DIRS:
			var next := at + dir
			if visited.has(next):
				continue
			if not world.is_editable(next):
				leaked = true
				continue
			if not open_cell(next):
				continue
			visited[next] = true
			queue.append(next)
	if leaked:
		# Remember every visited cell as outside — the next unit over
		# reads the answer from the cache instead of re-flooding. When the
		# table is already full, cache only the asked cell: the flood is
		# capped at MAX_ROOM_CELLS either way, so a re-scan stays cheap.
		if _room_of.size() + visited.size() <= MAX_CACHE_CELLS:
			for seen: Vector3i in visited:
				_room_of[seen] = null
		else:
			_room_of[cell] = null
		return null
	var room := Room.new()
	room.cells = visited
	_rooms.append(room)
	for seen: Vector3i in visited:
		_room_of[seen] = room
	return room


## The room's beauty score: the mean per-exposed-face value of its
## inner surfaces — floors, walls, ceilings and door leaves — plus the
## beauty of the furnishings standing in its cells. Faces shared with
## another open cell aren't surfaces and don't count; a covered face
## reads its covering's value, a bare one the block's. Cached until a
## covering or furnishing edit stales it.
func score(room: Room) -> float:
	if not room.beauty_stale:
		return room.beauty
	var sum := 0.0
	var faces := 0
	for cell: Vector3i in room.cells:
		for face in Flooring.FACE_DIRS.size():
			var dir: Vector3i = Flooring.FACE_DIRS[face]
			var neighbor := cell + dir
			var building := colony.building_at(neighbor)
			if world.is_solid(neighbor):
				sum += colony.flooring.face_beauty(cell, face)
				faces += 1
			elif building != null and (
				building.kind == Building.Kind.DOOR
				or building.kind == Building.Kind.COOLER
			):
				# A door leaf or a cooler's housing is a face of the
				# room too — its beauty is the building's own.
				sum += building.beauty
				faces += 1
			elif not open_cell(neighbor):
				# A face against a non-open cell that isn't solid —
				# unloaded edge or a leaf it doesn't dress. No surface,
				# no contribution.
				pass
		var furnishing := colony.building_at(cell)
		if furnishing != null and furnishing.beauty != 0.0:
			sum += furnishing.beauty
	room.beauty = sum / maxf(1.0, float(faces))
	room.beauty_stale = false
	return room.beauty


## The cells of every room currently cached — the climate tick walks
## this to move heat. Cheap alias: the room records already exist.
func all_rooms() -> Array[Room]:
	return _rooms


## The room's heat capacity — its volume in cubic metres, one cell
## each. Named once so the tick and the device math agree.
func volume_of(room: Room) -> float:
	return float(room.cells.size())


## Rebuild a room's boundary conductance table — the perimeter-leak
## model, adapted to six directions. Each boundary face earns one
## entry: doors leak a little toward whatever's on their far side,
## walls leak toward the space beyond them (halved past one layer of
## thickness, capped — a third layer buys nothing, and the wall's
## material never matters), buried walls pull toward the biome mean,
## and genuinely open faces — a hole where the flood met unloaded or
## outdoor air — equalize fast. Corner faces never count: heat flows
## in the six cardinal directions only.
func _analyze_boundary(room: Room) -> void:
	room.boundary.clear()
	for cell: Vector3i in room.cells:
		for dir in Flooring.FACE_DIRS:
			var next := cell + dir
			if room.cells.has(next):
				continue
			var building := colony.building_at(next)
			if world.is_solid(next):
				room.boundary.append(_wall_face(cell, dir, next))
			elif building != null and (
				building.kind == Building.Kind.DOOR
				or building.kind == Building.Kind.COOLER
			):
				# A sealed face that isn't terrain — the leaf or the
				# machine housing. Beyond it sits another room or the
				# outdoors; a door breathes, a housing barely does.
				var rate := (
					colony.TEMP_LEAK_DOOR
					if building.kind == Building.Kind.DOOR
					else colony.TEMP_LEAK_WALL
				)
				room.boundary.append({
					&"rate": rate,
					&"mode": TARGET_ROOM,
					&"room": room_at(next + dir),
				})
			elif open_cell(next):
				# Shouldn't happen — the flood takes every open cell
				# it can reach — but a changed cache mid-tick can hand
				# one over; equalize to it or the sky.
				room.boundary.append({
					&"rate": colony.TEMP_LEAK_OPEN,
					&"mode": TARGET_ROOM,
					&"room": room_at(next),
				})
	room.boundary_stale = false


## One wall face's conductance entry: the probe walks the face's
## direction for the first open cell past the wall — that's the space
## the face leaks toward (a room or the outdoors), and the layers
## crossed to reach it set the rate: one layer leaks, two halve it,
## and past two nothing more is gained. No open cell within the probe
## depth means deep ground — a buried wall — which pulls toward the
## biome mean instead of leaking at all.
func _wall_face(cell: Vector3i, dir: Vector3i, wall: Vector3i) -> Dictionary:
	var layers := 0
	var probe := wall
	for i in WALL_PROBE:
		if world.is_solid(probe):
			layers += 1
			probe += dir
			continue
		var building := colony.building_at(probe)
		if building != null and (
			building.kind == Building.Kind.DOOR
			or building.kind == Building.Kind.COOLER
		):
			layers += 1
			probe += dir
			continue
		if open_cell(probe):
			return {
				&"rate": (
					colony.TEMP_LEAK_WALL if layers <= 1
					else colony.TEMP_LEAK_WALL_DEEP
				),
				&"mode": TARGET_ROOM,
				&"room": room_at(probe),
			}
		# Uneditable — treat it as wall material and keep walking.
		layers += 1
		probe += dir
	if _deep_wall(wall, cell):
		return {&"rate": colony.TEMP_DEEP_PULL, &"mode": TARGET_MEAN, &"room": null}
	return {
		&"rate": colony.TEMP_LEAK_WALL_DEEP,
		&"mode": TARGET_OUTDOOR,
		&"room": null,
	}


## Whether [param wall] reads as buried structure — the room face of
## an underground wall: not exposed to the outdoors on any side (every
## open neighbour belongs to some room) and part of an unbroken
## vertical column of solid cells to the world's bottom. Underground
## walls are why a mountain room drifts to the biome mean.
func _deep_wall(wall: Vector3i, room_cell: Vector3i) -> bool:
	if _deep_cache.has(wall):
		return _deep_cache[wall]
	var deep := true
	# Exposure: any open neighbour that is outdoor air disqualifies —
	# a face of the wall touches the sky's weather.
	for dir in Flooring.FACE_DIRS:
		var side := wall + dir
		if side == room_cell:
			continue
		if open_cell(side) and room_at(side) == null:
			deep = false
			break
	# The column: solid all the way down to bedrock — the world's
	# uneditable floor. One open cell breaks it.
	if deep:
		var probe := wall + Vector3i.DOWN
		while world.is_editable(probe):
			if not world.is_solid(probe):
				deep = false
				break
			probe += Vector3i.DOWN
	_deep_cache[wall] = deep
	return deep


## The temperature at [param cell] — the room's one temperature when
## it's enclosed air, the outdoor ambient otherwise. [param outdoor_c]
## comes in so callers holding the weather value don't re-derive it.
func temperature_at(cell: Vector3i, outdoor_c: float) -> float:
	var room := room_at(cell)
	if room == null or is_nan(room.temperature):
		return outdoor_c
	return room.temperature


## The temperature a fresh room inherits — the carried warmth of the
## cells it now covers from before the last topology change, else NAN
## so the tick seeds ambient.
func _carried_temperature(room: Room) -> float:
	var sum := 0.0
	var n := 0
	for cell: Vector3i in room.cells:
		if _carry_temp.has(cell):
			sum += float(_carry_temp[cell])
			n += 1
	if n > 0:
		# Spent — a carried degree warms exactly one re-flooded room.
		for cell: Vector3i in room.cells:
			_carry_temp.erase(cell)
		return sum / n
	return NAN


## One climate tick over every cached room: seed fresh rooms (carried
## warmth first, ambient after), then walk each boundary's
## conductance entries and move a fraction of every gap. The sum is
## volume-damped — a ballroom's perimeter moves its air slower than a
## closet's, which is the heat-capacity half of the spec.
func tick_temperature(elapsed: float, outdoor_c: float, mean_c: float) -> void:
	for room in _rooms:
		if is_nan(room.temperature):
			room.temperature = _carried_temperature(room)
			if is_nan(room.temperature):
				room.temperature = outdoor_c
		if room.boundary_stale:
			_analyze_boundary(room)
		var d := 0.0
		for face: Dictionary in room.boundary:
			var target := outdoor_c
			match int(face[&"mode"]):
				TARGET_MEAN:
					target = mean_c
				TARGET_ROOM:
					var other: Room = face[&"room"]
					target = (
						other.temperature
						if other != null and not is_nan(other.temperature)
						else outdoor_c
					)
			d += float(face[&"rate"]) * (target - room.temperature)
		# Heat capacity: the boundary's flow divides by the room's
		# volume — a ballroom's perimeter moves its air slower than a
		# closet's, which is the surface-to-volume half of the model.
		room.temperature += d * elapsed / maxf(1.0, volume_of(room))


## Topology change — a block moved or a door appeared/vanished. Every
## cached answer may differ; rooms themselves are rebuilt on demand.
## Room warmth carries: the cells each doomed room covered keep its
## temperature so the re-flooded room standing on the same ground
## inherits it rather than snapping to ambient.
func invalidate() -> void:
	for room in _rooms:
		if not is_nan(room.temperature):
			for cell: Vector3i in room.cells:
				_carry_temp[cell] = room.temperature
	_room_of.clear()
	_rooms.clear()
	_deep_cache.clear()
	# The carry table can't outlive its use — once the map's warmed
	# regions have re-flooded, stale cells would mislead. Pruning to
	# the entries a rebuilt room consumes happens in tick; bound the
	# table here so a demolished site doesn't accumulate forever.
	if _carry_temp.size() > MAX_ROOM_CELLS * 4:
		_carry_temp.clear()


## Cosmetic change — coverings or furnishings edited. The components
## stand; only their scores recompute.
func invalidate_beauty() -> void:
	for room in _rooms:
		room.beauty_stale = true
