#include "delve_sim.h"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>

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

Vector3i DelveSim::pos_of_key(uint64_t key) {
	// Inverse of key_of: each 21-bit field sign-extends back to an int.
	auto un = [](uint64_t v) -> int {
		return (int)(((int64_t)(v & 0x1fffff) << 43) >> 43);
	};
	return Vector3i(un(key >> 42), un(key >> 21), un(key));
}

int DelveSim::cell_index(int rx, int ry, int rz) {
	return rx | (rz << 4) | (ry << 8);
}

void DelveSim::dlog(const String &msg) {
	if (!log_stream.is_open()) {
		return;
	}
	log_stream << Time::get_singleton()->get_ticks_msec() << "ms "
			   << msg.utf8().get_data() << "\n"
			   << std::flush;
}

bool DelveSim::configure(const Ref<RefCounted> &generator) {
	gen = Ref<DelveGenerator>(Object::cast_to<DelveGenerator>(generator.ptr()));
	if (gen.is_valid()) {
		bedrock_height = gen->get_bedrock_height();
	}
	const String path = ProjectSettings::get_singleton()->globalize_path(
			"user://delve_native.log");
	log_stream.open(std::string(path.utf8().get_data()), std::ios::trunc);
	dlog("configured");
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
	if (chunks.size() % 64 == 0) {
		dlog(vformat("materialize %d chunks, latest=(%d,%d,%d)",
				(int64_t)chunks.size(), block_pos.x, block_pos.y, block_pos.z));
	}
}

// The mirror caches generated terrain; when the generator's inputs
// change (regional grid / site field installs during boot) already-
// materialized chunks go stale and must be re-derived. Epoch changes
// only occur while world boot holds streaming, so the cleared chunks
// carry no mirrored edits — if that ever stops being true this clear
// would also drop uncommitted mirror state and needs rethinking.
void DelveSim::sync_gen_epoch() {
	if (gen.is_null() || gen->revision() == _gen_epoch) {
		return;
	}
	_gen_epoch = gen->revision();
	if (chunks.empty()) {
		return;
	}
	dlog(vformat("generator inputs changed; dropping %d mirrored chunks",
			(int64_t)chunks.size()));
	chunks.clear();
}

DelveSim::Chunk *DelveSim::chunk_at(const Vector3i &pos) {
	sync_gen_epoch();
	const uint64_t key = key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4);
	auto it = chunks.find(key);
	if (it != chunks.end()) {
		return it->second.get();
	}
	if (_mat_budget == 0) {
		return nullptr;
	}
	if (_mat_budget > 0) {
		--_mat_budget;
	}
	materialize(Vector3i(pos.x >> 4, pos.y >> 4, pos.z >> 4));
	it = chunks.find(key);
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
	// Aggregate-only logging: a camera pan unloads ~600 blocks in a
	// frame, and a flushed write per block is itself a stall.
	if (++_unloads_since_log >= 256) {
		dlog(vformat("block_unloaded x%d, latest=(%d,%d,%d)",
				_unloads_since_log, block_pos.x, block_pos.y, block_pos.z));
		_unloads_since_log = 0;
	}
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
	if (!water_seeded) {
		return;
	}
	// Terrain edits change the flow geometry: mining into a bank has
	// to flood the dig, filling a channel has to push its water out.
	// Reactivate the cell and its face neighbours so the next water
	// step sees the new void — a settled body contributes nothing
	// otherwise.
	static const Vector3i DIRS[7] = {
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	};
	bool near_water = false;
	for (const Vector3i &d : DIRS) {
		const Vector3i np = pos + d;
		const uint64_t nk = key_of(np.x, np.y, np.z);
		if (water_cell(np.x, np.y, np.z) > 0) {
			near_water = true;
			water_active.insert(nk);
		}
	}
	if (block_id != BLOCK_AIR) {
		// Solid fill displaces the cell's water — push it into open
		// neighbours, preferring the cell above (placed blocks squirt
		// their water up around the rim). Whatever can't move is
		// squeezed out — a truly packed fill losing its water is the
		// honest edge case.
		const uint32_t displaced = water_at(pos);
		if (displaced > 0) {
			water_put(pos, 0);
			int64_t left = displaced;
			static const Vector3i PUSH[5] = {
				Vector3i(0, 1, 0),
				Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			};
			for (const Vector3i &d : PUSH) {
				if (left <= 0) {
					break;
				}
				const Vector3i np = pos + d;
				if (!water_in_bounds(np.x, np.z) || water_solid_at(np)) {
					continue;
				}
				const int64_t room = WATER_FULL - water_at(np);
				const int64_t move = std::min(left, room);
				if (move <= 0) {
					continue;
				}
				water_put(np, water_at(np) + (uint32_t)move);
				left -= move;
				water_raise_top(np);
				water_active.insert(key_of(np.x, np.y, np.z));
				water_mark_dirty(np.x, np.z);
			}
			near_water = true;
			water_mark_dirty(pos.x, pos.z);
			water_refresh_top(col_key_of(pos.x, pos.z), pos.x, pos.z);
		}
		water_active.erase(key_of(pos.x, pos.y, pos.z));
	}
	if (near_water) {
		water_active.insert(key_of(pos.x, pos.y, pos.z));
		water_mark_dirty(pos.x, pos.z);
	}
}

bool DelveSim::is_solid(const Vector3i &pos) {
	return get_block(pos) != BLOCK_AIR;
}

// Solidity query for the water pass that never materializes a chunk —
// unmaterialized chunks hold no edits, so the generator can answer the
// single cell directly. A flow frontier touching unexplored ground
// would otherwise generate a full 16³ chunk per probe.
bool DelveSim::water_solid_at(const Vector3i &pos) {
	sync_gen_epoch();
	const uint64_t key =
			key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4);
	const auto it = chunks.find(key);
	if (it != chunks.end()) {
		return (*it->second)
						[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)]
				!= BLOCK_AIR;
	}
	if (gen.is_null()) {
		return false;
	}
	const int grass = gen->terrain_height(pos.x, pos.z);
	const int rt = gen->rock_top(pos.x, pos.z, grass);
	return gen->block_at(pos.x, pos.y, pos.z, grass, rt) != BLOCK_AIR;
}

// Same dual-source query as water_solid_at but returns the block id —
// the slice cap colors its cross-section by block, and unloaded cells
// still need an answer (the generator computes the would-be block,
// caves included) or the plan reads as swiss cheese over the fringe.
int64_t DelveSim::probe_block(const Vector3i &pos) {
	sync_gen_epoch();
	const uint64_t key =
			key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4);
	const auto it = chunks.find(key);
	if (it != chunks.end()) {
		return (*it->second)
				[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)];
	}
	if (gen.is_null()) {
		return BLOCK_AIR;
	}
	const int grass = gen->terrain_height(pos.x, pos.z);
	const int rt = gen->rock_top(pos.x, pos.z, grass);
	return gen->block_at(pos.x, pos.y, pos.z, grass, rt);
}

// Memory forensics for soak probes — one entry per live container so a
// runaway store shows up as a growing number instead of a mystery OOM.
godot::Dictionary DelveSim::debug_sizes() const {
	godot::Dictionary d;
	d["chunks"] = (int64_t)chunks.size();
	d["loaded_blocks"] = (int64_t)loaded_blocks.size();
	d["pile_loose"] = (int64_t)pile_loose.size();
	d["pile_clutter"] = (int64_t)pile_clutter.size();
	d["ladders"] = (int64_t)ladders.size();
	d["doors"] = (int64_t)doors.size();
	d["water_chunks"] = (int64_t)water_chunks.size();
	d["water_seed_chunks"] = (int64_t)water_seed_chunks.size();
	d["water_tops"] = (int64_t)water_tops.size();
	d["water_sources"] = (int64_t)water_sources.size();
	d["water_drains"] = (int64_t)water_drains.size();
	d["water_no_evap"] = (int64_t)water_no_evap.size();
	d["water_active"] = (int64_t)water_active.size();
	d["water_dirty_cols"] = (int64_t)water_dirty_cols.size();
	d["evap_queue"] = (int64_t)_water_evap_queue.size();
	d["job_board"] = (int64_t)job_board.size();
	d["pile_falls"] = (int64_t)pile_falls.size();
	d["unit_bodies"] = (int64_t)unit_bodies.size();
	d["point_map"] = (int64_t)point_map.size();
	return d;
}

bool DelveSim::is_standable(const Vector3i &pos) {
	return is_solid(pos + Vector3i(0, -1, 0)) && !is_solid(pos) && !is_solid(pos + Vector3i(0, 1, 0));
}

void DelveSim::set_pile_fill(const Vector3i &pos, int64_t loose_cm3, int64_t clutter_cm3) {
	const uint64_t key = key_of(pos.x, pos.y, pos.z);
	if (loose_cm3 <= 0) {
		pile_loose.erase(key);
	} else {
		pile_loose[key] = (int32_t)loose_cm3;
	}
	if (clutter_cm3 <= 0) {
		pile_clutter.erase(key);
	} else {
		pile_clutter[key] = (int32_t)clutter_cm3;
	}
}

int64_t DelveSim::pile_loose_at(const Vector3i &pos) const {
	const auto it = pile_loose.find(key_of(pos.x, pos.y, pos.z));
	return it == pile_loose.end() ? 0 : it->second;
}

int64_t DelveSim::pile_clutter_at(const Vector3i &pos) const {
	const auto it = pile_clutter.find(key_of(pos.x, pos.y, pos.z));
	return it == pile_clutter.end() ? 0 : it->second;
}

int64_t DelveSim::pile_fill_at(const Vector3i &pos) const {
	return pile_loose_at(pos) + pile_clutter_at(pos);
}

bool DelveSim::is_dense(const Vector3i &pos) const {
	return pile_clutter_at(pos) >= CLUTTER_BLOCK_CM3;
}

int64_t DelveSim::fill_of(const Vector3i &pos) {
	return is_solid(pos) ? BLOCK_CM3 : pile_fill_at(pos);
}

void DelveSim::set_ladder(const Vector3i &pos, bool on) {
	const uint64_t key = key_of(pos.x, pos.y, pos.z);
	if (on) {
		ladders.insert(key);
	} else {
		ladders.erase(key);
	}
}

bool DelveSim::ladder_at(const Vector3i &pos) const {
	return ladders.find(key_of(pos.x, pos.y, pos.z)) != ladders.end();
}

void DelveSim::set_door(const Vector3i &pos, bool on) {
	const uint64_t key = key_of(pos.x, pos.y, pos.z);
	if (on) {
		doors.insert(key);
	} else {
		doors.erase(key);
	}
}

