#include "delve_generator.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>

#include <atomic>

using namespace godot;

namespace delve {

static std::atomic<int64_t> g_gen_calls{0};

// Ore table, rarest first — matches _ore_rules in world_generator.gd:
// {block, min_depth, threshold}, first match wins.
struct OreRule {
	BlockId block;
	int min_depth;
	double threshold;
};
static const OreRule ORE_RULES[] = {
	{ BLOCK_GOLD_ORE, 28, 0.86 },
	{ BLOCK_IRON_ORE, 12, 0.74 },
	{ BLOCK_COAL_ORE, 4, 0.62 },
};

DelveGenerator::DelveGenerator() {
	height_noise.instantiate();
	cave_noise.instantiate();
	ore_noise.instantiate();
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

	ore_noise->set_seed(world_seed + 2);
	ore_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
	ore_noise->set_frequency(0.09);

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

int DelveGenerator::terrain_height(int x, int z) const {
	return base_height + (int)(height_noise->get_noise_2d((double)x, (double)z) * terrain_amplitude);
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

int DelveGenerator::ore_at(int x, int y, int z, int depth) const {
	const double value = Math::abs(ore_noise->get_noise_3d((double)x, (double)y, (double)z));
	for (const OreRule &rule : ORE_RULES) {
		if (depth >= rule.min_depth && value > rule.threshold) {
			return (int)rule.block;
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
		return (y == grass) ? BLOCK_GRASS : BLOCK_DIRT;
	}
	const int depth = top - y;
	if (depth > 2 && is_cave(x, y, z)) {
		return BLOCK_AIR;
	}
	const int ore = ore_at(x, y, z, grass - y);
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

	// Test hook — the _generate_block override is an engine-dispatched
	// virtual and can't also be a bound method under the same name.
	ClassDB::bind_method(
			D_METHOD("generate_block_test", "out_buffer", "origin_in_voxels", "lod"),
			&DelveGenerator::generate_block_test);
	ClassDB::bind_static_method("DelveGenerator",
			D_METHOD("debug_gen_calls"), &DelveGenerator::debug_gen_calls);
}

} // namespace delve
