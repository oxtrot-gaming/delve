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

## The overseer

- Free-flying camera; designates voxels via a `VoxelTool` raycast (96 m reach).
- **Actions, not buttons**: the overseer's abilities are a list (`ACTIONS`:
  mine, chop tree, clear pile, build dirt, designate stockpile, undesignate
  stockpile, spawn unit). LMB performs the selected action, R cycles,
  holding R past `ACTION_MENU_HOLD` (0.4 s) frees the cursor and pops a picker
  (`action_menu_requested` → HUD `PopupMenu`; selection or dismissal recaptures
  the mouse via `popup_hide` → `menu_closed`). RMB always cancels the
  designation under the cursor — checked at both the hit voxel and the pile
  voxel in front of it. Adding a verb = one enum entry plus a `_perform` case.
- **Drag paints a box**: pressing LMB or RMB anchors a box on the hit face's
  plane — the face normal picks the locked axis, so aiming along the ground
  paints a horizontal layer (DF-style per-layer digs) and aiming along a
  wall face paints a vertical section. Moving the aim while held promotes
  the press to a drag that commits on release; holding the button past
  `DRAG_HOLD` (0.25 s) makes the box *stick* — it survives the release,
  keeps following the aim, and LMB commits / RMB aborts it. Per-voxel
  validity stays in the `Colony.designate_*` functions, so cells the action
  can't touch are skipped. A cancel sweep clears both the hit layer and the
  air layer in front of it — clear and stockpile markers live a voxel out
  from the face. Rects clamp to `DRAG_MAX_AXIS` (64) per side. `spawn_unit`
  stays a single click — a box of new units makes no sense.
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
- **Camera collides with terrain**: treated as a box of half-extent
  `camera_margin` (0.3 m — keeps the near plane out of walls). Movement is
  applied axis-by-axis in ≤0.45 m increments, so the camera *slides* along
  terrain and cannot tunnel through a 1 m wall at low framerates. If it ever
  ends up inside solid voxels anyway (a chunk generating around it), movement
  is unrestricted so it can always escape.

## Units and jobs

- `ColonyJob`: work at a voxel (`MINE`, `CLEAR`, `BUILD`, `HAUL`, `CHOP`).
  States: pending → assigned → done/cancelled. Jobs never execute
  themselves. `HAUL` is the odd one out — it never goes on the board; a
  unit creates one for itself as an idle fallback so pathing, the reach
  rule and the stuck watchdog work on it unchanged.
- `Colony` is the job board: `designate_mine`, `designate_clear`,
  `designate_build`, `designate_chop`, `claim_job` (nearest open job),
  `release_job`, `complete_job`/`complete_clear`/`complete_build`/
  `complete_chop`. Cancelling a designation releases the assignee —
  cancelling any part of a tree cancels the chop job at its root.
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
- **Building** (`BUILD` jobs): *build dirt* marks an empty voxel (non-solid,
  non-packed — a partial pile is displaced at placement). Building is real
  hauling: the unit paths to the closest pile holding loose soil — no
  distance limit — shovels up to `carry_capacity` (0.5 m³) into its carried
  load at `clearing_speed`, hauls it back, and repeats. Delivered soil is
  absorbed into `job.progress` (the build voxel can't hold 1.25 m³ as a pile
  anyway — capacity is 1.0); at `DROP_VOLUME` the block is placed. Loose
  items split so exactly the needed volume leaves a pile; a unit that drops
  the job mid-haul drops its carried load where it stands, so matter is
  conserved. No soil anywhere → the job goes back on the board. Before
  placing, the builder evicts the voxel: `_occupies_voxel` checks every unit's
  capsule (feet *and* head voxel — a 1.8 m body spans two), idle occupants
  get `yield_to`'d like path-blockers, and an occupant that can't move (or
  won't leave in ~4 s) fails the job rather than being buried. The builder
  can't work from inside the voxel or beneath it — work spots and the reach
  check exclude both, so it never walls its own head in.
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
  so a bad target doesn't livelock the fallback.
  Interrupting a haul drops the carried items where the unit stands — the
  same `abandon_job` drop build jobs use.
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
  gates growth while a chunk is out.
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

## Open seams

- No persistence yet (`VoxelStreamSQLite` is the drop-in answer).
- Only dirt blocks are buildable so far — `block_id` on the job is wired for
  more, but there's no recipe/scaffold system for non-dirt materials.
- Stockpile capacity is just voxel fill (1 m³ per tile) — no per-item-type
  filtering, priorities, or stockpile UI beyond the designation outline yet.
