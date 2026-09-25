#pragma once

#include "delve_generator.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <array>
#include <cstdint>
#include <fstream>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace delve {

// Bounded voxel mirror for the simulation hot path.
//
// VoxelTerrain stays the presentation/streaming layer; this class keeps a
// sparse copy of the voxel data (16³ chunks, u8 block ids) so the sim
// queries a flat array instead of going through VoxelTool.
//
// Chunks materialize lazily: the mirror is a pure function of the
// deterministic terrain generator plus recorded edits, so a chunk is only
// generated when the sim first touches it — streamed terrain the sim
// never queries never costs anything. `on_block_unloaded` erases the
// chunk, matching the terrain (which forgets edits on unload).
//
// Pile fill lives in a voxel-keyed int32 map (cubic centimetres, matching
// GDScript's integer volume model) so it survives chunk materialization;
// Colony pushes it through set_pile_fill. A voxel is "packed" at exactly
// BLOCK_CM3 — no epsilon.
//
// `loaded_blocks` tracks which data blocks the terrain has streamed in —
// the native equivalent of VoxelTool.is_area_editable. Spill/settle walks
// stop at the loaded edge even though chunk *contents* materialize lazily.
//
// The native A* replicates VoxelAStarGrid3D's movement rules (8
// horizontal directions, +1 jump when hemmed in, falls up to 3, 1×2×1
// agent fit) and can optionally treat packed piles as solid.
//
// The job board mirrors claim-relevant ColonyJob state (voxel, claimed,
// per-unit drop records) so claim_job is a native scan instead of a
// per-job GDScript pass. ColonyJob stays the data store — the board only
// indexes eligibility.
class DelveSim : public godot::RefCounted {
	GDCLASS(DelveSim, godot::RefCounted)

	static constexpr int CHUNK = 16;
	static constexpr int CHUNK_CELLS = CHUNK * CHUNK * CHUNK;
	static constexpr int MAX_FALL_HEIGHT = 3;
	static constexpr float MAX_PATH_COST = 1000.0f;
	// Backstop for pathological searches (unreachable targets): the
	// endpoint+margin box bounds the space semantically, this bounds the
	// work. Hit it and the call reports unreachable, like AStarGrid3D.
	static constexpr size_t MAX_PATH_NODES = 65536;
	// VoxelAStarGrid3D defaults: 0.8×1.8×0.8 — fits a 1×2×1 voxel box.
	static constexpr float AGENT_XZ = 0.4f; // half-extent
	static constexpr float AGENT_Y = 0.9f;

	// Item/pile volumes in cubic centimetres — mirrors DropItem's
	// constants; 1 m³ = 1,000,000 cm³ exactly.
	static constexpr int32_t BLOCK_CM3 = 1000000;
	static constexpr int32_t MIN_LOOSE_CM3 = 10000;
	// BFS bound matching Colony._accepting_voxel's queue cap.
	static constexpr int MAX_ACCEPT_SEARCH = 4096;

	using Chunk = std::array<uint8_t, CHUNK_CELLS>;

	std::unordered_map<uint64_t, std::unique_ptr<Chunk>> chunks;
	std::unordered_map<uint64_t, int32_t> pile_fill;
	std::unordered_set<uint64_t> loaded_blocks;
	godot::Ref<DelveGenerator> gen;

	// Crash forensics: sparse events appended+flushed to
	// user://delve_native.log so the file survives a hard crash. Never
	// call from a per-tick inner loop.
	std::ofstream log_stream;
	int _unloads_since_log = 0;
	// Materialize budget for bounded searches: -1 = unlimited (normal
	// queries), find_path sets a finite cap so an unreachable target can't
	// generate terrain forever. chunk_at returns null when it hits 0 and
	// solid_at reads that as solid — the unknown can't be routed through,
	// matching the old loaded-cells-only grid's behaviour.
	int _mat_budget = -1;
	static constexpr int MAX_PATH_MATERIALIZE = 48;
	void dlog(const godot::String &msg);

	// Job board: ColonyJob instance id → claim state. Units are keyed by
	// their instance id as well.
	struct JobRecord {
		godot::Vector3i voxel;
		bool claimed = false;
		struct Drop {
			int64_t at = 0;
			int n = 0;
		};
		std::unordered_map<uint64_t, Drop> dropped_by;
	};
	std::unordered_map<int64_t, JobRecord> job_board;