bool DelveSim::door_at(const Vector3i &pos) const {
	return doors.find(key_of(pos.x, pos.y, pos.z)) != doors.end();
}

int64_t DelveSim::capacity_at(const Vector3i &pos) const {
	return ladder_at(pos) ? LADDER_PILE_CM3 : (int64_t)BLOCK_CM3;
}

bool DelveSim::is_packed(const Vector3i &pos) const {
	return pile_fill_at(pos) >= capacity_at(pos);
}

bool DelveSim::is_blocked(const Vector3i &pos) {
	return solid_at(pos, true);
}

// A floor a unit can rest on: real ground or a loose mound compacted
// full. Discrete goods offer no footing however dense they pack — a
// cell of them is waded or blocks, it never holds anyone up.
bool DelveSim::flooring_at(const Vector3i &pos) {
	return is_solid(pos) || pile_loose_at(pos) >= capacity_at(pos);
}

// Standable = support at feet level: flooring below, the top of a
// ladder in the cell below, the base of a ladder in the cell itself —
// or loose fill in the cell, whose surface the unit stands on. A high
// pile lifts the capsule's head into the second cell up, which must be
// free too. Head-deep water isn't standable — the level datum reaching
// the head voxel means swimming, not standing (a wading-depth cell
// still passes).
bool DelveSim::is_unit_standable(const Vector3i &pos) {
	const Vector3i down(0, -1, 0);
	if (is_blocked(pos) || is_blocked(pos + Vector3i(0, 1, 0))) {
		return false;
	}
	if (water_level_at(pos.x, pos.z) >= pos.y + 1) {
		return false;
	}
	const int64_t fill = pile_loose_at(pos);
	if (
			!flooring_at(pos + down) && !ladder_at(pos + down) &&
			!ladder_at(pos) && fill <= 0) {
		return false;
	}
	return fill <= 0 || float(fill) / float(BLOCK_CM3) <= 0.2f ||
			!is_blocked(pos + Vector3i(0, 2, 0));
}

PackedVector3Array DelveSim::collapse_check(const Vector3i &removed) {
	// Six face directions — support chains are face-adjacent only; a
	// diagonal staircase genuinely doesn't transmit it.
	static const Vector3i DIRS6[6] = {
		Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
		Vector3i(0, -1, 0), Vector3i(0, 1, 0),
		Vector3i(0, 0, -1), Vector3i(0, 0, 1),
	};
	PackedVector3Array doomed;
	// Cells proven anchored this call — a later seed reaching one is
	// anchored through it; cells condemned are skipped outright.
	std::unordered_set<uint64_t> anchored;
	std::unordered_set<uint64_t> seen;
	for (const Vector3i &dir : DIRS6) {
		const Vector3i seed = removed + dir;
		const uint64_t seed_key = key_of(seed.x, seed.y, seed.z);
		if (seen.count(seed_key) || !is_editable(seed) ||
				!solid_at(seed, false)) {
			continue;
		}
		// Best-first flood by lowest y: an anchored component dives
		// straight to bedrock in ~depth pops; a detached blob exhausts
		// quickly. Neither ordering changes what's proven, only the cost.
		std::priority_queue<std::pair<int64_t, uint64_t>> heap;
		std::unordered_set<uint64_t> local;
		heap.push(std::make_pair(-(int64_t)seed.y, seed_key));
		local.insert(seed_key);
		bool ok = false;
		while (!heap.empty() && !ok) {
			const auto top = heap.top();
			heap.pop();
			const Vector3i cell = pos_of_key(top.second);
			if (cell.y <= bedrock_height) {
				ok = true; // the base level itself
				break;
			}
			const int64_t id = get_block(cell);
			if (id == BLOCK_TRUNK || id == BLOCK_BRANCH) {
				ok = true; // a tree is its own anchor
				break;
			}
			for (const Vector3i &d : DIRS6) {
				const Vector3i next = cell + d;
				const uint64_t nkey = key_of(next.x, next.y, next.z);
				if (local.count(nkey)) {
					continue;
				}
				if (anchored.count(nkey)) {
					ok = true;
					break;
				}
				if (seen.count(nkey)) {
					// A condemned component's member — B merges into the
					// same fate; no need to re-traverse it.
					continue;
				}
				if (!is_editable(next)) {
					// The frontier — can't disprove a chain through
					// unstreamed terrain; never condemn on a guess.
					ok = true;
					break;
				}
				if (!solid_at(next, false)) {
					continue;
				}
				local.insert(nkey);
				heap.push(std::make_pair(-(int64_t)next.y, nkey));
			}
			if ((int64_t)local.size() > MAX_COLLAPSE_FLOOD) {
				ok = true; // too big to disprove — call it anchored
				break;
			}
		}
		seen.insert(local.begin(), local.end());
		if (ok) {
			anchored.insert(local.begin(), local.end());
		} else {
			for (const uint64_t k : local) {
				doomed.push_back(pos_of_key(k));
			}
		}
	}
	return doomed;
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
				// The eye sits at the stand height — on a pile that's its
				// loose-fill surface, not the cell's base.
				const Vector3 eye = Vector3(spot) + Vector3(
						0.5, 0.9 + double(pile_loose_at(spot)) / BLOCK_CM3, 0.5);
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
	if (chunk == nullptr) {
		// Either the generator is missing (all air) or a bounded search
		// exhausted its materialize budget — then the unknown reads as
		// solid so paths can't route through unexplored space.
		return _mat_budget == 0;
	}
	if ((*chunk)[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)] != BLOCK_AIR) {
		return true;
	}
	return packed_blocks &&
			(pile_fill_at(pos) >= capacity_at(pos) || is_dense(pos));
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

// A path cell needs ground (or a ladder rung) within fall distance —
// a ladder column is its own kind of floor, which is what keeps a long
// shaft of ladder cells pathable while hanging over open air.
bool DelveSim::ground_close_enough(const Vector3i &pos, bool packed_blocks) {
	for (int i = 1; i <= MAX_FALL_HEIGHT; ++i) {
		const Vector3i below = pos - Vector3i(0, i, 0);
		if (
				solid_at(below, false) || ladder_at(below) ||
				(packed_blocks && flooring_at(below))) {
			return true;
		}
	}
	return false;
}

void DelveSim::neighbor_positions(
		const Vector3i &pos, bool packed_blocks, Vector3i *out, int &count) {
	count = 0;
	const Vector3i down(0, -1, 0);
	const Vector3i up(0, 1, 0);
	// Supported = standing on flooring, on a ladder's top, or inside a
	// ladder cell — the same rule is_unit_standable uses. Clutter never
	// floors: a dense heap walls but holds nobody up.
	const bool c_below =
			solid_at(pos + down, false) || flooring_at(pos + down) ||
			ladder_at(pos + down) || ladder_at(pos);
	bool may_jump = false;

	Vector3i candidates[12];
	int n = 0;
	for (const Vector3i &dir : DIRECTIONS_2D) {
		const Vector3i npos = pos + dir;
		if (solid_at(npos, packed_blocks)) {
			may_jump = true;
			continue;
		}
		if (!c_below) {
			// Coming from a floating cell: the neighbor needs a floor —
			// its own ladder counts, as does standing on one below it.
			if (
					!flooring_at(npos + down) &&
					!ladder_at(npos + down) && !ladder_at(npos)) {
				continue;
			}
		}
		if (!ground_close_enough(npos, packed_blocks)) {
			continue;
		}
		candidates[n++] = npos;
	}
	// Climbing up: the usual jump onto a hemmed-in ledge, or a ladder —
	// the one in this cell lifts you to the next, the one above is
	// grabbed from below.
	bool up_candidate = may_jump && c_below;
	up_candidate = up_candidate || ladder_at(pos) || ladder_at(pos + up);
	if (up_candidate) {
		candidates[n++] = pos + up;
	}
	if (!c_below) {
		candidates[n++] = pos + down;
	} else if (ladder_at(pos + down)) {
		// Descending into the ladder rung below — a ladder is climbed
		// down rather than fallen past.
		candidates[n++] = pos + down;
	}
	for (int i = 0; i < n; ++i) {
		const Vector3i npos = candidates[i];
		if (!fits_at(npos, packed_blocks)) {
			continue;
		}
		if (!fits_between(pos, npos, packed_blocks)) {
			continue;
		}
		// Head-deep water walls the move — same gate as
		// is_unit_standable, and now reads the live sim so a flooded
		// corridor closes without waiting on the static datum.
		if (water_level_at(npos.x, npos.z) >= npos.y + 1) {
			continue;
		}
		out[count++] = npos;
	}
}

