class_name Unit
extends Node3D

## A worker: claims jobs from the [Colony], walks to them over the voxel grid
## and mines. Deliberately small — it is the hook where real AI (needs, skills,
## hauling, sleep schedules) gets added later.

enum State { IDLE, MOVING, WORKING, YIELDING, SLEEPING, EATING }
## How well the unit rests: NORMAL in a bed, POOR on the ground.
enum RestQuality { POOR, NORMAL }

const DLog := preload("res://scripts/dlog.gd")

## Skin-tone ramp anchors: pale to dark. Each unit draws a random point
## along the ramp at spawn.
const SKIN_TONE_PALE := Color(0.96, 0.80, 0.66)
const SKIN_TONE_MID := Color(0.55, 0.36, 0.24)
const SKIN_TONE_DARK := Color(0.20, 0.11, 0.07)

@export var move_speed: float = 4.0
## Enough to clear a 1 m step: apex is jump_speed² / (2 × gravity).
@export var jump_speed: float = 7.5
## Ladder descent rate — slower than walking, so a climb reads as a
## climb rather than a teleport down the shaft.
@export var climb_speed: float = 2.5
@export var gravity: float = 22.0
## Distance in metres from the unit's centre to a block's nearest face.
@export var mine_reach: float = 1.5
## Hardness points worked through per second.
@export var mining_speed: float = 2.0
## Cubic metres of items shovelled per second — clearing and gathering alike.
@export var clearing_speed: float = 2.0
## Material volume, in cubic centimetres, a unit carries on one trip.
@export var carry_capacity: int = 500_000
## Seconds of work at a crafting spot to finish one craft order.
@export var crafting_seconds: float = 4.0
## Seconds of work to take a construction apart.
@export var deconstruct_seconds: float = 2.0
## Seconds without getting closer to the job site before the unit drops the
## assignment as unreachable.
@export var stuck_timeout: float = 5.0
## Below this energy the unit stops taking jobs and finds somewhere to
## sleep — a free bed if one's reachable, else the ground under it.
@export var rest_seek: float = 0.25
## Below this hunger the unit interrupts work to eat — the nearest pile
## holding food, or it goes hungry and slows.
@export var food_seek: float = 0.3
## Work rate while starving — hunger at zero halves the unit's speed at
## every kind of labour rather than downing it.
const STARVING_SPEED := 0.5
## cm³ of food one bite takes, and seconds between bites while EATING.
const BITE_CM3 := 30_000
const BITE_SECONDS := 0.6
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
## Food piles the unit failed to reach or eat from — same escalating
## retry pattern as the haul blacklist, so one unreachable berry pile
## doesn't starve a unit that could reach another.
var _food_blacklist: Dictionary = {}
## The packed pile blocking the unit's path that it is hauling to a
## stockpile before resuming its job — Vector3i.MAX when not detouring.
var _detour: Vector3i = Vector3i.MAX
## Detour phase: false while heading for the blocking pile, true while
## carrying its contents to the stockpile.
var _detour_delivering := false
## What [member _goal_voxel] was before the detour took it over.
var _detour_return: Vector3i = Vector3i.ZERO
## How rested the unit is, 0–1. Drains while awake — a full bar lasts
## roughly two thirds of a day — and recovers while SLEEPING.
var energy := 1.0
## How fed the unit is, 0–1. Drains over a day; below [member food_seek]
## the unit seeks food, and at zero it keeps working at half speed.
var hunger := 1.0
## Eat-clock accumulator — one bite per [constant BITE_SECONDS].
var _eat_budget := 0.0
## The bed this unit is sleeping in (or walking to), or null.
var _rest_bed: Building = null
## Rest rate in force while SLEEPING — bed sleep is NORMAL, ground POOR.
var _rest_quality: RestQuality = RestQuality.POOR

## Skill XP by [constant ColonyJob.Skill]. Levels derive from XP, so only
## the raw points are stored: reaching level L takes
## [constant SKILL_XP_BASE] × L(L+1)/2 total XP — X to level 1, then 2X
## more to level 2, and so on.
var skills: Dictionary = {
	ColonyJob.Skill.MINING: 0.0,
	ColonyJob.Skill.CONSTRUCTION: 0.0,
	ColonyJob.Skill.PLANTS: 0.0,
	ColonyJob.Skill.CRAFTING: 0.0,
}
## Job-choice stance: a specialist favours jobs matching its skills over
## nearby ones; a generalist mostly takes the closest work. Player-set.
@export var specialize := false

## XP a level-0→1 jump costs — the requirement grows linearly after
## that: X, then 2X, 3X, …
const SKILL_XP_BASE := 10.0
## Work speed doubles every this many skill levels: a level-10 worker is
## ~2× a level-0 one, level 20 ~4×.
const SKILL_DOUBLE_LEVELS := 10.0
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
## Intended velocity — heading.x/z are written by move ticks, y is the
## vertical rate the sim reports back. Not a physics property: the unit
## has no body; DelveSim owns motion and this is just a scratchpad.
var velocity := Vector3.ZERO
## A move tick's jump request, consumed by the next _apply_motion.
var _want_jump := false
## A move tick's ladder-descent request, likewise consumed.
var _want_descend := false


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
@onready var _status_label: Label3D = $StatusLabel


func _ready() -> void:
	skin_tone = _random_skin_tone()
	# Staggered reserves keep the whole colony from napping at once.
	energy = randf_range(0.65, 1.0)
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


