# Delve — Design Notes

Working design document for the colony-sim framework. It records the decisions
made so far and the reasoning behind them, so future changes can tell the
difference between an invariant and an implementation detail.

For setup, controls and file layout see [README.md](README.md). The regression
gate is `scripts/tests/smoke_test.gd`.

## Pillars

- **The player directs, units work.** The overseer never touches a block; all
  world changes flow through the job board.
- **The voxel grid is the truth.** Reach, occupancy, pathing and drops are all
  defined per-voxel; nothing depends on mesh appearance.
- **Matter is conserved and visible.** Mining produces physical item piles with
  exact volume accounting — resources exist in the world until hauled.

## Engine and architecture

- **Godot 4 + Zylann's Voxel Tools** (v1.7, Godot 4.7.2). Voxel Tools is a C++
  module, so the project requires the custom build in `bin/`; a stock Godot
  editor cannot parse `VoxelTerrain`, `VoxelBuffer`, etc.
- **`BlockRegistry` is the single source of truth** for blocks. `BLOCKS` order
  defines both the voxel ids stored in `VoxelBuffer.CHANNEL_TYPE` and the model
  indices in the `VoxelBlockyLibrary` — treat it as a save format: append, never
  reorder.
- **`VoxelMesherBlocky`** (opaque cubes) is deliberate: it keeps mining discrete
  and makes "one click = one voxel = one drop" literal.
- The generator is a GDScript `VoxelGeneratorScript` (`WorldGenerator`) that
  delegates `_generate_block` to a compiled `DelveGenerator` (GDExtension,
  `native/`) when the extension is built — voxel-for-voxel identical, ~6×
  faster per block. The script must stay the shell: `is_runnable()` requires
  a `Script`, so an extension object alone can't drive streaming.
- **`DelveSim`** (same extension) is the native voxel mirror for the sim's
  hot path: sparse 16³ chunks of block ids materialized lazily on first
  query (deterministic generator + recorded edits, so streamed terrain the
  sim never touches is free), a voxel→cm³ pile-fill map pushed by `Colony`
  (packed derives from fill ≥ 1 m³, matching the integer volume model), and
  a loaded-block set standing in for `is_area_editable`. `world.is_solid`/
  `is_standable`/`find_path` prefer it; `VoxelTool` and
  `VoxelAStarGrid3D` remain the fallbacks. Its A* replicates
  `VoxelAStarGrid3D`'s movement rules (8-dir, +1 jump, 3-cell falls,
  1×2×1 fit), can route around packed piles via
  `find_path(..., avoid_packed=true)`, and adds ladder climb/descend
  edges off `Colony`-pushed ladder cells (see Ladders under Units and
  jobs). Pathfinding is bounded the way the
  GDScript `AStarGrid3D` region was — the endpoints' box plus a 24-cell
  margin — which matches the boundary rule below: pathing never roams
  past the colony edge. Two backstops keep pathological (unreachable)
  searches cheap: a 65,536-node expansion cap and a 48-chunk materialize
  budget per call — budget-exhausted cells read as solid so a search
  can't route through terrain it wasn't allowed to generate. The item
  spill/settle searches —
  `spill_target`, `settle_floor`, `accepting_voxel` (the bounded BFS) —
  are ported too: `Colony` keeps item semantics, the mirror does the
  walking. A job board (`job_add`/`job_drop`/`job_claim`) indexes
  claim-relevant `ColonyJob` state — the same skill/languish scoring and
  fresh-over-retry tiers — so `claim_job` is one native call; the
  `ColonyJob` objects stay authoritative for payload fields. Edits sync
  at `mine`/`place`/`remove_voxel`; `block_unloaded` erases the chunk
  (the terrain forgets edits, so the mirror must too).
- **The colony occupies a bounded, expandable play area** — initially on the
  order of 100×100 voxels, growing in ~50×50 chunks via a progression
  mechanic. The player cannot designate, mine or build outside the current
  boundary; the overseer may look a modest distance past it, and visitors or
  invaders (not yet implemented) appear at its edge. Nothing outside the
  boundary plus camera margin is simulated at the voxel level.
- **Simulation is decoupled from presentation — the sim runs headless.**
  Multiple colony sites are a stated goal, and each site must tick
  identically whether or not the overseer is present. So no logical
  progress may depend on instantiated presentation: pile flight, unit
  motion and job flow live in (or migrate toward) the sim; `ItemPile`
  nodes, `CharacterBody3D` bodies and `MultiMesh` scatter become pure
  visuals that mirror sim state when they exist at all. `DelveSim.tick`
  is the per-site heartbeat — it owns pile-flight timing, and unit
  *motion* is already sim-side: `unit_step` is a kinematic capsule move
  against the voxel mirror (fill-aware support heights, axis-slide,
  soft unit separation, head-on hit reporting for yields) that replaced
  `move_and_slide`. Measured effect at 50 units: physics step 6.3 →
  1.7 ms, per-unit script tick 40 → 8.8 µs. `Unit` nodes snap to sim
  positions — presentation interpolation can layer on if the sim tick
  rate ever decouples from rendering. Remaining presentation couplings:
  the unit state machine itself (job decisions still tick in GDScript)
  and item/pile object semantics.
- **The local map embeds in a coarser regional map.** The regional
  heightfield seeds local terrain generation (regional base height plus
  local detail noise), and significant local edits aggregate back into the
  regional map. See "Colony bounds and the regional map" below.

## Terminology

Workers are **units** (renamed from "colonists" — files, classes, input
actions, UI). "Colonist" should not reappear in new code.

## Terrain generation

`world_generator.gd`, all parameters exported and tunable.

- Rolling surface from 2D simplex height noise (`base_height` 32 ± amplitude 18),
  a 4-voxel dirt band over stone, hard floor at `bedrock_height` −64. The
  surface is plain dirt — grass is a decoration layer (see *Grass cover*
  below), never a voxel.
- **Rock outcrops**: a separate 2D `_rock_noise` raises the per-column rock top.
  Above `outcrop_threshold` (0.45) the rock ramps linearly from the normal
  `surface − soil_depth` up to `surface + outcrop_protrusion` (7). Measured on
  the shipped seed: ~9% of columns get rock intruding into the soil band,
  ~1.3% get stone exposed at or above the surface. Outcrops carry no ore
  (ore depth is measured from the grass line) and can host caves.
- **Caves**: `|noise| < 0.05`, suppressed within 2 voxels of the top so the
  surface doesn't get potholes.
- **Ores** are depth-gated, rarest first: coal ≥ 4 deep, iron ≥ 12, gold ≥ 28.
- **Saplings**: one jittered lattice slot per `tree_cell_size`² patch (8×8
  columns), half of patches seeded, on grass columns only
  (`grass > rock_top` — never on bare rock).
  Nothing is written to the voxel data — `sapling_species_at(x, z)` is the
  deterministic predicate `Forest` consults as chunks stream in, placing a
  decoration at `top + 1` (so `surface_height() + 1` is where they sit).
- **Invariants**: `surface_height()` returns the *true* topmost voxel including
  rock protrusions (spawn placement relies on this), and `_generate_block`'s
  sky early-out adds `outcrop_protrusion` to `max_surface` so tall outcrops
  aren't clipped.

## Colony bounds and the regional map

The colony is confined to a definite play area rather than an endless world.

