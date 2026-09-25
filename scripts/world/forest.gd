class_name Forest
extends Node

## Growing trees. Tracks every tree as a record keyed by its root voxel —
## a sapling at first, gaining height on a timer into a trunk with side
## branches and a leaf canopy — and fells them into item drops on a chop
## job.
##
## Only trunks and branches are real voxels (and so block movement).
## Saplings and leaves are decorations: the forest remembers which air
## cells hold them and draws them with [MultiMeshInstance3D]s, but the
## voxel itself stays [constant BlockRegistry.Block.AIR] — pathing,
## reach checks and physics never see them.
##
## Adding a species is a [constant SPECIES] entry plus its blocks — the
## structure builder is shared, parameters differ.

const Blocks := BlockRegistry.Block
const Resource_ := BlockRegistry.Resource_

## Species table. [member Forest._structure] reads these fields:
## the block set, how tall the species gets, the growth pace, where
## branches start and how often they repeat, the decoration colours, the
## work a chop job takes per part, and the drop volumes a felled tree
## yields.
const SPECIES: Dictionary = {
	&"oak": {
		&"name": "Oak",
		&"trunk": Blocks.TRUNK,
		&"branch": Blocks.BRANCH,
		&"leaf_color": Color(0.25, 0.48, 0.18),
		&"sapling_color": Color(0.45, 0.62, 0.25),
		&"max_height": 6,
		&"growth_seconds": 40.0,
		&"branch_min_level": 3,
		&"branch_every": 2,
		&"leaf_work": 0.1,
		&"sapling_work": 0.3,
		&"log_volume": 500_000,
		&"branch_volume": 400_000,
		&"leaf_volume": 50_000,
		&"sapling_volume": 150_000,
	},
}

var world: VoxelWorld
var colony: Colony

## root voxel → {species, height, voxels, next}: the tree's age in trunk
## voxels, every voxel it owns (real blocks and decoration cells), and
## when it next tries to grow.
var trees: Dictionary = {}
## Every voxel belonging to a tree → its root: trunk and branch cells,
## leaf cells and the sapling's cell. Designation and felling resolve
## any tree part through this.
var _index: Dictionary = {}
## Leaf decoration cells → their root. These voxels are AIR in the
## world; they only exist here and in the leaf multimesh.
var _leaves: Dictionary = {}
## Generated sapling slots whose tree was destroyed — the generator's
## lattice is deterministic, so without this a chopped sapling would
## regrow the moment its data block streams back in.
var _destroyed: Dictionary = {}
## Streaming block coord → {root: true}: which trees' roots sit in each
## block. Roots never move, so this only changes on _register and fell —
## it lets the block-loaded restore pass check the 27 blocks a tree could
## reach into instead of scanning every tree voxel ever claimed.
var _block_roots: Dictionary = {}
var _neighbor_deltas: Array[Vector3i] = []

## Side length of a leaf box — smaller than a voxel so canopy cells read
## as foliage clumps rather than solid cubes.
const LEAF_SIZE := 0.7

var _leaf_instances: MultiMeshInstance3D
var _sapling_instances: MultiMeshInstance3D
var _decorations_dirty := false


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony
	_leaf_instances = _make_decoration(_box(LEAF_SIZE))
	_sapling_instances = _make_decoration(_box(0.5))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				_neighbor_deltas.append(Vector3i(dx, dy, dz))
	world.block_loaded.connect(_on_block_loaded)


## Streaming block coord (origin / 16) containing [param voxel].
func _block_of(voxel: Vector3i) -> Vector3i:
	return Vector3i(voxel.x >> 4, voxel.y >> 4, voxel.z >> 4)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for root in trees.keys():
		var rec: Dictionary = trees.get(root, {})
		if rec.is_empty() or now < int(rec[&"next"]):
			continue
		_grow(root)
	if _decorations_dirty:
		_refresh_decorations()


