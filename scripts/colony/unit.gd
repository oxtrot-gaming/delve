class_name Unit
extends CharacterBody3D

## A worker: claims jobs from the [Colony], walks to them over the voxel grid
## and mines. Deliberately small — it is the hook where real AI (needs, skills,
## hauling, sleep schedules) gets added later.

enum State { IDLE, MOVING, WORKING, YIELDING }

const DLog := preload("res://scripts/dlog.gd")

## Skin-tone ramp anchors: pale to dark. Each unit draws a random point
## along the ramp at spawn.
const SKIN_TONE_PALE := Color(0.96, 0.80, 0.66)
const SKIN_TONE_MID := Color(0.55, 0.36, 0.24)
const SKIN_TONE_DARK := Color(0.20, 0.11, 0.07)

@export var move_speed: float = 4.0
## Enough to clear a 1 m step: apex is jump_speed² / (2 × gravity).
@export var jump_speed: float = 7.5
@export var gravity: float = 22.0
## Distance in metres from the unit's centre to a block's nearest face.
@export var mine_reach: float = 1.5
## Hardness points worked through per second.
@export var mining_speed: float = 2.0
## Cubic metres of items shovelled per second — clearing and gathering alike.
@export var clearing_speed: float = 2.0
## Material volume, in cubic centimetres, a unit carries on one trip.
@export var carry_capacity: int = 500_000
## Seconds without getting closer to the job site before the unit drops the
## assignment as unreachable.
@export var stuck_timeout: float = 5.0
## How much closer to the job site, in metres, counts as making progress.
const STUCK_PROGRESS := 0.25
## A* runs per repath, tops. A work spot further down the list is almost
## never the only reachable one, and a capped storm falls back to a
## pile-crossing path — the unit shoves obstructions aside on the way.
const MAX_PATH_ATTEMPTS := 16

var state: State = State.IDLE
var job: ColonyJob = null
## This unit's skin tone: a random point along the pale-to-dark ramp,
## rolled in [method _ready] and applied to the body material.
var skin_tone: Color = SKIN_TONE_MID

var _world: VoxelWorld
var _colony: Colony
var _path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _repath_cooldown: float = 0.0
var _job_search_cooldown: float = 0.0
var _stuck_elapsed: float = 0.0
var _best_goal_distance: float = INF
var _clear_budget: float = 0.0
## What the unit is pathing toward — the job voxel, or for a build fetch the
## dirt pile it's collecting from.
var _goal_voxel: Vector3i = Vector3i.ZERO
## Build/haul phase: true while fetching items, false while delivering.
var _fetching: bool = false
## Items physically carried — loose soil for a build job, pile contents for
## a haul. Dropped where the unit stands if the job is abandoned.
var _carried: Array[DropItem] = []
## Haul targets (source piles or stockpile tiles) that recently failed —
## the unit leaves them alone for a while instead of retrying in a loop.
var _haul_blacklist: Dictionary = {}
## The packed pile blocking the unit's path that it is hauling to a
## stockpile before resuming its job — Vector3i.MAX when not detouring.
var _detour: Vector3i = Vector3i.MAX
## Detour phase: false while heading for the blocking pile, true while
## carrying its contents to the stockpile.
var _detour_delivering := false
## What [member _goal_voxel] was before the detour took it over.
var _detour_return: Vector3i = Vector3i.ZERO
## Seconds spent sidestepping for another unit — yields give up quickly if
## the step-aside spot can't be reached.
var _yield_elapsed: float = 0.0
## Seconds spent waiting for units to clear a build voxel before giving up.
var _evict_elapsed: float = 0.0
## Instance id this unit's kinematic body is registered under in DelveSim.
var _sim_id: int = 0
## Sim/physics motion state — written by _apply_motion, read by the move
## ticks the way is_on_floor()/is_on_wall() used to be.
var _grounded := true
var _blocked_horiz := false
## A move tick's jump request, consumed by the next _apply_motion.
var _want_jump := false


## Cubic metres currently carried.
func _carried_volume() -> int:
	var total := 0
	for item in _carried:
		total += item.volume
	return total


## Shovel budget in cm³ — _clear_budget accrues in m³/s floats; spending
## snaps to integer cm³ so item volumes stay exact.
func _budget_cm3() -> int:
	return int(_clear_budget * DropItem.CM3_PER_M3)


func _spend_budget(cm3: int) -> void:
	_clear_budget -= float(cm3) / DropItem.CM3_PER_M3


@onready var _body: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	skin_tone = _random_skin_tone()
	# The capsule material is a shared scene resource — duplicate before
	# tinting or every unit would share one color.
	var material := _body.get_surface_override_material(0).duplicate() as StandardMaterial3D
	material.albedo_color = skin_tone
	_body.set_surface_override_material(0, material)


func setup(world: VoxelWorld, colony: Colony) -> void:
	_world = world
	_colony = colony
	_sim_id = get_instance_id()
	if _world.sim != null:
		_world.sim.unit_register(_sim_id, global_position)


