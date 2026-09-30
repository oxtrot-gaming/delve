class_name Plants
extends Node

## Small plants: single-cell decorations like the forest's saplings —
## a bush occupies one air voxel over solid ground, blocks nothing, and
## carries a forageable yield (berries for now). The forest's model is
## the precedent: the cell stays [constant BlockRegistry.Block.AIR], the
## plant exists as a record plus a [MultiMeshInstance3D] box.
##
## Unlike trees, forageables aren't felled — a forage takes the ripe
## yield and the bush regrows on a timer. Plants seeded by the terrain
## generator start at mixed ripeness, the same mixed-age rule trees
## follow.

const Resource_ := BlockRegistry.Resource_

## Species table — the structure a small plant needs: its colours, what
## a forage yields and how long the bush takes to bear again. `annual`
## crops die to their harvest — the plant itself is pulled up with the
## yield, so a field has to be re-sown; perennials (absent flag) bear
## again on the regrow clock. `yield_volume` is cm³ for a loose yield;
## for a discrete `yield_form` it is the item count instead.
const SPECIES: Dictionary = {
	&"berry_bush": {
		&"name": "Berry Bush",
		&"bush_color": Color(0.20, 0.42, 0.16),
		&"ripe_color": Color(0.66, 0.24, 0.18),
		&"yield_material": Resource_.BERRY,
		# Whole berries — a fruit is discrete (extract-seed's input form);
		# a dozen of them is the same ~0.3 m³ the bulk yield gave.
		&"yield_form": DropItem.Form.FRUIT,
		&"yield_volume": 12,
		&"forage_seconds": 3.0,
		&"annual": false,
		# Game seconds — 0.675 days. A harvest restores ~1.35
		# colonist-days of hunger, so one bush sustainably feeds ~2.
		&"regrow_seconds": 162.0,
	},
	# The first annual: a staple grain that dies to its harvest. The
	# yield is a handful of grain heads — edible like any grain, and
	# seed-bearing: the extract-seed craft threshes one head into two
	# wheat seed packets, which is how a wheat field re-sows itself.
	&"wheat": {
		&"name": "Wheat",
		&"bush_color": Color(0.55, 0.55, 0.25),
		&"ripe_color": Color(0.85, 0.70, 0.28),
		&"yield_material": Resource_.GRAIN,
		&"yield_form": DropItem.Form.FRUIT,
		# Six heads — the plant itself is consumed with the harvest.
		&"yield_volume": 6,
		&"forage_seconds": 3.0,
		&"annual": true,
		# Game seconds to mature from sowing — four days.
		&"regrow_seconds": 960.0,
	},
}

var world: VoxelWorld
var colony: Colony

## root voxel → {species, ripe, next}: the bush's record — whether it
## currently bears its yield, and when an empty bush bears again.
var bushes: Dictionary = {}
## Bush cells → their root. One cell per bush today; the index is the
## O(1) answer to [method bush_at].
var _index: Dictionary = {}
## Generated bush slots whose plant was destroyed — the generator's
## lattice is deterministic, so without this a mined-out bush would
## respawn the moment its data block streams back in.
var _destroyed: Dictionary = {}

## Side length of the bush box — smaller than a voxel.
const BUSH_SIZE := 0.65

var _bush_instances: MultiMeshInstance3D
var _decorations_dirty := false
## Staleness sweep clock — dug-out or built-over cells are noticed here
## too, not only when something asks [method bush_at] about them.
var _validate_elapsed := 0.0


func setup(p_world: VoxelWorld, p_colony: Colony) -> void:
	world = p_world
	colony = p_colony
	_bush_instances = _make_decoration(_box(BUSH_SIZE))
	world.block_loaded.connect(_on_block_loaded)


