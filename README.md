# Delve

A colony simulator on a fully mineable voxel world — "RimWorld in 3D" with
Dwarf Fortress leanings — built on Godot 4 and
[Zylann's Voxel Tools](https://github.com/Zylann/godot_voxel).

The player is an overseer: they fly over the terrain and *designate* work on a
shared job board. Units claim the jobs, path over the voxel grid, and do the
labour with their hands — every mined block becomes physical items that spill,
settle, get hauled cell by cell and never teleport into storage. Around that
core has grown a real colony: needs, moods, skills and person-held knowledge,
weather and seasons on a real planet clock, dynamic water, farming and
livestock, a craft ladder from knapped stone to bloomery steel, per-part
wounds and surgery, drafted combat — all inside a generated world of which
the colony site is one settleable tile.

## Requirements

Voxel Tools is a C++ engine module, so it requires a custom Godot build — an
ordinary Godot 4 download will not open this project. Grab the matching editor
binary:

```bash
tools/fetch_godot_voxel.sh        # downloads Voxel Tools v1.7 / Godot 4.7.2 into ./bin
./bin/godot.linuxbsd.editor.x86_64 --path .   # Linux
# on Windows (Git Bash): ./bin/godot.windows.editor.x86_64.exe --path .
```

The sim's hot paths live in an optional GDExtension under `native/` —
`DelveGenerator` (terrain generation) and `DelveSim` (the voxel mirror the A*,
water, pile-gravity and unit-step code runs against). The `.gdextension` only
maps Windows builds today; where no build exists, every system falls back to
the GDScript implementation — slower, but identical. To build it, see the
instructions in `native/CMakeLists.txt` (godot-cpp is cloned into
`native/godot-cpp`, which is gitignored along with `native/build` and
`native/bin`).

## Running

```bash
./bin/godot.linuxbsd.editor.x86_64 --path .                                        # editor
./bin/godot.linuxbsd.editor.x86_64 --path . scenes/main.tscn                       # play (skips the title screen)
./bin/godot.linuxbsd.editor.x86_64 --headless --path . --script res://scripts/tests/smoke_test.gd
```

The project scene (`scenes/worldgen.tscn`) opens on the title screen:
Continue (or any save slot), New world, Quit. A new world runs the embark
flow — a baseline data package (the planet's biome, species and flora
definitions), the seed and worldgen sliders (ocean coverage, temperature,
moisture, axial tilt), then a rotatable biome globe to pick the embark tile,
with a scenario dropdown beside it: *Lost Tribe* (five settlers with knapped
tools and three head of swine) or *Debug landing* (three settlers, bare).

The smoke test is the regression gate: it generates terrain, bakes the block
library, boots the worldgen flow, spawns the colony, designates a voxel and
asserts a unit mines it and the drop lands as an item pile. `scripts/tests/`
also holds a battery of focused probes — one per system (water flow and
machines, collapse, farm sowing, alloys, save/load round-trips, moods,
swimming, footing…) — run the same way as the smoke test.

[DESIGN.md](DESIGN.md) records the design decisions behind the mechanics
below; [PLAN.md](PLAN.md) the roadmap they shipped against.

## Controls

Timberborn-style: the cursor is always free, the camera is a boom orbiting a
focus point that rides the terrain.

| Input | Action |
| --- | --- |
| `WASD` / arrows, screen edges, `MMB` drag | pan the camera across the terrain |
| `Q` / `E`, `RMB` drag | rotate / orbit the camera; `Z` / `C` snap a quarter turn |
| Mouse wheel | zoom — while a drag box is up, extrude it along the face normal instead |
| `PgUp` / `PgDn` | raise / lower the slice plane (the layer view that lets you designate underground) |
| `Shift` | faster pan and rotation; `Shift`-click a settler to add them to the squad selection |
| Left click | apply the selected tool to the voxel under the cursor — drag to paint a box on the hit face's plane; hold to stick the box, click to commit. With no tool selected, inspect the unit, animal or building under the cursor |
| Right click / `Esc` | abort a pending box, then drop the inspected building/unit, then deselect the tool. With drafted settlers selected, RMB is an *order*: attack the critter under the cursor, wreck the aimed construction, or move to the cell |
| `Alt` (hold) | zone override — a stockpile/farm/area drag always starts a fresh zone instead of extending an adjacent one |
| `Del` / `Backspace` | cancel the designation under the cursor |
| `R` | cycle tools (hold to open the Architect menu — the same categories as the bottom bar) |
| `Space`, `1`/`2`/`3`, `.` | pause · 1x/3x/6x speed · advance one tick |
| `F9` | dump every unit's decision trail to the clipboard and `user://unit_diagnostics.txt` — the first thing to grab for a behaviour bug |

## The HUD

RimWorld-inspired, built in `scripts/ui/hud.gd`:

- **Top-left** — resources list: a tally of everything on stockpile tiles,
  grouped so unlike goods (different quality tiers, different materials)
  never silently merge.
- **Top-center** — settler bar: one button per unit with its current
  activity and energy; clicking jumps the camera (and selects the unit —
  `Shift`-click builds a squad), `[D]` marks the drafted. Each unit also
  floats a billboarded caption over its head showing the same activity text —
  blue while sleeping, dimmed while idle.
- **Top-right** — alerts region (still empty — nothing produces alerts yet).
- **Bottom-left** — inspect pane: selected action, whoever is under the
  cursor, the cell under the cursor (block, decoration, pile fill and
  contents, zone or building), unit/job counts and the perf readout.
- **Bottom bar** — the *Architect* menu: **Orders** (mine, chop, forage,
  cut plant, clear, cancel, deconstruct, uninstall, unpack, hunt, tame,
  forbid), **Zones** (stockpile, dumping zone, warehouse, farm field,
  fertilize, allowed areas, home area), **Structure** (walls and doors in
  dirt/stone/log/plank, ladder), **Floors** (packed earth, flagstone, plank,
  strip), **Production** (crafting spot, campfire, butcher spot, grave,
  charcoal mound, pit smelter, bloomery, research bench, metalworker's,
  fabrication, tailor's, toolmaker's and stonecutter's benches, kiln,
  refractory, stone crusher, stove), **Furniture** (the full bed/seating/
  table/storage/decor/lamp catalogue plus shelf and compost bin),
  **Recreation** (horseshoes, hoopstone, board and table games, telescope,
  instruments, television), **Power** (fuel generator, conduit, pylon,
  heater, cooler, water wheel, pump), **Security** (dirt mound, wood and
  stone barricades, wooden fence, floodgate, spike trap — Turret stays a
  stub), and **Dev** (spawn unit).
  Beside it the tabs — **Work** (the live job board: every open/assigned/
  suspended job with a per-unit "who can claim it and why not" breakdown,
  plus the crew list), **Assign** (the allowed-area manager),
  **Animals** (the roster: wild marks with tame progress, the domestic
  herd, a tame button per wild row), **Research** (no tech tree — a
  roster × skills grid showing what each settler knows, passions marked),
  **World** (the site's mesoscale map, every known site, and the
  travel/found-site controls) — then *Menu*: Save/Load (named slots plus
  the autosave slot under `user://saves/`), Options (volume, autosave
  cadence, perf overlay) and Quit. Factions and History stay visible but
  disabled.
- **Bottom-right** — display toggles, all live: Zones (designation markers),
  Plans (pending-build ghosts — also forced on while a wall tool or
  Deconstruct is selected), Beauty (the per-cell sight-line score heatmap),
  Roofs (bounded-room vs overhead cover), Flow (water flux arrows), Home
  area and Settler bar. Then the speed controls, the *Zz* sleep boost —
  fast-forwards to 6x while every settler at the site is asleep and drops
  back the moment someone wakes — and the calendar readout: season, local
  date and time, weather and temperature.
- **Selection panels** — a bare LMB click opens whatever's under the cursor:
  a worksite's bill queue (repeat condition, count, worker and skill band,
  ingredient radius, material filter, delivery target — plus campfire fuel
  controls, a bed's medical toggle, the floodgate's opening slider), a
  stockpile cell's zone filter (per-material checkboxes, priority rank,
  named presets, copy/paste), a farm field's crop picker (auto-chop and
  fertilize controls), a unit's panel (skills, needs, tastes, role, allowed
  area, medicine policy, surgery bills, holster reservations, Draft /
  Relieved / Specialize), an animal's area, and so on.