## Floating status caption — the same string the colonist bar shows,
## tinted by state so sleepers and loafers read at a glance.
func _process(_delta: float) -> void:
	if _status_label == null or _world == null:
		return
	var text := current_activity()
	if _status_label.text == text:
		return
	_status_label.text = text
	match state:
		State.SLEEPING:
			_status_label.modulate = Color(0.6, 0.75, 1.0)
		State.IDLE, State.YIELDING:
			_status_label.modulate = Color(1.0, 1.0, 1.0, 0.55)
		_:
			_status_label.modulate = Color.WHITE


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

	if _colony.needs_enabled:
		if state == State.SLEEPING:
			energy = minf(energy + delta / _rest_span(), 1.0)
			if energy >= 1.0:
				_wake()
		else:
			# A full bar lasts two thirds of a day awake — the rest of
			# the day is sleep, which is where the "a third of each day"
			# comes from.
			energy = maxf(energy - delta / (_colony.day_length() * 2.0 / 3.0), 0.0)
			if energy <= 0.0:
				_collapse()
		# A full stomach lasts a day — sleep doesn't pause digestion.
		hunger = maxf(hunger - delta / _colony.day_length(), 0.0)

	match state:
		State.IDLE:
			_tick_idle()
		State.MOVING:
			_tick_moving(delta)
		State.WORKING:
			_tick_working(delta)
		State.YIELDING:
			_tick_yielding(delta)
		State.SLEEPING:
			_tick_sleeping(delta)
		State.EATING:
			_tick_eating(delta)

	_apply_motion(delta)


func abandon_job() -> void:
	# An interrupted haul drops the load where the unit stands.
	for item in _carried:
		_colony._drop_item(item, _standing_voxel())
	_carried.clear()
	job = null
	if _rest_bed != null:
		if _rest_bed.occupant == self:
			_rest_bed.occupant = null
		_rest_bed = null
	_rest_quality = RestQuality.POOR
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_clear_budget = 0.0
	_fetching = false
	_evict_elapsed = 0.0
	_detour = Vector3i.MAX
	_detour_delivering = false
	_detour_return = Vector3i.ZERO
	_eat_budget = 0.0
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
			if job.type == ColonyJob.Type.CRAFT:
				if Colony.RECIPES[job.recipe].has("builds"):
					return (
						"fetching materials" if _fetching
						else "heading to the site"
					)
				return (
					"fetching materials" if _fetching
					else "heading to the crafting spot"
				)
			if job.type == ColonyJob.Type.FURNISH:
				return (
					"fetching a bed kit" if _fetching
					else "assembling a bed"
				)
			if job.type == ColonyJob.Type.REST:
				return "heading to bed"
			if job.type == ColonyJob.Type.EAT:
				return "seeking food"
			if job.type == ColonyJob.Type.FORAGE:
				return "heading to a berry bush"
			return "walking to %s" % str(job.voxel_position)
		State.YIELDING:
			return "stepping aside"
		State.SLEEPING:
			return (
				"sleeping" if _rest_quality == RestQuality.NORMAL
				else "sleeping on the ground"
			)
		State.EATING:
			return "eating"
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
			if job.type == ColonyJob.Type.CRAFT:
				if Colony.RECIPES[job.recipe].has("builds"):
					return (
						"fetching materials" if _fetching
						else String(Colony.RECIPES[job.recipe]["label"]).to_lower()
					)
				return "fetching materials" if _fetching else "crafting"
			if job.type == ColonyJob.Type.FURNISH:
				return (
					"fetching a bed kit" if _fetching
					else "assembling a bed"
				)
			if job.type == ColonyJob.Type.DECONSTRUCT:
				return "deconstructing %s" % (
					_colony.building_at(job.voxel_position).label()
					if _colony.building_at(job.voxel_position) != null
					else "a building"
				)
			if job.type == ColonyJob.Type.FORAGE:
				return "foraging berries"
			return "mining %s" % BlockRegistry.block_name(_world.get_block(job.voxel_position))
		_:
			if _colony != null and _colony.needs_enabled and hunger <= 0.0:
				return "starving"
			return "idle"


## Seconds a full sleep takes at this rest quality — a bed refills the
## bar in a third of a day; the ground takes 25% longer (five twelfths).
func _rest_span() -> float:
	var third := _colony.day_length() / 3.0
	return third if _rest_quality == RestQuality.NORMAL else third * 1.25


## Sleep done: hand the bed back and return to the board.
func _wake() -> void:
	if _rest_bed != null:
		if _rest_bed.occupant == self:
			_rest_bed.occupant = null
		_rest_bed = null
	job = null
	state = State.IDLE


## Out of energy mid-work: the unit sleeps where it stands — poor rest,
## no trip to a bed. The job goes back on the board first so it doesn't
## die on an assignee who's down for the count.
func _collapse() -> void:
	if job != null:
		_colony.release_job(job)
	abandon_job()
	_rest_quality = RestQuality.POOR
	state = State.SLEEPING


## The unit needs sleep: claim the nearest free bed and walk over —
## a REST job carries the goal through the usual moving machinery — or,
## when there's no bed, lie down on the ground right here. Ground rest
## is POOR: it takes a quarter again as long as a bed.
func _start_rest() -> void:
	_rest_quality = RestQuality.POOR
	var bed := _colony.nearest_free_bed(_standing_voxel())
	if bed != null:
		bed.occupant = self
		_rest_bed = bed
		if bed.footprint.has(_standing_voxel()):
			_rest_quality = RestQuality.NORMAL
			state = State.SLEEPING
			return
		job = ColonyJob.new(ColonyJob.Type.REST, bed.voxel)
		job.state = ColonyJob.State.ASSIGNED
		job.assignee = self
		_stuck_elapsed = 0.0
		_best_goal_distance = INF
		_goal_voxel = bed.voxel
		state = State.MOVING
		if _repath_to_job():
			return
		# The bed can't be reached — take the floor where we stand.
		bed.occupant = null
		_rest_bed = null
		job = null
	state = State.SLEEPING


