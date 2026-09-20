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
- The generator is a GDScript `VoxelGeneratorScript`. A `VoxelGeneratorGraph`
  is the documented upgrade path once the ruleset stops changing.

## Terminology

Workers are **units** (renamed from "colonists" — files, classes, input
actions, UI). "Colonist" should not reappear in new code.

## Terrain generation

`world_generator.gd`, all parameters exported and tunable.

- Rolling surface from 2D simplex height noise (`base_height` 32 ± amplitude 18),
  4-voxel dirt band under grass, stone below, hard floor at `bedrock_height` −64.
- **Rock outcrops**: a separate 2D `_rock_noise` raises the per-column rock top.
  Above `outcrop_threshold` (0.45) the rock ramps linearly from the normal
  `surface − soil_depth` up to `surface + outcrop_protrusion` (7). Measured on
  the shipped seed: ~9% of columns get rock intruding into the soil band,
  ~1.3% get stone exposed at or above the surface. Outcrops carry no ore
  (ore depth is measured from the grass line) and can host caves.
- **Caves**: `|noise| < 0.05`, suppressed within 2 voxels of the top so the
  surface doesn't get potholes.
- **Ores** are depth-gated, rarest first: coal ≥ 4 deep, iron ≥ 12, gold ≥ 28.
- **Invariants**: `surface_height()` returns the *true* topmost voxel including
  rock protrusions (spawn placement relies on this), and `_generate_block`'s
  sky early-out adds `outcrop_protrusion` to `max_surface` so tall outcrops
  aren't clipped.

## The overseer

- Free-flying camera; designates voxels via a `VoxelTool` raycast (96 m reach).
- **Actions, not buttons**: the overseer's abilities are a list (`ACTIONS`:
  mine, clear pile, spawn unit). LMB performs the selected action, E cycles,
  holding E past `ACTION_MENU_HOLD` (0.4 s) frees the cursor and pops a picker
  (`action_menu_requested` → HUD `PopupMenu`; selection or dismissal recaptures
  the mouse via `popup_hide` → `menu_closed`). RMB always cancels the
  designation under the cursor — checked at both the hit voxel and the pile
  voxel in front of it. Adding a verb = one enum entry plus a `_perform` case.
- **Camera collides with terrain**: treated as a box of half-extent
  `camera_margin` (0.3 m — keeps the near plane out of walls). Movement is
  applied axis-by-axis in ≤0.45 m increments, so the camera *slides* along
  terrain and cannot tunnel through a 1 m wall at low framerates. If it ever
  ends up inside solid voxels anyway (a chunk generating around it), movement
  is unrestricted so it can always escape.

## Units and jobs

- `ColonyJob`: work at a voxel (`MINE`, `CLEAR`; `BUILD` reserved). States:
  pending → assigned → done/cancelled. Jobs never execute themselves.
- `Colony` is the job board: `designate_mine`, `designate_clear`, `claim_job`
  (nearest open job), `release_job`, `complete_job`/`complete_clear`.
  Cancelling a designation releases the assignee.
- **Clearing** (`CLEAR` jobs): the overseer marks an item-filled voxel; a unit
  paths within reach and shovels its contents into adjoining voxels —
  `clearing_speed` m³/s, below → emptiest side → on top. Clearing shares the
  mining reach rule, but the target is non-solid so the face ray only has to
  reach the voxel, not hit it (`_can_reach_from` parameterises this). If every
  adjoining voxel is packed the unit gives up and the job goes back on the
  board. Clearing is also the player-facing version of path-shoving: same
  item-moving mechanics, driven by a job instead of an obstruction.
- **Stuck watchdog**: in `MOVING`, a unit tracks its best distance to the job
  site; if it hasn't closed `STUCK_PROGRESS` (0.25 m) for `stuck_timeout` (5 s)
  it drops the assignment via `release_job`. `release_job` records the drop on
  the job (`dropped_by`), and `claim_job` skips jobs the unit dropped within
  `DROPPED_JOB_RETRY_MSEC` (10 s) — a unit can't livelock reclaiming an
  unreachable job, but it can retry later (or another unit takes it).
- `Unit` is a `CharacterBody3D` state machine: idle → moving → working.
  Deliberately minimal — it is the extension point for needs, skills, hauling.
- Each unit has a `skin_tone` property: a random point on a pale → mid → dark
  ramp (`SKIN_TONE_*` constants), applied in `_ready` to a per-instance copy of
  the body material — the scene's capsule material is shared, so it must be
  duplicated before tinting.

### The mining reach rule

A unit may mine a block iff:

1. its centre is within `mine_reach` (1.5 m) of the **nearest point on the
   block's AABB**, and
2. a raycast to that point hits the target voxel first — nothing behind,
   above or below another solid block relative to the unit.

`_work_spots()` selects pathing destinations by evaluating the *same* predicate
from each candidate's stand position, so the planner and the mining gate can
never disagree. Units are 1.8 m tall, 0.9 m across; consequence: a unit on flat
ground can dig the surface diagonally below its feet (face distance ≈ 1.0 m).

Two latent engine bugs this rule exposed, now fixed: `VoxelAStarGrid3D.find_path`
omits the destination voxel (`VoxelWorld.find_path` appends it), and
`jump_speed` 6.0 gave a 0.82 m apex — below the 1 m steps the astar routes over;
now 7.5 (≈1.28 m apex).

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
- **Piles stay in the world** — nothing auto-deposits to the stockpile. That
  is intentional scaffolding for the haul job, not an oversight.

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
of the voxel above: the pile steps down through non-solid voxels until it rests
on a solid block, stopping at the edge of loaded terrain (`is_editable`)
rather than falling into the void.

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
- Settling treats packed voxels as floor — items land *on top of* a packed
  pile rather than inside it. A pile is allowed to exceed 1 m³ only via the
  squeeze-in fallback (every neighbour full).
- `Unit._is_blocked`/`_is_standable` and mining occlusion sample `is_packed`:
  a packed voxel can't be stood in, but the voxel above it is standable.
- `VoxelAStarGrid3D` has no obstacle hook (only voxel-id 0 is air), so
  `Unit._repath_to_job` post-validates returned paths: a clear path is always
  preferred, but a pile-crossing one is accepted when nothing else exists —
  the unit shoves the obstruction aside as it reaches it.

## Testing posture

`smoke_test.gd` runs headless against the real `main.tscn` and asserts end-to-end
behaviour (spawn → designate → mine → pile) plus controlled-geometry checks:
placed blocks in open air for reach/occlusion, a placed shelf for gravity,
measured-noise scans for outcrops. Prefer deterministic fixtures over RNG
assertions; where the drop table is random, assert conservation and class
invariants instead of counts.

## Open seams

- **Hauling** is the designed next step: piles → stockpile needs a `HAUL` job
  type, unit carry capacity, and stockpile deposit.
- No persistence yet (`VoxelStreamSQLite` is the drop-in answer).
- No building yet despite `Type.BUILD` and `PLANKS` existing.
- Stockpile UI exists but stays at zero until hauling lands.