The sun runs a real day/night cycle (~4-minute days) inside a 60-day year of
four seasons; the site's latitude and longitude set its sun path and day
length, so a second colony site elsewhere on the planet keeps its own local
time.

## Layout

```
scenes/main.tscn            world + overseer + colony + HUD — the playable scene
scenes/worldgen.tscn        entry scene: title screen, new-world options, globe embark picker
scenes/unit.tscn            unit body
scenes/animal.tscn          animal body
scripts/world/
  block_registry.gd         block ids, build/floor/furniture/recreation spec tables,
                            ore table, material data; builds the VoxelBlockyLibrary
  world_generator.gd        VoxelGeneratorScript shell over DelveGenerator: surface,
                            outcrops, caves, mineral intrusions, biome soils, the
                            sapling/bush/scree oracle lattices
  voxel_world.gd            VoxelTerrain wrapper + the DelveSim bridge: get/mine/place,
                            ground queries, A* paths, the collapse flood
  site_field.gd             one-shot site install: carved terrain raster, depression
                            fill, flow accumulation, basins/rivers/wetland flags
  water_view.gd             the live per-cell water as corner-averaged surface skins
  flow_view.gd              flux arrows over the waterline (the Flow toggle)
  slice_view.gd             the layer view: clip plane + cross-section cap tiles
  forest.gd                 trees: discovery, growth, felling, fruit drops, snags
  plants.gd                 shrubs and crops: discovery, ripeness, yields, stress,
                            damage, death; the forage resolver and crop table
  plant_growth.gd           the light × fertility × temperature multiplier both
                            plant systems share
  grass.gd                  grass cover: seeding, trampling, regrow/spread, grazing
  flooring.gd               thin coverings on any exposed block face
  rooms.gd                  sealed-space flood fill: rooms, boundary conductance,
                            uniform temperature, impressiveness grades
  weather.gd                site climate: seasons, temperature curves, precipitation
                            states, ground saturation
  day_cycle.gd              planet clock → this site's sun, day/night and calendar
  globe.gd                  the Goldberg-tiled planet: elevation/temperature/
                            precipitation fields, Whittaker biomes
  meso_map.gd               one globe tile resolved to a flat heightfield patch
  site.gd / region.gd       a colony site (anchor, bounds, live or dormant
                            colony) · the 256² persistence tile
  ruins.gd                  collapsed structures seeded at founding
  main.gd                   boot, save slots, the region cache, multi-site travel
scripts/colony/
  colony.gd                 the colony: job board, stockpiles/zones/areas, roster,
                            buildings, designations, recipes, fires, arrivals, power
  colony_job.gd             a unit of work at a voxel — the job-type enum and the
                            job→skill maps
  worksite_order.gd         one queued bill on a worksite
  building.gd               a construction's record: kind, spec, material, components,
                            hp, fuel, occupants
  item_pile.gd              dropped resources lying in the world, waiting to be hauled
  drop_item.gd              one item: material, form, volume, spec, quality, wear
  unit.gd                   the settler: needs, mood, facets, skills, health,
                            equipment — the idle → move → work state machine
  animal.gd                 wildlife and livestock: wander/graze/flee/fight,
                            tame sessions, pen behaviour
  species.gd                the creature spec table — the settler is an entry too
  stockpile_zone.gd         grouped storage cells: the shared reject filter + priority
  farm_field.gd             a growing zone: cells, crop, auto-chop/fertilize
  allowed_area.gd           a named cell set a unit or animal can be confined to
  overlays.gd               designation, zone, area and plan marker layers
scripts/player/overseer.gd  camera boom, voxel raycast, drag-box designation input,
                            squad selection and drafted orders
scripts/ui/hud.gd           the RimWorld shell: resources, settler bar, Architect
                            menu, tabs, toggles and every inspect panel
scripts/ui/worldgen.gd      title → new-world options → globe embark flow
scripts/ui/filter_presets.gd  named stockpile filter presets (per-user, across saves)
scripts/data/               selectable content: data_package.gd registry,
                            pack_vanilla.gd (biomes, species, flora), the two
                            scenarios, game_options.gd
scripts/dlog.gd             crash-surviving append-per-line debug log
scripts/tests/              smoke_test.gd (the regression gate) plus ~50 focused
                            system probes
native/                     the delve_native GDExtension — DelveGenerator and
                            DelveSim, the compiled fast paths (sources committed,
                            artifacts not)
shaders/                    the slice-view shader set
```

