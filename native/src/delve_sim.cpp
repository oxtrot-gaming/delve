#include "delve_sim.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace delve {

// Horizontal neighbor offsets — same order as VoxelAStarGrid3D's
// g_directions_2d so tie-breaking lands on the same cells.
static const Vector3i DIRECTIONS_2D[8] = {
	Vector3i(-1, 0, -1), Vector3i(0, 0, -1), Vector3i(1, 0, -1),
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(-1, 0, 1), Vector3i(0, 0, 1), Vector3i(1, 0, 1),
};

uint64_t DelveSim::key_of(int x, int y, int z) {
	const uint64_t ux = (uint64_t)(x & 0x1fffff);
	const uint64_t uy = (uint64_t)(y & 0x1fffff);
	const uint64_t uz = (uint64_t)(z & 0x1fffff);
	return (ux << 42) | (uy << 21) | uz;
}

int DelveSim::cell_index(int rx, int ry, int rz) {
	return rx | (rz << 4) | (ry << 8);
}

bool DelveSim::configure(const Ref<RefCounted> &generator) {
	gen = Ref<DelveGenerator>(Object::cast_to<DelveGenerator>(generator.ptr()));
	return gen.is_valid();
}

// Generates the chunk covering the block coordinate — the mirror is a
// pure function of the deterministic generator plus recorded edits, so
// this runs on first touch rather than eagerly per streamed block.
void DelveSim::materialize(const Vector3i &block_pos) {
	if (gen.is_null()) {
		return;
	}
	const uint64_t key = key_of(block_pos.x, block_pos.y, block_pos.z);
	if (chunks.find(key) != chunks.end()) {
		return;
	}
	auto chunk = std::make_unique<Chunk>();
	const Vector3i base = block_pos * CHUNK;
	for (int rx = 0; rx < CHUNK; ++rx) {
		const int x = base.x + rx;
		for (int rz = 0; rz < CHUNK; ++rz) {
			const int z = base.z + rz;
			const int grass = gen->terrain_height(x, z);
			const int rt = gen->rock_top(x, z, grass);
			for (int ry = 0; ry < CHUNK; ++ry) {
				(*chunk)[cell_index(rx, ry, rz)] =
						(uint8_t)gen->block_at(x, base.y + ry, z, grass, rt);
			}
		}
	}
	chunks.emplace(key, std::move(chunk));
}

DelveSim::Chunk *DelveSim::chunk_at(const Vector3i &pos) {
	materialize(Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4));
	auto it = chunks.find(key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4));
	return it == chunks.end() ? nullptr : it->second.get();
}

void DelveSim::on_block_loaded(const Vector3i &block_pos) {
	// Contents still materialize lazily — this only marks the block as
	// editable for spill/settle bounds checks.
	loaded_blocks.insert(key_of(block_pos.x, block_pos.y, block_pos.z));
}

void DelveSim::on_block_unloaded(const Vector3i &block_pos) {
	// The terrain forgets edits on unload; the mirror must too.
	const uint64_t key = key_of(block_pos.x, block_pos.y, block_pos.z);
	loaded_blocks.erase(key);
	chunks.erase(key);
}

bool DelveSim::is_loaded(const Vector3i &pos) const {
	return chunks.find(key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4)) != chunks.end();
}

bool DelveSim::is_editable(const Vector3i &pos) const {
	return loaded_blocks.find(key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4)) != loaded_blocks.end();
}

int64_t DelveSim::get_block(const Vector3i &pos) {
	const Chunk *chunk = chunk_at(pos);
	if (chunk == nullptr) {
		return BLOCK_AIR;
	}
	return (*chunk)[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)];
}

void DelveSim::set_block(const Vector3i &pos, int64_t block_id) {
	Chunk *chunk = chunk_at(pos);
	(*chunk)[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)] = (uint8_t)block_id;
}

bool DelveSim::is_solid(const Vector3i &pos) {
	return get_block(pos) != BLOCK_AIR;
}

