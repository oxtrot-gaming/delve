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
- `designate_build` happily queues a wall on a fully floating cell, and
  plans stack on unbuilt ghosts — legal at *designation* by design (the
  support may be a pending build); the suspension guard in item 9 fires
  at placement time instead.

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
   the smoke test. **Done (hunger, first slice).** `Unit.hunger` drains
   over a day; below `food_seek` (30%) a unit stops claiming work and
   walks to the nearest pile holding food (`nearest_food_pile`) as a
   self-issued `EAT` job, then eats bites out of the pile until full.
   Hunger at zero halves work speed everywhere (`STARVING_SPEED` × mining,
   clearing, crafting, deconstruction) instead of downing the unit. The
   first food source is the **wild berry bush**: a single-cell plant
   decoration (the forest's sapling model — see `plants.gd`), seeded on
   grass columns at mixed ripeness, stripped by an explicit `FORAGE`
   designation that drops physical `BERRY` items at the bush for hauling.
   A foraged bush regrows its yield on a timer. Covered by `_test_food`.
   **Farming landed** in item 14 — the bush doubles as the perennial
   crop template.

8. **Multi-z transition — ladders — built.** The DF "dig down" fantasy.
   Ladders are construct-in-place buildings (`designate_ladder`, three
   planks via the craft-fetch/escrow pipeline) that turn their cell into
   a climbable support: the native sim tracks them as a voxel set beside
   `pile_fill`, the A* gains vertical edges (climb into or out of a
   ladder cell, descend into a rung below), and `unit_step` sinks a
   descending unit at `climb_speed` instead of freefalling while a
   ladder holds the cell at or below the feet. A ladder supports a unit
   inside it *and* standing on the cell above, so a stacked rung chain
   solves the roof problem — a ~1.8 m unit needs two free voxels, so a
   roof sits ≥ 2 m up, reachable only by ladder. Ladders aren't floors
   for items: anything dropped above falls through to the bottom rung,
   and a pile sharing a ladder cell tops out at 750,000 cm³ (75% —
   `LADDER_PILE_CM3`, enforced through `voxel_capacity` and the sim's
   `capacity_at`). Designated up or down from any open air cell; a pile
   already there coexists. **Remaining:** real rendering — a
   wall-hugging ladder (facing, voxel edge) vs a freestanding pole
   (center) render differently but path identically, so the "adjacent
   solid" check is a render-time question. **Future-work notes:** keep
   the universal 1 m step invariant, but penalty-scaled for smaller
   bodies; injuries could take a unit's climb away entirely; alternate
   hard plank-like materials (metal rods) — the recipe already routes
   through `inputs`, so a second `builds` recipe is the shape; moving
   through/over piles should cost a movement penalty; and the engine
   `VoxelAStarGrid3D` fallback still can't see ladders (moot while unit
   motion is native-only).

9. ~~**Collapse mechanics.**~~ **Done — option (b), the guard.** A solid
   block stands iff a face-adjacent chain of solids connects it to the
   base level (`bedrock_height`, currently −64); tree blocks anchor
   themselves. Support is only ever *broken* by a removal, so the check
   is event-driven: `VoxelWorld.mine`/`remove_voxel` run
   `DelveSim.collapse_check`, which floods the removed cell's six
   neighbours — best-first by lowest y, so anchored terrain dives to
   bedrock in ~depth pops — and condemns a whole detached body at once.
   The frontier is trusted (an uneditable neighbour can't disprove a
   chain through unstreamed terrain), and a flood cap treats anything
   too big to disprove as anchored. Each condemned cell drops its
   mined-equivalent rubble where it stood via `block_collapsed`. Builds
   are guarded at placement time, not designation (stacked plans are
   legal — the support may itself be a pending build): once a build's
   recipe is fully escrowed, `would_be_supported` asks whether any
   face-neighbour is solid; an unsupported site suspends the job
   (`ColonyJob.suspended` — still designated, escrow intact, excluded
   from both the GDScript and native claim pools) until `block_placed`
   fires on an adjacent cell. Covered by `_test_collapse`.

