class_name Animal
extends Node3D

## A wild creature: wanders, grazes or hunts to feed, flees or fights
## when hurt, and leaves a corpse item when it dies. Behaviour is read
## from [constant Species.SPECIES] — diet, temperament, speed and the
## butcher table all come from the species entry, so a new animal is
## data, not code.
##
## Movement uses the same DelveSim unit-step channel as [Unit] but a
## much simpler follower: no jobs, no doors, no hauling — a path is
## walked waypoint to waypoint and given up on when it stalls.

signal died(animal: Animal)

enum State { IDLE, MOVING, GRAZING, EATING, FLEEING, ATTACKING }

const GRAVITY := 22.0
const JUMP_SPEED := 7.5
## A waypoint counts reached inside this flat distance — and per tick at
## least the distance the step could overshoot.
const WAYPOINT_RADIUS := 0.35
## Goal proximity that counts as "arrived" — reach a grazing cell, a
## corpse pile's edge, or the wander waypoint.
const ARRIVE_RANGE := 1.8
## Bite contact range in melee.
const MELEE_RANGE := 1.7
const STUCK_PROGRESS := 0.25
const STUCK_TIMEOUT := 5.0
## How far a fleeing animal gets before it calms — well past the flee
## range so a chase doesn't flutter on the boundary.
const FLEE_SAFE_MULT := 2.2
## cm³ of a corpse/meat pile eaten per bite.
const BITE_CM3 := 8_000
## Grass cover eaten per second while grazing — a cell's full cover is a
## few bites, not a field.
const GRAZE_RATE := 0.08
## Hunger restored per point of cover eaten.
const GRAZE_NUTRITION := 0.9
## Predators look this far for prey.
const HUNT_RANGE := 45.0
## A fight the target walked away from ends past this distance — the
## animal calms instead of running the quarry down forever (death and
## manhunting are item-28/29 material).
const DISENGAGE_RANGE := 22.0
## Prey sprints at full speed for this long, then tires — the hunter's
## window: flee animals outpace a unit at first, but a tired rabbit is
## catchable, which is what makes a melee hunt able to end.
const FLEE_TIRE_SEC := 8.0
const FLEE_TIRED_MULT := 0.55
## Wander destinations land in this ring around the animal.
const WANDER_MIN := 4
const WANDER_MAX := 18
## Threat re-check cadence.
const THREAT_SCAN := 0.6
## Taming: progress each landed session earns — four good sessions
## domesticate. The roll that decides landed-vs-failed weights the
## handler's Animals skill.
const TAME_SESSION_GAIN := 0.25
const TAME_BASE_CHANCE := 0.55
const TAME_SKILL_BONUS := 0.05
## A failed session reads by temperament: a fighter turns manhunter on
## this chance; a fleer always bolts.
const TAME_RAGE_CHANCE := 0.5
## A fence underfoot (built mid-crossing) is still escapable — the
## animal squeezes off it at this crawl rather than freezing on the
## rail. The pathfinder never routes *through* one, so this only ever
## means "climb down".
const FENCE_ESCAPE := 0.3

var species: StringName = &""
## A founding-herd or tamed animal — flagged by the scenario or the
## TAME job's sessions. A domestic animal doesn't bolt from passing
## settlers, doesn't count against the wild-spawn target, and eats
## feed piled inside its pen when the grass runs out.
var domestic := false
## Sessions of trust banked toward domestication — reaches 1.0 and the
## flag flips. Persists: a taming interrupted keeps what it earned.
var tame_progress := 0.0
## The player-assigned allowed area — null roams free. An assigned
## animal wanders, grazes and hunts inside its bounds; outside it, the
## next idle decision walks it back to the nearest cell.
var allowed_area: AllowedArea = null
var health := 1.0
## 1 is a full stomach; drains over `hunger_days` game-days.
var hunger := 0.8
var dead := false
var state := State.IDLE

var velocity := Vector3.ZERO

var _world: VoxelWorld
var _colony: Colony
var _sim_id := 0
var _grounded := false
var _blocked_horiz := false

