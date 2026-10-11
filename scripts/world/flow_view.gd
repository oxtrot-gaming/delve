class_name FlowView
extends Node3D

## Water-flow overlay — flat arrows laid on the live waterline, one
## per surface cell the sim reports flux for. The native sim emits
## [voxel, flux] pairs from the last water step; each arrow's yaw
## comes from the flux's xz direction and its length and shade from
## the cm³ magnitude. A polling view rather than a signal-driven one:
## the flux field is per-step, so the overlay just re-reads it at the
## water cadence while the toggle is on.
##
## Cells whose flux is mostly vertical — a pour over a bank, a
## waterfall — don't take a yaw: they draw as a small marker instead
## of a meaningless sideways arrow.

var _world: VoxelWorld
var _mmi: MultiMeshInstance3D
var _elapsed := 0.0

## Poll interval — the water steps at 0.2 s, so a touch under two
## steps keeps arrows fresh without re-reading mid-step.
const POLL_SEC := 0.3
## Arrows never exceed this — a storm-front flux field would
## otherwise build tens of thousands of instances in one frame. The
## sampler strides over the field instead, so coverage stays even
## when the set overflows.
const MAX_ARROWS := 8192
## cm³/step that maps to a full-cell arrow — a threshold river runs
## well under it, a big reach saturates it.
const LEN_REF := 120000.0
## Draw this far above the live surface — same trick the skin's
## SKIN_EPS uses, so arrows never z-fight the water plane.
const LIFT := 0.12
## Below this a cell's flux is rain-churn noise, not current — the
## sim's own move threshold is 10k; twice that keeps the overlay to
## flow a player could act on.
const MIN_FLUX := 20000.0


func _enter_tree() -> void:
	# The overlay is presentation — a paused sim keeps its last flux
	# field, and a paused pan shouldn't blank it.
	process_mode = Node.PROCESS_MODE_ALWAYS


func install(world: VoxelWorld) -> void:
	_world = world
	if _mmi != null:
		return
	_mmi = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _arrow_mesh()
	mm.instance_count = MAX_ARROWS
	mm.visible_instance_count = 0
	_mmi.multimesh = mm
	_mmi.material_override = SliceView.vcolor()
	add_child(_mmi)
	visible = false


func set_enabled(on: bool) -> void:
	if _mmi == null:
		return
	visible = on
	if on:
		_refresh()
	elif _mmi.multimesh != null:
		_mmi.multimesh.visible_instance_count = 0


func _process(delta: float) -> void:
	if not visible or _world == null or _world.sim == null:
		return
	_elapsed += delta
	if _elapsed >= POLL_SEC:
		_elapsed = 0.0
		_refresh()


func _refresh() -> void:
	var field: PackedVector3Array = _world.sim.water_flow_field()
	var mm := _mmi.multimesh
	var count := field.size() / 2
	if count <= 0:
		mm.visible_instance_count = 0
		return
	var stride := maxi(1, count / MAX_ARROWS)
	var drawn := 0
	for k in range(0, count, stride):
		var pos := field[k * 2]
		var f := field[k * 2 + 1]
		var total := f.length()
		if total < MIN_FLUX:
			continue
		var surf := _world.water_surface_at(int(pos.x), int(pos.z))
		var mag := Vector2(f.x, f.z).length()
		var t: Transform3D
		if mag < total * 0.15:
			# Near-vertical — a pour or a waterfall. A sideways yaw
			# would lie, so a small marker stands in for the arrow.
			t = Transform3D(
				Basis.from_scale(Vector3.ONE * 0.3),
				Vector3(pos.x + 0.5, surf + LIFT, pos.z + 0.5)
			)
		else:
			var len: float = clampf(total / LEN_REF, 0.4, 1.8)
			var basis := Basis().rotated(
				Vector3.UP, -atan2(f.z, f.x)
			)
			basis = basis.scaled(Vector3(len, 1.0, clampf(len, 0.3, 1.0)))
			t = Transform3D(
				basis, Vector3(pos.x + 0.5, surf + LIFT, pos.z + 0.5)
			)
		mm.set_instance_transform(drawn, t)
		# The palette must read against the blue-grey skin: slow water
		# gets a pale cyan-white, fast water warms toward gold.
		var speed := clampf(total / 400000.0, 0.0, 1.0)
		mm.set_instance_color(
			drawn,
			Color(0.55, 0.95, 1.0).lerp(Color(1.0, 0.9, 0.4), speed)
		)
		drawn += 1
		if drawn >= MAX_ARROWS:
			break
	mm.visible_instance_count = drawn


## Flat arrow in the XZ plane pointing +X, ~1.6 m nose-to-tail, wound
## so the top face's normal is +Y (the slice material culls backs).
static func _arrow_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Tail quad: (-0.75,±0.15) → (0.15,±0.15); head: (0.15,±0.42) → (0.85,0).
	st.add_vertex(Vector3(-0.75, 0, -0.15))
	st.add_vertex(Vector3(0.15, 0, 0.15))
	st.add_vertex(Vector3(0.15, 0, -0.15))
	st.add_vertex(Vector3(-0.75, 0, -0.15))
	st.add_vertex(Vector3(-0.75, 0, 0.15))
	st.add_vertex(Vector3(0.15, 0, 0.15))
	st.add_vertex(Vector3(0.15, 0, -0.42))
	st.add_vertex(Vector3(0.15, 0, 0.42))
	st.add_vertex(Vector3(0.85, 0, 0.0))
	return st.commit()