bool DelveSim::is_standable(const Vector3i &pos) {
	return is_solid(pos + Vector3i(0, -1, 0)) && !is_solid(pos) && !is_solid(pos + Vector3i(0, 1, 0));
}

void DelveSim::set_pile_fill(const Vector3i &pos, int64_t cm3) {
	const uint64_t key = key_of(pos.x, pos.y, pos.z);
	if (cm3 <= 0) {
		pile_fill.erase(key);
	} else {
		pile_fill[key] = (int32_t)cm3;
	}
}

int64_t DelveSim::pile_fill_at(const Vector3i &pos) const {
	const auto it = pile_fill.find(key_of(pos.x, pos.y, pos.z));
	return it == pile_fill.end() ? 0 : it->second;
}

int64_t DelveSim::fill_of(const Vector3i &pos) {
	return is_solid(pos) ? BLOCK_CM3 : pile_fill_at(pos);
}

bool DelveSim::is_packed(const Vector3i &pos) const {
	return pile_fill_at(pos) >= BLOCK_CM3;
}

bool DelveSim::is_blocked(const Vector3i &pos) {
	return solid_at(pos, true);
}

bool DelveSim::is_unit_standable(const Vector3i &pos) {
	return is_blocked(pos + Vector3i(0, -1, 0)) && !is_blocked(pos) && !is_blocked(pos + Vector3i(0, 1, 0));
}

// The reach rule from Unit._can_reach_from: within `reach` of the target's
// nearest face, no blocked cell along the approach march, and for a solid
// target the first terrain-solid voxel the ray meets must be the target.
bool DelveSim::can_reach_from(
		const Vector3 &from, const Vector3i &target, bool solid_target, double reach) {
	const Vector3 nearest(
			std::min(std::max(from.x, (real_t)target.x), (real_t)target.x + 1.0f),
			std::min(std::max(from.y, (real_t)target.y), (real_t)target.y + 1.0f),
			std::min(std::max(from.z, (real_t)target.z), (real_t)target.z + 1.0f));
	const Vector3 to_face = nearest - from;
	const double distance = to_face.length();
	if (distance > reach) {
		return false;
	}
	if (distance < 0.01) {
		return true;
	}
	const Vector3 direction = to_face / distance;
	const Vector3i from_cell((int)std::floor(from.x), (int)std::floor(from.y), (int)std::floor(from.z));

	if (solid_target) {
		// The voxel raycast: the first terrain-solid cell on the ray
		// (which pokes 0.5 past the face) must be the target itself.
		bool hit = false;
		for (double t = 0.0; t < distance + 0.5; t += 0.25) {
			const Vector3 p = from + direction * t;
			const Vector3i cell((int)std::floor(p.x), (int)std::floor(p.y), (int)std::floor(p.z));
			if (cell == from_cell) {
				continue;
			}
			if (solid_at(cell, false)) {
				if (cell != target) {
					return false;
				}
				hit = true;
				break;
			}
		}
		if (!hit) {
			return false;
		}
	}
	// Packed-pile occlusion march: no blocked cell between unit and face.
	for (double t = 0.0; t < distance - 0.2; t += 0.25) {
		const Vector3 p = from + direction * t;
		const Vector3i cell((int)std::floor(p.x), (int)std::floor(p.y), (int)std::floor(p.z));
		if (cell != from_cell && solid_at(cell, true)) {
			return false;
		}
	}
	return true;
}

PackedVector3Array DelveSim::work_spots(
		const Vector3i &target, const Vector3 &from,
		bool solid_target, bool exclude_self, double reach) {
	PackedVector3Array spots;
	for (int dx = -2; dx <= 2; ++dx) {
		for (int dy = -2; dy <= 1; ++dy) {
			for (int dz = -2; dz <= 2; ++dz) {
				const Vector3i spot = target + Vector3i(dx, dy, dz);
				if (exclude_self && (spot == target || spot == target + Vector3i(0, -1, 0))) {
					continue;
				}
				if (!is_unit_standable(spot)) {
					continue;
				}
				const Vector3 eye = Vector3(spot) + Vector3(0.5, 0.9, 0.5);
				if (can_reach_from(eye, target, solid_target, reach)) {
					spots.append(Vector3(spot));
				}
			}
		}
	}
	// Nearest-first, matching Unit._work_spots' sort.
	Vector3 *data = spots.ptrw();
	std::sort(data, data + spots.size(), [from](const Vector3 &a, const Vector3 &b) {
		return a.distance_squared_to(from) < b.distance_squared_to(from);
	});
	return spots;
}