## The root voxel of the tree owning [param voxel_position], or
## [constant Vector3i.MAX]. Works for trunks, branches, leaf cells and
## sapling cells. Stale entries — a mined trunk, a leaf cell that got
## built into — are noticed and dropped here.
func tree_root_at(voxel_position: Vector3i) -> Vector3i:
	var root: Vector3i = _index.get(voxel_position, Vector3i.MAX)
	if root == Vector3i.MAX:
		return Vector3i.MAX
	if not trees.has(root):
		_index.erase(voxel_position)
		_leaves.erase(voxel_position)
		return Vector3i.MAX
	if _leaves.has(voxel_position):
		if world.get_block(voxel_position) == Blocks.AIR:
			return root
		# Something was built into the leaf cell — the leaf is gone.
		_forget(root, voxel_position)
		return Vector3i.MAX
	if world.get_block(voxel_position) == Blocks.AIR and int(trees[root][&"height"]) == 0:
		return root  # the sapling cell itself is air
	if BlockRegistry.is_tree_block(world.get_block(voxel_position)):
		return root
	_forget(root, voxel_position)
	return Vector3i.MAX


## True when [param voxel_position] holds leaf decoration. The voxel
## itself is air — it never blocks anything.
func leaf_at(voxel_position: Vector3i) -> bool:
	return _leaves.has(voxel_position)


## Seconds of unit labour to fell the tree rooted at [param root] — the
## summed hardness of its blocks plus the species' work per leaf and
## sapling.
func tree_work(root: Vector3i) -> float:
	var rec: Dictionary = trees.get(root, {})
	if rec.is_empty():
		return 0.0
	var sp: Dictionary = SPECIES[rec[&"species"]]
	var total := 0.0
	var sapling_cell := root if int(rec[&"height"]) == 0 else Vector3i.MAX
	for voxel: Vector3i in rec[&"voxels"]:
		if _leaves.has(voxel):
			total += float(sp[&"leaf_work"])
		elif voxel == sapling_cell:
			total += float(sp[&"sapling_work"])
		else:
			total += BlockRegistry.hardness(world.get_block(voxel))
	return total


## Plants a sapling of [param species] at [param voxel_position] — needs
## open air over solid ground. The voxel stays air; the sapling is pure
## decoration. Used by world discovery and tests; later also by a
## farming job.
func plant_sapling(voxel_position: Vector3i, species: StringName = &"oak") -> bool:
	var sp: Dictionary = SPECIES.get(species, {})
	if sp.is_empty() or _index.has(voxel_position):
		return false
	if world.get_block(voxel_position) != Blocks.AIR:
		return false
	if not world.is_solid(voxel_position + Vector3i.DOWN):
		return false
	if not world.is_editable(voxel_position):
		return false
	_register(voxel_position, species)
	return true


## One growth step for the tree at [param root] — public so tests can age
## a tree without waiting out the timer.
func grow(root: Vector3i) -> void:
	if trees.has(root):
		_grow(root)


## Brings the whole tree down: every voxel it owns is cleared and its
## contents dropped where they stood — a log per trunk voxel, loose
## branch and leaf material for the rest. Items fall and spill through
## the normal deposit path.
func fell(root: Vector3i) -> void:
	var rec: Dictionary = trees.get(root, {})
	if rec.is_empty():
		return
	var sp: Dictionary = SPECIES[rec[&"species"]]
	var sapling_cell := root if int(rec[&"height"]) == 0 else Vector3i.MAX
	for voxel: Vector3i in rec[&"voxels"]:
		var item: DropItem = null
		if _leaves.has(voxel):
			item = DropItem.new(
				Resource_.LEAF, DropItem.Form.LOOSE, int(sp[&"leaf_volume"])
			)
		elif voxel == sapling_cell:
			item = DropItem.new(
				Resource_.BRANCH, DropItem.Form.LOOSE, int(sp[&"sapling_volume"])
			)
		else:
			var block_id := world.get_block(voxel)
			if block_id == int(sp[&"trunk"]):
				item = DropItem.new(
					Resource_.WOOD, DropItem.Form.LOG, int(sp[&"log_volume"])
				)
			elif block_id == int(sp[&"branch"]):
				item = DropItem.new(
					Resource_.BRANCH, DropItem.Form.LOOSE, int(sp[&"branch_volume"])
				)
			else:
				# The voxel changed hands since the last tick — leave it be.
				_index.erase(voxel)
				continue
			world.remove_voxel(voxel)
			colony._settle_pile_at(voxel + Vector3i.UP)
		_index.erase(voxel)
		_leaves.erase(voxel)
		if item != null:
			colony._drop_item(item, voxel)
	trees.erase(root)
	var bucket: Dictionary = _block_roots.get(_block_of(root), {})
	bucket.erase(root)
	if bucket.is_empty():
		_block_roots.erase(_block_of(root))
	_destroyed[root] = true
	_decorations_dirty = true


