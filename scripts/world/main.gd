extends Node3D

## Boots the prototype: waits for the terrain around the colony site to stream
## in, then drops the starting units on it.

@export var colony_site := Vector3i(0, 0, 0)

@onready var world: VoxelWorld = $VoxelWorld
@onready var colony: Colony = $Colony

var _units_spawned: bool = false


func _process(_delta: float) -> void:
	if _units_spawned:
		return
	var surface_y := world.predicted_surface_height(colony_site.x, colony_site.z)
	var site := Vector3i(colony_site.x, surface_y, colony_site.z)
	if not world.is_area_meshed(AABB(Vector3(site) - Vector3.ONE * 16.0, Vector3.ONE * 32.0)):
		return
	colony.spawn_initial_units(site)
	_units_spawned = true