10. ~~**Skills & job priorities.**~~ **Done.** Four skills — Mining
    (`MINE`), Construction (`BUILD`/`DECONSTRUCT`/`FURNISH`), Plants
    (`CHOP`/`FORAGE`), Crafting (`CRAFT`) — with `CLEAR`/`HAUL`/`REST`/
    `EAT` staying unskilled; the taxonomy lives in `ColonyJob.SKILL_FOR`
    and is deliberately open-ended. XP is flat per completed job
    (`XP_FOR`); levels derive from cumulative XP through the linear
    requirement (X for L1, then 2X, 3X, …) inverted via quadratic — no
    level counter to drift. Work speed is `2^(level/10)` (L10 ≈ 2×,
    L20 ≈ 4×), folded into `_work_rate` beside the starving penalty.
    `claim_job` scores jobs in metres-equivalent —
    `dist − skill_level·weight − age·languish` — where the per-unit
    `specialize` toggle (exposed on the colonist panel) swaps the skill
    weight between a nudge and expertise-dominant, and the capped
    languish term is the anti-starvation pressure that keeps unskilled
    busywork claimable. The native board mirrors `job_type`/`posted` and
    scores identically. Attributes will later modulate both work rate
    and `skill_gain_rate` — the hook points are already in place.
    Covered by `_test_skills`.

11. ~~**Tree growths + organic decay.**~~ **Done.** Mature trees fruit
    on their growth tick — the oak sheds one acorn (`Form.FRUIT`) per
    leaf block every five game-days, scattered to piles by ordinary drop
    gravity; bushes keep their fruit for FORAGE / a future HARVEST. The
    `extract_seed` recipe presses a fruit into two seed packets at the
    crafting spot — an ordinary `CRAFT` job (skill rate + XP apply) —
    and the packet carries the fruit's species for farming; a dedicated
    seed building can later beat the worksite on speed or yield. Organic
    decay (`Colony._decay_tick` + `DropItem.DECAY_RULES`) sweeps landed
    piles on the game clock: bulk stacks shed Poisson quanta calibrated
    to each material's mean lifetime (fruit 10 d, leaves and sawdust
    15 d, branches 60 d, seeds 60 d, compost 60 d, logs 120 d as
    discrete per-item rolls), a near-total roll finishes the stack so
    no slivers survive, and leaf/branch/log rot returns compost at the
    rule's fraction (¼, ½, ½). Planks are cured and exempt. A fruit
    whose last volume rots on soil rolls 5% to sprout its species —
    saplings need the cell plus all eight neighbours free of plants,
    bushes only their own cell — so vegetation creeps outward slowly.
    Covered by `_test_organics`.

12. ~~**Grass as decoration, not block.**~~ **Done.** `grass.gd` keeps a
    per-cell coverage map on the forest's leaf/sapling model: the voxel
    stays `DIRT` (it mines as soil, grass is never a drop), a multimesh
    slab renders the cover, and the generator seeds soil-topped columns
    at mixed coverage via a `grass_seed_at` oracle. Cover dies when the
    block under it is mined or its top face is covered — by a placed
    block, a registered building's footprint, or a packed pile — and
    foot traffic wears it: each entry into a cell's column costs 0.2
    cover, so ~5 crossings bare a healthy patch, worn cells regrow a
    step per scan visit, and a lush cell (≥0.7) slowly spreads into
    bare eligible neighbours. Records persist across streaming so
    trodden paths and built-over ground stay bare on reload. The float
    coverage map is deliberately grazing-ready. The `GRASS` block enum
    stays for palette compatibility but nothing generates it.

