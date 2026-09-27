# Delve — Next Steps Plan

Goal: "RimWorld but in 3D" with Dwarf Fortress influences. Assessed against the
code as of the current commit (job board, mining, hauling, stockpiles and the
item-conservation subsystem all working; see [DESIGN.md](DESIGN.md)).

## Where the project stands

The simulation core is unusually solid for a scaffold: job board, voxel-perfect
mining, matter-conserving item economy (drop/spill/settle/pack/shove),
stockpiles, hauling, and a real regression gate. But measured against the goal,
the loop currently dead-ends: **resources accumulate in stockpiles and nothing
consumes them, and units are robots** — no needs, no economy, no verticality
tooling, one-voxel-at-a-time designations.

## Gaps vs. the goal

### Closed resource loop (biggest gap)

- Logs → planks works now (crafting spot + `CRAFT` job, item 4 below). The
  planks are a discrete item form with no consumer yet — a plank wall or
  furniture tier is the obvious next use.
- Ore → nothing. No smelting yet, and crafting is one hardwired recipe —
  a recipe table and a second recipe (iron ore → iron item) is the open
  part of the loop.
- `stockpiles` are unfiltered (noted in DESIGN.md open seams) — coal and gold
  mix on the same tile.

### Colonist-ness (the RimWorld half)

- Units sleep now (energy/rest, beds — item 7), but still don't eat, have
  no skills, no moods, no schedule. `unit.gd`'s header names this as the
  extension point.
- Pause/1x/3x time controls exist (Space or the bottom-bar buttons), but
  there's no calendar or day/night cycle yet — the date label is a stub.
- `spawn_unit` is a debug verb; RimWorld's version is a wanderer-joins event.

### DF verticality

- Units climb only 1 m steps via `jump_speed`. Dig a 2-deep pit and its floor
  is unreachable forever — no stairs/ramps exist, and `VoxelAStarGrid3D` only
  knows solid-vs-air, so stair support is genuinely non-trivial.
- Only raycast-visible voxels can be designated — no slice view or x-ray for
  planning underground digs.
- Nothing checks structural support: `designate_build` happily queues a
  wall on a fully floating cell, and plans stack on unbuilt ghosts, so a
  floating castle is legal today. Once collapse mechanics exist that's an
  instant cave-in — see item 9 for the open design decision.

### UX

- The HUD is RimWorld-shaped now — resources top-left, colonist bar, bottom
  menu bar with a categorized Architect popup — but most of its tabs and
  toggles are stubs waiting on the systems below (Work, Assign, zones beyond
  stockpiles, furniture/power/security, a calendar).

## Ordered roadmap

1. ~~**Drag-box designation.**~~ **Done.** LMB/RMB press anchors a rect on
   the hit face's plane (ground drags paint horizontal layers, wall drags
   paint vertical sections); release applies the action per voxel, with
   validity checked per cell in `Colony.designate_*`. Cancel drags sweep the
   hit layer plus the air layer in front. `spawn_unit` stays single-click.
   Covered by `_test_drag` in the smoke test.

2. ~~**Trees + CHOP job.**~~ **Done.** `TRUNK`/`BRANCH` blocks (appended to
   `BLOCKS` per the save-format rule) are the only tree voxels — both solid.
   Saplings and leaves are forest-tracked decorations rendered over air
   cells (the generator's `sapling_species_at` predicate seeds them; nothing
   is written to voxel data), so pathing and physics see straight through.
   `forest.gd` ages each tree from sapling to trunk + branches + leaf
   canopy. `designate_chop` resolves any part — including an air-cell
   decoration — to the root; a unit fells the whole tree into one LOG per
   trunk voxel plus loose branch and leaf material. Species are a table —
   only oak so far. Covered by `_test_tree` in the smoke test.