var _path := PackedVector3Array()
var _path_index := 0
var _goal_voxel := Vector3i.MAX
var _stuck_elapsed := 0.0
var _best_goal_distance := INF
var _repath_cooldown := 0.0
var _idle_cooldown := 0.0
var _threat_scan := 0.0
var _flee_repath := 0.0
var _flee_elapsed := 0.0

## Pending intent carried through MOVING: which cell to graze, which
## pile to eat.
var _graze_cell := Vector3i.MAX
var _meal_voxel := Vector3i.MAX
## What hurt it — a Unit or Animal. Flee-temperaments run from it;
## fight-temperaments turn on it. Also a carnivore's stalked prey.
var _target: Node3D = null


func setup(world: VoxelWorld, colony: Colony) -> void:
	_world = world
	_colony = colony
	_sim_id = get_instance_id()
	health = Species.field(species, &"health", 60.0)
	if _world.sim != null:
		_world.sim.unit_register(_sim_id, global_position)


func _exit_tree() -> void:
	if _world != null and _world.sim != null and _sim_id != 0:
		_world.sim.unit_unregister(_sim_id)


func label() -> String:
	return Species.label(species)


func _spec() -> Dictionary:
	return Species.spec(species)


## True for a wild animal a handler could ever win over — plant and
## mixed eaters take bait; a carnivore's idea of livestock is the
## handler, so the wolf stays wildlife.
func tameable() -> bool:
	return (
		not domestic
		and StringName(_spec().get(&"diet", &"herbivore"))
			!= &"carnivore"
	)


## True when [param item] works as bait or pen-feed for this animal —
## food, minus the meat an herbivore won't touch.
func bait_ok(item: DropItem) -> bool:
	if item.forbidden or not DropItem.is_food(item.material):
		return false
	if (
		StringName(_spec().get(&"diet", &"herbivore")) == &"herbivore"
		and item.material == BlockRegistry.Resource_.MEAT
	):
		return false
	return true


## A meal delivered by hand — the bait's nutrition lands as hunger.
func feed(nutrition: float) -> void:
	hunger = minf(hunger + nutrition, 1.0)


## Turned manhunter — the rough end of a failed session: the animal
## fixates on [param attacker] and charges.
func rage(attacker: Node3D) -> void:
	_target = attacker
	_path.clear()
	_flee_elapsed = 0.0
	state = State.ATTACKING


## Bolted — the mild end of a failed session for a flee temperament.
func spook(attacker: Node3D) -> void:
	_target = attacker
	_flee_repath = 0.0
	_flee_elapsed = 0.0
	state = State.FLEEING


## Settled — a fight or flight resolves: the target clears and the
## idle loop picks the next decision fresh.
func calm() -> void:
	_target = null
	_to_idle()


## True while the animal's turned manhunter on a settler — the tame
## board's "can't work this mark" read: a raged animal doesn't take
## bait, it takes fingers.
func enraged() -> bool:
	return state == State.ATTACKING and _target is Unit


## One taming session's resolution: progress on a landed session, a
## rage or a bolt on failure — the temperament decides which failure
## means. [param handler]'s Animals skill weights the odds; [param
## roll] and [param rage_roll] force the checks in tests (-1 rolls live).
func tame_session(
	handler: Unit, roll := -1.0, rage_roll := -1.0
) -> StringName:
	if roll < 0.0:
		roll = randf()
	var chance := clampf(
		TAME_BASE_CHANCE
			+ TAME_SKILL_BONUS * handler.skill_level(ColonyJob.Skill.ANIMALS),
		0.0, 0.95
	)
	if roll < chance:
		tame_progress = minf(tame_progress + TAME_SESSION_GAIN, 1.0)
		if tame_progress >= 1.0:
			domestic = true
			calm()
			return &"tamed"
		return &"progress"
	# The rough end of a failed handling — a fighter can turn
	# manhunter; a fleer simply bolts. A fight that doesn't rage
	# just loses interest in the hand-out.
	if (
		StringName(_spec().get(&"temperament", &"flee")) == &"fight"
	):
		if rage_roll < 0.0:
			rage_roll = randf()
		if rage_roll < TAME_RAGE_CHANCE:
			rage(handler)
			return &"rages"
		return &"failed"
	spook(handler)
	return &"spooked"


