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

- `PLANKS`/`WOOD` exist in `block_registry.gd` but nothing generates wood — no
  trees, no chop verb. Wood is unobtainable.
- `ColonyJob.block_id` is wired for any block but only dirt is reachable via the
  UI, and `_tick_fetching` only knows loose soil (`unit.gd`,
  `colony.nearest_soil_voxel`).
- Ore → nothing. No crafting station, no smelting, no recipes. Stockpiles are
  write-only storage.
- `stockpiles` are unfiltered (noted in DESIGN.md open seams) — coal and gold
  mix on the same tile.

### Colonist-ness (the RimWorld half)

- Units work 24/7: no hunger, no sleep, no skills. `unit.gd`'s header names
  this as the extension point.
- No time controls at all — no pause, no speed multiplier, no day/night. The
  input map has only movement + designation.
- `spawn_unit` is a debug verb; RimWorld's version is a wanderer-joins event.

### DF verticality

- Units climb only 1 m steps via `jump_speed`. Dig a 2-deep pit and its floor
  is unreachable forever — no stairs/ramps exist, and `VoxelAStarGrid3D` only
  knows solid-vs-air, so stair support is genuinely non-trivial.
- Only raycast-visible voxels can be designated — no slice view or x-ray for
  planning underground digs.

### UX

- Designation is one click = one voxel. RimWorld mining is drag-rectangle; the
  cheapest high-impact gap.
- The action list will outgrow the cycle-E model as verbs multiply (already 6).

## Ordered roadmap

1. ~~**Drag-box designation.**~~ **Done.** LMB/RMB press anchors a rect on
   the hit face's plane (ground drags paint horizontal layers, wall drags
   paint vertical sections); release applies the action per voxel, with
   validity checked per cell in `Colony.designate_*`. Cancel drags sweep the
   hit layer plus the air layer in front. `spawn_unit` stays single-click.
   Covered by `_test_drag` in the smoke test.

2. **Trees + CHOP job.** A `TREE_TRUNK`/`LEAVES` block pair (append to
   `BLOCKS` — never reorder, per the save-format rule), scattered on grass in
   `world_generator.gd`, and a `CHOP` job type that's MINE-on-a-tree producing
   WOOD items. Small, and unlocks the whole wood chain.

3. **Generalize build materials.** Let `designate_build` carry the target
   block's material class; replace `nearest_soil_voxel`/`pull_loose_soil` with
   material-parameterized pile queries (`has_loose`/`take_loose` already take
   a material — the abstraction is half there). Build dirt/stone/planks.

4. **A workshop + CRAFT job.** One placed block (e.g. `STONE_FURNACE`), a
   recipe table, and a job type that fetches inputs from stockpiles and
   deposits outputs — structurally the build job's fetch/deliver loop pointed
   at a station instead of a voxel. Smelt iron ore → iron item; saw wood →
   planks. This is what makes mining *mean* something.

5. **Stockpile filtering.** A per-tile material filter set at designation
   time (cycle material like actions, or a follow-up click). Small change, big
   legibility; listed in DESIGN.md open seams.

6. **Time controls + day/night.** `Engine.time_scale` for pause/1x/3x is
   nearly free; a sun rotation drives the next item.

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

- `nearest_haulable_pile`/`nearest_stockpile_with_room`/`nearest_soil_voxel`
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