3. ~~**Generalize build materials.**~~ **Done.** *Build wall* became one
   action per material — *build dirt wall*, *build stone wall*, *build log
   wall* — with the player's pick committed at designation
   (`job.material`/`job.block_id`). `BlockRegistry.WALL_MATERIALS` maps each
   wall material class to its block and a per-form recipe — 1.25 m³ loose
   soil → dirt block, nine boulders + ten cobbles → `STONE_WALL`, two logs
   → `LOG_WALL`. Delivered items are recorded per-form (`job.delivered`)
   with the actual items kept in `job.components` — a wall absorbs exactly
   its recipe. New stone/log species slot in as new recipes + actions.
   Pending builds are aimable plans: the aim ray stops on them while plans
   are visible (a HUD toggle, plus auto-on whenever a wall tool or
   Deconstruct is selected), so walls stack on/beside/below unbuilt ones
   and Deconstruct cancels a plan outright.
   Finished constructions register `Building` records (`Colony.buildings`)
   carrying material + inputs, which is what deconstruction returns and what
   later material-tinted models will read. *Deconstruct* is an Orders tool
   for any `deconstructable` building (dirt walls exempt — they read as
   natural ground and mine out instead).

4. ~~**A workshop + CRAFT job.**~~ **Done.** *Designate crafting spot* places
   a worksite — a `Building` that needs no materials — on an empty voxel
   over solid ground. Its tasks live on its inspect panel, not the Orders
   menu: select the spot (no tool → LMB) to order *Craft planks* or cancel
   the order. A unit fetches one whole log from the nearest pile, saws it
   at the spot and drops three discrete `PLANK` items (20% of the log each)
   plus the 40% balance as loose sawdust — all of the log's material.
   Deconstructing removes the site and any queued order. Covered by
   `_test_craft`/`_test_deconstruct`/`_test_hud` in the smoke test.
   Still open: a general recipe table and smelting (iron ore → iron item).

5. ~~**Stockpile filtering.**~~ **Done.** Inspecting a stockpile tile opens
   its admission panel — a checkbox per material class writing into the
   tile's reject-set (`stockpile_admits`/`set_stockpile_admission`). Hauling
   is filter-aware end to end: destinations must admit the load, fetches
   carry only what the chosen tile stores, deposits re-check admission
   mid-haul, and rejected contents on a tile get evicted to an admitting
   tile. Still open: material categories for the toggle list once the
   material table grows.

6. ~~**Time controls + day/night.**~~ **Done.** Pause/1x/3x/6x drive
   `get_tree().paused` + `Engine.time_scale` (Space or the bottom bar; the
   overseer/HUD keep `PROCESS_MODE_ALWAYS` so planning works while paused).
   `DayCycle` runs a real calendar: `planet_time` is a shared global clock
   and each site resolves local solar position from its latitude/longitude
   (sun altitude is latitude-dependent, sunrise/sunset longitude-dependent)
   — sized so a unit crosses a normal colony and back inside one day's
   ~120 s of daylight (240 s days at the equinox track, so daylight is a
   clean half). The HUD date is live. **Still open:**
   work/movement penalties in darkness (blocked on a lighting system),
   seasons/declination (the sun runs the equinox track), weather and
   temperature — none are roadmapped yet. Multi-site is halfway there:
   each site gets its own `DayCycle` exports, and `planet_time` should be
   promoted to a region clock when a second site is active.

7. ~~**Sleep first, then hunger.**~~ **Done (sleep).** Units drain energy
   while awake — a full bar is two thirds of a day — and below `rest_seek`
   (25%) stop taking jobs and rest instead: a free bed (`nearest_free_bed`)
   gives NORMAL rest, refilling in a third of a day; the ground is POOR,
   25% longer. Zero energy collapses a unit into ground sleep mid-work.
   Beds are furniture: crafted at a crafting spot from six planks as a
   *bed kit* (a deliberately compact packed-down item — the fiction that a
   bed fits one stockpile voxel is provisional, see DESIGN.md), then a
   `FURNISH` job unpacks it into a two-horizontal-cell `Building` that
   holds one sleeper (`occupant`). Deconstructing a bed from either cell
   wakes the sleeper and hands the kit back. Covered by `_test_rest` in
   the smoke test. **Still open: hunger** — a forageable berry bush is the
   cheapest version, farming the real one.