## Asleep: hold still and recover — _physics_process refills the bar at
## the active rest quality and _wake() releases the unit at full.
func _tick_sleeping(_delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0


## The unit needs food: walk to the nearest pile holding something
## edible — an EAT job carries the goal through the usual moving
## machinery like a REST job does. With no food anywhere the unit just
## keeps working; starvation slows it but doesn't down it.
func _start_eat() -> void:
	var spot := _colony.nearest_food_pile(_standing_voxel(), _food_blacklist)
	if spot == Vector3i.MAX:
		return
	job = ColonyJob.new(ColonyJob.Type.EAT, spot)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = spot
	if _repath_to_job():
		state = State.MOVING
	else:
		# The food can't be reached — remember it and stay hungry; the
		# next seek tries the next-best pile instead of hammering this one.
		_blacklist_food(spot)
		job = null
		_job_search_cooldown = 2.0


## Marks a food pile as recently failed — the next seek picks a
## different pile when one exists.
func _blacklist_food(spot: Vector3i) -> void:
	var record: Dictionary = _food_blacklist.get(spot, {})
	record["at"] = _colony.game_msec()
	record["n"] = int(record.get("n", 0)) + 1
	_food_blacklist[spot] = record


## At the food pile: a bite every BITE_SECONDS until full or the pile's
## food runs out. Bites are consumed where they stand — the pile shrinks
## by exactly what was eaten.
func _tick_eating(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var pile := _colony.item_pile_at(job.voxel_position)
	if pile == null or hunger >= 1.0:
		job = null
		state = State.IDLE
		return
	if not _can_clear_from(global_position, job.voxel_position):
		# Drifted or shoved out of reach — walk back for another bite.
		state = State.MOVING
		return
	_eat_budget += delta
	var out_of_food := false
	while _eat_budget >= BITE_SECONDS and hunger < 1.0:
		_eat_budget -= BITE_SECONDS
		var got := pile.take_up_to(
			BITE_CM3,
			func(item: DropItem) -> bool:
				return DropItem.is_food(item.material)
		)
		if got.is_empty():
			# The pile's edible part is gone — anything left isn't food.
			# A food-less pile won't answer the next seek, so ending the
			# meal here just sends a still-hungry unit to the next pile.
			out_of_food = true
			break
		for item in got:
			hunger = minf(
				hunger + DropItem.nutrition_of(item.material, item.volume), 1.0
			)
		_colony.remove_pile_if_empty(job.voxel_position)
	if hunger >= 1.0 or out_of_food or _colony.item_pile_at(job.voxel_position) == null:
		job = null
		state = State.IDLE


## Labour rate multiplier: a starving unit works at half speed —
## hunger bottoms out into a penalty, not a collapse — and skill in the
## current job's discipline speeds everything proportionally.
func _work_rate() -> float:
	var rate := 1.0
	if _colony.needs_enabled and hunger <= 0.0:
		rate *= STARVING_SPEED
	if job != null:
		rate *= skill_rate(ColonyJob.SKILL_FOR.get(job.type, -1))
	return rate


## Highest level whose cumulative XP requirement — X·L(L+1)/2 — has been
## met. Inverting that quadratic keeps level a pure function of XP, so
## no separate level counter can drift out of sync.
func skill_level(skill: int) -> int:
	var xp: float = skills.get(skill, 0.0)
	return floori((sqrt(1.0 + 8.0 * xp / SKILL_XP_BASE) - 1.0) / 2.0)


## Work-rate multiplier from skill — 2^(level / SKILL_DOUBLE_LEVELS):
## level 10 ≈ 2×, level 20 ≈ 4×. An unskilled type passes -1 → 1.0.
func skill_rate(skill: int) -> float:
	if skill < 0:
		return 1.0
	return pow(2.0, skill_level(skill) / SKILL_DOUBLE_LEVELS)


## XP the next level at [param level] still needs — X for 0→1, 2X for
## 1→2, 3X for 2→3.
static func skill_xp_next(level: int) -> float:
	return SKILL_XP_BASE * (level + 1)


## 0–1 progress through the current level — for the colonist panel's bar.
func skill_progress(skill: int) -> float:
	var level := skill_level(skill)
	var spent: float = skills.get(skill, 0.0) - SKILL_XP_BASE * level * (level + 1) / 2.0
	return clampf(spent / skill_xp_next(level), 0.0, 1.0)


## Award XP. The gain-rate hook is where attributes — aptitude, focus —
## will modulate learning speed once they exist.
func gain_skill_xp(skill: int, amount: float) -> void:
	if skill < 0:
		return
	skills[skill] = skills.get(skill, 0.0) + amount * skill_gain_rate(skill)


## Learning-speed multiplier — a flat 1.0 until attributes land.
func skill_gain_rate(_skill: int) -> float:
	return 1.0


func _tick_idle() -> void:
	if _job_search_cooldown > 0.0:
		return
	_job_search_cooldown = 0.5
	if _colony.needs_enabled:
		if energy <= rest_seek:
			_start_rest()
			return
		if hunger <= food_seek:
			_start_eat()
			if state != State.IDLE:
				return
			# No reachable food — keep working hungry. The work
			# penalty only bites at zero.
	job = _colony.claim_job(self)
	if job == null:
		_try_start_haul()
		return
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = job.voxel_position
	_fetching = false
	if job.type == ColonyJob.Type.BUILD and not _wall_full(job):
		# Nothing to deliver yet — head for the closest pile that has
		# what the recipe still needs.
		var next := _colony.nearest_wall_voxel(
			_standing_voxel(), job.material, _wall_need(job)
		)
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.CRAFT:
		# Craft jobs fetch their inputs first — the goal starts at a pile.
		var next := _colony.nearest_forms_voxel(
			_standing_voxel(), _craft_wanted_forms()
		)
		if next == Vector3i.MAX:
			# No usable inputs anywhere — back on the board it goes.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.FURNISH:
		# Furnishing is a fetch-and-place: grab the kit from the nearest
		# pile that has one, carry it to the anchor.
		var next := _colony.nearest_form_voxel(
			_standing_voxel(), DropItem.Form.BED
		)
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
	# Arrival must cover this tick's travel: at high time_scale a single
	# step can carry past the waypoint without ever entering a small
	# radius — the unit would orbit the point until the watchdog fires.
	if flat_distance < maxf(0.35, move_speed * delta):
		# Straight up or down in the column — a ladder edge. A hop inside
		# the cell lifts the feet onto the rung's top surface; sinking at
		# climb_speed descends it under control. A vertical waypoint with
		# no ladder is a step-up marker: skip it — the horizontal push
		# that follows trips the jump on wall contact.
		var standing := _standing_voxel()
		var waypoint_cell := Vector3i(waypoint.floor())
		if waypoint_cell.y > standing.y:
			if _colony.ladder_at(standing) or _colony.ladder_at(waypoint_cell):
				if _grounded:
					_want_jump = true
				_steer_toward_column(waypoint_cell)
				return
		elif (
			waypoint_cell.y < standing.y
			and _colony.ladder_at(waypoint_cell)
		):
			_want_descend = true
			_steer_toward_column(waypoint_cell)
			return
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


## Eases the capsule onto [param cell]'s centre column — keeps a climb
## or descent lined up with the rung so the foot samples stay over the
## ladder while the unit rises or sinks.
func _steer_toward_column(cell: Vector3i) -> void:
	var inward := Vector3(cell) + Vector3(0.5, 0.0, 0.5) - global_position
	velocity.x = inward.x * move_speed
	velocity.z = inward.z * move_speed


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
	if job.type == ColonyJob.Type.CRAFT:
		_tick_crafting(delta)
		return
	if job.type == ColonyJob.Type.FURNISH:
		_tick_furnishing(delta)
		return
	if job.type == ColonyJob.Type.REST:
		# Arrived at the bed — lie down.
		_rest_quality = RestQuality.NORMAL
		state = State.SLEEPING
		return
	if job.type == ColonyJob.Type.EAT:
		# Arrived at the food pile — tuck in.
		state = State.EATING
		return
	if job.type == ColonyJob.Type.FORAGE:
		_tick_foraging(delta)
		return
	if job.type == ColonyJob.Type.DECONSTRUCT:
		_tick_deconstructing(delta)
		return

	if not _can_mine(job.voxel_position):
		state = State.MOVING
		return

	var block_id := _world.get_block(job.voxel_position)
	if not BlockRegistry.is_solid(block_id):
		_colony.complete_job(job, block_id)
		abandon_job()
		return

	job.progress += mining_speed * delta * _work_rate()
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
	job.progress += mining_speed * delta * _work_rate()
	if job.progress < work:
		return
	_colony.fell_tree(job)
	job = null
	state = State.IDLE


## Craft work: fetch the recipe's inputs from the nearest piles that have
## them — as many trips as the carry load takes — deliver each load into
## the job's escrow at the spot, then work the order. The inputs are only
## consumed when the order finishes, so a cancelled craft puts them back
## into the world intact.
func _tick_crafting(delta: float) -> void:
	if _fetching:
		_tick_craft_fetch(delta)
		return
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	# Escrow whatever the unit is carrying that the recipe still needs.
	var kept: Array[DropItem] = []
	for item in _carried:
		var want := _craft_need(item.form)
		if want <= 0 or item.volume > want:
			kept.append(item)
			continue
		job.delivered[item.form] = (
			int(job.delivered.get(item.form, 0)) + item.volume
		)
		job.components.append(item)
		if job.material == BlockRegistry.Resource_.NONE:
			job.material = item.material
	_carried = kept
	if _craft_needs():
		# More inputs outstanding — back to the piles.
		_advance_craft_goal()
		return
	job.progress += delta * _work_rate()
	if job.progress < crafting_seconds:
		return
	# The order completes: the escrowed inputs are consumed, the outputs
	# and the offcut remainder drop at the spot.
	var consumed := 0
	var material := job.material
	for item in job.components:
		consumed += item.volume
	var produced := 0
	var recipe: Dictionary = Colony.RECIPES[job.recipe]
	# `output_material` overrides the input class — extract-seed presses
	# fruit into seed packets, not more fruit.
	var out_material: BlockRegistry.Resource_ = recipe.get(
		"output_material", material
	)
	for output: Dictionary in recipe["outputs"]:
		for form: int in output:
			for i in int(output[form]):
				var volume := DropItem.form_volume(form)
				produced += volume
				var product := DropItem.new(out_material, form, volume)
				# A seed packet keeps the species of the fruit it was
				# pressed from — oak acorns yield oak seeds.
				if form == DropItem.Form.SEED:
					product.species = DropItem.FRUIT_SPECIES.get(
						material, &""
					)
				_colony._drop_item(product, job.voxel_position)
	if bool(recipe.get("waste", false)) and consumed > produced:
		_colony._drop_item(
			DropItem.new(material, DropItem.Form.LOOSE, consumed - produced),
			job.voxel_position
		)
	# Whatever the unit still holds wasn't needed — set it down.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	_colony.complete_craft(job)
	job = null
	state = State.IDLE


## Craft fetch: at the pile, lift items of the forms the recipe still
## needs until the load fills, then carry them to the spot.
func _tick_craft_fetch(delta: float) -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null or _craft_wanted_in(pile).is_empty():
		_advance_craft_goal()
		return
	var cap := mini(carry_capacity - _carried_volume(), _budget_cm3())
	var took := false
	for form in _craft_wanted_in(pile):
		var item := pile.take_form(form, cap)
		if item == null:
			continue
		_carried.append(item)
		_spend_budget(item.volume)
		cap -= item.volume
		took = true
		if cap <= 0:
			break
	_colony.remove_pile_if_empty(_goal_voxel)
	if took or _carried_volume() >= carry_capacity:
		_advance_craft_goal()
	elif _budget_cm3() >= carry_capacity:
		# A full shovel and nothing takeable — the inputs here are all
		# heavier than a unit can carry.
		_give_up_on_job()


## cm³ of [param form] the craft order still wants — recipe inputs count
## whole items; [member ColonyJob.delivered] tallies what's arrived.
func _craft_need(form: DropItem.Form) -> int:
	var inputs: Dictionary = Colony.RECIPES[job.recipe]["inputs"]
	var want := int(inputs.get(form, 0)) * DropItem.form_volume(form)
	return maxi(want - int(job.delivered.get(form, 0)), 0)


## True while any recipe input is still missing.
func _craft_needs() -> bool:
	for form: int in Colony.RECIPES[job.recipe]["inputs"]:
		if _craft_need(form) > 0:
			return true
	return false


## The forms the recipe still wants — the fetch query's filter.
func _craft_wanted_forms() -> Array:
	var forms: Array = []
	for form: int in Colony.RECIPES[job.recipe]["inputs"]:
		if _craft_need(form) > 0:
			forms.append(form)
	return forms


## The subset of a pile's stock the recipe still wants — intersected so
## the fetch tick only lifts what's needed.
func _craft_wanted_in(pile: ItemPile) -> Array:
	var forms: Array = []
	for form in _craft_wanted_forms():
		if pile.form_volume(form) > 0:
			forms.append(form)
	return forms


## Next craft-job goal: deliver the load to the spot when the unit holds
## inputs, or the recipe is complete; else fetch from the next-closest
## pile holding a wanted form.
func _advance_craft_goal() -> void:
	var carrying_needed := false
	for item in _carried:
		if _craft_need(item.form) > 0:
			carrying_needed = true
			break
	if carrying_needed or not _craft_needs():
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_forms_voxel(
			_standing_voxel(), _craft_wanted_forms()
		)
		if next == Vector3i.MAX:
			# No usable inputs anywhere — back on the board it goes.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## Furnishing: fetch the kit the building unpacks from, carry it to the
## anchor, and the building goes up — no terrain changes, just the
## footprint registering in the colony's buildings.
func _tick_furnishing(delta: float) -> void:
	if _fetching:
		if not _can_clear_from(global_position, _goal_voxel):
			state = State.MOVING
			return
		_clear_budget += clearing_speed * delta * _work_rate()
		var pile := _colony.item_pile_at(_goal_voxel)
		if pile == null:
			_advance_furnish_goal()
			return
		var kit := pile.take_form(
			DropItem.Form.BED,
			mini(carry_capacity - _carried_volume(), _budget_cm3())
		)
		if kit == null:
			if pile.form_volume(DropItem.Form.BED) <= 0:
				_advance_furnish_goal()
			elif _budget_cm3() >= carry_capacity:
				_give_up_on_job()
			return
		_carried.append(kit)
		_spend_budget(kit.volume)
		_colony.remove_pile_if_empty(_goal_voxel)
		_advance_furnish_goal()
		return
	var here := _standing_voxel()
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var kit := _carried_form(DropItem.Form.BED)
	if kit == null:
		# Arrived empty-handed — the kit went somewhere; fetch again.
		_advance_furnish_goal()
		return
	_carried.erase(kit)
	job.components.append(kit)
	# Anything else in hand isn't the bed's business — set it down.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	_colony.complete_furnish(job)
	job = null
	state = State.IDLE


## Next furnish-job goal: deliver the kit to the anchor once it's in
## hand, else fetch from the next-closest pile holding one.
func _advance_furnish_goal() -> void:
	if _carried_form(DropItem.Form.BED) != null:
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_form_voxel(
			_standing_voxel(), DropItem.Form.BED
		)
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## The first carried item of [param form], or null.
func _carried_form(form: DropItem.Form) -> DropItem:
	for item in _carried:
		if item.form == form:
			return item
	return null


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
	_clear_budget += clearing_speed * delta * _work_rate()
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), 1, _haul_blacklist, pile.materials()
	)
	if sp != Vector3i.MAX:
		var admit := func(item: DropItem) -> bool:
			return _colony.stockpile_admits(sp, item.material)
		var room := _colony.voxel_capacity(sp) - _colony.voxel_fill(sp)
		var want := mini(carry_capacity, room) - _carried_volume()
		while want > 0 and _budget_cm3() > 0:
			var got := pile.take_up_to(mini(want, _budget_cm3()), admit)
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
## pile that has what the recipe still needs (no distance limit — the
## unit walks to wherever it is), carry a load back to the site, repeat
## until every form the recipe calls for has arrived — `job.delivered`
## tallies the cm³ absorbed per form, `job.components` keeps the actual
## items so the finished wall knows what it was built of. The first load
## a unit picks commits the job's material (and so the block it builds)
## — permanently: a wall is one recipe, and a material that runs out
## sends the job back to the board rather than switching it to another.
## Then displace whatever sits in the voxel and place the block.
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


