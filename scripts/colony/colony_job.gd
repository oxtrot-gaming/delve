class_name ColonyJob
extends RefCounted

## A unit of work the colony wants done at a voxel position.

enum Type { MINE, BUILD, CLEAR, HAUL }
enum State { PENDING, ASSIGNED, DONE, CANCELLED }

var type: Type
var voxel_position: Vector3i
var state: State = State.PENDING
var assignee: Node = null
## Units that dropped this job (timestamp in msec) — they wait before
## claiming it again so a stuck assignment doesn't get re-taken in a loop.
var dropped_by: Dictionary = {}
## Work already done on this job: seconds of mining labour, or cubic metres
## of material gathered for a build.
var progress: float = 0.0
## Block to place, for [constant Type.BUILD] jobs.
var block_id: int = BlockRegistry.Block.PLANKS


func _init(job_type: Type, position: Vector3i) -> void:
	type = job_type
	voxel_position = position


func is_open() -> bool:
	return state == State.PENDING


func is_active() -> bool:
	return state == State.PENDING or state == State.ASSIGNED
