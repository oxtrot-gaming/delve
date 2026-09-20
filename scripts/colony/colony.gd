class_name Colony
extends Node3D

## Owns the colony state: the job board, the colonists and the stockpile.
##
## The player never mines directly; they designate work, colonists claim jobs
## from here and report back when the work is done.

signal job_added(job: ColonyJob)
signal job_finished(job: ColonyJob)
signal stockpile_changed(resource: BlockRegistry.Resource_, amount: int)
signal colonist_spawned(colonist: Colonist)

const COLONIST_SCENE := preload("res://scenes/colonist.tscn")

@export var world_path: NodePath = NodePath("../VoxelWorld")
@export var initial_colonists: int = 3
## Radius, in voxels, of the area colonists spawn in around the colony origin.
@export var spawn_radius: int = 6

var world: VoxelWorld
var jobs: Array[ColonyJob] = []
var colonists: Array[Colonist] = []
var stockpile: Dictionary[BlockRegistry.Resource_, int] = {}

var _designation_markers: Dictionary[Vector3i, Node3D] = {}
var _marker_mesh: BoxMesh
var _marker_material: StandardMaterial3D


func _ready() -> void:
	world = get_node(world_path)
	_marker_mesh = BoxMesh.new()
	_marker_mesh.size = Vector3.ONE * 1.02
	_marker_material = StandardMaterial3D.new()
	_marker_material.albedo_color = Color(1.0, 0.85, 0.2, 0.35)
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


## Queues a mining job, unless that voxel is already designated.
func designate_mine(voxel_position: Vector3i) -> ColonyJob:
	if _designation_markers.has(voxel_position):
		return null
	if not world.is_solid(voxel_position):
		return null

	var job := ColonyJob.new(ColonyJob.Type.MINE, voxel_position)
	jobs.append(job)
	_add_marker(voxel_position)
	job_added.emit(job)
	return job


func cancel_designation(voxel_position: Vector3i) -> void:
	for job in jobs:
		if job.voxel_position == voxel_position and job.is_active():
			job.state = ColonyJob.State.CANCELLED
			if job.assignee != null and job.assignee.has_method(&"abandon_job"):
				job.assignee.abandon_job()
	_remove_marker(voxel_position)
	_prune_jobs()


## Closest open job to [param from_position], claimed for [param colonist].
func claim_job(colonist: Colonist) -> ColonyJob:
	var best: ColonyJob = null
	var best_distance := INF
	for job in jobs:
		if not job.is_open():
			continue
		var distance := Vector3(job.voxel_position).distance_squared_to(colonist.global_position)
		if distance < best_distance:
			best_distance = distance
			best = job
	if best != null:
		best.state = ColonyJob.State.ASSIGNED
		best.assignee = colonist
	return best


func release_job(job: ColonyJob) -> void:
	if job.state == ColonyJob.State.ASSIGNED:
		job.state = ColonyJob.State.PENDING
		job.assignee = null


func complete_job(job: ColonyJob, mined_block_id: int) -> void:
	job.state = ColonyJob.State.DONE
	job.assignee = null
	_remove_marker(job.voxel_position)
	var drop := BlockRegistry.drop_of(mined_block_id)
	if drop != BlockRegistry.Resource_.NONE:
		add_resource(drop, 1)
	job_finished.emit(job)
	_prune_jobs()


func add_resource(resource: BlockRegistry.Resource_, amount: int) -> void:
	stockpile[resource] = stockpile.get(resource, 0) + amount
	stockpile_changed.emit(resource, stockpile[resource])


func resource_count(resource: BlockRegistry.Resource_) -> int:
	return stockpile.get(resource, 0)


func open_job_count() -> int:
	var count := 0
	for job in jobs:
		if job.is_active():
			count += 1
	return count


## Drops colonists on solid ground around [param origin].
func spawn_initial_colonists(origin: Vector3i) -> void:
	for i in initial_colonists:
		var angle := TAU * float(i) / float(maxi(initial_colonists, 1))
		var offset := Vector3i(int(cos(angle) * spawn_radius), 0, int(sin(angle) * spawn_radius))
		spawn_colonist(origin + offset)


func spawn_colonist(near_voxel: Vector3i) -> Colonist:
	var ground_y := world.ground_height(near_voxel.x, near_voxel.z, near_voxel.y + 32)
	var colonist: Colonist = COLONIST_SCENE.instantiate()
	colonist.name = "Colonist%d" % (colonists.size() + 1)
	add_child(colonist)
	colonist.global_position = Vector3(near_voxel.x + 0.5, ground_y + 1.5, near_voxel.z + 0.5)
	colonist.setup(world, self)
	colonists.append(colonist)
	colonist_spawned.emit(colonist)
	return colonist


func _add_marker(voxel_position: Vector3i) -> void:
	var marker := MeshInstance3D.new()
	marker.mesh = _marker_mesh
	marker.material_override = _marker_material
	marker.position = Vector3(voxel_position) + Vector3.ONE * 0.5
	add_child(marker)
	_designation_markers[voxel_position] = marker


func _remove_marker(voxel_position: Vector3i) -> void:
	var marker: Node3D = _designation_markers.get(voxel_position)
	if marker != null:
		marker.queue_free()
		_designation_markers.erase(voxel_position)


func _prune_jobs() -> void:
	jobs = jobs.filter(func(job: ColonyJob) -> bool: return job.is_active())