PackedVector3Array DelveSim::find_path(
		const Vector3i &from, const Vector3i &to, bool avoid_packed,
		int64_t margin) {
	// Logged on entry — this was a crash site, so its args matter.
	dlog(vformat("find_path (%d,%d,%d)->(%d,%d,%d) avoid_packed=%d",
			from.x, from.y, from.z, to.x, to.y, to.z, (int)avoid_packed));
	PackedVector3Array result;
	// Search bounds: the endpoints' box plus margin — the same region the
	// GDScript AStarGrid3D was clamped to, and inside the colony boundary
	// rule (pathing never explores past the boundary + margin). This is
	// what keeps an unreachable target from fanning out across the whole
	// materializable world.
	const Vector3i lo(
			MIN(from.x, to.x) - (int)margin,
			MIN(from.y, to.y) - (int)margin,
			MIN(from.z, to.z) - (int)margin);
	const Vector3i hi(
			MAX(from.x, to.x) + (int)margin,
			MAX(from.y, to.y) + (int)margin,
			MAX(from.z, to.z) + (int)margin);
	const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
	const int saved_budget = _mat_budget;
	_mat_budget = MAX_PATH_MATERIALIZE;
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

	while (!open_heap.empty() && pool.size() <= MAX_PATH_NODES) {
		const auto top = open_heap.front();
		std::pop_heap(open_heap.begin(), open_heap.end(), heap_cmp);
		open_heap.pop_back();
		const uint32_t ci = top.second;
		// Copy, not reference — pool.push_back below can reallocate the
		// vector, which would leave a held reference dangling.
		const PathNode current = pool[ci];
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
			if (npos.x < lo.x || npos.x > hi.x ||
					npos.y < lo.y || npos.y > hi.y ||
					npos.z < lo.z || npos.z > hi.z) {
				continue;
			}
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
			float edge = std::sqrt((float)(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z));
			// A door is a hole in the wall that costs a pause: charge the
			// swing time here so a genuinely shorter open route wins.
			if (doors.find(nkey) != doors.end()) {
				edge += DOOR_COST;
			}
			// Pushing through clutter costs on a curve that steepens as
			// the heap packs — mirroring Colony.traversal_mult's
			// 1/(1 + K·f²) walk multiplier as edge cost 1 + K·f².
			const int64_t clutter = pile_clutter_at(npos);
			if (clutter > 0) {
				const float f = std::min(
						1.0f, float(clutter) / float(capacity_at(npos)));
				edge *= 1.0f + CLUTTER_K * f * f;
			}
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

	const int64_t elapsed_ms =
			(Time::get_singleton()->get_ticks_usec() - t0) / 1000;
	if (elapsed_ms > 20 || pool.size() > MAX_PATH_NODES || _mat_budget == 0) {
		dlog(vformat("find_path slow: %dms, %d nodes, capped=%d budget=%d",
				elapsed_ms, (int64_t)pool.size(),
				(int)(pool.size() > MAX_PATH_NODES), _mat_budget));
	}
	_mat_budget = saved_budget;

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
	stats["piles"] = (int64_t)pile_loose.size() + (int64_t)pile_clutter.size();
	stats["jobs"] = (int64_t)job_board.size();
	int64_t claimed = 0;
	for (const auto &entry : job_board) {
		if (entry.second.claimed) {
			claimed += 1;
		}
	}
	stats["jobs_claimed"] = claimed;
	stats["falls"] = (int64_t)pile_falls.size();
	int64_t water_cm3 = 0;
	int64_t water_cells = 0;
	for (const auto &[ck, chunk] : water_chunks) {
		for (int i = 0; i < CHUNK_CELLS; ++i) {
			water_cm3 += (*chunk)[i];
			water_cells += (*chunk)[i] > 0 ? 1 : 0;
		}
	}
	stats["water_cm3"] = water_cm3;
	stats["water_cells"] = water_cells;
	stats["water_active"] = (int64_t)water_active.size();
	stats["water_cols"] = (int64_t)water_tops.size();
	return stats;
}

// ---- Job board ---------------------------------------------------------

void DelveSim::job_add(
		int64_t id, const Vector3i &voxel,
		int64_t job_type, int64_t posted_ms) {
	dlog(vformat("job_add %d (%d,%d,%d)", id, voxel.x, voxel.y, voxel.z));
	JobRecord record;
	record.voxel = voxel;
	record.job_type = (int32_t)job_type;
	record.posted_ms = posted_ms;
	job_board[id] = record;
}

void DelveSim::job_remove(int64_t id) {
	dlog(vformat("job_remove %d", id));
	job_board.erase(id);
}

void DelveSim::job_suspend(int64_t id, bool on) {
	auto it = job_board.find(id);
	if (it != job_board.end()) {
		it->second.suspended = on;
		if (on) {
			// Suspending releases the holder — a job put back on the
			// board while a unit held it must not stay claimed forever
			// or it can never be taken again once unsuspended.
			it->second.claimed = false;
		}
	}
}

void DelveSim::job_set_posted(int64_t id, int64_t posted_ms) {
	auto it = job_board.find(id);
	if (it != job_board.end()) {
		it->second.posted_ms = posted_ms;
	}
}

void DelveSim::job_drop(int64_t id, int64_t unit_id, int64_t now_ms) {
	dlog(vformat("job_drop %d unit=%d", id, unit_id));
	auto it = job_board.find(id);
	if (it == job_board.end()) {
		return;
	}
	JobRecord &job = it->second;
	job.claimed = false;
	JobRecord::Drop &drop = job.dropped_by[(uint64_t)unit_id];
	drop.at = now_ms;
	drop.n += 1;
	// Unit 0 is the colony-wide record: a job that keeps failing backs off
	// for everyone, so an unreachable job can't carousel between units.
	JobRecord::Drop &any = job.dropped_by[0];
	any.at = now_ms;
	any.n += 1;
}

int64_t DelveSim::job_claim(
		int64_t unit_id, const Vector3 &pos, int64_t now_ms,
		int64_t retry_base_ms, int64_t retry_max_ms,
		const PackedFloat64Array &type_scores,
		double dist_weight, double languish_rate, double languish_cap_s) {
	// Instance ids are arbitrary int64s (often negative) — track found
	// flags rather than using a sentinel value.
	bool has_best = false;
	int64_t best = 0;
	double best_d = std::numeric_limits<double>::max();
	bool has_retry = false;
	int64_t retry = 0;
	double retry_d = std::numeric_limits<double>::max();
	for (auto &entry : job_board) {
		JobRecord &job = entry.second;
		if (job.claimed || job.suspended) {
			continue;
		}
		// Lower wins: metres, minus the unit's skill bonus for this type,
		// minus the waiting-time bonus — both in metres-equivalent.
		double bonus = 0.0;
		if (job.job_type >= 0 && job.job_type < type_scores.size()) {
			bonus = type_scores[job.job_type];
		}
		const double age_s = std::max(
				(now_ms - job.posted_ms) / 1000.0, 0.0);
		const double d = Vector3(job.voxel).distance_to(pos) * dist_weight
				- bonus
				- std::min(age_s, languish_cap_s) * languish_rate;
		// Wildcard backoff first: a recently-dropped job cools off for the
		// whole colony.
		const auto any = job.dropped_by.find(0);
		if (any != job.dropped_by.end()) {
			const int ashift = std::min(any->second.n - 1, 30);
			const int64_t adelay = std::min(retry_base_ms << ashift, retry_max_ms);
			if (now_ms - any->second.at < adelay) {
				continue;
			}
		}
		const auto dropped = job.dropped_by.find((uint64_t)unit_id);
		if (dropped == job.dropped_by.end()) {
			if (!has_best || d < best_d) {
				best_d = d;
				best = entry.first;
				has_best = true;
			}
			continue;
		}
		// retry_delay_msec: base * 2^(n-1), capped — clamp the shift so a
		// pathological drop count can't overflow.
		const int shift = std::min(dropped->second.n - 1, 30);
		const int64_t delay = std::min(retry_base_ms << shift, retry_max_ms);
		if (now_ms - dropped->second.at < delay) {
			continue;
		}
		if (!has_retry || d < retry_d) {
			retry_d = d;
			retry = entry.first;
			has_retry = true;
		}
	}
	if (has_best || has_retry) {
		const int64_t chosen = has_best ? best : retry;
		job_board[chosen].claimed = true;
		return chosen;
	}
	return -1;
}

// ---- Dynamic water ------------------------------------------------------
//
// Per-cell volumes, evolved at WATER_TICK_SEC cadence inside tick():
//   1. Sources top their cells up, drains remove, and every ~5 s the
//      exposed surface cells shed the evaporation rate.
//   2. Gravity: a wet cell pours into the open cell below at full rate.
//   3. Head exchange: a wet cell trades volume with open lateral and
//      upward neighbours proportional to the head difference — K times
//      the gap per tick — where a cell's head is the free surface of its
//      connected body. See water_body_head for the connectivity rule.
// All flows are computed against the pre-step state and applied as one
// delta pass (Jacobi ordering) — what a cell exports is limited by what
// it holds, what a cell imports by the room its pending inflow leaves.
// Cells that changed reactivate themselves and their neighbours, so a
// settled body drops out of the pass entirely.

uint64_t DelveSim::col_key_of(int x, int z) {
	const uint64_t ux = (uint64_t)(x & 0x1fffff);
	const uint64_t uz = (uint64_t)(z & 0x1fffff);
	return (ux << 21) | uz;
}

int32_t DelveSim::water_cell(int x, int y, int z) const {
	return (int32_t)water_at(Vector3i(x, y, z));
}

uint32_t DelveSim::water_at(const Vector3i &pos) const {
	const uint64_t ck = key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4);
	const auto it = water_chunks.find(ck);
	if (it == water_chunks.end()) {
		return 0;
	}
	return (*it->second)[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)];
}

void DelveSim::water_put(const Vector3i &pos, uint32_t vol) {
	const uint64_t ck = key_of(pos.x >> 4, pos.y >> 4, pos.z >> 4);
	auto it = water_chunks.find(ck);
	if (it == water_chunks.end()) {
		if (vol == 0) {
			return;
		}
		auto wc = std::make_unique<WaterChunk>();
		wc->fill(0);
		it = water_chunks.emplace(ck, std::move(wc)).first;
	}
	(*it->second)[cell_index(pos.x & 15, pos.y & 15, pos.z & 15)] = vol;
}

bool DelveSim::water_in_bounds(int x, int z) const {
	return x >= water_min_x && x < water_max_x &&
			z >= water_min_z && z < water_max_z;
}

void DelveSim::water_seed_flood(
		const PackedInt32Array &flood, const Vector2i &origin, int64_t vs,
		const PackedByteArray &cell_flags, int64_t cell_m) {
	water_chunks.clear();
	water_seed_chunks.clear();
	water_tops.clear();
	water_sources.clear();
	water_drains.clear();
	water_active.clear();
	water_dirty_cols.clear();
	water_no_evap.clear();
	water_flux.clear();
	_water_evap_queue.clear();
	_water_rain_queue.clear();
	_water_accum = 0.0;
	water_seeded = true;
	water_min_x = origin.x;
	water_min_z = origin.y;
	water_max_x = origin.x + (int)vs;
	water_max_z = origin.y + (int)vs;
	if (gen.is_null()) {
		return;
	}
	for (int64_t i = 0; i < vs * vs; ++i) {
		const int level = flood[i];
		if (level == WATER_DRY) {
			continue;
		}
		const int x = origin.x + (int)(i % vs);
		const int z = origin.y + (int)(i / vs);
		const int grass = gen->terrain_height(x, z);
		const int surf = std::max(grass, gen->rock_top(x, z, grass));
		for (int y = surf + 1; y <= level; ++y) {
			// The skin cell seeds just under full so the rendered
			// surface sits exactly where the static datum put it.
			water_put(
					Vector3i(x, y, z),
					y == level ? WATER_SEED_TOP : (int32_t)WATER_FULL);
		}
		if (surf + 1 <= level) {
			water_tops[col_key_of(x, z)] = level;
			water_mark_dirty(x, z);
		}
	}
	// The settle pass only needs the frontier: a wet cell that can
	// actually export — open air beside it (shoreline creep) or below
	// it (a pour). A saturated cell can also push up into air overhead
	// when body pressure is behind it, but a partial skin can't: the
	// flat interior and surface stay dormant until the shoreline
	// reaches them.
	static const Vector3i DIRS6[6] = {
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	};
	for (const auto &[ckey, chunk] : water_chunks) {
		const Vector3i base = pos_of_key(ckey) * CHUNK;
		for (int i = 0; i < CHUNK_CELLS; ++i) {
			const uint32_t v = (*chunk)[i];
			if (v == 0) {
				continue;
			}
			const Vector3i pos(
					base.x + (i & 15), base.y + (i >> 8),
					base.z + ((i >> 4) & 15));
			for (const Vector3i &d : DIRS6) {
				if (d.y > 0 && (int32_t)v < WATER_FULL) {
					continue;
				}
				const Vector3i np = pos + d;
				if (water_at(np) == 0 && !water_solid_at(np)) {
					water_active.insert(key_of(pos.x, pos.y, pos.z));
					break;
				}
			}
		}
	}
	// River columns evade evaporation — their water comes from an
	// upstream catchment this pass doesn't model, so letting them
	// sweat would dry the channel over a day.
	if (cell_flags.size() > 0 && cell_m > 0) {
		const int64_t side = vs / cell_m;
		for (int64_t cz = 0; cz < side; ++cz) {
			for (int64_t cx = 0; cx < side; ++cx) {
				if ((cell_flags[cz * side + cx] & 2) == 0) {
					continue;
				}
				for (int64_t dz = 0; dz < cell_m; ++dz) {
					for (int64_t dx = 0; dx < cell_m; ++dx) {
						water_no_evap.insert(col_key_of(
								origin.x + (int)(cx * cell_m + dx),
								origin.y + (int)(cz * cell_m + dz)));
					}
				}
			}
		}
	}
	// Snapshot the seed — water_serialize diffs against this baseline
	// so a still body saves as nothing.
	for (const auto &[ckey, chunk] : water_chunks) {
		auto copy = std::make_unique<WaterChunk>();
		*copy = *chunk;
		water_seed_chunks[ckey] = std::move(copy);
	}
	dlog(vformat("water seeded: %d chunks, %d columns, %d active",
			(int64_t)water_chunks.size(), (int64_t)water_tops.size(),
			(int64_t)water_active.size()));
}