## The cell the creature was last seen standing in — the step-hook
## that springs traps compares against it.
var _trap_cell := Vector3i.MAX


func _physics_process(delta: float) -> void:
	var pt := Time.get_ticks_usec()
	_tick_physics(delta)
	Perf.sample(&"animals", Time.get_ticks_usec() - pt)


func _tick_physics(delta: float) -> void:
	if dead or _world == null or _world.sim == null or _colony == null:
		return
	_repath_cooldown = maxf(_repath_cooldown - delta, 0.0)
	var day := _colony.day_length()
	hunger = maxf(
		hunger - delta / (day * Species.field(species, &"hunger_days", 1.0)), 0.0
	)
	if hunger <= 0.0:
		# Starving wears health down at about half a bar a day.
		health = maxf(health - delta * Species.field(species, &"health", 60.0) * 0.5 / day, 0.0)
		if health <= 0.0:
			die(null)
			return
	_threat_scan -= delta
	if _threat_scan <= 0.0:
		_threat_scan = THREAT_SCAN
		_scan_for_threat()

	match state:
		State.IDLE:
			_tick_idle(delta)
		State.MOVING:
			_tick_move(delta)
		State.FLEEING:
			_tick_fleeing(delta)
		State.ATTACKING:
			_tick_attacking(delta)
		State.GRAZING:
			_tick_grazing(delta)
		State.EATING:
			_tick_eating(delta)
	_apply_sim_motion(delta)

	# Whatever the creature stepped into this frame answers for
	# itself — the spike trap was set for exactly this.
	var step := _standing_voxel()
	if step != _trap_cell:
		_trap_cell = step
		_colony.try_trap(step, self)


func current_activity() -> String:
	match state:
		State.MOVING:
			return "wandering"
		State.GRAZING:
			return "grazing"
		State.EATING:
			return "eating"
		State.FLEEING:
			return "fleeing %s" % _target_name()
		State.ATTACKING:
			return "attacking %s" % _target_name()
	return "idle"


func _target_name() -> String:
	if _target == null or not is_instance_valid(_target):
		return ""
	if _target is Animal:
		return _target.label()
	return "a settler"


## Something a flee-temperament animal runs from came close — today the
## only threats are units (predators announce themselves by biting).
func _scan_for_threat() -> void:
	if domestic:
		# A tame animal doesn't bolt from the hands that feed it.
		return
	var flee_range := Species.field(species, &"flee_range", 0.0)
	if flee_range <= 0.0 or state == State.FLEEING or _target != null:
		return
	var nearest: Unit = null
	var nearest_d := flee_range
	for unit in _colony.units:
		if (
			unit.job != null
			and unit.job.type == ColonyJob.Type.TAME
			and unit.job.animal == self
		):
			# The bait holds it — the working handler reads as company,
			# not a threat, or a session could never finish.
			continue
		var d := global_position.distance_to(unit.global_position)
		if d < nearest_d:
			nearest_d = d
			nearest = unit
	if nearest != null:
		_target = nearest
		state = State.FLEEING
		_flee_repath = 0.0


