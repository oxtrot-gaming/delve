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

### RimWorld-parity roadmap

The following is the gap list against RimWorld's core play loop
(Basics guide and its linked pages), excluding the storyteller system —
no director-driven incidents or difficulty curve. Threats will come
from simulation instead (wildlife, weather, terrain). Ordered by
dependency and leverage.

21. **Cooking + meals.** Completes the food loop on existing machinery:
    a kitchen worksite, a `MEAL` item form (faster-decaying than raw,
    higher food value, small morale bonus vs the raw-food penalty), a
    Cooking skill, and a food-poisoning roll gated on cook skill.
    Kitchen is a `Building` with the worksite-order queue from item 16;
    `CRAFT`-adjacent job type carrying the Cooking skill. Open seams:
    whether meals are multi-input recipes (needs recipe inputs to be
    a dict of (material, form) pairs — mostly there), meal-to-mouth
    spoilage pressure vs raw stockpiling, and where the Cooking skill
    lands in `SKILL_FOR`/`XP_FOR`.

22. **Bill details.** Item 16's queue gets RimWorld's bill refinement
    pass: an unpause threshold on until-bills (stock to X, resume at Y —
    the "pause until satisfied" knob), an output-disposition picker on
    each order (haul to best stockpile vs drop at feet — a per-order
    flag the completion path reads instead of always posting a haul),
    and an input radius so a kitchen works beside its ingredients.
    Add stockpile *priority* alongside the filter set — `StockpileZone`
    gains a rank and `nearest_stockpile_with_room` sorts by
    rank-then-distance — plus a dumping-stockpile preset (same record,
    different default rejects). Open seams: whether priority is an int
    ladder or an enum, and whether until-bill counting should include
    in-flight goods.

23. **Doors + rooms + the indoors predicate.** A `DOOR` building —
    a passable wall cell units path through but which still encloses.
    Then room detection: flood-fill open cells to the region edge /
    sky; a cell that can't reach either is *indoors*, and a contiguous
    indoor region is a *room*. Voxel queries make this cheap — no
    RimWorld-style roof entities needed; roofed simply means the cell
    has no vertical line of sky. Buildings can then read
    `is_indoors(voxel)` for speed/comfort modifiers. Open seams:
    flood-fill cost on mine/build (cache room membership, invalidate on
    boundary edits), doors vs fences/curtain walls for pens, and
    whether the sim or GDScript owns the room graph.

24. **Outdoor deterioration.** A second decay axis: items weather when
    unroofed — new `Deteriorate`-style rules in `DropItem.DECAY_RULES`
    keyed on `is_indoors` from item 23, so stone and steel are exempt
    but wood/cloth/food rot faster in the rain. Distinct from organic
    decay (which keeps running indoors). Gives rooms their first
    mechanical payoff and stockpile placement its first real trade-off.

25. **Recreation need + a rec building.** Third need beside
    hunger/energy, draining on the game clock and refilled by an idle
    activity at a recreation building (a game-board or training-dummy
    analog — furniture with a use-interaction). Units self-issue a
    `RECREATE` job below a seek line, same pattern as `EAT`/`REST`.
    Open seams: joy variety (one activity suffices at first), where
    recreation sits in the job-claim order, and traits that bend the
    drain rate (`recreation_seek_mult` on the `TRAIT_EFFECTS` seam).