## How the pieces fit

### The world

- **Blocks** are ids in `VoxelBuffer.CHANNEL_TYPE`. `BlockRegistry.BLOCKS` is
  the single source of truth: its order defines the ids *and* the model
  indices in the blocky library — append new blocks at the end, never reorder.
- **Terrain** is blocky (`VoxelMesherBlocky`), which keeps mining discrete:
  one click, one cube, one resource unit. Generation is a GDScript
  `VoxelGeneratorScript` that delegates to the compiled `DelveGenerator` when
  the extension is loaded — voxel-for-voxel identical, ~6× faster.
- **The planet** is three stacked layers, each deterministic from the world
  seed: the **globe** (a ~180k-cell Goldberg tiling with elevation,
  temperature, precipitation and Whittaker biomes — ocean and ice cap refuse
  embark), the **meso map** (one globe tile resolved to a flat heightfield
  that pins the voxel terrain's regional base height), and the **site** (the
  ~128² voxel patch the colony occupies). The colony's edit boundary is
  bounded — you can look a margin past it but only designate inside.
- **Sites live in regions** — a 256² tile that is the persistence unit.
  Several sites can share one region; unvisited ones sit dormant with their
  saved colony payload. The World tab's meso map marks a cell and sends a
  travel party walking (or founds a new dormant site); parties cross the meso
  layer abstractly at walking pace and walk in from the destination's rim.