func _exit_tree() -> void:
	if _world != null and _world.sim != null and _sim_id != 0:
		_world.sim.unit_unregister(_sim_id)


## A random point along the pale → mid → dark skin-tone ramp.
static func _random_skin_tone() -> Color:
	var t := randf()
	if t < 0.5:
		return SKIN_TONE_PALE.lerp(SKIN_TONE_MID, t * 2.0)
	return SKIN_TONE_MID.lerp(SKIN_TONE_DARK, t * 2.0 - 1.0)


func _physics_process(delta: float) -> void:
	if _world == null:
		return

	_job_search_cooldown = maxf(_job_search_cooldown - delta, 0.0)
	_repath_cooldown = maxf(_repath_cooldown - delta, 0.0)

	match state:
		State.IDLE:
			_tick_idle()
		State.MOVING:
			_tick_moving(delta)
		State.WORKING:
			_tick_working(delta)
		State.YIELDING:
			_tick_yielding(delta)

	_apply_motion(delta)


func abandon_job() -> void:
	# An interrupted haul drops the load where the unit stands.
	for item in _carried:
		_colony._drop_item(item, _standing_voxel())
	_carried.clear()
	job = null
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_clear_budget = 0.0
	_fetching = false
	_evict_elapsed = 0.0
	_detour = Vector3i.MAX
	_detour_delivering = false
	_detour_return = Vector3i.ZERO
	state = State.IDLE


func current_activity() -> String:
	match state:
		State.MOVING:
			if job == null:
				return "walking"
			if _detour != Vector3i.MAX:
				if _detour == job.voxel_position:
					return "hauling cleared items"
				return "hauling a blockage" if _detour_delivering else "clearing a blockage"
			if job.type == ColonyJob.Type.HAUL:
				return "fetching items" if _fetching else "hauling to stockpile"
			if job.type == ColonyJob.Type.BUILD and _fetching:
				return "fetching wall materials"
			return "walking to %s" % str(job.voxel_position)
		State.YIELDING:
			return "stepping aside"
		State.WORKING:
			if job == null:
				return "working"
			if job.type == ColonyJob.Type.CHOP:
				return "chopping a tree"
			if job.type == ColonyJob.Type.HAUL:
				return "loading items" if _fetching else "stockpiling items"
			if job.type == ColonyJob.Type.CLEAR:
				return "clearing %s" % str(job.voxel_position)
			if job.type == ColonyJob.Type.BUILD:
				if _fetching:
					return "gathering wall materials"
				if job.material == BlockRegistry.Resource_.NONE:
					return "building a wall"
				return "building %s" % BlockRegistry.block_name(job.block_id)
			return "mining %s" % BlockRegistry.block_name(_world.get_block(job.voxel_position))
		_:
			return "idle"


func _tick_idle() -> void:
	if _job_search_cooldown > 0.0:
		return
	_job_search_cooldown = 0.5
	job = _colony.claim_job(self)
	if job == null:
		_try_start_haul()
		return
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = job.voxel_position
	_fetching = false
	if job.type == ColonyJob.Type.BUILD and not _wall_full(job):
		# Nothing to deliver yet — head for the closest usable pile.
		var next := _colony.nearest_wall_voxel(_standing_voxel(), job.material)
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	if _repath_to_job():
		state = State.MOVING
	else:
		_give_up_on_job()