## True when a build job has gathered every form and volume its wall's
## recipe calls for — impossible until a material is committed.
func _wall_full(build_job: ColonyJob) -> bool:
	var recipe := BlockRegistry.wall_recipe(build_job.material)
	if recipe.is_empty():
		return false
	for form in recipe:
		if int(build_job.delivered.get(form, 0)) < int(recipe[form]):
			return false
	return true


## What the wall's recipe is still missing once the carried load arrives:
## form → cm³, forms already covered left out.
func _wall_need(build_job: ColonyJob, load: Array[DropItem] = []) -> Dictionary:
	var covered := build_job.delivered.duplicate()
	for item in load:
		covered[item.form] = int(covered.get(item.form, 0)) + item.volume
	var need := {}
	var recipe := BlockRegistry.wall_recipe(build_job.material)
	for form in recipe:
		var missing := int(recipe[form]) - int(covered.get(form, 0))
		if missing > 0:
			need[form] = missing
	return need


## Fetching: at the pile, take wall material into the carried load until
## the load, the shovel budget or the remaining need runs out — then head
## back.
func _tick_fetching(delta: float) -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null:
		_advance_build_goal()
		return
	var need := _wall_need(job, _carried)
	if need.is_empty():
		# The load already in hand finishes the recipe — deliver it.
		_advance_build_goal()
		return
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
		or pile.wall_need_volume(job.material, need) <= 0
		or (got.is_empty() and _carried_volume() > 0)
	):
		# Loaded, this pile has nothing more the recipe wants, or the
		# rest won't fit this trip.
		_advance_build_goal()
	elif got.is_empty() and _budget_cm3() >= carry_capacity:
		# A full shovel budget and still nothing takeable — the pile's
		# needed items are all heavier than a unit can carry.
		_give_up_on_job()


