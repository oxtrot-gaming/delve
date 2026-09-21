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
  mine, clear pile, build dirt, designate stockpile, undesignate stockpile,
  spawn unit). LMB performs the selected action, E cycles,
  holding E past `ACTION_MENU_HOLD` (0.4 s) frees the cursor and pops a picker
  (`action_menu_requested` → HUD `PopupMenu`; selection or dismissal recaptures
  the mouse via `popup_hide` → `menu_closed`). RMB always cancels the
  designation under the cursor — checked at both the hit voxel and the pile
  voxel in front of it. Adding a verb = one enum entry plus a `_perform` case.
- **The highlight follows the action**: it boxes the voxel the selected action
  would touch (`_action_voxel`) — the hit block for mine, the air voxel in
  front of the face for clear/spawn — and turns red when the action can't act
  there (`_action_valid`: clear needs a pile, spawn needs an unpacked voxel,
  mine needs a solid block). `_perform` refuses invalid targets, so the
  highlight never lies about what a click will do.
- **Camera collides with terrain**: treated as a box of half-extent
  `camera_margin` (0.3 m — keeps the near plane out of walls). Movement is
  applied axis-by-axis in ≤0.45 m increments, so the camera *slides* along
  terrain and cannot tunnel through a 1 m wall at low framerates. If it ever
  ends up inside solid voxels anyway (a chunk generating around it), movement
  is unrestricted so it can always escape.

## Units and jobs

- `ColonyJob`: work at a voxel (`MINE`, `CLEAR`, `BUILD`, `HAUL`). States:
  pending → assigned → done/cancelled. Jobs never execute themselves. `HAUL`
  is the odd one out — it never goes on the board; a unit creates one for
  itself as an idle fallback so pathing, the reach rule and the stuck
  watchdog work on it unchanged.
- `Colony` is the job board: `designate_mine`, `designate_clear`,
  `designate_build`, `claim_job` (nearest open job), `release_job`,
  `complete_job`/`complete_clear`/`complete_build`. Cancelling a designation
  releases the assignee.
- **Clearing** (`CLEAR` jobs): the overseer marks an item-filled voxel; a unit
  paths within reach and shovels its contents into adjoining voxels —
  `clearing_speed` m³/s, below → emptiest side → on top. Clearing shares the
  mining reach rule, but the target is non-solid so the face ray only has to
  reach the voxel, not hit it (`_can_reach_from` parameterises this). If every
  adjoining voxel is packed the unit gives up and the job goes back on the
  board. Clearing is also the player-facing version of path-shoving: same
  item-moving mechanics, driven by a job instead of an obstruction.
- **Building** (`BUILD` jobs): *build dirt* marks an empty voxel (non-solid,
  non-packed — a partial pile is displaced at placement). Building is real
  hauling: the unit paths to the closest pile holding loose soil — no
  distance limit — shovels up to `carry_capacity` (0.5 m³) into its carried
  load at `clearing_speed`, hauls it back, and repeats. Delivered soil is
  absorbed into `job.progress` (the build voxel can't hold 1.25 m³ as a pile
  anyway — capacity is 1.0); at `DROP_VOLUME` the block is placed. Loose
  items split so exactly the needed volume leaves a pile; a unit that drops
  the job mid-haul drops its carried load where it stands, so matter is
  conserved. No soil anywhere → the job goes back on the board. A unit can't
  work from inside the build voxel (work spots exclude it) or place a block
  containing itself.
- **Stockpiles and hauling**: *designate stockpile* marks an empty voxel on
  top of a solid block (`designate_stockpile`; undesignate removes it) — a
  persistent designation in `Colony.stockpiles`, not a job, drawn as a faint
  translucent outline. Idle units (`_try_start_haul`, when no job is
  claimable) create a `HAUL` job: path to the nearest pile not in a
  stockpile, take up to `carry_capacity` — `ItemPile.take_up_to` splits loose
  items and picks whole solids that fit — then path to the nearest stockpile
  tile with room for the load (`nearest_stockpile_with_room`) and deposit.
  Big piles take several trips; a tile that fills mid-haul is re-picked at
  arrival. Unreachable sources/destinations go on a per-unit `_haul_blacklist`
  for `DROPPED_JOB_RETRY_MSEC` so a bad target doesn't livelock the fallback.
  Interrupting a haul drops the carried items where the unit stands — the
  same `abandon_job` drop build jobs use.
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
  pile rather than inside it.
- **The 1 m³ cap is enforced, not assumed**: `_enforce_capacity` runs after
  every deposit and landing merge — a pile over one cubic metre splits, moving
  the excess (smallest items first; loose items split so only the surplus
  leaves) into the same below → emptiest-side → on-top order used elsewhere.
  The sole exception remains the squeeze-in fallback: a pile can exceed 1 m³
  only when literally every adjoining voxel is already packed.
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

- No persistence yet (`VoxelStreamSQLite` is the drop-in answer).
- Only dirt blocks are buildable so far — `block_id` on the job is wired for
  more, but there's no recipe/scaffold system for non-dirt materials.
- Stockpile capacity is just voxel fill (1 m³ per tile) — no per-item-type
  filtering, priorities, or stockpile UI beyond the designation outline yet.
