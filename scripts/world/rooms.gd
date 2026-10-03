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

const Blocks := BlockRegistry.Block


## One bounded component: the cells it spans and the lazily-recomputed
## beauty score. `beauty` is -INF while stale.
class Room:
	var cells: Dictionary = {}
	var beauty := -INF
	var beauty_stale := true


var world: VoxelWorld
var colony: Colony

var _room_of: Dictionary = {}
var _rooms: Array[Room] = []


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony


## Whether [param cell] is open for room purposes: air, editable, and
## not claimed by a door — the only building that seals.
func open_cell(cell: Vector3i) -> bool:
	if not world.is_editable(cell):
		return false
	if world.get_block(cell) != Blocks.AIR:
		return false
	var building := colony.building_at(cell)
	if building != null and building.kind == Building.Kind.DOOR:
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
		# reads the answer from the cache instead of re-flooding.
		for seen: Vector3i in visited:
			_room_of[seen] = null
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
			elif building != null and building.kind == Building.Kind.DOOR:
				# A door leaf is a face of the room too — its beauty is
				# the building's own.
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


## Topology change — a block moved or a door appeared/vanished. Every
## cached answer may differ; rooms themselves are rebuilt on demand.
func invalidate() -> void:
	_room_of.clear()
	_rooms.clear()


## Cosmetic change — coverings or furnishings edited. The components
## stand; only their scores recompute.
func invalidate_beauty() -> void:
	for room in _rooms:
		room.beauty_stale = true