	// In-flight pile falls, keyed by ItemPile instance id. The sim owns
	// landing timing so a site's item flow doesn't depend on presentation
	// nodes processing — the same curve ItemPile._process integrates.
	struct PileFall {
		float cur_y = 0.0f;
		float target_y = 0.0f;
		float speed = 0.0f;
	};
	std::unordered_map<int64_t, PileFall> pile_falls;
	static constexpr float PILE_FALL_GRAVITY = 30.0f;
	static constexpr float PILE_FALL_SPEED_MAX = 25.0f;

	// Kinematic unit bodies — the sim owns motion so a site ticks
	// identically without instantiated CharacterBody3D nodes. A unit is a
	// capsule of radius 0.35, half-height 0.9 (unit.tscn); horizontal
	// motion is blocked by is_blocked cells and by support surfaces more
	// than STEP_HEIGHT above the feet (a tall-enough pile blocks like a
	// wall, a shallow one is mounted). Other units separate softly.
	struct UnitBody {
		godot::Vector3 pos; // capsule centre — global_position equivalent
		float vel_y = 0.0f;
	};
	std::unordered_map<int64_t, UnitBody> unit_bodies;
	static constexpr float UNIT_HALF_HEIGHT = 0.9f;
	static constexpr float UNIT_STEP_HEIGHT = 0.55f;
	static constexpr float UNIT_SEPARATION = 0.7f; // ~2× capsule radius
	static constexpr float GROUND_EPS = 0.05f;

	float cell_surface(int x, int y, int z);
	float support_height(const godot::Vector3 &pos) const;
	bool horizontal_clear(const godot::Vector3 &pos) const;

	// A* scratch, reused across queries.
	struct PathNode {
		godot::Vector3i pos;
		float gscore = 0.0f;
		float fscore = 0.0f;
		uint32_t came_from = UINT32_MAX;
	};
	std::vector<PathNode> pool;
	std::unordered_map<uint64_t, uint32_t> point_map;
	// Lazy heap: (fscore, index) pairs; stale entries skipped on pop.
	std::vector<std::pair<float, uint32_t>> open_heap;

	static uint64_t key_of(int x, int y, int z);
	static int cell_index(int rx, int ry, int rz);
	void materialize(const godot::Vector3i &block_pos);
	Chunk *chunk_at(const godot::Vector3i &pos);

	bool solid_at(const godot::Vector3i &pos, bool packed_blocks);
	bool is_floor_for(const godot::Vector3i &pos, int64_t volume, bool splittable);
	bool fits_at(const godot::Vector3i &pos, bool packed_blocks);
	bool fits_between(const godot::Vector3i &a, const godot::Vector3i &b, bool packed_blocks);
	bool ground_close_enough(const godot::Vector3i &pos, bool packed_blocks);
	void neighbor_positions(const godot::Vector3i &pos, bool packed_blocks, godot::Vector3i *out, int &count);
	bool can_reach_from(
			const godot::Vector3 &from, const godot::Vector3i &target,
			bool solid_target, double reach);

protected:
	static void _bind_methods();

public:
	// Wires the mirror to the compiled terrain generator used for chunk
	// materialization. Returns false when the extension object is missing.
	bool configure(const godot::Ref<godot::RefCounted> &generator);

	// Streaming hooks — argument is the DATA BLOCK coordinate (voxel
	// origin / 16), matching VoxelTerrain.block_loaded/unloaded.
	void on_block_loaded(const godot::Vector3i &block_pos);
	void on_block_unloaded(const godot::Vector3i &block_pos);

	bool is_loaded(const godot::Vector3i &pos) const;
	// The terrain streams this voxel's data block — the native equivalent
	// of VoxelTool.is_area_editable. Spill and settle walks stop here.
	bool is_editable(const godot::Vector3i &pos) const;
	int64_t get_block(const godot::Vector3i &pos);
	void set_block(const godot::Vector3i &pos, int64_t block_id);
	bool is_solid(const godot::Vector3i &pos);
	bool is_standable(const godot::Vector3i &pos);
	// Pile fill in cm³ — 0 erases. Packed derives from fill >= BLOCK_CM3.
	void set_pile_fill(const godot::Vector3i &pos, int64_t cm3);
	int64_t pile_fill_at(const godot::Vector3i &pos) const;
	// Occupied space in cm³: BLOCK_CM3 for solid blocks, else pile fill.
	int64_t fill_of(const godot::Vector3i &pos);
	bool is_packed(const godot::Vector3i &pos) const;
	// Blocked = terrain-solid OR packed pile — the unit's occupancy rule.
	bool is_blocked(const godot::Vector3i &pos);
	// Unit standability: blocked floor, two free voxels — a unit can stand
	// on a packed pile, which is why this differs from is_standable.
	bool is_unit_standable(const godot::Vector3i &pos);