void DelveSim::water_mark_dirty(int x, int z) {
	water_dirty_cols.insert(col_key_of(x, z));
	water_dirty_cols.insert(col_key_of(x + 1, z));
	water_dirty_cols.insert(col_key_of(x - 1, z));
	water_dirty_cols.insert(col_key_of(x, z + 1));
	water_dirty_cols.insert(col_key_of(x, z - 1));
}

void DelveSim::water_refresh_top(uint64_t col_key, int x, int z,
		const std::unordered_map<uint64_t, int64_t> *delta) {
	const auto it = water_tops.find(col_key);
	if (it == water_tops.end()) {
		return;
	}
	int y = it->second;
	// A cell above the recorded top may have filled; climb, but only
	// onto a cell with footing (see water_raise_top).
	while (water_cell(x, y + 1, z) >= WATER_TOP_MIN &&
			(water_supported(x, y, z, delta))) {
		++y;
	}
	while (y > bedrock_height - 16 && water_cell(x, y, z) < WATER_TOP_DROP) {
		--y;
	}
	if (y <= bedrock_height - 16) {
		water_tops.erase(it);
	} else {
		it->second = y;
	}
}

bool DelveSim::water_supported(int x, int y, int z,
		const std::unordered_map<uint64_t, int64_t> *delta) {
	int64_t below_v = water_cell(x, y, z);
	if (delta != nullptr) {
		const auto bd = delta->find(key_of(x, y, z));
		if (bd != delta->end()) {
			below_v += bd->second;
		}
	}
	return below_v >= WATER_FULL || water_solid_at(Vector3i(x, y, z));
}

void DelveSim::water_raise_top(const Vector3i &pos,
		const std::unordered_map<uint64_t, int64_t> *delta) {
	if (water_at(pos) < WATER_TOP_MIN) {
		return;
	}
	const uint64_t ck = col_key_of(pos.x, pos.z);
	const auto tit = water_tops.find(ck);
	if (tit == water_tops.end()) {
		water_tops[ck] = pos.y;
		return;
	}
	if (pos.y <= tit->second) {
		return;
	}
	// Climbing past the recorded top only counts when the new cell has
	// footing — a saturated cell or solid ground directly below. Water
	// pushed above a partial surface always pours into that surface's
	// room, so letting it count would flip the waterline a whole voxel
	// each tick while the column fills.
	if (!water_supported(pos.x, pos.y - 1, pos.z, delta)) {
		return;
	}
	water_tops[ck] = pos.y;
}

void DelveSim::water_rescan_top(int x, int z) {
	const uint64_t ck = col_key_of(x, z);
	// Deserialized water can sit well above anything the seed knew
	// (an embanked reservoir), so scan the whole plausible column. The
	// footing rule from water_raise_top applies too: a skim suspended
	// over unsaturated space isn't a surface.
	for (int y = bedrock_height + 512; y > bedrock_height - 16; --y) {
		if (water_cell(x, y, z) >= WATER_TOP_MIN &&
				water_supported(x, y - 1, z, nullptr)) {
			water_tops[ck] = y;
			return;
		}
	}
	water_tops.erase(ck);
}

Dictionary DelveSim::water_serialize() {
	Dictionary out;
	Dictionary chunks_out;
	std::unordered_set<uint64_t> keys;
	for (const auto &[k, c] : water_chunks) {
		keys.insert(k);
	}
	for (const auto &[k, c] : water_seed_chunks) {
		keys.insert(k);
	}
	for (const uint64_t ck : keys) {
		const auto cit = water_chunks.find(ck);
		const auto sit = water_seed_chunks.find(ck);
		PackedInt32Array diffs;
		for (int i = 0; i < CHUNK_CELLS; ++i) {
			const int32_t cur =
					cit == water_chunks.end() ? 0 : (*cit->second)[i];
			const int32_t seed =
					sit == water_seed_chunks.end() ? 0 : (*sit->second)[i];
			if (cur != seed) {
				diffs.push_back(i);
				diffs.push_back(cur);
			}
		}
		if (!diffs.is_empty()) {
			const Vector3i c = pos_of_key(ck);
			chunks_out[vformat("%d,%d,%d", c.x, c.y, c.z)] = diffs;
		}
	}
	out["chunks"] = chunks_out;
	return out;
}

void DelveSim::water_deserialize(const Dictionary &data) {
	if (!water_seeded) {
		return;
	}
	const Dictionary chunks_out = data.get("chunks", Dictionary());
	std::unordered_set<uint64_t> touched_cols;
	const Array keys = chunks_out.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const PackedInt32Array diffs = chunks_out[keys[i]];
		const PackedStringArray parts =
				String(keys[i]).split(",");
		if (parts.size() != 3) {
			continue;
		}
		const Vector3i base(
				parts[0].to_int() * CHUNK, parts[1].to_int() * CHUNK,
				parts[2].to_int() * CHUNK);
		for (int j = 0; j + 1 < diffs.size(); j += 2) {
			const int idx = diffs[j];
			const Vector3i pos(
					base.x + (idx & 15), base.y + (idx >> 8),
					base.z + ((idx >> 4) & 15));
			water_put(pos, (uint32_t)diffs[j + 1]);
			water_active.insert(key_of(pos.x, pos.y, pos.z));
			touched_cols.insert(col_key_of(pos.x, pos.z));
		}
	}
	// Tops and the dirty set rebuild over every column a diff touched —
	// the saved top can sit far from the seeded one in either direction.
	for (const uint64_t ck : touched_cols) {
		const int x = (int)(((int64_t)((ck >> 21) & 0x1fffff) << 43) >> 43);
		const int z = (int)(((int64_t)(ck & 0x1fffff) << 43) >> 43);
		water_rescan_top(x, z);
		water_mark_dirty(x, z);
	}
	dlog(vformat("water restored: %d chunks of diffs, %d columns",
			(int64_t)chunks_out.size(), (int64_t)touched_cols.size()));
}

double DelveSim::water_body_head(uint64_t start_key) {
	// Labels live in lazily-allocated per-chunk arrays stamped with the
	// step's epoch — no cross-step clearing, and a chunk resets only
	// when a scan actually touches it.
	auto comp_at = [&](const Vector3i &p) -> int32_t {
		const auto it = _water_comp_chunks.find(
				key_of(p.x >> 4, p.y >> 4, p.z >> 4));
		if (it == _water_comp_chunks.end() ||
				it->second->epoch != _water_comp_epoch) {
			return -1;
		}
		return it->second->label[cell_index(p.x & 15, p.y & 15, p.z & 15)];
	};
	auto comp_set = [&](const Vector3i &p, int32_t id) {
		const uint64_t ck = key_of(p.x >> 4, p.y >> 4, p.z >> 4);
		auto it = _water_comp_chunks.find(ck);
		if (it == _water_comp_chunks.end()) {
			it = _water_comp_chunks.emplace(
					ck, std::make_unique<WaterCompChunk>()).first;
		}
		WaterCompChunk *wc = it->second.get();
		if (wc->epoch != _water_comp_epoch) {
			wc->label.fill(-1);
			wc->epoch = _water_comp_epoch;
		}
		wc->label[cell_index(p.x & 15, p.y & 15, p.z & 15)] = id;
		++_water_comp_cells;
	};
	const Vector3i start = pos_of_key(start_key);
	const int32_t known = comp_at(start);
	if (known >= 0) {
		return _water_comp_head[known];
	}
	const int32_t id = (int32_t)_water_comp_head.size();
	double head = -1e30;
	std::vector<uint64_t> stack;
	stack.push_back(start_key);
	comp_set(start, id);
	size_t visited = 0;
	while (!stack.empty()) {
		// A storm-scale body (a draining lake) would otherwise scan
		// millions of cells in one step; a truncated scan marks the
		// label UNKNOWN so every cell falls back to its own column's
		// waterline — a partial head measured over an arbitrary subset
		// varies per scan and never settles.
		if (++visited > (size_t)WATER_COMP_CAP) {
			head = WATER_HEAD_UNKNOWN;
			break;
		}
		const uint64_t ck = stack.back();
		stack.pop_back();
		const Vector3i p = pos_of_key(ck);
		const uint32_t v = water_cell(p.x, p.y, p.z);
		head = std::max(head, p.y + v / double(WATER_FULL));
		// Lateral edges join any two wet cells; vertical edges only
		// conduct when the lower cell is saturated — that's the rule
		// that lets a buried conduit push water up a rising arm while
		// a waterfall (partial cells in air) stays unpressurized.
		static const Vector3i DIRS[6] = {
			Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		};
		for (const Vector3i &d : DIRS) {
			const Vector3i np = p + d;
			if (comp_at(np) >= 0) {
				continue;
			}
			const uint32_t nv = water_cell(np.x, np.y, np.z);
			if (nv == 0) {
				continue;
			}
			if (d.y > 0) {
				// Upward: this cell must be saturated to conduct.
				if ((int32_t)v < WATER_FULL) {
					continue;
				}
			} else if (d.y < 0) {
				// Downward: the upper cell (the neighbour) must be.
				if ((int32_t)nv < WATER_FULL) {
					continue;
				}
			}
			comp_set(np, id);
			stack.push_back(key_of(np.x, np.y, np.z));
		}
	}
	_water_comp_head.push_back(head);
	return head;
}

