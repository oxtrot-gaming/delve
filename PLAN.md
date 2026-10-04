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

18. **Persistence.** Done — the save unit is a `Region`, not a site, per the
    regional-map design: a `Site` (anchor + 128² bounds + colony payload)
    embeds in a `Region` (256² voxel tile) which owns the terrain edit log,
    the coarse heightfield summary (`CELLS²` samples, still derived data —
    the real two-layer generator split is the open seam), and the sites.
    `VoxelWorld` emits `block_edited` on every write path (mine, place,
    collapse, fell) into `region.edits`, indexed per 16³ stream chunk and
    replayed on `block_loaded` — which fixes chunk-unload amnesia and is
    also how loaded terrain applies its deltas over regenerated ground.
    `colony.serialize`/`deserialize` covers units (position, cargo, needs,
    traits, skill XP, stance), piles + items, buildings + worksite orders,
    jobs (restored PENDING — assignments are transient), stockpiles +
    filters, farms, forest/plant/grass records, and rebuilds markers and
    the native sim. Saves land in `user://saves/<slot>/` as world.json
    (seed + planet clock + region list) plus `region_<x>_<z>.json` per
    tile; a dormant site keeps its last colony payload in `site.state`.
    HUD Menu wires Save/Load (Options stays stubbed). Open seams:
    `VoxelStreamSQLite` as the durable stream backing instead of the JSON
    edit log, multiple *active* sites ticking in one region, site
    activation/deactivation, region streaming, and inter-site travel.

19. ~~**Opportunistic hauling.**~~ **Done.** When a fresh clear path is
    found in `_repath_to_job`, `_try_opportunistic_detour` walks the
    route's cells for a pile that wants hauling — `nearest_haulable_pile`'s
    eligibility, so a pile its own stockpile tile fully admits is left
    alone — and, when a stockpile admitting its haulable materials sits
    within `DETOUR_GOAL_REACH` (12 m) of the job's goal, the detour
    machinery borrows `_goal_voxel` for a grab-deliver-resume loop. The
    prevalidated tile is stashed in `_detour_dest`: at the pile the unit
    delivers only to it (a substitute could drag the walk far off route),
    and takes only what a real haul would move — `_haul_fetch_admits`
    keeps a pile-on-stockpile's admitted items in place. Empty-handed
    moving units only; HAUL jobs are excluded outright (the search can't
    beat their own assignment), and self-issued REST/EAT/desperate errands
    aren't waylaid. Willingness is a reach, not a flag: `specialize`
    multiplies it by `DETOUR_SPECIALIST_REACH` (0.4) and shrinks the
    path ring to cells the route runs straight through, and
    `trait_factor(&"detour_mult")` is wired in for a future trait — no
    TRAIT_EFFECTS entry sets it yet. Covered by `_test_opportunistic`.

20. ~~**Plant environment: daylight + fertility.**~~ **Done** (the two
    axes landed; the rest split into roadmap items). Species entries
    declare a light band — `light_min`/`light_low`/`light_high`/
    `light_max` in sun-intensity units (sin of solar altitude) — and a
    `fertility_sensitivity`; `PlantGrowth` turns both into a growth
    multiplier (trapezoid light curve × fertility^sensitivity, floored
    at 0). `daylight_at` combines `DayCycle.sun_intensity` with a
    column sky scan — caves and roofs grow nothing. Growth stays on
    the `next` deadline model: the per-second `_growth_tick` slides
    each pending deadline by the interval's un-grown fraction, so night
    pauses growth in lockstep and fertilized ground outruns the nominal
    clock — no rescheduling storms. Blocks carry type-level
    `fertility`/`fertilizability` (dirt 100%/100%, the rest 0); cells
    that have actually been fertilized hold the extra in
    `colony.fertilization`, which serializes sparse. Compost finishing
    its rot feeds the block below (+1% per 1000 cm³), and accrued
    growth drains stored fertilization. Covered by
    `_test_plant_environment`. Deferred: soil *type* and
    temperature/weather wait on regional biomes (item 39); sustained
    out-of-band light harming plants — per-species grace periods, glare
    faster than shade — is item 40; the manual composting/fertilize
    jobs are item 40. Still open from the original scope: tree
    senescence (max age → dead trunk) and deciduous sheds, and a
    daylight cache if the column scans ever cost.

### RimWorld-parity roadmap

The following is the gap list against RimWorld's core play loop
(Basics guide and its linked pages), excluding the storyteller system —
no director-driven incidents or difficulty curve. Threats will come
from simulation instead (wildlife, weather, terrain). Ordered by
dependency and leverage.