func _tick_moving(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	if _goal_in_reach():
		_path.clear()
		if _detour != Vector3i.MAX:
			_detour_arrived()
		else:
			state = State.WORKING
		return

	# Watchdog: no meaningful progress toward the site for too long means
	# the path is physically blocked — drop the assignment for someone else.
	var goal_distance := global_position.distance_to(
		Vector3(_goal_voxel) + Vector3(0.5, 0.5, 0.5)
	)
	if goal_distance < _best_goal_distance - STUCK_PROGRESS:
		_best_goal_distance = goal_distance
		_stuck_elapsed = 0.0
	else:
		_stuck_elapsed += delta
		if _stuck_elapsed > stuck_timeout:
			if _detour != Vector3i.MAX:
				_fail_detour()
			else:
				_give_up_on_job()
			return

	if _path_index >= _path.size():
		if _repath_cooldown > 0.0:
			return
		if not _repath_to_job():
			if _detour != Vector3i.MAX:
				_fail_detour()
			else:
				_give_up_on_job()
		return

	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	if flat_distance < 0.35:
		_path_index += 1
		return

	# A packed item pile in the way (the astar can't see those): once close
	# enough to reach it, haul it to a stockpile when one has room —
	# otherwise shove its contents into neighbouring voxels.
	if flat_distance < 1.6:
		var waypoint_cell := Vector3i(waypoint.floor())
		for cell in [waypoint_cell, waypoint_cell + Vector3i.UP]:
			if not _world.is_solid(cell) and _colony.is_packed(cell):
				if _detour == Vector3i.MAX and _start_detour(cell):
					break
				if cell != _detour:
					_colony.shove_pile(cell)

	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if _grounded and (to_waypoint.y > 0.6 or _blocked_horiz):
		_want_jump = true


func _tick_working(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	velocity.x = 0.0
	velocity.z = 0.0

	if job.type == ColonyJob.Type.CLEAR:
		_tick_clearing(delta)
		return
	if job.type == ColonyJob.Type.BUILD:
		_tick_building(delta)
		return
	if job.type == ColonyJob.Type.HAUL:
		_tick_hauling(delta)
		return
	if job.type == ColonyJob.Type.CHOP:
		_tick_chopping(delta)
		return

	if not _can_mine(job.voxel_position):
		state = State.MOVING
		return

	var block_id := _world.get_block(job.voxel_position)
	if not BlockRegistry.is_solid(block_id):
		_colony.complete_job(job, block_id)
		abandon_job()
		return

	job.progress += mining_speed * delta
	if job.progress < BlockRegistry.hardness(block_id):
		return

	var mined := _world.mine(job.voxel_position)
	if mined == BlockRegistry.Block.AIR:
		# Area unloaded under us: put the job back on the board.
		_colony.release_job(job)
		abandon_job()
		return
	_colony.complete_job(job, mined)
	job = null
	state = State.IDLE


## Chopping work: the unit works the tree's root voxel — the reach rule
## follows whether the root is solid (a trunk) or not (a sapling) — and
## once the summed hardness of the whole tree is met, it all comes down
## at once as drops.
func _tick_chopping(delta: float) -> void:
	var root := job.voxel_position
	var block_id := _world.get_block(root)
	if not _can_reach_from(global_position, root, BlockRegistry.is_solid(block_id)):
		state = State.MOVING
		return
	var work := _colony.forest.tree_work(root)
	if work <= 0.0:
		# The tree is gone — felled while the unit was walking over.
		_colony.complete_chop(job)
		job = null
		state = State.IDLE
		return
	job.progress += mining_speed * delta
	if job.progress < work:
		return
	_colony.fell_tree(job)
	job = null
	state = State.IDLE


## Clearing work: empty the job voxel's pile a little at a time. With a
## stockpile that has room the items are carried there — a load at a time,
## walking back between trips — otherwise they're shoveled into adjoining
## voxels like before.
func _tick_clearing(delta: float) -> void:
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var pile := _colony.item_pile_at(job.voxel_position)
	if pile == null or pile.items.is_empty():
		_colony.complete_clear(job)
		job = null
		state = State.IDLE
		return
	_clear_budget += clearing_speed * delta
	var sp := _colony.nearest_stockpile_with_room(
			_standing_voxel(), Colony.MIN_LOOSE_CM3, _haul_blacklist
	)
	if sp != Vector3i.MAX:
		var room := DropItem.BLOCK_CM3 - _colony.voxel_fill(sp)
		var want := mini(carry_capacity, room) - _carried_volume()
		while want > 0 and _budget_cm3() > 0:
			var got := pile.take_up_to(mini(want, _budget_cm3()))
			if got.is_empty():
				break
			var volume := 0
			for item in got:
				volume += item.volume
			_carried.append_array(got)
			_spend_budget(volume)
			want = mini(carry_capacity, room) - _carried_volume()
		_colony.remove_pile_if_empty(job.voxel_position)
		if _carried_volume() > 0:
			# A delivery leg — the detour machinery walks the load to the
			# stockpile, then repaths back here to keep clearing.
			_detour = job.voxel_position
			_detour_return = job.voxel_position
			_detour_delivering = true
			_goal_voxel = sp
			_path.clear()
			_stuck_elapsed = 0.0
			_best_goal_distance = INF
			state = State.MOVING
			if not _repath_to_job():
				_fail_detour()
			return
		# Nothing fits the carry load (oversized solid items) — scatter
		# what's left like there's no stockpile.
	while _clear_budget > 0.0:
		var item := _colony.move_pile_item(job.voxel_position)
		if item == null:
			if _colony.item_pile_at(job.voxel_position) == null:
				_colony.complete_clear(job)
				job = null
				state = State.IDLE
			else:
				# Every adjoining voxel is packed — the pile can't shrink.
				_give_up_on_job()
			return
		_spend_budget(item.volume)


## Build work is a hauling loop: fetch wall material from the closest
## pile that has some (no distance limit — the unit walks to wherever it
## is), carry a load back to the site, repeat until the wall has its full
## volume — `job.progress` is the cubic centimetres delivered. The first load
## a unit picks commits the job's material (and so the block it builds);
## if that material runs out mid-job the commitment lifts and the next
## fetch can pick another. Then displace whatever sits in the voxel and
## place the block.
func _tick_building(delta: float) -> void:
	if _world.is_solid(job.voxel_position):
		# The block is already there — the job is moot.
		_colony.complete_build(job)
		job = null
		state = State.IDLE
		return
	if _fetching:
		_tick_fetching(delta)
	else:
		_tick_delivering(delta)


## True when a build job has gathered all the material its wall needs —
## impossible until a material is committed.
func _wall_full(build_job: ColonyJob) -> bool:
	return (
		build_job.material != BlockRegistry.Resource_.NONE
		and build_job.progress >= BlockRegistry.wall_volume_for(build_job.material)
	)


## Fixes the job's material to whatever [param pile] can supply the most
## of — loose soil, stone boulders and cobbles, or logs — and with it
## the block the wall becomes.
func _commit_wall_material(pile: ItemPile) -> void:
	var best := BlockRegistry.Resource_.NONE
	var best_volume := 0
	for material: BlockRegistry.Resource_ in BlockRegistry.WALL_MATERIALS:
		var volume := pile.wall_volume(material)
		if volume > best_volume:
			best_volume = volume
			best = material
	if best == BlockRegistry.Resource_.NONE:
		return
	job.material = best
	job.block_id = BlockRegistry.wall_block_for(best)


## Fetching: at the pile, take wall material into the carried load until
## the load, the shovel budget or the remaining need runs out — then head
## back.
func _tick_fetching(delta: float) -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null:
		_advance_build_goal()
		return
	if job.material == BlockRegistry.Resource_.NONE:
		_commit_wall_material(pile)
		if job.material == BlockRegistry.Resource_.NONE:
			# Nothing usable here after all.
			_advance_build_goal()
			return
	var need := (
		BlockRegistry.wall_volume_for(job.material)
		- int(job.progress) - _carried_volume()
	)
	var got := pile.take_wall(
		job.material,
		need,
		mini(carry_capacity - _carried_volume(), _budget_cm3())
	)
	var taken := 0
	for item in got:
		taken += item.volume
	_carried.append_array(got)
	_spend_budget(taken)
	_colony.remove_pile_if_empty(_goal_voxel)
	if (
		_carried_volume() >= carry_capacity
		or pile.wall_volume(job.material) <= 0
		or (got.is_empty() and _carried_volume() > 0)
	):
		# Loaded, this pile is drained, or the rest won't fit this trip.
		_advance_build_goal()
	elif got.is_empty() and _budget_cm3() >= carry_capacity:
		# A full shovel budget and still nothing takeable — the pile's
		# eligible items are all heavier than a unit can carry.
		_give_up_on_job()


## Delivering: at the site, the carried load is absorbed into the wall's
## material tally — whole items while any need remains, so the last one
## may overshoot; anything beyond that is still in hand. Fetch again
## until the wall's full volume has arrived, then place it.
func _tick_delivering(delta: float) -> void:
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	var target := BlockRegistry.wall_volume_for(job.material)
	var kept: Array[DropItem] = []
	for item in _carried:
		if (
			job.progress < target
			and BlockRegistry.item_fits_wall(item, job.material)
		):
			job.progress += item.volume
		else:
			kept.append(item)
	_carried = kept
	if job.progress < target:
		_advance_build_goal()
		return
	# Leftovers overshot the wall's need — drop them beside the site
	# rather than absorbing them into the block.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	# A unit in the voxel would be buried — a capsule spans its standing
	# voxel and the one above, so both count. Idle occupants get shoved
	# aside like path-blockers; one that can't move (or won't leave in
	# time) fails the job rather than getting buried.
	var blocked := false
	for u in _colony.units:
		if not _occupies_voxel(u, job.voxel_position):
			continue
		if u == self:
			# Head inside the target — back out to a proper work spot.
			state = State.MOVING
			return
		if u.state == State.IDLE:
			u.yield_to(self)
			if u.state != State.YIELDING:
				# Nowhere to step — the voxel can't be cleared.
				_give_up_on_job()
				return
		blocked = true
	if blocked:
		_evict_elapsed += delta
		if _evict_elapsed > 4.0:
			_give_up_on_job()
		return
	_evict_elapsed = 0.0
	# Push whatever piled up in the voxel while hauling into the neighbours.
	while _colony.item_pile_at(job.voxel_position) != null:
		if _colony.move_pile_item(job.voxel_position) == null:
			_give_up_on_job()
			return
	if not _world.place(job.voxel_position, job.block_id):
		_colony.release_job(job)
		abandon_job()
		return
	_colony.complete_build(job)
	job = null
	state = State.IDLE


## Picks the next build-job goal: carry the load to the site if the unit
## holds any, else fetch from the next-closest usable pile. With a full
## wall and no load the delivery tick takes it from there.
func _advance_build_goal() -> void:
	if _carried_volume() > 0 or _wall_full(job):
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_wall_voxel(_standing_voxel(), job.material)
		if (
			next == Vector3i.MAX
			and job.material != BlockRegistry.Resource_.NONE
		):
			# The committed material ran out — open the job to anything.
			job.material = BlockRegistry.Resource_.NONE
			next = _colony.nearest_wall_voxel(_standing_voxel(), job.material)
		if next == Vector3i.MAX:
			# No wall material anywhere — put the job back on the board.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## Idle fallback: with no designated job to claim, haul loose items to a
## stockpile — the nearest pile that isn't already in one, to the nearest
## stockpile tile with room. The haul is an off-board job so pathing and
## the stuck watchdog work on it unchanged.
func _try_start_haul() -> void:
	var source := _colony.nearest_haulable_pile(_standing_voxel(), _haul_blacklist)
	if source == Vector3i.MAX:
		return
	if (
		_colony.nearest_stockpile_with_room(
			_standing_voxel(), Colony.MIN_LOOSE_CM3, _haul_blacklist
		) == Vector3i.MAX
	):
		return
	job = ColonyJob.new(ColonyJob.Type.HAUL, source)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_fetching = true
	_goal_voxel = source
	if not _repath_to_job():
		_give_up_on_job()
	else:
		state = State.MOVING


## Hauling work: load items off the source pile, carry them to a stockpile.
func _tick_hauling(delta: float) -> void:
	if _fetching:
		_tick_haul_fetch(delta)
	else:
		_tick_haul_deliver()


## At the source pile: load items until the load reaches what fits in the
## destination stockpile (capacity-limited — big piles take several trips).
func _tick_haul_fetch(delta: float) -> void:
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null or pile.items.is_empty():
		if _carried_volume() > 0:
			_set_haul_destination()
			return
		# The pile was emptied before we arrived — find another one.
		var next := _colony.nearest_haulable_pile(_standing_voxel(), _haul_blacklist)
		if next == Vector3i.MAX:
			job = null
			state = State.IDLE
		else:
			_goal_voxel = next
			_path.clear()
			state = State.MOVING
		return
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), Colony.MIN_LOOSE_CM3, _haul_blacklist
	)
	if sp == Vector3i.MAX:
		# No stockpile has any room — the haul is impossible for now.
		_give_up_on_job()
		return
	var room := DropItem.BLOCK_CM3 - _colony.voxel_fill(sp)
	var want := mini(carry_capacity, room) - _carried_volume()
	_clear_budget += clearing_speed * delta
	while want > 0 and _budget_cm3() > 0:
		var got := pile.take_up_to(mini(want, _budget_cm3()))
		if got.is_empty():
			break
		var volume := 0
		for item in got:
			volume += item.volume
		_carried.append_array(got)
		_spend_budget(volume)
		want = mini(carry_capacity, room) - _carried_volume()
	_colony.remove_pile_if_empty(_goal_voxel)
	if _carried_volume() >= mini(carry_capacity, room) or pile.items.is_empty():
		_set_haul_destination()