void DelveSim::water_step() {
	water_flux.clear();
	if (water_paused || water_chunks.empty()) {
		water_active.clear();
		return;
	}
	++_water_comp_epoch;
	_water_comp_head.clear();
	_water_comp_cells = 0;
	// Sources and drains are boundary conditions — they fire whether or
	// not the body around them is active, and reactivate their cells.
	for (const auto &[key, rate] : water_sources) {
		const Vector3i pos = pos_of_key(key);
		if (water_solid_at(pos)) {
			continue;
		}
		const uint32_t v = water_at(pos);
		if (v < WATER_FULL) {
			const uint32_t add = (uint32_t)std::min<int64_t>(rate, WATER_FULL - v);
			water_put(pos, v + add);
			water_raise_top(pos);
			water_mark_dirty(pos.x, pos.z);
			water_active.insert(key);
		}
	}
	for (const auto &[key, rate] : water_drains) {
		const Vector3i pos = pos_of_key(key);
		const uint32_t v = water_at(pos);
		if (v > 0) {
			const uint32_t take = (uint32_t)std::min<int64_t>(rate, v);
			water_put(pos, v - take);
			if (v - take < WATER_TOP_DROP) {
				// The drained cell emptied or dropped to a skim — if it
				// was the top, the waterline steps to the next wet cell.
				water_refresh_top(col_key_of(pos.x, pos.z), pos.x, pos.z);
			}
			water_mark_dirty(pos.x, pos.z);
			water_active.insert(key);
		}
	}
	// Pumps move water intake -> outflow like a paired drain/source —
	// conservative by construction: only what the intake holds and the
	// outflow has room for crosses, so a pump into a blocked face or
	// out of a dry one does nothing rather than minting volume.
	for (const auto &[key, pump] : water_pumps) {
		const Vector3i ip = pos_of_key(key);
		const uint32_t v = water_at(ip);
		if (v == 0) {
			continue;
		}
		const Vector3i op = pos_of_key(pump.out_key);
		if (water_solid_at(op)) {
			continue;
		}
		const uint32_t ov = water_at(op);
		const uint32_t move = (uint32_t)std::min<int64_t>(
				std::min<int64_t>(pump.rate_cm3, v), WATER_FULL - ov);
		if (move == 0) {
			continue;
		}
		water_put(ip, v - move);
		water_put(op, ov + move);
		if (v - move < WATER_TOP_DROP) {
			water_refresh_top(col_key_of(ip.x, ip.z), ip.x, ip.z);
		}
		water_raise_top(op);
		water_mark_dirty(ip.x, ip.z);
		water_mark_dirty(op.x, op.z);
		water_active.insert(key);
		water_active.insert(pump.out_key);
	}
	// Evaporation amortizes across the ~50 s cadence: the queue refills
	// once empty, so every surface cell still sweeps once per cycle
	// without a single-step walk over every wet column. The per-visit
	// take is ten times the per-sweep rate — same total drain, a tenth
	// of the per-step cost.
	if (_water_evap_queue.empty()) {
		_water_evap_queue.reserve(water_tops.size());
		for (const auto &[ck, y] : water_tops) {
			_water_evap_queue.push_back(ck);
		}
	}
	{
		const size_t evap_batch = water_tops.size() / 250 + 1;
		for (size_t n = 0; n < evap_batch && !_water_evap_queue.empty();
				++n) {
			const uint64_t ck = _water_evap_queue.back();
			_water_evap_queue.pop_back();
			if (water_no_evap.count(ck)) {
				continue;
			}
			const auto tit = water_tops.find(ck);
			if (tit == water_tops.end()) {
				continue;
			}
			const int x = (int)(((int64_t)(ck >> 21 & 0x1fffff) << 43) >> 43);
			const int z = (int)(((int64_t)(ck & 0x1fffff) << 43) >> 43);
			const int y = tit->second;
			const Vector3i pos(x, y, z);
			const uint32_t v = water_at(pos);
			if (v == 0) {
				continue;
			}
			const uint32_t nv =
					v - std::min<uint32_t>(v, WATER_EVAP_CM3 * 10);
			water_put(pos, nv);
			if (nv < WATER_TOP_DROP) {
				// The top cell dried out or dropped to a skim — the
				// waterline steps to the next wet cell (or the column
				// goes dry). Only this case wakes flow (the pit can
				// take a lateral refill) or changes the render — a
				// partial decrement moves the skin by less than a
				// millimetre, invisible.
				water_refresh_top(ck, x, z);
				water_mark_dirty(x, z);
				water_active.insert(key_of(x, y, z));
				for (const Vector3i &d : std::initializer_list<Vector3i>{
						Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
						Vector3i(0, 0, 1), Vector3i(0, 0, -1)}) {
					const Vector3i np = pos + d;
					water_active.insert(key_of(np.x, np.y, np.z));
				}
			}
		}
	}
	// Precipitation amortizes like evaporation: when the queue runs
	// dry it refills from the loaded blocks' column-chunks (deduped,
	// then expanded to individual columns), and each step services a
	// ~1/250 slice — a full cycle takes ~250 steps (~50 s), matching
	// the old cadence without the single-step ~90k-column spike.
	if (water_rain_cm3 > 0 && gen.is_valid()) {
		if (_water_rain_queue.empty()) {
			std::unordered_set<uint64_t> seen;
			for (const uint64_t bk : loaded_blocks) {
				const Vector3i b = pos_of_key(bk);
				seen.insert(
						((uint64_t)(b.x & 0x1fffff) << 21)
						| (uint64_t)(b.z & 0x1fffff));
			}
			_water_rain_queue.reserve(seen.size() * CHUNK * CHUNK);
			for (const uint64_t ck : seen) {
				const int bx = (int)(((int64_t)((ck >> 21) & 0x1fffff) << 43) >> 43);
				const int bz = (int)(((int64_t)(ck & 0x1fffff) << 43) >> 43);
				for (int dz = 0; dz < CHUNK; ++dz) {
					for (int dx = 0; dx < CHUNK; ++dx) {
						_water_rain_queue.push_back(
								col_key_of(bx * CHUNK + dx,
										bz * CHUNK + dz));
					}
				}
			}
		}
		const size_t rain_batch = _water_rain_queue.size() / 250 + 1;
		for (size_t n = 0;
				n < rain_batch && !_water_rain_queue.empty(); ++n) {
			const uint64_t ck2 = _water_rain_queue.back();
			_water_rain_queue.pop_back();
			const int x =
					(int)(((int64_t)(ck2 >> 21 & 0x1fffff) << 43) >> 43);
			const int z =
					(int)(((int64_t)(ck2 & 0x1fffff) << 43) >> 43);
			if (!water_in_bounds(x, z)) {
				continue;
			}
			// Rain wets the column's surface — its water top when
			// wet, else the first air cell over the bed (rock or
			// soil roof shelters what's below).
			const auto tit = water_tops.find(ck2);
			int y;
			if (tit != water_tops.end()) {
				y = tit->second;
			} else {
				const int grass = gen->terrain_height(x, z);
				y = std::max(grass, gen->rock_top(x, z, grass)) + 1;
			}
			const Vector3i pos(x, y, z);
			if (water_solid_at(pos)) {
				continue;
			}
			const uint32_t v = water_at(pos);
			if (v >= WATER_FULL) {
				continue;
			}
			const uint32_t add = (uint32_t)std::min<int64_t>(
					water_rain_cm3 * 10, WATER_FULL - v);
			water_put(pos, v + add);
			water_raise_top(pos);
			water_mark_dirty(x, z);
			water_active.insert(key_of(x, y, z));
		}
	}
	if (water_active.empty()) {
		return;
	}
	// Flow pass over a bounded slice of the active set — cells past the
	// budget stay queued for the next step. Deltas accumulate first so
	// every decision reads the pre-step state; reservations against the
	// delta keep a cell from exporting past its volume or a target past
	// its room.
	std::vector<uint64_t> active;
	active.reserve(std::min(water_active.size(), WATER_STEP_BUDGET));
	for (auto it = water_active.begin();
			it != water_active.end() && active.size() < WATER_STEP_BUDGET;) {
		active.push_back(*it);
		it = water_active.erase(it);
	}
	std::unordered_map<uint64_t, int64_t> delta;
	delta.reserve(active.size() * 2);
	auto vol_of = [&](uint64_t k) -> int64_t {
		const Vector3i p = pos_of_key(k);
		const int64_t v = water_cell(p.x, p.y, p.z);
		const auto d = delta.find(k);
		return d == delta.end() ? v : v + d->second;
	};
	static const Vector3i LATERAL[4] = {
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	};
	for (const uint64_t key : active) {
		const Vector3i pos = pos_of_key(key);
		const int64_t v = vol_of(key);
		if (v <= 0) {
			continue;
		}
		int64_t out_left = v;
		// Gravity first: an open cell below takes whatever it can hold.
		const Vector3i below = pos + Vector3i(0, -1, 0);
		if (water_in_bounds(below.x, below.z) && !water_solid_at(below)) {
			const int64_t room = WATER_FULL - vol_of(key_of(below.x, below.y, below.z));
			const int64_t move = std::min(out_left, room);
			if (move > 0) {
				delta[key] -= move;
				delta[key_of(below.x, below.y, below.z)] += move;
				water_flux[key] +=
						Vector3i(0, -(int32_t)move, 0);
				out_left -= move;
			}
		}
		if (out_left <= 0) {
			continue;
		}
		// The pushing head is computed lazily: a saturated cell relays
		// its connected body's free surface (the pressure that rises
		// U-tubes and buried conduits), while a partial cell IS a free
		// surface and pushes with its own fill height. A settled lake's
		// skin is all partial cells, so the common case never scans a
		// body at all.
		double hc = 0.0;
		bool hc_set = false;
		for (int di = 0; di < 5; ++di) {
			const Vector3i dir =
					di < 4 ? LATERAL[di] : Vector3i(0, 1, 0);
			const Vector3i np = pos + dir;
			if (!water_in_bounds(np.x, np.z) || water_solid_at(np)) {
				continue;
			}
			const uint64_t nk = key_of(np.x, np.y, np.z);
			const int64_t room = WATER_FULL - vol_of(nk);
			if (room <= 0) {
				continue;
			}
			// Any neighbour with room is non-full, so it resists with
			// its own surface height — no body scan on that side either.
			const double hn =
					np.y + double(std::max<int64_t>(0, vol_of(nk))) / WATER_FULL;
			if (!hc_set) {
				if (v < WATER_FULL) {
					hc = pos.y + double(v) / WATER_FULL;
				} else {
					// A column open to the sky has its own free
					// surface — its top IS the pushing head, no body
					// scan needed. Only a roofed column (a conduit
					// sealed under rock, where the true head can sit
					// higher than the local waterline) needs the
					// connected-body walk.
					const uint64_t ck =
							col_key_of(pos.x, pos.z);
					const auto tit = water_tops.find(ck);
					const bool roofed =
							tit == water_tops.end() ||
							water_solid_at(Vector3i(
									pos.x, tit->second + 1, pos.z));
					if (!roofed && tit->second > pos.y) {
						hc = tit->second +
								double(water_cell(
										pos.x, tit->second, pos.z)) /
										WATER_FULL;
					} else if (!roofed) {
						hc = pos.y + double(v) / WATER_FULL;
					} else {
						hc = WATER_HEAD_UNKNOWN;
						if (_water_comp_cells <
								WATER_COMP_STEP_CAP) {
							hc = water_body_head(key);
						}
						if (hc <= WATER_HEAD_UNKNOWN) {
							// Body too big to see whole — degrade to
							// this column's own waterline.
							hc = (tit != water_tops.end() &&
										 tit->second > pos.y)
									? tit->second +
											double(water_cell(
													pos.x, tit->second,
													pos.z)) /
													WATER_FULL
									: pos.y + double(v) / WATER_FULL;
						}
					}
				}
				hc_set = true;
			}
			double drive = WATER_FLOW_K * (hc - hn) * WATER_FULL;
			if (!water_edge_scales.empty()) {
				// A regulated edge (a floodgate's sluice) throttles the
				// transfer continuously — scaling the drive, not the
				// outcome, so a half-open gate moves half the water
				// rather than flickering on/off.
				drive *= water_edge_scale(key, nk);
			}
			const int64_t want = (int64_t)drive;
			if (want < WATER_FLOW_MIN) {
				continue;
			}
			int64_t move = std::min(std::min(want, out_left), room);
			if (di == 4) {
				// Rising past the surface vents only this cell's net
				// surplus — inflow landed this step, not the cell's own
				// substance. Exporting below saturation lets the
				// pushed cell pour straight back (a flickering open-
				// air geyser); keeping the pusher full gives the new
				// cell real footing and the rise actually stays.
				move = std::min(move,
						std::max<int64_t>(0, vol_of(key) - WATER_FULL));
			}
			if (move <= 0) {
				continue;
			}
			delta[key] -= move;
			delta[nk] += move;
			water_flux[key] += Vector3i(
					dir.x * (int32_t)move, dir.y * (int32_t)move,
					dir.z * (int32_t)move);
			out_left -= move;
			if (out_left <= 0) {
				break;
			}
		}
	}
	// Apply: volumes move, tops track, changed columns flag the view,
	// and every touched cell plus its neighbours reactivates for the
	// next step.
	static const Vector3i ALL_DIRS[6] = {
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	};
	for (const auto &[key, d] : delta) {
		if (d == 0) {
			continue;
		}
		const Vector3i pos = pos_of_key(key);
		const int64_t nv = water_cell(pos.x, pos.y, pos.z) + d;
		water_put(pos, (uint32_t)std::max<int64_t>(0, nv));
		const uint64_t ck = col_key_of(pos.x, pos.z);
		const auto tit = water_tops.find(ck);
		const int top_before =
				tit == water_tops.end() ? WATER_DRY : tit->second;
		if (nv < WATER_TOP_DROP) {
			// Empty or skim-thin: not a surface — the top walks down.
			if (tit != water_tops.end() && tit->second == pos.y) {
				water_refresh_top(ck, pos.x, pos.z, &delta);
			}
		} else {
			water_raise_top(pos, &delta);
		}
		const auto tit2 = water_tops.find(ck);
		const int top_after =
				tit2 == water_tops.end() ? WATER_DRY : tit2->second;
		// The render and vegetation only see the waterline — a buried
		// change or a skim cell that never became the top can't show,
		// and a surface-cell change only shows once it crosses a skin
		// band. Everything else stays queued out of the rebuilds.
		const int64_t ov = nv - d;
		if (top_after != top_before ||
				(tit2 != water_tops.end() &&
						pos.y == tit2->second &&
						nv / WATER_SKIN_BUCKET !=
								ov / WATER_SKIN_BUCKET)) {
			water_mark_dirty(pos.x, pos.z);
		}
		water_active.insert(key);
		// Neighbour wakes are the frontier's breadth; when the backlog
		// is already saturated the changed cell alone keeps it moving.
		if (water_active.size() < WATER_WAKE_CAP) {
			for (const Vector3i &dd : ALL_DIRS) {
				const Vector3i np = pos + dd;
				water_active.insert(key_of(np.x, np.y, np.z));
			}
		}
	}
}

