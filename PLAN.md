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

- Units work 24/7: no hunger, no sleep, no skills. `unit.gd`'s header names
  this as the extension point.
- Pause/1x/3x time controls exist (Space or the bottom-bar buttons), but
  there's no calendar or day/night cycle yet — the date label is a stub.
- `spawn_unit` is a debug verb; RimWorld's version is a wanderer-joins event.

### DF verticality

- Units climb only 1 m steps via `jump_speed`. Dig a 2-deep pit and its floor
  is unreachable forever — no stairs/ramps exist, and `VoxelAStarGrid3D` only
  knows solid-vs-air, so stair support is genuinely non-trivial.
- Only raycast-visible voxels can be designated — no slice view or x-ray for
  planning underground digs.

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

3. ~~**Generalize build materials.**~~ **Done.** *Build wall* replaced *build
   dirt*: `BlockRegistry.WALL_MATERIALS` maps each wall-eligible material class
   to its block and required volume — 1.25 m³ loose soil → dirt block, 1.0 m³
   stone boulders/cobbles → `STONE_WALL`, two logs → `LOG_WALL`. The first
   load fetched commits `job.material`/`job.block_id`; eligibility is per-form
   (`item_fits_wall`), and a commitment lifts if the material runs out mid-job.

4. ~~**A workshop + CRAFT job.**~~ **Done — as a designation, not a block.**
   *Designate crafting spot* marks an empty voxel on solid ground (no
   material cost, nothing built — a persistent marker like a stockpile);
   *Craft planks* orders one craft there. A unit fetches one whole log from
   the nearest pile, saws it at the spot and drops three discrete `PLANK`
   items (20% of the log each) plus the 40% balance as loose sawdust — all
   of the log's material. Undesignating (or an RMB cancel) removes the spot
   and cancels its order, dropping any carried input intact. Covered by
   `_test_craft` in the smoke test. Still open: a general recipe table and
   smelting (iron ore → iron item).

5. **Stockpile filtering.** A per-tile material filter set at designation
   time (cycle material like actions, or a follow-up click). Small change, big
   legibility; listed in DESIGN.md open seams.

6. ~~**Time controls**~~ **Partly done** — pause/1x/3x via `get_tree().paused`
   + `Engine.time_scale` (Space or the bottom bar; the overseer/HUD keep
   `PROCESS_MODE_ALWAYS` so planning works while paused). **Still open:**
   day/night — a sun rotation plus a real game clock to feed the stubbed date
   label.

7. **Sleep first, then hunger.** Energy need → unit seeks a claimed bed
   (needs wood → ordered after 2–4) or naps on the ground with a penalty.
   Hunger needs a food source — a forageable berry bush is the cheapest
   version, farming the real one.

8. **Ramps/stairs.** The DF "dig down" fantasy. Hardest item on this list:
   `VoxelAStarGrid3D` treats anything non-air as solid, so this needs either a
   parallel walkability layer feeding `_is_standable`/`_repath_to_job`, or a
   custom astar pass. Worth doing after the economy loop exists.

9. **Skills & job priorities.** `claim_job` is already a scored nearest-first
   selection — adding priority weight and per-unit skill multipliers on
   `mining_speed`/`clearing_speed` is a small diff with outsized RimWorld
   flavor.

10. **Persistence.** `VoxelStreamSQLite` for terrain plus a colony serializer
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
