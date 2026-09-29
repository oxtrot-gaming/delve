# Delve

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

Timberborn-style: the cursor is always free, the camera is a boom orbiting a
focus point that rides the terrain.

| Input | Action |
| --- | --- |
| `WASD` / arrows, screen edges, `MMB` drag | pan the camera across the terrain |
| `Q` / `E`, `RMB` drag | rotate / orbit the camera; `Z` / `C` snap a quarter turn |
| Mouse wheel | zoom — while a drag box is up, extrude it along the face normal instead |
| `Shift` | faster pan and rotation |
| Left click | apply the selected tool to the voxel under the cursor — drag to paint a box on the hit face's plane; hold to stick the box, click to commit |
| Right click / `Esc` | abort a pending box, otherwise deselect the tool |
| `Del` / `Backspace` | cancel the designation under the cursor |
| `R` | cycle tools (hold to open the Architect menu — the same categories as the bottom bar) |
| `Space`, `1`/`2`/`3`, `.` | pause · 1x/3x/6x speed · advance one tick |

## The HUD

RimWorld-inspired, built in `scripts/ui/hud.gd`:

- **Top-left** — resources list: a tally of everything on stockpile tiles.
- **Top-center** — colonist bar: one button per unit with its current
  activity and energy; clicking jumps the camera. Each unit also floats a
  billboarded caption over its head showing the same activity text —
  blue while sleeping, dimmed while idle.
- **Top-right** — alerts region (empty — nothing produces alerts yet).
- **Bottom-left** — inspect pane: selected action, the cell under the cursor,
  pile fill, designation, and the perf readout.
- **Bottom bar** — the *Architect* menu (Orders / Zones / Structure /
  Production / Furniture / Power / Security / Dev) plus stubbed tabs
  (Work, Assign, Animals, Research, Factions, World, History) and a *Menu*
  with Quit. Categories and tabs without systems behind them stay visible
  but disabled.
- **Bottom-right** — display toggles (Zones, Plans and Colonist bar work;
  Beauty, Roofs and Home area are stubs), the speed controls, and the
  calendar readout. Plans shows pending-construction ghosts — it also
  turns itself on while a wall tool or Deconstruct is selected. The sun
  runs a real day/night cycle (~4-minute days) that pauses and speeds up
  with the game clock; the site's latitude/longitude set its sun path, so
  a second colony site elsewhere on the planet keeps its own local time.

## Layout

