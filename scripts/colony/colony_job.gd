class_name ColonyJob
extends RefCounted

## A unit of work the colony wants done at a voxel position.

enum Type { MINE, BUILD, CLEAR, HAUL, CHOP }
enum State { PENDING, ASSIGNED, DONE, CANCELLED }

var type: Type
var voxel_position: Vector3i
var state: State = State.PENDING
var assignee: Node = null
## Units that dropped this job — unit → {at: msec, n: consecutive drops}.
## A unit waits before claiming the job again so a stuck assignment doesn't
## get re-taken in a loop; repeated failures stretch the wait.
var dropped_by: Dictionary = {}
## Work already done on this job: seconds of mining labour, or cubic
## centimetres of material gathered for a build. Kept float-typed since it
## serves both; build progress is whole cm³.
var progress: float = 0.0
## Block to place, for [constant Type.BUILD] jobs — set when the job's
## material commits.
var block_id: int = BlockRegistry.Block.DIRT
## Wall material a BUILD job committed to — the first load a fetcher
## picks decides it; NONE until then.
var material: BlockRegistry.Resource_ = BlockRegistry.Resource_.NONE


func _init(job_type: Type, position: Vector3i) -> void:
	type = job_type
	voxel_position = position


func is_open() -> bool:
	return state == State.PENDING


func is_active() -> bool:
	return state == State.PENDING or state == State.ASSIGNED