21. ~~**Cooking + meals.**~~ **Done — campfire tier.** The campfire is
    the bootstrap kitchen and light source before stoves exist (a stove
    wants steel, which waits on ore mining + processing — see item 41).
    A *Build campfire* designation places a cobble-ring
    (`Building.Kind.CAMPFIRE`, five cobbles) via the construct-in-place
    recipe path, and the ring doubles as a worksite: `prepare_meal`
    bills queue on it alone — `site` in the recipe pins the bill to the
    building kind so a bare crafting spot can't cook. Four fruit
    (2,500 cm³ each) become one `MEAL` item carrying the ingredients'
    summed nutrition × 1.75, the recipe's `skill`/`xp` overrides train
    Cooking at 1 XP per meal (ten meals take a level-0 cook to level
    1). The fire burns physical fuel — leaves, sawdust/loose wood,
    branches, and logs carry per-cm³ or per-item burn-seconds
    (`DropItem.FUEL_SECONDS_*`) — up to a `CAMPFIRE_FUEL_CAP` bank,
    lighting an `OmniLight3D` child out to `CAMPFIRE_LIGHT_RADIUS`
    (5 m; `colony.illumination_at` is the 0–1 falloff query the
    deferred poor-light work penalties will consume). An unlit fire
    suspends its bills in place — queued orders stay, a running craft
    waits at the site — and feeding it resumes where it left off. The
    inspect panel toggles `auto_refuel` (default on) and its
    `refuel_fraction` threshold; below the threshold a `REFUEL` job
    posts and a unit fetches the best burn-seconds-per-metre pile
    (`nearest_fuel_voxel` — PROVISIONAL selection policy; diversifying
    fuels will want per-fuel preferences). Delivered fuel is consumed
    into burn-seconds; non-fuel strays are set down at the fire.
    Bootstrap material: `WorldGenerator.loose_rocks_in` scatters
    deterministic boulder/cobble clusters over the surface and the
    colony seeds them as real piles on stream-in, tombstoning
    picked-clean slots (`_rock_spent`) so re-streaming never restocks.
    **Balance note:** fruit servings were rescaled ~10× (2,500 cm³ ≈
    a 1,600 kcal meal's worth, 12 fruit per bush ≈ 30,000 cm³) — the
    whole food-volume/eat-rate economy is PROVISIONAL and needs a
    balancing pass once more food sources and the mood model land.
    Covered by `_test_campfire`/`_test_loose_rocks`. **Deferred:**
    stoves (steel), temperature/heat output, poor-light work penalties,
    meal-vs-raw morale deltas, food-poisoning rolls, multi-ingredient
    recipes, and additional fuels.

22. ~~**Bill details.**~~ **Done.** Item 16's queue got RimWorld's bill
    refinement pass. Until-bills gained the resume threshold (`unpause_at`
    — stock to X, resume at Y, defaulting to one under the target) and
    the stored-only counting flag (`count_stored_only` tallies only
    stockpile tiles; the default counts landed + in-flight + carried,
    matching RimWorld's in-flight behaviour). Bills suspend/resume
    (`paused` — a running job goes back on the board with its escrow
    intact), shuffle and clone via `move_order`/`duplicate_order`, gate
    ingredients by `ingredient_radius` and `rejected_materials`, and
    restrict workers through `worker_index` + the `skill_min`/`skill_max`
    band — `claim_job` hides ineligible jobs for the pick instead of
    drop-recording them, so a wrong-skilled probe can't put a colony-wide
    backoff on a pinned bill. Output disposition is per-order
    (`deliver_mode`: worker's feet, best admitting stockpile, or a named
    zone's nearest qualifying cell — the worker ferries the load itself),
    and `StockpileZone` carries a five-rung priority enum sorted
    rank-first/distance-second in `nearest_stockpile_with_room`, plus a
    dumping-stockpile preset (low priority, rubble-and-litter admits).
    The HUD order rows expose all of it — suspend, ▲▼, duplicate,
    condition + threshold, stored-only, deliver picker + zone target,
    radius, skill band, worker pin — and the stockpile panel picks the
    zone's priority. Everything serializes; missing fields fall to
    defaults on old saves. Covered by `_test_bill_details` and the
    persistence round-trip. **Deferred** (needs mechanics that don't
    exist yet): bills on pawns, medicine requirements, ingredient
    hit-point ranges, unfinished-item authorship, per-ingredient pickers
    richer than material class, and the radius outline on hover.

23. **Doors + rooms + the indoors predicate.** Doors are **done** —
    a `DOOR` building spans the sill cell and the headroom cell above
    (the capsule is 1.8 m, so a doorway is two voxels); the sill stays
    open air while the sim's `doors` set marks it, A* charging
    `DOOR_COST` to enter and the unit paying `DOOR_OPEN_SECONDS` at the
    threshold before the door closes behind it. A door spec derives from
    its wall (`door_of`): recipe +25% rounded up to whole items per form,
    the excess dropping as offcut — sawdust (WOOD) or gravel (STONE).
    The same spec table gained the plank wall: five planks, no offcut,
    fills the voxel. No dirt door; fences deferred to the animals item.
    Remaining: room detection — flood-fill open cells to the region edge
    / sky; a cell that can't reach either is *indoors*, a contiguous
    indoor region a *room*. Voxel queries make this cheap — no
    RimWorld-style roof entities needed; roofed simply means the cell
    has no vertical line of sky. Buildings can then read
    `is_indoors(voxel)` for speed/comfort modifiers. Open seams:
    flood-fill cost on mine/build (cache room membership, invalidate on
    boundary edits), doors vs fences/curtain walls for pens, and whether
    the sim or GDScript owns the room graph. Covered by `_test_doors`.

24. ~~**Outdoor deterioration.**~~ **Done.** A second decay axis in
    `DropItem.WEATHER_RULES`, rolled inside `_decay_tick` beside the
    organic rules: wood in every form weathers at 150 game-days —
    including cured planks and bed kits, which organic decay exempts —
    and foodstuffs weather at their organic lifetime, so an unroofed
    meal or fruit goes about twice as fast. The gate is
    `Colony.sees_sky` — the column scan factored out of `daylight_at`,
    which is exactly item 23's roofed primitive — so any solid voxel
    overhead shelters a pile (caves count), and the `is_indoors` room
    graph can refine it when it lands. Weathered volume just
    disappears: no compost, no fertilization, no sprout; organic rot
    claims a doubly-doomed item first so compost attribution stays
    deterministic, and for loose stacks only the organic share
    composts. Minerals exempt outright. Covered by the `_test_organics`
    weathering checks. **Deferred:** the rain multiplier (item 32),
    per-material rate tuning once weather exists, and a hover hint on
    weathering piles.

25. ~~**Recreation need + recreation buildings.**~~ Done: `recreation`
    drains while awake (a day and a half a bar); below
    `recreation_seek` an idle unit self-issues a `RECREATE` job —
    desperate-flagged like `EAT`/`REST`, never on the board. Activities
    are dictionary specs with a `kind` (tolerance category), session
    `seconds`, and flags (`sky`, `moves`, `partner`); free ones live in
    `Unit.REC_ACTIVITIES` — praying, meditating, skygazing (gated on
    `sees_sky`), going for a walk (accrues en route, waypoints chain),
    relaxing socially (borrows the nearest idle unit in
    `REC_SOCIAL_SEEK`, both gain) — and building-backed ones in
    `BlockRegistry.REC_SPECS`, one `occupant` claim each: horseshoe
    pin, hoopstone ring, game-of-Ur board, tafl table, billiards
    table, poker table, telescope (sky-gated at designation *and* at
    use), harp, harpsichord, piano — all construct-in-place through the
    campfire's `designate`/`CRAFT`/`complete_construct` path under
    Architect → Recreation. Repeating a kind grows `_rec_tolerance`
    (decays ~a week of days) so variety pays. Sessions end on fill,
    duration, losing the spot (roofed sky, torn-down building,
    wandered-off partner), or a hungrier need. Saved per unit:
    `recreation` + `rec_tolerance`. Covered by `_test_recreation`.
    **Deferred from the RimWorld activity list** — snowman (32's
    snow/weather), swimming (water mechanics), meditation-focus types
    (26's mood/ideology layer — plain meditate already ships), cheering
    up patients (28's medical), reading (book items), television
    (power + research), viewing art (34's beauty/beauty-objects),
    visiting graves (corpses/memorial buildings), beer/drug use
    (consumable chemical items + addiction model), gatherings
    (social-event system), gladiator duels (29's combat + arena),
    playing with a baby (reproduction/childcare), party spots and
    caravan idle (caravan system). Open seam: `recreation_seek_mult`
    already hangs on the `TRAIT_EFFECTS` seam for a future trait.

26. ~~**Mood + moodlets.**~~ **Done.** `Unit.mood` is a 0–1 bar that
    drifts toward `mood_target()` — base 0.32 (RimWorld's baseline)
    plus the summed offsets of live thoughts — at RimWorld's
    asymmetric rates (+12%/h rising, −8%/h falling), frozen while
    SLEEPING so break risk pauses with it. Thoughts live in the
    `THOUGHTS` data table: stored entries stack per-source up to a
    `stack` cap and expire per-stack over `days`; entries without
    `days` are state thoughts recomputed per tick. Wired sources:
    slept on ground / in a bed, ate raw food / a cooked meal, had fun
    / socialized (recreation sessions that actually paid), plus the
    state thoughts `starving`, `bored_stiff`, and gregarious-only
    `craves_company`. Break thresholds follow RimWorld's baseline —
    minor 35%, major at 4/7, extreme at 1/4 of major, with MTBs of
    4/0.8/0.5 days — shifted by `stress_vulnerability` and capped to
    the 1–50% band. Breaks so far are the mild end: minor moods binge
    on food (a desperate EAT job to full) or wander in a daze, worse
    spirals always daze — a zero-power `moves` recreation outing — and
    a finished break leaves `catharsis` (+0.15, 3d) so marginal units
    don't chain-break.

    **Personality is Dwarf Fortress-style facets, not RimWorld
    passions or categorical traits.** `Unit.facets` is a 0–100
    per-facet map rolled at spawn (`activity_level`,
    `stress_vulnerability`, `cheer_propensity`, `gregariousness`,
    `immoderation` — DF names); `facet_scale` turns a facet into a
    ×0.5–1.5 intensity multiplier that modulates which moodlets a
    unit can even have (`facet_min`/`facet_max` gates) and how hard
    they hit, plus behaviour seams like `_recreation_seek` and the
    break threshold. This stands in place of RimWorld's trait tiers —
    Lazy↔Industrious is a position on `activity_level`, not a flag.
    The older categorical `traits`/`TRAIT_EFFECTS` (ascetic, gourmand,
    iron_willed, immoderation) stay wired for now but are slated to
    fold into facet bands — e.g. gourmand ≈ `immoderation` ≥75 — so
    new personality behaviour should read facets, not new trait names.
    DF's **preferences** system (likes/dislikes feeding moodlets and
    work affinity) is a natural companion for item 44's generation.

    Deferred: aggressive/violent break tiers (berserk, tantrum, insult
    sprees) need combat and arrest (29); high-mood **inspirations**
    need a use for them first; environment thoughts — beauty and
    impressive rooms (34), cramped/dark rooms (23's room graph),
    soaked/cold (32), ate-without-table (47's dining set), corpses and
    witnessed death — wait on their systems. **Morale → work rate**
    stays deferred by design: when it lands it should be
    facet-modulated (activity_level for pace, stress_vulnerability for
    penalty shape), not a flat multiplier.

    **Modding note:** most of RimWorld's thoughts are XML data — our
    equivalent tables (`THOUGHTS`, `REC_ACTIVITIES`, `REC_SPECS`,
    `TRAIT_EFFECTS`, `BUILD_SPECS`, `DropItem`'s decay/weather rules)
    are already plain Dictionaries and are the cheap candidates for
    runtime spec files. The expensive side — pathing, the native sim,
    need physics — stays baked. Identifying which is which belongs to
    whatever item builds the loader.

27. ~~**Wildlife + hunting + butchering.**~~ Done. `Species.SPECIES`
    is the runtime-spec table — mass, health, speed, diet, temperament,
    butcher yields and unique drops per species; the colonist's own
    carry/drag/melee norms live there too. Five animals cover the
    categories: rabbit (small prey herbivore), deer (grazing herd
    animal, drops antlers), boar (omnivore that fights back, tusks),
    wolf (carnivore that hunts rabbits and deer when hungry), bear
    (large dangerous omnivore). `Animal` is a lightweight second
    entity class — same sim channel, no jobs — that wanders, grazes
    the grass cover (`grass.crop`), flees on approach (and tires, so a
    melee chase can end), fights back by temperament, and starves.
    `HUNT` designation picks the nearest live animal; the hunter
    chases, melee-ticks at range, and breaks off under a third of its
    health. Death drops a species-tagged `CORPSE` item — three-day
    rot — and the butcher spot (three cobbles, construct-in-place)
    posts a `BUTCHER` job when a corpse exists: haul the carcass over
    (dragging if it's big), then `butcher_seconds` of work scaled by
    the new `BUTCHERING` skill. Species `yields` fractions produce
    meat/leather/bone; extras are whole items; a level-0 butcher keeps
    75% and the rest — plus everything the spec doesn't name — falls
    to butchering scraps that compost in a day and a half, so carcass
    mass is conserved end to end.
    **Hauling is now mass-based**: items carry `mass_kg()` (volume ×
    per-material density in `RESOURCE_DENSITY`); a unit's load is
    gated per-item and in total by `drag_kg` and penalized above
    `carry_kg` at half walk speed — both species norms scaled by the
    new `strength` facet. Deferred: taming/domestication + pens (the
    fences from 23), `TAME` job, livestock grazing crops; manhunter
    rage on failed hunts; ranged hunting (needs weapons — 29);
    reproduction/herds; pack-animal hauling (the species carry/drag
    fields are already there); wheelbarrows/sleds for over-drag loads;
    **logs and boulders sit in an awkward middle band** — heavy enough
    to drag-slow every construction haul, sized before mass existed:
    revisiting their item sizes is an open follow-up. Predators don't
    yet stalk colonists (that's drafting + combat, 29).

28. **Health: injuries + tending + rescue.** ✅ Per-part wounds, not a
    pooled HP stat: `Unit.BODY_PARTS` (head/torso vital, arms `works`,
    legs `moves`) and `wounds` records `{part, kind, severity, bleed,
    care}` — hits pick a part by coverage and a wound kind by the
    attacker's species `wound_kind`. Open wounds bleed per game-day into
    `blood_loss`; severity knits at a care-tier rate (natural, +bed).
    Derived consequences: `mobility`/`manipulation` scale walk speed and
    work rate; `is_downed` (health line, blood-loss line, or a destroyed
    leg) drops the unit into `DOWNED`; `_lethal` (bar gone, vital part
    destroyed, bled out) → `die()` → a physical colonist `CORPSE` that
    the butcher search refuses (`yields`-keyed). Care tiers: field
    first aid anywhere stops bleeding only (care 1); a `medical`-flagged
    bed — toggled on the building panel — enables real treatment (care
    2), and a spent herbal bundle seals a share instantly (care 3).
    Wounded units self-seek a medical bed (`_start_medical_rest`) and
    stay for bedrest while hurt; the colony's `_medical_tick` posts
    `TEND` for the wounded and `RESCUE` for the downed under a free
    bed — patients haul by the mass rules: a rescuer's `drag_kg` must
    cover `patient.mass_kg()`, so some patients are simply too heavy.
    Medicine is real stuff: heal-all (*Prunella vulgaris* — the
    real-world selfheal, standing in while proper herbal compounding is
    deferred) seeds ~1/8 of wild bush slots, forages into `MEDICINE`
    bundles, and re-seeds from them (`FRUIT_SPECIES`). `MEDICINE` is a
    `ColonyJob.Skill`; `TEND`/`RESCUE` feed it. Open seams: infection/
    disease timers, surgery/operations — medicine-gated procedures on a
    bedded patient, RimWorld's "performing an operation" — a per-patient
    medicine policy (the Assign tab's role), herbal compounding
    (several plants → a remedy, deliberately deferred), pain/thought
    tuning, and grave/garbage handling for colonist corpses.

29. **Drafting + combat.** Done: inspect a colonist → Draft toggle on
    the unit panel ([D] in the colonist bar); with a drafted unit
    inspected, an RMB click orders a move (aimed cell) or an attack
    (animal under the cursor). Drafted units take no board jobs and
    service no needs — they hold a post and charge any animal that
    enters ATTACKING state inside the guard radius. Critical failure
    undrafts them: hunger/energy/recreation at the critical line,
    mood below the break threshold, or too badly injured — the line
    slides with the new `bravery` facet (timid fold early, stalwart
    hold deep). Being hit is itself the order: `take_hit` → `_engage`
    drops carried items and a carried patient, wakes a sleeper, and
    turns the unit on its attacker whether drafted or not. Combat is
    melee-adjacent via self-issued ORDER jobs riding the HUNT chase
    machinery; wounds feed 28's system. Equipment exists as one
    provisional `Unit.equipment` slot — the on/off-hand + clothing
    model (holsters, belts, backpacks; hand-occupancy carrying
    penalties) is deferred to apparel (37). Fortifications: dirt
    mound (loose-soil `input_cm3`/`input_material` recipe pins — new
    recipe keys) and wood/stone barricades — partial-height cover
    (`provides_cover`), a `COVER_CRAWL`/`PILE_CRAWL` traversal cost
    through `Colony.traversal_mult` for units and animals alike, and
    grass stripped on build. Open seams: ranged weapons + LOS (voxel
    raycast through open cells, cover blocking), spike traps (menu
    stub), friendly fire, unit-vs-unit, and multi-select drafting.

30. ~~**Combat damage to the world.**~~ **Done (melee).** Buildings
    and terrain take hits: `hp`/`max_hp` on `Building` rated by
    material class and kind, `_block_damage` per-cell on terrain,
    `damage_building`/`damage_cell` as the verbs — a wrecked
    construction deconstructs (same teardown, same material return),
    a wrecked block breaks as if mined, collapse cascades come free.
    Melee fights splash `combat_splash` onto the cell between the
    fighters plus stray neighbours; drafted units take `order_wreck`
    (RMB a construction) for intentional demolition; first damage
    posts a `REPAIR` job (Construction skill) that restores `hp`.
    Integrity reads on the inspect line and worksite panel; `hp` and
    block damage persist. Deferred: plant damage (item 40), ranged
    overshoots and explosives (need those mechanics), and whether
    wrecks drop "broken" goods — today a wreck pays like a teardown.

31. ~~**Quality.**~~ **Done.** Crafted goods roll
    `randfn(level/10 + 0.25, 0.25)` off the recipe's skill at
    completion — `job.quality` stamps every output item and any
    `builds:` product; a bed kit's roll transfers to the furnished bed.
    `DropItem.quality_tier` names awful→masterwork on item and building
    labels. Sub-zero is a botch: inputs refunded to the worksite floor,
    the bill requeues in the same hands, half XP, `botched_craft`
    thought. Reads: bed rest and tend seal ×(0.80+0.20q), recreation
    fill ×(0.70+0.30q), meal nutrition ×(0.95+0.05q). Quality is
    independent of material, persists on items and buildings, and pile
    groups don't merge unlike tiers. Open seams: weapons/tools/apparel
    reads when those types exist, meal moodlets, material-quality
    interaction (plasteel vs wood).

32. ~~**Weather + seasons.**~~ **Done (provisional).** `Weather` is a
    site-local sky owned by the `Colony` — region-scoping waits on the
    regional-generation work, and no synoptic-scale patterns exist.
    Four 15-day seasons off the planet clock; a seasonal solar
    declination makes day length itself seasonal. Cfa temperature:
    yearly sine 3→27 °C, daily sine ±5 °C phased low-before-sunrise /
    high-before-sunset, plus bounded mean-reverting noise. Five-state
    precipitation machine (clear ~60%, rain/snow, dry/wet
    thunderstorms at the per-season rates) with `saturation` tracking
    ground wetting; rare ±15 °C heat-wave/cold-snap events ramp over
    half days; storm states carry lightning — the ignition source for
    33. `light_factor` already gates plant daylight; weather +
    saturation + event state serialize on the colony record and the
    HUD clock line reads season/weather/temp. Open seams: region
    ownership, plant temperature effects (40), unit temperature
    effects (36), wind, forecast UI, other biomes.

33. ~~**Fire.**~~ **Done (provisional).** `Colony._fires` ticks
    per-cell fuel ledgers — ignition today is storm lightning through
    `ignite` (the funnel other sources plug into), posting a
    `FIREFIGHT` job per cell. Flammability composes block, building
    material, grass/bush/tree and pile ratings; spread rolls
    source×target flammability against laterals + up, suppressed by
    wet ground. Burn-out consumes contents (grass strips to a natural
    firebreak, wood blocks burn without drops via `world.mine`,
    buildings wreck through `damage_building`); saturation gates
    catching and precipitation triples burn-down. `FIREFIGHT` claims
    ahead of routine work, works a beside-the-target spot, and
    `beat_fire` drains fuel — a stomped fire leaves contents standing.
    Burning cells get a near-wall `traversal_mult`. Open seams:
    spread is probability-per-neighbour not fuel/heat-transfer,
    smoke, ambient-heat contribution (36), burn scars, and whether
    `CLEAR`-ing grass is the intended firebreak verb.

34. ~~**Flooring + beauty/impressiveness.**~~ **Done.** `Flooring` is
    a second decoration layer beside grass: face coverings keyed
    (open cell, face index into `FACE_DIRS`), dressing any of a
    cell's six exposed faces — floors underfoot, walls, ceilings —
    rendered as tinted quads in the same chunked dirty-refresh
    multimeshes, pruned when the backing block or the air cell goes.
    Three launch specs (`packed_dirt`, `flagstone`, `plank_floor`)
    ride the whole BUILD pipeline: pave designates a face-keyed
    BUILD job (`job.face_dir`), strip a face-keyed DECONSTRUCT,
    both reachable through Architect → Floors with face-locked
    drags. `Rooms` lazily flood-fills open components (doors seal,
    4096-cell cap, invalidated on any `block_edited`); a unit in a
    room reads the room's integrated score — mean per-exposed-face
    beauty, covered faces overriding bare block values, furnishings
    summing in — while outdoors it reads the sight-line mean of
    solid faces, coverings and beauty-bearing objects within 5 m,
    every credit requiring a clear voxel raycast (RimWorld's 8 m
    cut to 5; values scaled an order under RimWorld's since 3D
    exposes far more surface). Beauty refreshes per unit on a 3 s
    stagger and feeds drab/pleasant/impressive surroundings
    thoughts; raycast and cell-probe counts ride the HUD perf line
    (`beauty_rays_per_sec`/`beauty_cells_per_sec`). Open seams:
    move-speed and fire-resistance bonuses for flooring, room
    *stats* beyond beauty (space, cleanliness, impressiveness
    tiers), sculptures/fine furniture as crafted decor, art skill.

35. **Research** — DONE (provisional). Technology is held by people,
    not the colony: gated skills (`PIT_SMELTING`, `BLOOMERY_SMELTING`,
    `CHARCOAL_BURNING`, and `ELECTRICIAN` — reserved for item 36's
    powered builds) already refuse claims below level 1, so the "tech
    tree" is the knowledge model itself. The new machinery is the
    **research bench** (4 planks, construct-in-place) and the **Study**
    action on it: a worksite bill parameterized by item type, offered
    for every manufactured item type sitting in colony piles. The
    `study_*` pseudo-recipes are synthesized from each product's make
    recipe — `recipe_of` resolves them beside `RECIPES`; charcoal gets
    a hand-written make-record since no bill produces it. The student
    fetches the specimen, works a spell, and earns the make recipe's
    XP × (1 − level/10) — full at level 0, nothing at 10, and units
    at level 10+ can't claim the job at all. A fumbled study —
    0.6 × (2/3)^level — breaks the specimen into the materials that
    made it: the provisional break model until item integrity exists.
    Raw materials aren't studyable (nothing "makes" a log); found or
    bought goods are how a colony bootstraps gated skills without a
    teacher. Open seams: a real breakage/integrity model, an
    Intellectual skill pacing research, project-style unlocks for
    powers like electricity, region-level research sites.

36. **Power + temperature** — DONE (first pass). Two intertwined
    systems, both riding the worksite-scan cadence:

    **Manufactured stock.** New item forms `SHEET`, `WIRE`,
    `COMPONENT` per metal; `FORM_SUBSTITUTES` lets a sheet fill a
    plank slot by *volume* (two 50k sheets pay one 100k plank want)
    while material pins still bind — a wood-pinned slot takes no
    steel. Sheet metal and wire come from raw metal on the
    **metalworker's bench** (plank-or-sheet built) at full rate or a
    bare crafting spot at half — the `sites` table rates a recipe per
    worksite kind. The **fabrication bench** (sheet + 2 components)
    runs `machine_components`: 30k iron + 20k copper loose → 5
    components. The whole chain trains the new `MANUFACTURING` skill.

    **Power.** A fuelled **generator** (Electrician build, campfire
    fuel rules) puts 400W onto whatever conductor net it touches;
    nets flood through wired walls, pylons and generator cells on the
    six cardinal faces. **Conduit** is a face job like paving —
    copper wire run into a *constructed* wall (natural stone refuses),
    gated Electrician, and the wire lives in the wall's components so
    teardown hands it back. **Pylons** string freestanding lines and
    slow the cell's walk. Devices (150W heater, 200W cooler) powered
    while touching a fed net — brownout drops the cheapest-cell-last
    deterministically. The heater rolls a small fire chance while
    powered, worse in a plank housing.

    **Temperature.** RimWorld's perimeter-leak model adapted to the
    voxel graph: each `Room` carries one uniform temperature and a
    lazily-analyzed boundary where every exposed face earns a
    conductance — walls leak toward the space probed beyond them
    (halved past one layer, capped at two, material-irrelevant), a
    closed door breathes slowly, buried walls and roof with unbroken
    overburden pull toward the biome mean (15 °C), and open faces
    equalize fast. Flow divides by room volume for heat capacity.
    The **cooler** seals its wall-gap cell like a door leaf — which
    is what lets it hold two climates — and pumps cold-side heat to
    its hot side plus waste; the heater pours into its room. Rooms
    seed at ambient, carry their warmth across topology invalidation,
    and `temperature_at` gives units the indoor-vs-outdoor answer.

    Open seams: lamps + dark-work penalty (23's indoor read now
    exists), freezer preservation below 0 °C (organics decay
    unmodified), shock/fire risk from exposed conduit, insulated
    cable tiers, biome-varying mean temperature (a constant for now),
    cooler orientation UI beyond the designate-time bearing.

37. **Apparel + cloth.** A fibre crop (cotton analog — farmable species
    on the item-14 machinery) → weaving recipe → `CLOTH` bolt →
    tailored garments at a tailor worksite; leather from butchering
    (27) as the early alternative. Garments wear out, provide armor
    (29) and warmth (36). Also unblocks item 13's containers — bags
    are cloth goods. Open seams: wear/decay on equipped items,
    equipment slots vs carried cargo, and layering rules.

38. **Allowed areas, forbid flag, shelves.** The zoning/safety layer:
    per-unit allowed-area masks (keep colonists inside the walls),
    an item/building forbid flag that excludes it from hauling,
    eating, and crafting inputs, and shelves — low-capacity storage
    furniture that can be a named bill destination (22's output picker
    learns named targets). Open seams: area paint UI, whether forbid
    lives on `DropItem` or the pile, and shelf-vs-zone filter
    unification.

39. **Regional biomes.** A biome layer in regional map generation:
    temperature and precipitation fields deciding soil block types —
    each carrying its own `fertility`/`fertilizability` defaults and
    seed palettes — plus the weather those bands imply. This is where
    item 20's deferred axes land: soil *type* as a growth modifier
    distinct from fertility, and a third environmental band
    (temperature, with `temp_min`/`low`/`high`/`max` fields mirroring
    the light band) on species entries. Feeds 32's weather machine and
    36's ambient temperature. Open seams: biome field resolution vs the
    128² site grid, cross-region plant palettes, and whether biome data
    lives on the `Region` record or a coarser world map.

40. **Plant stress + death.** Item 20 drew the light band but no
    teeth: a plant held below `light_min` or above `light_max` accrues
    stress past a per-species grace period, then takes damage to
    death — glare typically killing faster than shade (a night can't
    kill a normal plant; a week might). Per-species grace and damage
    rates; the same shape later wraps temperature (39) and extreme
    fertility. Also unlocks inverted-band species: `light_max ≈ 0`
    plants that only grow in the dark. Open seams: damage model
    (health pool vs straight timer), what death leaves (a snag state?
    `_destroyed` tombstones already exist), and lamps (36) as a growth
    light source for indoor farms.

41. **Manual composting + fertilize jobs.** Compost today is a decay
    byproduct that fertilizes only where it happened to rot. Two jobs
    make it deliberate: composting — a worksite order or zone flag that
    speeds organics → COMPOST (or a hauling variant that collects
    compostable refuse into a pile that rots faster), and `FERTILIZE`
    — a haul-shaped job carrying compost to target soil cells (farm
    fields first, or a fertilize designation) that calls
    `colony.fertilize` on delivery. Open seams: zone flag vs building
    for the compost bin, work-seconds per cell spread, and the UI
    affordance (farm-field toggle vs painted designation).

42. ~~**Ore mining + processing → metal.**~~ **DONE.** Clay patches the
    soil band (sterile — no grass or plants; bloomery feedstock);
    mineral intrusions seed connected blobs in country rock on two
    seeded lattices (1–3-voxel outcrop hints, 3–9-voxel deep bodies)
    with per-ore `share`/`host`/`metal`/`furnace` specs
    (`BlockRegistry.ORES`); mining splits drops mineral/rock by share;
    ~1-in-6 surface scree piles are ore-bearing. Charcoal mounds
    (log + branches → supervised `BURN` → 0.3 m³ charcoal at 1.5×
    log fuel); crush bills at the craft spot turn ore boulders/cobbles
    into smeltable gravel; the pit smelter (cobbles) smelts
    malachite→copper and cassiterite→tin, the bloomery (clay) smelts
    hematite→iron — equal ore-gravel and charcoal in, half-volume raw
    metal out; native gold waits on the crucible. Knowledge gating:
    `GATED_SKILLS` (Pit smelting, Bloomery smelting, Charcoal burning)
    gate claims at level 1 — technology lives in units, spreads by
    `post_teach` lessons (drip XP capped at the teacher's own) and
    contemplation (15%-of-sessions insight into a random skill), and
    dies with its holders. Save format bumped to 2 — pre-42 saves are
    refused. Deferred: the crucible, the stone crusher building,
    manuals/trade/inspection knowledge paths, biome-specific country
    rock, alloy recipes, and everything metal unlocks (stove, tools,
    metal builds).

43. **Tool requirements on jobs.** Once units have equipment (lands
    with 29's combat kit), gate work on carried tools: CHOP wants a
    hatchet, MINE a pickaxe, etc. — a `tool` field on `ColonyJob` or
    the recipe row checked at claim/fetch time, with tool-less work
    either impossible or drastically slower. The loose-rock scatter
    (21) already bootstraps the stone for knapping primitive tools.
    Open seams: tool item durability, tool stockpile admission, and
    whether tools are carried items or equipment slots.

44. **Fetch radius for loose items.** `nearest_fuel_voxel`/
    `nearest_forms_voxel`/`nearest_haulable_pile`/`nearest_wall_voxel`
    search every pile in the colony — colonists will happily trek the
    map edge for a branch. Gate the searches on a home-area concept
    (RimWorld's): a painted or derived zone inside which idle-haul,
    craft-fetch, refuel-fetch and food-seek queries run, falling back
    to unrestricted search only when nothing in-area matches. Shares
    machinery with 38's allowed-area masks — likely the same painted
    layer read by the fetch queries instead of by the unit. Open
    seams: paint UI vs auto-derived (buildings + stockpiles footprint),
    per-job-type override (a player should be able to send someone
    out for a specific haul), and the spatial index the bigger map
    will want anyway.

45. **Colonist generation + roster growth.** `spawn_unit` is a debug
    verb; the real mechanic is a scenario-defined starting roster —
    a few colonists with randomized skill levels, **passions** (a
    learn-rate multiplier on `skill_gain_rate` plus a mood hook into
    26 — item 10's attribute seams are already in place), traits,
    and age/health quirks — plus a starting-item scatter on the map.
    Roster growth then comes from simulation events rather than a
    storyteller: a wanderer-joins arrival, rescue-and-recruit (28).
    Open seams: scenario/package data shape, arrival pacing without a
    director, whether newcomers spawn at the region edge and walk in,
    and where Social earns its keep (recruit difficulty, trade later).

46. **Schedule tab.** RimWorld's per-hour band assignment — Anything /
    Recreation / Work / Sleep — consulted at the idle and need gates:
    Sleep bands ground the rest-seek line, Work bands suppress
    recreation and idle, Recreation lets joy refill before work
    resumes. A thin layer over the existing needs model; its payoff is
    night shifts, forced convalescence (28), and giving 25's `RECREATE`
    a natural slot. Open seams: the hour-grid UI, whether bands
    override need thresholds or bias them, and drafted units ignoring
    the book entirely (29 wins).

47. **Furniture: seating, tables, comfort.** The Architect → Furniture
    stub fills in: dining tables + chairs (the "ate without table"
    moodlet hook in 26), bedside pieces feeding a comfort stat that
    raises rest quality on 7's bed model, and worksite seating. Every
    piece rides the bed's pipeline — kit item → `FURNISH` job →
    multi-cell building — so this is content, not new machinery. Open
    seams: comfort aggregation radius, eat-time chair/table adjacency
    checks, and kit economics vs carry limits (13).

48. **Stonecutting + stone blocks.** The Basics' early-materials arc:
    a stonecutter worksite batches boulders/cobbles into uniform
    `BLOCK` items, and stone walls get a block-keyed build spec —
    trading bench time for cheaper field construction, mirroring
    log → plank. Nonflammability is the real prize once 33 lands, and
    blocks are also the natural input for furniture/flooring. Open
    seams: block item size vs carry limits (13), whether the
    raw-boulder wall spec survives or phases out, and gravel offcuts
    feeding the recipe's remainder.

**Design fork — manual work priorities.** RimWorld's Work tab is a
per-colonist × per-work-type priority grid the player hand-tunes.
Delve's `claim_job` scoring (distance − skill − languish, with the
`specialize` toggle) is a different philosophy: the colony reacts to
skills instead of rosters. Decide before the UI hardens — a priority
grid can sit *on top of* scoring as a type-gate/multiplier without
replacing it, but bolting it on later means re-teaching players an
existing system. Deliberately deferred, not forgotten.

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

## Follow-ups on shipped work

Loose ends left behind by done items — smaller than roadmap entries,
bigger than a commit note.

- **Detour selection still walks before it knows.** The ungrabbable-pile
  fix (blacklist + shove fallback in `_detour_arrived`) stopped the
  detour loop, but the unit still travels to the pile before learning
  nothing fits: `nearest_stockpile_with_room` asks for 1 cm³ of room
  while `_set_haul_destination` already computes "room for the biggest
  unsplittable item". Pass the pile's smallest admitted item volume as
  the load so hopeless detours never start.
- **Occupancy claims are pairwise, not systematic.** The generated
  rock-pile/tree collision was fixed per-pair (sapling discovery skips
  piles, rock seeding skips tree roots, `plant_sapling` refuses piled
  cells) — but a pile is invisible to `is_solid`, so every future system
  that claims a cell must remember `item_pile_at` itself. A shared
  "cell claimed" predicate would retire the whole bug class.
- **Fallback pathfinder parity.** The engine `VoxelAStarGrid3D` sees
  neither ladders (item 8) nor door sills (item 23) — moot while unit
  motion is native-only, but the divergence grows with each traversal
  feature added to the native sim.
- **Room detection** is the live half of item 23 — doors shipped, the
  indoors predicate hasn't. Everything downstream (24's deterioration,
  26's cramped-room moodlet, 36's coolers) waits on it.
- **Food economy balance.** Item 21's rescale is provisional — the
  fruit/meal volume math wants a pass once recreation (25) and mood
  (26) exist, so hunger pressure is tuned against the full needs model.
- **Bed-kit fiction.** Item 7's packed-bed-as-one-voxel item is a
  placeholder for real furniture dimensions; item 46 may retire it.
- **`planet_time` promotion.** The shared clock is per-site-correct
  today; it must move onto `Region` when a second site activates
  (items 6, 18).

## First milestone

Items **1–3** as one milestone — drag-designate a hillside, trees get chopped,
planks get built — gives a playable "gather → build" loop that everything else
hangs off of.
