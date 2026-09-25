#pragma once

#include "delve_generator.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <array>
#include <cstdint>
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
// Packed-pile flags live in a voxel-keyed set so they survive chunk
// materialization; Colony pushes them through set_packed.
//
// The native A* replicates VoxelAStarGrid3D's movement rules (8
// horizontal directions, +1 jump when hemmed in, falls up to 3, 1×2×1
// agent fit) and can optionally treat packed piles as solid.
class DelveSim : public godot::RefCounted {
	GDCLASS(DelveSim, godot::RefCounted)

	static constexpr int CHUNK = 16;
	static constexpr int CHUNK_CELLS = CHUNK * CHUNK * CHUNK;
	static constexpr int MAX_FALL_HEIGHT = 3;
	static constexpr float MAX_PATH_COST = 1000.0f;
	// VoxelAStarGrid3D defaults: 0.8×1.8×0.8 — fits a 1×2×1 voxel box.
	static constexpr float AGENT_XZ = 0.4f; // half-extent
	static constexpr float AGENT_Y = 0.9f;

	using Chunk = std::array<uint8_t, CHUNK_CELLS>;

	std::unordered_map<uint64_t, std::unique_ptr<Chunk>> chunks;
	std::unordered_set<uint64_t> packed_cells;
	godot::Ref<DelveGenerator> gen;

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
	int64_t get_block(const godot::Vector3i &pos);
	void set_block(const godot::Vector3i &pos, int64_t block_id);
	bool is_solid(const godot::Vector3i &pos);
	bool is_standable(const godot::Vector3i &pos);
	void set_packed(const godot::Vector3i &pos, bool packed);
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
	godot::PackedVector3Array find_path(
			const godot::Vector3i &from, const godot::Vector3i &to, bool avoid_packed = false);

	godot::Dictionary debug_stats() const;
};

} // namespace delve
