class_name ColonyJob
extends RefCounted

## A unit of work the colony wants done at a voxel position.

enum Type {
	MINE, BUILD, CLEAR, HAUL, CHOP, CRAFT, DECONSTRUCT, FURNISH, REST, FORAGE, EAT,
	SOW
}
enum State { PENDING, ASSIGNED, DONE, CANCELLED }
## Worker skills — the disciplines a job type can train and benefit from.
## Not exhaustive: new task kinds will add entries.
enum Skill { MINING, CONSTRUCTION, PLANTS, CRAFTING }

## Job type → skill trained by it. Types missing here are unskilled
## labour — anyone works them at base speed and they grant no XP.
const SKILL_FOR := {
	Type.MINE: Skill.MINING,
	Type.BUILD: Skill.CONSTRUCTION,
	Type.DECONSTRUCT: Skill.CONSTRUCTION,
	Type.FURNISH: Skill.CONSTRUCTION,
	Type.CHOP: Skill.PLANTS,
	Type.FORAGE: Skill.PLANTS,
	Type.SOW: Skill.PLANTS,
	Type.CRAFT: Skill.CRAFTING,
}
## Display name per skill — the colonist panel's rows.
const SKILL_NAMES := {
	Skill.MINING: "Mining",
	Skill.CONSTRUCTION: "Construction",
	Skill.PLANTS: "Plants",
	Skill.CRAFTING: "Crafting",
}
## Skill XP granted for finishing a job of each type — flat for now; a
## per-task scale (e.g. by hardness or recipe size) can replace it once
## balancing calls for it.
const XP_FOR := {
	Type.MINE: 6.0,
	Type.BUILD: 5.0,
	Type.DECONSTRUCT: 3.0,
	Type.FURNISH: 4.0,
	Type.CHOP: 5.0,
	Type.FORAGE: 3.0,
	Type.SOW: 3.0,
	Type.CRAFT: 5.0,
}

var type: Type
var voxel_position: Vector3i
var state: State = State.PENDING
var assignee: Node = null
## Units that dropped this job — unit → {at: msec, n: consecutive drops}.
## A unit waits before claiming the job again so a stuck assignment doesn't
## get re-taken in a loop; repeated failures stretch the wait.
var dropped_by: Dictionary = {}
## Work already done on this job: seconds of mining, crafting or
## deconstructing labour.
var progress: float = 0.0
## Block to place, for [constant Type.BUILD] jobs — decided by the
## material the job was ordered with.
var block_id: int = BlockRegistry.Block.DIRT
## Wall material a BUILD job was ordered with — the player's pick decides
## which wall this is, and it never changes: a wall whose material runs
## out waits for more rather than becoming a different wall.
var material: BlockRegistry.Resource_ = BlockRegistry.Resource_.NONE
## Material a BUILD job has absorbed so far, per item form — checked
## against the recipe's per-form cm³.
var delivered: Dictionary = {}
## The items absorbed into a BUILD job's wall — or escrowed as a CRAFT
## job's inputs — kept intact so the construction can hand back exactly
## what went in on deconstruction, or the cancelled order drops it.
var components: Array[DropItem] = []
## Which entry in [constant Colony.RECIPES] a CRAFT job is running.
var recipe: StringName = &""
## The worksite bill a CRAFT job is running for — null for orders that
## never go through a worksite queue (a ladder's `builds` order).
var order: WorksiteOrder = null
## The crop a SOW job plants — a Plants or Forest species key, set from
## the farm field's assignment. The seed item it fetches must carry the
## same species.
var species: StringName = &""
## The building kind a FURNISH job assembles — what the delivered kit
## unpacks into.
var furniture_kind: Building.Kind = Building.Kind.WORKSITE
## Extra cells beyond [member voxel_position] that a multi-voxel job
## occupies — the bed's second cell. Markers, plan ghosts and cancel
## sweeps all treat these as the job's own.
var extra_voxels: Array[Vector3i] = []

## A suspended job stays designated and on the board but can't be
## claimed — today the only suspension is a build waiting for a
## neighbouring placement that would support its block.
var suspended := false
## Self-issued by a starving unit rather than posted on the colony's
## board — a desperation forage and the meal that follows it. Such jobs
## are never registered, so a give-up blacklists the goal rather than
## re-posting the work.
var desperate := false
## When the job hit the board — claim scoring grows more eager the
## longer a job waits, so old work eventually wins over closer picks.
var posted_msec := 0


func _init(job_type: Type, position: Vector3i) -> void:
	type = job_type
	voxel_position = position


func is_open() -> bool:
	return state == State.PENDING and not suspended


func is_active() -> bool:
	return state == State.PENDING or state == State.ASSIGNED