13. **Carry limits by item shape + containers.** **Deferred — pending
    cloth.** Containers want a flexible material — bags, sacks and
    backpacks are cloth goods — and cloth waits on a fibre crop; the
    farming machinery landed in item 14, but textiles still need their
    own expansion on top of it. Building the container pipeline on placeholder
    materials now just pays the rework twice. Kept in place for the
    design notes: a unit carries either a *small* volume of loose
    material (the current 0.5 m³, possibly smaller) **or** one solid
    item — one boulder, one log, one bed kit — instead of the flat
    volume cap. Then add *containers* (bags, boxes, backpacks): fillable
    to their own capacity — possibly larger than the loose allowance —
    and haulable as a single item under the one-solid rule. That's the
    throughput lever: a backpack full of cobbles beats a bare handful.
    Open seams: whether containers are crafted items, which jobs get to
    use them, and how packing/unpacking a container interacts with
    stockpile filters.

14. ~~**Farming via physical seed bundles**~~ **Done — zone + sow job,
    first pass.** The Progression: Agriculture physical-seeds rule
    shipped: `designate_farm` zones contiguous cells into a `FarmField`
    record (one field per drag, markers like stockpiles), the inspect
    panel assigns a crop from `farmable_species` (every `Plants` and
    `Forest` species — a field can grow trees), and a periodic `_tick_field`
    scan posts `SOW` jobs per open cell — shrubs take any unoccupied cell
    over dirt, trees additionally demand the 3×3 plant-free spacing the
    wild-sprout rule uses — gated on a species-matched `Form.SEED`
    packet existing in some pile (`_seed_exists`; the job suspends when
    the supply vanishes rather than churning). A sow unit fetches the
    packet (`take_seed` filters piles by species), carries it over, and a
    short work tick plants an immature bush or sapling identical to the
    decay-sprout path — farmed plants grow exactly like wild ones, and
    planting turns the sod (the grass under the cell dies). Ripe shrubs
    auto-post `FORAGE` jobs; `annual` species (wheat — the first) come
    up whole on harvest — the bush dies, tombstoned against stream-in —
    and the freed cell re-sows itself once a seed exists again.
    Perennials (the berry bush) bear on their regrow clock forever. Tree
    fields get the inspect panel's "chop mature trees" toggle:
    `auto_chop` posts a `CHOP` per mature in-field trunk. Wheat closes
    the seed loop physically: its harvest drops `GRAIN` *grain heads*
    (`Form.FRUIT` — edible, decaying, and volunteer-sprouting), and
    `extract_seed` threshes a head into two wheat packets since
    `FRUIT_SPECIES[GRAIN]` resolves to wheat. Covered by `_test_farm`.
    **Open seams:** weather/light/fertility sowing gates (the hooks sit
    in `_sowable`), tilled-soil or fertility bonuses, a dedicated seed
    building beating the crafting spot, crop blight/rot in the field,
    and PA's knowledge-unlock gate if physical possession proves too
    permissive.

15. ~~**Sleep-speed boost.**~~ **Done.** A `Zz` toggle in the speed row
    arms `Colony.sleep_boost`; while armed and every unit at the site
    sleeps, the clock runs at the top standard speed (6x), falling back
    to the player's pick the moment anyone wakes — and pause always
    wins. The check is observer-based, not a per-frame rescan:
    `Unit.state` is now a property whose setter emits `state_changed`
    (the observer seam a modding interface will reuse), the colony keeps
    a sleeping-set off that hook, and `_all_asleep` is an O(1) size read.
    "All" is the focused site's roster — a multi-site future filters
    inside `_all_asleep`, and domestic animals land in `units` and count
    identically. Both speed paths (HUD buttons, overseer hotkeys) now
    route through `Colony.set_speed`/`set_paused` — one authority, so
    the boost can't fight a manual setting. Engaged reads as the 6x
    button lit plus a tinted toggle. Covered by the HUD test.

