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
   soil → dirt block, 120 dressed blocks → `STONE_WALL` (item 48), one
   log → `LOG_WALL`. Delivered items are recorded per-form (`job.delivered`)
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
   Beds are furniture: designated straight onto their cells through
   the furniture catalog (item 47) — a `CRAFT` job with the `bed`
   recipe builds the two-horizontal-cell `Building` in place from five
   planks. Deconstructing a bed from either cell wakes the sleeper and
   hands the planks back; an *uninstall* instead packs it into a
   furniture crate for the warehouse. Covered by `_test_rest` in the
   smoke test. **Done (hunger, first slice).** `Unit.hunger` drains
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
    stockpile filters. **Update since deferral:** the mass model
    landed (item 27) — `mass_kg()` via `RESOURCE_DENSITY`,
    `carry_kg`/`drag_kg` caps — which relocates the seam: discrete
    items should gate on *mass* (a 1 m³ log at ~600 kg drags fine),
    not on `carry_capacity`, which was sized for loose pours — landed
    in item 49: `take_up_to`/`take_form`/`take_wall` accept a `lift_kg`
    allowance, so an over-cap discrete item still comes along when its
    mass fits the drag limit.

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
    mid-job. The attribute seam landed as `Unit.traits`/`trait_factor`
    and has since folded into facets (item 26's architecture won) —
    `immoderation` and `stress_vulnerability` now slide the thresholds
    and meal size. Open seams: mid-job interruption (a facet-gated
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
    facets, skill XP, stance), piles + items, buildings + worksite orders,
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
    `activity_level` widens the reach — a restless unit grabs farther
    off-route. Covered by `_test_opportunistic`.

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
    `_test_plant_environment`. Deferred: soil *type* waits on regional
    biomes (item 39); plant damage/death from sustained out-of-band
    light and temperature — per-species grace periods, glare faster
    than shade — landed with item 40; the manual composting/fertilize
    jobs are item 41. Still open from the original scope: tree
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
    including cured planks and furniture crates, which organic decay
    exempts —
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
    caravan idle (caravan system). `activity_level` already slides the
    recreation-seek line — the old `recreation_seek_mult` trait knob is
    gone with the trait system.

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

    **Expectations** — RimWorld's bootstrap cushion: `Colony.
    founded_msec` (serialized; old saves found at load) starts a
    +0.30 `expectations_bonus()` that decays linearly to zero over
    the first 15 colony days, added straight into `mood_target()`.
    Settlers expect hardship, not comfort — the colony has a
    fortnight to substitute real amenities before the cushion is
    gone. `slept_on_ground` also caps at 2 stacks (−0.10) instead of
    5: the sharpest stacker was a mood death sentence for a colony
    that simply hadn't built beds yet.

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
    iron_willed, immoderation) are now folded in — the appetite traits
    became positions on `immoderation`, iron_willed a low
    `stress_vulnerability`, and saved trait ids load by nudging the
    matching facet toward its band end.
    DF's **preferences** system (likes/dislikes feeding moodlets and
    work affinity) is a natural companion for item 44's generation.

    Deferred: aggressive/violent break tiers (berserk, tantrum, insult
    sprees) need combat and arrest (29); high-mood **inspirations**
    need a use for them first; environment thoughts — beauty and
    impressive rooms (34) and cramped/dark rooms (56) since landed —
    soaked/cold (57), corpses and witnessed death — wait on their
    systems. **Morale → work rate**
    stays deferred by design: when it lands it should be
    facet-modulated (activity_level for pace, stress_vulnerability for
    penalty shape), not a flat multiplier.

    **Modding note:** most of RimWorld's thoughts are XML data — our
    equivalent tables (`THOUGHTS`, `REC_ACTIVITIES`, `REC_SPECS`,
    `BUILD_SPECS`, `DropItem`'s decay/weather rules)
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
    revisiting their item sizes is an open follow-up. Since then the
    conservation audit found the sharper problem in the same place:
    `LOG_CM3` equals `carry_capacity` because it was fit to the volume
    cap, and a 1 m³ trunk voxel fells into a single half-metre log —
    half the wood vanishes. The resize and the mass-bound take path
    are queued in item 49. Predators don't
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
    `builds:` product, furniture included; a crate reinstall keeps the
    piece's roll untouched.
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
    (`beauty_rays_per_sec`/`beauty_cells_per_sec`). Item 68 closed
    the remaining seams: floor speed/fire-resist bonuses, room
    *stats* beyond beauty (use, cleanliness, wealth, impressiveness
    tiers), sculptures as crafted decor, the art skill.

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

37. **Apparel + cloth** — DONE (first pass). Cotton joins `Plants.SPECIES`
    as the second annual: the harvest pours raw `COTTON` (loose, organic
    decay, no seed) which the tailor's bench — a new production
    worksite — weaves into `CLOTH` while combing the sowing's seed back
    out. Cloth never rots but weathers outdoors like wood. Garments are
    `GARMENT`-form `DropItem`s carrying a `spec` into `APPAREL_SPECS`
    (tribalwear, tool belt, backpack — cloth or leather input), a `wear`
    value that frays at a slow trickle, and RimWorld-style body layers
    (`ON_SKIN`/`MIDDLE`/`SHELL`/`UTILITY`) that conflict. The bench's
    synthesized `repair_*`/`salvage_*` bills pin the garment by
    `input_spec`; a repair's material bill is the make cost scaled by
    wear and restores 80%, a salvage returns half the make cost scaled
    by wear. Equipment: units have two `hands` (a tool each halves
    hauling, both forbid it), garments lend holsters (the belt's two)
    and carry bonuses (the pack's ×1.5), a haul-bound unit stows held
    tools into free holsters, and idle units dress themselves —
    swapping up to better-wear kit, which is how worn garments reach a
    pile for the bench. Threadbare kit falls off and drops. Saves
    migrate the old single `equipment` slot into a hand.

    Open seams: armor/warmth effects (29/36 wired the slots, not the
    stats), tool production and use (TOOL_SPECS has knife/pickaxe
    records but no recipes), two-handed tools (the flag exists), more
    garment types and layer coverage, a strip order for direct removal,
    bag-for-hauling beyond the backpack's passive bonus.

38. **Allowed areas, forbid flag, shelves.** Done: `AllowedArea`
    records — named, player-painted cell sets in `Colony.areas` with
    their own marker overlay — assignable to units and animals; every
    `nearest_*` query and `claim_job` gates on `Colony.in_area`,
    `ORDER` jobs exempt, an out-of-bounds restricted unit walks home
    via `nearest_area_cell`, and reassignment drops a job outside the
    new bounds. `DropItem.forbidden` is the per-item flag (toggled at
    pile granularity): every colonist take path skips it and
    `ItemPile.take_up_to` enforces it internally, animals opting out
    per call. Shelves are `Building.Kind.SHELF` (2 planks, Architect
    > Storage): their cell is a stockpile tile — same filters and
    priorities — at `SHELF_PILE_CM3` (2× floor); teardown removes the
    zone and re-caps the pile. Stockpile filters copy/paste between
    zones and save/load as named `user://` presets (`FilterPresets`).
    `STORAGE_REPORT.md` tabulates every storable resource by class,
    mass and volume. Open seams: per-form shelf packing factors (the
    report's recommendation — shelves should stack discrete items
    tighter, not just hold twice as much), shelves as named bill
    destinations (22's output picker), area-aware haul *source*
    restriction (a restricted unit can still be assigned to grab an
    out-of-bounds pile if the destination is in — ORDER-only today via
    the fetch-leg area checks), and multi-cell shelving units.

39. **Regional biomes.** A biome layer in regional map generation:
    temperature and precipitation fields deciding soil block types —
    each carrying its own `fertility`/`fertilizability` defaults and
    seed palettes — plus the weather those bands imply. This is where
    item 20's deferred axes land: soil *type* as a growth modifier
    distinct from fertility, and a third environmental band
    (temperature, with `temp_min`/`low`/`high`/`max` fields mirroring
    the light band) on species entries. Feeds 32's weather machine and
    36's ambient temperature. **Groundwork landed**: the three-layer
    world now exists — `WorldGlobe` (Goldberg sphere, ~180k hex/pent
    tiles on a moon-sized planet, macro elevation/temperature/
    precipitation per tile), `MesoMap` (per-tile flat 100 m heightfield,
    rim-pinned to neighbouring macro heights), and the site embedding
    (`Site.world_tile` + `install_regional_grid` feeding
    `WorldGenerator._regional_base`, parity-mirrored in DelveGenerator).
    **Macro biomes landed**: the globe picks its sea level from a
    percentile cut of the raw height field at the ocean-coverage slider
    (0–95 %, steps of 5, default 70 — 100 % unreachable on purpose),
    applies latitude/altitude temperature with a hot/cold bias and
    noise-only precipitation with a wet/dry bias (no circulation or
    orographic models yet), and classifies every tile against the
    Whittaker temperature × rainfall bands — ocean under the line, ice
    cap where frozen. Swamps deliberately can't come out of this table:
    rainforest vs. swamp is a drainage question, so low-drainage
    variants wait on the riverine model. The three options are
    inspector sliders on `Main` and ride `world.json`. **New-world UI
    landed**: `scenes/worldgen.tscn` is the entry scene — stage 1 takes
    the seed (prepopulated random) plus ocean/temperature/rainfall
    sliders, stage 2 renders the planet as a rotatable globe (per-cell
    biome fills over a dark sphere — the grout is the cell outline)
    and the player clicks a tile to embark on; water tiles (ocean and
    ice cap) refuse. Embark stages `Main.pending_world`, consumed by
    the fresh-boot path to seed the generator, apply the sliders and
    settle the picked tile; a fourth slider sets the planet's axial
    tilt. **Macro→micro climate landed**: `MesoMap` now carries
    per-cell mean temperature (altitude-lapsed against macro
    elevation) and precipitation alongside height, and
    `_apply_site_climate` writes the tile's latitude/longitude onto
    the `DayCycle` and derives `Weather.site_climate` — meso mean is
    the annual temperature, sin(lat)·tilt scales the ±12 °C seasonal
    swing (southern sites run a flipped calendar), and annual cm
    scales the precipitation share off the 100 cm/yr reference Markov
    (40% wet), capped at 0.85 so wet climates still see dry spells.
    Remaining: a title/load flow in front of worldgen (the options
    panel has a bare Load button for now), rain *modality* (Seattle's
    drizzle vs Chicago's bursts — the current model stretches clear
    spells, it can't vary intensity), biome→weather/plants hookup
    (item 20's soil axes — the soil-type half is landing under the
    soils/hydrology pass below), off-site travel over the meso layer,
    and incident site instantiation. Open seams: biome field
    resolution vs the 128² site grid, cross-region plant palettes,
    and whether biome data lives on the `Region` record or on the
    world tile.

39b. ~~**Soils and hydrology.**~~ **DONE** (post-plan loose end, see
    DESIGN *Soils and hydrology*). `SiteField.generate` runs one pass at
    site install over a ~1.5 km / 4 m window of the effective surface:
    bucketed priority-flood depression fill → D8 flow accumulation →
    lake basins `{cells, level, outlet}` plus a per-cell `spill` datum,
    river channels (catchment ≥ a precipitation-scaled threshold) carved
    3 m as a bilinear *drop* raster with water 1 m below grade, wetland
    and shore rings. Water is a level datum — `water_level_at` on both
    generators, `WaterView` draws the surface skin, `DelveSim` and the
    fallback `is_standable` block head-deep water. Soils: per-cell biome
    classification → pack `soil` spec weight tables resolved into clumps
    by two seeded noise channels (`RICH_DIRT` 1.4 / `POOR_DIRT` 0.7 /
    `DIRT` 1.0 topsoils all mining to generic `SOIL`; `SAND`, `PEAT` —
    a bulk fuel — and `FROZEN_GROUND` appended for save compat); depth
    is spec × warmth×moisture × slope in quarter-metres. Farming/grass/
    sprout predicates unified on `fertilizability`. Rasters install into
    both generators like the regional grid — `gen_parity` covers the
    fielded path. Covered by the worldmap site-field checks. Deferred:
    dynamic basin level events, player dam/outlet re-spill (the `spill`
    datum is the hook), swimming/wading costs, spawn-point dry-land
    pick.

40. ~~**Plant stress + death.**~~ **DONE.** Plants carry a hit-point
    pool (`hit_points` per species) that accrues cumulative damage
    from every source through `Plants.damage`/`Forest.damage`.
    Temperature rides a second `PlantGrowth` trapezoid — three nested
    °C bands (`temp_opt`/`temp_grow`/`temp_dorm`): full growth, slowed
    growth, dormant-unhurt, then damage ∝ °C of overshoot beyond
    dormant, read through `colony.temperature_at` so heated rooms
    matter. Light stress runs on per-species grace timers
    (`shade_grace_s`/`glare_grace_s`) on the record — `dark`/`glare`
    accrue out-of-band and bleed off at half rate in-band, so a normal
    night never bites but sustained darkness or glare does (glare
    ~5× faster). At the threshold the plant dies to a standing corpse:
    bushes brown and decay to a compost pile on `decay_seconds`;
    trees stop growing/fruiting, shed the browned canopy to compost,
    and leave the snag standing for the axe. Survivors harvest light —
    forage, felling and fruit drops scale by remaining health. Fire
    already plugs in (`_fire_tick` bleeds burning cells' plants); the
    model is the seam for explosions, storms and combat. Deferred:
    manual cut-plant/tilling (item 41), lamps as crop lighting (36),
    inverted-band dark-growing species. Covered by
    `_test_plant_environment`.

41. ~~**Manual composting + fertilize jobs.**~~ **DONE.** Compost is
    deliberate on both ends now. The compost bin (Architect →
    Furniture, four planks — sheets substitute) is a one-cell storage
    building on the shelf model: its stockpile zone's preset filter
    admits only `DropItem.compostable_materials()` — the decay rules
    carrying a compost fraction — and outranks general stockpiles at
    HIGH priority so refuse hauls itself in, while finished compost
    isn't admitted and hauls back out. Its cell's organic decay runs at
    `COMPOST_BIN_BOOST` (3×); weathering is unaffected, and COMPOST
    itself is exempt so the product keeps its own clock. On the output
    side, `FERTILIZE` jobs (Plants, sow-shaped: fetch loose compost →
    spread → `colony.fertilize` at `FERTILIZE_PER_CM3`) come from two
    drivers sharing one `_fertilize_jobs` cell index — painted marks
    (`designate_fertilize`, Architect → Zones) that repost until the
    soil hits `FERTILIZE_PAINT_TARGET` (2.0), and a farm field's
    auto-fertilizer ("Fertilize soil" toggle + 0.5–5.0 target slider on
    the farm panel, unplanted cells included). No-compost suspends jobs
    like the seedless-sow gate; everything serializes; the cancel sweep
    lifts marks. Covered by `_test_compost`.

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
    refused. Deferred: manuals/trade/inspection knowledge paths and
    the rest of what metal unlocks (tools past the iron set, metal
    builds). The crucible, the stone crusher, alloy recipes,
    biome-specific country rock and the stove landed with item 67.

43. ~~**Tool requirements on jobs.**~~ **DONE.** `Colony.required_tool`
    gates work: CHOP wants an axe, MINE splits at
    `HARD_MINE_HARDNESS` (2.0 — dirt/clay soft, stone and ore hard) —
    soft takes a shovel or pick, hard the pick alone. A claimant
    without the class fetches one (`nearest_tool_voxel` + a fetch leg
    on the same `_fetching` machinery builds use); none anywhere hands
    the job back like a starved build. Tools ride one hand and stow to
    the belt's slot-indexed holsters — `holster_prefs` reserves a slot
    per tool spec (unit panel, one picker per slot; `&""` is
    anything-goes). `TOOL_SPECS` carries class, head material, per-use
    rate and `life` in hardness-units: the stone set knaps at any
    crafting spot from `ROD_MATERIALS` + two cobbles at half speed
    (the pick a quarter on hard), the iron set forges at the
    toolmaker's bench from a rod + two raw-iron units (`TOOL_METAL_CM3`)
    at 1.2×/800-life. Wear drains per progress; a spent head breaks in
    place — haft back whole, head as loose gravel, no re-forming.
    Metal heads repair at the bench (`repair_<spec>` pseudo-recipes,
    wear-priced metal at one unit per 40% restored, capped at 80%).
    The bench is fuelled but exempt from the ambient burn —
    `burns_passively` splits the kinds; the craft tick pays fuel per
    work second and a cold forge queues without dispatching. Deferred:
    bulk tool profiles, weapons as tool classes, and butchery/tool
    needs beyond mine/chop. Covered by `_test_tools`.

44. ~~**Fetch radius for loose items.**~~ **DONE.** The home area —
    RimWorld's, extruded to 3D: a colony-wide `home_cells` set the
    player paints and erases with the Zones expand/erase tools, plus an
    areas-panel row with the live cell count and an *Auto-expand*
    toggle and a bottom-right Home-area overlay switch. With auto on,
    each completed building/furniture footprint cell, conduit line
    (`complete_conduit`), stockpile and farm designation pulls the
    3×3×3 cube around itself in (`_grow_home_around`); save-load
    registers buildings with `grow_home=false` so paint the player
    erased stays erased. The spawn gates read membership, never
    terrain: `_post_repair` and `_post_firefight` return early off-home
    — a wilderness fire burns on and a battered far-flung wall goes
    unmended — and since firefighting bills re-derive from the fires
    list on load, `home_area`/`auto_home` restore ahead of it. Fetch
    is a preference rather than a wall: `_home_match` demotes an
    out-of-home candidate to `_Match.RETRY` inside the bucketed
    `_nearest_indexed` search (seed, food, haulable, wall-material and
    form fetches), so in-home goods win at any distance and the
    outside pick only applies when home can't serve;
    `nearest_fuel_voxel`'s score loop carries a parallel best-home
    pick for the same rule. Membership is an O(1) dictionary read;
    `nearest_home_cell` answers "walk back inside" off the dedicated
    `_home_buckets` spatial index. Deferred: cleaning jobs (no dirt or
    mess sim yet — the gate seam is ready) and a per-job home
    override for deliberate far hauls. Covered by `_test_home_area`.

45. **Colonist generation + roster growth.** The data-package layer is
    in: `DataPackage` (`scripts/data/`) registers baseline packages —
    biome table + first-match Whittaker `biome_rules`, `animals`,
    `plants`, `trees`, the worldgen species palette, the wildlife mix —
    and scenarios: `settler_count`, per-settler `skills`/`knowledge`
    rolls over a background `skill_range` band, founding `animals`
    (domestic-flagged), a landing `items` scatter, and an `entry` rule.
    The worldgen screen picks the baseline package at stage 1 (biome
    assignment consumes the rules) and the scenario beside Embark; both
    ids ride `pending_world` and world.json, and `spawn_initial_units`
    applies the roster — `lost_tribe` is the reference (five settlers,
    three domestic boars, knapped tools, charcoal knowledge), `dev` the
    bare debug landing. Post-embark arrivals go through
    `spawn_settler`/`periphery_entry`/`Unit.arrive` — a traveller's
    bearing casts back across `site.bounds` to the edge it crosses.
    Still open: **passions** (a learn-rate multiplier on
    `skill_gain_rate` plus a mood hook into 26), per-settler
    customization at embark, age/health quirks, non-`periphery` entry
    kinds, the mesomap travel path that supplies the bearing, and the
    roster-growth events themselves (wanderer-joins, rescue-and-recruit
    28) — arrival pacing without a director, and where Social earns its
    keep (recruit difficulty, trade later).

46. **Self-scheduling — done.** The RimWorld schedule tab is
    deliberately *not* built: its per-hour bands impose a
    micromanagement load the game shouldn't ask players to carry
    (DESIGN.md, "Self-scheduling"). Scheduling is goal-driven instead —
    the SmarterScheduling model — and already lives in the needs gate:
    mood therapy (`_mood_therapy_line` seek + `_decompressing` latch
    through `_mood_release_line`), colony alertness while
    `care_pending()`, and `Unit.relieved` as the player's stand-down
    control. Remaining seams from the mod's feature set, for when their
    systems land: a party/event override (no events yet), patient
    feeding policy (wait-to-be-fed vs feed-themselves — item 28's
    convalescence work), night-owl/handler schedule drift (no trait
    analog or animal sleep worth syncing yet), and a colony-level
    posture toggle if a raid/caravan phase ever needs one.

47. **Furniture — done.** The Architect → Furniture menu fills in with
    the core RimWorld furniture set (minus DLC pieces): sleeping spots,
    bedrolls, single/double/royal/hospital/animal beds, stools, dining
    chairs, armchairs, couches, four table sizes, shelves, end tables,
    dressers, bookcases, plant pots, and torch/standing/floodlight/sun
    lamps. The machinery changed shape entirely: the packed-kit fiction
    is gone — furniture is a `BlockRegistry.FURNITURE_SPECS` catalog
    entry built **in place** by a `CRAFT` job whose recipe `builds` the
    piece over a real footprint (`furniture_cells` tries both rotations
    and every anchor-corner role), with quality rolling onto the
    building rather than a kit. Higher pieces gate behind
    `COMPLEX_FURNITURE`/`ELECTRICIAN`; powered lamps join the power net
    and `sun_lamp` feeds `grow_light_at` for farm cells.
    **Uninstall/reinstall shipped with it**: an uninstall order packs
    the piece into a `CRATE` item — exact components, quality and wear
    inside, a delivered plank/sheet shell wrapped outside — and a
    matching crate satisfies the furniture bill whole (the drag-fetch
    treats it as mass-gated, not volume-gated), reinstall returning the
    shell as loose items. Crates only store in the new **warehouse**
    zone (`StockpileZone.warehouse`, deeper cell capacity), which stays
    a distinct class on zone merges; `designate_unpack` spills the
    real contents back. Legacy saves migrate: `FURNISH` jobs load as
    `CRAFT`-bed orders and `BED` items as packed bed crates. Eat-side
    the "ate without table" thought is live (`_finish_meal` checks for
    a table in `MEAL_AURA_RADIUS`). Remaining seams: a comfort stat
    aggregating seating/beds into rest quality (26's mood work), the
    chair/table adjacency elegance of RimWorld's dining check, beauty
    aura sources for decor, and DLC-tier pieces (boulder/mech furniture
    families) when their systems exist.

48. ~~**Stonecutting + stone blocks.**~~ **Done.** `Form.BLOCK` is the
    dressed 5 L stone unit (`STONE_BLOCK_CM3`), cut at the
    stonecutter's bench (`STONECUTTER` — two planks and a boulder for
    the cutting bed, so it stands before its own product exists). The
    `cut_blocks_*` bills are site-pinned to the bench and material-
    pinned to plain stone: a cobble dresses to 1 block + 5 L gravel, a
    boulder to 12 + 40 L — exact conservation either way. The work
    paces on Crafting but the recipe's `xp: 0` keeps it uneducational.
    Masonry retools onto blocks: `stone_wall` takes 120 (down from a
    cubic metre of field rubble — dimensioned stone lays tighter),
    `flagstone` takes 20 a metre, and `stone_door` derives an exact 150
    (no rounding offcut). The raw-stone path survives only where
    rubble belongs — the dry-laid cobble barricade — plus crusher
    feedstock. Nonflammability is still the prize once 33 lands. The
    crusher and the differentiated cut stones landed with item 67 —
    `crush_*` folded off the craft spot into the machine, and every
    country rock answers the stone pin.

49. **Conservation + footing pass.** DONE. Repairs the leaks the
    item-model audit logged (DESIGN.md, "The conservation ledger").
    Mass: a trunk voxel fells into a whole 1 m³ `LOG` (~600 kg) and
    `take_up_to`/`take_form`/`take_wall` accept a `lift_kg` allowance —
    a discrete item over the volume cap still comes along when its
    mass fits the unit's drag limit, spending kilograms not volume.
    Smelts: the gangue half tails out as host-rock loose slag beside
    the metal. Destruction: `built_recipe_of` maps a built block back
    to its recipe, so mining a wall returns scrap at the invested
    volume — wood splinters loose, stone shatters to deterministic
    boulders/cobbles for the saw. Footing: pile fill splits into
    loose (raises the floor) and clutter (discrete goods, never
    footing). Clutter costs `1 + 4f²` on the entered cell — a curve
    that steepens quadratically to the 0.75 m³ dense threshold, where
    the heap blocks passage and reads as flimsy cover (melee splash
    erodes its items). A pour under a stander lifts them while the
    cell two up is free; with it blocked the pour stops at headroom
    and the surplus evicts to a neighbour. A shrinking pile drops
    the stander back down. Open seams: clutter-aware fetch selection
    (a unit still walks to a dense pile before learning it's shove
    work), and whether dense heaps want a hit-point pool of their own
    instead of pure item erosion.

50. **Dynamic water.** **IN PROGRESS** — see DESIGN *Dynamic water*.
    Supersedes the static level-datum model's deferred seams (basin
    level events, dam/outlet re-spill): a live per-cell volume sim in
    `DelveSim`, voxel-resolution, shallow-water flux exchange on a
    ~200 ms tick, sparse chunked storage + dirty-set ticking.
    `SiteField`'s raster stays the worldgen authority and seeds the
    initial volumes; `water_level_at`/`water_depth_at` switch from
    `field.flood` reads to sim reads behind the same signatures so
    standability, vegetation gates and WaterView inherit live water.
    **Landed**: sparse chunked cm³ store seeded from `field.flood`,
    5 Hz step inside `sim.tick` — gravity pour first, then head-driven
    exchange where a cell's head is its connected body's free surface
    (saturated verticals conduct, so culverts fill bottom-up —
    Timberborn 1.0's stacked-column rule, communicating vessels),
    Jacobi deltas, active-set ticking, dirty-column stream feeding a
    tiled WaterView; displacement on fill and re-activation on dig;
    standability/pathing read live water; rain and evaporation are in
    (river columns evap-exempt until upstream inflow exists); water
    state round-trips as a delta vs the deterministic seed. The
    embark settle storm (raster-vs-voxel disagreement, DESIGN) is
    bounded by a per-step cell budget, epoch-stamped component
    labels and amortized evaporation (~60 ms/step during the storm,
    ~0 settled); `water_set_paused` freezes the step for the
    deterministic smoke suite — movement coverage lives in the
    flow probe.
    **Remaining**: (a) river-edge source/drain pairs from `flow_next`
    — wire them together or not at all, a lone drain empties its
    reach; (b) regulated edges (dam/levee/floodgate buildings scaling
    edge flux); (c) flux consumers — water wheels, pumps,
    irrigation→fertility; (d) momentum/flux smoothing for dramatic
    dam-breaks. Anti-goals for v1: no second fluid, no erosion, no
    pressure waves beyond the comp-head rule. Careful with:
    flux-clamp stability, path invalidation on flood.

### Phase 3 roadmap

Everything numbered below is either the open remainder of item 50 or a
deferred seam whose dependencies have since landed — ordered by
dependency and leverage, as usual.

51. **Water: river-edge source/drain pairs.** Item 50's (a). **Done**:
    `SiteField.river_boundaries` walks `flow_next` off the site window
    — upstream-edge river cells become sources at a rate ∝ accumulated
    catchment (scaled by `Weather` precipitation), exit-edge cells
    become drains, paired per wet component inside the field so a
    spring-reach feeding an internal basin takes no drain. Soggy
    non-river cells get neither. `main.gd` registers the pairs after
    `water_seed_flood` on both fresh and load paths (they re-derive
    from `field`, nothing serializes); `Site.default_bounds` supplies
    the rect before the Site record exists. Rivers now carry in as
    live boundary conditions instead of static seed volume — the
    smoke site logs 16 source / 16 drain columns. **Done — extra**:
    the flow overlay (toggleable, default off, HUD "Flow").
    `DelveSim` now accumulates per-cell outflow vectors during
    `water_step` (vertical + lateral, cm³ direction-weighted) and
    exports column-top cells via `water_flow_field`;
    `scripts/world/flow_view.gd` polls it at the water cadence and
    draws yaw-oriented arrows on the skin — length/color ∝ flux,
    near-vertical flux collapses to a marker, sub-`MIN_FLUX` churn
    (rain noise on lakes) is filtered. Same datum feeds the item-53
    flux consumers. `water_boundary_probe` covers the pairing rules
    and the live pour; `flow_shot` is the visual check. Known limit:
    the colony camera clamps to site bounds while the field spans
    1536 m — field-edge rivers flow beyond camera reach, and
    in-bounds carry is modest, so arrows there read subtle.

52. **Water: regulated edges.** Item 50's (b). Done. The native seam
    `water_set_edge_scale(cell, dir, factor)` stores a continuous 0..1
    throttle per undirected edge (canonical low/high cell-key pair —
    naming either endpoint hits the same record; ≥1 clears back to
    open) and scales the head-driven transfer in `water_step`, so a
    half-open gate moves half the water rather than flickering — the
    Timberborn lesson. `water_edge_scale_at` reads the factor back for
    tests and diagnostics. Player-facing shape: the **floodgate** —
    four planks, construct-in-place on an open cell over solid ground,
    in or out of the wet — throttling its cell's four lateral edges
    from an "Open" slider (5% steps) on its inspect panel. The
    fraction rides the building record; registration replays the
    scales onto the sim on load the way seeded volumes do, and
    teardown/mining returns the edges to unregulated flow. A gate
    seals flow at its own level — deeper water overtops it; a channel
    deeper than a cell wants the curtain built from terrain too. Dams
    and levees stay pure terrain — no building kind needed. The
    `floodgate_probe` tanks prove sealed/half/open volumes and the
    overlay's flux collapse; smoke covers designate → scale → slider →
    serialize → teardown → load replay.

53. **Water: flux consumers.** Item 50's (c), done. Wheel: a plank
    `WATER_WHEEL` designate on a wet cell (its own or a lateral
    neighbour holds water at designation — a dry-season bed is fair,
    an open field isn't) whose hub conducts; the net flood's producer
    pass reads `water_flux_at(cell)` and converts at
    `WHEEL_W_PER_CM3`, capped at `WHEEL_MAX_WATTS`. Efficiency is < 1
    by construction — a pump's full 200 L step yields 40 W against
    its own 200 W draw, so pump→wheel→pump can't perpetuum. Pump: a
    `PUMP` building (components + planks) whose `face_dir` picks the
    intake cell — any of the six faces, a downward intake being a
    sump — with `designate_pump` defaulting a non-face pick to the
    wettest lateral; the power tick syncs powered pumps into the
    sim's `water_pumps` records, which move
    min(rate, held, room) intake→outflow each water step —
    conservative by construction, bypassing edge throttles (a pump
    can push through a closed gate), standing down on rate 0.
    Irrigation is a real moisture layer rather than a bonus: a
    per-(x,z) saturation store in `[0,1]` — ambient 0.25 on plain
    dirt, rain-soaked columns toward 0.85 only under the sky (snow
    holds its water), draining back over ~a couple of game-days —
    plus standing water's irrigation reach sized by the body's
    column count (`0.75·√n`, a 100-column pond ~6, a puddle ~1) per
    DESIGN's abuse note. `PlantGrowth.moisture_factor` is a
    per-species trapezoid shaped exactly like the temperature curve
    (`moist_grow_min/max` outer bounds, `moist_opt_min/max` plateau),
    multiplied into `growth_factor` for bushes and trees alike;
    species differ — a wild berry bush feeds off ambient, wheat
    wants rain or a channel, cotton wants more, heal-all prefers it
    wet, oaks barely care. `_sowable` refuses cells standing in more
    than a skim of water. The `water_works_probe` tanks prove pump
    conservation, rate cap, dry/full no-ops, record clearing, and
    the flux read; smoke covers designate gating, wheel watts,
    powered/unpowered pumping, the trapezoid, rain soak/drain,
    sowing, and the moisture save payload.

54. **Water: flood pathing + surge smoothing.** Item 50's (d) plus its
    named hazard: route invalidation when cells flood. Timberborn's
    answer — let walkers swim rather than repath — fits the
    `traversal_mult` machinery piles and cover already use:
    wading/swimming costs scale with depth, and `is_standable`/the
    native A* stop treating head-deep water as a wall. Surge: the
    per-tick transfer caps exist; add front dampening so a breach
    advances as a wave instead of teleport-filling its basin.
    **Shipped.** Depth model: water ≤1 m over the support is a wade —
    passable, `traversal_mult` slowing with fill (`WADE_TRAVEL` at a
    full metre); deeper is swim-only. `unit_step` floats the capsule
    at a surface draught (`SWIM_DRAUGHT`, tuned under the jump apex so
    a water-level bank stays clamberable), reports `swimming`, and a
    jump impulse while floating runs ordinary arc physics — that is
    the clamber. `find_path` takes a `swim` flag: swim routes emit
    *surface* nodes (floating cell above the waterline, entered by an
    implicit drop), gated on capsule headroom above the line; wading
    edges price by depth, swimming edges cost `SWIM_EDGE_COST` so a
    dry detour can still win. `VoxelWorld.find_path` and the unit's
    path calls pass `can_swim()` — Swimming skill ≥1 *and* empty
    hands: no tools drawn, no pack, no patient. Swimming drains
    energy at `SWIM_TIRE` (4×), trains `SWIM_XP_SWIM` per second,
    deep-wading trains a trickle (`SWIM_XP_WADE`) so the landlocked
    can reach level 1. Swept in involuntarily, a would-be swimmer
    `stow_tools()` into holsters first, then ditches whatever still
    fills its hands — pack, patient, un-stowable tool — overboard.
    Surge: each active cell exports at most its *pre-step* settled
    volume, so same-step inflow can't relay onward — a breach wets
    one ring per water step; the upward vent uses the same cap.
    `water_swimming_probe.gd` covers all of it: feet down in a wade,
    float at draught, buoyant lift from submerged, clamber onto the
    bank, non-swimmer routed around the moat, swimmer straight
    through it, a roofed waterline refusing the swim route, and the
    surge front advancing exactly one ring per step.

55. **Carry by item shape + containers** — item 13, unblocked. Its
    deferral was cloth and item 37 shipped it. **Shipped.**
    `DropItem.stored` holds container freight, kept apart from
    `packed`/`shell`, which is what a furniture crate *is*.
    `CONTAINER_SPECS` keys by `spec` like the apparel/tool tables —
    tare, capacity, an accept-forms whitelist, and a `worn` flag — so
    container kinds are data: the sack (loose goods and food), the
    deliberately narrow seed pouch (seeds and fruit only), the
    sheet-goods box (most discrete goods — never boulders, logs,
    corpses, or another container — bags can't nest anywhere), and
    the backpack garment, whose old ×1.5 `carry_mult` is gone — it
    fills and empties on the wearer's back instead. Bags and pouches
    sew at the tailor from cloth or leather; boxes nail together from
    a plank or two sheets — the recipe's `output_spec` names the
    container record and the product comes out at tare volume.

    A container's `volume` is always tare + contents and `mass_kg`
    recurses, so the effective-volume rule falls out everywhere for
    free. Stockpile admission: non-empty `stored` gates recursively —
    every item inside must be admitted — and a small container then
    lands wherever its freight does (a sack of stone is stone-pile
    goods); an empty CRATE-form container is warehouse goods, the
    "containers of that type" filter. Freight crates — goods sealed
    in a minified *large* container — still gate on the warehouse.
    Uninstalling a stocked shelf sweeps its pile into the crate's
    `stored`; `_crate_unpackable` refuses a freight-carrying crate
    and fetch queries only recurse into `is_container()` items, so
    the stock is unreachable until `complete_construct` stands the
    piece and spills the goods back onto the new shelf.

    Hauling packs bags at the source (`fill_container` scoops what the
    destination admits under the lift budget), drags them whole, tops
    off containers already in hand and the worn pack, and pours a
    container's contents per-item at a destination that won't take it
    whole — a mixed sack can't ping-pong. `_stowable` keeps the trip
    honest: a pile with admissible goods nothing can hold doesn't
    stall the tick. Task fetches (craft, wall, uninstall shell, seed
    pouch, compost, fuel, food) see inside containers — the unit
    carries the bag whole, the delivery escrow draws only the
    still-missing volume out of it (`container_take_up_to`, run after
    the carried load escrows so goods in hand don't over-draw), and
    the container — unused freight still sealed — sets down beside
    the task site. The worn pack's freight counts in
    `_load_volume`/`_carried_mass` and bars a swim like any carried
    cargo; the entry-drop spills a worn bag's contents with the rest.
    `stored` serializes at slot 11 (size-guarded, so old saves load),
    and container-output recipes skip the study table so the
    furniture-crate wildcard keeps teaching joinery. The smoke
    section covers tare/room math, whitelists, admission, pack-at-
    source, the task-fetch drop, the shelf seal and the worn pack.

56. ~~**Light matters — the dark-work penalty.**~~ **Done.** The new
    `work_light_at` joins the two illumination halves — `light_at`
    (daylight + lamp falloff) and `illumination_at` (burning
    campfires) — into the "bright enough to work" query. A unit caches
    it as `light_level` on the beauty cadence, resampled the moment the
    standing cell changes so a step into a dark tunnel bites at once.
    Below `DARK_LIGHT` (0.15 — night, caves and unlit rooms sit at zero
    while a storm-wet noon still reads ~0.23) `_work_rate` and
    `_move_speed` both pay RimWorld's four-fifths darkness factor, so
    lamps, torches and fires are economy rather than decor. The room
    graph feeds the deferred item-26 thoughts: `Colony.is_indoors` is
    the bounded-component predicate, `room_cells` rides the same
    surroundings sample, and `in_the_dark` (−0.04, stress-vulnerability
    scaled) plus `cramped` (−0.03, rooms of ≤8 cells) sit alongside the
    beauty moodlets.

57. ~~**Unit temperature — comfort, exposure, apparel, freezers.**~~
    **Done.** Every species now carries `comfort_min`/`comfort_max`
    °C — the colonist's floor is the seeded `TEMP_COLD_FLOOR` (0),
    the ceiling a real summer afternoon (28), and fur-bearing wildlife
    runs a cold-shifted band for when animals read it. A unit caches
    `air_c` on the surroundings cadence, resampled the moment the
    standing cell changes like the light sample, and outside its band
    the `cold`/`hot` thoughts fire (−0.04, stress-vulnerability). Past
    `EXPOSURE_MARGIN` (8 °C) the air writes a wound — `hypothermia` or
    `heatstroke`, added to `WOUND_BLEED` at zero bleed — accruing
    `EXPOSURE_SEVERITY_PER_DAY` (20/day) scaled by depth over an
    `EXPOSURE_DEPTH_SCALE` band. Half lands on the torso, the rest on
    a leg, so frostbite downs through the health pool before the vital
    torso fails; `_tick_wounds` leaves these kinds alone (medicine
    can't tend the weather) while `_exposure_tick` warms them away at
    24/day once the unit's back inside its band. The apparel stat
    pass is item 37's seam filled: spec `warmth` drops the cold edge
    (tribalwear 4 °C) and spec `armor` bleeds `take_hit` severity
    (tribalwear 8%, wear-scaled, capped at `ARMOR_CAP` 0.7) — the
    splash still lands full force. Freezers: `_decay_tick` gates the
    organic rule on `temperature_at < TEMP_FREEZE_C` per pile —
    weathering still rolls, only the rot pauses — so a powered cooler
    in a sealed room pulls it below zero and the meat inside keeps.
    Heat-vein vents and passive coolers later, as is per-part armor
    coverage once apparel has pieces that map to parts.

58. ~~**Taming, pens and livestock.**~~ **Done.** Item 27's deferred
    half plus item 23's fences. The `TAME` job (Animals skill, same
    discipline the hunt trains) fetches bait from the nearest pile the
    mark accepts — herbivores won't touch meat, carnivores never
    qualify — then chases the mark and works it in `TAME_SESSION_SEC`
    channels; each session feeds the mark one hand-out and resolves
    through `animal.tame_session`, banking `TAME_SESSION_GAIN` (0.25)
    on a landed roll (`TAME_BASE_CHANCE` 0.55 + 0.05·skill, cap 0.95)
    until `tame_progress` hits 1.0 and the `domestic` flag lands. A
    miss bolts a flee temperament or, at `TAME_RAGE_CHANCE`, turns a
    fighter manhunter — `job_block_reason` reports "mark enraged" and
    the board holds the job until it calms; a mark that dies or turns
    domestic under another handler ends the job. Fences are the pen's
    rail: `Building.Kind.FENCE` (wood_fence recipe, 2 planks,
    KIND_HP_MULT 0.4) registers `set_fence` in the sim like doors —
    the native pathfinder charges units `FENCE_COST` (a hop) but a
    `no_fences` find_path flag refuses the cell entirely, which is the
    animal route; `traversal_mult(voxel, entity)` answers `FENCE_CRAWL`
    for colonists and 0 for animals, whose `_is_standable` also
    rejects rails while a mid-route build triggers a repath (or a
    `FENCE_ESCAPE` climb-off when standing on one). Pen zones ride the
    existing allowed-area machinery — `set_animal_area`, the animal
    panel's picker, idle walks home — and domestic animals suppress
    the colonist-flee response, graze their pen, eat `bait_ok` feed
    piled inside it when the grass runs out, don't count against the
    wild-spawn target, and breed on `LIVESTOCK_INTERVAL_DAYS` (2 game
    days): a species herd of ≥2 under `HERD_CAP` (12) adds a domestic
    calf that inherits its parent's pen. The Animals tab is live — a
    roster of every creature with species, wild/domestic, area,
    activity and fed%, plus a Tame button on wild marks that posts
    the designation and reports banked progress. Pack-animal hauling
    stays deferred with wheelbarrows (the species carry/drag fields
    exist); training beyond the initial Animals skill follows later.

59. ~~**Medical depth + the dead.**~~ **Done.** Infection: skin-
    breaking wound kinds (`cut`/`bite`/`gore`) accrue `infection` on
    the wound record — a per-kind day rate (`WOUND_INFECT_PER_DAY`,
    bites fastest) scaled by `INFECT_CARE_MULT` across the care
    tiers; a medicined tend (care 3) fights it back at
    `INFECT_CURE_PER_DAY`. Past `INFECTED_LINE` the wound stops
    knitting and festers (+`INFECT_FESTER_PER_DAY` severity) until
    infection drops back under the line — and a ruined part never
    knits at all. `_health_update` writes off non-vital parts wrecked
    outright into `ruined_parts` (gangrene); `amputate` takes one off
    into `lost_parts` — a lost leg prices a peg-leg hobble in
    `mobility` (`LOST_LEG_MOBILITY`), a lost arm halves
    `manipulation`, and both legs gone is `is_downed` for good until
    prosthetics exist. Surgery rides `ColonyJob.Type.SURGERY`
    (Medicine skill, 8 XP): `Unit.surgery_bills` is the worksite-bill
    list with the bedded patient as ingredient — `post_surgery_bill`
    validates against the body (no infection, no treat bill; nothing
    ruined, no amputation) and `_medical_tick` auto-bills
    `treat_infection` at `INFECT_SURGERY_LINE`, then posts the job
    only while the patient lies on a medical bed. The operation is
    medicine-gated: the surgeon must fetch a bundle first (no bundle,
    the claim back-offs to the board), `SURGERY_SECONDS` of bedside
    channel spends it — `treat_infection` zeroes every wound's
    infection, `amputate` takes the ruined part — and unloads the
    spares beside the bed. Per-patient medicine policy lands the
    Assign tab's second live control: `MedPolicy` NEVER/STOCKED/
    ALWAYS on the unit panel — NEVER never spends a bundle (field
    dressing only), STOCKED spends on medical-bed tends (the old
    behavior), ALWAYS lets a tend fetch and burn a bundle anywhere.
    Graves: `Building.Kind.GRAVE`, a 4-cobble recipe under the
    overseer's `designate_grave` action (Misc menu), `buried` species
    on the building record ("Grave of a colonist"), and
    `nearest_free_grave`/`nearest_occupied_grave` queries.
    `ColonyJob.Type.BURY` (unskilled labour) posts in `_burial_tick`
    — one per unburied colonist corpse, capped by open plots — while
    `_nearest_butcherable_corpse` keeps refusing them (no `yields`
    on the species); the bearer fetches the body, retargets if its
    grave fills or falls, and `complete_bury` lays it in for
    `BURY_SECONDS` of work. The dead are felt: `_unit_died` lands
    `witnessed_death` on survivors inside `WITNESS_DEATH_RANGE` and
    `lost_friend` on the whole camp, and an occupied grave is a
    recreation pick (`visit_grave`, item 25's deferred activity) that
    ends in `mourned`, not `had_fun`. All of it serializes — wound
    infection as the record's sixth field, ruined/lost parts, policy,
    bill queue, grave `buried`, patient-linked jobs.

60. ~~**Roster growth — arrivals.**~~ **Done.** `Skill.SOCIAL` joins
    the discipline list — its first use is the recruit roll.
    Passions: `_apply_settler` rolls `Unit.passions` per skill for
    every settler (embark included) — `PASSION_DEAD_CHANCE`/`MINOR`/
    `BURNING` shares price `skill_gain_rate` at ×0/×1.5/×2 (absent is
    ordinary); a burning passion's `passion` moodlet (item 26 hook)
    fires while the live job trains it. Wanderer-joins:
    `_arrivals_tick` rolls once a game-day —
    `arrival_chance = ARRIVAL_DAILY × mood_mult(0.2–1.8) × roster
    fade to ROSTER_SOFT_CAP` — RimWorld's event approximated without
    a director, entering on a random bearing through the scenario's
    periphery path (the meso travel path supplies real ones later —
    both arrival kinds). A `STRANGER_SHARE` of landed rolls is the
    rescue-and-recruit instead: `spawn_stranger` drops a guest
    (`stranger` + `relieved` — roster-adjacent but never on the
    board) at the edge, hurt enough to be downed with every wound
    under its ruin line — TEND/RESCUE apply like anyone. `_guests_tick`
    on the medical cadence resolves a recovered guest
    (`RECRUIT_READY_HEALTH`): `resolve_guest` rolls
    `RECRUIT_BASE + RECRUIT_SOCIAL_STEP × best Social` (cap
    `RECRUIT_CAP`) — the colony's best talker persuades and banks
    `RECRUIT_XP` either way. A join clears both flags; a refusal sets
    `departing`, walks them to the rim on `arrive`'s own ORDER
    machinery, and `_unit_departed` despawns them inside
    `DEPART_EDGE_CELLS` — reissued if a rescue dragged them back
    mid-walk. A stranger's death still lands `witnessed_death` on
    bystanders but not `lost_friend` — nobody grieves a guest who
    never joined. Passions, `stranger` and `departing` all serialize.

61. **Ranged combat + traps.** Weapons as tool classes (43's seam):
    bow/spear specs — range, damage, cooldown — produced at the
    toolmaker's bench. LOS by voxel raycast through open cells with
    `provides_cover` blocking; overshoot rolls friendly fire through
    item 30's cell-damage machinery. The spike trap — still a menu
    stub — is a triggered building damaging a cell's entering
    occupant. Multi-select drafting and unit-vs-unit follow (26's
    violent break tiers need arrest to resolve). The turret waits on
    power plus this item.
    **Landed**: `TOOL_SPECS` carries the `spear` (`melee` 14, `stab`)
    and `bow` (`range` 14, `shot_damage` 9, `shot_cooldown` 2.6) as
    ordinary tool classes — both two-handers, both bills on the
    toolmaker's bench (a hafted point, a sprung stave — no forge
    knowledge). `arm()` draws the best carried weapon into the hands
    as a fight opens; a wielded weapon swaps `_melee_dps`'s species
    base and lends its `wound_kind`, and a drawn bow changes the
    ORDER fight's reach: `_fight_in_reach` and `_tick_order` stand
    off at `range` when `Colony.line_of_fire` — a voxel DDA through
    open cells, blocked by solids and `provides_cover` (the mark's
    own cell doesn't count — on the mound is exposure, not cover) —
    says the shot's clean. `SHOT_HIT_NEAR`/`EDGE` (0.9→0.35) price
    the hit roll by distance; a miss runs `_overshoot` one cell past
    the mark — an occupant there eats the shaft at full spec damage
    (friendly fire, real wounds and all) and bare ground takes item
    30's `damage_cell`. `job.foe` carries a Unit target through the
    same fight machinery `job.animal` uses — `_target_valid` accepts
    colonists (a downed one's out of the fight), drafted RMB orders
    attack them, and `_nearest_threat` adds berserk units to the
    drafted scan. Multi-select drafting: shift-click in the world
    builds `overseer._squad` (inspected unit is its face; `+ ` marks
    the colonist bar), the panel's draft toggle fans out via
    `set_squad_drafted`, and every RMB order — attack, wreck, move —
    fans out to the squad's drafted members. The spike trap is a
    real Security-menu build (`Building.Kind.SPIKE_TRAP`, 3 planks):
    the cell mirrors into the sim like a fence — unit paths pay
    `TRAP_COST` while animal routes pass `ignore_traps` and see open
    ground (`traversal_mult` agrees: `TRAP_AVOID` for colonists, 1.0
    for hoof and claw) — and `try_trap` on cell entry springs it
    once: `SPIKE_TRAP_DAMAGE` (22) as a `stab` wound on the occupant
    (units and animals alike; the downed being dragged don't spring
    it), the stakes splinter with no salvage, and the sim mirror
    drops on the same teardown. 26's violent break tiers landed: a
    major/extreme snap rolls `BREAK_VIOLENT_SHARE` (0.4) into
    `_berserk` — stalk the nearest colonist through the fight
    machinery, re-marking when one goes down — ending on the mood
    release line, a down, or the `ARREST` job the medical tick posts
    per rampage: any colonist grabs the breaker and holds
    `ARREST_SECONDS` (4) of channel while the swings land (`_engage`
    declines the return brawl), `complete_arrest` ends the break
    through the ordinary catharsis path. The rest of the share still
    dazes — `break_violent_roll` pins the roll for tests. A rampage's
    end — calm, down, arrest, or the cool-into-daze — runs
    `_release_grudges`: every defender whose fight was the berserker
    stands down, since `_engage` keeps a hit's grudge past the job
    that landed it. And `_engage` itself reads hostility: a colonist
    never feuds a calm colonist (a stray shaft or a mis-ordered
    swing is a wound, not a war) — only a `_berserk` or `stranger`
    attacker earns the return swing. The turret remains deferred to
    power.

62. **Work tab — roles, fetch override, and the clean-up loop.** The
    fork resolved against the RimWorld-style matrix: `Unit.role`
    designates a lane (`Colony.ROLES` — generalist, labourer, miner,
    builder, grower, smith, handler, medic, steward) whose job types
    earn the flat `CLAIM_ROLE_BONUS` in `_claim_type_scores` — additive
    on the skill read, so the appointee takes their lane at a
    walkable distance without outbidding a true specialist up close.
    A bias, never a gate: `job_block_reason` still owns eligibility,
    and `specialize` still owns how much skill counts — they pair.
    The role rides the save; an unknown one loads as generalist. The
    Assign tab carries the picker next to Specialize; the Work tab's
    job board gains a crew roster (name — role — live activity, click
    to select and jump) and the per-unit breakdown labels each line
    with its role. The picked job also carries "Fetch anywhere" —
    `job.home_override`, the deferred item-44 seam: its fetch queries
    (`nearest_*` pile queries plus `nearest_fuel_voxel`'s home pick)
    take `far_ok` and skip the in-home demotion for a deliberate far
    haul; it serializes with the job. The clean-up loop landed too:
    `mess` records accrue on home cells only — footsteps track dirt,
    bleeding wounds stain, burned-out cells leave ash — and the scan
    posts a `CLEAN` bill per cell past the threshold; the steward
    claims it and `_tick_cleaning` scrubs it dry. Mess serializes;
    the bills re-derive like firefighting. **Shipped.**

63. **Options + the title flow.** `GameOptions` (statics +
    `user://options.cfg`) holds the knobs — master volume, autosave
    cadence, the perf readout toggle — and the Menu's Options item
    opens a panel that edits them live; keybinds join later. Autosave
    is real: `Main._autosave_check` writes the `autosave` slot on a
    wall-clock cadence so game speed can't multiply it, and it can't
    clobber the manual `default` save. The worldgen screen gains a
    stage-0 title — Continue (newest slot), New world (the old
    options stage), a save-slot list (`Main.save_slots`, newest
    first) replacing stage 1's bare Load button, and Quit; Menu's
    Quit splits into quit-to-title and quit-to-OS. **Shipped.**

64. **Overlays and the remaining tabs.** `ColonyOverlays` paints two
    MultiMesh heatmaps over the standing surface near the focus —
    topmost standable cell per column, capped at the slice plane so
    interior floors win while slicing. Beauty reuses
    `Colony.unit_beauty` outright — the room score indoors, the
    sight-line sample outdoors — budgeted a few cells a frame on a
    focus-outward queue that re-sweeps forever, so edits drift the
    paint behind play. Roofs classifies cover per cell: bounded room,
    unbounded overhead cover, open sky (untiled). The Animals tab
    rides item 58. Research is a roster × skills-and-knowledge grid —
    levels plus passion marks, since the tech model lives in people.
    World shows the meso heightfield with region site bounds boxed
    plus the site list; it becomes the travel UI under item 65.
    Factions/History stay stubbed until factions and an event log
    exist. **Shipped.**

65. **Multi-site.** `planet_time` promoted onto `Region` — every
    region file carries the shared clock — and sites now span the
    whole planet: the flat voxel space is partitioned per world tile
    (`_tile_voxel_origin` — a tile's patch derives from its first
    site's anchor, unsettled tiles get a deterministic slot), and
    `Site.meso_cell` pins each site on its tile's map. Sites activate
    by focus: `focus_site` serializes the live colony dormant into its
    record and round-trips the autosave slot, so the load path resolves
    `active_site` from world.json, installs that tile's meso, and
    deserializes the destination payload (a surveyed-but-empty site
    restores as an empty colony). Region streaming is the `_regions`
    cache plus on-demand region-file loads — every touched region
    writes its own `region_<x>_<z>.json`. Travel: `send_unit_to` puts
    a colonist under travel orders (relieved, walking the rim on the
    departure bearing), the travellers tick packs them into a
    `travel_parties` record — unit payloads, a land-only BFS route
    over the globe's tile graph, metres walked at march pace — and
    `_arrive_party` lands them: live sites spawn them in off
    `periphery_entry(bearing)`, dormant sites stage the payloads at
    the rim, and bare ground becomes an incident site on arrival. The
    World tab lists every cached site with Focus/Send controls, shows
    in-flight parties, and LMB-marks a meso cell for point travel or
    surveying. One live colony at a time — several *active* sites
    ticking concurrently stays future work. **Shipped.**

66. **`VoxelStreamSQLite`** as the durable stream backing — each
    world tile owns a `voxels_tile_<n>.sqlite` store under the save
    slot (a tile's 16 km patch dwarfs the ~160 m streaming radius,
    so a tile-scoped file can never absorb a neighbour's blocks the
    way region-scoped files could; sites on different tiles keep
    different stores, same-tile sites correctly share contiguous
    space, and `Main._streams` holds every instance the session
    opens for the concurrent multi-site shape). The store binds at
    boot while the viewer is still held — `set_stream` on a live
    terrain reloads every loaded block, so boot is the only free
    moment; an unsaved world binds against a scratch root
    (`user://_voxels_live`, wiped on each fresh boot), and a slot
    change flushes each open store, copies its file into the new
    slot, then repoints `database_path` — the bound instance never
    rebinds. `save_game` only flushes `save_modified_blocks`.
    With a stream bound, `record_edit` stops logging streamed-cell
    writes — the
    JSON log shrinks to cells no stream can see
    (`remove_voxel_recorded`, ruins' off-screen walls), replay
    sheds each entry into the DB as its chunk loads, and save-time
    pruning drops entries whose blocks just flushed. A v2 save's
    edit log migrates transparently: replay writes it into blocks,
    the stream captures them, the file goes quiet. Region files
    keep their tiny residual log; streamed blocks live in the
    store. **Shipped.**

67. **Metals line completion — ceramics, country rock, alloys,
    stove.** Item 42's deferred list, plus the ceramics chain it
    implied. Country rock: `SiteField` carries a per-cell rock raster
    (block ids) driven by `pack_vanilla`'s biome→rock weight tables —
    soil adjustment, drainage, vegetation factors — with a serpentine
    intrusion seam; `WorldGenerator._block_at` substitutes the field's
    rock for plain stone, modulates the soil spec and drainage-scaled
    hydrology thresholds, couples sapling/bush seeding to the rock's
    vegetation factor, and screes the field's own loose rock; the
    native generator mirrors it through `install_field` +
    `rock_block_at` (parity holds). Ore tailings take the host rock via
    `DropItem.for_block`'s host override. Rock is a material class:
    `BlockRegistry.ROCK_*`, `is_rock_material` and `material_fits`
    widen every stone pin — crush/cut bills and the wall
    fetch/escrow wants all take granite, marble, slate, limestone or
    serpentine where they once wanted STONE exact. Ceramics: clay
    fires in the KILN — `fire_brick` (60 k clay + 20 k charcoal →
    50 k firebrick) and `fire_crucible` (30 k + 10 k → a crucible
    tool item, `needs_spec`'d by `smelt_gold`; `has_spec_item` gates
    dispatch and the worksite re-scan frees it on arrival). The
    REFRACTORY builds from firebrick and alone hosts the alloys:
    `alloy_bronze` (90 k copper + 10 k tin + charcoal),
    `alloy_steel` (95 k iron + charcoal). The STONE_CRUSHER folds
    every `crush_*` bill off the craft spot into one machine, and
    `MAT_INHERIT` pours crush output in the input's own rock — a
    granite boulder grinds to granite cobbles and granite gravel. The
    STOVE is the steel cooking tier past the campfire: steel sheets
    build it (`sheet_metal_bronze`/`sheet_metal_steel` complete the
    sheet line), the stew cooks there alone, shared meals run half
    again as fast, and it burns fuel per worked second like the forge.
    Two latent sim bugs surfaced driving the line: a laden unit's
    blocking-pile detour could pour or drop its craft cargo mid-route
    (the detour is now empty-hands-only, matching the opportunistic
    gate), and `_advance_*_goal` leg transitions retargeted
    `_goal_voxel` without re-arming the stuck watchdog — a unit that
    once closed on a pile could never satisfy the progress test on a
    farther leg, so multi-ingredient crafts starved mid-route and gave
    up. `_goal_voxel` is now a property whose setter resets the
    watchdog on every retarget. Covered by `_test_metals` (the whole
    chain) and `alloy_probe.gd`. **Done.**

68. **Rooms beyond beauty — stats, comfort, art.** Done. Every `Room`
    carries a stat block recomputed lazily beside its beauty score:
    `use` (hospital/bedroom/dining/recreation/workshop/room — medical
    beds first, then beds, tables, rec pieces, worksites),
    `cleanliness` (1 − mean mess fill, staled through
    `Rooms.stale_cell` on every `add_mess`/`scrub_cell`), `wealth`
    (furniture + recreation + paving worths × quality, one piece per
    footprint), and `impressiveness` — a 0–100 grade weighting space
    (saturates at 60 cells), beauty, wealth (caps at 500) and
    cleanliness into RimWorld-shaped tiers: awful <20 < drab <35 <
    mediocre <50 < decent <65 < impressive <85 ≤ wondrous. The mood
    consumes the grade: `slept_in_{poor,decent,impressive,wondrous}_room`
    replace the plain bed thought when the sleeper's bedroom grades
    out, and `ate_in_{drab,impressive,wondrous}_dining` rides a tabled
    meal's room the same way. **Comfort** lands as a spec stat —
    `&"comfort"` on beds folds up to +20 % into `_bed_quality_mult`'s
    rest, and a seat at `COMFORTABLE_SEAT` (armchair, couch) adds the
    `comfortable_seating` meal thought. **Art**: `Skill.ART`, three
    carve-in-place sculptures (small/sculpture/grand, any country-rock
    blocks), quality riding the carver's Art roll and scaling the
    decor beauty + wealth. **Flooring bonuses**: `speed` (flagstone
    1.15×, plank 1.10×) multiplies `traversal_mult` and mirrors into
    the native pathfinder via `sim.set_floor` — a paved hall is worth
    a detour; `fire_resist` cancels a share of `_cell_flammability` so
    stone paving slows the spread. The inspect line names an indoor
    cell's room — "Decent bedroom". `_test_room_stats` covers the
    whole line; `hud`/`overseer` carry the three furnish actions.

**Design fork — manual work priorities.** RimWorld's Work tab is a
per-colonist × per-work-type priority grid the player hand-tunes.
Delve's `claim_job` scoring (distance − skill − languish, with the
`specialize` toggle) is a different philosophy: the colony reacts to
skills instead of rosters. Decide before the UI hardens — a priority
grid can sit *on top of* scoring as a type-gate/multiplier without
replacing it, but bolting it on later means re-teaching players an
existing system. Deliberately deferred, not forgotten — item 62
decides it before the Work tab's UI hardens.

- ~~Slice/x-ray view~~ — landed as the Timberborn-style slice view with
  cross-section caps (`slice_view.gd`); the remaining piece is stairs/
  ramps, which still don't exist (ladders are the only vertical transit).

## Follow-ups on shipped work

Loose ends left behind by done items — smaller than roadmap entries,
bigger than a commit note.

- ~~**Detour selection still walks before it knows.**~~ **Fixed.** Every
  `nearest_stockpile_with_room` probe that guards a pile grab now asks
  for `maxi(pile.smallest_takeable_volume(mats), 1)` — the pile's
  smallest takeable non-loose item — instead of a bare cm³: detour
  pre-checks (`_start_detour`, `_opportunistic_detour_at`), arrival
  re-resolution (`_detour_stockpile`), opportunistic revalidation
  (`_detour_dest_ok` scans per-item against actual room), haul-job
  creation in `_tick_idle`, the fetch retry loop, and the clearing
  tick's destination pick. Hopeless walks never start.
- ~~**Occupancy claims are pairwise, not systematic.**~~ **Fixed.**
  `Colony.Occ` flags every non-terrain claim (PILE, PACKED, BUILDING,
  TREE, UNIT, DESIGNATION, LADDER, ZONE, BUSH) and
  `cell_claimed(voxel, mask)` answers them in one pass — cheap dict
  claims first, the unit-roster scan last. Designation guards, the
  zone/furniture cellables, world-gen seeding, forest growth, and the
  overseer's placement previews all read through it. The mask naming
  is the point: `Plants.plant` deliberately stays pile-tolerant since
  a dead plant composts onto its own cell and replants beside the
  heap, while a sapling refuses the same cell because it grows solid
  parts. New claim sources add a flag + a clause once.
- **Fallback pathfinder parity.** The engine `VoxelAStarGrid3D` sees
  neither ladders (item 8) nor door sills (item 23) — moot while unit
  motion is native-only, but the divergence grows with each traversal
  feature added to the native sim.
- ~~**Room detection — landed.**~~ **Fully consumed.** Item 34 shipped
  `rooms.gd`: lazy flood-fill of open components, door-sealed,
  invalidated on `block_edited`, carrying temperature and beauty. The
  downstream consumers named here all shipped with items 56/57:
  `cramped` rides `room_cells` (≤8 cells, −0.03), `in_the_dark` rides
  the light sample indoors and out (−0.04), `unit_beauty` returns the
  room's integrated score indoors, and `_climate_tick` moves heat
  through the graph — heater pours into its room, the powered cooler
  pumps `COOLER_POWER` from its cold face to its hot face plus 15%
  waste, and `_decay_tick` freezes organic rot below `TEMP_FREEZE_C`
  so a sealed cooler room is a working freezer.
- **Food economy balance.** Item 21's rescale is provisional — the
  fruit/meal volume math wants a pass once recreation (25) and mood
  (26) exist, so hunger pressure is tuned against the full needs model.
- **Bed-kit fiction — retired.** Item 47 landed it: furniture packs
  into spec-stamped crates that only warehouse zones admit, and the
  crate's exact contents ride back out on reinstall or unpack.
- **Conservation leaks in the item model — repaired.** Item 49 landed
  it: a trunk voxel fells into a whole 1 m³ log, smelts tail their
  gangue out as slag, and mining a built wall returns scrap at the
  recipe's invested volume (stone → boulders/cobbles, wood → loose
  splinters) rather than the generic 125% mining bulk.
- **Fill-is-floor — now by form.** Item 49 split pile fill into loose
  (raises footing) and clutter (never a floor): sparse discrete goods
  are waded on a `1/(1 + 4f²)` curve, a heap past three quarters of a
  cell blocks like a low wall and soaks melee blows as flimsy cover.
- **Mass-bound takes landed.** `take_up_to`/`take_form`/`take_wall`
  carry a `lift_kg` allowance — an over-cap discrete item still comes
  along when its mass fits the drag limit, so a 1 m³ log (~600 kg)
  is a drag, not an impossible lift.
- **`planet_time` promotion.** The shared clock is per-site-correct
  today; it must move onto `Region` when a second site activates
  (items 6, 18) — item 65 carries it.
- **`repair_job_at` and `nearest_ripe_bush`** still scan linearly —
  fine at this scale, worth bucket indexes when colonies grow.
- **`find_path`'s `margin=24`** caps path length at ~48 voxels;
  long-distance hauling silently fails beyond that.
- **Pile rendering.** Each `ItemPile` is a `Node3D` rebuilding
  `BoxMesh` children per item — a shared `MultiMeshInstance3D` or
  mesh pooling is the fix at hundreds of piles.
- ~~**Metals line completion.**~~ **Landed as item 67** — crucible
  gold, the crusher machine, alloys, the steel stove, country rock
  and the differentiated cut stones. What remains is deeper: metal
  tools past the iron set, metal constructions, and the
  manuals/trade/inspection knowledge paths.
- ~~**Rooms beyond beauty.**~~ **Landed as item 68** — the room
  stat block (use, space, cleanliness, wealth, impressiveness
  tiers), comfort on beds and seats, sculptures with an `art`
  skill, and floor speed/fire-resist bonuses. What remains: finer
  decor variety (rugs, wall art), beauty-sensitive animals, and
  bedroom assignment policies.
- **Mood/craft reads.** Meal moodlets, quality reads on tools and
  apparel, material-quality interaction (plasteel vs wood).
- **Fire.** Smoke, ambient-heat contribution to room temperature,
  burn scars; the rain multiplier on weathering and a weathering
  hover hint.
- **Farming.** Manual cut-plant, a tilled-soil/fertility bonus,
  inverted-band dark-growing species.
- **Scheduling seams.** Party/event override, patient feeding policy
  (wait-to-be-fed vs feed-themselves), night-owl/handler drift, a
  colony posture toggle.
- **Colonist generation.** Per-settler customization at embark,
  age/health quirks, non-`periphery` entry kinds.
- **Tools.** Bulk tool profiles, butchery/tool needs beyond
  mine/chop.
- **Power.** Insulated cable tiers, shock/fire risk from exposed
  conduit, cooler orientation UI beyond designate-time bearing.
- **Apparel.** A strip order, two-handed tools (the flag exists),
  more garment types and layer coverage.
- **Storage.** Per-form shelf packing factors, shelves as named bill
  destinations, area-aware haul *source* restriction, multi-cell
  shelving units.
- **Bills.** Bills on pawns, medicine requirements, ingredient
  hit-point ranges, unfinished-item authorship, the ingredient-radius
  outline on hover.
- **Wildlife.** Pack-animal hauling, wheelbarrows/sleds for over-drag
  loads.
- **Television.** Power exists — a `REC_SPECS` entry with a powered
  gate on the lamp model unblocks the last recreation stub.
- **Rain modality.** Drizzle climates vs burst climates — the Markov
  stretches clear spells but can't vary intensity.
- **Wrecks drop broken goods.** Today a wrecked construction pays
  like a clean teardown.
- **Dense heaps.** Whether dense clutter wants its own hit-point
  pool instead of pure item erosion; clutter-aware fetch selection.
- **Manual work priorities.** The design fork above — decided as
  part of item 62 before the Work tab's UI hardens.

## First milestone

Items **1–3** as one milestone — drag-designate a hillside, trees get chopped,
planks get built — gives a playable "gather → build" loop that everything else
hangs off of.