void DelveSim::water_add(const Vector3i &pos, int64_t cm3) {
	if (cm3 <= 0 || water_solid_at(pos)) {
		return;
	}
	water_seeded = true;
	const int64_t v = water_at(pos);
	const int64_t nv = std::min<int64_t>(WATER_FULL, v + cm3);
	water_put(pos, (uint32_t)nv);
	water_raise_top(pos);
	water_mark_dirty(pos.x, pos.z);
	water_active.insert(key_of(pos.x, pos.y, pos.z));
	for (const Vector3i &d : std::initializer_list<Vector3i>{
				Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1)}) {
		const Vector3i np = pos + d;
		water_active.insert(key_of(np.x, np.y, np.z));
	}
}

void DelveSim::water_set_source(const Vector3i &pos, int64_t rate_cm3) {
	const uint64_t key = key_of(pos.x, pos.y, pos.z);
	if (rate_cm3 <= 0) {
		water_sources.erase(key);
	} else {
		water_sources[key] = (int32_t)rate_cm3;
	}
	water_active.insert(key);
}

void DelveSim::water_set_rain(int64_t cm3_per_sweep) {
	water_rain_cm3 = (int32_t)std::max<int64_t>(0, cm3_per_sweep);
}

void DelveSim::water_set_paused(bool p) {
	water_paused = p;
}

void DelveSim::water_set_drain(const Vector3i &pos, int64_t rate_cm3) {
	const uint64_t key = key_of(pos.x, pos.y, pos.z);
	if (rate_cm3 <= 0) {
		water_drains.erase(key);
	} else {
		water_drains[key] = (int32_t)rate_cm3;
	}
	water_active.insert(key);
}

float DelveSim::water_edge_scale(uint64_t a, uint64_t b) const {
	const auto e = std::minmax(a, b);
	const auto it = water_edge_scales.find({e.first, e.second});
	return it == water_edge_scales.end() ? 1.0f : it->second;
}

void DelveSim::water_set_edge_scale(
		const Vector3i &pos, const Vector3i &dir, double factor) {
	// Unit-axis neighbours only — a diagonal or zero dir names no edge.
	if (dir.length_squared() != 1) {
		return;
	}
	const uint64_t a = key_of(pos.x, pos.y, pos.z);
	const Vector3i np = pos + dir;
	const uint64_t b = key_of(np.x, np.y, np.z);
	const auto e = std::minmax(a, b);
	const double f = std::clamp(factor, 0.0, 1.0);
	if (f >= 1.0) {
		// Full flow is the absent-entry default.
		water_edge_scales.erase({e.first, e.second});
	} else {
		water_edge_scales[{e.first, e.second}] = (float)f;
	}
	// Wake both cells: a freshly opened gate has pent-up head to
	// equalize right away, and a closing one needs the next step to
	// see the new coefficient rather than waiting on a neighbour's
	// wake.
	water_active.insert(a);
	water_active.insert(b);
}

double DelveSim::water_edge_scale_at(
		const Vector3i &pos, const Vector3i &dir) const {
	if (dir.length_squared() != 1) {
		return 1.0;
	}
	const uint64_t a = key_of(pos.x, pos.y, pos.z);
	const Vector3i np = pos + dir;
	const uint64_t b = key_of(np.x, np.y, np.z);
	return water_edge_scale(a, b);
}

void DelveSim::water_set_pump(
		const Vector3i &intake, const Vector3i &outflow, int64_t rate_cm3) {
	const uint64_t key = key_of(intake.x, intake.y, intake.z);
	if (rate_cm3 <= 0) {
		water_pumps.erase(key);
		return;
	}
	water_pumps[key] = {
		key_of(outflow.x, outflow.y, outflow.z), (int32_t)rate_cm3};
	water_active.insert(key);
}

Vector3i DelveSim::water_flux_at(const Vector3i &pos) const {
	const auto it = water_flux.find(key_of(pos.x, pos.y, pos.z));
	return it == water_flux.end() ? Vector3i() : it->second;
}

int64_t DelveSim::water_level_at(int64_t x, int64_t z) {
	if (water_seeded) {
		const auto it = water_tops.find(col_key_of((int)x, (int)z));
		return it == water_tops.end() ? WATER_DRY : it->second;
	}
	// Pre-seed the live map is empty — answer from the installed
	// datum so early standability checks still see generated water.
	if (gen.is_valid()) {
		return gen->water_level_at((int)x, (int)z);
	}
	return WATER_DRY;
}

double DelveSim::water_surface_at(int64_t x, int64_t z) {
	if (!water_seeded) {
		if (gen.is_valid()) {
			const int64_t level = gen->water_level_at((int)x, (int)z);
			return level == WATER_DRY ? double(WATER_DRY) : level + 0.97;
		}
		return double(WATER_DRY);
	}
	const auto it = water_tops.find(col_key_of((int)x, (int)z));
	if (it == water_tops.end()) {
		return double(WATER_DRY);
	}
	const int32_t v = water_cell((int)x, it->second, (int)z);
	return it->second + v / double(WATER_FULL);
}

int64_t DelveSim::water_depth_at(int64_t x, int64_t z) {
	const int64_t level = water_level_at(x, z);
	if (level == WATER_DRY || gen.is_null()) {
		return 0;
	}
	return std::max<int64_t>(0, level - gen->terrain_height((int)x, (int)z));
}

int64_t DelveSim::water_volume_at(const Vector3i &pos) const {
	return water_at(pos);
}

PackedVector3Array DelveSim::water_drain_dirty() {
	PackedVector3Array out;
	out.resize(water_dirty_cols.size());
	int i = 0;
	for (const uint64_t ck : water_dirty_cols) {
		const int x = (int)(((int64_t)((ck >> 21) & 0x1fffff) << 43) >> 43);
		const int z = (int)(((int64_t)(ck & 0x1fffff) << 43) >> 43);
		out[i++] = Vector3(x, 0, z);
	}
	water_dirty_cols.clear();
	return out;
}

