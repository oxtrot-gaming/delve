# Voxel Colony

A starting framework for a colony simulator with voxel mining, built on Godot 4 and
[Zylann's Voxel Tools](https://github.com/Zylann/godot_voxel).

The player is an overseer: they fly over the terrain and *designate* voxels to be mined.
Colonists claim those jobs off a shared job board, path to them over the voxel grid, dig
the block out and deposit what it drops into the colony stockpile.

## Requirements

Voxel Tools is a C++ engine module, so it requires a custom Godot build — an ordinary
Godot 4 download will not open this project. Grab the matching editor binary:

```bash
tools/fetch_godot_voxel.sh        # downloads Voxel Tools v1.7 / Godot 4.7.2 into ./bin
./bin/godot.linuxbsd.editor.x86_64 --path .
```

## Running

```bash
./bin/godot.linuxbsd.editor.x86_64 --path .                                        # editor
./bin/godot.linuxbsd.editor.x86_64 --path . scenes/main.tscn                       # play
./bin/godot.linuxbsd.editor.x86_64 --headless --path . --script res://scripts/tests/smoke_test.gd
```

The smoke test is the regression check: it generates terrain, bakes the block library,
spawns the colony, designates a voxel and asserts a colonist mines it into the stockpile.

## Controls

| Input | Action |
| --- | --- |
| `WASD`, `Space` / `Ctrl` | fly the overseer camera (`Shift` to boost) |
| Mouse | look |
| Left click | designate the targeted voxel for mining |
| Right click | cancel a designation |
| `C` | spawn a colonist at the targeted spot |
| `Esc` | release the mouse cursor |

## Layout

```
scenes/main.tscn          world + overseer + colony + HUD
scenes/colonist.tscn      colonist body
scripts/world/
  block_registry.gd       block ids, colors, hardness, drops; builds the VoxelBlockyLibrary
  world_generator.gd      VoxelGeneratorScript: surface, caves, depth-gated ore veins
  voxel_world.gd          VoxelTerrain wrapper: get/mine/place, ground queries, A* paths
  main.gd                 boots the colony once terrain has streamed in
scripts/colony/
  colony_job.gd           a unit of work at a voxel (MINE / BUILD)
  colony.gd               job board, stockpile, colonist roster, designation markers
  colonist.gd             idle → move → work state machine
scripts/player/overseer.gd  flying camera, voxel raycast, designation input
scripts/ui/hud.gd           stockpile / colonist / target readout
```

## How the pieces fit

- **Blocks** are ids in `VoxelBuffer.CHANNEL_TYPE`. `BlockRegistry.BLOCKS` is the single
  source of truth: its order defines the ids *and* the model indices in the blocky
  library, so append new blocks at the end rather than reordering them.
- **Terrain** is blocky (`VoxelMesherBlocky`), which keeps mining discrete: one click,
  one cube, one resource unit.
- **Mining** goes through `VoxelWorld.mine()`, which refuses to edit unloaded chunks and
  returns the removed block id so the caller knows what was dropped.
- **Jobs** never execute themselves. `Colony.designate_mine()` queues work, colonists call
  `claim_job()` / `complete_job()`, and cancelling a designation releases the assignee.
- **Pathfinding** uses `VoxelAStarGrid3D` over a region around the colonist and target,
  so digging into a hill changes reachability without any navmesh rebaking.

## Next steps this scaffold is shaped for

- More job types (`ColonyJob.Type.BUILD` is already reserved) and a priority/skill system.
- Hauling: currently a mined block teleports into the stockpile; the drop should become an
  item entity and a haul job.
- Persistence: set `VoxelWorld.stream` to a `VoxelStreamSQLite` to save edited chunks.
- Faster generation: port `world_generator.gd` to a `VoxelGeneratorGraph` resource, or
  enable `use_gpu_generation`, once the world ruleset settles.