	// Standable voxels a unit could work [target] from — the native port
	// of Unit._work_spots: a ±2 scan box, unit-standable check, and the
	// reach rule (nearest face within reach, no blocked cell between, and
	// for solid targets the ray's first solid hit must be the target).
	// Returns the spots nearest-first relative to `from`.
	godot::PackedVector3Array work_spots(
			const godot::Vector3i &target, const godot::Vector3 &from,
			bool solid_target, bool exclude_self, double reach);

	// Same contract as VoxelAStarGrid3D.find_path: start through the cell
	// before the target (VoxelWorld appends the destination), empty when
	// unreachable. Packed piles count as solid when avoid_packed.
	// The search is confined to the endpoints' bounding box plus `margin`
	// — matching the GDScript AStarGrid3D region clamp and the colony
	// boundary rule: pathing never needs to roam past the boundary edge.
	godot::PackedVector3Array find_path(
			const godot::Vector3i &from, const godot::Vector3i &to,
			bool avoid_packed = false, int64_t margin = 24);

	// ---- Item/spill search — ports of Colony's GDScript helpers, run ----
	// ---- against the mirror so each call is one boundary crossing. ----

	// The voxel an item spills into: straight down when it isn't packed,
	// else the first unblocked side (position-hashed rotation in place of
	// GDScript's shuffle — same acceptance, arbitrary order).
	godot::Vector3i spill_target(const godot::Vector3i &pos);

	// The lowest voxel an item of `volume` cm³ would settle into from
	// `pos` — Colony._settle_floor: walk down while the cell below is
	// editable and not a floor for the item.
	godot::Vector3i settle_floor(
			const godot::Vector3i &pos, int64_t volume, bool splittable);

	// Colony._accepting_voxel: nearest voxel able to hold `item_volume`
	// cm³ without overfilling — adjoining voxels in preference order,
	// then a bounded BFS above the source. `needed` < 0 means "whole item,
	// capped at a voxel"; loose items accept partial fits. Returns
	// Vector3i(INT32_MAX, ...) when nothing fits.
	godot::Vector3i accepting_voxel(
			const godot::Vector3i &pos, int64_t item_volume, bool loose, int64_t needed);

	// ---- Job board ----------------------------------------------------

	// Register/unregister a job; ids are ColonyJob instance ids.
	void job_add(int64_t id, const godot::Vector3i &voxel);
	void job_remove(int64_t id);
	// Record a drop: the job goes back to unclaimed and `unit_id` gets a
	// retry record (at=now, n++). Mirrors Colony.release_job.
	void job_drop(int64_t id, int64_t unit_id, int64_t now_ms);
	// Nearest claimable job to `pos` for `unit_id` — fresh jobs beat
	// retry-eligible ones, matching Colony.claim_job. Claims it (marks
	// claimed) and returns its id, or -1.
	int64_t job_claim(
			int64_t unit_id, const godot::Vector3 &pos, int64_t now_ms,
			int64_t retry_base_ms, int64_t retry_max_ms);

	// ---- Site tick ----------------------------------------------------

	// Register/retarget a pile fall. `from_y`/`target_y` are world Y and
	// `speed` the current fall speed, matching ItemPile's fall state.
	void pile_fall_start(int64_t pile_id, double from_y, double target_y, double speed);
	// Remove a fall without landing it (pile freed mid-flight).
	void pile_fall_cancel(int64_t pile_id);
	// The per-site heartbeat — advances logical sim state that must not
	// depend on presentation. Today: pile falls. Returns the instance
	// ids of piles that landed this tick.
	godot::PackedInt64Array tick(double delta);

	// ---- Unit bodies --------------------------------------------------

	// Register/unregister a unit body at `pos` (capsule centre).
	void unit_register(int64_t id, const godot::Vector3 &pos);
	void unit_unregister(int64_t id);
	godot::Vector3 unit_pos(int64_t id) const;
	// Kinematic step replacing CharacterBody3D.move_and_slide for unit
	// motion: `heading` is the desired horizontal velocity (m/s),
	// `jump_speed` > 0 requests a hop when grounded, `gravity` applies
	// when unsupported. Slide along blocked cells is approximated by
	// axis-separated retries; other units push apart softly. Returns
	// {pos, vel_y, grounded, blocked, hit_unit} — hit_unit is the first
	// unit bumped roughly head-on, for the yield trigger.
	godot::Dictionary unit_step(
			int64_t id, const godot::Vector3 &heading,
			double jump_speed, double gravity, double delta);

	godot::Dictionary debug_stats() const;
};

} // namespace delve