- **Soils are biome-aware**: each biome lays a patchwork of soil classes —
  poor/rich dirt, clay, sand, peat, frozen ground over a clayey subsoil —
  with depth scaled by slope and climate. Every soil variant mines to generic
  `SOIL`; fertility lives in the ground (and in per-cell fertilization), not
  the item. Country rock varies by biome too — granite shields, limestone
  basins, marble/slate folds, serpentine intrusions.
- **Hydrology**: the site install carves river channels into the terrain
  raster, fills lake basins to their spill level and flags wetlands and
  shores — then hands it all to a *live* per-cell simulation: each open
  voxel holds a water volume in cm³, wet cells trade volume with neighbours
  proportional to head difference (falls first, so waterfalls behave), rivers
  feed from edge inlets and exposed cells evaporate. Terrain is a moving
  boundary — breach a wall and the basin floods, stack blocks and it dams.
  Units wade and swim through it.
- **Water machines**: the floodgate throttles a cell's flux 0–100% from its
  inspect slider (regulated edges, not on/off gates), the pump is a paired
  sink/source edge that moves water uphill while powered, and the water
  wheel turns the flux through its cells into watts — deliberately
  inefficient, so no pump→wheel→pump perpetuum mobile.
- **Weather and seasons**: a five-state sky (clear, rain, snow, dry/wet
  storms) whose parameters come off the tile's climate — meso mean
  temperature, annual rainfall, and a latitude-scaled seasonal swing on a
  tilted axis. Temperature rides a yearly + daily sine plus bounded noise;
  rare heat waves and cold snaps bias it. Rain wets the ground (and soaks
  fuel faster); storms throw lightning that ignites the colony's flammable
  cells — dry-storm strikes are the dangerous kind.
- **Ruins**: a handful of collapsed structures seeded at founding — partial
  stone walls whose dressed blocks deconstruct back out, rubble underfoot,
  the occasional out-of-place stone.

### Matter — drops, piles and gravity

- **Mining** goes through `VoxelWorld.mine()`, which refuses to edit
  unloaded chunks and returns the removed block id so the caller knows what
  was dropped. Drops total 125% of the mined volume and keep the material
  class: soft material yields one loose item; hard material shatters into
  boulders (0.1 m³), cobbles (0.01 m³) and a loose balance.
- **Ore is embedded, not pure** — a hematite voxel is iron in stone.
  `BlockRegistry.ORES` carries each mineral's `share` of the cubic metre,
  so the boulder/cobble/gravel mix lands the exact fraction: mining native
  gold almost always returns one gold sliver in ordinary rock. Mineral
  intrusions seed deep blobs plus 1–3-voxel hints in surface outcrops, and
  roughly one scattered rock pile in six is mineral-bearing — surface ore
  before you ever dig.
- **Spilling**: a dropped item settles where it lands only if the voxel has
  room — spill probability is occupancy plus half the item's volume. Loose
  items split off that fraction; solid items hop aside whole.
- **Settling**: piles never hover — drops fall, and when a block is mined
  out whatever was piled above drops into the freed voxel and keeps falling
  until it rests on a floor. Logic is instant, visuals lag: the pile node
  animates downward and merges into whatever it lands on.
- **Fill is floor — loose fill anyway**: a voxel's capacity is its *total*
  item fill, and at a full cubic metre the pile is *packed* — renders as a
  solid block, impassable, blocks paths and mining lines, footing for items
  and units above. But the floor a unit stands on is the *loose* fill only
  (poured soil, gravel, sawdust). Discrete goods — logs, boulders, meals —
  are clutter: waded through on a quadratically steepening curve, and past
  0.75 m³ of it the heap is *dense* — impassable, unstandable, flimsy cover
  in a fight. A pour that would lift a stander's head into a blocked cell
  stops at headroom and evicts the surplus.
- **Shoving, hauling and clearing**: a packed pile blocking the only route
  gets hauled aside when a stockpile has room, shoved item-by-item into
  neighbouring voxels otherwise. *Clear pile* queues the same mechanics as a
  job — items move, never vanish.