// ---- A* (VoxelAStarGrid3D-compatible movement) ---------------------------

bool DelveSim::solid_at(const Vector3i &pos, bool packed_blocks) {
	const Chunk *chunk = chunk_at(pos);
	if (chunk != nullptr && (*chunk)[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)] != BLOCK_AIR) {
		return true;
	}
	return packed_blocks && pile_fill_at(pos) >= BLOCK_CM3;
}

// The agent is a 0.8×1.8×0.8 box centred with the VoxelAStarGrid3D fitting
// offset (0, 0.5, 0): its footprint is the voxel column, spanning the cell
// and the one above.
bool DelveSim::fits_at(const Vector3i &pos, bool packed_blocks) {
	const int min_x = (int)std::floor(pos.x + 0.5f - AGENT_XZ);
	const int min_y = (int)std::floor(pos.y + 1.0f - AGENT_Y);
	const int min_z = (int)std::floor(pos.z + 0.5f - AGENT_XZ);
	const int max_x = (int)std::ceil(pos.x + 0.5f + AGENT_XZ);
	const int max_y = (int)std::ceil(pos.y + 1.0f + AGENT_Y);
	const int max_z = (int)std::ceil(pos.z + 0.5f + AGENT_XZ);
	for (int x = min_x; x < max_x; ++x) {
		for (int y = min_y; y < max_y; ++y) {
			for (int z = min_z; z < max_z; ++z) {
				if (solid_at(Vector3i(x, y, z), packed_blocks)) {
					return false;
				}
			}
		}
	}
	return true;
}

// Midpoint fit — for diagonal moves the box straddles the corner columns,
// which is what keeps agents from cutting through diagonal gaps.
bool DelveSim::fits_between(const Vector3i &a, const Vector3i &b, bool packed_blocks) {
	const Vector3 mid = Vector3(a + b + Vector3i(1, 1, 1)) * 0.5f;
	const int min_x = (int)std::floor(mid.x - AGENT_XZ);
	const int min_y = (int)std::floor(mid.y + 0.5f - AGENT_Y);
	const int min_z = (int)std::floor(mid.z - AGENT_XZ);
	const int max_x = (int)std::ceil(mid.x + AGENT_XZ);
	const int max_y = (int)std::ceil(mid.y + 0.5f + AGENT_Y);
	const int max_z = (int)std::ceil(mid.z + AGENT_XZ);
	for (int x = min_x; x < max_x; ++x) {
		for (int y = min_y; y < max_y; ++y) {
			for (int z = min_z; z < max_z; ++z) {
				if (solid_at(Vector3i(x, y, z), packed_blocks)) {
					return false;
				}
			}
		}
	}
	return true;
}

bool DelveSim::ground_close_enough(const Vector3i &pos, bool packed_blocks) {
	for (int i = 1; i <= MAX_FALL_HEIGHT; ++i) {
		if (solid_at(pos - Vector3i(0, i, 0), packed_blocks)) {
			return true;
		}
	}
	return false;
}

