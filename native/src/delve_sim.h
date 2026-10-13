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
#include <map>
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
// agent fit), treats ladder cells as vertically climbable, and can
// optionally treat packed piles as solid.
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
	// Extra edge cost to step into a door cell — priced as the open-pause
	// (Unit.DOOR_OPEN_SECONDS ≈ 0.75 s) at walk speed (4 m/s) ≈ 3 cells.
	static constexpr float DOOR_COST = 3.0f;
	// The fence hop costs like a door for a unit — scramble over and go.
	// Animals never pay it: their paths refuse the cell entirely.
	static constexpr float FENCE_COST = 3.0f;
	// A trap cell prices the detour into a unit's path: they know where
	// the stakes are, so the A* steers around — but a cornered route
	// still costs it rather than reporting unreachable. Animals don't
	// get the discount; their routes pass ignore_traps and walk on.
	static constexpr float TRAP_COST = 25.0f;
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
	// A pile sharing its voxel with a ladder tops out at three quarters —
	// the ladder claims the rest of the space.
	static constexpr int32_t LADDER_PILE_CM3 = BLOCK_CM3 * 3 / 4;
	static constexpr int32_t MIN_LOOSE_CM3 = 10000;
	// Discrete-fill volume that chokes a voxel — a pile holding this much
	// clutter can't be waded: it blocks passage like a low wall, though
	// never a floor to stand on. Mirrors DropItem.CLUTTER_BLOCK_CM3.
	static constexpr int32_t CLUTTER_BLOCK_CM3 = 750000;
	// Clutter drag on movement — entering a cell costs 1 + K·f² times its
	// distance where f is the clutter fraction of capacity. Mirrors
	// DropItem.CLUTTER_K.
	static constexpr float CLUTTER_K = 4.0f;
	// BFS bound matching Colony._accepting_voxel's queue cap.
	static constexpr int MAX_ACCEPT_SEARCH = 4096;
	// A disconnected body bigger than this is treated as anchored rather
	// than condemned — missing a collapse is recoverable, a runaway flood
	// per removed block is not.
	static constexpr int MAX_COLLAPSE_FLOOD = 16384;

	using Chunk = std::array<uint8_t, CHUNK_CELLS>;

	std::unordered_map<uint64_t, std::unique_ptr<Chunk>> chunks;
	// Pile fill split by role: loose fill pours and compacts — it's the
	// only fraction that raises footing; clutter is discrete goods —
	// they slow passage (quadratic in fill) and choke the cell past
	// CLUTTER_BLOCK_CM3 without ever being a floor.
	std::unordered_map<uint64_t, int32_t> pile_loose;
	std::unordered_map<uint64_t, int32_t> pile_clutter;
	// Ladder cells, pushed by Colony through set_ladder like pile fill.
	// A ladder never blocks its cell: it supports a unit standing inside
	// it (base level) or on top of it (the cell above), so a stack is
	// climbed rung by rung. A pile may share the cell, at 25% less
	// capacity — the ladder takes up the space.
	std::unordered_set<uint64_t> ladders;
	// Door cells, pushed by Colony through set_door like ladders. A door
	// never blocks its cell — it stays air — but a path through it pays
	// the swing time, so the A* charges DOOR_COST to enter one.
	std::unordered_set<uint64_t> doors;
	// Fence cells, pushed by Colony through set_fence like doors. A
	// fence never blocks its cell — a unit's path pays the scramble
	// (FENCE_COST) — but the no_fences route flag refuses it entirely,
	// which is how livestock stay penned while colonists hop over.
	std::unordered_set<uint64_t> fences;
	// Spike-trap cells, pushed by Colony through set_trap like fences.
	// A trap never blocks either — a unit's path just pays TRAP_COST
	// to cross it (they know better), while the ignore_traps route —
	// the animals the trap was set for — sees open ground.
	std::unordered_set<uint64_t> traps;
	std::unordered_set<uint64_t> loaded_blocks;
	godot::Ref<DelveGenerator> gen;
	// Support anchor horizon — mirrored from the generator at configure.
	int bedrock_height = -64;
	// Last-seen DelveGenerator::state_epoch. The mirror caches generated
	// terrain, so if the generator's inputs move after chunks
	// materialized (a field install racing the first streamed blocks
	// during boot) the stale chunks must be dropped — sync_gen_epoch
	// checks this on the read paths.
	int64_t _gen_epoch = -1;
	void sync_gen_epoch();

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
		// ColonyJob.Type — indexes the unit's per-type skill score in
		// job_claim.
		int32_t job_type = 0;
		// Colony.game_msec() when posted — waiting jobs gain score so
		// stale work eventually beats closer picks (anti-starvation).
		int64_t posted_ms = 0;
		bool claimed = false;
		// A suspended job waits on a condition outside the board — today
		// an unsupported build site — and can't be claimed until Colony
		// lifts the flag.
		bool suspended = false;
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

	// Two support roles for a ladder cell: queried as the floor of the
	// cell above it offers its top (the unit stands on it), queried as
	// the feet's own cell it offers its base (the unit stands inside it).
	float cell_surface(int x, int y, int z, bool as_floor);
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
	static uint64_t col_key_of(int x, int z);
	static int cell_index(int rx, int ry, int rz);
	static godot::Vector3i pos_of_key(uint64_t key);
	void materialize(const godot::Vector3i &block_pos);
	Chunk *chunk_at(const godot::Vector3i &pos);

	// ---- Dynamic water state ------------------------------------------
	// Sparse per-cell volumes; a column's top lives in water_tops so
	// level queries don't scan. Sources/drains are per-cell rates
	// applied each water tick. Dirty columns feed WaterView's
	// incremental re-lay — a changed cell marks its column and the
	// four lateral neighbours (their skirts face it).
	// Volumes live in lazily-allocated 16³ chunks like the terrain mirror —
	// a lake is millions of wet cells and a flat map would spend ~50 B of
	// bookkeeping per cm³ field. water_tops maps column → top wet cell y
	// so level queries never scan. water_active bounds the flow pass to
	// cells that changed or neighbour a change; sources/drains are
	// per-cell cm³/tick rates applied each step. Dirty columns feed
	// WaterView's incremental re-lay — a changed surface marks its column
	// and the four lateral neighbours (their skirts face it).
	using WaterChunk = std::array<uint32_t, CHUNK_CELLS>;
	std::unordered_map<uint64_t, std::unique_ptr<WaterChunk>> water_chunks;
	// Deep copy of the seeded store — water_serialize diffs against it,
	// and a deserialize could in principle need cells the live map
	// dropped. Sized like the flood: heavy but allocated once.
	std::unordered_map<uint64_t, std::unique_ptr<WaterChunk>> water_seed_chunks;
	std::unordered_map<uint64_t, int32_t> water_tops;
	std::unordered_map<uint64_t, int32_t> water_sources;
	std::unordered_map<uint64_t, int32_t> water_drains;
	// Regulated edges — floodgates et al. throttle the head-driven flux
	// across an edge by a continuous factor in [0,1], absent entries
	// being fully open. Keyed canonically by the edge's two endpoint
	// cell keys (low, high): water may cross either way depending on
	// the heads, so the record doesn't care which side the setter
	// named first. Few records ever exist — an ordered map is plenty.
	std::map<std::pair<uint64_t, uint64_t>, float> water_edge_scales;
	// Powered pumps — a building moving water from its intake cell to
	// its outflow at rate cm³/step, conservative by construction: the
	// step moves only what the intake actually holds (and the outflow
	// has room for), never minting volume. Keyed by the intake cell.
	struct WaterPump {
		uint64_t out_key;
		int32_t rate_cm3;
	};
	std::unordered_map<uint64_t, WaterPump> water_pumps;
	// River columns (FLAG_RIVER at seed) — a flowing reach is fed by its
	// upstream catchment, which this pass doesn't model yet, so evap
	// would visibly drain the channel over a day. Lakes evaporate;
	// rivers don't.
	std::unordered_set<uint64_t> water_no_evap;
	std::unordered_set<uint64_t> water_active;
	std::unordered_set<uint64_t> water_dirty_cols;
	// Per-cell outflow accumulated during the last water step —
	// direction-weighted cm³, the "current" datum water_flow_field
	// exports for the render seam (the flow overlay) and, later, for
	// wheels and pumps reading the same edge flux. Cleared each step.
	std::unordered_map<uint64_t, godot::Vector3i> water_flux;
	bool water_seeded = false;
	// Simulation window — the site field's voxel extent. Water never
	// leaves it: past the edge there is no datum and chunk_at would
	// happily materialize terrain forever for a dribbling stream.
	int water_min_x = 0;
	int water_min_z = 0;
	int water_max_x = 0;
	int water_max_z = 0;
	bool water_in_bounds(int x, int z) const;
	double _water_accum = 0.0;
	// Evaporation amortizes across its cadence: the queue refills once
	// empty, so every surface cell still sweeps once per ~5 s without
	// a single-step walk over every wet column.
	std::vector<uint64_t> _water_evap_queue;
	// Precipitation amortizes the same way: column keys of the
	// streamed region, refilled when empty, a batch per step — the old
	// every-250-steps full sweep walked ~90k columns in one spike.
	std::vector<uint64_t> _water_rain_queue;
	int32_t water_rain_cm3 = 0;
	// Freeze for deterministic runs (the smoke suite): seeded water
	// still answers every query, but the step mutates nothing — a
	// settling lake can't wander into a fixture mid-check.
	bool water_paused = false;
	// Per-step scratch for body heads — comp id per wet cell, head per
	// Connected-body scratch for water_body_head, in lazily-allocated
	// 16³ chunks so a step never pays to clear a giant label map — a
	// chunk's labels are valid only while its epoch matches the step's.
	struct WaterCompChunk {
		int32_t epoch = -1;
		std::array<int32_t, CHUNK_CELLS> label;
	};
	std::unordered_map<uint64_t, std::unique_ptr<WaterCompChunk>>
			_water_comp_chunks;
	std::vector<double> _water_comp_head;
	int32_t _water_comp_epoch = 0;
	int64_t _water_comp_cells = 0;
	static constexpr double WATER_TICK_SEC = 0.2;
	// Per-tick wall-clock bound on water work. At high game speeds
	// _water_accum would otherwise stack many steps into one tick —
	// during a draining-lake storm each step is ~8192 cells (~10 ms),
	// so six steps read as a 60-100 ms tick. Steps past the budget
	// keep their debt dropped, not compounded: the water trails the
	// game clock rather than stalling it.
	static constexpr int64_t WATER_TICK_BUDGET_US = 10000;
	static constexpr int WATER_MAX_STEPS_PER_TICK = 4;
	static constexpr int32_t WATER_FULL = 1000000;
	// Seeded skin sits a hair under the cell top, matching the old
	// level-datum render (surface at level + 0.97).
	static constexpr int32_t WATER_SEED_TOP = 970000;
	// Evaporation per exposed surface cell per tick — small enough to
	// be invisible in-session, real over a season.
	static constexpr int32_t WATER_EVAP_CM3 = 100;
	// Fraction of the head difference moved across an edge per tick —
	// quarter-difference converges smoothly without overshooting the
	// equalization point into oscillation.
	static constexpr double WATER_FLOW_K = 0.25;
	// Exchange deadband: moves smaller than this never fire. Without a
	// floor, near-equal neighbours trade centilitres forever — the
	// frontier never drains and the surface twitches every tick.
	static constexpr int64_t WATER_FLOW_MIN = 10000;
	// A cell must hold at least this much to count as a column's water
	// top. Pressure-pushed skim cells (< 1%) arrive above a surface,
	// pour straight back down, and would otherwise flip the rendered
	// waterline a whole voxel every tick.
	static constexpr int32_t WATER_TOP_MIN = 25000;
	// Wading/swimming split for units: water deeper than this over the
	// support buoys the capsule — it floats at the draught line with
	// the head clear — instead of holding a wader up from the bed.
	static constexpr float SWIM_DEPTH = 1.0f;
	// Feet ride this far below the waterline — shallow enough that a
	// jump impulse still clears a bank at surface level (apex ~1.28 m
	// at jump_speed 7.5), deep enough the body reads as in the water.
	static constexpr float SWIM_DRAUGHT = 0.9f;
	static constexpr float SWIM_RISE_K = 8.0f;
	// A* surcharges for water — swimming prices like the fatigue it
	// costs so a dry detour twice as long still wins; wading scales
	// with the fill toward a chest-deep crawl.
	static constexpr float SWIM_EDGE_COST = 4.0f;
	static constexpr float WADE_EDGE_COST = 3.0f;
	// …but once a cell IS the top it stays so until it drains below
	// this floor — the band between the two is hysteresis that keeps a
	// thin flowing sheet from blinking on and off the render.
	static constexpr int32_t WATER_TOP_DROP = 2500;
	// A surface cell's fill change only flags its column dirty when it
	// crosses a band this wide — finer churn moves the sheet by
	// centimetres, invisible in a voxel-scale skin, and dirty flags
	// are what queue tile rebuilds.
	static constexpr int64_t WATER_SKIN_BUCKET = 50000;
	// A far-from-equilibrium seed (a fresh lake finding voxel-scale rim
	// leaks the raster couldn't see) can hold a frontier of hundreds of
	// thousands of cells hot for many steps. Each step emits from at
	// most this many cells — the wavefront creeps visibly instead of
	// stalling the tick — and once the backlog itself is saturated,
	// neighbour wakes are dropped (a changed cell always re-queues
	// itself, so the frontier still advances; wakes are a latency
	// optimisation, not a correctness requirement).
	static constexpr size_t WATER_STEP_BUDGET = 8192;
	static constexpr size_t WATER_WAKE_CAP = 32768;
	// Bound on one connected-body head scan — see water_body_head.
	static constexpr int WATER_COMP_CAP = 65536;
	// water_body_head returns this when the connected body is bigger
	// than one scan can label — the caller then falls back to the
	// column's own waterline. Without it, different cells of the same
	// giant body would cache heads computed over different subsets and
	// pressure could trade water back and forth forever.
	static constexpr double WATER_HEAD_UNKNOWN = -1e20;
	// Bound on total body-scan labels per step; past it a saturated
	// cell degrades to its own column's surface as its head — exact
	// for open water, merely under-pressurized for conduits mid-storm.
	static constexpr int64_t WATER_COMP_STEP_CAP = 262144;
	static constexpr int64_t WATER_DRY = -30000;

	void water_step();
	void water_mark_dirty(int x, int z);
	int32_t water_cell(int x, int y, int z) const;
	// Read/write through the lazily-allocated water chunks.
	uint32_t water_at(const godot::Vector3i &pos) const;
	void water_put(const godot::Vector3i &pos, uint32_t vol);
	// Solidity without side effects: reads the mirror chunk when it's
	// materialized, else answers the single cell from the generator —
	// water flow must never materialize terrain just to probe it.
	bool water_solid_at(const godot::Vector3i &pos);
	// Flood-label the connected water body containing `start` and return
	// its free-surface head (max cell y + fill fraction over members).
	// Bodies connect through lateral edges between wet cells and through
	// vertical edges where the lower cell is saturated — a saturated
	// column conducts its surface's pressure to its base, so U-bends and
	// culverts fill bottom-up. A falling column of partial cells doesn't
	// conduct: a waterfall doesn't pressurize the pool it lands in.
	double water_body_head(uint64_t start_key);
	// Recompute a column's top wet cell after changes — walks down
	// from the recorded top to the next wet cell (or erases). When a
	// delta map is given, footing cells are read with pending deltas
	// applied — a cell that's exporting water this step can't support
	// a surface above it.
	void water_refresh_top(uint64_t col_key, int x, int z,
			const std::unordered_map<uint64_t, int64_t> *delta = nullptr);
	// Raise a column's recorded top to pos.y when the cell now reads as
	// a real surface — skim-thin cells and water without footing (no
	// saturated cell or solid ground directly below) never flip the
	// waterline.
	void water_raise_top(const godot::Vector3i &pos,
			const std::unordered_map<uint64_t, int64_t> *delta = nullptr);
	// Footing for a surface cell: the cell below is (or, counting
	// pending deltas, will be) saturated, or is solid ground.
	bool water_supported(int x, int y, int z,
			const std::unordered_map<uint64_t, int64_t> *delta);
	// Full rescan for deserialize — the restored top can sit above
	// anything the seed recorded, so refresh_top's local walk can't
	// find it. Bounded by the field's vertical range.
	void water_rescan_top(int x, int z);
	// The flux multiplier on the edge spanning cells a and b, default
	// 1.0 — used by the head-driven transfer in water_step.
	float water_edge_scale(uint64_t a, uint64_t b) const;

	bool solid_at(const godot::Vector3i &pos, bool packed_blocks);
	bool flooring_at(const godot::Vector3i &pos);
	bool is_floor_for(const godot::Vector3i &pos, int64_t volume, bool splittable);
	bool fits_at(const godot::Vector3i &pos, bool packed_blocks);
	bool fits_between(const godot::Vector3i &a, const godot::Vector3i &b, bool packed_blocks);
	bool ground_close_enough(const godot::Vector3i &pos, bool packed_blocks);
	void neighbor_positions(const godot::Vector3i &pos, bool packed_blocks, godot::Vector3i *out, int &count, bool allow_swim = false);
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
	// The block id the way water sees it — materialized chunks from
	// data, everything else from the generator (outcrops and caves
	// included), so far-field queries never read a false "unloaded" air.
	int64_t probe_block(const godot::Vector3i &pos);
	// Container census for memory forensics (soak probes).
	godot::Dictionary debug_sizes() const;
	bool is_solid(const godot::Vector3i &pos);
	bool is_standable(const godot::Vector3i &pos);
	// Ladder cells, mirrored by Colony on build/deconstruct.
	void set_ladder(const godot::Vector3i &pos, bool on);
	bool ladder_at(const godot::Vector3i &pos) const;
	// Door cells — walkable, but entering one costs the open-pause.
	void set_door(const godot::Vector3i &pos, bool on);
	bool door_at(const godot::Vector3i &pos) const;
	// Fence cells — unit paths pay the hop; animal paths refuse them.
	void set_fence(const godot::Vector3i &pos, bool on);
	void set_trap(const godot::Vector3i &pos, bool on);
	bool fence_at(const godot::Vector3i &pos) const;
	bool trap_at(const godot::Vector3i &pos) const;
	// Item capacity of a voxel — a ladder claims a quarter of its cell.
	int64_t capacity_at(const godot::Vector3i &pos) const;
	// Pile fill in cm³, split by role — loose raises footing, clutter
	// slows and chokes. Both 0 erases the cell. Packed derives from the
	// total >= capacity.
	void set_pile_fill(const godot::Vector3i &pos, int64_t loose_cm3, int64_t clutter_cm3);
	int64_t pile_loose_at(const godot::Vector3i &pos) const;
	int64_t pile_clutter_at(const godot::Vector3i &pos) const;
	// Total fill — loose + clutter.
	int64_t pile_fill_at(const godot::Vector3i &pos) const;
	// Clutter past the choke threshold — walked around, not through.
	bool is_dense(const godot::Vector3i &pos) const;
	// Occupied space in cm³: BLOCK_CM3 for solid blocks, else pile fill.
	int64_t fill_of(const godot::Vector3i &pos);
	bool is_packed(const godot::Vector3i &pos) const;
	// Blocked = terrain-solid OR packed pile — the unit's occupancy rule.
	bool is_blocked(const godot::Vector3i &pos);
	// Unit standability: blocked floor, two free voxels — a unit can stand
	// on a packed pile, which is why this differs from is_standable.
	bool is_unit_standable(const godot::Vector3i &pos);

	// Structural support: a solid cell is anchored iff it chains through
	// face-adjacent solids to the base level (y <= bedrock_height) or to a
	// tree block — a living tree holds itself. Called after `removed`
	// became air; each solid neighbour's component is re-proven by a
	// best-first flood that dives for the lowest cell first, so ordinary
	// terrain reaches bedrock in ~depth pops. Anchors: bedrock, a tree
	// block, the unloaded frontier (can't disprove a path through it), or
	// the flood cap. A component that exhausts without anchoring is
	// returned in full — the collapse cascade is the set, not a drip.
	godot::PackedVector3Array collapse_check(const godot::Vector3i &removed);

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
	// `swim` admits submerged cells as neighbours — gated on open
	// headroom above the waterline and priced so a dry detour still
	// wins — for units cleared to cross deep water (skill, hands).
	// `no_fences` refuses fence cells outright — the animal route, so
	// penned livestock can't path over the rail a colonist hops.
	// `ignore_traps` skips the TRAP_COST edge penalty — the same animal
	// route, since livestock don't know where the stakes are.
	godot::PackedVector3Array find_path(
			const godot::Vector3i &from, const godot::Vector3i &to,
			bool avoid_packed = false, int64_t margin = 24,
			bool swim = false, bool no_fences = false,
			bool ignore_traps = false);

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

	// Register/unregister a job; ids are ColonyJob instance ids. `job_type`
	// is ColonyJob.Type and `posted_ms` the posting time — both feed the
	// claim score.
	void job_add(
			int64_t id, const godot::Vector3i &voxel,
			int64_t job_type, int64_t posted_ms);
	void job_remove(int64_t id);
	// Mirror Colony's suspension flag: a suspended job stays on the board
	// but can't be claimed until unsuspended.
	void job_suspend(int64_t id, bool on);
	// Overwrite a job's posting time — restores a loaded job's age, and
	// tests backdate jobs to exercise the languish term.
	void job_set_posted(int64_t id, int64_t posted_ms);
	// Record a drop: the job goes back to unclaimed and `unit_id` gets a
	// retry record (at=now, n++). Mirrors Colony.release_job.
	void job_drop(int64_t id, int64_t unit_id, int64_t now_ms);
	// Best-scoring claimable job for `unit_id` — fresh jobs beat
	// retry-eligible ones, matching Colony.claim_job. Claims it (marks
	// claimed) and returns its id, or -1.
	// Score = distance*dist_weight − type_scores[job_type] − languish:
	// `type_scores` (indexed by ColonyJob.Type) is the unit's skill bonus
	// per type in metres-equivalent; `languish` rewards jobs by waiting
	// time at languish_rate m/s, capped at languish_cap_s seconds.
	int64_t job_claim(
			int64_t unit_id, const godot::Vector3 &pos, int64_t now_ms,
			int64_t retry_base_ms, int64_t retry_max_ms,
			const godot::PackedFloat64Array &type_scores,
			double dist_weight, double languish_rate, double languish_cap_s);

	// ---- Site tick ----------------------------------------------------

	// Register/retarget a pile fall. `from_y`/`target_y` are world Y and
	// `speed` the current fall speed, matching ItemPile's fall state.
	void pile_fall_start(int64_t pile_id, double from_y, double target_y, double speed);
	// Remove a fall without landing it (pile freed mid-flight).
	void pile_fall_cancel(int64_t pile_id);
	// The per-site heartbeat — advances logical sim state that must not
	// depend on presentation. Pile falls integrate every call; water
	// steps at WATER_TICK_SEC cadence. Returns the instance ids of piles
	// that landed this tick.
	godot::PackedInt64Array tick(double delta);

	// ---- Dynamic water ------------------------------------------------
	// Per-cell water in cm³ (WATER_FULL = 1 m³ fills a voxel) — the
	// site's live waterline, seeded from the SiteField flood raster and
	// then evolved: gravity pours down at full rate, lateral/upward
	// exchange moves a fraction of the head difference, where a cell's
	// head is the free surface of its connected water body (so U-tubes
	// and aqueducts fill bottom-up, per communicating vessels). The
	// generator's water_level_at stays the *seeded* datum; the queries
	// below are the live truth once water_seed_flood has run.
	void water_seed_flood(
			const godot::PackedInt32Array &flood, const godot::Vector2i &origin,
			int64_t vs,
			const godot::PackedByteArray &cell_flags = godot::PackedByteArray(),
			int64_t cell_m = 4);
	// Top wet cell's y in the column, or FIELD_DRY (-30000).
	int64_t water_level_at(int64_t x, int64_t z);
	// Fractional surface — top cell y + fill fraction — for rendering.
	double water_surface_at(int64_t x, int64_t z);
	// Old contract: level - terrain_height. 0 when dry.
	int64_t water_depth_at(int64_t x, int64_t z);
	int64_t water_volume_at(const godot::Vector3i &pos) const;
	// Direct volume add — tests, rain, pumps. Clamps to the cell's room.
	void water_add(const godot::Vector3i &pos, int64_t cm3);
	// Boundary conditions: a source tops its cell up at rate cm³/tick,
	// a drain removes at rate. Registered at seed from the field's
	// river edge cells.
	void water_set_source(const godot::Vector3i &pos, int64_t rate_cm3);
	void water_set_drain(const godot::Vector3i &pos, int64_t rate_cm3);
	// Continuous throttle on the edge between pos and pos+dir — a
	// floodgate's open fraction. factor ≥ 1 clears the record back to
	// full flow; the scale multiplies the head-driven transfer (the
	// lateral and rise moves), which keeps a partially open gate
	// smooth instead of oscillating on/off. The edge is undirected:
	// naming it from either endpoint hits the same record.
	void water_set_edge_scale(const godot::Vector3i &pos,
			const godot::Vector3i &dir, double factor);
	// The throttle on the edge between pos and pos+dir, 1.0 when no
	// record exists — the query side for diagnostics and tests.
	double water_edge_scale_at(
			const godot::Vector3i &pos, const godot::Vector3i &dir) const;
	// A powered pump's plumbing: rate ≤ 0 removes the record. The step
	// moves min(rate, held, room) from intake to outflow — the building
	// drives the rate from its power state, the sim keeps it honest.
	void water_set_pump(const godot::Vector3i &intake,
			const godot::Vector3i &outflow, int64_t rate_cm3);
	// This step's accumulated outflow vector at pos — what a water
	// wheel reads. Zero for cells the last step didn't touch.
	godot::Vector3i water_flux_at(const godot::Vector3i &pos) const;
	// Precipitation: cm³ added per column per evaporation sweep (25
	// steps, ~5 s) while rain falls. Rain wets every loaded column at
	// its surface cell — the sim only simulates the streamed region.
	void water_set_rain(int64_t cm3_per_sweep);
	// Deterministic-mode switch for the harness — queries keep reading
	// the seeded store while the step does nothing.
	void water_set_paused(bool paused);
	// Columns whose waterline changed since the last drain — WaterView
	// re-lays just these (plus their neighbours) each refresh.
	godot::PackedVector3Array water_drain_dirty();
	// Surface flux for the flow overlay: interleaved [position, flux]
	// pairs — position is the voxel, flux the last step's accumulated
	// outflow vector in cm³. Only column-top cells export; submerged
	// flux is invisible under the skin and doubles the payload.
	godot::PackedVector3Array water_flow_field();
	// Site-payload persistence: a delta against the seeded flood, since
	// the field regenerates deterministically on load and re-seeding is
	// free. Per chunk only the cells that differ travel — a settled
	// body serializes to almost nothing.
	godot::Dictionary water_serialize();
	void water_deserialize(const godot::Dictionary &data);

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
	// unit bumped roughly head-on, for the yield trigger. `descend_speed`
	// > 0 requests a ladder descent: while the feet cell or the cell
	// below it holds a ladder the unit sinks at that rate instead of
	// falling — the script's waypoint logic paces it rung by rung.
	godot::Dictionary unit_step(
			int64_t id, const godot::Vector3 &heading,
			double jump_speed, double gravity, double delta,
			double descend_speed = 0.0);

	godot::Dictionary debug_stats() const;
};

} // namespace delve
