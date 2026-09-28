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
   **Still open: farming** — see the seed-bundle item below.

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

11. **Tree growths + organic decay.** Trees should periodically generate
    and drop growths — seeds, fruit, whatever fits the species — that
    decay away so the map doesn't fill with litter. The same decay clock
    should cover *all* organic materials (leaves, branch material, seeds
    rot quickly; logs and branches take a very long time). Once a tech
    tree exists, research can offer ways to slow or halt organic decay.
    Seeds naturally pair with farming: a dropped seed is the cheapest
    path to the "forageable/replantable" food source hunger needs.

12. **Grass as decoration, not block.** Today grass is a voxel —
    green dirt, mined and hauled like soil. The plan is grass as a
    tracked decoration *on top of* dirt (and possibly other blocks) —
    the forest's leaf/sapling model is the precedent: the cell stays
    whatever block it is, a decoration layer renders the grass and the
    system spreads it slowly to neighbouring eligible blocks. Generation
    seeds it and the small-plants rule applies — seeded growth starts at
    mixed coverage, not zero. Open seams: whether mining a grassed block
    yields dirt or dirt-plus-grass-cutting, whether trampling/construction
    kills it, and how far decoration state rides on persistence.

13. **Carry limits by item shape + containers.** Rework hauling: a unit
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

14. **Farming via physical seed bundles** — the Progression: Agriculture
    model (github.com/fernyrepos/Progression-Agriculture) rather than
    vanilla RimWorld's free-seeds sowing. Seeds are real items — one
    bundle per crop species — obtained by *packing harvested produce* at a
    workstation (a seed-packing bench; the crafting spot as the cheap
    double-cost alternative, the same free-vs-bench tradeoff the bed
    recipe already uses). The seed item *is* the sowing gate: you can't
    plant a crop you don't hold, and initial bundles come from foraging,
    traders or scenario starts. This preserves the physical-resources
    rule: forage wild plants → produce → pack into seed bundles → sow →
    harvest → pack more seeds. Fruit-bearing trees (item 11's growth
    drops) stay deferred; the berry bush is the template the crop/plant
    machinery will grow from — `plants.gd` is deliberately species-tabled
    for it. Open seams: whether sowing is a zone+designation like
    stockpiles or a per-plot building, whether crops need tilled soil,
    and where PA's UnlockCrop knowledge gate lands (or whether physical
    possession alone suffices).

15. **Sleep-speed boost.** RimWorld's toggleable quality-of-life feature:
    when every unit is asleep, kick the game to high speed until the
    first unit wakes. The pieces already exist — `DayCycle`/`Engine.
    time_scale` drives the HUD's speed buttons and `Unit.state` exposes
    SLEEPING — so this is a toggle plus a per-frame "all sleeping" check.
    Open seams: what speed it boosts to, whether needs-draining events
    (a unit hitting zero hunger mid-sleep) break the boost early, and
    whether the HUD shows it as engaged vs. merely enabled.

16. **Worksite job queues + conditional repeat.** Worksites like the
    crafting spot should hold a *queue* of orders, not just one order at
    a time — RimWorld's bill system: do X times, do until you have N in
    stock, do forever. This turns the craft-spot panel's one-button
    orders into a proper production list. Open seams: the per-order
    condition vocabulary (count / "while below" / repeat-forever),
    whether queued-but-not-runnable orders block or skip, whether orders
    are per-worksite or colony-wide, and where the escrow lives for an
    order that hasn't started yet (presumably inputs escrow on start,
    not on queue).

17. **Desperation foraging.** A sufficiently hungry unit shouldn't starve
    next to a bush nobody designated: below a desperation line (a lower
    threshold than `food_seek`), a unit that finds no edible pile should
    self-direct a forage — walk to the nearest ripe bush, strip it, and
    eat the yield *on the spot* rather than dropping it for hauling. The
    machinery mostly exists: `nearest_food_pile` covers the pile leg,
    `Plants` tracks ripe bushes, and `EAT` already eats out of a pile —
    the new parts are a bush query ("nearest ripe forageable"), a
    self-issued forage-then-eat chain, and a threshold so desperation
    doesn't compete with ordinary `FORAGE` designations. Open seams: the
    threshold itself (zero, or a band between `food_seek` and zero),
    whether the yield is dropped and eaten or eaten off the bush
    directly, and whether desperation can interrupt a claimed job
    mid-work or only fires at the idle gate.

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