## Registers a tree record for the sapling at [param root]. The first
## growth tick is staggered by a hash so a freshly loaded forest doesn't
## grow in lockstep.
func _register(root: Vector3i, species: StringName) -> void:
	var sp: Dictionary = SPECIES[species]
	var jitter := hash(Vector3i(root.x, 0, root.z)) & 0x7fffffff
	var delay := int(
		float(sp[&"growth_seconds"]) * 1000.0
		* (0.5 + float(jitter % 1000) / 1000.0)
	)
	trees[root] = {
		&"species": species,
		&"height": 0,
		&"voxels": [root],
		&"next": Time.get_ticks_msec() + delay,
	}
	_index[root] = root
	_block_roots.get_or_add(_block_of(root), {})[root] = true
	_decorations_dirty = true


## Drops a voxel's claim without touching the world — for cells the
## world changed under us (a mined trunk, a built-in leaf cell).
func _forget(root: Vector3i, voxel_position: Vector3i) -> void:
	_index.erase(voxel_position)
	if _leaves.erase(voxel_position):
		_decorations_dirty = true
	var rec: Dictionary = trees.get(root, {})
	if not rec.is_empty():
		(rec[&"voxels"] as Array).erase(voxel_position)


## The voxels a tree of [param height] should occupy: [code]solid[/code]
## maps voxel → block id (a vertical trunk plus side branches every
## [code]branch_every[/code] levels once tall enough), [code]leaves[/code]
## lists the canopy cells hugging the trunk's top — chosen
## deterministically per level so growth is stable and stunted branches
## stay stunted.
func _structure(root: Vector3i, sp: Dictionary, height: int) -> Dictionary:
	var solid := {}
	var leaves: Array[Vector3i] = []
	for i in height:
		solid[root + Vector3i(0, i, 0)] = int(sp[&"trunk"])
	var sides := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]
	for i in range(int(sp[&"branch_min_level"]), height):
		if (i - int(sp[&"branch_min_level"])) % int(sp[&"branch_every"]) != 0:
			continue
		var side: Vector3i = sides[_hash(root, i) % sides.size()]
		var length := 1 + _hash(Vector3i(i, root.x, root.z)) % 2
		for s in range(1, length + 1):
			var voxel := root + Vector3i(0, i, 0) + side * s
			if not solid.has(voxel):
				solid[voxel] = int(sp[&"branch"])
	# The canopy: short branch arms out of the tip, then a diamond of
	# leaves — a leaf cell is kept only while it face-touches a solid
	# part, so nothing floats detached and nothing sits at ground level.
	var top := root + Vector3i(0, height - 1, 0)
	if height >= 2:
		for side in sides:
			var arm: Vector3i = top + side
			if not solid.has(arm):
				solid[arm] = int(sp[&"branch"])
		var crown := top + Vector3i.UP
		if not solid.has(crown):
			solid[crown] = int(sp[&"branch"])
	var ortho := [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP,
		Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK
	]
	for dx in range(-2, 3):
		for dy in range(-1, 3):
			for dz in range(-2, 3):
				if absi(dx) + absi(dy) + absi(dz) > 2:
					continue
				var voxel := top + Vector3i(dx, dy, dz)
				if voxel.y <= root.y or solid.has(voxel):
					continue
				for side in ortho:
					if solid.has(voxel + side):
						leaves.append(voxel)
						break
	return {&"solid": solid, &"leaves": leaves}


func _hash(root: Vector3i, salt: int = 0) -> int:
	return hash(Vector4i(root.x, root.y, root.z, salt)) & 0x7fffffff


## Ages the tree at [param root]: sheds voxels no longer part of the
## structure and grows into new ones. Solid parts only ever grow into
## open, unoccupied, item-free air — a tree can't swallow terrain, piles
## or a unit; leaf cells just need air and no other tree's claim. A
## missing root means the tree was destroyed outside our control — fell
## whatever remains.
func _grow(root: Vector3i) -> void:
	var rec: Dictionary = trees[root]
	var sp: Dictionary = SPECIES[rec[&"species"]]
	var interval := int(float(sp[&"growth_seconds"]) * 1000.0)
	var now := Time.get_ticks_msec()
	rec[&"next"] = now + interval
	if not world.is_editable(root):
		return
	var height := int(rec[&"height"])
	# The root is air while the tree is still a sapling, trunk afterwards.
	var root_block := Blocks.AIR if height == 0 else int(sp[&"trunk"])
	if world.get_block(root) != root_block:
		fell(root)
		return
	if height >= int(sp[&"max_height"]):
		# Mature — still wake occasionally to shed parts that left the
		# structure and retry cells that were occupied last time.
		_grow_into(root, rec, _structure(root, sp, height))
		rec[&"next"] = now + interval * 8
		return
	height += 1
	rec[&"height"] = height
	if height == 1:
		# The sapling decoration gives way to a real trunk voxel.
		_decorations_dirty = true
	_grow_into(root, rec, _structure(root, sp, height))