## At the stockpile: unload the carried items into its voxel.
func _tick_haul_deliver() -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	if _colony.voxel_fill(_goal_voxel) + _carried_volume() > DropItem.BLOCK_CM3:
		# It filled up while we walked — find another tile.
		_set_haul_destination()
		return
	for item in _carried:
		_colony._deposit_item(item, _goal_voxel)
	_carried.clear()
	job = null
	state = State.IDLE


## Picks the stockpile tile this haul's load goes to — the nearest with
## room for it. With nowhere that fits, the job is dropped (and the load
## with it).
func _set_haul_destination() -> void:
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), _carried_volume(), _haul_blacklist
	)
	if sp == Vector3i.MAX:
		_give_up_on_job()
		return
	_fetching = false
	_goal_voxel = sp
	_path.clear()
	state = State.MOVING


## A packed pile sits on the path's waypoint: when a stockpile can take a
## load, detour to haul the blockage there instead of scattering it with a
## shove. The detour borrows _goal_voxel and the path, so the reach rule,
## repathing and the stuck watchdog all keep working on it.
func _start_detour(cell: Vector3i) -> bool:
	if _detour != Vector3i.MAX:
		return false
	var record: Dictionary = _haul_blacklist.get(cell, {})
	if not record.is_empty() and (
		Time.get_ticks_msec() - int(record.get("at", 0))
		< _colony.retry_delay_msec(record)
	):
		return false
	var pile := _colony.item_pile_at(cell)
	if pile == null or pile.items.is_empty():
		return false
	if (
		_colony.nearest_stockpile_with_room(
			_standing_voxel(), Colony.MIN_LOOSE_CM3, _haul_blacklist
		) == Vector3i.MAX
	):
		return false
	_detour = cell
	_detour_return = _goal_voxel
	_detour_delivering = false
	_goal_voxel = cell
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	DLog.log("unit %d detours to pile %s (job %s)" % [_sim_id, cell, _detour_return])
	return true