void DelveSim::neighbor_positions(
		const Vector3i &pos, bool packed_blocks, Vector3i *out, int &count) {
	count = 0;
	const bool c_below = solid_at(pos + Vector3i(0, -1, 0), packed_blocks);
	bool may_jump = false;

	Vector3i candidates[11];
	int n = 0;
	for (const Vector3i &dir : DIRECTIONS_2D) {
		const Vector3i npos = pos + dir;
		if (solid_at(npos, packed_blocks)) {
			may_jump = true;
			continue;
		}
		if (!c_below) {
			// Coming from a floating cell: the neighbor needs a floor.
			if (!solid_at(npos + Vector3i(0, -1, 0), packed_blocks)) {
				continue;
			}
		}
		if (!ground_close_enough(npos, packed_blocks)) {
			continue;
		}
		candidates[n++] = npos;
	}
	if (may_jump && c_below) {
		candidates[n++] = pos + Vector3i(0, 1, 0);
	}
	if (!c_below) {
		candidates[n++] = pos + Vector3i(0, -1, 0);
	}
	for (int i = 0; i < n; ++i) {
		const Vector3i npos = candidates[i];
		if (!fits_at(npos, packed_blocks)) {
			continue;
		}
		if (!fits_between(pos, npos, packed_blocks)) {
			continue;
		}
		out[count++] = npos;
	}
}

PackedVector3Array DelveSim::find_path(
		const Vector3i &from, const Vector3i &to, bool avoid_packed) {
	PackedVector3Array result;
	pool.clear();
	point_map.clear();
	open_heap.clear();

	PathNode start;
	start.pos = from;
	start.gscore = 0.0f;
	const Vector3i hd = to - from;
	start.fscore = (float)(std::abs(hd.x) + std::abs(hd.y) + std::abs(hd.z));
	pool.push_back(start);
	point_map.emplace(key_of(from.x, from.y, from.z), 0);

	auto heap_cmp = [](const std::pair<float, uint32_t> &a, const std::pair<float, uint32_t> &b) {
		return a.first > b.first; // min-heap on fscore
	};
	open_heap.push_back({ start.fscore, 0 });

	Vector3i neighbors[11];
	uint32_t end_index = UINT32_MAX;

	while (!open_heap.empty()) {
		const auto top = open_heap.front();
		std::pop_heap(open_heap.begin(), open_heap.end(), heap_cmp);
		open_heap.pop_back();
		const uint32_t ci = top.second;
		const PathNode &current = pool[ci];
		if (current.fscore < top.first - 0.001f) {
			continue; // stale heap entry superseded by a better score
		}
		if (current.pos == to) {
			end_index = ci;
			break;
		}
		int ncount = 0;
		neighbor_positions(current.pos, avoid_packed, neighbors, ncount);
		for (int i = 0; i < ncount; ++i) {
			const Vector3i npos = neighbors[i];
			const uint64_t nkey = key_of(npos.x, npos.y, npos.z);
			auto it = point_map.find(nkey);
			uint32_t ni;
			if (it != point_map.end()) {
				ni = it->second;
			} else {
				ni = (uint32_t)pool.size();
				PathNode node;
				node.pos = npos;
				node.gscore = std::numeric_limits<float>::max();
				pool.push_back(node);
				point_map.emplace(nkey, ni);
			}
			const Vector3i dir = npos - current.pos;
			const float edge = std::sqrt((float)(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z));
			const float g = current.gscore + edge;
			PathNode &node = pool[ni];
			if (g + 0.0001f < node.gscore && g < MAX_PATH_COST) {
				node.came_from = ci;
				node.gscore = g;
				const Vector3i h = to - npos;
				node.fscore = g + (float)(std::abs(h.x) + std::abs(h.y) + std::abs(h.z));
				open_heap.push_back({ node.fscore, ni });
				std::push_heap(open_heap.begin(), open_heap.end(), heap_cmp);
			}
		}
	}

	if (end_index == UINT32_MAX) {
		return result;
	}
	// Walk back like AStarGrid3D::reconstruct_path — yields the cells from
	// start through the node BEFORE the target; the caller appends it.
	std::vector<Vector3i> rev;
	uint32_t idx = end_index;
	int guard = 0;
	while (pool[idx].came_from != UINT32_MAX && guard++ < 10000) {
		idx = pool[idx].came_from;
		rev.push_back(pool[idx].pos);
	}
	result.resize((int)rev.size());
	for (size_t i = 0; i < rev.size(); ++i) {
		const Vector3i &p = rev[rev.size() - 1 - i];
		result[i] = Vector3((float)p.x, (float)p.y, (float)p.z);
	}
	return result;
}