## Applies a structure to the tree's owned voxels: sheds what's no longer
## part of it, then claims the new cells — world blocks for the solid
## set, index entries only for the leaf cells.
func _grow_into(root: Vector3i, rec: Dictionary, want: Dictionary) -> void:
	var want_solid: Dictionary = want[&"solid"]
	var want_leaves: Array = want[&"leaves"]
	var leaf_set := {}
	for voxel in want_leaves:
		leaf_set[voxel] = true

	# Shed owned voxels the structure no longer wants, and leaf cells that
	# stopped being air — only a block that is still ours is removed; a
	# replaced or mined voxel is somebody else's business.
	for voxel: Vector3i in (rec[&"voxels"] as Array).duplicate():
		if _leaves.has(voxel):
			if leaf_set.has(voxel) and world.get_block(voxel) == Blocks.AIR:
				continue
			_forget(root, voxel)
			continue
		if want_solid.has(voxel):
			continue
		_index.erase(voxel)
		(rec[&"voxels"] as Array).erase(voxel)
		if BlockRegistry.is_tree_block(world.get_block(voxel)):
			world.remove_voxel(voxel)
			colony._settle_pile_at(voxel + Vector3i.UP)

	for voxel: Vector3i in want_solid:
		var want_id: int = want_solid[voxel]
		var owner: Vector3i = _index.get(voxel, Vector3i.MAX)
		if owner != Vector3i.MAX and owner != root:
			continue  # another tree got there first
		var current := world.get_block(voxel)
		if current == want_id:
			if owner == Vector3i.MAX:
				_index[voxel] = root
				(rec[&"voxels"] as Array).append(voxel)
			continue
		if _leaves.erase(voxel):
			_decorations_dirty = true  # our leaf cell becomes a solid part
		if current == Blocks.AIR:
			if colony.item_pile_at(voxel) != null or _occupied(voxel):
				continue
			if world.place(voxel, want_id):
				_index[voxel] = root
				if owner == Vector3i.MAX:
					(rec[&"voxels"] as Array).append(voxel)
		elif owner == root:
			# Our part was replaced — swap tree blocks, shed anything foreign.
			if BlockRegistry.is_tree_block(current):
				world.remove_voxel(voxel)
				world.place(voxel, want_id)
			else:
				_forget(root, voxel)

	for voxel: Vector3i in want_leaves:
		if _index.has(voxel):
			continue  # already claimed — by us or another tree
		if world.get_block(voxel) != Blocks.AIR or colony.is_packed(voxel):
			continue
		_leaves[voxel] = root
		_index[voxel] = root
		(rec[&"voxels"] as Array).append(voxel)
		_decorations_dirty = true


## True when a unit's capsule — feet voxel plus head voxel — fills
## [param voxel_position]; solid growth won't grow into it.
func _occupied(voxel_position: Vector3i) -> bool:
	for unit in colony.units:
		if unit.occupies(voxel_position):
			return true
	return false