## Reached the detour's current goal: shovel the obstructing pile into the
## carried load, or unload at the stockpile and resume the real job.
func _detour_arrived() -> void:
	if not _detour_delivering:
		var pile := _colony.item_pile_at(_detour)
		var sp := _colony.nearest_stockpile_with_room(
			_standing_voxel(), Colony.MIN_LOOSE_CM3, _haul_blacklist
		)
		if pile == null or pile.items.is_empty() or sp == Vector3i.MAX:
			# Someone else cleared the blockage, or nowhere has room after
			# all — either way, back to the job's own path.
			_end_detour()
			return
		var room := DropItem.BLOCK_CM3 - _colony.voxel_fill(sp)
		var want := mini(carry_capacity, room) - _carried_volume()
		if want > 0:
			_carried.append_array(pile.take_up_to(want))
			_colony.remove_pile_if_empty(_detour)
		if _carried.is_empty():
			_end_detour()
			return
		_detour_delivering = true
		_goal_voxel = sp
		_path.clear()
		_stuck_elapsed = 0.0
		_best_goal_distance = INF
		if not _repath_to_job():
			_fail_detour()
		return
	for item in _carried:
		_colony._deposit_item(item, _goal_voxel)
	_carried.clear()
	_end_detour()


## Detour finished: restore the job's own goal and repath to it.
func _end_detour() -> void:
	_detour = Vector3i.MAX
	_detour_delivering = false
	_goal_voxel = _detour_return
	_detour_return = Vector3i.ZERO
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if not _repath_to_job():
		_give_up_on_job()