- **Boundary.** Roughly 100×100 voxels at colony founding, expandable in
  ~50×50 chunks through progression. The boundary gates *edits* — mining,
  building, designation, clearing — not sight: the camera roams a margin past
  it, and terrain still generates in the margin so the world doesn't end in
  a cliff of missing chunks. `is_editable`/`designate_*` are the natural
  choke points for the "inside the colony" check.
- **Simulation scope.** Voxel-level simulation is limited to the boundary
  plus that margin: unit pathing, forest scans, pile/stockpile/job searches
  and eventually the native sim core all operate on a fixed, known volume
  (~100×100×~160 voxels — small enough to keep a flat native mirror of the
  play area rather than hitting `VoxelTerrain` per query). Visitors and
  invaders spawn at boundary-edge columns and path inward.
- **Expansion** widens the edit boundary and the simulated volume together;
  terrain beyond it stays generator-deterministic until claimed.
- **Regional map.** The local map is a detail window into a coarser world
  map. Generation is two-layer: `surface(x,z) = regional_base(x,z) +
  local_detail_noise(x,z)` — the generator samples a regional height source
  (a pluggable interface, flat-stubbed until the map exists; the GDScript
  oracle and `DelveGenerator` must stay parity-identical). Edits propagate
  upward in aggregate: the colony accumulates per-region height/volume
  deltas from mine/place/settle and writes batched updates back, rather than
  mirroring every voxel. Eventually the margin terrain itself can be drawn
  from regional data at lower resolution instead of full voxels.

## The overseer

- **Strategy camera, free cursor** (Timberborn-style): the overseer node is a
  focus point that rides the terrain's surface (`_ride_terrain` eases it
  toward `world.ground_height` — skipping trees — with a `height_settle`
  time constant, so voxel steps glide instead of jolting; a first
  placement or `jump_to` still snaps), and the camera sits on a boom —
  `_yaw` orbits, `_pitch` (~26°–83°) tilts, `_distance` zooms. A ceiling
  over an open focus cell is an overhang: the focus rides the floor
  beneath it; only when the focus is *inside* rock does the surface above
  pull it up a face. There is no mouse capture:
  targeting raycasts from the cursor's screen position every frame, and a
  GUI hover suppresses the highlight. WASD/arrows or the screen edges pan
  the focus, Q/E rotate (Z/C snap 90°), the wheel zooms (a pending drag
  borrows it for extrusion), MMB-drag grab-pans, RMB-drag orbits, Shift
  boosts. Pause/speed/tick live on Space, 1/2/3 and `.`.
- **Actions are tools**: the overseer's abilities are a list (`ACTIONS`:
  mine, chop tree, forage, clear pile, cancel, build dirt/stone/log wall,
  deconstruct, designate stockpile, undesignate stockpile, designate
  crafting spot, place bed, build ladder, spawn unit) —
  `-1` is "no tool": an LMB click then *inspects* — it selects the building
  under the cursor (`_selected` → `selection_changed`) so the HUD's worksite
  panel can offer that site's tasks. LMB applies the selected tool, R cycles,
  holding R past `ACTION_MENU_HOLD` (0.4 s) pops the categorized Architect
  menu (`action_menu_requested` → HUD `PopupMenu`; selection or dismissal
  closes via `popup_hide` → `menu_closed`). Esc or an RMB click aborts a
  pending box, then drops the inspected building, then deselects the tool.
  `cancel` is a tool like the others — LMB paints it over a box; it clears
  the hit voxel and the air layer in front. Adding a verb = one enum entry
  plus a `_perform` case, plus a slot in the HUD's `ARCHITECT_MENU` category.
- **Drag paints a box**: pressing LMB anchors a box on the hit face's
  plane — the face normal picks the locked axis, so aiming along the ground
  paints a horizontal layer (DF-style per-layer digs) and aiming along a
  wall face paints a vertical section. Moving the aim while held promotes
  the press to a drag that commits on release; holding the button past
  `DRAG_HOLD` (0.25 s) makes the box *stick* — it survives the release,
  keeps following the aim, and LMB commits / Esc or an RMB click aborts it.
  Per-voxel validity stays in the `Colony.designate_*` functions, so cells
  the action can't touch are skipped. The cancel tool sweeps both the hit
  layer and the air layer in front of it — clear and stockpile markers live
  a voxel out from the face. Rects clamp to `DRAG_MAX_AXIS` (64) per side.
  `spawn_unit` stays a single click — a box of new units makes no sense.
- **The wheel extrudes a drag into a volume**: while a box is up, the mouse
  wheel (or PgUp/PgDn) extends it along the face normal in either direction
  — scroll down digs into the face, scroll up grows toward the camera. Cells
  the action can't touch are simply skipped on commit.
- **The highlight never z-fights**: while dragging it stretches to cover the
  box plus `HIGHLIGHT_EXPAND` (4 cm) of margin, so its faces never sit
  coplanar with voxel faces; its tint shows coverage, not per-cell validity.
- **The highlight follows the action**: it boxes the voxel the selected action
  would touch (`_action_voxel`) — the hit block for mine, the air voxel in
  front of the face for clear/spawn — and turns red when the action can't act
  there (`_action_valid`: clear needs a pile, spawn needs an unpacked voxel,
  mine needs a solid block). `_perform` refuses invalid targets, so the
  highlight never lies about what a click will do.
- **Pending builds are aimable ghosts**: after the world raycast,
  `_raycast_plans` walks the same ray voxel-by-voxel (Amanatides–Woo)
  looking for a pending build cell while plans are visible — a plan in
  front of the terrain hit becomes the hit (`AimHit`, a writable stand-in
  for the read-only `VoxelRaycastResult`), so a wall can be painted on the
  face of one that isn't built yet and deconstruct can reach it. Terrain
  closer than the plan still wins, and hidden plans don't block the ray.
- **The boom stays overhead**: pitch clamps to `pitch_min`..`pitch_max`
  (26°–83°), so the camera arm rarely dips into terrain. The focus point
  rides the surface — easing toward the ground height over `height_settle`
  (~0.12 s) instead of snapping, so voxel steps, ridges and freshly dug
  pits pull the camera smoothly rather than jolting it — and tree blocks
  don't count as ground, so a canopy never yanks the camera upward.

## The HUD

RimWorld's main screen is the model (`Hud`, a `CanvasLayer` that builds its
controls in code): the map stays the dominant view and the UI lives on the
screen edges.

