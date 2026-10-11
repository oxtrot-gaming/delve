class_name SliceView
extends Node3D

## Timberborn-style layer view: a world-space clip plane that discards
## every fragment above a y level, letting the player look into caves,
## buried rooms and anything under a roof. The cut is carried by one
## global shader parameter — every world material (terrain, water,
## decorations, piles) is built through the static factories here so the
## whole scene slices with a single `global_shader_parameter_set`.
##
## Hidden voxels still exist — they keep colliding and keep shading the
## cells beneath them out of the mesher's face list, which would leave
## the cut reading hollow. The cap mesh fixes that: one quad under the
## cut plane for every column whose voxel AT the level is solid AND
## whose voxel ABOVE is solid — the cells whose real top face the
## mesher culled. Cells open above keep their own rendered face (a cap
## under it would be a near-coplanar duplicate — z-fighting), and cells
## open at the level show the floors and walls below through the gap.
## Solidity comes from the sim's
## probe_block so unstreamed columns answer through the generator —
## the plan covers the whole field, not just the materialized part.
##
## Controls (Overseer): PgDn lowers the cut a layer, PgUp raises it;
## raising back to the level where slicing began exits the view. While
## slicing, aim raycasts start where the ray crosses the plane so
## designations can only land on cells that actually render.

## Global shader parameter carrying the cut plane (world y). Materials
## discard fragments above it; far past terrain top means "slicing off".
const PARAM := "delve_slice_y"
## Off-value — comfortably above anything the generator emits.
const SLICE_OFF := 1.0e6

## Columns per cap tile side — matches the decoration column-chunks.
const TILE := 16
## Tile builds per frame at most — entering the view spreads the scan
## over frames rather than hitching once.
const MAX_REBUILDS := 48
## Cap rebuilds also yield after this much frame time — tiles over
## unmaterialized chunks pay a generator query per column, so a raw
## tile count could still spike a frame.
const MAX_REBUILD_US := 4000
## Cap tiles build only this far around the camera focus — the site
## field is far bigger than any viewport, so the cut scans what the
## player can actually see and follows them as they pan.
const CAP_RADIUS := 320
## The cap rides this far under the plane. It must clear the
## decorations that nudge quads off their backing face (floor slabs sit
## at face-0.02) while staying under the water skin's tops (~0.94 of
## the cell) so a submerged cross-section still reads as water.
const CAP_EPS := 0.10
## Cross-sections shade dimmer than natural faces so the flat plan
## doesn't read as surface terrain.
const CAP_DIM := 0.82

var _world: VoxelWorld
## Tile extents from the installed site — cap tiles seed lazily inside.
var _bounds: Rect2i  # installed for callers; the cap builds everywhere
## tile Vector2i → MeshInstance3D
var _tiles: Dictionary = {}
var _pending: Dictionary = {}
## Near-first tile seed order around the focus — recomputed only when
## the focus tile changes (the sort over ~1.7k tiles is ~5ms).
var _order: Array[Vector2i] = []
var _order_focus := Vector2i(1 << 30, 1 << 30)
## Tiles already scanned at the CURRENT level — a level move clears
## the set so near tiles re-scan.
var _built: Dictionary = {}
## The node the cut follows — main assigns the Overseer.
var focus: Node3D
## Highest visible voxel y while slicing, -1 while the view is off.
var top_layer := -1
## The level the view opened at — raising the cut back to it exits.
var _home := -1

func _enter_tree() -> void:
	visible = false
	# Presentation follows the camera while the sim is paused —
	# designations and slice pans still land, so cap rebuilds must
	# too (same reason the terrain streamer is ALWAYS).
	process_mode = Node.PROCESS_MODE_ALWAYS


## The cut parameter is declared in project.godot [shader_globals] —
## it exists from boot, so factories only ever set it, never add it.
## (global_shader_parameter_get_list is editor-only and errors when
## called at runtime; add errors on an existing name.)
func is_active() -> bool:
	return top_layer >= 0


## The world-space plane height — the top of the highest visible voxel.
func plane() -> float:
	return float(top_layer) + 1.0


func install(field: SiteField, world: VoxelWorld) -> void:
	_world = world
	_bounds = Rect2i(
		field.origin, Vector2i.ONE * field.side * field.cell_m
	)
	if not world.block_edited.is_connected(_on_block_edited):
		world.block_edited.connect(_on_block_edited)


## Moves the cut. [param seed_level] is the voxel layer to open at —
## the ground under the camera focus. Lowering from off opens the view
## one layer under the seed; raising back to the seed closes it.
func adjust(direction: int, seed_level: int) -> void:
	if not is_active():
		if direction >= 0:
			return
		_home = seed_level
		_set_level(maxi(seed_level - 1, 0))
		return
	var next := top_layer + direction
	_set_level(next if next < _home else -1)


func _set_level(layer: int) -> void:
	top_layer = layer
	if layer < 0:
		RenderingServer.global_shader_parameter_set(PARAM, SLICE_OFF)
		visible = false
		_pending.clear()
		return
	RenderingServer.global_shader_parameter_set(PARAM, float(layer) + 1.0)
	visible = true
	# Every cap is stale at the new level — near tiles re-scan.
	_built.clear()