- **Collapse**: a solid block stands iff a face-connected chain of solids
  reaches the base level; mining or deconstructing a support brings the
  detached body down as mined rubble. A build that would land unsupported
  *suspends* — designated, materials escrowed — until a neighbouring
  placement anchors it, so stacked walls plan freely and finish bottom-up.

### Jobs, hauling and zones

- **Jobs** never execute themselves: designations post to `Colony`'s board
  (mine, clear, build, chop, forage, cut plant, craft, sow, fertilize,
  deconstruct, uninstall, unpack, haul, refuel, hunt, tame, butcher, tend,
  rescue, surgery, bury, repair, firefight, clean, teach, arrest, burn…),
  units `claim_job()` the best-scoring open one — distance minus skill minus
  a languish term that grows the longer the job waits, with urgency bonuses
  for firefighting — and cancelling a designation releases the assignee.
  A unit that makes no progress for 5 s drops the job; retry delay doubles
  with each consecutive failure up to two minutes. Self-issued jobs (rest,
  eat, desperate forage, recreation, dress, drafted orders) never touch the
  board.
- **Reach**: a unit can work a voxel only within 1.5 m of its nearest point
  and with no other solid voxel between — the path planner evaluates the
  same predicate from each candidate stand position, so the planner and the
  gate never disagree. Standing on a partial pile counts.
- **Pathfinding** runs the native sim's A* — `VoxelAStarGrid3D`'s movement
  rules (8-dir, +1 jumps, 3-cell falls, 1×2×1 fit) plus ladder edges, door
  tolls and per-cell traversal costs (cover, clutter, trap cells settlers
  route around and animals don't). `VoxelAStarGrid3D` remains the fallback.
- **Stockpiles** mark empty cells on solid ground into `StockpileZone`s —
  a shared admission filter (per-material checkboxes), a priority rank,
  and named presets that copy between zones and persist across saves.
  Dumping zones take refuse at low priority; **warehouse** zones are the
  only places furniture crates fit; **shelf** buildings double a cell's
  capacity and own their zone; **compost bins** admit only compostables at
  high priority and triple their rot rate. Gestures extend the zone they
  touch, Alt forces a fresh one, ambiguous drags fail, zoned cells are
  never adopted. Rejecting a material evicts what the zone holds.
- **Hauling is mass-gated**: capacity is kilograms (carry 40, drag 1500,
  scaled by the `strength` facet and by apparel like the backpack), so a
  bear carcass or a whole log is a *drag* item — slow. Idle units sweep
  loose piles toward admitting tiles; a pile blocking a job's path is
  hauled aside rather than shoved when it can be; and a unit walking a
  fresh route grabs a pile that wants moving when an admitting tile sits
  near its goal — the opportunistic detour. Loads taken on a failed haul
  drop where the unit stands.
- **Allowed areas, forbid, home area**: painted cell sets confine a unit's
  or animal's every `nearest_*` query and claim. The forbid flag makes a
  pile's contents untouchable to settlers (animals don't care — the X
  marks the spot). The **home area** is the colony's lived-in footprint —
  it auto-expands around finished construction and new zones (toggleable),
  and it's what makes repair, firefight and cleaning bills spawn: a
  wilderness blaze burns on its own.
- **Yielding and traffic**: an idle unit physically blocks a corridor, so
  a pusher shoves it a step aside (`yield_to`); bodies collide head-on in
  the sim's unit channel, not the A*.

### Buildings, craft and industry

- **Building** is real hauling: a wall spec is a *recipe* — 1.25 m³ of
  loose soil compacts into a dirt block, a stone wall takes 120 dressed
  blocks (the stone tool has per-rock variants), a log wall one log, a
  plank wall five planks — and the unit fetches each form from the nearest
  usable pile in ≤0.5 m³ trips until escrow is full. The material is pinned
  at designation: a wall whose material runs out waits rather than becoming
  a different wall. Pending builds are aimable ghost *plans* — you can
  stack designations before a single block goes up.
- **Doors** are two-cell buildings over an open sill — units path through,
  paying a small toll per passage — and a door leaf is what seals a room.
  Coolers seal like doors so they can hang in a wall gap holding two
  climates.
- **Deconstruction is lossless**: a finished construction registers a
  `Building` record holding the *exact* input items; teardown drops them
  whole (except packed-dirt walls, which read as natural ground and must
  be mined — mining any wall yields scrap at its recipe's invested
  volume). The same tool cancels a pending plan outright.
- **Damage and repair**: constructions carry hp off their material's
  hardness — melee, fire and wreck orders wear it down and a hit self-posts
  a `REPAIR` bill inside the home area; at zero the building comes down.
  Bare terrain banks damage per-cell too, breaking as if mined.