- **Resources list** top-left: a transparent tally of `stockpile_contents()`
  — one line per material+form on stockpile tiles ("Wood log ×2", "Soil
  1.25 m³"). Click-through; the map behind it stays designatable.
- **Colonist bar** top-center: one button per unit, click jumps the camera
  (`overseer.jump_to`). Rebuilt on `unit_spawned`.
- **Alerts region** top-right: an empty container until systems produce
  alerts.
- **Inspect pane** bottom-left: the selected action, the cell under the
  cursor (block, pile fill, designation), unit/job counts, controls hints
  and the frame-time readout.
- **Menu bar** along the bottom: *Architect* pops the same categorized menu
  R-hold does (Orders, Zones, Structure, Production — plus Furniture/Power/
  Security categories whose entries are disabled stubs), the remaining tabs
  (Work, Assign, Animals, Research, Factions, World, History) are disabled
  stubs, and *Menu* has stubbed Save/Load/Options plus Quit.
- **Toggles + time controls** bottom-right: the Zones toggle hides
  designation markers (`colony.set_markers_visible`) and Colonist bar hides
  the bar; Beauty, Roofs and Home area are stubs. Plans is a third live
  toggle — `set_plans_visible_manual` shows or hides the
  pending-construction ghosts independently of zone markers, and selecting
  a wall tool or Deconstruct turns the view on regardless
  (`set_plans_tool_active`), so plans are always aimable while a planning
  tool is in hand. Pause/1x/3x/6x drive
  `get_tree().paused` + `Engine.time_scale` — Space pauses, 1/2/3 set the
  speed, `.` ticks once (unpause, one physics frame, pause). The date
  readout is live: `DayCycle` advances planet time with game delta (paused
  and speed-scaled automatically) and turns it into this site's local sun
  via latitude/longitude exports — longitude shifts local time, latitude
  tilts the sun's arc. `planet_time` is also the game's clock:
  `DayCycle.game_msec()`/`Colony.game_msec()` hand out game-time
  milliseconds, and every gameplay timer — plant regrow, tree growth
  steps, job retry cool-offs, claim languish, unit blacklists — compares
  against it, so a pause freezes all of them and 3x/6x accelerates them
  exactly like `delta`-driven needs. Species times
  (`growth_seconds`/`regrow_seconds`) are measured in game seconds:
  an oak steps every 5 days (30 to full height) and a berry bush bears
  every 0.675 days — ~2 colonists fed per bush. It steers the directional light's azimuth and a
  twilight ramp on `light_energy`, the sky's energy multiplier, and the
  ambient mix — `ambient_light_sky_contribution` fades to 0 at night so a
  dim constant color (`NIGHT_AMBIENT`) takes over; night reads dark blue,
  not black. A fresh game opens mid-morning (`start_fresh`, ~07:40 local).
  The label shows local day + hour and a "·night" marker. Day length
  (240 s at 1x) is tuned so a unit crosses a normal site and back inside
  daylight.
  Seasons are stubbed at the equinox (`solar_declination_deg = 0`) until
  weather/temperature exist; night work penalties wait on a lighting
  system.
- **Paused is playable**: the overseer and HUD run `PROCESS_MODE_ALWAYS`, so
  the camera keeps panning and designations keep landing while the sim is
  paused — plan-while-paused. The cursor is never captured, so HUD controls
  are always clickable and clicks on panels never reach the world.

## Units and jobs

- `ColonyJob`: work at a voxel (`MINE`, `CLEAR`, `BUILD`, `HAUL`, `CHOP`,
  `CRAFT`, `FURNISH`, `REST`).
  States: pending → assigned → done/cancelled. Jobs never execute
  themselves. `HAUL` is the odd one out — it never goes on the board; a
  unit creates one for itself as an idle fallback so pathing, the reach
  rule and the stuck watchdog work on it unchanged. `REST` is likewise a
  unit-internal job — a tired unit mints one for itself to carry the walk
  to a claimed bed. Jobs that span more than a voxel (a bed is two)
  carry `extra_voxels`, and per-cell lookups (`plan_job_at`,
  `deconstruct_job_at`, `building_at`) resolve any covered cell to the
  job or building.
- `Colony` is the job board: `designate_mine`, `designate_clear`,
  `designate_build`, `designate_chop`, `designate_forage`, `claim_job`
  (best-scoring open job), `release_job`, `complete_job`/`complete_clear`/
  `complete_build`/`complete_chop`/`complete_forage`. Cancelling a
  designation releases the assignee — cancelling any part of a tree
  cancels the chop job at its root.
- **Chopping** (`CHOP` jobs): *chop tree* marks any part of a tree — the
  raycast can't hit a sapling or leaf cell directly (both are air), so the
  overseer also resolves `previous_position` through
  `Forest.tree_root_at`; any hit resolves to the tree's root,
  which is what the unit works. Work is the summed hardness of every voxel
  the tree currently owns (`tree_work`), so a sapling falls in a touch and
  a mature oak takes real labour. Completion fells the *whole* tree at once
  (`fell_tree` → `Forest.fell`): every part voxel is removed and dropped
  where it stood — one `LOG` (0.5 m³ `WOOD`, a whole-item form) per trunk
  voxel, plus loose `BRANCH`/`LEAF` material for the rest — so a taller
  tree yields more logs, and the drops settle and spill like mined loot.
  Mining a tree part directly is refused (`designate_mine` bounces tree
  voxels to the chop path); a tree whose parts vanished outside the
  forest's control finishes the job empty-handed.
- **Clearing** (`CLEAR` jobs): the overseer marks an item-filled voxel; a unit
  paths within reach and empties its pile at `clearing_speed` m³/s. With a
  stockpile that has room, the items are *hauled* — up to `carry_capacity`
  per trip through the same detour machinery a path-blockage uses, walking
  back to keep clearing until the pile is gone. With nowhere to haul, the
  contents are shoveled into adjoining voxels instead — below → emptiest
  side → on top. Clearing shares the mining reach rule, but the target is
  non-solid so the face ray only has to reach the voxel, not hit it
  (`_can_reach_from` parameterises this). If every adjoining voxel is packed
  and no item fits the carry load, the unit gives up and the job goes back
  on the board. Clearing is also the player-facing version of path-shoving:
  same item-moving mechanics, driven by a job instead of an obstruction.
- **Foraging** (`FORAGE` jobs): *forage* marks a ripe berry bush — the
  cell is air the ray passes through, so the overseer resolves
  `previous_position` through `Plants.bush_at`, and only a ripe bush can
  be designated (`can_forage`). Work is the species' `forage_seconds` at
  `mining_speed`; completion calls `Plants.forage`, which takes the yield
  and drops physical `BERRY` items at the bush's cell for the hauling
  pipeline — foraging never removes the plant. A bush dug out or built
  over mid-job is noticed by `bush_at`'s lazy re-validation and finishes
  the job empty-handed.
- **Building** (`BUILD` jobs): the wall tools — *build dirt wall*, *build
  stone wall*, *build log wall* — mark an empty voxel (non-solid,
  non-packed — a partial pile is displaced at placement). A pending wall
  is a *plan*, not terrain: it draws as a ghost marker while plans are
  visible (see Toggles), and since plans are aimable the next wall can be
  designated on top of, beside, or below an unbuilt one — adjacency to
  other plans never matters, only the target cell itself must be free of
  solid, packed items, trees and prior designations. The player picks
  the wall's material up front: the job is ordered as one material
  (`job.material`/`job.block_id` fixed at designation), and each material
  is a *recipe* — `BlockRegistry.WALL_MATERIALS` maps a material class to
  its block and the cm³ of each item form it takes: 1.25 m³ of loose soil
  compacts into a plain dirt block (indistinguishable from natural
  ground), a `STONE_WALL` is exactly nine boulders and ten cobbles (loose
  gravel is too fine to stack), and a `LOG_WALL` is two logs — both a flat
  cubic metre. Building is real hauling: the unit paths to the closest
  pile holding what the recipe still needs — no distance limit, and only
  the ordered material's forms count — shovels up to `carry_capacity`
  (0.5 m³) into its carried load at `clearing_speed`, hauls it back, and
  repeats. A wall whose material runs out waits for more rather than
  becoming a different wall. Delivered items are
  absorbed per-form into `job.delivered` — solids only when they fit
  their form's missing volume, loose soil split to the exact remainder —
  so the wall takes *exactly* its recipe and leftovers drop beside the
  site. A unit that drops the job mid-haul drops its carried load where
  it stands, so matter is conserved. Before
  placing, the builder evicts the voxel: `_occupies_voxel` checks every unit's
  capsule (feet *and* head voxel — a 1.8 m body spans two), idle occupants
  get `yield_to`'d like path-blockers, and an occupant that can't move (or
  won't leave in ~4 s) fails the job rather than being buried. The builder
  can't work from inside the voxel or beneath it — work spots and the reach
  check exclude both, so it never walls its own head in.
- **Buildings remember what they're made of**: a finished construction
  registers a `Building` record in `Colony.buildings` (walls and worksites
  alike) — its kind, the block it sits in, the material class, and the
  exact items absorbed (`job.components`). That record is what makes
  deconstruction lossless and will let building models recolor to their
  material once they exist.
- **Deconstructing** (`DECONSTRUCT` jobs): the *Deconstruct* tool marks a
  construction for teardown — any building whose `deconstructable` flag is
  set. A unit works it for `deconstruct_seconds` (2 s), the block leaves
  the terrain and the record's exact input items drop where it stood: a
  stone wall hands back nine boulders and ten cobbles, a log wall its two
  logs, a crafting spot just disappears. A packed-dirt wall is the one
  exception — tamped soil reads as natural ground, `deconstructable` is
  false, and it has to be mined out instead (mining any wall also works —
  its record dies with the block and the drops are the generic shatter).
  Timberborn-style, the same tool cancels a *pending* plan: clicking a
  ghost cancels its build job outright — nothing stands there yet, so
  there's nothing to take apart.
- **Stockpiles and hauling**: *designate stockpile* marks an empty voxel on
  top of a solid block (`designate_stockpile`; undesignate removes it) — a
  persistent designation in `Colony.stockpiles`, not a job, drawn as a faint
  translucent outline. Each tile carries a *reject-set* of material classes
  (`stockpile_admits`/`set_stockpile_admission`), and the inspect tool's
  click on a tile opens a per-material checkbox panel. Hauling respects the
  filter end to end: a destination must admit at least some of the load
  (`nearest_stockpile_with_room` takes a materials list), fetches carry only
  items the chosen tile stores (`ItemPile.take_up_to` takes an admit
  predicate), and the pour re-checks admission so a mid-haul filter change
  retargets the leftovers. A pile holding rejected material on its own tile
  is itself haulable — rejected contents get evicted to a tile that admits
  them. A destination must also physically fit something: loose material
  shaves into any room, but a solid item needs its whole volume — a
  nearly-full tile that can't take the smallest boulder is blacklisted
  and the next tile tried, or the fetch stalls forever. Idle units
  (`_try_start_haul`, when no job is
  claimable) create a `HAUL` job: path to the nearest pile that wants
  moving, take up to `carry_capacity` — `ItemPile.take_up_to` splits loose
  items and picks whole solids that fit — then path to the nearest
  admitting tile with room for the load and deposit.
  Big piles take several trips; a tile that fills mid-haul is re-picked at
  arrival. Unreachable sources/destinations go on a per-unit `_haul_blacklist`
  so a bad target doesn't livelock the fallback.
  Interrupting a haul drops the carried items where the unit stands — the
  same `abandon_job` drop build jobs use.
- **Crafting**: *designate crafting spot* marks an empty voxel on a solid
  block (`designate_craft_spot`) — the simplest `Building`, a worksite:
  nothing is built and nothing is required, but it lives in
  `Colony.buildings` like a wall, so it deconstructs like one and shows an
  inspect panel when clicked with no tool selected. Worksite tasks aren't
  map-paint orders — they live on the site: the panel gets a button per
  recipe in `Colony.RECIPES` (`designate_craft(spot, recipe)`; one order
  per spot at a time — the spot's outline swaps to the queued look while
  an order is live — and *Cancel order* drops it via `cancel_craft_order`).
  Recipes declare `inputs` per `DropItem.Form`, `outputs`, and a `waste`
  flag; the unit fetches wanted forms from the nearest piles in as many
  trips as it needs — the bed's six planks (600 L) don't fit one carry
  (500 L). Delivered inputs are escrowed into `job.delivered`/
  `job.components` at the worksite; only when the recipe is satisfied does
  `crafting_seconds` (4 s) run — an interrupted order drops carried inputs
  and returns escrowed ones rather than deleting them. Products and the
  consumed-minus-produced balance drop at the spot as loose sawdust: the
  saw yields three planks (20% of the log each) + 40% waste; the bed
  yields one 400 L `BED` kit + 200 L waste — both keep volume conserved.
  A cancel sweep over the spot lifts its queued order but leaves the site
  standing — removing a building is deconstruction's job. A unit
  can't work from inside the spot voxel — like a build site it's excluded
  from the work spots, so products don't drop under its feet.
- **Furniture — the bed**: *Place bed* lives in the Architect menu's
  Furniture category (`designate_bed`). A bed anchors on the air cell in
  front of the hit face and claims the first free horizontal neighbour —
  `_bed_cell_free` requires an editable, unmarked, unbuilt, treeless air
  cell over solid floor, `bed_cells` returns the pair. The `FURNISH` job's
  `extra_voxels` holds the second cell; both get plan markers, so the
  ghost shows under Plans, either cell cancels the whole designation, and
  either cell resolves to the building afterward. A unit fetches a `BED`
  kit from the nearest pile, unpacks it into a two-cell
  `Building.Kind.BED` that holds one sleeper (`occupant`) — the kit drops
  back whole on deconstruction. **The packed-kit fiction is provisional**:
  a placed bed is two voxels of furniture but the uninstalled item is a
  compact 400 L kit so it fits single-voxel stockpiles and carry capacity.
  The alternative is a large-item warehouse zone — `BED_KIT_CM3` and the
  recipe's output volume are the only places the fiction lives, so
  swapping it later is a small change.
- **Ladders — multi-z transition**: *Build ladder* lives under Structure
  (`designate_ladder`): any open air cell, no floor required — a ladder
  hangs, which is what lets a shaft be dug top-down. Construction is the
  craft pipeline in place: the `&"ladder"` recipe carries a `builds` key
  naming `Building.Kind.LADDER`, a unit fetches its three planks through
  the ordinary fetch/escrow flow, and `complete_craft` becomes
  `complete_construct` — the escrowed inputs land on the record, so
  deconstruction hands exactly three planks back. Mechanics live in the
  native sim's `ladders` voxel set: a ladder never blocks its cell, but
  it *supports* — a unit may stand inside a ladder cell (its base is the
  floor) or on the cell above (the ladder's top is the floor), so the
  A*'s neighbour walk gains vertical edges: climb up from inside a
  ladder or into a rung overhead, descend into a rung below. Descent is
  paced — `unit_step`'s `descend_speed` sinks the unit at `climb_speed`
  while a ladder holds the feet cell or the one beneath it, instead of
  freefalling the shaft. Items don't rest on ladders: `is_floor_for`
  sees an empty ladder cell as no floor at all, so a drop falls through
  the whole stack and collects at the bottom rung — a ladder and a pile
  share a cell, but the pile's capacity drops to `LADDER_PILE_CM3`
  (750,000 cm³, three quarters — the ladder claims the rest), enforced
  through `Colony.voxel_capacity`/`DelveSim.capacity_at` and pushed out
  by `_enforce_capacity` on completion. Rendering is provisional — a
  pole centred in the cell (`_ladder_mesh`); whether a wall-hugging
  facing or a freestanding pole shows is a render-time question, since
  both path identically. A packed ladder cell (≥ 750k of items) still
  blocks like any packed voxel — clearing it is a `CLEAR` job.
- **Needs — rest**: while `Colony.needs_enabled` is on, `Unit.energy`
  drains over two thirds of `DayCycle.day_length` awake — the remaining
  third is sleep, which is what "a third of each day" means. Below
  `rest_seek` (25%) a unit stops claiming work and `_start_rest` takes
  over: claim the nearest free bed (`nearest_free_bed` — no occupant, no
  pending teardown), walk to it as a self-issued `REST` job, sleep
  `NORMAL` and refill in a third of a day — or lie down on the spot for
  `POOR` rest, 25% longer, when no bed is free or reachable. Reaching
  energy 0 mid-work `_collapse`s into ground sleep; the job goes back on
  the board first so it can't die on a downed assignee. Waking frees the
  bed's occupant slot; a bed deconstructed out from under its sleeper
  evicts it (`complete_deconstruct` calls `abandon_job`). A sleeping unit
  shows "sleeping"/"sleeping on the ground" in the colonist bar, which
  also carries each unit's energy percent.
- **Needs — hunger**: `Unit.hunger` drains over a `DayCycle.day_length`
  (sleep doesn't pause digestion). Below `food_seek` (30%) an idle unit
  `_start_eat`s: path to the nearest pile holding edible items
  (`nearest_food_pile` — anything whose material has a
  `DropItem.NUTRITION_PER_CM3` entry) as a self-issued `EAT` job, then
  `EATING` takes a `BITE_CM3` bite every `BITE_SECONDS` — consumed where
  it stands, pile shrinking by exactly what was eaten — until full or the
  pile's food runs out, then back to the board. With no reachable food the
  unit keeps working; hunger bottoming out is a *penalty*, not a
  collapse — `_work_rate()` halves every kind of labour progress and
  shovel budget while hunger sits at zero (`STARVING_SPEED`), and an idle
  starving unit captions "starving". Edibility is a material property
  (`DropItem.is_food`/`nutrition_of`), so new foods are a table entry.
- **Status captions**: every unit floats a billboarded, fixed-size
  `Label3D` (`StatusLabel` in `unit.tscn`) above its head, refreshed in
  `_process` from `current_activity()` — the same string the colonist bar
  uses — only when the text changes. Sleepers tint blue, idle/yielding
  units dim, everyone else is white.
- **Yielding**: the astar doesn't know about bodies, so an idle unit standing
  in a corridor physically blocks anyone pathing through. A `MOVING` unit
  with a job that collides head-on with an `IDLE` unit shoves it:
  `yield_to` walks the idle unit to a standable neighbour off the pusher's
  path (`YIELDING` state, ~2 s timeout), then it's idle again. Only idle
  units can be shoved — a unit with a job is already going somewhere — and
  if there's nowhere to step, the pusher's stuck watchdog handles it.
- **Stuck watchdog**: in `MOVING`, a unit tracks its best distance to the job
  site; if it hasn't closed `STUCK_PROGRESS` (0.25 m) for `stuck_timeout` (5 s)
  it drops the assignment via `release_job`. `release_job` records the drop on
  the job (`dropped_by[unit] = {at, n}`), and `claim_job` treats jobs the unit
  failed as a last resort: it only retries one once the retry delay has
  elapsed *and* no other open job exists — a unit always tries a different
  job first. The delay doubles with each consecutive failure
  (`DROPPED_JOB_RETRY_MSEC` 10 s, capped at `DROPPED_JOB_RETRY_MAX_MSEC`
  2 min), so a permanently impossible job goes quiet instead of being
  retried forever. Haul fallback targets (`_haul_blacklist`) use the same
  escalating last-resort records.
- `Unit` is a `CharacterBody3D` state machine: idle → moving → working.
  Deliberately minimal — it is the extension point for needs, skills, hauling.
- Each unit has a `skin_tone` property: a random point on a pale → mid → dark
  ramp (`SKIN_TONE_*` constants), applied in `_ready` to a per-instance copy of
  the body material — the scene's capsule material is shared, so it must be
  duplicated before tinting.

### Skills and job choice

Work taxonomy: `ColonyJob.SKILL_FOR` maps skilled job types to a
`ColonyJob.Skill` — Mining (`MINE`), Construction
(`BUILD`/`DECONSTRUCT`/`FURNISH`), Plants (`CHOP`/`FORAGE`), Crafting
(`CRAFT`). Types absent from the map (`CLEAR`, `HAUL`, `REST`, `EAT`)
are unskilled labour: base speed, no XP. The list is open-ended — new
task kinds extend the enum and the map together.

- **Levels from XP.** A unit stores only XP per skill; level derives
  from it, inverting the linear requirement — X to reach L1, then 2X
  more for L2, 3X for L3 — so reaching L takes `X·L(L+1)/2` cumulative
  XP and `level = ⌊(√(1+8·xp/X) − 1)/2⌋`. `_finish_job` grants the
  assignee `ColonyJob.XP_FOR[type]` — flat per job type until balancing
  calls for per-task scales.
- **Speed.** `skill_rate = 2^(level/10)`: L10 ≈ 2×, L20 ≈ 4×. It folds
  into `_work_rate` alongside the starving penalty, so every labour
  kind — mining, clearing, crafting, felling — speeds up uniformly.
- **Claim scoring.** `claim_job` picks the lowest score, all terms in
  metres-equivalent:
  `dist·CLAIM_DIST_WEIGHT − level·weight − age·CLAIM_LANGUISH_RATE`.
  The skill `weight` is the unit's stance — `specialize` (per-unit
  toggle on the colonist panel) swaps `CLAIM_SKILL_GENERALIZE` for
  `CLAIM_SKILL_SPECIALIZE`, turning a mild preference into expertise
  that crosses the camp. The languish term caps at
  `CLAIM_LANGUISH_CAP` seconds: a waiting job grows steadily more
  attractive, the anti-starvation pressure that keeps unskilled
  busywork from languishing under a camp of specialists. `HAUL` needs
  no term — it never hits the board; any idle unit with nothing
  claimable hauls.
- **Native parity.** The mirror's `JobRecord` carries `job_type` and
  `posted_ms` so `job_claim` scores identically in one call;
  `job_set_posted` exists to restore a job's age (saves, tests).
- **Attribute seam.** `skill_gain_rate` (currently 1.0) and
  `_work_rate` are the two hook points where attributes — aptitude,
  focus — will modulate learning and labour when that system lands.

### The mining reach rule

A unit may mine a block iff:

1. its centre is within `mine_reach` (1.5 m) of the **nearest point on the
   block's AABB**, and
2. a raycast to that point hits the target voxel first — nothing behind,
   above or below another solid block relative to the unit.

`_work_spots()` selects pathing destinations by evaluating the *same* predicate
from each candidate's stand position, so the planner and the mining gate can
never disagree. A cell holding a partial pile **is** a work spot: the unit
stands on the fill's surface, so reach is measured from an eye lifted by the
fill height — otherwise a pile ringed by other piles (the middle of a dense
stockpile) would have no reachable spot at all and its contents could never be
fetched, hauled, or eaten. `is_unit_standable`/`_is_standable` treat a partial
pile as its own support, with the headroom check lifted accordingly (the
yield sidestep still prefers clean cells). Units are 1.8 m tall,
0.9 m across; consequence: a unit on flat ground can dig the surface diagonally
below its feet (face distance ≈ 1.0 m).

Two latent engine bugs this rule exposed, now fixed: `VoxelAStarGrid3D.find_path`
omits the destination voxel (`VoxelWorld.find_path` appends it), and
`jump_speed` 6.0 gave a 0.82 m apex — below the 1 m steps the astar routes over;
now 7.5 (≈1.28 m apex).

## Structural support

A solid block stays up iff a face-adjacent chain of solids connects it to the
**base level** (`bedrock_height`, −64) — diagonal neighbours don't transmit
support. Tree blocks anchor themselves, so a felled trunk never pulls its own
canopy down as "unsupported". Because only a removal can break a chain, the
check is **event-driven**: `VoxelWorld.mine`/`remove_voxel` call
`DelveSim.collapse_check`, which floods each solid neighbour of the removed
cell — a `seen`/`anchored` pair of sets keeps components from being re-proven,
and the flood is best-first by lowest y so anchored terrain reaches bedrock in
~depth pops while a detached blob exhausts quickly. A neighbour outside
editable bounds *can't disprove* a chain running through unstreamed terrain, so
the frontier anchors conservatively; a flood past `MAX_COLLAPSE_FLOOD` (16384)
does the same rather than burning the frame. Each condemned cell comes out via
`block_collapsed` — colony-side it cancels that cell's jobs, erases building
records, drops the mined-equivalent rubble in place, and settles whatever was
piled on top.

Placement flips the check around: since every standing solid is already
anchored, a candidate cell needs exactly one solid face-neighbour to be
supported (`Colony.would_be_supported`). A build job that finishes its escrow
on an unsupported cell **suspends** — designation marker stays up, escrowed
material stays in the job, `ColonyJob.suspended` removes it from both the
GDScript and native claim pools — and `block_placed` lifts the flag on the six
cells adjacent to each new block. Plans may still be designated floating: the
support a stacked plan needs might itself be a pending build, so judgement
belongs at placement time, not at the designating click.

## Trees and the forest

`forest.gd` (a `Colony` child) tracks every tree as a record keyed by its
root voxel: `{species, height, voxels, next}`. The record is the authority
on which cells belong to the tree — an index maps every part (solid or
decoration) back to its root, `tree_root_at` re-validates on lookup so
parts removed outside the forest's control drop out lazily, and a missing
root fells whatever remains.

- **Decorations, not voxels**: only `TRUNK` and `BRANCH` are real blocks
  (appended to `BLOCKS` — never reorder, ids are the save format) — both
  solid, both movement blockers. Saplings and leaves are tracked cells the
  forest renders with `MultiMeshInstance3D`s — leaf boxes are
  sub-voxel-sized and offset to hug the side of their cell nearest a solid
  part of the tree. Their voxels stay `AIR`, so
  the astar, reach checks and physics treat them as empty. That sidesteps
  `VoxelAStarGrid3D`'s every-non-air-is-solid rule entirely — a unit paths
  straight through a sapling or the canopy.
- **Discovery**: the generator writes no blocks; `block_loaded` (block-grid
  coordinates, ×16) sweeps each column through `sapling_species_at` — the
  generator's own deterministic lattice — and registers hits at
  `predicted_surface_height + 1`. The same pass **restores tree voxels**:
  nothing persists terrain edits across streaming, so a regenerated block
  lacks the trunks the records still claim — reapplying the structure
  before the next growth tick is what keeps a streamed-in canopy from
  being read as a destroyed tree and felled into falling debris.
  `_destroyed` keeps a felled sapling slot from respawning; `is_editable`
  gates growth while a chunk is out. A generated slot seeds at a random
  age — `seeded_height` hashes the root into 0–`max_height`, so a fresh
  world opens with log-bearing trees to harvest rather than a lawn of
  saplings, and a reloaded slot reseeds identically. Seeded small plants
  should follow the same rule. Only generated terrain ages this way —
  `plant_sapling` still starts at zero.
- **Growth**: a per-tree timer (`growth_seconds`, hash-staggered) adds one
  trunk level at a time up to `max_height`. Each level's structure is
  deterministic — `_structure` maps the wanted solid voxel → block id, with
  side branches every `branch_every` levels past `branch_min_level` and,
  once tall enough, branch arms off the tip carrying a diamond leaf
  canopy. Every leaf cell must face-touch a trunk or branch — nothing
  floats detached — and nothing hangs at or below the ground-level trunk
  segment. Solid parts only grow into
  open, unoccupied, item-free air; leaf cells need air and no other tree's
  claim — so a stunted branch stays stunted. A tree will never grow into a
  unit (`Unit.occupies` spans the capsule's two voxels). A sapling becoming
  a trunk just swaps its decoration for a voxel.
- **Species** are a `SPECIES` table keyed by name — block set, height, pace,
  branching, decoration colours, work and drop volumes. Only oak exists;
  adding one is a table entry plus its blocks.
- **Felling** clears every voxel and decoration cell the tree owns and drops
  each where it stood: a `LOG` per trunk voxel (`DropItem.Form.LOG` — a
  whole item, rendered as a stretched box in piles), loose `BRANCH`/`LEAF`
  volumes for the rest. Everything goes through `_drop_item`, so debris
  spills and settles like mined loot.

## Small plants

`plants.gd` (a `Colony` child, next to `Forest`) tracks forageable plants
as single-cell records: `root → {species, ripe, next}`, with the same
index-and-lazy-validation pattern `tree_root_at` uses — a cell dug out or
built over is noticed on lookup and marked `_destroyed` so the
deterministic lattice can't respawn it.

- **Decoration, not voxel**: a bush's cell stays `AIR`; the plant renders
  as a sub-voxel box through one `MultiMeshInstance3D`, tinted by state —
  ripeness shifts toward the species' fruit colour so a forageable plant
  reads at a glance. Pathing, reach and physics see empty air.
- **Discovery**: `block_loaded` sweeps each chunk through the generator's
  `bushes_in` — the same lattice walk as `saplings_in` on its own coarser
  grid, grass columns only — and registers hits at `surface_height + 1`.
  Generated slots start at *mixed ripeness* (`seeded_ripe`, hashed off the
  root so a reload reseeds identically): the same mixed-age rule trees
  follow, so a fresh world opens with food to forage.
- **Forage and regrow**: `Plants.forage` hands back the species' yield
  items and starts the regrow timer (`regrow_seconds`); the bush sits
  unripe until the clock ripens it again, so a berry bush is a renewable
  stand, not a one-shot pickup. `SPECIES` is the extension table — name,
  colours, yield material/volume, work and regrow seconds — modelled to
  grow into the farmed-crop layer.

## Fruit, decay and sprouting

Plant life produces physical items, and plant-derived items rot back out
of the world — the loop keeps litter bounded and lets vegetation spread
slowly without any designation.

- **Tree fruit**: on a mature tree's five-game-day growth tick (the same
  `growth_seconds` step it already wakes for) it drops one fruit item
  per leaf block — the oak's is the acorn. Each fruit falls from its
  canopy voxel and settles through ordinary pile gravity, so the yield
  scatters around the base rather than arriving as a tidy stack. Bushes
  never drop fruit — theirs is collected by FORAGE (or HARVEST, when it
  exists). Fruit is a discrete `Form.FRUIT` item whose material is the
  species' fruit material (`ACORN`); `DropItem.FRUIT_SPECIES` maps it
  back to the species that bears it.
- **Seed extraction**: `extract_seed` is an ordinary recipe in
  `Colony.RECIPES` — one fruit to two `Form.SEED` packets at a crafting
  spot — so it rides the whole CRAFT pipeline: fetch, escrow, work
  seconds, Crafting skill rate and XP. The packet's `species` field
  carries the fruit's lineage (oak acorns → oak seeds) — the seam
  farming will read when sowing exists — and the recipe's
  `output_material` override is the hook a dedicated seed building will
  reuse to do the job better.
- **Organic decay**: `Colony._decay_tick` sweeps every landed pile each
  `DECAY_TICK_SEC` game-seconds (so pause and time-scale just work). Per
  material, `DropItem.DECAY_RULES` names a mean lifetime and a compost
  fraction: fruit 10 d, leaves and sawdust (loose wood) 15 d at ¼,
  branches 60 d at ½, seeds and compost itself 60 d to nothing, logs
  120 d at ½; planks are cured and minerals never rot. Bulk stacks shed
  a Poisson number of `DECAY_QUANTUM_CM3` chunks per sweep — no per-item
  ages, no slivers: a roll covering nearly all of a stack takes the
  whole thing — while discrete items rot whole at a `dt/life` chance
  per sweep. Compost materializes inside the same pile.
- **Sprouting**: when the last volume of a fruit item rots over soil
  (`DIRT`), it rolls `DECAY_SPROUT_CHANCE` (5%) to plant its
  species — a sapling for tree fruit, an immature bush otherwise. A
  sapling demands its cell and all eight neighbours free of trees and
  bushes; a bush only needs its own cell. At 5% per rotted fruit the
  treeline creeps rather than spreads.
- **Planned extensions** (PLAN.md item 20): growth modulated by daylight,
  weather, soil type and per-block fertility — with compost as the
  fertility input — plus maximum tree age, dead standing trunks and
  deciduous leaf drop under weather.

## Grass cover

`grass.gd` (PLAN item 12): grass is a decoration layer over plain dirt,
the forest's sapling model applied per surface cell — the voxel stays
`DIRT` (mined grass yields soil, no grass item exists) and a per-cell
coverage float renders as a `MultiMeshInstance3D` slab that shrinks and
browns as cover thins.

- **Seeding**: `block_loaded` consults the generator's `grass_seed_at`
  oracle — deterministic, soil-topped columns only (rock outcrops grow
  none) — and records mixed coverage (0.4–1.0), the small-plants rule.
- **Death**: cover dies with its block (`block_mined`/`block_collapsed`)
  or when its top face is buried — by a placed block (`block_placed`),
  a registered building footprint (`register_building` bares the cell
  under each footprint cell, so walls, beds, worksites and ladders all
  count), or a packed pile.
- **Trampling**: a grounded unit pays `TRAMPLE_WEAR` (0.2) per entry
  into a cell's column — keyed on ground-cell changes, so standing
  still never grinds — so ~5 crossings bare a healthy patch.
- **Regrowth and spread**: a rotating scan slice visits each record
  every few game-seconds; thin cover regrows `REGROW_STEP` a visit, and
  a lush cell (≥ `SPREAD_MIN`) occasionally seeds a bare eligible
  neighbour — stepping up or down a level for terraces.
- **Persistence**: records are never erased — a zeroed cell tombstones
  "seen, currently bare" — so trampled paths and demolished floors
  don't reseed on stream-in. The coverage float is the seam grazing
  will read.
- **Performance**: the scan processes `SCAN_SLICE` records per tick
  rather than the whole map, and the multimesh rebuilds only when a
  cell crosses a coverage band — constant per-tick cost regardless of
  map size.

## Drops, piles and gravity

The most worked-through subsystem; treat the numbers as fixed rules.

- **125% rule**: a mined block drops items totalling exactly 1.25 m³, all with
  the block's material class. Soft material → one loose item. Hard material →
  3–9 boulders (0.1 m³) + 5–30 cobbles (0.01 m³) + one loose gravel balance;
  the ranges are bounded so the balance is always positive. (The count ranges
  are the one arbitrary knob — user specified volumes, not distribution.)
- **`DropItem`** is the data (`material`, `form`, `volume`, `RefCounted`);
  **`ItemPile`** is the world entity rendering one voxel's items. `Colony.
  item_piles` maps `Vector3i → ItemPile`; piles at the same voxel merge.
  Edibility is a material property: `NUTRITION_PER_CM3` maps a material
  class to hunger restored per cm³ eaten (`is_food`/`nutrition_of`) —
  berries are the first entry, so food is just another physical item the
  pile pipeline already knows how to hold, spill and haul.
- **Piles stay in the world** — nothing teleports to storage; items move only
  when a unit physically hauls them to a stockpile (see above).

### Spilling

When an item is dropped into a voxel, spill probability =
`occupancy + 0.5 × item.volume` (voxel = 1 m³, so volumes are portions).

- Loose item: splits — fraction `p` moves on, rest deposits.
- Solid item: moves whole with probability `p`.
- Spill target: the voxel below if it has room, else a random orthogonal side.
- Solid voxels count as occupancy 1.0, and full voxels are skipped as targets —
  both are needed for termination (a solid voxel would eject forever).
- Guards: `MAX_SPILL_HOPS = 16`; loose fragments < `MIN_LOOSE_VOLUME` (0.01 m³)
  settle without splitting. If every neighbour is full the item squeezes in
  anyway — piles can exceed 1 m³, occupancy just saturates.

### Settling

Piles never hover. Every deposit settles, and `block_mined` triggers a settle
of the voxel above: the pile steps down through open voxels until it rests on
a floor, stopping at the edge of loaded terrain (`is_editable`) rather than
falling into the void.

A voxel counts as a floor for what's falling onto it (`_is_floor_for`) when
it is *packed* — a solid block or a full pile — or when it holds a pile the
incoming material can't merge into. Loose material can always pour into a
pile with any room left, since the surplus just overflows back onto it; but
an unsplittable item that doesn't fit the pile below rests on top of it
instead — otherwise it would fall in, overfill the pile, be pushed straight
back out by `_enforce_capacity`, and bounce between the two voxels forever.

**Logic is instant, visuals lag.** `item_piles` re-keys to the landing voxel
immediately (occupancy/spill stay correct), while the `ItemPile` node animates
downward with gravity (`FALL_GRAVITY`, capped at `FALL_SPEED_MAX`) and emits
`landed` on arrival. If the landing voxel already has a pile, the falling pile
is held in `Colony._in_flight` — unkeyed — and merges on arrival, so rubble
visibly lands *on* the heap instead of teleporting into it. A pile whose floor
vanishes mid-flight re-settles when it lands. Freshly deposited items also
tween down ~1 voxel into their pile slot (`_drop_in`), except merged items,
which were already visually in place.

Watch out: a mid-flight merge means `item_piles` briefly omits the falling
pile's volume — tests must drain `_in_flight` before tallying.

### Fill is floor

A voxel's effective floor level is its item fill: `Colony.voxel_fill()` reports
the occupied portion (1.0 for a solid block), and `is_packed()` marks fill
≥ 1 m³ (`ItemPile.is_full`, `FULL_EPSILON` slack) as *effectively solid*.
Consequences:

- `ItemPile` carries a `StaticBody3D` box as tall as its contents, so units
  physically stand on piles and packed piles are real walls.
- A packed pile renders as a slightly-inset solid cube tinted by its material
  class (the inset avoids z-fighting neighbouring voxel faces) instead of the
  scattered-item look — solidity is visible, not just simulated.
- Packed piles are obstructions, not walls: a unit whose path crosses one walks
  up to it and *shoves* — moving items, smallest first, into the voxel below or
  the emptiest side until fill drops below full. Clear paths are preferred when
  repathing; a pile-crossing path is only taken when no clear one exists. If
  every neighbour is packed too, the shove fails and the stuck watchdog drops
  the job. Shoved items go through the normal deposit path, so they settle and
  spill — and a pile left hovering above the cleared voxel falls in, so digging
  through a two-deep pile drains it gradually.
- Obstructed units haul before they shove: when a packed pile sits on a job's
  path and a stockpile has room, the unit *detours* — borrowing the goal/path
  machinery, so the reach rule, repathing and the stuck watchdog all still
  apply — loads up to `carry_capacity` (0.5 m³) from the blockage, delivers it
  to the stockpile, then repaths to the real job and resumes it. A blocked
  detour goal joins the haul blacklist (with the same escalating retry), any
  load taken is dropped where the unit stands, and the pile goes back to being
  a shove target. With no stockpile room, the shove is the only option — the
  detour exists to turn a scatter into storage, not to replace the scatter.
- Settling treats packed voxels as floor — items land *on top of* a packed
  pile rather than inside it — and also rests on a pile it can't merge into
  (see `_is_floor_for` under Settling).
- Settling never tunnels: packed voxels are skipped outright as deposit
  candidates in `_accepting_voxel` and don't expand the outward search —
  an item can't be dropped into a solid block or full pile, so it can't
  leak into an open pocket underneath a wall either.
- **The 1 m³ cap is enforced, not assumed**: `_enforce_capacity` runs after
  every deposit and landing merge — a pile over one cubic metre splits, moving
  the excess (smallest items first; loose items split so only the surplus
  leaves) into the same below → emptiest-side → on-top order used elsewhere.
  When no adjoining voxel can take the item, `_accepting_voxel` searches
  outward from the voxel above for the nearest landing spot that fits —
  judged by where the item would *settle*, so a boulder can't be pushed onto
  the voxel above a half-full hole only to fall straight back in and bounce
  forever. The sole exception remains the squeeze-in fallback: a pile can
  exceed 1 m³ only when literally nothing in reach has room.
- **The source stays full while the excess searches**: `_enforce_capacity`
  peeks at the smallest item rather than taking it before `_accepting_voxel`
  runs — an over-full voxel still counts as packed, so the cell above a
  buried pile reads as resting on it and a dug-out hole overflows *upward*
  (1.25 m³ in a walled hole = 1.0 in the hole + 0.25 on the cell above).
  And in `_accepting_voxel`'s BFS, a candidate whose landing falls back into
  the source is skipped as a target but still expands the search — otherwise
  a hole's only open side (up) would wall off the rim and clearing or
  overflowing a buried pile could never move anything out.
- A voxel shared with a ladder is the one exception to the 1 m³ cap:
  `voxel_capacity` reports `LADDER_PILE_CM3` (750,000 cm³) there and the
  same rule lands on every path — deposits, spills, stockpile room and
  the sim's `capacity_at` — so a ladder cell packs at three quarters.
- `Unit._is_blocked`/`_is_standable` and mining occlusion sample `is_packed`:
  a packed voxel can't be stood in, but the voxel above it is standable.
- `VoxelAStarGrid3D` has no obstacle hook (only voxel-id 0 is air), so
  `Unit._repath_to_job` post-validates returned paths: a clear path is always
  preferred, but a pile-crossing one is accepted when nothing else exists —
  the unit detours to haul or shoves the obstruction aside as it reaches it.
  Nothing non-air is ever walkable, which is exactly why saplings and leaves
  live outside the voxel data as decorations.

## Testing posture

`smoke_test.gd` runs headless against the real `main.tscn` and asserts end-to-end
behaviour (spawn → designate → mine → pile) plus controlled-geometry checks:
placed blocks in open air for reach/occlusion, a placed shelf for gravity,
measured-noise scans for outcrops. Prefer deterministic fixtures over RNG
assertions; where the drop table is random, assert conservation and class
invariants instead of counts.

### Crash diagnostics

Two append-per-line logs survive hard crashes and record the sparse events
that precede them. `scripts/dlog.gd` (`DLog`, preloaded — not `class_name`,
so headless `-s` runs don't depend on the class cache) writes
`user://delve_debug.log` with startup, spawn, designation and unit-transition
breadcrumbs; `DelveSim` writes `user://delve_native.log` with `configure`,
unit register/unregister, chunk materialization, `find_path` calls and
pile-flight events. On Windows `user://` maps to
`%APPDATA%\Godot\app_userdata\Delve\`; the engine's own crash backtrace lands
in `logs\godot.log` beside them. After a crash, the last lines of
`delve_native.log` name the subsystem (streaming churn, pathing, unit step)
that was running.

## Open seams

- No persistence yet (`VoxelStreamSQLite` is the drop-in answer).
- Walls are the only buildable blocks so far — dirt, stone and log via
  `WALL_MATERIALS` — but there's no recipe/scaffold system for anything
  fancier (planks, furniture, stairs).
- Stockpile capacity is just voxel fill (1 m³ per tile). Material classes
  filter per tile via the inspect panel — flat checkboxes for now; when the
  material list grows it wants a category layer (soils/stones/woods/ores)
  so the toggle count stays manageable.
- Solids obey structural support: a block stands iff a chain of
  face-adjacent solids connects it to the base level, and every removal
  re-proves the local neighbourhood — a detached body comes down as
  mined rubble (see "Structural support" in the simulation section).
  Floating builds still designate fine; the job suspends at placement
  time until an adjacent placement anchors it.
- Grass coverage isn't persisted beyond in-memory records — a trampled
  or cleared cell stays bare across a reload, but only because the
  record tombstones it; a full save needs the coverage map serialized
  alongside the colony. See PLAN.md item 18.
- Farming will follow the Progression: Agriculture model — physical seed
  bundles packed from harvested produce rather than vanilla RimWorld's
  free seeds — see PLAN.md item 14. The berry bush's `Plants` machinery
  (single-cell records, species table, ripeness, yield drops) is the
  template crops will grow from; fruit-bearing trees already exist —
  oaks drop acorns, and `extract_seed` presses fruit into species-tagged
  seed packets ready for sowing.