func _process(delta: float) -> void:
	var now := (
		colony.game_msec() if colony != null else Time.get_ticks_msec()
	)
	_validate_elapsed += delta
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		if not rec[&"ripe"] and now >= int(rec[&"next"]):
			rec[&"ripe"] = true
			_decorations_dirty = true
	if _validate_elapsed >= 1.0:
		_validate_elapsed = 0.0
		var stale: Array[Vector3i] = []
		for root: Vector3i in bushes:
			if (
				world.get_block(root) != BlockRegistry.Block.AIR
				or not world.is_solid(root + Vector3i.DOWN)
			):
				stale.append(root)
		for root in stale:
			bush_at(root)  # forgets the record and tombstones the slot
	if _decorations_dirty:
		_refresh_decorations()


## The root voxel of the bush at [param voxel_position], or
## [constant Vector3i.MAX]. Stale records — a cell built into or dug out
## from under — are noticed and dropped here.
func bush_at(voxel_position: Vector3i) -> Vector3i:
	var root: Vector3i = _index.get(voxel_position, Vector3i.MAX)
	if root == Vector3i.MAX or not bushes.has(root):
		return Vector3i.MAX
	if (
		world.get_block(root) != BlockRegistry.Block.AIR
		or not world.is_solid(root + Vector3i.DOWN)
	):
		_forget(root)
		_destroyed[root] = true
		return Vector3i.MAX
	return root


## True when the bush at [param root] is ripe and can be foraged.
func can_forage(root: Vector3i) -> bool:
	var rec: Dictionary = bushes.get(root, {})
	return not rec.is_empty() and bool(rec[&"ripe"])


## Seconds of unit labour a forage on [param root]'s bush takes.
func forage_work(root: Vector3i) -> float:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty():
		return 0.0
	return float(SPECIES[rec[&"species"]][&"forage_seconds"])


## Takes the bush's yield: returns the items a forage drops (the caller
## spills them into the world) and starts the regrow timer. An annual
## comes up whole — the harvest destroys the plant. Empty for a bush
## that isn't ripe.
func forage(root: Vector3i) -> Array[DropItem]:
	var rec: Dictionary = bushes.get(root, {})
	if rec.is_empty() or not bool(rec[&"ripe"]):
		return []
	var sp: Dictionary = SPECIES[rec[&"species"]]
	if sp.get(&"annual", false):
		# The plant comes up whole — and if it stood on a generated
		# slot, the tombstone keeps a stream-in from regrowing it.
		_forget(root)
		_destroyed[root] = true
	else:
		rec[&"ripe"] = false
		rec[&"next"] = colony.game_msec() + int(
			float(sp[&"regrow_seconds"]) * 1000.0
		)
	_decorations_dirty = true
	var form: DropItem.Form = sp.get(&"yield_form", DropItem.Form.LOOSE)
	var drops: Array[DropItem] = []
	if form == DropItem.Form.LOOSE:
		drops.append(
			DropItem.new(sp[&"yield_material"], form, int(sp[&"yield_volume"]))
		)
	else:
		# Discrete yields count items — wheat drops whole grain heads.
		for i in int(sp[&"yield_volume"]):
			drops.append(
				DropItem.new(sp[&"yield_material"], form, DropItem.form_volume(form))
			)
	return drops


## Whether a generated slot starts ripe — deterministic off the root, so
## a reloaded slot reseeds identically. Two thirds bear immediately: a
## fresh world has food to forage without waiting out a regrow.
func seeded_ripe(root: Vector3i) -> bool:
	return _hash(root, 491) % 3 != 0


func _hash(root: Vector3i, salt: int = 0) -> int:
	return hash(Vector4i(root.x, root.y, root.z, salt)) & 0x7fffffff


## Plants an immature bush at [param root] — the decay-sprout path.
## False when the cell can't host one (claimed, non-air, no ground).
func plant(root: Vector3i, species: StringName) -> bool:
	if not SPECIES.has(species) or _index.has(root):
		return false
	if world.get_block(root) != BlockRegistry.Block.AIR:
		return false
	if not world.is_solid(root + Vector3i.DOWN):
		return false
	_register(root, species, false)
	return true