## The detour's current goal proved unreachable: blacklist it, drop the
## load where the unit stands and go back to the job's own path — the pile
## it was clearing is dealt with by a shove instead.
func _fail_detour() -> void:
	var record: Dictionary = _haul_blacklist.get(_goal_voxel, {})
	record["at"] = Time.get_ticks_msec()
	record["n"] = int(record.get("n", 0)) + 1
	_haul_blacklist[_goal_voxel] = record
	for item in _carried:
		_colony._drop_item(item, _standing_voxel())
	_carried.clear()
	_end_detour()


## Asks this unit to step aside for [param pusher] — only idle units can be
## shoved; a busy unit is already going somewhere. The unit walks to a
## standable neighbour that's off the pusher's path and unoccupied, then
## returns to idle. If no such spot exists it simply stays put and the
## pusher's stuck watchdog deals with the blockage.
func yield_to(pusher: Unit) -> void:
	if state != State.IDLE:
		return
	DLog.log("unit %d yields to %d at %s" % [_sim_id, pusher._sim_id, _standing_voxel()])
	var pusher_cells := {
		pusher._standing_voxel(): true,
		pusher._goal_voxel: true,
	}
	for i in range(pusher._path_index, pusher._path.size()):
		pusher_cells[Vector3i(pusher._path[i].floor())] = true
	var occupied := {}
	for unit in _colony.units:
		occupied[unit._standing_voxel()] = true
	var here := _standing_voxel()
	var candidates: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var spot := here + Vector3i(dx, dy, dz)
				if _is_standable(spot) and not occupied.has(spot):
					candidates.append(spot)
	# Prefer spots off the pusher's path, then farthest from the pusher.
	var from := pusher.global_position
	candidates.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			var sa := Vector3(a).distance_squared_to(from) - (1000.0 if pusher_cells.has(a) else 0.0)
			var sb := Vector3(b).distance_squared_to(from) - (1000.0 if pusher_cells.has(b) else 0.0)
			return sa > sb
	)
	for spot in candidates:
		var path := _world.find_path(here, spot)
		if path.is_empty():
			continue
		_path = path
		_path_index = 0
		_yield_elapsed = 0.0
		state = State.YIELDING
		return


## Sidestepping: follow the yield path, then go back to idle. A short
## timeout covers the case where the spot can't actually be reached.
func _tick_yielding(delta: float) -> void:
	_yield_elapsed += delta
	if _path_index >= _path.size() or _yield_elapsed > 2.0:
		state = State.IDLE
		return
	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	if flat_distance < 0.35:
		_path_index += 1
		return
	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if _grounded and (to_waypoint.y > 0.6 or _blocked_horiz):
		_want_jump = true


## True when the current goal voxel's face is reachable from where the
## unit stands — mining requires a solid target, everything else a
## non-solid one; a unit can't build the block it's standing in.
## True when any part of [param unit]'s capsule intersects [param voxel].
## The capsule is 1.8 m tall, so a unit always spans its feet voxel and the
## head voxel above it — checking only the standing voxel misses burials.
## True when this unit's capsule fills [param voxel_position] — feet voxel
## or head voxel. Growth uses it to avoid growing a tree into a unit.
func occupies(voxel_position: Vector3i) -> bool:
	return _occupies_voxel(self, voxel_position)


static func _occupies_voxel(u: Unit, voxel: Vector3i) -> bool:
	var bottom := (u.global_position - Vector3(0.0, 0.9, 0.0)).floor()
	var top := (u.global_position + Vector3(0.0, 0.9, 0.0)).floor()
	return (
		int(bottom.x) == voxel.x
		and int(bottom.z) == voxel.z
		and voxel.y >= int(bottom.y)
		and voxel.y <= int(top.y)
	)


func _goal_in_reach() -> bool:
	if _detour != Vector3i.MAX:
		return _can_clear_from(global_position, _goal_voxel)
	if job.type == ColonyJob.Type.MINE:
		return _can_mine(job.voxel_position)
	if job.type == ColonyJob.Type.CHOP:
		return _can_reach_from(
			global_position, job.voxel_position, _world.is_solid(job.voxel_position)
		)
	var here := _standing_voxel()
	if (
		job.type == ColonyJob.Type.BUILD
		and not _fetching
		and (here == job.voxel_position or here + Vector3i.UP == job.voxel_position)
	):
		return false
	return _can_clear_from(global_position, _goal_voxel)