```
scenes/main.tscn          world + overseer + colony + HUD
scenes/unit.tscn      unit body
scripts/world/
  block_registry.gd       block ids, colors, hardness, drops, solidity; builds the VoxelBlockyLibrary
  world_generator.gd      VoxelGeneratorScript: surface, rock outcrops, caves, depth-gated ore veins, sapling scatter
  voxel_world.gd          VoxelTerrain wrapper: get/mine/place, ground queries, A* paths
  forest.gd               growing trees: discovery, growth, felling; the chop designation's resolver
  plants.gd               plants: bush discovery, ripeness, yields, annual/perennial; the forage resolver
  grass.gd                grass cover: seeded coverage, trampling, regrow and spread
  main.gd                 boots the colony once terrain has streamed in
scripts/colony/
  colony_job.gd           a unit of work at a voxel (MINE / CLEAR / BUILD / HAUL / CHOP / CRAFT / FURNISH / REST / DECONSTRUCT / FORAGE / EAT / SOW)
  farm_field.gd           a growing zone: its cells, crop assignment and auto-chop flag
  colony.gd               job board, stockpile, unit roster, buildings, designation markers
  building.gd             a construction's record: kind, block, material and exact input items
  item_pile.gd            dropped resources lying in the world, waiting to be hauled
  drop_item.gd            one dropped item: material class, form (loose/boulder/cobble/log/plank/bed kit), volume
  unit.gd             idle → move → work state machine
scripts/player/overseer.gd  flying camera, voxel raycast, designation input
scripts/ui/hud.gd           RimWorld-style shell: resources list, colonist bar, architect menu, toggles, time controls
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
- **Clearing**: marking a filled voxel queues a clearing job. A unit walks up
  and shovels every item into adjoining voxels — below first, then the emptiest
  side, then on top — until the pile is gone. Items move, never vanish.
- **Building**: the wall actions — *Build dirt wall*, *Build stone wall*,
  *Build log wall* — mark an empty voxel with the material picked up
  front. A unit fetches what that material's recipe still needs from the
  closest usable pile (no distance limit — it walks there), carries at
  most 0.5 m³ per trip, and repeats until every form the recipe calls for
  has arrived: 1.25 m³ of loose soil compacts into a dirt block
  (indistinguishable from natural ground), nine boulders and ten cobbles
  raise a stone wall, and two logs raise a log wall. Pending walls are
  *plans* — aimable ghosts you can keep building on top of, beside or
  below — so a tower or a row of wall designates before a single block
  goes up. A finished wall is a
  *building* — it remembers the material and the exact items it was built
  of.
- **Deconstructing**: the *Deconstruct* tool marks a construction for
  teardown — stone walls, log walls, worksites — and clicking a pending
  plan with it cancels that build outright. A unit takes a standing
  construction apart and
  the exact input items drop where it stood, whole. A packed-dirt wall is
  the exception: it reads as natural ground and has to be mined out
  instead (mining a built wall works too — it yields the generic shatter).
- **Stockpiles**: *Designate stockpile* marks an empty voxel on solid ground
  with a faint outline. Idle units haul the nearest loose pile to the
  nearest tile that admits its contents and has room — up to 0.5 m³ per
  trip, splitting bigger piles — and drop their load on the spot if the
  haul is interrupted. Selecting a tile with the inspect tool opens its
  admission filter: a checkbox per material class, all on by default.
  Rejecting a material also evicts what the tile already holds — those
  items get hauled to a tile that will take them.
- **Crafting**: *Designate crafting spot* marks an empty voxel on solid
  ground — a worksite: a building that costs nothing to place. Its tasks
  live on the site, not in the Orders menu — select it with a bare LMB
  click and its panel offers a button per recipe (*Craft planks*, *Craft
  bed*), plus *Cancel order* and *Deconstruct*. The unit fetches the
  recipe's inputs from the nearest piles in as many trips as it takes,
  saws at the spot for a few seconds, and drops the products plus the
  leftover fraction as loose sawdust — all of the inputs' material.
  Cancelling an order returns carried and delivered inputs intact; the
  site itself comes down via deconstruct.
- **Beds and rest**: units burn energy while awake — a full bar is two
  thirds of a day — and below a quarter they stop taking jobs and sleep:
  in a bed if one is free (fully rested after a third of a day), on the
  ground otherwise (poor rest, 25% longer), collapsing mid-work at zero.
  *Place bed* in the Architect menu's Furniture category plans a
  two-horizontal-cell footprint over solid floor; a unit fetches a bed
  kit — six planks crafted at a crafting spot — and unpacks it into a
  building that sleeps one occupant and drops the kit back when
  deconstructed.
- **Hunger and foraging**: units drain hunger over a day — below the seek
  line they walk to the nearest pile holding food and eat out of it, and
  at zero they keep working at half speed rather than collapsing. The
  first food source is the wild berry bush: a single-cell plant
  decoration (never a voxel — units path through it) seeded on grass at
  mixed ripeness, tinted to show when it bears. *Forage* in the Orders
  menu designates a ripe bush; a unit strips its yield into physical
  berry items at the bush for hauling, and the bush regrows on a timer.
- **Ladders**: *Build ladder* in the Architect menu's Structure category
  places a ladder in any open voxel — no floor needed, so shafts build
  top-down too. It costs three planks, fetched and assembled in place.
  A ladder never blocks its cell but supports a unit inside it or on
  the cell above, and stacked ladders climb or descend any height —
  rung by rung, not by falling. Items don't rest on a ladder: drops
  fall through to the bottom rung, and a pile sharing a ladder cell
  caps at three quarters of a cubic metre. Deconstructing hands the
  three planks back.
- **Collapse**: solid blocks need structural support — a face-connected
  chain of solids down to the base level. Mining or deconstructing a
  support brings down the whole detached body it held, each block
  dropping its mined rubble where it stood. Builds that would land
  unsupported *suspend* instead: the plan stays designated with its
  materials escrowed until a neighbouring placement anchors it — so
  stacked walls can be planned freely and finish bottom-up.
- **Jobs** never execute themselves. `Colony.designate_mine()` queues work, units call
  `claim_job()` / `complete_job()`, and cancelling a designation releases the assignee.
  A unit that makes no progress toward its job site for `stuck_timeout` seconds (5)
  drops the assignment; dropped jobs can't be re-claimed by the same unit for 10 s.
- **Skills**: units train Mining, Construction, Plants and Crafting by
  doing — each completed job grants XP, levels climb on a linear XP
  requirement, and work speed doubles every 10 levels. Job choice is a
  scored pick — distance minus a skill bonus minus a bonus that grows
  the longer a job waits — and each unit's *Specialize* toggle on its
  colonist panel trades "take the nearest work" for "cross the camp for
  my craft", while the waiting-time term keeps unskilled jobs claimable.
- **Reach**: a unit can mine a block only when its centre is within 1.5 m of the
  block's nearest face and no other solid voxel lies between them — nothing hidden
  behind, above or below another block. `Unit._work_spots()` picks pathing
  destinations by running the same check from each candidate's stand position.
- **Pathfinding** uses `VoxelAStarGrid3D` over a region around the unit and target,
  so digging into a hill changes reachability without any navmesh rebaking. Piles
  aren't voxels either — when a path is only blocked by a packed pile the unit
  detours to haul it to a stockpile, or shoves it aside.
- **Trees**: trees scattered on grass grow over time into a trunk with branches
  and a leaf canopy — generated terrain seeds them at mixed ages, so grown,
  log-bearing trees stand ready to harvest from the start. Trunk and branches
  are real solid voxels; saplings and leaves
  are tracked decorations rendered over air — units path straight through them.
  *Chop tree* on any part of a tree designates the whole thing: a unit works the
  root until the tree's summed hardness is met, then the tree fells all at once —
  one log per trunk voxel, plus loose branch and leaf material dropped where the
  parts stood. Species live in a table; only oak exists so far.
- **Fruit, seeds and decay**: mature trees drop one species fruit per leaf
  block every five game-days — oaks scatter acorns around their base — while
  bushes keep theirs for forage. The *Extract seed* order at a crafting spot
  presses a fruit into two species-tagged seed packets. Plant-derived items
  rot on the game clock at per-material rates — stochastically, so no ages
  are tracked — with leaves, branches and logs leaving compost behind, and
  a fruit rotting on soil can sprout a new plant of its kind.
- **Grass**: ground cover is decoration, not a block — the surface voxel is
  plain dirt and mines as soil, while a per-cell coverage layer renders
  the green. Construction over a grassed cell buries its cover, foot
  traffic wears it down (~five crossings strip a healthy patch), and
  living cover slowly regrows and spreads to bare neighbours.
- **Farming**: *Farm field* in the Zones menu marks growing cells into a
  field; select it and its panel assigns a crop — every shrub or tree
  species, wheat included — and tree fields get a *Chop mature trees*
  toggle. The field posts a *Sow* job per open cell the crop fits
  (shrubs need bare air over dirt; trees also want the 3×3 spacing wild
  saplings do), but only while a seed packet of the species exists in a
  pile — a unit carries the packet over and plants it. Sown plants grow
  like wild ones; ripe shrubs harvest themselves through ordinary forage
  jobs, annual crops (wheat) die to their harvest and re-sow on their
  own, perennials (the berry bush) bear forever, and auto-chop fells a
  tree field's mature trunks for timber. Wheat heads thresh into seed
  packets via *Extract seed*, so a wheat field can feed itself.

## Next steps this scaffold is shaped for

- Attributes that modulate skill gain and work rates, and richer hauling
  (item-shape carry limits, containers, opportunistic pickup).
- Persistence: set `VoxelWorld.stream` to a `VoxelStreamSQLite` to save edited chunks.
- Faster generation: port `world_generator.gd` to a `VoxelGeneratorGraph` resource, or
  enable `use_gpu_generation`, once the world ruleset settles.