- **Floors, rooms and beauty**: paving tools dress any exposed block face
  (packed earth, flagstone, plank — thin recipes, face-exact drags).
  `Rooms` flood-fills sealed open space — outdoors never counts — and each
  room carries a uniform temperature (boundary conductance: doors leak,
  open faces equalize, deep walls read as ground) and an impressiveness
  grade off its beauty, space and furnishings. Units sample the beauty of
  what they can see — room score indoors, a sight bubble outside — and
  mood, rest quality and dining thoughts answer to it.
- **Worksites and bills**: production buildings hold a RimWorld-style bill
  queue — *do X times*, *until you have X* (with an unpause-at hysteresis
  and a stored-only option), or *forever* — plus pause, ingredient radius,
  material filters, a pinned worker, a skill band, and delivery to the
  worker's feet or a named stockpile. A bill whose inputs don't exist
  slides to the back; a running bill's escrowed inputs return on cancel.
- **Craft quality**: every finished craft rolls off the maker's skill —
  awful through masterwork — onto its outputs and the buildings it raises.
  Beds rest and heal better, recreation fills faster, meals feed more; a
  sub-zero roll botches (inputs spill, the bill requeues in the same
  hands). Quality survives packing into crates.
- **Furniture** is a catalogue of craft-in-place builds — beds and
  bedrolls, seats, tables, storage, sculpture, lamps — gated where it
  makes sense (real beds want *Complex furniture* knowledge; powered lamps
  want the grid). *Uninstall* packs a piece into a spec-stamped crate
  (plus a spent sheet shell) that only warehouse zones admit;
  re-designating unpacks it intact; *Unpack* cracks the crate in place.
- **Ladders** hang in any open cell — shafts dig top-down — support a unit
  inside or on top, let drops fall through to the bottom rung, and cap a
  shared pile at ¾ m³.
- **Tools gate the labour**: digging wants a shovel or pick, hard rock a
  pick alone, chopping an axe. A unit without one in hand redirects to
  fetch the nearest qualifying tool — knapped stone first (rod + cobbles,
  half speed, short-lived), forged iron from the toolmaker's bench later
  (faster, 800 wear-units). Wear drains per hardness-unit of work; metal
  tools repair at the bench, knapped heads just break.
- **Knowledge, not a tech tree**: the gated skills — pit smelting,
  bloomery smelting, charcoal burning, electrician, HVAC, complex
  furniture — can't be *claimed* by a unit below level 1. Knowledge is XP
  living in people: it spreads by doing, by `TEACH` jobs (a tutor drips XP
  into a student at a fraction of their own), by the Contemplate recreation
  (a rare insight into anything, even things nobody knows), and by the
  research bench's *Study* bills — dismantle a found artifact for the XP
  its recipe demands (a found pick teaches bloomery). A dead expert is a
  real setback.
- **The production ladder**: campfire (five cobbles — cooks, lights, heats,
  burns fuel-seconds with an auto-`REFUEL` job) → charcoal mound (a
  supervised `BURN` — charcoal out-fuels its wood) → stonecutter's bench
  (field rubble → dressed blocks) and stone crusher → pit smelter
  (malachite, cassiterite → copper, tin) → bloomery (clay-built; hematite →
  iron) → kiln (firebrick, the gold crucible) → refractory (bronze, steel)
  → metalworker's and fabrication benches (sheet, wire, machine
  components) → toolmaker's bench, tailor's bench, and the stove — the
  regulated firebox that out-cooks the open ring.
- **Power**: the fuel generator (campfire-style fuel store) and the water
  wheel feed *nets* — floods over conductor faces: conduit embedded in
  built walls by an `install_conduit` face job, freestanding pylons, and
  the devices themselves. Watts go to the cheapest cells first in a
  brownout: the electric heater warms its room (and occasionally starts a
  fire), the cooler pumps heat across a wall gap — and a cold enough room
  freezes the organic rot clock outright, which is the freezer.
- **Cloth and gear**: cotton is an annual crop; the tailor's bench weaves
  it (and leather) into garments — tribalwear, tool belts, backpacks —
  each covering apparel layers that can't collide. Worn pieces fray over
  ~60 days, repair bills scale their cost to the wear, salvage bills
  reclaim half. Hands, holster slots and worn kit decide what a unit
  carries; a holster reservation is how a pocket stays free for a weapon.

### Units — needs, minds and bodies