## Saplings seeded by the terrain generator are discovered as their data
## blocks stream in: [param block_origin] is the block's corner in 16³
## blocks. The lattice is deterministic, so [_member _destroyed] keeps a
## felled sapling from coming back on reload.
##
## The same pass restores tree voxels: nothing persists terrain edits
## across streaming, so a regenerated block comes back without the trunks
## and branches the records still claim. Reapplying the structure here —
## before any growth tick can read the gap as a destroyed tree and fell it
## — is what keeps leaves from raining off a canopy that just streamed in.
func _on_block_loaded(block_origin: Vector3i) -> void:
	var base := block_origin * 16
	var generator := world.generator_script
	var saplings: Dictionary = generator.saplings_in(base, 16)
	for pos: Vector2i in saplings:
		var voxel := Vector3i(pos.x, generator.surface_height(pos.x, pos.y) + 1, pos.y)
		if _destroyed.has(voxel) or _index.has(voxel):
			continue
		if world.get_block(voxel) != Blocks.AIR:
			continue  # somebody dug or built here since generation
		_register(voxel, saplings[pos])
	# A tree's voxels stay within a few metres of its root, so only roots
	# in this block or its neighbours can reach inside it.
	var roots := {}
	for d in _neighbor_deltas:
		for root: Vector3i in _block_roots.get(block_origin + d, {}):
			var rec: Dictionary = trees.get(root, {})
			if rec.is_empty() or int(rec[&"height"]) == 0:
				continue
			for voxel: Vector3i in rec[&"voxels"]:
				if (
					voxel.x >= base.x and voxel.x < base.x + 16
					and voxel.y >= base.y and voxel.y < base.y + 16
					and voxel.z >= base.z and voxel.z < base.z + 16
				):
					roots[root] = true
					break
	for root: Vector3i in roots:
		var rec: Dictionary = trees.get(root, {})
		# Height-0 trees are pure sapling decorations — no voxels to
		# restore, and an empty structure would shed their index claim.
		if rec.is_empty() or int(rec[&"height"]) == 0:
			continue
		_grow_into(
			root, rec,
			_structure(root, SPECIES[rec[&"species"]], int(rec[&"height"]))
		)


## Redraws the leaf and sapling multimeshes from the current records —
## batched to once a frame so a streaming burst costs one rebuild.
func _refresh_decorations() -> void:
	_decorations_dirty = false
	var leaf_mm := _leaf_instances.multimesh
	leaf_mm.instance_count = _leaves.size()
	var i := 0
	# Each leaf box hugs the side of its cell nearest a solid part of its
	# tree, so the canopy clings to trunk and branches instead of floating
	# as whole cubes.
	var margin := 0.5 - LEAF_SIZE * 0.5
	for voxel: Vector3i in _leaves:
		var rec: Dictionary = trees.get(_leaves[voxel], {})
		var centre := Vector3(voxel) + Vector3(0.5, 0.5, 0.5)
		leaf_mm.set_instance_transform(
			i,
			Transform3D(
				Basis(), centre + _toward_solid(voxel, rec) * margin
			)
		)
		leaf_mm.set_instance_color(i, _species_color(rec, &"leaf_color"))
		i += 1
	var sapling_mm := _sapling_instances.multimesh
	var sapling_roots: Array[Vector3i] = []
	for root: Vector3i in trees:
		if int(trees[root][&"height"]) == 0:
			sapling_roots.append(root)
	sapling_mm.instance_count = sapling_roots.size()
	i = 0
	for root: Vector3i in sapling_roots:
		sapling_mm.set_instance_transform(
			i, Transform3D(Basis(), Vector3(root) + Vector3(0.5, 0.25, 0.5))
		)
		sapling_mm.set_instance_color(
			i, _species_color(trees[root], &"sapling_color")
		)
		i += 1


## Per-axis sign of the offset to the solid part of [param rec] closest to
## a leaf cell — which way the leaf box leans inside its voxel. Zero when
## the record is gone, which leaves the box centred.
func _toward_solid(voxel: Vector3i, rec: Dictionary) -> Vector3:
	var best := Vector3i.ZERO
	var best_d := 0x7fffffff
	for part: Vector3i in rec.get(&"voxels", []):
		if _leaves.has(part):
			continue
		var d: Vector3i = (part - voxel).abs()
		var md := d.x + d.y + d.z
		if md > 0 and md < best_d:
			best_d = md
			best = part - voxel
	return Vector3(best).sign()


func _species_color(rec: Dictionary, key: StringName) -> Color:
	var sp: Dictionary = SPECIES.get(rec.get(&"species", &""), {})
	return Color(sp.get(key, Color(0.3, 0.5, 0.2)))


## One multimesh drawing a decoration mesh once per tracked voxel.
## [code]use_colors[/code] lets each instance take its species' tint;
## the large custom AABB keeps the whole batch visible.
func _make_decoration(mesh: Mesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.custom_aabb = AABB(Vector3(-8192, -512, -8192), Vector3(16384, 1024, 16384))
	var instances := MultiMeshInstance3D.new()
	instances.multimesh = mm
	instances.material_override = _decoration_material()
	instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instances)
	return instances


func _box(size: float) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	return mesh


static func _decoration_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material