16. ~~**Worksite job queues + conditional repeat.**~~ **Done.** Worksites
    hold a *queue* of bills (`Building.orders`, `WorksiteOrder` records —
    per-worksite, not colony-wide) instead of a single order. RimWorld's
    three repeat conditions ship: **do X times** (leaves the queue when
    `done >= target`), **until you have X** (parks in place while
    stocked — `_have_count` totals the recipe's first output form across
    every landed pile, material-agnostic — and resumes when the count
    dips), and **forever**. A 1-game-second dispatch pass
    (`_dispatch_worksite`, also run the moment a bill is queued) walks
    head-first; a bill whose recipe inputs don't exist anywhere
    (`_order_dispatchable`, cm³-accurate per form) rotates to the back
    rather than blocking the line, and parked until-bills hold their
    place. Escrow stays per-job — inputs land in `job.delivered`/
    `job.components` only once the bill's job runs, so a queued bill
    owns nothing and a cancelled run hands its escrow back
    (`_cancel_job`). The panel's recipe buttons now enqueue, and each
    queue row gets a condition picker, a target spinner, and a remove
    button; *Cancel order* ends the running bill (cancelling just the
    job would re-dispatch it), and a cancel sweep empties the whole
    queue while leaving the site standing. `designate_craft` survives as
    a queue-and-dispatch shortcut for tests. Open seams: per-order
    input/output material filters (a "planks from oak" bill), pausing a
    bill without dropping it, bill copy/reorder controls, count
    carried/in-flight goods in until-checks, and whether escrow should
    ever move earlier than job start.

17. ~~**Desperation foraging.**~~ **Done.** Below `desperation_seek`
    (12%, always under the unit's effective seek line) with no edible
    pile reachable, an idle unit self-issues an unregistered
    `FORAGE` job (`job.desperate`) on `nearest_ripe_bush` — nearest ripe
    bush carrying no designation, so desperation never competes with
    orders — strips it through the normal forage tick, then eats a
    self-issued `EAT` meal from the yield pile right there, stopping at
    its own food-seek line instead of gorging (`_meal_target`); what's
    left stays dropped. Piles still win over bushes at any depth — the
    bush is the fallback. Desperation fires only at the idle gate, not
    mid-job. The attribute seam landed too: `Unit.traits` +
    `trait_factor` + `TRAIT_EFFECTS` give personality multipliers —
    `food_seek_mult`, `desperation_mult`, `meal_target_mult` — so
    ascetic/gourmand/iron-willed/immoderation already bend the
    thresholds and meal size, and future traits add a factor name at the
    decision point. Open seams: mid-job interruption (a trait-gated
    break-off check at the work tick), desperation on other needs (rest,
    safety), eating the yield *while* foraging rather than after, and a
    colony-side bush index if the linear `nearest_ripe_bush` scan hurts.

18. **Persistence.** `VoxelStreamSQLite` for terrain plus a colony serializer
    (jobs, `item_piles`, `stockpiles`, unit positions/cargo). Defer until the
    colony state stops churning — every new system above adds save surface.

19. **Opportunistic hauling.** Whenever a moving, empty-handed unit will
    pass close to a haulable item *and* its destination is close to the
    item's destination, it should pick the item up mid-path, deliver it,
    and resume its original trip — hauling throughput from trips that
    happen anyway instead of dedicated haul legs. Open seams: what
    "close" means for path vs item and destination vs stockpile (path-
    distance sampling vs straight-line), whether the detour goes through
    the existing `_detour` machinery, how it interacts with a unit
    already detouring for a packed pile, and whether specialists'
    willingness to detour shrinks (the specialize stance as a distance
    cap).

20. **Plant environment + lifecycle.** Growth for trees and bushes
    should be modulated by daylight, weather, soil type and soil
    fertility: outside a species' optimal ranges it grows slower or not
    at all, and extreme conditions kill it. Compost is the fertility
    lever — applied by a colonist task or released automatically when
    compost decays on soil — which needs fertility tracked per soil
    block. Trees also need a maximum age: a dead tree drops its leaves
    and branches but leaves a dead trunk that chops like a live one,
    and deciduous species should be able to shed leaves under weather
    triggers. Once a tech tree exists, research can offer ways to slow
    or halt organic decay. Open seams: where per-block fertility lives
    (decoration layer vs voxel metadata), whether weather is a global
    state machine or per-region, and how growth-rate multipliers feed
    back into the `next` timers without rescheduling storms.

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