func _tick_idle(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_idle_cooldown -= delta
	if _idle_cooldown > 0.0:
		return
	_idle_cooldown = randf_range(1.5, 4.0)
	if (
		allowed_area != null
		and not allowed_area.cells.has(_standing_voxel())
	):
		# Out of bounds — head for the closest area cell and keep to
		# the pen. A flee that ran it out ends here.
		var home := _colony.nearest_area_cell(_standing_voxel(), allowed_area)
		if home != Vector3i.MAX:
			_walk_to(home)
		return
	if hunger < 0.5 and _seek_food():
		return
	_wander()


## The idle decision: find something edible and walk to it. Returns true
## when a goal was taken.
func _seek_food() -> bool:
	match StringName(_spec().get(&"diet", &"herbivore")):
		&"herbivore":
			if _seek_grass():
				return true
			# A penned herbivore with cropped-bare ground looks to the
			# trough — hay and kitchen scraps piled in its area.
			if domestic:
				return _seek_feed()
			return false
		&"carnivore":
			# Carrion first — a corpse pile beats a hunt.
			var corpse := _colony.nearest_form_voxel(
				_standing_voxel(), DropItem.Form.CORPSE, allowed_area, true
			)
			if corpse != Vector3i.MAX:
				_meal_voxel = corpse
				_walk_to(corpse)
				return true
			var meat := _colony.nearest_form_voxel(
				_standing_voxel(), DropItem.Form.LOOSE, allowed_area, true
			)
			# Loose piles aren't all meat — take_up_to filters at bite.
			if meat != Vector3i.MAX and _pile_has_meat(meat):
				_meal_voxel = meat
				_walk_to(meat)
				return true
			var prey := _nearest_prey()
			if prey != null:
				_target = prey
				state = State.ATTACKING
				return true
			return false
		_:
			# Omnivore: a corpse is food too, else grass — and for the
			# penned ones, whatever feed the colony piles inside.
			var corpse := _colony.nearest_form_voxel(
				_standing_voxel(), DropItem.Form.CORPSE, allowed_area, true
			)
			if corpse != Vector3i.MAX:
				_meal_voxel = corpse
				_walk_to(corpse)
				return true
			if _seek_grass():
				return true
			if domestic:
				return _seek_feed()
			return false
	return false


## The trough side of pen life: the nearest food pile inside the
## animal's own area — bait_ok rules out the meat a herbivore won't
## touch even when it's starving.
func _seek_feed() -> bool:
	var pile := _colony.nearest_bait_pile(
		_standing_voxel(), self, {}, allowed_area
	)
	if pile == Vector3i.MAX:
		return false
	_meal_voxel = pile
	_walk_to(pile)
	return true


func _seek_grass() -> bool:
	var grass := _colony.grass
	if grass == null:
		return false
	var here := _standing_voxel()
	for r in range(1, 25):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var cell := Vector3i(here.x + dx, here.y, here.z + dz)
				if (
					grass.grassed(cell)
					and Colony.in_area(allowed_area, cell)
				):
					_graze_cell = cell
					_walk_to(cell)
					return true
	return false


func _pile_has_meat(voxel_position: Vector3i) -> bool:
	var pile := _colony.item_pile_at(voxel_position)
	if pile == null:
		return false
	for item in pile.items:
		if item.material == BlockRegistry.Resource_.MEAT:
			return true
	return false


func _nearest_prey() -> Animal:
	var hunts: Array = _spec().get(&"hunts", [])
	if hunts.is_empty():
		return null
	var best: Animal = null
	var best_d := HUNT_RANGE
	for animal in _colony.animals:
		if (
			animal == self or not is_instance_valid(animal)
			or animal.dead or not hunts.has(animal.species)
			or not Colony.in_area(
				allowed_area, Vector3i(animal.global_position.floor())
			)
		):
			continue
		var d := global_position.distance_to(animal.global_position)
		if d < best_d:
			best_d = d
			best = animal
	return best


func _wander() -> void:
	var here := _standing_voxel()
	for attempt in 12:
		var cell := here + Vector3i(
			randi_range(-WANDER_MAX, WANDER_MAX),
			0,
			randi_range(-WANDER_MAX, WANDER_MAX)
		)
		if here.distance_to(cell) < WANDER_MIN:
			continue
		if not Colony.in_area(allowed_area, cell):
			continue
		cell.y = _world.ground_height(cell.x, cell.z, cell.y + 24) + 1
		if _is_standable(cell):
			_walk_to(cell)
			return


func _walk_to(cell: Vector3i) -> void:
	_goal_voxel = cell
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	state = State.MOVING
	_repath()


func _tick_move(delta: float) -> void:
	if _goal_in_reach():
		_arrive()
		return
	_follow_path(delta, _speed())


func _tick_fleeing(delta: float) -> void:
	if (
		_target == null
		or not is_instance_valid(_target)
		or global_position.distance_to(_target.global_position)
			> Species.field(species, &"flee_range", 9.0) * FLEE_SAFE_MULT
	):
		_target = null
		_to_idle()
		return
	_flee_repath -= delta
	if _flee_repath <= 0.0 or _goal_in_reach():
		_flee_repath = 1.5
		var away := (global_position - _target.global_position)
		away.y = 0.0
		var here := _standing_voxel()
		var cell := here + Vector3i(away.normalized() * 12.0)
		cell.y = _world.ground_height(cell.x, cell.z, cell.y + 24) + 1
		if _is_standable(cell):
			_goal_voxel = cell
			_repath()
	_flee_elapsed += delta
	var speed := _speed()
	if _flee_elapsed > FLEE_TIRE_SEC:
		speed *= FLEE_TIRED_MULT
	_follow_path(delta, speed)


func _tick_attacking(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		_target = null
		_to_idle()
		return
	if _target is Animal and _target.dead:
		# Prey down — eat the kill.
		_target = null
		var corpse := _colony.nearest_form_voxel(
			_standing_voxel(), DropItem.Form.CORPSE, allowed_area, true
		)
		if corpse != Vector3i.MAX:
			_meal_voxel = corpse
			_walk_to(corpse)
		else:
			_to_idle()
		return
	var distance := global_position.distance_to(_target.global_position)
	if distance > DISENGAGE_RANGE:
		_target = null
		_to_idle()
		return
	if distance <= MELEE_RANGE:
		velocity.x = 0.0
		velocity.z = 0.0
		_target.take_hit(Species.field(species, &"melee", 0.0) * delta, self)
		return
	# Chase: the goal follows the target, repathing when it moves a cell.
	var cell: Vector3i = (
		_target._standing_voxel()
		if _target is Animal
		else Vector3i(_target.global_position.floor())
	)
	if cell != _goal_voxel and _repath_cooldown <= 0.0:
		_goal_voxel = cell
		_repath()
	_follow_path(delta, _speed())


func _tick_grazing(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var grass := _colony.grass
	if grass == null or hunger >= 1.0:
		_graze_cell = Vector3i.MAX
		_to_idle()
		return
	if not _goal_in_reach():
		state = State.MOVING
		return
	if grass.coverage_at(_graze_cell) <= 0.0:
		# Cropped bare — look one ring over for more.
		var here := _standing_voxel()
		var found := Vector3i.MAX
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell := Vector3i(here.x + dx, here.y, here.z + dz)
				if (
					grass.grassed(cell)
					and Colony.in_area(allowed_area, cell)
				):
					found = cell
					break
			if found != Vector3i.MAX:
				break
		if found == Vector3i.MAX:
			_graze_cell = Vector3i.MAX
			_to_idle()
			return
		_graze_cell = found
		_walk_to(found)
		return
	var bite := minf(GRAZE_RATE * delta, grass.coverage_at(_graze_cell))
	grass.crop(_graze_cell, bite)
	hunger = minf(hunger + bite * GRAZE_NUTRITION, 1.0)


func _tick_eating(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	if hunger >= 1.0:
		_meal_voxel = Vector3i.MAX
		_to_idle()
		return
	if not _goal_in_reach():
		state = State.MOVING
		return
	var pile := _colony.item_pile_at(_meal_voxel)
	if pile == null:
		_meal_voxel = Vector3i.MAX
		_to_idle()
		return
	var bite := pile.take_up_to(BITE_CM3, func(item: DropItem) -> bool:
		return (
			item.form == DropItem.Form.CORPSE
			or item.material == BlockRegistry.Resource_.MEAT
			or (domestic and bait_ok(item))
		), true)
	if bite.is_empty():
		_meal_voxel = Vector3i.MAX
		_to_idle()
		return
	var nutrition := 0.0
	for item in bite:
		# Flesh is flesh for hunger — a corpse feeds at the meat rate
		# (its own material carries no nutrition entry); everything
		# else prices by what it is.
		nutrition += (
			DropItem.nutrition_of(BlockRegistry.Resource_.MEAT, item.volume)
			if item.form == DropItem.Form.CORPSE
			else item.nutrition_value()
		)
	hunger = minf(hunger + nutrition, 1.0)
	_colony.remove_pile_if_empty(_meal_voxel)


## Shared path-follower: waypoint walk, stuck watchdog, repath on
## exhaustion. Returns early when the goal is reached.
func _follow_path(delta: float, speed: float) -> void:
	var goal_distance := global_position.distance_to(
		Vector3(_goal_voxel) + Vector3(0.5, 0.5, 0.5)
	)
	if goal_distance < _best_goal_distance - STUCK_PROGRESS:
		_best_goal_distance = goal_distance
		_stuck_elapsed = 0.0
	else:
		_stuck_elapsed += delta
		if _stuck_elapsed > STUCK_TIMEOUT:
			_to_idle()
			return
	if _path_index >= _path.size():
		if _repath_cooldown > 0.0:
			return
		if not _repath():
			_to_idle()
		return
	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	if flat_distance < maxf(WAYPOINT_RADIUS, speed * delta):
		_path_index += 1
		return
	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	# Mounds and clutter underfoot slow paws the same as boots — and a
	# fence in the route is a rail this body can't climb at all. The
	# pathfinder refuses them, so a 0 here means the route predates the
	# rail: climb off if we're standing on it, repath otherwise.
	var crawl := minf(
		_colony.traversal_mult(Vector3i(waypoint.floor()), self),
		_colony.traversal_mult(_standing_voxel(), self)
	)
	if crawl <= 0.0:
		if _colony.traversal_mult(_standing_voxel(), self) <= 0.0:
			crawl = FENCE_ESCAPE
		else:
			_repath()
			return
	velocity.x = direction.x * speed * crawl
	velocity.z = direction.z * speed * crawl
	if _grounded and (to_waypoint.y > 0.6 or _blocked_horiz):
		# The sim step takes a jump impulse; animals use the same one.
		_want_jump = true


var _want_jump := false
var _want_descend := false


func _speed() -> float:
	return Species.field(species, &"speed", 4.0)


func _repath() -> bool:
	_repath_cooldown = 1.0
	# no_fences — the pen rail a settler hops is a wall to this body.
	# ignore_traps — hoof and claw don't know where the stakes are.
	_path = _world.find_path(
		_standing_voxel(), _goal_voxel, 24, false, false, true, true,
		_sim_id
	)
	_path_index = 0
	if _path.is_empty():
		# The goal cell itself may be unreachable (a packed pile, water).
		# Try its standable ring before giving up on the outing.
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var alt := _goal_voxel + Vector3i(dx, 0, dz)
				if not _is_standable(alt):
					continue
				_path = _world.find_path(
					_standing_voxel(), alt, 24, false, false, true, true,
					_sim_id
				)
				if not _path.is_empty():
					_path_index = 0
					return true
		return false
	return true


func _arrive() -> void:
	_path.clear()
	if _graze_cell != Vector3i.MAX:
		state = State.GRAZING
	elif _meal_voxel != Vector3i.MAX:
		state = State.EATING
	else:
		_to_idle()


func _to_idle() -> void:
	_path.clear()
	_goal_voxel = Vector3i.MAX
	_graze_cell = Vector3i.MAX
	_meal_voxel = Vector3i.MAX
	_flee_elapsed = 0.0
	_idle_cooldown = randf_range(1.0, 3.0)
	state = State.IDLE


func _goal_in_reach() -> bool:
	if not _grounded or _goal_voxel == Vector3i.MAX:
		return false
	return (
		global_position.distance_to(
			Vector3(_goal_voxel) + Vector3(0.5, 0.5, 0.5)
		) <= ARRIVE_RANGE
	)


func _standing_voxel() -> Vector3i:
	return Vector3i(
		floori(global_position.x),
		floori(global_position.y - 0.9 + 0.001),
		floori(global_position.z)
	)


func _is_standable(voxel_position: Vector3i) -> bool:
	# A rail isn't a floor — a fence cell never makes a destination,
	# whatever else is under it.
	var rail := _colony.building_at(voxel_position)
	if rail != null and rail.kind == Building.Kind.FENCE:
		return false
	if _world.sim != null:
		return _world.sim.is_unit_standable(voxel_position)
	return (
		not _world.is_solid(voxel_position)
		and not _colony.is_dense_pile(voxel_position)
		and _colony.is_flooring(voxel_position + Vector3i.DOWN)
	)


## External damage — a hunt's melee or a predator's bite. Fight
## temperaments turn on their attacker; flee temperaments bolt.
## [param _kind] is the wound the hit opens — unused while animals
## track one pooled health bar, kept for the signature take_hit
## shares with Unit so a trap or arrow doesn't care what it hits.
func take_hit(damage: float, attacker: Node3D, _kind := &"") -> void:
	if dead:
		return
	health -= damage
	# Stray force lands around the fight — cover, walls and ground near
	# the quarry erode while the blows rain down.
	if _colony != null and attacker != null and is_instance_valid(attacker):
		_colony.combat_splash(global_position, attacker.global_position, damage)
		# Bloodied prey marks the ground where the blow landed.
		_colony.add_mess(
			_standing_voxel(), &"blood",
			minf(damage * Colony.BLOOD_PER_DAMAGE, 1.0)
		)
	if health <= 0.0:
		die(attacker)
		return
	if _target != attacker:
		_target = attacker
		if StringName(_spec().get(&"temperament", &"flee")) == &"fight":
			state = State.ATTACKING
			_path.clear()
		elif state != State.FLEEING:
			state = State.FLEEING
			_flee_repath = 0.0


## Death: leave the carcass as a physical corpse item — the animal
## becomes part of the item economy — and free the node.
## [param _killer] is unused today but is the hook for predator XP and
## thoughts later.
func die(_killer: Node3D) -> void:
	if dead:
		return
	dead = true
	if _colony != null:
		_colony._drop_item(_colony.make_corpse(species), _standing_voxel())
		died.emit(self)
	queue_free()


## Persisted with the colony — species, position, and the needs that
## carry over. Live state (a chase, a graze) re-derives on load.
func serialize() -> Dictionary:
	return {
		"species": String(species),
		"position": [
			global_position.x, global_position.y, global_position.z
		],
		"health": health,
		"hunger": hunger,
		"domestic": domestic,
		"tame_progress": tame_progress,
	}


func deserialize(data: Dictionary) -> void:
	species = StringName(data.get("species", "rabbit"))
	health = float(data.get("health", Species.field(species, &"health", 60.0)))
	hunger = float(data.get("hunger", 0.8))
	domestic = bool(data.get("domestic", false))
	tame_progress = float(
		data.get("tame_progress", 1.0 if domestic else 0.0)
	)


func _apply_sim_motion(delta: float) -> void:
	var sim_pos: Vector3 = _world.sim.unit_pos(_sim_id)
	if global_position.distance_squared_to(sim_pos) > 0.0025:
		_world.sim.unit_register(_sim_id, global_position)
	var heading := Vector3(velocity.x, 0.0, velocity.z)
	if (
		state == State.IDLE
		or state == State.GRAZING
		or state == State.EATING
	):
		heading = heading.move_toward(Vector3.ZERO, _speed())
	var res: Dictionary = _world.sim.unit_step(
		_sim_id, heading, JUMP_SPEED if _want_jump else 0.0, GRAVITY,
		delta, 0.0
	)
	_want_jump = false
	global_position = res["pos"]
	_grounded = res["grounded"]
	_blocked_horiz = res["blocked"]
	velocity = Vector3(heading.x, res["vel_y"], heading.z)
