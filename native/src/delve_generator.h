#pragma once

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/voxel_buffer.hpp>
#include <godot_cpp/classes/voxel_generator_script.hpp>

namespace delve {

// Block ids — must match BlockRegistry.Block in scripts/world/block_registry.gd.
enum BlockId {
	BLOCK_AIR = 0,
	BLOCK_DIRT = 1,
	BLOCK_GRASS = 2,
	BLOCK_STONE = 3,
	BLOCK_COAL_ORE = 4,
	BLOCK_IRON_ORE = 5,
	BLOCK_GOLD_ORE = 6,
};

// Native port of scripts/world/world_generator.gd — identical math and block
// ids (see BlockRegistry.Block), but compiled C++ so it parallelizes across
// Voxel Tools' generation threads instead of serializing in GDScript.
//
// WorldGenerator remains the oracle for column queries (surface_height,
// sapling_species_at) and for the generator-parity test; this class only
// implements the terrain fill.
class DelveGenerator : public godot::VoxelGeneratorScript {
	GDCLASS(DelveGenerator, godot::VoxelGeneratorScript)

	godot::Ref<godot::FastNoiseLite> height_noise;
	godot::Ref<godot::FastNoiseLite> cave_noise;
	godot::Ref<godot::FastNoiseLite> ore_noise;
	godot::Ref<godot::FastNoiseLite> rock_noise;

	int world_seed = 1337;
	int base_height = 32;
	double terrain_amplitude = 18.0;
	int soil_depth = 4;
	int bedrock_height = -64;
	double outcrop_threshold = 0.45;
	double outcrop_protrusion = 7.0;

	void configure_noise();

	bool is_cave(int x, int y, int z) const;
	int ore_at(int x, int y, int z, int depth) const;

protected:
	static void _bind_methods();

public:
	DelveGenerator();

	void set_world_seed(int seed);
	int get_world_seed() const;

	void set_base_height(int height);
	int get_base_height() const;

	void set_terrain_amplitude(double amplitude);
	double get_terrain_amplitude() const;

	void set_soil_depth(int depth);
	int get_soil_depth() const;

	void set_bedrock_height(int height);
	int get_bedrock_height() const;

	void set_outcrop_threshold(double threshold);
	double get_outcrop_threshold() const;

	void set_outcrop_protrusion(double protrusion);
	double get_outcrop_protrusion() const;

	// Terrain rules — public (not script-bound) so DelveSim can refill
	// mirrored chunks straight from the generator on block loads.
	int terrain_height(int x, int z) const;
	int rock_top(int x, int z, int grass) const;
	int block_at(int x, int y, int z, int grass, int rock_top_y) const;

	// Real C++ overrides — register_virtuals binds them as the extension
	// virtuals the engine dispatches to from its worker threads. They are
	// NOT script-callable; scripts use generate_block_test below.
	void _generate_block(
			const godot::Ref<godot::VoxelBuffer> &out_buffer,
			const godot::Vector3i &origin_in_voxels,
			int32_t lod) override;
	int32_t _get_used_channels_mask() const override;

	// Script-callable wrapper for tests (bound methods can't share the
	// virtual names — ClassDB rejects the double registration).
	void generate_block_test(
			const godot::Ref<godot::VoxelBuffer> &out_buffer,
			const godot::Vector3i &origin_in_voxels,
			int32_t lod);
	static int64_t debug_gen_calls();
};

} // namespace delve