## Registers a bush record for the plant at [param root].
func _register(root: Vector3i, species: StringName, ripe: bool) -> void:
	var sp: Dictionary = SPECIES[species]
	var jitter := _hash(root, 223) % 1000
	var delay := int(
		float(sp[&"regrow_seconds"]) * 1000.0 * (0.5 + jitter / 1000.0)
	)
	bushes[root] = {
		&"species": species,
		&"ripe": ripe,
		# Unripe seeded bushes bear soon rather than on a full regrow.
		&"next": colony.game_msec() + delay,
	}
	_index[root] = root
	_decorations_dirty = true


## Drops a bush's record without touching the world.
func _forget(root: Vector3i) -> void:
	_index.erase(root)
	bushes.erase(root)
	_decorations_dirty = true


## Bush slots seeded by the terrain generator are discovered as their
## data blocks stream in — the bush cell is air over grass at
## surface_height + 1. [member _destroyed] keeps a mined-out slot from
## reseeding on reload.
func _on_block_loaded(block_origin: Vector3i) -> void:
	var base := block_origin * 16
	var generator := world.generator_script
	# Bushes sit one voxel above the surface — a block outside that band
	# holds none, so the lattice scan is skipped outright.
	if (
		base.y > generator.max_surface_height() + 1
		or base.y + 16 <= generator.min_surface_height() + 1
	):
		return
	var slots: Dictionary = generator.bushes_in(base, 16)
	for pos: Vector2i in slots:
		var voxel := Vector3i(
			pos.x, generator.surface_height(pos.x, pos.y) + 1, pos.y
		)
		if _destroyed.has(voxel) or _index.has(voxel):
			continue
		if world.get_block(voxel) != BlockRegistry.Block.AIR:
			continue  # somebody dug or built here since generation
		_register(voxel, slots[pos], seeded_ripe(voxel))


## Redraws the bush multimesh from current records — ripe bushes tint
## toward their fruit colour so a forageable plant reads at a glance.
func _refresh_decorations() -> void:
	_decorations_dirty = false
	var mm := _bush_instances.multimesh
	mm.instance_count = bushes.size()
	var i := 0
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		mm.set_instance_transform(
			i,
			Transform3D(Basis(), Vector3(root) + Vector3(0.5, 0.35, 0.5))
		)
		var sp: Dictionary = SPECIES.get(rec[&"species"], {})
		mm.set_instance_color(
			i,
			Color(
				sp.get(
					&"ripe_color" if rec[&"ripe"] else &"bush_color",
					Color(0.3, 0.5, 0.2)
				)
			)
		)
		i += 1


## One multimesh drawing a decoration mesh once per tracked voxel —
## same construction the forest decorations use.
func _make_decoration(mesh: Mesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.custom_aabb = AABB(
		Vector3(-8192, -512, -8192), Vector3(16384, 1024, 16384)
	)
	var instances := MultiMeshInstance3D.new()
	instances.multimesh = mm
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.9
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	instances.material_override = material
	instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instances)
	return instances


func _box(size: float) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	return mesh


## Save records: bushes as [root, species, ripe, next] rows plus the
## generated-slot tombstones — a destroyed slot must stay dead across a
## reload just like a re-stream.
func serialize() -> Dictionary:
	var list: Array = []
	for root: Vector3i in bushes:
		var rec: Dictionary = bushes[root]
		list.append([
			root.x, root.y, root.z,
			String(rec[&"species"]), bool(rec[&"ripe"]), int(rec[&"next"]),
		])
	var destroyed_list: Array = []
	for root: Vector3i in _destroyed:
		destroyed_list.append([root.x, root.y, root.z])
	return {"bushes": list, "destroyed": destroyed_list}


## Replaces live state wholesale — the colony clears before loading.
func deserialize(data: Dictionary) -> void:
	bushes.clear()
	_index.clear()
	_destroyed.clear()
	for e: Array in data.get("bushes", []):
		var root := Vector3i(int(e[0]), int(e[1]), int(e[2]))
		bushes[root] = {
			&"species": StringName(e[3]),
			&"ripe": bool(e[4]),
			&"next": int(e[5]),
		}
		_index[root] = root
	for e: Array in data.get("destroyed", []):
		_destroyed[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = true
	# Paint now rather than flagging for _process — a paused game never
	# ticks, so a flagged load would stay invisible until unpause.
	_refresh_decorations()