func _process(_delta: float) -> void:
	if not is_active() or _world == null:
		return
	# Keep the cut seeded around the focus, nearest tiles first — the
	# player reads the ground they're standing over before the horizon,
	# and a level move fills the centre before the rim.
	if focus != null:
		var ft := Vector2i(
			floori(focus.global_position.x) >> 4,
			floori(focus.global_position.z) >> 4
		)
		# The near-first seed order only changes when the focus crosses
		# a tile boundary — recomputing the sort every frame costs ~5ms
		# for nothing.
		if ft != _order_focus:
			_order_focus = ft
			var rt := ceili(CAP_RADIUS / float(TILE))
			_order.clear()
			for dz in range(-rt, rt + 1):
				for dx in range(-rt, rt + 1):
					# Cap tiles self-answer solidity through probe_block —
					# no streaming dependency, so out-of-site tiles build
					# the same generated cross-section the terrain shows.
					_order.append(Vector2i(ft.x + dx, ft.y + dz))
			_order.sort_custom(
				func(a: Vector2i, b: Vector2i) -> bool:
					return a.distance_squared_to(ft) < b.distance_squared_to(ft)
			)
		for tile in _order:
			if not _built.has(tile):
				_pending[tile] = true
		# Drop cap nodes and stale queue entries the focus has left
		# behind — panning without eviction would retain every visited
		# tile's mesh and scan job forever.
		var evict_t := CAP_RADIUS / float(TILE) + 2.0
		var gone: Array[Vector2i] = []
		for t: Vector2i in _tiles:
			if Vector2(t).distance_squared_to(Vector2(ft)) > evict_t * evict_t:
				gone.append(t)
		for t: Vector2i in _pending:
			if Vector2(t).distance_squared_to(Vector2(ft)) > evict_t * evict_t:
				gone.append(t)
		for t in gone:
			var inst: MeshInstance3D = _tiles.get(t)
			if inst != null:
				inst.queue_free()
			_tiles.erase(t)
			_pending.erase(t)
			_built.erase(t)
	var built := 0
	var deadline := Time.get_ticks_usec() + MAX_REBUILD_US
	for tile: Vector2i in _pending.keys():
		if built >= MAX_REBUILDS or Time.get_ticks_usec() >= deadline:
			break
		_pending.erase(tile)
		_rebuild_tile(tile)
		_built[tile] = true
		built += 1


func _on_block_edited(voxel: Vector3i, _block_id: int) -> void:
	if is_active() and voxel.y == top_layer:
		var tile := Vector2i(voxel.x >> 4, voxel.z >> 4)
		_pending[tile] = true
		_built.erase(tile)


## Lays the cap quads of one 16×16 tile: the cut's cross-section through
## solid columns, nothing where the level is open. Solidity comes from
## the sim — it answers materialized chunks from data and everything
## else from the generator, so the plan never has "unloaded" holes.
func _rebuild_tile(tile: Vector2i) -> void:
	var inst: MeshInstance3D = _tiles.get(tile)
	if inst == null:
		inst = MeshInstance3D.new()
		inst.mesh = ArrayMesh.new()
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.custom_aabb = AABB(
			Vector3(-8192, -512, -8192), Vector3(16384, 1024, 16384)
		)
		add_child(inst)
		_tiles[tile] = inst
	inst.position = Vector3(tile.x * TILE, 0, tile.y * TILE)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := plane() - CAP_EPS
	var ox: int = tile.x * TILE
	var oz: int = tile.y * TILE
	var quads := 0
	# probe_block answers materialized chunks from data and everything
	# else from the generator — a stale binary falls back to data-only
	# queries, which still draw the streamed field correctly.
	var sim: Object = _world.sim
	var probe: bool = sim != null and sim.has_method(&"probe_block")
	for dz in TILE:
		for dx in TILE:
			var pos := Vector3i(ox + dx, top_layer, oz + dz)
			var block_id := 0
			if probe:
				block_id = int(sim.probe_block(pos))
			elif _world.is_editable(pos):
				block_id = _world.get_block(pos)
			if block_id == BlockRegistry.Block.AIR:
				continue
			# The cap exists only to replace a top face the mesher
			# culled — that's every cell whose voxel ABOVE is solid.
			# When the cell above is open, the real face renders at
			# the plane; a cap under it is a near-coplanar duplicate
			# and the pair z-fights at grazing angles.
			var above := 0
			if probe:
				above = int(sim.probe_block(pos + Vector3i.UP))
			elif _world.is_editable(pos + Vector3i.UP):
				above = _world.get_block(pos + Vector3i.UP)
			if above == BlockRegistry.Block.AIR:
				continue
			var color: Color = BlockRegistry.block_color(block_id) * CAP_DIM
			color.a = 1.0
			st.set_color(color)
			var a := Vector3(dx, y, dz)
			var b := Vector3(dx, y, dz + 1)
			var c := Vector3(dx + 1, y, dz + 1)
			var d := Vector3(dx + 1, y, dz)
			# Godot's front face is the CW side — emit the winding that
			# reads front-side from above or every quad culls out.
			for v in [a, c, b, a, d, c]:
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
			quads += 1
	inst.mesh.clear_surfaces()
	if quads > 0:
		st.index()
		inst.mesh = st.commit()
		inst.mesh.surface_set_material(0, _cap_mat())


## Opaque per-colour material — terrain blocks, packed piles. The
## loaded shaders ride the resource cache — nothing lives in statics.
static func opaque(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_opaque.gdshader")
	material.set_shader_parameter(&"albedo", color)
	return material


## Vertex-colour albedo — the decoration multimeshes carry their palette
## in the mesh (grass shades, leaf tones, floor coverings, cap quads).
static func vcolor() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_vcolor.gdshader")
	return material


## The cap's own material — vertex colour like the decorations but
## unshadowed: a site-wide flat plane receiving sun shadows at grazing
## angles would grow acne speckle, and a cross-section reads better
## flat and diagrammatic anyway.
static func _cap_mat() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_cap.gdshader")
	return material


## Translucent per-colour material — the water skin.
static func alpha(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/slice_alpha.gdshader")
	material.set_shader_parameter(&"albedo", color)
	return material