func _apply_motion(delta: float) -> void:
	if _world.sim != null:
		_apply_sim_motion(delta)
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	if state == State.IDLE or state == State.WORKING:
		velocity.x = move_toward(velocity.x, 0.0, move_speed)
		velocity.z = move_toward(velocity.z, 0.0, move_speed)
	if _want_jump:
		velocity.y = jump_speed
		_want_jump = false
	# The intended heading — move_and_slide rewrites velocity, so capture it
	# before the collision pass.
	var heading := Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_grounded = is_on_floor()
	_blocked_horiz = is_on_wall()
	# A unit with somewhere to be shoves idle units out of its way — the
	# astar doesn't know about bodies, so corridors clog without this. Only
	# head-on contact counts; brushing past a shoulder doesn't shove.
	if state == State.MOVING and job != null and heading.length_squared() > 0.01:
		heading = heading.normalized()
		for i in get_slide_collision_count():
			var hit := get_slide_collision(i)
			var blocker := hit.get_collider()
			if (
				blocker is Unit
				and blocker.state == State.IDLE
				and hit.get_normal().dot(heading) < -0.3
			):
				blocker.yield_to(self)


## Sim-driven motion: the intended velocity goes to DelveSim, which resolves
## it against voxel occupancy, pile fill heights and other units — the same
## job move_and_slide did, but without a physics body, and identically when
## no scene is instantiated. The node's transform follows the sim position
## verbatim; all position queries keep working.
func _apply_sim_motion(delta: float) -> void:
	# External teleports (tests, future tools) write global_position —
	# forward them into the sim or the body would snap back next step.
	var sim_pos: Vector3 = _world.sim.unit_pos(_sim_id)
	if global_position.distance_squared_to(sim_pos) > 0.0025:
		DLog.log("unit %d teleported %s -> %s" % [_sim_id, sim_pos, global_position])
		_world.sim.unit_register(_sim_id, global_position)
	var heading := Vector3(velocity.x, 0.0, velocity.z)
	if state == State.IDLE or state == State.WORKING:
		heading = heading.move_toward(Vector3.ZERO, move_speed)
	var res: Dictionary = _world.sim.unit_step(
		_sim_id, heading, jump_speed if _want_jump else 0.0, gravity, delta
	)
	_want_jump = false
	global_position = res["pos"]
	_grounded = res["grounded"]
	_blocked_horiz = res["blocked"]
	velocity = Vector3(heading.x, res["vel_y"], heading.z)
	var hit_unit: int = res["hit_unit"]
	if (
		hit_unit >= 0
		and state == State.MOVING
		and job != null
		and heading.length_squared() > 0.01
	):
		var blocker := instance_from_id(hit_unit) as Unit
		if blocker != null and blocker.state == State.IDLE:
			blocker.yield_to(self)


## True when the unit can mine [param voxel_position] from where it stands.
func _can_mine(voxel_position: Vector3i) -> bool:
	return _can_mine_from(global_position, voxel_position)


## The mining rule: the unit's centre must be within [member mine_reach] of
## the block's nearest face, and no other solid voxel may sit between them —
## blocks behind, above or below another block relative to the unit are out.
func _can_mine_from(from: Vector3, voxel_position: Vector3i) -> bool:
	return _can_reach_from(from, voxel_position, true)


## Same reach rule for a non-solid target — a voxel holding an item pile.
## The ray passes through it, so the packed-cell march alone checks that no
## solid or packed voxel sits between the unit and the pile.
func _can_clear_from(from: Vector3, voxel_position: Vector3i) -> bool:
	return _can_reach_from(from, voxel_position, false)


## Shared reach rule: within [member mine_reach] of the voxel's nearest face,
## with no solid or packed voxel in between. For a solid target the face ray
## must also land on the target itself.
func _can_reach_from(from: Vector3, voxel_position: Vector3i, solid_target: bool) -> bool:
	if _world.sim != null:
		return _world.sim.can_reach_from(from, voxel_position, solid_target, mine_reach)
	var nearest := from.clamp(Vector3(voxel_position), Vector3(voxel_position) + Vector3.ONE)
	var to_face := nearest - from
	var distance := to_face.length()
	if distance > mine_reach:
		return false
	if distance < 0.01:
		return true
	var direction := to_face / distance
	if solid_target:
		var hit := _world.raycast(from, direction, distance + 0.5)
		if hit == null or hit.position != voxel_position:
			return false
	# A voxel packed full of items occludes like a solid block — this march
	# also catches solid voxels, since is_packed covers both.
	var travelled := 0.0
	while travelled < distance - 0.2:
		var cell := Vector3i((from + direction * travelled).floor())
		if cell != Vector3i(from.floor()) and _colony.is_packed(cell):
			return false
		travelled += 0.25
	return true