- **Needs drive the day** — no schedule tab. Energy drains over two thirds
  of a day (beds rest well, ground poorly, medical beds treat), hunger over
  a day (pile-eaten meals; below desperation a starving unit self-forages
  an undesignated ripe bush; at zero it works at half speed), recreation
  over a day and a half (free activities — pray, walk, socialize,
  contemplate, visit a grave — or the built ones, with a per-kind tolerance
  that wants variety), and **mood** drifts toward a base plus the summed
  offsets of live *thoughts* — slept on the ground, raw meal, drab room,
  admired favoured art, working in the dark. Below the break threshold
  (shifted by `stress_vulnerability`) the unit rolls a mental break:
  food binge, a wandering daze, or — under the violent share — a berserk
  rampage the colony must subdue. Catharsis follows; mood-therapy holds a
  fraying unit in recreation until it actually recovers.
- **Facets, tastes and passions**: `facets` is a rolled 0–100 map
  (`activity_level`, `stress_vulnerability`, `cheer_propensity`,
  `gregariousness`, `immoderation`, `strength`, `bravery`) — the trait
  system as positions, not flags; behaviour seams read it directly
  (immoderation slides eating thresholds, bravery sets the drafted break
  line). `preferences` is a Dwarf-Fortress handful of likes/dislikes over
  materials and creatures — a favoured marble statue, a hated wolf, a liked
  cloth all shade the thoughts that touch them. `passions` mark burning
  affinities per skill — ×2 XP and a moodlet for doing the loved work.
- **Skills and roles**: 18 skills train by doing (mining, construction,
  plants, crafting, cooking, animals, butchering, medicine, the smelts,
  charcoal, electrician, HVAC, manufacturing, complex furniture, swimming,
  social, art); work speed doubles every 10 levels. The unit panel's
  *Specialize* trades "nearest work" for "cross the camp for my craft", and
  its *role* picker (generalist through steward) biases claim scoring
  toward the role's job types.
- **Health is per-part**: head and torso are vital, arms work, legs move;
  wounds record kind, severity, bleed and care on a part, and part loss
  reprices the unit — a destroyed leg downs it, a destroyed vital kills.
  Bleeding is the clock. Tending anywhere stops bleeding (field care); a
  tend on a medical-flagged bed treats; a tend that burns a *heal-all*
  bundle seals wounds — and the wild herb is a farmable species. Wounds can
  fester into infections the surgeon's bills answer (`treat_infection`,
  `amputate`), and each patient's medicine policy says how much herb a
  doctor may spend. Downed units get `RESCUE`d — literally hauled, subject
  to the same drag limits — to a claimed bed. Death drops a corpse item;
  `BURY` jobs fill designated graves, and grief eases by visiting them.
- **Comfort**: units read the room/ambient temperature against their
  comfort band — exposure thoughts, then real harm — and garments extend
  the band. Darkness costs work and move speed and a thought; lit rooms,
  lamps and fires lift all three. Room smoke builds up and hurts lungs.
- **Drafting and combat**: the Draft checkbox is a stance — a drafted unit
  holds a post, ignores needs until its bravery-scaled floor, and takes
  `RMB` orders: attack the marked animal or hostile (a berserk settler
  counts), wreck the aimed construction, move to the cell. `Shift`-click
  squads order together; an idle drafted post auto-charges anything that
  turns hostile nearby; being hit turns any unit on its attacker. Fists
  tick the species' melee dps at contact; wielded weapons replace it — a
  spear raises the dps and opens stabs, a hunting bow stands off and
  shoots down clear lines with a range-falloff hit chance, overshooting
  onto whatever stands past the mark. Cover — mounds, barricades, fences —
  soaks the melee splash that erodes it mid-fight; spike traps spring once
  on whoever steps in.
- **Arrivals and departures**: the roster grows RimWorld-style — wanderers
  walk in off the map edge on a mood-scaled daily roll (a large roster
  chokes it), hurt strangers collapse at the rim for rescue-and-recruit,
  and a refused or unhappy guest walks back off. New settlers spawn at the
  periphery on the scenario's entry rule. A settler sent off-site travels
  the meso layer and walks into the destination's roster — or founds the
  dormant site waiting there.

### The living world

- **Trees** grow real voxels — trunk and branches solid, saplings and the
  leaf canopy tracked decorations units path through. Generated terrain
  seeds them at mixed ages. *Chop tree* designates the whole tree from any
  part: the unit works the root to the tree's summed hardness, then
  everything fells at once — a log per trunk voxel plus loose branch and
  leaf material. Mature trees drop one fruit per leaf block every five
  game-days (oaks scatter acorns); damaged trees yield by their remaining
  health and die to standing snags.