PackedVector3Array DelveSim::water_flow_field() {
	PackedVector3Array out;
	for (const auto &[key, f] : water_flux) {
		const Vector3i pos = pos_of_key(key);
		const auto tit = water_tops.find(col_key_of(pos.x, pos.z));
		// The overlay draws on the skin — a submerged cell's flux is
		// invisible under it, so only column tops export.
		if (tit == water_tops.end() || tit->second != pos.y) {
			continue;
		}
		out.push_back(Vector3(pos));
		out.push_back(Vector3(f));
	}
	return out;
}

// ---- Site tick ----------------------------------------------------------

void DelveSim::pile_fall_start(
		int64_t pile_id, double from_y, double target_y, double speed) {
	dlog(vformat("pile_fall_start %d %.2f->%.2f v=%.1f",
			pile_id, from_y, target_y, speed));
	const auto existing = pile_falls.find(pile_id);
	if (existing != pile_falls.end()) {
		// Retarget mid-flight: the sim's position/speed are authoritative,
		// not the presentation node's.
		existing->second.target_y = float(target_y);
		return;
	}
	PileFall &f = pile_falls[pile_id];
	f.cur_y = float(from_y);
	f.target_y = float(target_y);
	f.speed = float(speed);
}

void DelveSim::pile_fall_cancel(int64_t pile_id) {
	dlog(vformat("pile_fall_cancel %d", pile_id));
	pile_falls.erase(pile_id);
}

PackedInt64Array DelveSim::tick(double delta) {
	PackedInt64Array landed;
	const float dt = float(delta);
	if (water_seeded) {
		_water_accum += delta;
		const int64_t deadline = Time::get_singleton()->get_ticks_usec() +
				WATER_TICK_BUDGET_US;
		int steps = 0;
		while (_water_accum >= WATER_TICK_SEC &&
				steps < WATER_MAX_STEPS_PER_TICK &&
				Time::get_singleton()->get_ticks_usec() < deadline) {
			_water_accum -= WATER_TICK_SEC;
			water_step();
			++steps;
		}
		// Debt the per-tick budget couldn't service is dropped — at
		// high game speeds the water trails a few steps behind rather
		// than compounding a stall.
		if (_water_accum > WATER_TICK_SEC * WATER_MAX_STEPS_PER_TICK) {
			_water_accum = WATER_TICK_SEC * WATER_MAX_STEPS_PER_TICK;
		}
	}
	for (auto it = pile_falls.begin(); it != pile_falls.end();) {
		PileFall &f = it->second;
		// ItemPile._process's integrator: accelerate first, then descend.
		f.speed = std::min(f.speed + PILE_FALL_GRAVITY * dt, PILE_FALL_SPEED_MAX);
		f.cur_y -= f.speed * dt;
		if (f.cur_y <= f.target_y) {
			landed.push_back(it->first);
			it = pile_falls.erase(it);
		} else {
			++it;
		}
	}
	if (!landed.is_empty()) {
		dlog(vformat("tick landed %d", (int64_t)landed.size()));
	}
	return landed;
}

// ---- Unit bodies --------------------------------------------------------

void DelveSim::unit_register(int64_t id, const Vector3 &pos) {
	dlog(vformat("unit_register %d at (%.1f,%.1f,%.1f)", id, pos.x, pos.y, pos.z));
	UnitBody &b = unit_bodies[id];
	b.pos = pos;
	b.vel_y = 0.0f;
}

void DelveSim::unit_unregister(int64_t id) {
	dlog(vformat("unit_unregister %d", id));
	unit_bodies.erase(id);
}

Vector3 DelveSim::unit_pos(int64_t id) const {
	const auto it = unit_bodies.find(id);
	return it == unit_bodies.end() ? Vector3() : it->second.pos;
}

// Top walkable surface of a cell: a solid block tops at its upper face,
// a loose mound lifts to its fill fraction — clutter never does, a heap
// of discrete goods is something to push through, not stand on. -INF
// for empty cells. A ladder serves two surfaces: as the floor of the
// cell above it offers its top (standing on the ladder), and as the
// feet's own cell it offers its base (standing inside it). A pile in
// the same cell still contributes its own surface.
float DelveSim::cell_surface(int x, int y, int z, bool as_floor) {
	const Vector3i cell(x, y, z);
	if (is_solid(cell)) {
		return float(y) + 1.0f;
	}
	const int64_t loose = pile_loose_at(cell);
	const float pile_s =
			loose > 0 ? float(y) + float(loose) / float(BLOCK_CM3) : -1e30f;
	if (ladder_at(cell)) {
		const float lad = as_floor ? float(y) + 1.0f : float(y);
		return std::max(lad, pile_s);
	}
	return pile_s;
}

// The ground surface holding a unit at `pos`: the highest walkable
// surface among the columns the capsule's foot disk overlaps, at or a
// step above the feet — plus any surface engulfing a foot sample (a pile
// filling around a unit lifts it, the way collision resolution would).
float DelveSim::support_height(const Vector3 &pos) const {
	const float feet_y = pos.y - UNIT_HALF_HEIGHT;
	const int feet_cell = int(std::floor(feet_y));
	static const float OFF[5][2] = {
		{0.0f, 0.0f}, {0.3f, 0.0f}, {-0.3f, 0.0f}, {0.0f, 0.3f}, {0.0f, -0.3f},
	};
	float support = -1e30f;
	for (const auto &off : OFF) {
		const int cx = int(std::floor(pos.x + off[0]));
		const int cz = int(std::floor(pos.z + off[1]));
		// The engulf rule (a surface above the feet still supports, pushing
		// the unit up like collision would) applies only to the centre
		// column — an edge sample inside a neighbouring wall would pop the
		// unit on top of the wall otherwise.
		const bool centre = off[0] == 0.0f && off[1] == 0.0f;
		for (int dy = 0; dy >= -1; --dy) {
			// const_cast: the cell lookups only read the mirror. The cell
			// below the feet answers as a floor; the feet's own cell
			// answers for what a unit inside it stands on.
			const float s = const_cast<DelveSim *>(this)->cell_surface(
					cx, feet_cell + dy, cz, dy == -1);
			if (s <= -1e29f) {
				continue;
			}
			if (s <= feet_y + UNIT_STEP_HEIGHT || (centre && s > feet_y)) {
				support = std::max(support, s);
			}
		}
	}
	return support;
}

// Can the capsule bottom occupy `pos`? Every foot-sample column must be
// clear of blocked cells at feet and head height, and no support surface
// may sit more than a step above the feet (a tall pile walls like rock).
bool DelveSim::horizontal_clear(const Vector3 &pos) const {
	const float feet_y = pos.y - UNIT_HALF_HEIGHT;
	static const float OFF[5][2] = {
		{0.0f, 0.0f}, {0.3f, 0.0f}, {-0.3f, 0.0f}, {0.0f, 0.3f}, {0.0f, -0.3f},
	};
	DelveSim *self = const_cast<DelveSim *>(this);
	for (const auto &off : OFF) {
		const int cx = int(std::floor(pos.x + off[0]));
		const int cz = int(std::floor(pos.z + off[1]));
		const int fcell = int(std::floor(feet_y + 0.05f));
		for (int dy = 0; dy <= 1; ++dy) {
			if (self->is_blocked(Vector3i(cx, fcell + dy, cz))) {
				return false;
			}
		}
		const float feet_s = self->cell_surface(cx, fcell, cz, false);
		if (feet_s > -1e29f && feet_s - feet_y > UNIT_STEP_HEIGHT) {
			return false;
		}
	}
	return true;
}

Dictionary DelveSim::unit_step(
		int64_t id, const Vector3 &heading,
		double jump_speed, double gravity, double delta, double descend_speed) {
	UnitBody &b = unit_bodies[id];

	// Integrate in bounded substeps: plain Euler shrinks the jump apex by
	// ~v·dt/2, so at 6x time_scale a 1 m ledge the capsule clears at 1x
	// becomes unreachable — the unit jumps, misses, falls back, and the
	// watchdog cancels the job. Substepping at <=1/60 s makes physics
	// identical at any game speed.
	const double MAX_SUBSTEP = 1.0 / 60.0;
	const int substeps = std::max(1, int(std::ceil(delta / MAX_SUBSTEP)));
	const float dt = float(delta / substeps);

	bool blocked = false;
	int64_t hit_unit = -1;
	bool grounded = false;
	for (int sub = 0; sub < substeps; ++sub) {
		// --- horizontal: try the full move, then axis-separated slides ---
		Vector3 cand = b.pos + heading * dt;
		if (heading.length_squared() > 0.0f) {
			if (horizontal_clear(cand)) {
				b.pos.x = cand.x;
				b.pos.z = cand.z;
			} else {
				// The intended move hit something — the axis retries are the
				// slide approximation, but the contact counts (jump triggers
				// on it the way is_on_wall did).
				blocked = true;
				Vector3 cx = b.pos;
				cx.x = cand.x;
				Vector3 cz = b.pos;
				cz.z = cand.z;
				if (horizontal_clear(cx)) {
					b.pos.x = cand.x;
				} else if (horizontal_clear(cz)) {
					b.pos.z = cand.z;
				}
			}
		}

		// --- unit contact: the mover slides around other units, which are ---
		// --- not displaced (idle units step aside via yield_to instead).  ---
		const float hlen = Vector2(heading.x, heading.z).length();
		Vector3 hdir;
		if (hlen > 0.01f) {
			hdir = Vector3(heading.x / hlen, 0.0f, heading.z / hlen);
		}
		for (auto &entry : unit_bodies) {
			if (entry.first == id) {
				continue;
			}
			UnitBody &other = entry.second;
			const Vector3 delta3 = other.pos - b.pos;
			if (std::abs(delta3.y) > 1.8f) {
				continue;
			}
			const Vector2 d2(delta3.x, delta3.z);
			const float dist = d2.length();
			if (dist >= UNIT_SEPARATION) {
				continue;
			}
			const Vector2 dir = dist > 1e-4f ? d2 / dist : Vector2(1.0f, 0.0f);
			b.pos.x -= dir.x * (UNIT_SEPARATION - dist);
			b.pos.z -= dir.y * (UNIT_SEPARATION - dist);
			if (hit_unit == -1 && hlen > 0.01f && Vector2(hdir.x, hdir.z).dot(dir) > 0.3f) {
				hit_unit = entry.first;
			}
		}

		// --- vertical: support, jump, gravity, landing ---
		const float support = support_height(b.pos);
		float feet = b.pos.y - UNIT_HALF_HEIGHT;
		grounded = support > -1e29f && feet <= support + GROUND_EPS;
		if (grounded) {
			feet = support;
			b.vel_y = 0.0f;
			// The jump request is an impulse — it applies on the first
			// substep only, like a single key press.
			if (sub == 0 && jump_speed > 0.0) {
				b.vel_y = float(jump_speed);
				grounded = false;
			} else if (descend_speed > 0.0) {
				// Climbing down a ladder: while the cell below the feet is a
				// ladder the unit sinks at the climb rate — no freefall, and
				// each rung's base catches the feet before the next sink.
				const Vector3i fcell(
						int(std::floor(b.pos.x)), int(std::floor(feet + 1e-4f)),
						int(std::floor(b.pos.z)));
				if (ladder_at(fcell + Vector3i(0, -1, 0)) || ladder_at(fcell)) {
					feet -= float(descend_speed) * dt;
					const float under = support_height(
							Vector3(b.pos.x, feet + UNIT_HALF_HEIGHT, b.pos.z));
					if (under > -1e29f && feet < under) {
						feet = under;
					}
					b.pos.y = feet + UNIT_HALF_HEIGHT;
				}
			}
		}
		if (!grounded) {
			b.vel_y -= float(gravity) * dt;
			feet += b.vel_y * dt;
			if (b.vel_y > 0.0f &&
					is_blocked(Vector3i(
							int(std::floor(b.pos.x)),
							int(std::floor(feet + UNIT_HALF_HEIGHT * 2.0f)),
							int(std::floor(b.pos.z))))) {
				b.vel_y = 0.0f; // head bump on a solid ceiling
			}
			const float under = support_height(Vector3(b.pos.x, feet + UNIT_HALF_HEIGHT, b.pos.z));
			if (under > -1e29f && feet < under) {
				feet = under;
				b.vel_y = 0.0f;
				grounded = true;
			}
		}
		b.pos.y = feet + UNIT_HALF_HEIGHT;
	}

	Dictionary out;
	out["pos"] = b.pos;
	out["vel_y"] = b.vel_y;
	out["grounded"] = grounded;
	out["blocked"] = blocked;
	out["hit_unit"] = hit_unit;
	return out;
}