func _repath_to_job() -> bool:
	_repath_cooldown = 1.0
	_path.clear()
	_path_index = 0
	if job == null:
		return false

	var start := _standing_voxel()
	var blocked_path := PackedVector3Array()
	# A detour goal is a pile or stockpile tile — always a non-solid target.
	# A chop target is solid once the root is trunk, not while a sapling.
	var solid_target := _detour == Vector3i.MAX and (
		job.type == ColonyJob.Type.MINE
		or (
			job.type == ColonyJob.Type.CHOP
			and _world.is_solid(job.voxel_position)
		)
	)
	# A unit can't deliver from inside the block it's building — or from
	# directly beneath it, where its head would be buried.
	var exclude_self := (
		job.type == ColonyJob.Type.BUILD
		and _detour == Vector3i.MAX
		and _goal_voxel == job.voxel_position
	)
	var spots := _work_spots(_goal_voxel, solid_target, exclude_self)
	# Each candidate costs an A* run (~0.05-1.3 ms); a target hemmed in by
	# blocked spots would otherwise burn a path per spot per repath. Cap the
	# attempts — the next repath retries with fresh geometry, and a
	# pile-crossing path is better than none anyway.
	var attempts := 0
	for target in spots:
		if attempts >= MAX_PATH_ATTEMPTS:
			break
		attempts += 1
		var path := _world.find_path(start, target)
		if path.is_empty():
			continue
		if _path_is_clear(path):
			_path = path
			return true
		if blocked_path.is_empty():
			blocked_path = path
	# No clear route: take a pile-crossing one and shove obstructions aside
	# as they come within reach.
	if not blocked_path.is_empty():
		_path = blocked_path
		return true
	return false


## Voxel the unit currently stands in.
func _standing_voxel() -> Vector3i:
	return Vector3i(floori(global_position.x), roundi(global_position.y - 0.9), floori(global_position.z))


## True when a voxel blocks a unit: solid terrain, or packed full of items.
func _is_blocked(voxel_position: Vector3i) -> bool:
	if _world.sim != null:
		return _world.sim.is_blocked(voxel_position)
	return _world.is_solid(voxel_position) or _colony.is_packed(voxel_position)


## Standable for a unit: a solid or packed floor below, two free voxels.
## A partially filled voxel is enterable — its pile's collision lifts the
## unit to the fill level, and a unit can stand on top of a packed one.
func _is_standable(voxel_position: Vector3i) -> bool:
	if _world.sim != null:
		return _world.sim.is_unit_standable(voxel_position)
	return (
		_is_blocked(voxel_position + Vector3i.DOWN)
		and not _is_blocked(voxel_position)
		and not _is_blocked(voxel_position + Vector3i.UP)
	)


## True when no path cell runs through a blocked voxel. The voxel astar does
## not know about item fill, so a path can nominally pass through a packed
## pile — the unit shoves those aside on approach, but a clear path is
## preferred when one exists.
func _path_is_clear(path: PackedVector3Array) -> bool:
	for i in range(1, path.size()):
		if _is_blocked(Vector3i(path[i].floor())):
			return false
	return true


## Standable voxels a unit could work [param target] from, nearest first.
## Scans the box of spots whose centre is plausibly in reach — a spot counts
## only if reaching the target from it passes the same check the unit uses.
## [param exclude_self] keeps a unit from working from inside the target
## voxel or the one beneath it — a unit can't build the block it stands in,
## and standing directly under it puts its head inside.
func _work_spots(target: Vector3i, solid_target: bool = true, exclude_self: bool = false) -> Array[Vector3i]:
	if _world.sim != null:
		var native: Array[Vector3i] = []
		for spot in _world.sim.work_spots(
			target, global_position, solid_target, exclude_self, mine_reach
		):
			native.append(Vector3i(spot))
		return native
	var reachable: Array[Vector3i] = []
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var spot := target + Vector3i(dx, dy, dz)
				if exclude_self and (spot == target or spot == target + Vector3i.DOWN):
					continue
				if not _is_standable(spot):
					continue
				if _can_reach_from(Vector3(spot) + Vector3(0.5, 0.9, 0.5), target, solid_target):
					reachable.append(spot)
	var here := global_position
	reachable.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return Vector3(a).distance_squared_to(here) < Vector3(b).distance_squared_to(here)
	)
	return reachable


func _give_up_on_job() -> void:
	DLog.log("unit %d gave up: state=%d job=%s pos=%s" % [
		_sim_id, state,
		job.voxel_position if job != null else Vector3i.MAX,
		_standing_voxel(),
	])
	if job != null:
		if job.type == ColonyJob.Type.HAUL:
			# Whatever we failed to reach goes quiet for a while — longer
			# with each consecutive failure.
			var record: Dictionary = _haul_blacklist.get(_goal_voxel, {})
			record["at"] = Time.get_ticks_msec()
			record["n"] = int(record.get("n", 0)) + 1
			_haul_blacklist[_goal_voxel] = record
		_colony.release_job(job)
	_job_search_cooldown = 1.5
	abandon_job()