- **Plants** are single-cell decorations with the same record model —
  berry bushes, wheat, cotton, the heal-all herb, cave mushrooms (the
  dark-farming crop that wants shade). They grow by a light × fertility ×
  temperature multiplier, accrue stress in darkness and glare, take damage
  from heat/cold/fire/trampling, and die to compostable corpses. *Forage*
  strips a ripe bush's yield into physical items; *Cut plant* takes the
  plant itself.
- **Fruit, seeds and decay**: *Extract seed* presses a fruit into two
  species-tagged seed packets (wheat heads feed themselves back). Organic
  items rot stochastically at per-material rates — compost fractions
  return, a fruit rotting on soil can sprout its species — and a second
  weathering axis erodes anything left under open sky (roof the goods you
  care about; a cold room freezes the clock).
- **Grass** is a coverage layer, not a block: it tramples underfoot, dies
  under construction, regrows and spreads, and it's what herbivores graze.
- **Farming**: *Farm field* zones assign any crop — field scans post `SOW`
  jobs where the crop fits and a species-matched seed packet exists, ripe
  shrubs harvest through ordinary forage, annuals (wheat, cotton) die to
  their harvest and re-sow, perennials bear forever, auto-chop fells mature
  timber, and a fertilize target posts `FERTILIZE` jobs that shovel
  compost into the soil. Compost bins rot refuse three times faster.
- **Wildlife** is a species table — mass, temperament, diet, speed, yields —
  wandering the map, grazing the grass, fleeing or fighting by temperament,
  repopulating daily from the map edge; carnivores hunt live prey. *Hunt*
  designates a quarry for melee (or a held bow); the corpse is a physical,
  rotting, drag-gated item the butcher spot cuts into meat, leather, bone
  and species extras — scraps rot to compost, volume conserved end to end.
- **Taming and livestock**: *Tame* designates a wild mark — repeated baited
  sessions bank trust until the animal turns `domestic`, and a failed
  session on a fighter turns it manhunter instead. Domestic animals hold
  inside their allowed area — a wooden fence is a pen rail a settler hops
  but an animal won't — and eat pasture grass or piled feed. The tribal
  start lands with three tame boars.
- **Fire** is a per-cell ledger: lightning (today's only igniter) catches a
  cell whose contents — grass, bushes, trees, wooden constructions —
  carry flammability; spread is per-face per tick against both cells'
  flammability, climbing but never sinking; wet ground resists and
  precipitation triples burn-down. Burning eats fuel locally (grass burns
  off into a natural firebreak, buildings take hp damage, flammable blocks
  burn to nothing) and leaves ash the `CLEAN` crews scrub on home cells.
  Every lit cell posts an urgent `FIREFIGHT` bill — beat the cell out
  before it spreads.
- **The sim underneath**: `DelveSim` is the native voxel mirror — sparse
  16³ chunks materialized lazily (deterministic generation + recorded
  edits), the pile-fill map, the A*, ladder cells, water layers, pile
  flight and a kinematic unit-step channel both units and animals share.
  `Unit`/`Animal` nodes snap to sim positions; the job decision machinery
  still ticks in GDScript.

### Persistence and debugging

- **Saves** are slots under `user://saves/` — a `world.json` (seed, globe
  options, planet clock, travel parties) plus one `region_<x>_<z>.json`
  per region tile (edit log replayed over deterministic regen, plus each
  site's colony payload). `VoxelStreamSQLite` backs the terrain itself:
  one durable store per globe tile, so same-tile sites share contiguous
  voxel space and different tiles never collide. Autosaves land in their
  own slot on a configurable cadence; the title screen and the in-game
  Save/Load card read the same slot list.
- **Filter presets** (`user://filter_presets.json`) and **options**
  (`user://options.cfg`) are per-user, riding across saves.
- **Debugging**: `DLog` (`user://delve_debug.log`) and the native mirror's
  `user://delve_native.log` are crash-surviving breadcrumb logs; `F9`
  dumps every unit's ~96-entry decision trail to the clipboard and
  `user://unit_diagnostics.txt` for behaviour bugs.

## Next steps this scaffold is shaped for

- The stubbed surface: turrets in the Security menu, the Factions and
  History tabs, and the boundary-edge visitors/invaders the colony bounds
  were built for — raids are the missing pressure on everything above.
- Richer water and climate: momentum/pressure beyond gravity order,
  terrain freezing, erosion and sediment, circulation and orographic lift
  in the planet's fields, wind and a forecast readout.
- More of the knowledge web: manuals, trade, and the strata that are still
  implicit freebies; predators that stalk settlers, reproduction and the
  deeper animal systems the species table anticipates.
- Moving the remaining presentation couplings — the unit state machine,
  item/pile object semantics — into `DelveSim` so dormant sites tick fully
  headless.
