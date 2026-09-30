class_name WorksiteOrder
extends RefCounted

## One queued bill on a worksite — RimWorld's bill model: a recipe plus
## the condition that decides when it's done ordering. The queue itself
## lives on the worksite's [Building] record; an order carries no
## inputs — items escrow into the *job* once it runs, so a queued order
## is pure intent and a cancelled one loses nothing.
enum Condition {
	## Run the recipe [member target] more times, then leave the queue.
	TIMES,
	## Keep the recipe running while the colony holds fewer than
	## [member target] of the recipe's output; pauses in place while
	## stocked, resumes when the count drops to [member unpause_at].
	UNTIL_HAVE,
	## Run the recipe whenever inputs exist, forever.
	FOREVER,
}

## Where a run's products end up — RimWorld's "product destination".
enum Deliver {
	## Drop the products at the worksite (haulers may still move them).
	FEET,
	## The worker carries them to the best stockpile admitting them —
	## highest [member StockpileZone.priority] first, then nearest.
	BEST_STOCKPILE,
	## The worker carries them to the zone [member deliver_target]
	## belongs to — RimWorld's "Take to X".
	ZONE,
}

## Which entry in [constant Colony.RECIPES] this order runs.
var recipe: StringName = &""
var condition: Condition = Condition.TIMES
## Run count for [constant TIMES], stock target for [constant UNTIL_HAVE];
## ignored by [constant FOREVER].
var target: int = 1
## Successful runs so far — what [constant TIMES] counts against.
var done: int = 0
## Manually suspended — the bill keeps its place in line but dispatches
## nothing; a live run is paused with it.
var paused := false
## Stock count an UNTIL_HAVE bill resumes at once parked — "unpause at"
## in RimWorld. -1 means "the target minus one": any dip below the
## target wakes it (the behaviour before the knob existed). Clampable
## to 0 for "only restart once the stock runs dry".
var unpause_at: int = -1
## True while an UNTIL_HAVE bill sits satisfied — parked on a full
## stock count, waiting for the drop to [member unpause_at].
var satisfied := false
## When true an UNTIL_HAVE count only totals items on stockpile tiles —
## RimWorld's "items not in a stockpile are not counted". Off keeps the
## older every-landed-pile count.
var count_stored_only := false
var deliver_mode: Deliver = Deliver.FEET
## A cell of the zone [constant Deliver.ZONE] ships to. The zone itself
## is looked up live — the stored voxel is just a handle into it.
var deliver_target: Vector3i = Vector3i.MAX
## Metres a fetch may range from the worksite for inputs — 0 = anywhere.
var ingredient_radius := 0.0
## Index into [member Colony.units] this bill is pinned to, or -1 for
## any worker — RimWorld's worker selection.
var worker_index := -1
## Skill band the recipe's skill must fall in for a unit to take the
## bill — RimWorld's allowed-skill min/max.
var skill_min := 0
var skill_max := 20
## Rejected input material ints — an empty set admits anything of the
## right form. RimWorld's per-bill ingredient filter, material-class
## granularity: a berry-only seed press rejects GRAIN fruit.
var rejected_materials: Dictionary = {}


## Whether this order wants work right now — a satisfied UNTIL_HAVE
## isn't unperformable, it's parked: it keeps its place in line and
## waits for the stock count to dip to [member unpause_at].
func wants_work(have: int) -> bool:
	match condition:
		Condition.TIMES:
			return done < target
		Condition.FOREVER:
			return true
		Condition.UNTIL_HAVE:
			if satisfied:
				if have <= unpause_level():
					satisfied = false
				else:
					return false
			elif have >= target:
				satisfied = true
				return false
			return true
	return false


## The count that wakes a parked until-bill: [member unpause_at] when
## set, else one under the target — "stock dips below X" semantics.
func unpause_level() -> int:
	return unpause_at if unpause_at >= 0 else maxi(target - 1, 0)


## Whether an item of [param material] may feed this bill's inputs.
func admits_material(material: BlockRegistry.Resource_) -> bool:
	return not rejected_materials.get(int(material), false)


## The fields a "copy bill" carries over — everything but the progress.
func copy_into(other: WorksiteOrder) -> void:
	other.recipe = recipe
	other.condition = condition
	other.target = target
	other.unpause_at = unpause_at
	other.count_stored_only = count_stored_only
	other.deliver_mode = deliver_mode
	other.deliver_target = deliver_target
	other.ingredient_radius = ingredient_radius
	other.worker_index = worker_index
	other.skill_min = skill_min
	other.skill_max = skill_max
	other.rejected_materials = rejected_materials.duplicate()


## Player-facing summary for the queue row — "×3 (1/3)",
## "≥6 (4 there)", "∞ (7 done)"; a parked until-bill and a suspended
## bill say so.
func summary(have: int) -> String:
	var text := ""
	match condition:
		Condition.TIMES:
			text = "×%d (%d/%d)" % [target, done, target]
		Condition.UNTIL_HAVE:
			text = "≥%d (%d there)" % [target, have]
			if satisfied:
				text += ", parked"
		Condition.FOREVER:
			text = "∞ (%d done)" % done
	if paused:
		text = "⏸ " + text
	return text