8. **Ramps/stairs.** The DF "dig down" fantasy. Hardest item on this list:
   `VoxelAStarGrid3D` treats anything non-air as solid, so this needs either a
   parallel walkability layer feeding `_is_standable`/`_repath_to_job`, or a
   custom astar pass. Worth doing after the economy loop exists.

9. **Collapse mechanics.** A built block with no support comes down —
   gravity for constructions, and the drops/settle/pack machinery already
   exists to land the rubble. **Open decision — what happens to an
   unsupported plan:** today nothing stops a player from designating a
   floating wall, and stacked plans make it easy to design structures
   whose base gets built *after* their upper floors (completion order is
   nearest-first, not bottom-up). Two stances once collapse lands:
   (a) *allow it* — the job completes and the block immediately
   collapses, DF-style "!!fun!!" with conserved rubble; or (b) *guard
   it* — the build suspends or cancels when its support is missing, and
   unsupported plans get flagged at designation or rechecked when a
   neighbor plan is cancelled. The real seam is *when* support is judged:
   designation-time rejection is cheap but wrong for stacked plans (the
   support may be a pending build), so the choice is really between
   checking at placement time vs. letting the collapse system sort it
   out. Whatever the call, plan ghosts already know their neighbors, so a
   "suspended — unsupported" plan state is available if (b) wins.

10. **Skills & job priorities.** `claim_job` is already a scored nearest-first
    selection — adding priority weight and per-unit skill multipliers on
    `mining_speed`/`clearing_speed` is a small diff with outsized RimWorld
    flavor.

11. **Tree growths + organic decay.** Trees should periodically generate
    and drop growths — seeds, fruit, whatever fits the species — that
    decay away so the map doesn't fill with litter. The same decay clock
    should cover *all* organic materials (leaves, branch material, seeds
    rot quickly; logs and branches take a very long time). Once a tech
    tree exists, research can offer ways to slow or halt organic decay.
    Seeds naturally pair with farming: a dropped seed is the cheapest
    path to the "forageable/replantable" food source hunger needs.

12. **Carry limits by item shape + containers.** Rework hauling: a unit
    carries either a *small* volume of loose material (the current
    0.5 m³, possibly smaller) **or** one solid item — one boulder, one
    log, one bed kit — instead of the flat volume cap. Then add
    *containers* (bags, boxes, backpacks): fillable to their own
    capacity — possibly larger than the loose allowance — and haulable
    as a single item under the one-solid rule. That's the throughput
    lever: a backpack full of cobbles beats a bare handful. Open seams:
    whether containers are crafted items, which jobs get to use them,
    and how packing/unpacking a container interacts with stockpile
    filters.

13. **Persistence.** `VoxelStreamSQLite` for terrain plus a colony serializer
    (jobs, `item_piles`, `stockpiles`, unit positions/cargo). Defer until the
    colony state stops churning — every new system above adds save surface.

## Scaling seams to watch

- `nearest_haulable_pile`/`nearest_stockpile_with_room`/`nearest_wall_voxel`
  are linear scans over `item_piles`/`stockpiles` on every idle tick — fine at
  3 units, will need a spatial index at colony scale.
- Each `ItemPile` is a `Node3D` rebuilding `BoxMesh` children per item —
  heavy at hundreds of piles; a shared `MultiMeshInstance3D` or mesh pooling
  is the eventual fix.
- `find_path`'s `margin=24` caps path length at ~48 voxels; long-distance
  hauling will silently fail beyond that.
- Slice/x-ray view (render only up to a y-level) belongs with stairs —
  underground planning is otherwise click-on-face archaeology.

## First milestone

Items **1–3** as one milestone — drag-designate a hillside, trees get chopped,
planks get built — gives a playable "gather → build" loop that everything else
hangs off of.