Dictionary DelveSim::debug_stats() const {
	Dictionary stats;
	size_t cells = chunks.size() * (size_t)CHUNK_CELLS;
	stats["chunks"] = (int64_t)chunks.size();
	stats["cells"] = (int64_t)cells;
	stats["bytes"] = (int64_t)(chunks.size() * sizeof(Chunk));
	stats["piles"] = (int64_t)pile_fill.size();
	return stats;
}

// ---- Item/spill search -------------------------------------------------

static const Vector3i SPILL_SIDES[4] = {
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
};

// Colony._is_floor_for: packed is always a floor; empty or a pile a
// splittable item can pour into is not; an unsplittable item rests on a
// pile it would overfill.
bool DelveSim::is_floor_for(const Vector3i &pos, int64_t volume, bool splittable) {
	if (is_blocked(pos)) {
		return true;
	}
	const int64_t fill = pile_fill_at(pos);
	if (fill <= 0) {
		return false;
	}
	if (splittable) {
		return false;
	}
	return fill + volume > BLOCK_CM3;
}

Vector3i DelveSim::spill_target(const Vector3i &pos) {
	const Vector3i below = pos + Vector3i(0, -1, 0);
	if (!is_blocked(below)) {
		return below;
	}
	// Position-hashed rotation in place of GDScript's shuffle — same
	// "first open side" acceptance, order varies per cell.
	const int start = (int)(((pos.x * 31 + pos.z * 17 + pos.y * 13) & 3) + 4) & 3;
	for (int i = 0; i < 4; ++i) {
		const Vector3i neighbor = pos + SPILL_SIDES[(start + i) & 3];
		if (!is_blocked(neighbor)) {
			return neighbor;
		}
	}
	return pos;
}

Vector3i DelveSim::settle_floor(const Vector3i &pos, int64_t volume, bool splittable) {
	Vector3i landing = pos;
	Vector3i below = landing + Vector3i(0, -1, 0);
	// The editable check bounds the walk at the streamed edge; 512 steps
	// is a safety net for degenerate states.
	for (int guard = 0; guard < 512; ++guard) {
		if (!is_editable(below) || is_floor_for(below, volume, splittable)) {
			break;
		}
		landing = below;
		below = landing + Vector3i(0, -1, 0);
	}
	return landing;
}

Vector3i DelveSim::accepting_voxel(
		const Vector3i &pos, int64_t item_volume, bool loose, int64_t needed) {
	static const Vector3i MAX_V(INT32_MAX, INT32_MAX, INT32_MAX);
	const int64_t want =
			needed >= 0 ? std::min(item_volume, needed) : std::min(item_volume, (int64_t)BLOCK_CM3);
	Vector3i partial = MAX_V;

	// Adjoining voxels first: below, then sides from emptiest to fullest,
	// then straight up — each judged by where the item would settle.
	Vector3i sides[4];
	for (int i = 0; i < 4; ++i) {
		sides[i] = pos + SPILL_SIDES[i];
	}
	std::sort(sides, sides + 4, [this](const Vector3i &a, const Vector3i &b) {
		return fill_of(a) < fill_of(b);
	});

	const Vector3i adjoining[6] = {
		pos + Vector3i(0, -1, 0), sides[0], sides[1], sides[2], sides[3],
		pos + Vector3i(0, 1, 0),
	};
	for (const Vector3i &candidate : adjoining) {
		if (is_blocked(candidate)) {
			continue;
		}
		const Vector3i landing = settle_floor(candidate, item_volume, loose);
		if (landing == pos) {
			continue;
		}
		const int64_t room = BLOCK_CM3 - fill_of(landing);
		if (room >= want) {
			return landing;
		}
		if (partial == MAX_V && loose && room > MIN_LOOSE_CM3) {
			partial = landing;
		}
	}

	// Nothing adjoining — BFS outward from the voxel above the source.
	std::unordered_set<uint64_t> visited;
	visited.insert(key_of(pos.x, pos.y, pos.z));
	std::vector<Vector3i> queue;
	queue.push_back(pos + Vector3i(0, 1, 0));
	size_t head = 0;
	while (head < queue.size() && (int)head < MAX_ACCEPT_SEARCH) {
		const Vector3i candidate = queue[head++];
		const uint64_t ckey = key_of(candidate.x, candidate.y, candidate.z);
		if (visited.find(ckey) != visited.end()) {
			continue;
		}
		visited.insert(ckey);
		if (is_blocked(candidate)) {
			continue;
		}
		const Vector3i landing = settle_floor(candidate, item_volume, loose);
		if (landing != pos) {
			const int64_t room = BLOCK_CM3 - fill_of(landing);
			if (room >= want) {
				return landing;
			}
			if (partial == MAX_V && loose && room > MIN_LOOSE_CM3) {
				partial = landing;
			}
		}
		for (const Vector3i &side : SPILL_SIDES) {
			queue.push_back(candidate + side);
		}
		queue.push_back(candidate + Vector3i(0, 1, 0));
		queue.push_back(candidate + Vector3i(0, -1, 0));
	}
	return partial;
}

