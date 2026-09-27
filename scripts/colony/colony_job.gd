class_name ColonyJob
extends RefCounted

## A unit of work the colony wants done at a voxel position.

enum Type {
	MINE, BUILD, CLEAR, HAUL, CHOP, CRAFT, DECONSTRUCT, FURNISH, REST, FORAGE, EAT
}
enum State { PENDING, ASSIGNED, DONE, CANCELLED }

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
## The building kind a FURNISH job assembles — what the delivered kit
## unpacks into.
var furniture_kind: Building.Kind = Building.Kind.WORKSITE
## Extra cells beyond [member voxel_position] that a multi-voxel job
## occupies — the bed's second cell. Markers, plan ghosts and cancel
## sweeps all treat these as the job's own.
var extra_voxels: Array[Vector3i] = []


func _init(job_type: Type, position: Vector3i) -> void:
	type = job_type
	voxel_position = position


func is_open() -> bool:
	return state == State.PENDING


func is_active() -> bool:
	return state == State.PENDING or state == State.ASSIGNED
