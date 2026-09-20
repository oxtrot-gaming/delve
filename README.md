# Voxel Colony

A starting framework for a colony simulator with voxel mining, built on Godot 4 and
[Zylann's Voxel Tools](https://github.com/Zylann/godot_voxel).

The player is an overseer: they fly over the terrain and *designate* voxels to be mined.
Units claim those jobs off a shared job board, path to them over the voxel grid, dig
the block out and drop its resource as an item pile in the mined-out space.

## Requirements

Voxel Tools is a C++ engine module, so it requires a custom Godot build — an ordinary
Godot 4 download will not open this project. Grab the matching editor binary:

```bash
tools/fetch_godot_voxel.sh        # downloads Voxel Tools v1.7 / Godot 4.7.2 into ./bin
./bin/godot.linuxbsd.editor.x86_64 --path .   # Linux
# on Windows (Git Bash): ./bin/godot.windows.editor.x86_64.exe --path .
```

## Running

```bash
./bin/godot.linuxbsd.editor.x86_64 --path .                                        # editor
./bin/godot.linuxbsd.editor.x86_64 --path . scenes/main.tscn                       # play
./bin/godot.linuxbsd.editor.x86_64 --headless --path . --script res://scripts/tests/smoke_test.gd
```

The smoke test is the regression check: it generates terrain, bakes the block library,
spawns the colony, designates a voxel and asserts a unit mines it and the drop lands
as an item pile.

[DESIGN.md](DESIGN.md) records the design decisions behind the mechanics below.

## Controls

| Input | Action |
| --- | --- |
| `WASD`, `Space` / `Ctrl` | fly the overseer camera (`Shift` to boost); the camera cannot enter terrain and slides along it |
| Mouse | look |
| Left click | designate the targeted voxel for mining |
| Right click | cancel a designation |
| `C` | spawn a unit at the targeted spot |
| `Esc` | release the mouse cursor |

## Layout

```
scenes/main.tscn          world + overseer + colony + HUD
scenes/unit.tscn      unit body
scripts/world/
  block_registry.gd       block ids, colors, hardness, drops; builds the VoxelBlockyLibrary
  world_generator.gd      VoxelGeneratorScript: surface, rock outcrops, caves, depth-gated ore veins
  voxel_world.gd          VoxelTerrain wrapper: get/mine/place, ground queries, A* paths
  main.gd                 boots the colony once terrain has streamed in
scripts/colony/
  colony_job.gd           a unit of work at a voxel (MINE / BUILD)
  colony.gd               job board, stockpile, unit roster, designation markers
  item_pile.gd            dropped resources lying in the world, waiting to be hauled
  drop_item.gd            one dropped item: material class, form (loose/boulder/cobble), volume
  unit.gd             idle → move → work state machine
scripts/player/overseer.gd  flying camera, voxel raycast, designation input
scripts/ui/hud.gd           stockpile / unit / target readout
```

## How the pieces fit

- **Blocks** are ids in `VoxelBuffer.CHANNEL_TYPE`. `BlockRegistry.BLOCKS` is the single
  source of truth: its order defines the ids *and* the model indices in the blocky
  library, so append new blocks at the end rather than reordering them.
- **Terrain** is blocky (`VoxelMesherBlocky`), which keeps mining discrete: one click,
  one cube, one resource unit.
- **Mining** goes through `VoxelWorld.mine()`, which refuses to edit unloaded chunks and
  returns the removed block id so the caller knows what was dropped.
- **Drops** total 125% of the mined block's volume and keep its material class. Soft
  material (soil) yields one loose item; hard material shatters into a random mix of
  boulders (0.1 m³) and cobbles (0.01 m³) topped up with a loose balance.
- **Spilling**: a dropped item settles where it lands only if the voxel has room —
  the spill probability is the voxel's occupancy plus half the item's volume. Loose
  items split off that fraction; solid items hop aside whole. Spilled items prefer
  the voxel below, then any orthogonal side, and keep re-checking until they settle.
- **Settling**: piles never hover — an item dropped into open air falls, and when a
  block is mined out, whatever was piled on top drops into the freed voxel and keeps
  falling until it rests on a solid block. Falls are animated: the pile accelerates
  downward and merges into any pile it lands on, and fresh drops rain into their
  slots from a voxel or so up.
- **Fill is floor**: a voxel's effective floor is its fill level — a pile carries a
  collision box as tall as its contents, so units stand on piles. A voxel holding a
  full cubic metre of items is *packed*: it renders as a solid block, is impassible,
  blocks paths and mining lines, and is solid footing for items and units above it.
- **Shoving**: when a packed pile blocks a unit's only route to a job, the unit
  walks up to it and moves items into neighbouring voxels until the cell clears —
  preferring clear routes first, and digging through rubble when there is none.
- **Jobs** never execute themselves. `Colony.designate_mine()` queues work, units call
  `claim_job()` / `complete_job()`, and cancelling a designation releases the assignee.
  A unit that makes no progress toward its job site for `stuck_timeout` seconds (5)
  drops the assignment; dropped jobs can't be re-claimed by the same unit for 10 s.
- **Reach**: a unit can mine a block only when its centre is within 1.5 m of the
  block's nearest face and no other solid voxel lies between them — nothing hidden
  behind, above or below another block. `Unit._work_spots()` picks pathing
  destinations by running the same check from each candidate's stand position.
- **Pathfinding** uses `VoxelAStarGrid3D` over a region around the unit and target,
  so digging into a hill changes reachability without any navmesh rebaking.

## Next steps this scaffold is shaped for

- More job types (`ColonyJob.Type.BUILD` is already reserved) and a priority/skill system.
- Hauling: mined blocks drop as [ItemPile]s where they were dug out; a haul job should
  carry them from the pile to the stockpile.
- Persistence: set `VoxelWorld.stream` to a `VoxelStreamSQLite` to save edited chunks.
- Faster generation: port `world_generator.gd` to a `VoxelGeneratorGraph` resource, or
  enable `use_gpu_generation`, once the world ruleset settles.