void DelveSim::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "generator"), &DelveSim::configure);
	ClassDB::bind_method(D_METHOD("on_block_loaded", "block_pos"), &DelveSim::on_block_loaded);
	ClassDB::bind_method(D_METHOD("on_block_unloaded", "block_pos"), &DelveSim::on_block_unloaded);
	ClassDB::bind_method(D_METHOD("is_loaded", "pos"), &DelveSim::is_loaded);
	ClassDB::bind_method(D_METHOD("is_editable", "pos"), &DelveSim::is_editable);
	ClassDB::bind_method(D_METHOD("get_block", "pos"), &DelveSim::get_block);
	ClassDB::bind_method(D_METHOD("set_block", "pos", "block_id"), &DelveSim::set_block);
	ClassDB::bind_method(D_METHOD("is_solid", "pos"), &DelveSim::is_solid);
	ClassDB::bind_method(D_METHOD("is_standable", "pos"), &DelveSim::is_standable);
	ClassDB::bind_method(D_METHOD("set_pile_fill", "pos", "cm3"), &DelveSim::set_pile_fill);
	ClassDB::bind_method(D_METHOD("pile_fill_at", "pos"), &DelveSim::pile_fill_at);
	ClassDB::bind_method(D_METHOD("fill_of", "pos"), &DelveSim::fill_of);
	ClassDB::bind_method(D_METHOD("is_packed", "pos"), &DelveSim::is_packed);
	ClassDB::bind_method(D_METHOD("is_blocked", "pos"), &DelveSim::is_blocked);
	ClassDB::bind_method(D_METHOD("is_unit_standable", "pos"), &DelveSim::is_unit_standable);
	ClassDB::bind_method(
			D_METHOD("work_spots", "target", "from", "solid_target", "exclude_self", "reach"),
			&DelveSim::work_spots);
	ClassDB::bind_method(
			D_METHOD("can_reach_from", "from", "target", "solid_target", "reach"),
			&DelveSim::can_reach_from);
	ClassDB::bind_method(
			D_METHOD("find_path", "from", "to", "avoid_packed"),
			&DelveSim::find_path, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("spill_target", "pos"), &DelveSim::spill_target);
	ClassDB::bind_method(
			D_METHOD("settle_floor", "pos", "volume", "splittable"),
			&DelveSim::settle_floor);
	ClassDB::bind_method(
			D_METHOD("accepting_voxel", "pos", "item_volume", "loose", "needed"),
			&DelveSim::accepting_voxel);
	ClassDB::bind_method(D_METHOD("debug_stats"), &DelveSim::debug_stats);
}

} // namespace delve
