class_name ColonyJob
extends RefCounted

## A unit of work the colony wants done at a voxel position.

enum Type { MINE, BUILD }
enum State { PENDING, ASSIGNED, DONE, CANCELLED }

var type: Type
var voxel_position: Vector3i
var state: State = State.PENDING
var assignee: Node = null
## Work already done on this job, in seconds of unit labour.
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