## Delivering: at the site, each carried item of the ordered material
## joins the wall — whole items when their form's recipe slot fits them,
## loose material split down to exactly what's missing. Items of a form
## the recipe doesn't want stay in hand and get dropped beside the site.
## Fetch again until the recipe is complete, then place the block.
func _tick_delivering(delta: float) -> void:
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	var recipe := BlockRegistry.wall_recipe(job.material)
	var kept: Array[DropItem] = []
	for item in _carried:
		var missing := (
			int(recipe.get(item.form, 0))
			- int(job.delivered.get(item.form, 0))
		)
		if item.material != job.material or missing <= 0:
			kept.append(item)
			continue
		var part := item.volume
		if item.form == DropItem.Form.LOOSE:
			part = mini(missing, item.volume)
		elif missing < item.volume:
			# A solid item that won't fit its slot can't join the wall.
			kept.append(item)
			continue
		job.delivered[item.form] = int(job.delivered.get(item.form, 0)) + part
		var escrowed := DropItem.new(item.material, item.form, part)
		escrowed.species = item.species
		job.components.append(escrowed)
		item.volume -= part
		if item.volume > 0:
			kept.append(item)
	_carried = kept
	if not _wall_full(job):
		_advance_build_goal()
		return
	if not _colony.would_be_supported(job.voxel_position):
		# Nothing to hang the block from — the job suspends until an
		# adjacent placement anchors it. The escrowed material stays in
		# the job; only the loose carry drops where the unit stands.
		_colony.suspend_build_job(job)
		abandon_job()
		return
	# Leftovers the recipe didn't want — drop them beside the site
	# rather than burying them in the block.
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
## holds any, else fetch from the next-closest pile that has what the
## recipe still needs. With a full wall and no load the delivery tick
## takes it from there.
func _advance_build_goal() -> void:
	if _carried_volume() > 0 or _wall_full(job):
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var need := _wall_need(job)
		var next := _colony.nearest_wall_voxel(_standing_voxel(), job.material, need)
		if next == Vector3i.MAX:
			# The material was ordered — nothing usable anywhere means
			# the wall waits for its recipe, not for a different material.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## Foraging: strip a ripe bush's yield — a short work like a chop, but