// ---- Item/spill search -------------------------------------------------

static const Vector3i SPILL_SIDES[4] = {
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
};

// Colony._is_floor_for: packed is always a floor; empty or a pile a
// splittable item can pour into is not; an unsplittable item rests on a
// pile it would overfill. Dense cells still take items — clutter may
// refuse a unit but it isn't full until the total says so.
bool DelveSim::is_floor_for(const Vector3i &pos, int64_t volume, bool splittable) {
	if (is_solid(pos) || is_packed(pos)) {
		return true;
	}
	const int64_t fill = pile_fill_at(pos);
	if (fill <= 0) {
		return false;
	}
	if (splittable) {
		return false;
	}
	return fill + volume > capacity_at(pos);
}

Vector3i DelveSim::spill_target(const Vector3i &pos) {
	const Vector3i below = pos + Vector3i(0, -1, 0);
	if (!is_solid(below) && !is_packed(below)) {
		return below;
	}
	// Position-hashed rotation in place of GDScript's shuffle — same
	// "first open side" acceptance, order varies per cell.
	const int start = (int)(((pos.x * 31 + pos.z * 17 + pos.y * 13) & 3) + 4) & 3;
	for (int i = 0; i < 4; ++i) {
		const Vector3i neighbor = pos + SPILL_SIDES[(start + i) & 3];
		if (!is_solid(neighbor) && !is_packed(neighbor)) {
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
		if (is_solid(candidate) || is_packed(candidate)) {
			continue;
		}
		const Vector3i landing = settle_floor(candidate, item_volume, loose);
		if (landing == pos) {
			continue;
		}
		const int64_t room = capacity_at(landing) - fill_of(landing);
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
		if (is_solid(candidate) || is_packed(candidate)) {
			continue;
		}
		const Vector3i landing = settle_floor(candidate, item_volume, loose);
		if (landing != pos) {
			const int64_t room = capacity_at(landing) - fill_of(landing);
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
	ClassDB::bind_method(D_METHOD("probe_block", "pos"), &DelveSim::probe_block);
	ClassDB::bind_method(D_METHOD("debug_sizes"), &DelveSim::debug_sizes);
	ClassDB::bind_method(D_METHOD("set_block", "pos", "block_id"), &DelveSim::set_block);
	ClassDB::bind_method(D_METHOD("is_solid", "pos"), &DelveSim::is_solid);
	ClassDB::bind_method(
			D_METHOD("collapse_check", "removed"), &DelveSim::collapse_check);
	ClassDB::bind_method(D_METHOD("is_standable", "pos"), &DelveSim::is_standable);
	ClassDB::bind_method(
			D_METHOD("set_ladder", "pos", "on"), &DelveSim::set_ladder);
	ClassDB::bind_method(D_METHOD("ladder_at", "pos"), &DelveSim::ladder_at);
	ClassDB::bind_method(
			D_METHOD("set_door", "pos", "on"), &DelveSim::set_door);
	ClassDB::bind_method(D_METHOD("door_at", "pos"), &DelveSim::door_at);
	ClassDB::bind_method(
			D_METHOD("capacity_at", "pos"), &DelveSim::capacity_at);
	ClassDB::bind_method(
			D_METHOD("set_pile_fill", "pos", "loose_cm3", "clutter_cm3"),
			&DelveSim::set_pile_fill);
	ClassDB::bind_method(D_METHOD("pile_loose_at", "pos"), &DelveSim::pile_loose_at);
	ClassDB::bind_method(D_METHOD("pile_clutter_at", "pos"), &DelveSim::pile_clutter_at);
	ClassDB::bind_method(D_METHOD("pile_fill_at", "pos"), &DelveSim::pile_fill_at);
	ClassDB::bind_method(D_METHOD("is_dense", "pos"), &DelveSim::is_dense);
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
			D_METHOD("find_path", "from", "to", "avoid_packed", "margin"),
			&DelveSim::find_path, DEFVAL(false), DEFVAL(24));
	ClassDB::bind_method(D_METHOD("spill_target", "pos"), &DelveSim::spill_target);
	ClassDB::bind_method(
			D_METHOD("settle_floor", "pos", "volume", "splittable"),
			&DelveSim::settle_floor);
	ClassDB::bind_method(
			D_METHOD("accepting_voxel", "pos", "item_volume", "loose", "needed"),
			&DelveSim::accepting_voxel);
	ClassDB::bind_method(
			D_METHOD("job_add", "id", "voxel", "job_type", "posted_ms"),
			&DelveSim::job_add);
	ClassDB::bind_method(D_METHOD("job_remove", "id"), &DelveSim::job_remove);
	ClassDB::bind_method(
			D_METHOD("job_suspend", "id", "on"), &DelveSim::job_suspend);
	ClassDB::bind_method(
			D_METHOD("job_set_posted", "id", "posted_ms"),
			&DelveSim::job_set_posted);
	ClassDB::bind_method(
			D_METHOD("job_drop", "id", "unit_id", "now_ms"), &DelveSim::job_drop);
	ClassDB::bind_method(
			D_METHOD(
					"job_claim", "unit_id", "pos", "now_ms", "retry_base_ms",
					"retry_max_ms", "type_scores", "dist_weight",
					"languish_rate", "languish_cap_s"),
			&DelveSim::job_claim);
	ClassDB::bind_method(
			D_METHOD("pile_fall_start", "pile_id", "from_y", "target_y", "speed"),
			&DelveSim::pile_fall_start);
	ClassDB::bind_method(
			D_METHOD("pile_fall_cancel", "pile_id"), &DelveSim::pile_fall_cancel);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &DelveSim::tick);
	ClassDB::bind_method(
			D_METHOD("water_seed_flood", "flood", "origin", "vs", "cell_flags", "cell_m"),
			&DelveSim::water_seed_flood,
			DEFVAL(PackedByteArray()), DEFVAL(4));
	ClassDB::bind_method(
			D_METHOD("water_add", "pos", "cm3"), &DelveSim::water_add);
	ClassDB::bind_method(
			D_METHOD("water_set_source", "pos", "rate_cm3"),
			&DelveSim::water_set_source);
	ClassDB::bind_method(
			D_METHOD("water_set_drain", "pos", "rate_cm3"),
			&DelveSim::water_set_drain);
	ClassDB::bind_method(
			D_METHOD("water_set_edge_scale", "pos", "dir", "factor"),
			&DelveSim::water_set_edge_scale);
	ClassDB::bind_method(
			D_METHOD("water_set_pump", "intake", "outflow", "rate_cm3"),
			&DelveSim::water_set_pump);
	ClassDB::bind_method(
			D_METHOD("water_flux_at", "pos"), &DelveSim::water_flux_at);
	ClassDB::bind_method(
			D_METHOD("water_edge_scale_at", "pos", "dir"),
			&DelveSim::water_edge_scale_at);
	ClassDB::bind_method(
			D_METHOD("water_set_rain", "cm3_per_sweep"),
			&DelveSim::water_set_rain);
	ClassDB::bind_method(
			D_METHOD("water_set_paused", "paused"),
			&DelveSim::water_set_paused);
	ClassDB::bind_method(
			D_METHOD("water_level_at", "x", "z"), &DelveSim::water_level_at);
	ClassDB::bind_method(
			D_METHOD("water_surface_at", "x", "z"),
			&DelveSim::water_surface_at);
	ClassDB::bind_method(
			D_METHOD("water_depth_at", "x", "z"), &DelveSim::water_depth_at);
	ClassDB::bind_method(
			D_METHOD("water_volume_at", "pos"), &DelveSim::water_volume_at);
	ClassDB::bind_method(
			D_METHOD("water_drain_dirty"), &DelveSim::water_drain_dirty);
	ClassDB::bind_method(
			D_METHOD("water_flow_field"), &DelveSim::water_flow_field);
	ClassDB::bind_method(
			D_METHOD("water_serialize"), &DelveSim::water_serialize);
	ClassDB::bind_method(
			D_METHOD("water_deserialize", "data"),
			&DelveSim::water_deserialize);
	ClassDB::bind_method(
			D_METHOD("unit_register", "id", "pos"), &DelveSim::unit_register);
	ClassDB::bind_method(
			D_METHOD("unit_unregister", "id"), &DelveSim::unit_unregister);
	ClassDB::bind_method(D_METHOD("unit_pos", "id"), &DelveSim::unit_pos);
	ClassDB::bind_method(
			D_METHOD("unit_step", "id", "heading", "jump_speed", "gravity", "delta", "descend_speed"),
			&DelveSim::unit_step, DEFVAL(0.0));
	ClassDB::bind_method(D_METHOD("debug_stats"), &DelveSim::debug_stats);
}

} // namespace delve
