#include "delve_generator.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <atomic>
#include <vector>

using namespace godot;

namespace delve {

static std::atomic<int64_t> g_gen_calls{0};

DelveGenerator::DelveGenerator() {
	height_noise.instantiate();
	cave_noise.instantiate();
	clay_noise.instantiate();
	rock_noise.instantiate();
	configure_noise();
}

void DelveGenerator::configure_noise() {
	// Mirrors WorldGenerator._configure_noise — same seeds, types and
	// frequencies so the parity test compares like for like.
	height_noise->set_seed(world_seed);
	height_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
	height_noise->set_frequency(0.006);
	height_noise->set_fractal_octaves(4);

	cave_noise->set_seed(world_seed + 1);
	cave_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
	cave_noise->set_frequency(0.035);

	clay_noise->set_seed(world_seed + 2);
	clay_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
	clay_noise->set_frequency(0.07);

	rock_noise->set_seed(world_seed + 3);
	rock_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
	rock_noise->set_frequency(0.02);
}

void DelveGenerator::set_world_seed(int seed) {
	world_seed = seed;
	configure_noise();
}
int DelveGenerator::get_world_seed() const {
	return world_seed;
}
void DelveGenerator::set_base_height(int height) {
	base_height = height;
}
int DelveGenerator::get_base_height() const {
	return base_height;
}
void DelveGenerator::set_terrain_amplitude(double amplitude) {
	terrain_amplitude = amplitude;
}
double DelveGenerator::get_terrain_amplitude() const {
	return terrain_amplitude;
}
void DelveGenerator::set_soil_depth(int depth) {
	soil_depth = depth;
}
int DelveGenerator::get_soil_depth() const {
	return soil_depth;
}
void DelveGenerator::set_bedrock_height(int height) {
	bedrock_height = height;
}
int DelveGenerator::get_bedrock_height() const {
	return bedrock_height;
}
void DelveGenerator::set_outcrop_threshold(double threshold) {
	outcrop_threshold = threshold;
}
double DelveGenerator::get_outcrop_threshold() const {
	return outcrop_threshold;
}
void DelveGenerator::set_outcrop_protrusion(double protrusion) {
	outcrop_protrusion = protrusion;
}
double DelveGenerator::get_outcrop_protrusion() const {
	return outcrop_protrusion;
}
void DelveGenerator::set_regional_origin(Vector2i origin) {
	regional_origin = origin;
}
Vector2i DelveGenerator::get_regional_origin() const {
	return regional_origin;
}
void DelveGenerator::set_regional_step(int step) {
	regional_step = step > 0 ? step : 1;
}
int DelveGenerator::get_regional_step() const {
	return regional_step;
}
void DelveGenerator::set_regional_size(int size) {
	regional_size = size;
}
int DelveGenerator::get_regional_size() const {
	return regional_size;
}
void DelveGenerator::set_regional_grid(PackedInt32Array grid) {
	regional_grid = grid;
}
PackedInt32Array DelveGenerator::get_regional_grid() const {
	return regional_grid;
}

// Mirrors WorldGenerator._regional_base — identical integer math,
// clamp included, so generated terrain is voxel-identical.
int DelveGenerator::regional_base(int x, int z) const {
	if (regional_grid.is_empty() || regional_size < 2) {
		return base_height;
	}
	const int64_t span = (int64_t)(regional_size - 1) * regional_step;
	const int64_t cx = CLAMP((int64_t)x - regional_origin.x, 0, span);
	const int64_t cz = CLAMP((int64_t)z - regional_origin.y, 0, span);
	// gx stops at size-2 so the +1/+size reads stay in bounds; fx can
	// reach step exactly at the far edge, which evaluates to the border
	// node's exact value.
	const int64_t gx = MIN(cx / regional_step, (int64_t)regional_size - 2);
	const int64_t gz = MIN(cz / regional_step, (int64_t)regional_size - 2);
	const int64_t fx = cx - gx * regional_step;
	const int64_t fz = cz - gz * regional_step;
	const int64_t i00 = gz * regional_size + gx;
	const int64_t top = regional_grid[i00] * (regional_step - fx)
			+ regional_grid[i00 + 1] * fx;
	const int64_t bot = regional_grid[i00 + regional_size] * (regional_step - fx)
			+ regional_grid[i00 + regional_size + 1] * fx;
	return (int)((top * (regional_step - fz) + bot * fz)
			/ ((int64_t)regional_step * regional_step));
}

int DelveGenerator::terrain_height(int x, int z) const {
	return regional_base(x, z) + (int)(height_noise->get_noise_2d((double)x, (double)z) * terrain_amplitude);
}

int DelveGenerator::rock_top(int x, int z, int grass) const {
	const int normal = grass - soil_depth;
	const double n = rock_noise->get_noise_2d((double)x, (double)z);
	if (n <= outcrop_threshold) {
		return normal;
	}
	const double t = (n - outcrop_threshold) / (1.0 - outcrop_threshold);
	return normal + (int)Math::round(t * (soil_depth + outcrop_protrusion));
}

bool DelveGenerator::is_cave(int x, int y, int z) const {
	return Math::abs(cave_noise->get_noise_3d((double)x, (double)y * 2.0, (double)z)) < 0.05;
}

bool DelveGenerator::clay_at(int x, int z) const {
	return clay_noise->get_noise_2d((double)x, (double)z) > clay_threshold;
}

uint32_t DelveGenerator::imix(int64_t x, int64_t y, int64_t z, int64_t salt) const {
	// Identical arithmetic to WorldGenerator._imix — mask to 32 bits
	// after every step (GDScript ints are 64-bit signed, so the ANDs
	// are explicit there; uint32_t wraps for free here).
	uint32_t h = (uint32_t)(
			x * 2654435761ll + y * 2246822519ll + z * 3266489917ll
			+ salt * 668265263ll + (int64_t)world_seed * 374761393ll);
	h = (h ^ (h >> 13)) * 3266489917u;
	h = h ^ (h >> 16);
	return h;
}

// Would this voxel generate as plain country rock — the only matrix an
// intrusion may occupy? Mirrors WorldGenerator._base_is_stone.
bool DelveGenerator::base_is_stone(int x, int y, int z) const {
	if (y <= bedrock_height) {
		return true;
	}
	const int grass = terrain_height(x, z);
	const int rt = rock_top(x, z, grass);
	const int top = MAX(grass, rt);
	if (y > top || y > rt) {
		return false;
	}
	if (top - y > 2 && is_cave(x, y, z)) {
		return false;
	}
	return true;
}

static const Vector3i INTRUSION_SIDES[6] = {
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
};

// Whether v belongs to the blob grown from centre — the block id when
// it does, BLOCK_AIR otherwise. Face-connected flood picking the
// lowest-hash frontier voxel each step, counting only rock members —
// same algorithm as WorldGenerator._intrusion_member.
int DelveGenerator::intrusion_member(
		const Vector3i &center, int size, int block,
		const Vector3i &v, int64_t salt) const {
	if (!base_is_stone(center.x, center.y, center.z)) {
		return BLOCK_AIR;
	}
	if (v == center) {
		return block;
	}
	int members = 1;
	// Exact membership matters (the GDScript twin uses a Dictionary) —
	// a small linear set keeps the port collision-free.
	std::vector<Vector3i> visited{center};
	std::vector<Vector3i> frontier;
	auto seed_frontier = [&](const Vector3i &p) {
		for (const Vector3i &s : INTRUSION_SIDES) {
			const Vector3i n = p + s;
			if (std::find(visited.begin(), visited.end(), n) == visited.end()) {
				visited.push_back(n);
				frontier.push_back(n);
			}
		}
	};
	seed_frontier(center);
	while (members < size && !frontier.empty()) {
		size_t best = 0;
		uint32_t best_h = imix(frontier[0].x, frontier[0].y, frontier[0].z, salt);
		for (size_t i = 1; i < frontier.size(); i++) {
			const uint32_t hv = imix(frontier[i].x, frontier[i].y, frontier[i].z, salt);
			if (hv < best_h) {
				best_h = hv;
				best = i;
			}
		}
		const Vector3i pick = frontier[best];
		frontier.erase(frontier.begin() + best);
		const bool stone = base_is_stone(pick.x, pick.y, pick.z);
		if (pick == v) {
			return stone ? block : BLOCK_AIR;
		}
		if (stone) {
			members += 1;
		}
		for (const Vector3i &s : INTRUSION_SIDES) {
			const Vector3i n = pick + s;
			if (std::find(visited.begin(), visited.end(), n) != visited.end()) {
				continue;
			}
			visited.push_back(n);
			if (std::abs(n.x - center.x) + std::abs(n.y - center.y)
					+ std::abs(n.z - center.z) <= size + 1) {
				frontier.push_back(n);
			}
		}
	}
	return BLOCK_AIR;
}

// The ore block at a rock voxel — AIR for country stone. Mirrors
// WorldGenerator._intrusion_at: same lattices, same salts, same picks.
int DelveGenerator::intrusion_at(int x, int y, int z) const {
	// Surface lattice — blobs only exist inside outcrop rock.
	const int sc = INTRUSION_SURF_CELL;
	const int cx = (int)Math::floor((double)x / sc);
	const int cz = (int)Math::floor((double)z / sc);
	for (int dcx = -1; dcx <= 1; dcx++) {
		for (int dcz = -1; dcz <= 1; dcz++) {
			const int c0x = cx + dcx;
			const int c0z = cz + dcz;
			const uint32_t h = imix(c0x, 0, c0z, 811);
			if (h % 2 == 0) {
				continue;
			}
			const int count = 1 + (int)((h >> 3) % 2);
			for (int k = 0; k < count; k++) {
				const uint32_t hk = imix(c0x, k, c0z, 937);
				const int px = c0x * sc + (int)(hk % sc);
				const int pz = c0z * sc + (int)((hk >> 4) % sc);
				const int grass = terrain_height(px, pz);
				const int rt = rock_top(px, pz, grass);
				if (rt <= grass) {
					continue;
				}
				const Vector3i center(px, rt - 1 - (int)((hk >> 8) % 2), pz);
				const int size = 1 + (int)((hk >> 12) % 3);
				const int dist = std::abs(x - center.x) + std::abs(y - center.y)
						+ std::abs(z - center.z);
				if (dist > size + 1) {
					continue;
				}
				const int ore = intrusion_member(
						center, size, (int)INTRUSION_TABLE[hk % 14],
						Vector3i(x, y, z), hk);
				if (ore != BLOCK_AIR) {
					return ore;
				}
			}
		}
	}
	// Deep lattice — blobs scatter through the rock mass.
	const int dc = INTRUSION_DEEP_CELL;
	const int bx = (int)Math::floor((double)x / dc);
	const int by = (int)Math::floor((double)y / dc);
	const int bz = (int)Math::floor((double)z / dc);
	for (int dxx = -1; dxx <= 1; dxx++) {
		for (int dyy = -1; dyy <= 1; dyy++) {
			for (int dzz = -1; dzz <= 1; dzz++) {
				const int c0x = bx + dxx;
				const int c0y = by + dyy;
				const int c0z = bz + dzz;
				const uint32_t h = imix(c0x, c0y, c0z, 613);
				if (h % 5 > 1) {
					continue;
				}
				const Vector3i center(
						c0x * dc + (int)(h % dc),
						c0y * dc + (int)((h >> 5) % dc),
						c0z * dc + (int)((h >> 10) % dc));
				const int size = 3 + (int)((h >> 15) % 7);
				const int dist = std::abs(x - center.x) + std::abs(y - center.y)
						+ std::abs(z - center.z);
				if (dist > size + 1) {
					continue;
				}
				const int ore = intrusion_member(
						center, size, (int)INTRUSION_TABLE[(h >> 21) % 14],
						Vector3i(x, y, z), h);
				if (ore != BLOCK_AIR) {
					return ore;
				}
			}
		}
	}
	return BLOCK_AIR;
}

int DelveGenerator::block_at(int x, int y, int z, int grass, int rock_top_y) const {
	const int top = MAX(grass, rock_top_y);
	if (y > top) {
		return BLOCK_AIR;
	}
	if (y <= bedrock_height) {
		return BLOCK_STONE;
	}
	if (y > rock_top_y) {
		// Grass is a decoration layer, not a block — the soil band is
		// dirt throughout except where a clay patch claims the column,
		// and the Grass system seeds coverage on top (never on clay).
		return clay_at(x, z) ? BLOCK_CLAY : BLOCK_DIRT;
	}
	const int depth = top - y;
	if (depth > 2 && is_cave(x, y, z)) {
		return BLOCK_AIR;
	}
	const int ore = intrusion_at(x, y, z);
	return (ore != BLOCK_AIR) ? ore : BLOCK_STONE;
}

void DelveGenerator::_generate_block(
		const Ref<VoxelBuffer> &out_buffer, const Vector3i &origin_in_voxels, int32_t lod) {
	g_gen_calls.fetch_add(1, std::memory_order_relaxed);
	if (lod != 0) {
		return;
	}
	const Vector3i size = out_buffer->get_size();
	const int max_surface = base_height + (int)Math::ceil(terrain_amplitude) + (int)Math::ceil(outcrop_protrusion);
	if (origin_in_voxels.y > max_surface) {
		out_buffer->fill(BLOCK_AIR, VoxelBuffer::CHANNEL_TYPE);
		return;
	}
	for (int rx = 0; rx < size.x; rx++) {
		const int x = origin_in_voxels.x + rx;
		for (int rz = 0; rz < size.z; rz++) {
			const int z = origin_in_voxels.z + rz;
			const int grass = terrain_height(x, z);
			const int rt = rock_top(x, z, grass);
			for (int ry = 0; ry < size.y; ry++) {
				const int y = origin_in_voxels.y + ry;
				const int block = block_at(x, y, z, grass, rt);
				if (block != BLOCK_AIR) {
					out_buffer->set_voxel(block, rx, ry, rz, VoxelBuffer::CHANNEL_TYPE);
				}
			}
		}
	}
	out_buffer->compress_uniform_channels();
}

int32_t DelveGenerator::_get_used_channels_mask() const {
	return 1 << VoxelBuffer::CHANNEL_TYPE;
}

void DelveGenerator::generate_block_test(
		const Ref<VoxelBuffer> &out_buffer, const Vector3i &origin_in_voxels, int32_t lod) {
	_generate_block(out_buffer, origin_in_voxels, lod);
}

int64_t DelveGenerator::debug_gen_calls() {
	return g_gen_calls.load(std::memory_order_relaxed);
}

void DelveGenerator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_world_seed", "seed"), &DelveGenerator::set_world_seed);
	ClassDB::bind_method(D_METHOD("get_world_seed"), &DelveGenerator::get_world_seed);
	ClassDB::bind_method(D_METHOD("set_base_height", "height"), &DelveGenerator::set_base_height);
	ClassDB::bind_method(D_METHOD("get_base_height"), &DelveGenerator::get_base_height);
	ClassDB::bind_method(D_METHOD("set_terrain_amplitude", "amplitude"), &DelveGenerator::set_terrain_amplitude);
	ClassDB::bind_method(D_METHOD("get_terrain_amplitude"), &DelveGenerator::get_terrain_amplitude);
	ClassDB::bind_method(D_METHOD("set_soil_depth", "depth"), &DelveGenerator::set_soil_depth);
	ClassDB::bind_method(D_METHOD("get_soil_depth"), &DelveGenerator::get_soil_depth);
	ClassDB::bind_method(D_METHOD("set_bedrock_height", "height"), &DelveGenerator::set_bedrock_height);
	ClassDB::bind_method(D_METHOD("get_bedrock_height"), &DelveGenerator::get_bedrock_height);
	ClassDB::bind_method(D_METHOD("set_outcrop_threshold", "threshold"), &DelveGenerator::set_outcrop_threshold);
	ClassDB::bind_method(D_METHOD("get_outcrop_threshold"), &DelveGenerator::get_outcrop_threshold);
	ClassDB::bind_method(D_METHOD("set_outcrop_protrusion", "protrusion"), &DelveGenerator::set_outcrop_protrusion);
	ClassDB::bind_method(D_METHOD("get_outcrop_protrusion"), &DelveGenerator::get_outcrop_protrusion);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "world_seed"), "set_world_seed", "get_world_seed");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "base_height"), "set_base_height", "get_base_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "terrain_amplitude"), "set_terrain_amplitude", "get_terrain_amplitude");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "soil_depth"), "set_soil_depth", "get_soil_depth");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "bedrock_height"), "set_bedrock_height", "get_bedrock_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "outcrop_threshold"), "set_outcrop_threshold", "get_outcrop_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "outcrop_protrusion"), "set_outcrop_protrusion", "get_outcrop_protrusion");

	ClassDB::bind_method(D_METHOD("set_regional_origin", "origin"), &DelveGenerator::set_regional_origin);
	ClassDB::bind_method(D_METHOD("get_regional_origin"), &DelveGenerator::get_regional_origin);
	ClassDB::bind_method(D_METHOD("set_regional_step", "step"), &DelveGenerator::set_regional_step);
	ClassDB::bind_method(D_METHOD("get_regional_step"), &DelveGenerator::get_regional_step);
	ClassDB::bind_method(D_METHOD("set_regional_size", "size"), &DelveGenerator::set_regional_size);
	ClassDB::bind_method(D_METHOD("get_regional_size"), &DelveGenerator::get_regional_size);
	ClassDB::bind_method(D_METHOD("set_regional_grid", "grid"), &DelveGenerator::set_regional_grid);
	ClassDB::bind_method(D_METHOD("get_regional_grid"), &DelveGenerator::get_regional_grid);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "regional_origin"), "set_regional_origin", "get_regional_origin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "regional_step"), "set_regional_step", "get_regional_step");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "regional_size"), "set_regional_size", "get_regional_size");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "regional_grid"), "set_regional_grid", "get_regional_grid");

	// Test hook — the _generate_block override is an engine-dispatched
	// virtual and can't also be a bound method under the same name.
	ClassDB::bind_method(
			D_METHOD("generate_block_test", "out_buffer", "origin_in_voxels", "lod"),
			&DelveGenerator::generate_block_test);
	ClassDB::bind_static_method("DelveGenerator",
			D_METHOD("debug_gen_calls"), &DelveGenerator::debug_gen_calls);
}

} // namespace delve