## the plant stays and regrows rather than coming down.
func _tick_foraging(delta: float) -> void:
	var root := _colony.plants.bush_at(job.voxel_position)
	if root == Vector3i.MAX:
		# The bush is gone — dug out or built over mid-walk.
		_colony.complete_forage(job)
		job = null
		state = State.IDLE
		return
	if not _can_clear_from(global_position, root):
		state = State.MOVING
		return
	var work := _colony.plants.forage_work(root)
	if work <= 0.0:
		_colony.complete_forage(job)
		job = null
		state = State.IDLE
		return
	job.progress += mining_speed * delta * _work_rate()
	if job.progress < work:
		return
	_colony.complete_forage(job)
	job = null
	state = State.IDLE


## Deconstruction: work the building for its seconds, then it comes apart
## — the block leaves terrain and the exact items it was built of drop.
func _tick_deconstructing(delta: float) -> void:
	var building := _colony.building_at(job.voxel_position)
	if building == null:
		# The construction is already gone — the job is moot.
		_colony.complete_deconstruct(job)
		job = null
		state = State.IDLE
		return
	var solid := building.block_id != BlockRegistry.Block.AIR
	if not _can_reach_from(global_position, job.voxel_position, solid):
		state = State.MOVING
		return
	job.progress += delta * _work_rate()
	if job.progress < deconstruct_seconds:
		return
	_colony.complete_deconstruct(job)
	job = null
	state = State.IDLE