26. **Mood + moodlets.** Aggregate the environment into a morale stat:
    moodlets as named, timed modifiers — slept-on-ground (item 7's
    penalty already distinguishes bed vs ground), ate-raw (21),
    impressive room (33), cramped/dark workspace (23's room graph),
    starved, soaked (31). Morale gates work speed and, at the bottom,
    interruptions — start with mild disruptions (daze, wander, binge
    eat) rather than RimWorld's full break taxonomy. `traits` get
    mood-relevant factors (`mood_mult`, break thresholds). Open seams:
    moodlet stacking rules, the break threshold curve, and whether
    morale modulates `_work_rate` directly or through a multiplier.

27. **Wildlife + hunting + butchering.** Animals as a second `Unit`
    species class — spawn with the world, wander, graze the grass
    layer (which is already coverage-float "grazing-ready"), flee when
    approached. `HUNT` designation kills through melee for now →
    `CORPSE` item → butcher worksite → `MEAT` + `LEATHER` outputs via
    the standard recipe pipeline. Meat feeds the kitchen from 21;
    leather banks toward apparel (36). Predator species hunt wildlife —
    and, later, colonists — which is the non-storyteller threat source.
    Open seams: herd/flee AI cost, corpse decay (already have rules),
    manhunter rage chance on failed hunts, and animal reproduction.

28. **Health: injuries + tending + rescue.** Units get a health stat —
    wounds from combat/falls/failed work, bleeding timers, a `DOWNED`
    state; a Doctor work-type (`TEND` job) that treats patients at
    beds (medical flag on `Bed`-class buildings), and `RESCUE` hauling
    for the downed. Medicine as a tiered input (none / herbal — healroot
    is a farmable species — / manufactured) scaling tend quality.
    Precedes combat so there's something to lose. Open seams: wound
    model granularity (pooled HP vs per-part), infection/disease
    timers, death → `CORPSE` + grave/garbage handling.

29. **Drafting + combat.** The first direct-control input mode:
    select unit(s), draft, then right-click move / attack-move;
    melee range = adjacency, ranged needs a weapon item and line of
    sight through open voxels. Walls and built cover block line of
    sight — the voxel world gives cover/chokepoints for free. Combat
    wounds feed 28. First threats are wildlife predators (27), not
    storyteller raids. Open seams: drafted units vs job-system
    requisition, friendly-fire rules, equipment slots on `Unit`,
    and how far targeting extends past `find_path`'s margin.

30. **Quality.** Crafted goods roll a quality tier off maker skill —
    stored on `DropItem`/building, so beds restore rest faster, meals
    are worth more, weapons hit harder. Cheap once the stat exists;
    makes skill investment visible. Open seams: quality distribution
    curve, whether it propagates into buildable-block properties, and
    material-quality interaction (plasteel vs wood).

31. **Weather + seasons.** A region-scoped weather state machine —
    clear/rain/dry-storm/wind — plus a season calendar on the planet
    clock. Gates plant growth (20's environment model), waters/dries
    soil, puts out fires, drives cold snaps that end growing seasons.
    Ignition source for 32. Open seams: per-region vs global weather
    (region is the persistence unit already — weather state serializes
    onto it), weather → `grass`/crop hooks, and forecast UI.

32. **Fire.** Flammability table on materials/buildings, spread across
    face-adjacent burnables on a tick, a `FIREFIGHT` job (top priority,
    beat-out interaction), and ignition from dry-storm lightning (31)
    plus accidents. Wood walls burn; stone doesn't — the stonecutter's
    classic early-game trade-off lands automatically. Open seams:
    spread model (per-cell probability vs fuel/resistance), smoke,
    and whether `CLEAR`-ing grass becomes the firebreak tool.

33. **Flooring + beauty/impressiveness.** Floor overlays as a
    decoration layer like grass — laid by `FURNISH`-class jobs,
    giving move-speed and fire-resistance bonuses. Beauty as a per-
    room stat (decor items, flooring, open space, cleanliness);
    impressive rooms pay moodlets into 26. Sculptures/fine furniture
    as crafted decor items. Open seams: beauty scoring radius, floor
    vs building-block dichotomy, and art skill if sculptures arrive.

34. **Research.** A research bench + `RESEARCH` job type (Intellectual
    skill) accumulating project points; a tech tree gates recipes,
    building types, and powers (electricity in 35 is the first big
    unlock). Idle-priority filler work — RimWorld's "research when
    there's nothing better" falls out of the job-claim ordering for
    free. Open seams: tech prerequisites UI, knowledge vs blueprint
    gating on `worksite_recipes`, and whether any tech gates terrain
    features (e.g., deep drilling).

35. **Power + temperature.** Combined infrastructure arc: generators
    (wood-fired first) + conduit/building links within a radius →
    powered buildings. Lamps raise indoor light (work-speed modifier
    in dark rooms from 23), heaters/coolers move room temperature —
    which needs a per-room temperature model riding the room graph,
    outdoor ambient from weather/season (31), and a freezer rule that
    halts organic decay below 0 °C. Open seams: power graph storage,
    fuel-as-input jobs for wood-fired generators, and heat diffusion
    through walls/doors.

36. **Apparel + cloth.** A fibre crop (cotton analog — farmable species
    on the item-14 machinery) → weaving recipe → `CLOTH` bolt →
    tailored garments at a tailor worksite; leather from butchering
    (27) as the early alternative. Garments wear out, provide armor
    (29) and warmth (35). Also unblocks item 13's containers — bags
    are cloth goods. Open seams: wear/decay on equipped items,
    equipment slots vs carried cargo, and layering rules.

37. **Allowed areas, forbid flag, shelves.** The zoning/safety layer:
    per-unit allowed-area masks (keep colonists inside the walls),
    an item/building forbid flag that excludes it from hauling,
    eating, and crafting inputs, and shelves — low-capacity storage
    furniture that can be a named bill destination (22's output picker
    learns named targets). Open seams: area paint UI, whether forbid
    lives on `DropItem` or the pile, and shelf-vs-zone filter
    unification.

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

## First milestone

Items **1–3** as one milestone — drag-designate a hillside, trees get chopped,
planks get built — gives a playable "gather → build" loop that everything else
hangs off of.