## Idle fallback: with no designated job to claim, haul loose items to a
## stockpile — the nearest pile that isn't already in one, to the nearest
## stockpile tile with room. The haul is an off-board job so pathing and
## the stuck watchdog work on it unchanged.
func _try_start_haul() -> void:
	var source := _colony.nearest_haulable_pile(_standing_voxel(), _haul_blacklist)
	if source == Vector3i.MAX:
		return
	var pile := _colony.item_pile_at(source)
	var mats := _haulable_materials(pile, source)
	if (
		_colony.nearest_stockpile_with_room(
			_standing_voxel(), 1, _haul_blacklist, mats
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


## The materials a pile wants moved: everything in it, or — when it sits
## on a stockpile tile — only what the tile's filter rejects, so the rest
## stays put.
func _haulable_materials(pile: ItemPile, voxel: Vector3i) -> Array:
	if not _colony.is_stockpile(voxel):
		return pile.materials()
	var rejected: Array = []
	for material in pile.materials():
		if not _colony.stockpile_admits(voxel, material):
			rejected.append(material)
	return rejected


## The filter for what this fetch may pick up: the destination has to
## store it, and an eviction haul takes only what the source tile rejects.
func _haul_fetch_admits(pile: ItemPile, voxel: Vector3i, sp: Vector3i) -> Callable:
	return func(item: DropItem) -> bool:
		return (
			_colony.stockpile_admits(sp, item.material)
			and (
				not _colony.is_stockpile(voxel)
				or not _colony.stockpile_admits(voxel, item.material)
			)
		)


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
	var mats := _haulable_materials(pile, _goal_voxel)
	var sp := Vector3i.MAX
	var room := 0
	var admit := Callable()
	while true:
		sp = _colony.nearest_stockpile_with_room(
			_standing_voxel(), 1, _haul_blacklist, mats
		)
		if sp == Vector3i.MAX:
			# No stockpile admits this pile's contents — the haul is
			# impossible for now.
			_give_up_on_job()
			return
		admit = _haul_fetch_admits(pile, _goal_voxel, sp)
		room = _colony.voxel_capacity(sp) - _colony.voxel_fill(sp)
		# A tile is only useful when it can hold at least one admissible
		# item — a solid needs its whole volume, while loose material
		# shaves down to whatever room is left. A nearly-full tile that
		# can't fit the smallest boulder would stall the take loop
		# forever, so skip it.
		var takeable := false
		for item in pile.items:
			if (
				admit.call(item)
				and (item.form == DropItem.Form.LOOSE or item.volume <= room)
			):
				takeable = true
				break
		if takeable:
			break
		var record: Dictionary = _haul_blacklist.get(sp, {})
		record["at"] = _colony.game_msec()
		record["n"] = int(record.get("n", 0)) + 1
		_haul_blacklist[sp] = record
	var want_cap := mini(carry_capacity, room)
	var want := want_cap - _carried_volume()
	_clear_budget += clearing_speed * delta * _work_rate()
	while want > 0 and _budget_cm3() > 0:
		var got := pile.take_up_to(mini(want, _budget_cm3()), admit)
		if got.is_empty():
			break
		var volume := 0
		for item in got:
			volume += item.volume
		_carried.append_array(got)
		_spend_budget(volume)
		want = want_cap - _carried_volume()
	_colony.remove_pile_if_empty(_goal_voxel)
	var more := false
	for item in pile.items:
		if (
			admit.call(item)
			and (item.form == DropItem.Form.LOOSE or item.volume <= want)
		):
			more = true
			break
	if _carried.is_empty() and not more:
		# Nothing admissible fits the remaining trip room — a solid too
		# big for the budget still counts, since the budget accrues.
		_give_up_on_job()
		return
	if _carried_volume() >= want_cap or (not more and _carried_volume() > 0):
		_set_haul_destination()


## Pours carried items into [param voxel]'s pile until it is full — loose
## items split to fit the remaining room, solids move only whole. The
## carried list keeps whatever would not fit — and whatever the tile's
## filter stopped admitting while the load was in flight.
func _pour_carried_into(voxel: Vector3i) -> void:
	for i in range(_carried.size() - 1, -1, -1):
		var item: DropItem = _carried[i]
		if (
			_colony.is_stockpile(voxel)
			and not _colony.stockpile_admits(voxel, item.material)
		):
			continue
		var room := _colony.voxel_capacity(voxel) - _colony.voxel_fill(voxel)
		var pour := 0
		if item.form == DropItem.Form.LOOSE:
			pour = mini(item.volume, room)
		elif item.volume <= room:
			pour = item.volume
		if pour > 0:
			var poured := DropItem.new(item.material, item.form, pour)
			poured.species = item.species
			_colony._deposit_item(poured, voxel)
			item.volume -= pour
		if item.volume <= 0:
			_carried.remove_at(i)


## At the stockpile: unload the carried items into its voxel.
func _tick_haul_deliver() -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	# The tile may have filled while we walked — pour what still fits and
	# take the rest elsewhere rather than force-dumping the whole load.
	_pour_carried_into(_goal_voxel)
	if _carried.is_empty():
		job = null
		state = State.IDLE
		return
	_set_haul_destination()


## Picks the stockpile tile this haul's load goes to — the nearest with
## room for it that admits at least some of it. With nowhere that fits,
## the job is dropped (and the load with it).
func _set_haul_destination() -> void:
	# A tile qualifies when it can hold the biggest unsplittable item —
	# loose material pours into whatever room is left at delivery, so any
	# nonempty room counts.
	var load := 1
	var mats: Array = []
	for item in _carried:
		if item.form != DropItem.Form.LOOSE:
			load = maxi(load, item.volume)
		if not mats.has(item.material):
			mats.append(item.material)
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), load, _haul_blacklist, mats
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
		_colony.game_msec() - int(record.get("at", 0))
		< _colony.retry_delay_msec(record)
	):
		return false
	var pile := _colony.item_pile_at(cell)
	if pile == null or pile.items.is_empty():
		return false
	if (
		_colony.nearest_stockpile_with_room(
			_standing_voxel(), 1, _haul_blacklist, pile.materials()
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
			_standing_voxel(), 1, _haul_blacklist,
			pile.materials() if pile != null else []
		)
		if pile == null or pile.items.is_empty() or sp == Vector3i.MAX:
			# Someone else cleared the blockage, or nowhere has room after
			# all — either way, back to the job's own path.
			_end_detour()
			return
		var admit := func(item: DropItem) -> bool:
			return _colony.stockpile_admits(sp, item.material)
		var room := _colony.voxel_capacity(sp) - _colony.voxel_fill(sp)
		var want := mini(carry_capacity, room) - _carried_volume()
		if want > 0:
			_carried.append_array(pile.take_up_to(want, admit))
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
	_pour_carried_into(_goal_voxel)
	if _carried.is_empty():
		_end_detour()
		return
	# The tile filled while we walked — retarget the leftovers instead of
	# overfilling it and kicking off a spill cascade.
	_set_haul_destination()


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
	record["at"] = _colony.game_msec()
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
				if (
					_is_standable(spot)
					and _colony.voxel_fill(spot) <= 0
					and not occupied.has(spot)
				):
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
	# Same overshoot guard as _tick_moving: the radius has to cover one
	# tick's travel or a fast clock makes the unit orbit the waypoint.
	if flat_distance < maxf(0.35, move_speed * delta):
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
	if not _grounded:
		# Reach opens mid-climb or mid-hop before the unit lands — don't
		# start work (or shortcut pathing) from the air; a falling unit
		# sinks out of reach and ping-pongs between states instead.
		return false
	if _detour != Vector3i.MAX:
		return _can_clear_from(global_position, _goal_voxel)
	if job.type == ColonyJob.Type.REST:
		# The unit sleeps *in* the bed — either cell of its footprint.
		return (
			_rest_bed != null
			and _rest_bed.footprint.has(_standing_voxel())
		)
	if job.type == ColonyJob.Type.MINE:
		return _can_mine(job.voxel_position)
	if job.type == ColonyJob.Type.CHOP:
		return _can_reach_from(
			global_position, job.voxel_position, _world.is_solid(job.voxel_position)
		)
	if job.type == ColonyJob.Type.DECONSTRUCT:
		return _can_reach_from(
			global_position, job.voxel_position, _world.is_solid(job.voxel_position)
		)
	var here := _standing_voxel()
	if (
		(job.type == ColonyJob.Type.BUILD or job.type == ColonyJob.Type.CRAFT)
		and not _fetching
		and (here == job.voxel_position or here + Vector3i.UP == job.voxel_position)
	):
		return false
	return _can_clear_from(global_position, _goal_voxel)


func _apply_motion(delta: float) -> void:
	if _world.sim == null:
		# No kinematic body left — without DelveSim the unit holds still.
		return
	_apply_sim_motion(delta)


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
		_sim_id, heading, jump_speed if _want_jump else 0.0, gravity, delta,
		climb_speed if _want_descend else 0.0
	)
	_want_jump = false
	_want_descend = false
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

	# Already in reach — standing on a pile beside the goal, say — so no
	# path is needed at all: the next move tick sees the goal in reach
	# and starts work. Skip the spot scan entirely; a pile-hemmed target
	# might offer no spot the pathfinder accepts even from up close.
	if _goal_in_reach():
		return true
	var start := _standing_voxel()
	if job.type == ColonyJob.Type.REST:
		# The sleeper walks into the bed's own cell — a standable air
		# voxel over the floor the bed sits on.
		_path = _world.find_path(start, _goal_voxel)
		return not _path.is_empty()
	var blocked_path := PackedVector3Array()
	# A detour goal is a pile or stockpile tile — always a non-solid target.
	# A chop target is solid once the root is trunk, not while a sapling.
	var solid_target := _detour == Vector3i.MAX and (
		job.type == ColonyJob.Type.MINE
		or (
			(
				job.type == ColonyJob.Type.CHOP
				or job.type == ColonyJob.Type.DECONSTRUCT
			)
			and _world.is_solid(job.voxel_position)
		)
	)
	# A unit can't deliver from inside the block it's building — or from
	# directly beneath it, where its head would be buried. A craft spot is
	# worked from beside it too: standing in the workstation puts dropped
	# products under the unit's feet.
	var exclude_self := (
		(job.type == ColonyJob.Type.BUILD or job.type == ColonyJob.Type.CRAFT)
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


## Voxel the unit currently stands in — the cell holding the feet. On a
## partial pile that's the pile's own cell (the feet are inside it), not
## the cell above.
func _standing_voxel() -> Vector3i:
	return Vector3i(
		floori(global_position.x),
		floori(global_position.y - 0.9 + 0.001),
		floori(global_position.z)
	)


## True when a voxel blocks a unit: solid terrain, or packed full of items.
func _is_blocked(voxel_position: Vector3i) -> bool:
	if _world.sim != null:
		return _world.sim.is_blocked(voxel_position)
	return _world.is_solid(voxel_position) or _colony.is_packed(voxel_position)


## Standable for a unit: support at feet level — a blocked cell below, a
## ladder below or in the cell, or a partial pile in the cell whose
## surface the unit stands on — and headroom for the capsule at that
## height. On a pile past a fifth full the head pokes into the cell two
## up, which must be free too.
func _is_standable(voxel_position: Vector3i) -> bool:
	if _world.sim != null:
		return _world.sim.is_unit_standable(voxel_position)
	if _is_blocked(voxel_position) or _is_blocked(voxel_position + Vector3i.UP):
		return false
	var fill := _colony.voxel_fill(voxel_position)
	if (
		not _is_blocked(voxel_position + Vector3i.DOWN)
		and not _colony.ladder_at(voxel_position + Vector3i.DOWN)
		and not _colony.ladder_at(voxel_position)
		and fill <= 0
	):
		return false
	return fill <= DropItem.BLOCK_CM3 / 5 or not _is_blocked(
		voxel_position + Vector3i(0, 2, 0)
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
## A pile cell is a valid spot: the unit stands on the pile's surface, so
## reach is measured from an eye lifted by the fill — a pile ringed by
## other piles is still reachable.
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
				var lift := float(_colony.voxel_fill(spot)) / DropItem.BLOCK_CM3
				if _can_reach_from(
					Vector3(spot) + Vector3(0.5, 0.9 + lift, 0.5), target, solid_target
				):
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
			record["at"] = _colony.game_msec()
			record["n"] = int(record.get("n", 0)) + 1
			_haul_blacklist[_goal_voxel] = record
		elif job.type == ColonyJob.Type.EAT:
			_blacklist_food(_goal_voxel)
		_colony.release_job(job)
	_job_search_cooldown = 1.5
	abandon_job()
