class_name Unit
extends Node3D

## A worker: claims jobs from the [Colony], walks to them over the voxel grid
## and mines. Deliberately small — it is the hook where real AI (needs, skills,
## hauling, sleep schedules) gets added later.

enum State { IDLE, MOVING, WORKING, YIELDING, SLEEPING, EATING, RECREATING, DOWNED }
## How well the unit rests: NORMAL in a bed, POOR on the ground.
enum RestQuality { POOR, NORMAL }

## Every state transition reports here — the observer seam colony
## bookkeeping (sleep counting for the sleep-speed boost) and future
## mod hooks subscribe to rather than polling every unit every frame.
signal state_changed(from_state: State, to_state: State)

const DLog := preload("res://scripts/dlog.gd")

## Skin-tone ramp anchors: pale to dark. Each unit draws a random point
## along the ramp at spawn.
const SKIN_TONE_PALE := Color(0.96, 0.80, 0.66)
const SKIN_TONE_MID := Color(0.55, 0.36, 0.24)
const SKIN_TONE_DARK := Color(0.20, 0.11, 0.07)

@export var move_speed: float = 4.0
## Enough to clear a 1 m step: apex is jump_speed² / (2 × gravity).
@export var jump_speed: float = 7.5
## Ladder descent rate — slower than walking, so a climb reads as a
## climb rather than a teleport down the shaft.
@export var climb_speed: float = 2.5
@export var gravity: float = 22.0
## Distance in metres from the unit's centre to a block's nearest face.
@export var mine_reach: float = 1.5
## Hardness points worked through per second.
@export var mining_speed: float = 2.0
## Cubic metres of items shovelled per second — clearing and gathering alike.
@export var clearing_speed: float = 2.0
## Material volume, in cubic centimetres, a unit carries on one trip —
## the shovel/bag's scoop limit. Mass is the second cap: the load must
## also come in under `drag_kg`.
@export var carry_capacity: int = 500_000
## The unit's species — every unit is a colonist today, but capacities
## and hit points read off the shared Species table so a second body
## plan is a data entry, not a subclass.
var species: StringName = &"colonist"
## Hit points — the sum of every body part's pool, kept synced from
## [member wounds] by `_sync_health` so the combat and HUD code that
## reads a single bar still works. The wounds are authoritative; this
## is the derived total.
@export var health: float = 100.0
## The fraction of walk speed a dragged load allows — corpses, boulders
## and other over-`carry_kg` loads still move, just slowly.
const DRAG_SPEED_MULT := 0.5
## Under this fraction of max health a hunter gives up the chase — the
## animal won the fight.
const HUNT_ABORT_FRACTION := 0.35

## The per-part body plan (item 28): wounds land on parts, and part
## damage — not the pooled bar — drives incapacitation, death and the
## physical effects. `hp` is the damage a part takes before it is
## destroyed outright; `coverage` its share of incoming hits; `vital`
## parts kill when destroyed and `moves` parts down the unit (and slow
## it meanwhile). Sums: hp 100, coverage 1.0.
const BODY_PARTS: Dictionary = {
	&"head": {&"hp": 10.0, &"coverage": 0.08, &"vital": true},
	&"torso": {&"hp": 40.0, &"coverage": 0.40, &"vital": true},
	&"left_arm": {&"hp": 10.0, &"coverage": 0.13, &"works": true},
	&"right_arm": {&"hp": 10.0, &"coverage": 0.13, &"works": true},
	&"left_leg": {&"hp": 15.0, &"coverage": 0.13, &"moves": true},
	&"right_leg": {&"hp": 15.0, &"coverage": 0.13, &"moves": true},
}
## Display names for the inspect panel's wound list.
const PART_NAMES: Dictionary = {
	&"head": "head", &"torso": "torso",
	&"left_arm": "left arm", &"right_arm": "right arm",
	&"left_leg": "left leg", &"right_leg": "right leg",
}
## A wound record: {part, kind, severity, bleed, care} — `bleed` is the
## fraction of total blood lost per game-day, `care` the treatment tier
## (0 untreated, 1 first aid — bleeding stopped only, 2 bedded medical
## tend, 3 bedded tend with medicine). Wound kinds set the bleed rate
## per severity point.
const WOUND_BLEED: Dictionary = {
	&"bruise": 0.0,
	&"cut": 0.05,
	&"bite": 0.06,
	&"gore": 0.08,
}
## Severity healed per game-day, before the care multiplier — an
## untreated scratch closes in a day or two on its own.
const WOUND_HEAL_PER_DAY := 8.0
## Healing multiplier per care tier — first aid literally only stops
## the bleeding (tier 1 heals at the natural rate); real treatment
## needs an established medical bed.
const CARE_HEAL_MULT: Array[float] = [1.0, 1.0, 3.0, 4.0]
## Resting in a bed — any bed — heals a little faster on top of care.
const BED_HEAL_MULT := 1.5
## Blood regenerated per game-day once nothing is bleeding.
const BLOOD_RECOVERY_PER_DAY := 0.35
## A medicined tend seals this share of each wound instantly — the
## care multiplier does the rest over the following days.
const TEND_MEDICINE_SEAL := 0.25
## Below this health the unit drops: too hurt to stand. A destroyed
## leg or deep blood loss down the unit at any health total.
const DOWNED_HEALTH := 45.0
## Below this blood fraction the unit drops; at zero it dies.
const DOWNED_BLOOD_LOSS := 0.5
## Below this health the unit is a patient — it seeks a medical bed
## and stays until it mends past the line.
const PATIENT_HEALTH := 80.0
## Live wounds. Small — a handful per serious fight — and serialized.
var wounds: Array = []
## Blood lost, as a fraction of the whole — bleeds out at 1.0.
var blood_loss := 0.0
## The unit has died: pending removal. Its corpse is a physical item.
var dead := false
## A downed unit being hauled to a bed by a rescuer — its mass counts
## against the carrier's load and it does not path on its own.
var _carried_unit: Unit = null
## The rescuer carrying this unit, or null.
var _carried_by: Unit = null
## Seconds of work at a crafting spot to finish one craft order.
@export var crafting_seconds: float = 4.0
## Seconds of work to take a construction apart.
@export var deconstruct_seconds: float = 2.0
## Seconds of work at the field cell to set a seed in the ground.
@export var sow_seconds: float = 1.5
## Seconds of spreading work a fertilize job spends at its cell once the
## compost is in hand — same motion as sowing.
@export var fertilize_seconds: float = 1.5
## Seconds without getting closer to the job site before the unit drops the
## assignment as unreachable.
@export var stuck_timeout: float = 5.0
## Below this energy the unit stops taking jobs and finds somewhere to
## sleep — a free bed if one's reachable, else the ground under it.
@export var rest_seek: float = 0.25
## Below this hunger the unit interrupts work to eat — the nearest pile
## holding food, or it goes hungry and slows.
@export var food_seek: float = 0.3
## The desperation line: below this hunger — always below the effective
## food-seek line — a unit that finds no edible pile self-forages the
## nearest ripe bush and eats the yield on the spot.
@export var desperation_seek: float = 0.12
## Below this recreation the unit stops taking jobs and goes looking
## for fun — a rec building if one's free, else a walk, the sky, a
## prayer or a chat. Recreation below the line never interrupts work —
## only the idle gate reads it.
@export var recreation_seek: float = 0.35
## A spent mood-therapy latch re-arms once the fun bar drops back this
## far while mood stays critical — sessions below it top the bar with
## room to spare. Picked so the drain-plus-session cycle (~2 min)
## beats the `had_fun` thought's half-day decay: sessions stack the
## positive thought instead of letting each one expire alone.
const REC_THERAPY_REFILL := 0.75
## Work rate while starving — hunger at zero halves the unit's speed at
## every kind of labour rather than downing it.
const STARVING_SPEED := 0.5
## Seconds a unit stands at a closed door while it swings — the door
## opens for the passage and shuts itself after. The pathfinder prices
## a door cell the same distance this pause costs at walk speed.
const DOOR_OPEN_SECONDS := 0.75

## Personality facets — the character-attribute system, Dwarf Fortress
## style: each facet is a continuous 0–100 value rolled at spawn rather
## than a categorical trait. Where RimWorld would gate behaviour behind
## a trait name (Lazy/Industrious, Nervous/Steadfast) a facet's position
## modulates it — `facet_scale` turns 50 into ×1.0, the ends into
## ×0.5/×1.5. The set so far:
##   activity_level       restless — seeks recreation sooner, boredom
##                        bites harder, and wanders further off-route
##                        to grab a haulable pile it passes
##                        (the Lazy↔Industrious band)
##   stress_vulnerability amplifies negative thoughts, pulls the break
##                        threshold up, and shortens the hunger a unit
##                        will sit with before self-foraging
##                        (Nervous↔Steadfast)
##   cheer_propensity     amplifies positive thoughts
##   gregariousness       social thoughts pay more; the gregarious
##                        crave company and go lonely without it
##   immoderation         pleasures of the table matter more — seeks
##                        food earlier, gorges past the hunger line,
##                        and breaks off for a meal sooner
##   strength             scales carry/drag capacity — the Weak↔Strong
##                        hauling band
##   bravery              how deep into critical failure a drafted unit
##                        holds before breaking off the fight — and how
##                        hard its fists land in melee
## The facet list is deliberately small — new facets join when a system
## has a use for them. The old categorical `traits` folded into these
## bands: ascetic/gourmand/immoderation became positions on
## immoderation, iron_willed a low stress_vulnerability; saved trait
## ids still load by nudging the matching facet toward its end.
const FACETS: Array[StringName] = [
	&"activity_level",
	&"stress_vulnerability",
	&"cheer_propensity",
	&"gregariousness",
	&"immoderation",
	&"strength",
	&"bravery",
]
## The unit's facet values, 0–100 — rolled in `_ready`, persisted.
var facets: Dictionary = {}


## Thoughts — RimWorld's name for timed mood modifiers, the moodlet
## seam. Every entry is a data row, so the set is cheap to extend and a
## natural candidate for runtime spec files when modding lands. Fields:
##   `label`      shown in UI/log text
##   `offset`     mood shift per stack, on the 0–1 mood scale
##   `days`       lifetime in game days — its presence makes the thought
##                stored and stackable; entries without it are state
##                thoughts recomputed every tick by `_state_thought_on`
##   `stack`      max simultaneous stacks (each expires separately)
##   `facet`      intensity facet — the offset scales with
##                `facet_scale(facet)`; absent means flat
##   `facet_min`/`facet_max`  gate — the thought only applies while the
##                named facet sits in the range
const THOUGHTS: Dictionary = {
	# Nights under the open sky sting, but the second rough night is
	# the hurt that stays with a settler — stacking to five made a
	# homeless fortnight a mood death sentence nothing could answer.
	&"slept_on_ground": {
		&"label": "slept on the ground", &"offset": -0.05,
		&"days": 1.0, &"stack": 2, &"facet": &"stress_vulnerability",
	},
	&"slept_in_bed": {
		&"label": "slept in a bed", &"offset": 0.04,
		&"days": 1.0, &"stack": 3, &"facet": &"cheer_propensity",
	},
	&"ate_raw_food": {
		&"label": "ate raw food", &"offset": -0.04,
		&"days": 1.0, &"stack": 3, &"facet": &"immoderation",
	},
	&"ate_cooked_meal": {
		&"label": "ate a cooked meal", &"offset": 0.05,
		&"days": 1.0, &"stack": 3, &"facet": &"immoderation",
	},
	&"ate_at_table": {
		&"label": "ate at a table", &"offset": 0.03,
		&"days": 1.0, &"stack": 3, &"facet": &"cheer_propensity",
	},
	&"ate_without_table": {
		&"label": "ate without a table", &"offset": -0.04,
		&"days": 1.0, &"stack": 3, &"facet": &"stress_vulnerability",
	},
	&"had_fun": {
		&"label": "had some fun", &"offset": 0.06,
		&"days": 0.5, &"stack": 5, &"facet": &"cheer_propensity",
	},
	&"socialized": {
		&"label": "relaxed with company", &"offset": 0.05,
		&"days": 0.5, &"stack": 5, &"facet": &"gregariousness",
	},
	&"catharsis": {
		&"label": "catharsis", &"offset": 0.15,
		&"days": 3.0, &"stack": 2,
	},
	&"botched_craft": {
		&"label": "botched a crafting job", &"offset": -0.05,
		&"days": 1.0, &"stack": 3, &"facet": &"stress_vulnerability",
	},
	&"starving": {
		&"label": "starving", &"offset": -0.15,
		&"facet": &"stress_vulnerability",
	},
	&"bored_stiff": {
		&"label": "bored stiff", &"offset": -0.08,
		&"facet": &"activity_level",
	},
	&"craves_company": {
		&"label": "craves company", &"offset": -0.05,
		&"facet": &"gregariousness", &"facet_min": 60,
	},
	&"in_pain": {
		&"label": "in pain", &"offset": -0.08,
		&"facet": &"stress_vulnerability",
	},
	# Carried or bedridden, unconscious — the patient misses all of it.
	&"in_medical_care": {
		&"label": "receiving care", &"offset": 0.02,
	},
	# Surroundings — the beauty sample the colony scores every few
	# seconds: a dressed room or a tidy clearing lifts spirits, bare
	# dirt walls drag on them.
	&"drab_surroundings": {
		&"label": "drab surroundings", &"offset": -0.03,
		&"facet": &"stress_vulnerability",
	},
	&"pleasant_surroundings": {
		&"label": "pleasant surroundings", &"offset": 0.03,
		&"facet": &"cheer_propensity",
	},
	&"impressive_surroundings": {
		&"label": "impressive surroundings", &"offset": 0.06,
		&"facet": &"cheer_propensity",
	},
}
## Baseline mood with no thoughts — RimWorld's "strive to survive"
## default; a difficulty knob when difficulty lands.
const MOOD_BASE := 0.32
## Mood-bar drift rates per in-game hour — rising is faster than
## falling, RimWorld's asymmetry.
const MOOD_RISE := 0.12
const MOOD_FALL := 0.08
## Minor break threshold before the stress-vulnerability shift —
## RimWorld's baseline, with major at 4/7 and extreme at 1/4 of major.
const BREAK_MINOR := 0.35
## Mean-time-between-breaks per tier, in game days — RimWorld's
## baseline table.
const BREAK_MTB_MINOR := 4.0
const BREAK_MTB_MAJOR := 0.8
const BREAK_MTB_EXTREME := 0.5
## Current mood, 0–1 — drifts toward `mood_target()`, frozen while
## SLEEPING. Below the break threshold the unit risks a mental break.
var mood := 0.5
## Debug/difficulty knob — scales break MTBs; tests shrink it to force
## prompt breaks.
var break_mtb_scale := 1.0
## Active stored thoughts: id → Array of expiry game_msecs, one per
## stack. State thoughts never land here.
var _thoughts: Dictionary = {}
## True while a mental break runs — suppresses need interrupts on the
## break activity and switches `_meal_target` to full for a binge.
var _in_break := false
## Game-msec of the last social recreation — feeds `craves_company`.
var _last_social_at := -1
## What the current meal contained — bites flag the forms so the end of
## the meal can attach the right thought.
var _meal_voxel: Vector3i = Vector3i.MAX
var _meal_ate := false
var _meal_cooked := false
## cm³ of food one bite takes, and seconds between bites while EATING.
const BITE_CM3 := 10_000
const BITE_SECONDS := 0.6
## Seconds between surroundings samples — the beauty pass raycasts, so
## it runs on this cadence rather than per frame, staggered per unit.
const BEAUTY_REFRESH_SEC := 3.0
## How much closer to the job site, in metres, counts as making progress.
const STUCK_PROGRESS := 0.25
## A* runs per repath, tops. A work spot further down the list is almost
## never the only reachable one, and a capped storm falls back to a
## pile-crossing path — the unit shoves obstructions aside on the way.
const MAX_PATH_ATTEMPTS := 16

var state: State = State.IDLE:
	set(value):
		if value == state:
			return
		var previous := state
		_note("%s -> %s" % [State.keys()[state], State.keys()[value]])
		state = value
		state_changed.emit(previous, state)
var job: ColonyJob = null
## This unit's skin tone: a random point along the pale-to-dark ramp,
## rolled in [method _ready] and applied to the body material.
var skin_tone: Color = SKIN_TONE_MID

var _world: VoxelWorld
var _colony: Colony
var _path: PackedVector3Array = PackedVector3Array()
var _path_index: int = 0
var _repath_cooldown: float = 0.0
## Swing time spent at the door the path is about to cross — the unit
## waits it out at the threshold, then walks through.
var _door_wait: float = 0.0
## The door cell the current crossing already paid the swing for —
## while the waypoint stays that cell the unit walks on through instead
## of re-opening it every frame; stepping onto the cell clears it, so
## the way back pays again.
var _door_paid := Vector3i.MAX
var _job_search_cooldown: float = 0.0
var _stuck_elapsed: float = 0.0
var _best_goal_distance: float = INF
var _clear_budget: float = 0.0
## What the unit is pathing toward — the job voxel, or for a build fetch the
## dirt pile it's collecting from.
var _goal_voxel: Vector3i = Vector3i.ZERO
## Build/haul phase: true while fetching items, false while delivering.
var _fetching: bool = false
## Craft phase: true while ferrying finished products to the bill's
## destination stockpile — the "Take to …" delivery leg.
var _delivering_craft: bool = false
## Items physically carried — loose soil for a build job, pile contents for
## a haul. Dropped where the unit stands if the job is abandoned.
var _carried: Array[DropItem] = []
## Haul targets (source piles or stockpile tiles) that recently failed —
## the unit leaves them alone for a while instead of retrying in a loop.
var _haul_blacklist: Dictionary = {}
## Food piles the unit failed to reach or eat from — same escalating
## retry pattern as the haul blacklist, so one unreachable berry pile
## doesn't starve a unit that could reach another.
var _food_blacklist: Dictionary = {}
## The pile the unit is hauling to a stockpile before resuming its job —
## a packed pile blocking the path, or a pile beside the route grabbed
## opportunistically. Vector3i.MAX when not detouring.
var _detour: Vector3i = Vector3i.MAX
## Detour phase: false while heading for the pile, true while carrying
## its contents to the stockpile.
var _detour_delivering := false
## What [member _goal_voxel] was before the detour took it over.
var _detour_return: Vector3i = Vector3i.ZERO
## What [member _fetching] was before the detour took over the goal —
## haul-side code rewrites it mid-detour, and a build fetch that loses
## its flag comes back "delivering" to a pile cell: reach passes, work
## bounces, and the unit flickers between them forever.
var _detour_return_fetching := false
## True when the detour is an opportunistic grab — a pile beside the
## route, hauled only to the stockpile it was validated against and only
## taking what a real haul would move. False for a blocking pile, which
## comes out wholesale and delivers to the nearest tile with room.
var _detour_opportunistic := false
## The stockpile an opportunistic detour was validated against — picked
## for sitting near the job's goal. Vector3i.MAX for a blocking pile,
## whose destination is chosen at arrival instead.
var _detour_dest: Vector3i = Vector3i.MAX

## Direct control: a drafted unit takes no jobs and services no needs —
## it holds its post, chases attackers in reach, and breaks off only
## when a critical need or injury says the fight is over. Drafting is a
## stance, not a state: the ORDER job carries the current instruction
## (a post voxel, or an animal in `job.animal` to engage).
var drafted := false
## The cell a drafted unit returns to — its hold position. Vector3i.MAX
## means it stands where it is.
var _order_voxel: Vector3i = Vector3i.MAX
## What the unit is fighting — set by an attack order or by being hit.
## Any live hostile here takes priority over every other behaviour.
## Deliberately untyped: a killed animal frees mid-order and a typed
## field reads back null, which would make a finished attack order
## indistinguishable from a stand-fast one.
var _combat_target = null
## The live ORDER job is a fight, not a post-hold — `job.animal` alone
## can't say so once the target frees (a freed reference reads null).
var _order_fighting := false
## Seconds between hostile scans while standing a drafted post — the
## scan is a colony-wide animal sweep, too dear to run per frame.
var _order_scan := 0.0
## The drafted guard radius — hostiles inside it get charged.
const GUARD_RANGE := 8.0
## Seconds between guard scans at a held post.
const ORDER_SCAN_SECONDS := 0.6
## Furthest a combat order chases — past it the quarry's gone and the
## fight is called off.
const ORDER_DISENGAGE := 40.0
## The critical-need line a drafted unit breaks at, before personality —
## `bravery` scales it: the timid break at need ~0.375, the stalwart
## hold to ~0.125.
const DRAFT_NEED_LINE := 0.25
## Worn apparel — garments on the body, layer-resolved through
## [constant DropItem.APPAREL_SPECS]: two worn items can't share a
## layer, and each may lend holsters or a carry bonus.
var worn: Array[DropItem] = []
## Tools held in the hands — most units have two, so two one-handers
## or one two-hander fits. A hand holding a tool can't carry: cargo
## lives in [member _carried] and the free-hand fraction scales its
## capacity. Weapons are tools for this purpose when they exist.
var hands: Array[DropItem] = []
## Tools stowed in the holsters worn garments lend — the tool belt's
## two. Indexed by slot: an entry is a DropItem or null, so a reserved
## slot can sit empty waiting for its tool. A holstered tool frees
## its hand without leaving the unit's possession.
var holstered: Array = []
## Per-holster-slot reservations — `&""` takes any tool, anything else
## admits only a tool of that spec. Sized to `holster_count()`; the
## player sets them per slot so a slot can be kept free for a weapon.
var holster_prefs: Array[StringName] = []
## The player's allowed-area assignment — null means unrestricted.
## The gate runs at target selection: job claims, fetch queries and
## self-issued errands all veto cells outside the area. A drafted
## unit's orders are player-forced and skip it.
var allowed_area: AllowedArea = null
## Seconds of worn-garment wear accrued — the tick applies it to every
## worn item at a fixed trickle.
var _wear_elapsed := 0.0
## Worn garments lose this much condition per second — a garment worn
## around the clock lasts about sixty game-days before it's threadbare.
const GARMENT_WEAR_PER_SEC := 1.0 / (240.0 * 60.0)
## How far from the job's goal, in metres, a stockpile may sit for a
## mid-route grab to count as "on the way".
const DETOUR_GOAL_REACH := 12.0
## Specialists' cap on the same reach — a specialist keeps to its route
## where a generalist wanders further for a free haul.
const DETOUR_SPECIALIST_REACH := 0.4
## How rested the unit is, 0–1. Drains while awake — a full bar lasts
## roughly two thirds of a day — and recovers while SLEEPING.
var energy := 1.0
## How fed the unit is, 0–1. Drains over a day; below [member food_seek]
## the unit seeks food, and at zero it keeps working at half speed.
var hunger := 1.0
## How amused the unit is, 0–1. Drains slowly — a full bar lasts about a
## day and a half — and refills while a RECREATE job runs. Below
## [member recreation_seek] the unit goes looking for fun at idle.
var recreation := 1.0
## The surroundings score the unit last sampled — the enclosing room's
## integrated beauty, or a sight-line mean of the faces and objects
## within [constant Colony.BEAUTY_RADIUS]. The surroundings thoughts
## threshold on it; refreshed every [constant BEAUTY_REFRESH_SEC].
var beauty := 0.0
var _beauty_elapsed := 0.0
## Eat-clock accumulator — one bite per [constant BITE_SECONDS].
var _eat_budget := 0.0
## The bed this unit is sleeping in (or walking to), or null.
var _rest_bed: Building = null
## Rest rate in force while SLEEPING — bed sleep is NORMAL, ground POOR.
var _rest_quality: RestQuality = RestQuality.POOR

## Recreation activities that need no building — the free half of the
## list. Building-backed activities key their spec into
## [constant BlockRegistry.REC_SPECS]; the shared fields here are
## `kind` (the tolerance category — repeating one kind yields less),
## `seconds` (session length), `label` (status gerund) and flags:
## `sky` (the spot must see the sky), `moves` (the travel IS the
## activity — a walk accrues while moving), `partner` (needs a nearby
## idle unit).
const REC_ACTIVITIES: Dictionary = {
	&"pray": {
		&"kind": &"solitary", &"label": "praying", &"seconds": 24.0,
	},
	&"meditate": {
		&"kind": &"solitary", &"label": "meditating", &"seconds": 32.0,
	},
	## Contemplation is the self-taught path to knowledge: a finished
	## session rolls [constant CONTEMPLATE_INSIGHT_CHANCE] for enough XP
	## in a random skill to learn it outright — the thinker may invent
	## a skill nobody in the colony has. Facets and mood will later bend
	## the propensity; the per-skill pool comes later too.
	&"contemplate": {
		&"kind": &"solitary", &"label": "contemplating", &"seconds": 40.0,
	},
	&"skygaze": {
		&"kind": &"solitary", &"label": "skygazing", &"seconds": 28.0,
		&"sky": true,
	},
	&"walk": {
		&"kind": &"solitary", &"label": "going for a walk", &"seconds": 48.0,
		&"moves": true,
	},
	&"social": {
		&"kind": &"social", &"label": "relaxing socially", &"seconds": 28.0,
		&"partner": true,
	},
	## Not recreation — a minor mental break: the unit wanders
	## aimlessly for a while. `power` 0 means the outing pays no
	## recreation and `_pick_recreation` never offers it; only
	## `_start_break` forces it.
	&"daze": {
		&"kind": &"none", &"label": "wandering in a daze",
		&"seconds": 32.0, &"moves": true, &"power": 0.0,
	},
}
## How much of the recreation bar a full-rate session refills.
const REC_SESSION_FILL := 0.35
## Tolerance decay per day — a used-up kind is forgotten in about a
## week of game days.
const REC_TOLERANCE_DECAY := 0.15
## How close the social partner must stay for the chat to count.
const REC_SOCIAL_RANGE := 3.0
## How far out a unit looks for someone to relax with.
const REC_SOCIAL_SEEK := 24.0
## Seconds left on the running recreation session — a walk spends it
## moving, everything else spends it standing.
var _rec_left := 0.0
## The recreation building this unit is playing, or null — its
## `occupant` claim frees when the session ends or drops.
var _rec_building: Building = null
## The unit being chatted with on a social recreation session, or null.
var _rec_partner: Unit = null
## Recreation actually gained this session — a session that paid out
## leaves a `had_fun` thought behind.
var _session_gain := 0.0
## Recreation spots that recently failed — voxel → {at, n} with the
## same escalating retry delay as the haul blacklist.
var _rec_blacklist: Dictionary = {}
## Per-kind familiarity, 0–1 — doing an activity grows its kind's
## tolerance and scales down its gain; tolerance decays over days.
var _rec_tolerance: Dictionary = {}

## Skill XP by [constant ColonyJob.Skill]. Levels derive from XP, so only
## the raw points are stored: reaching level L takes
## [constant SKILL_XP_BASE] × L(L+1)/2 total XP — X to level 1, then 2X
## more to level 2, and so on.
var skills: Dictionary = {
	ColonyJob.Skill.MINING: 0.0,
	ColonyJob.Skill.CONSTRUCTION: 0.0,
	ColonyJob.Skill.PLANTS: 0.0,
	ColonyJob.Skill.CRAFTING: 0.0,
}
## Job-choice stance: a specialist favours jobs matching its skills over
## nearby ones; a generalist mostly takes the closest work. Player-set.
@export var specialize := false

## Duty flag — relieved units take no board jobs at all: they still
## rest, eat, seek care and recreation on their own, but the player has
## stood them down (convalescence, pre-raid rest, a problem colonist
## better kept in the rec room). Player-set, rides the save.
@export var relieved := false

## Mood-therapy latch — true while the unit's decompressing after
## crossing the therapy line; cleared when mood clears the release
## margin (hysteresis keeps it from ping-ponging session-to-work).
var _decompressing := false
## Set when a therapy stint ends by topping the fun bar out — the mood
## intervention is spent until fun genuinely drains again (down to the
## boredom seek line). Without it a chronically-low mood re-latches the
## tick after release and the unit chains sessions back to back.
var _decompress_spent := false

## XP a level-0→1 jump costs — the requirement grows linearly after
## that: X, then 2X, 3X, …
const SKILL_XP_BASE := 10.0
## Work speed doubles every this many skill levels: a level-10 worker is
## ~2× a level-0 one, level 20 ~4×.
const SKILL_DOUBLE_LEVELS := 10.0
## Skill XP a tutoring unit drips to its student per second of lesson —
## 100 XP (ten levels) takes ~3½ in-game hours. The teacher takes half
## as much again from practising the explanation.
const TEACH_XP_PER_SECOND := 0.3
## The unit's recent decisions — state changes, claims, goal picks,
## detours — as timestamped one-liners, newest last. The trail answers
## "why is it doing that" after the fact; the overseer's debug dump (F9)
## writes every unit's trail to the clipboard and a user:// file.
const DECISION_TRAIL_MAX := 96
var _decisions: Array[String] = []

## Chance a finished contemplation session yields an insight — a level-1
## worth of XP in a random skill. Kept low: knowledge should be scarce.
const CONTEMPLATE_INSIGHT_CHANCE := 0.15
## Seconds spent sidestepping for another unit — yields give up quickly if
## the step-aside spot can't be reached.
var _yield_elapsed: float = 0.0
## Seconds spent waiting for units to clear a build voxel before giving up.
var _evict_elapsed: float = 0.0
## Instance id this unit's kinematic body is registered under in DelveSim.
var _sim_id: int = 0
## Sim/physics motion state — written by _apply_motion, read by the move
## ticks the way is_on_floor()/is_on_wall() used to be.
var _grounded := true
var _blocked_horiz := false
## Intended velocity — heading.x/z are written by move ticks, y is the
## vertical rate the sim reports back. Not a physics property: the unit
## has no body; DelveSim owns motion and this is just a scratchpad.
var velocity := Vector3.ZERO
## A move tick's jump request, consumed by the next _apply_motion.
var _want_jump := false
## A move tick's ladder-descent request, likewise consumed.
var _want_descend := false
## The ground cell this unit last wore — trampling counts cell entries,
## not frames, so standing still never grinds grass down.
var _trample_cell := Vector3i.MAX


## Cubic metres currently carried.
func _carried_volume() -> int:
	var total := 0
	for item in _carried:
		total += item.volume
	return total


## Hand slots occupied by held tools — a two-handed tool takes both.
func _hands_busy() -> int:
	var busy := 0
	for item in hands:
		busy += 2 if DropItem.tool_two_handed(item) else 1
	return mini(busy, 2)


## The free-hand fraction for hauling — 1.0 empty-handed, 0.5 with one
## tool in hand, 0.0 with both hands (or a two-hander) full.
func _hands_free_frac() -> float:
	return (2.0 - _hands_busy()) / 2.0


## The carry multiplier worn apparel lends — the backpack's bonus.
func _apparel_carry_mult() -> float:
	var mult := 1.0
	for item in worn:
		mult *= DropItem.garment_carry_mult(item)
	return mult


## The load this unit can lift right now — the base carry capacity
## times the apparel bonus and the free-hand fraction. A tool in one
## hand halves the load; tools in both end it. This replaces raw
## `carry_cap()` everywhere a take is bounded.
func carry_cap() -> int:
	return int(
		carry_capacity * _apparel_carry_mult() * _hands_free_frac()
	)


## Kilograms the unit can carry unpenalized — the species norm scaled
## by the strength facet, and by the same hands/apparel factors as the
## volume cap: a full hand halves what the other can haul.
func _carry_kg() -> float:
	return (
		Species.field(species, &"carry_kg", 40.0)
		* _facet_scale(&"strength")
		* _apparel_carry_mult()
		* _hands_free_frac()
	)


## The heaviest load — per item and in total — the unit can move at
## all; over it, nothing budges.
func _drag_kg() -> float:
	return (
		Species.field(species, &"drag_kg", 1500.0)
		* _facet_scale(&"strength")
	)


## Mass of everything in hand — carried items plus a carried patient.
func _carried_mass() -> float:
	var kg := 0.0
	for item in _carried:
		kg += item.mass_kg()
	if _carried_unit != null:
		kg += _carried_unit.mass_kg()
	return kg


## True while the load is over carry capacity — the unit is dragging,
## and `_move_speed` halves for it. A patient is always dragged — even
## a light colonist outweighs `carry_kg`.
func _dragging() -> bool:
	return _carried_mass() > _carry_kg()


## The body layers already covered by worn garments.
func _worn_layers() -> Array:
	var layers: Array = []
	for item in worn:
		layers.append_array(DropItem.garment_layers(item))
	return layers


## Whether [param item] can go on — a garment whose layers are all
## still free.
func can_wear(item: DropItem) -> bool:
	if item.form != DropItem.Form.GARMENT or worn.has(item):
		return false
	var taken := _worn_layers()
	for layer in DropItem.garment_layers(item):
		if taken.has(layer):
			return false
	return true


## Puts a garment on — false when one of its layers is taken. The
## caller owns the item's passage here (a pile take, a carried drop).
func wear_garment(item: DropItem) -> bool:
	if not can_wear(item):
		return false
	worn.append(item)
	_resize_holsters()
	return true


## Takes a garment off; the caller owns where it lands. If the piece
## lent holsters, tools stranded over the new holster count drop at
## the unit's feet rather than floating in limbo.
func strip_garment(item: DropItem) -> void:
	worn.erase(item)
	_resize_holsters()


## Keeps the holster arrays sized to what the worn garments lend —
## a belt going on opens slots (and prefs), one coming off strands
## whatever sat past the new count: the tools drop at the unit's feet.
func _resize_holsters() -> void:
	var count := holster_count()
	while holstered.size() < count:
		holstered.append(null)
	while holster_prefs.size() < count:
		holster_prefs.append(&"")
	while holstered.size() > count:
		var item: DropItem = holstered.pop_back()
		if item != null and _colony != null:
			_colony._drop_item(item, _standing_voxel())
	while holster_prefs.size() > count:
		holster_prefs.pop_back()


## The first worn garment of [param spec_id], or null.
func garment_worn(spec_id: StringName) -> DropItem:
	for item in worn:
		if item.spec == spec_id:
			return item
	return null


## The worn garments whose layers [param item] would occupy — the
## pieces a swap would have to take off first.
func garment_conflicts(item: DropItem) -> Array[DropItem]:
	var out: Array[DropItem] = []
	for layer in DropItem.garment_layers(item):
		for garment in worn:
			if (
				DropItem.garment_layers(garment).has(layer)
				and not out.has(garment)
			):
				out.append(garment)
	return out


## Whether the unit wants a garment from a pile — either its layers
## are free, or every garment it would displace is more worn than it
## (the swap is an upgrade). A worse piece over better worn kit is
## left for someone else.
func wants_garment(item: DropItem) -> bool:
	if can_wear(item):
		return true
	var conflicts := garment_conflicts(item)
	if conflicts.is_empty():
		return false
	for conflict in conflicts:
		if conflict.wear >= item.wear:
			return false
	return true


## Holster slots the worn garments lend — the tool belt's two.
func holster_count() -> int:
	var total := 0
	for item in worn:
		total += DropItem.garment_holsters(item)
	return total


## Occupied holster slots — `holstered` is indexed by slot, so its
## size is capacity and nulls are empty space (reserved or not).
func _holstered_count() -> int:
	var taken := 0
	for item in holstered:
		if item != null:
			taken += 1
	return taken


## Free holster slots — counting reserved-but-empty ones: something
## fits there, just not anything.
func holster_room() -> int:
	return holster_count() - _holstered_count()


## The first holster slot that takes [param tool] — free, and either
## unreserved or reserved for this tool's spec. -1 when nothing fits:
## a slot kept for a weapon refuses the shovel.
func _holster_slot_for(tool: DropItem) -> int:
	for i in mini(holstered.size(), holster_count()):
		if holstered[i] != null:
			continue
		var pref: StringName = (
			holster_prefs[i] if i < holster_prefs.size() else &""
		)
		if pref == &"" or pref == tool.spec:
			return i
	return -1


## Whether the tool can go to a hand — a free slot for a one-hander,
## both for a two-hander.
func can_hold(item: DropItem) -> bool:
	if not DropItem.is_tool_item(item):
		return false
	return (
		_hands_busy() + (2 if DropItem.tool_two_handed(item) else 1) <= 2
	)


## Puts a tool in hand — false when it doesn't fit. The caller owns
## the item's passage here.
func hold_tool(item: DropItem) -> bool:
	if not can_hold(item):
		return false
	hands.append(item)
	return true


## Stows held tools into holster slots that take them — the
## belt-wearer's answer to a haul: the tools leave the hands without
## leaving the unit's possession. Tools no slot accepts stay held;
## a reserved slot keeps its vacancy for its own spec.
func stow_tools() -> void:
	for i in range(hands.size() - 1, -1, -1):
		var slot := _holster_slot_for(hands[i])
		if slot < 0:
			continue
		holstered[slot] = hands[i]
		hands.remove_at(i)


## Moves held tools into holster room when hands are needed for
## carrying — called at the fetch sites so a belt-wearing unit frees
## its hands instead of hauling at half capacity.
func _stow_for_work() -> void:
	if _hands_busy() > 0:
		stow_tools()


## The best tool the unit already carries for [param classes] —
## hands first (already wielded), then the holsters. Null when
## nothing fits; worn-out shells don't count as equipment.
func _tool_for(classes: Array) -> DropItem:
	for item in hands:
		if (
			classes.has(DropItem.tool_class(item))
			and item.wear > 0.0
		):
			return item
	for item in holstered:
		if (
			item != null
			and classes.has(DropItem.tool_class(item))
			and item.wear > 0.0
		):
			return item
	return null


## The required tool in hand — pulls a matching holstered tool into a
## free hand when the hands don't already hold one (stowing other
## tools to make room). Null when the unit carries nothing usable.
func _work_tool(classes: Array) -> DropItem:
	for item in hands:
		if (
			classes.has(DropItem.tool_class(item))
			and item.wear > 0.0
		):
			return item
	var stowed := _tool_for(classes)
	if stowed == null:
		return null
	if not can_hold(stowed):
		stow_tools()
	if not can_hold(stowed):
		return null
	holstered[holstered.find(stowed)] = null
	hands.append(stowed)
	return stowed


## Wears a working tool down — one point of wear per hardness-unit of
## progress over the head's rated life — then breaks it when it runs
## out: the haft drops whole and the shattered head pours back as
## gravel. A dead head can't be re-forged, which is what the iron
## set is for.
func _wear_tool(tool: DropItem, progress: float) -> void:
	var life := DropItem.tool_use_life(tool)
	if life <= 0.0:
		return
	tool.wear -= progress / life
	if tool.wear <= 0.0:
		_break_tool(tool)


## Drops a broken tool's remains at the unit's feet — the rod whole,
## the head as gravel — and frees the hand it was in.
func _break_tool(tool: DropItem) -> void:
	hands.erase(tool)
	var at := _standing_voxel()
	_colony._drop_item(
		DropItem.new(
			BlockRegistry.Resource_.BRANCH, DropItem.Form.LOOSE,
			DropItem.ROD_CM3
		),
		at
	)
	_colony._drop_item(
		DropItem.new(
			int(tool.material), DropItem.Form.LOOSE, DropItem.COBBLE_CM3
		),
		at
	)
	_note("%s broke" % tool.spec_name())


## Sends the unit after the nearest qualifying tool, or hands the job
## back when no pile holds one anywhere — like a build job starved of
## materials, it returns to the board for the next claimant.
func _redirect_tool_fetch(classes: Array) -> void:
	var next := _colony.nearest_tool_voxel(
		_standing_voxel(), classes, allowed_area
	)
	if next == Vector3i.MAX:
		_give_up_on_job()
		return
	_fetching = true
	_goal_voxel = next
	_path.clear()
	state = State.MOVING


## The fetch half of a tool job: at the pile, take the best qualifying
## tool — to a free hand, or to a holster when the hands are full —
## then head for the work.
func _tick_tool_fetch(_delta: float) -> void:
	var classes: Array = (
		Colony.required_tool(job, _world).get(&"classes", [])
	)
	if _tool_for(classes) != null:
		# Something qualified reached the belt or hands en route.
		_fetching = false
		_goal_voxel = job.voxel_position
		_path.clear()
		state = State.MOVING
		return
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	var pile := _colony.item_pile_at(_goal_voxel)
	var tool: DropItem = pile.take_tool(classes) if pile != null else null
	if pile != null:
		_colony.remove_pile_if_empty(_goal_voxel)
	if tool == null:
		# The pile drained under us — look again or give up.
		_redirect_tool_fetch(classes)
		return
	if not hold_tool(tool):
		var slot := _holster_slot_for(tool)
		if slot >= 0:
			holstered[slot] = tool
		else:
			# Nowhere to put it — back on the ground and give up.
			_colony._drop_item(tool, _standing_voxel())
			_give_up_on_job()
			return
	_fetching = false
	_goal_voxel = job.voxel_position
	_path.clear()
	state = State.MOVING


## Worn garments fray at a slow, fixed trickle — sixty game-days of
## continuous wear to threadbare. Once a garment is gone it comes off
## and drops: threadbare clothing falls apart rather than lingering.
func _wear_tick(delta: float) -> void:
	_wear_elapsed += delta
	if _wear_elapsed < 1.0:
		return
	var worn_loss := _wear_elapsed * GARMENT_WEAR_PER_SEC
	_wear_elapsed = 0.0
	var gone: Array[DropItem] = []
	for garment in worn:
		garment.wear = maxf(0.0, garment.wear - worn_loss)
		if garment.wear <= 0.0:
			gone.append(garment)
	for garment in gone:
		# strip_garment also drops holstered tools the piece stranded.
		strip_garment(garment)
		if _colony != null:
			_colony._drop_item(garment, _standing_voxel())


## Leg-condition multiplier: part damage on `moves` parts slows the
## unit; a destroyed leg downs it outright (see `is_downed`).
func mobility() -> float:
	var legs := 0.0
	var total := 0
	for part: StringName in BODY_PARTS:
		var spec: Dictionary = BODY_PARTS[part]
		if not spec.get(&"moves", false):
			continue
		total += 1
		legs += 1.0 - clampf(
			part_damage(part) / float(spec[&"hp"]), 0.0, 1.0
		)
	return legs / maxi(total, 1)


## Arm-condition multiplier for labour — wrecked hands work slower.
func manipulation() -> float:
	var arms := 0.0
	var total := 0
	for part: StringName in BODY_PARTS:
		var spec: Dictionary = BODY_PARTS[part]
		if not spec.get(&"works", false):
			continue
		total += 1
		arms += 1.0 - clampf(
			part_damage(part) / float(spec[&"hp"]), 0.0, 1.0
		)
	return arms / maxi(total, 1)


## Walk speed under the current load and leg wounds — dragged loads
## move at half pace, wrecked legs proportionally slower.
func _move_speed() -> float:
	var leg_mult := 0.3 + 0.7 * mobility()
	return move_speed * leg_mult * (
		DRAG_SPEED_MULT if _dragging() else 1.0
	)


## Post-filters a pulled item list by what the body can move: the
## running mass caps at `drag_kg`, single items over it go back to
## [param pile], and a loose item that only partly fits pours off the
## kilograms that do. Every pickup runs through here, so nothing ever
## lands in hand the unit couldn't lift.
func _keep_liftable(items: Array[DropItem], pile: ItemPile) -> Array[DropItem]:
	var kept: Array[DropItem] = []
	var back: Array[DropItem] = []
	var room := maxf(_drag_kg() - _carried_mass(), 0.0)
	for item in items:
		var kg := item.mass_kg()
		if kg <= room:
			room -= kg
			kept.append(item)
			continue
		if item.form == DropItem.Form.LOOSE:
			# Bulk pours — take the kilograms that fit.
			var fit := int(
				room * 1000.0 / BlockRegistry.density_of(item.material)
			)
			if fit > 0:
				var part := DropItem.new(item.material, item.form, fit)
				part.species = item.species
				part.nutrition = item.nutrition
				item.volume -= fit
				kept.append(part)
				room = 0.0
		back.append(item)
	if not back.is_empty():
		pile.add_items(back, false)
	return kept


## Shovel budget in cm³ — _clear_budget accrues in m³/s floats; spending
## snaps to integer cm³ so item volumes stay exact.
func _budget_cm3() -> int:
	return int(_clear_budget * DropItem.CM3_PER_M3)


func _spend_budget(cm3: int) -> void:
	_clear_budget -= float(cm3) / DropItem.CM3_PER_M3


@onready var _body: MeshInstance3D = $MeshInstance3D
@onready var _status_label: Label3D = $StatusLabel


func _ready() -> void:
	skin_tone = _random_skin_tone()
	# Personality facets — a bell curve around average, DF-style.
	if facets.is_empty():
		for facet_name: StringName in FACETS:
			facets[facet_name] = int(clampf(randfn(50.0, 16.0), 0.0, 100.0))
	# Staggered reserves keep the whole colony from napping at once.
	energy = randf_range(0.65, 1.0)
	# Same for the surroundings sampler — a rosterful of units resampling
	# in one frame would spike the raycast budget.
	_beauty_elapsed = randf() * BEAUTY_REFRESH_SEC
	# The capsule material is a shared scene resource — duplicate before
	# tinting or every unit would share one color.
	var material := _body.get_surface_override_material(0).duplicate() as StandardMaterial3D
	material.albedo_color = skin_tone
	_body.set_surface_override_material(0, material)


func setup(world: VoxelWorld, colony: Colony) -> void:
	_world = world
	_colony = colony
	_sim_id = get_instance_id()
	if _world.sim != null:
		_world.sim.unit_register(_sim_id, global_position)


func _exit_tree() -> void:
	if _world != null and _world.sim != null and _sim_id != 0:
		_world.sim.unit_unregister(_sim_id)


## Serialized form for the region save — position, needs, skills, facets
## and what's in hand. A claimed job doesn't persist: it reverts to
## pending on load and someone claims it again; self-issued work (rest,
## eat, desperation) re-derives from the restored needs.
func serialize() -> Dictionary:
	var carried: Array = []
	for item in _carried:
		carried.append(item.serialize())
	var skill_list: Array = []
	for skill in skills:
		skill_list.append([int(skill), skills[skill]])
	var tolerance: Dictionary = {}
	for kind: StringName in _rec_tolerance:
		tolerance[String(kind)] = _rec_tolerance[kind]
	var facet_data: Dictionary = {}
	for facet_name: StringName in facets:
		facet_data[String(facet_name)] = facets[facet_name]
	# Thoughts persist as seconds-remaining per stack so a save resumed
	# under a different clock still honours the original lifetimes.
	var thought_data: Dictionary = {}
	var now := _colony.game_msec()
	for id: StringName in _thoughts:
		var left: Array = []
		for expiry in _thoughts[id]:
			left.append(maxi(int(expiry) - now, 0) / 1000.0)
		if not left.is_empty():
			thought_data[String(id)] = left
	var wound_data: Array = []
	for wound: Dictionary in wounds:
		wound_data.append([
			String(wound[&"part"]), String(wound[&"kind"]),
			float(wound[&"severity"]), float(wound[&"bleed"]),
			int(wound[&"care"]),
		])
	return {
		"position": [
			global_position.x, global_position.y, global_position.z
		],
		"species": String(species),
		"health": health,
		"wounds": wound_data,
		"blood_loss": blood_loss,
		"hunger": hunger,
		"energy": energy,
		"recreation": recreation,
		"rec_tolerance": tolerance,
		"mood": mood,
		"facets": facet_data,
		"thoughts": thought_data,
		"social_ago": (
			(now - _last_social_at) / 1000.0
			if _last_social_at >= 0 else null
		),
		"specialize": specialize,
		"relieved": relieved,
		"drafted": drafted,
		"order_post": (
			[_order_voxel.x, _order_voxel.y, _order_voxel.z]
			if _order_voxel != Vector3i.MAX else null
		),
		"worn": worn.map(
			func(item: DropItem) -> Array: return item.serialize()
		),
		"hands": hands.map(
			func(item: DropItem) -> Array: return item.serialize()
		),
		"holstered": holstered.map(
			func(item: DropItem) -> Variant: return (
				item.serialize() if item != null else null
			)
		),
		"holster_prefs": holster_prefs.map(
			func(p: StringName) -> String: return String(p)
		),
		"state": int(state),
		"skills": skill_list,
		"carried": carried,
		"bed": (
			[_rest_bed.voxel.x, _rest_bed.voxel.y, _rest_bed.voxel.z]
			if _rest_bed != null else null
		),
	}


## Restores a freshly spawned unit from its save record — the colony has
## already placed the node, this refills what it carries.
func deserialize(data: Dictionary, colony: Colony) -> void:
	var pos: Array = data.get("position", [0, 0, 0])
	global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	species = StringName(data.get("species", "colonist"))
	health = float(data.get("health", health))
	for e: Array in data.get("wounds", []):
		wounds.append({
			&"part": StringName(e[0]), &"kind": StringName(e[1]),
			&"severity": float(e[2]), &"bleed": float(e[3]),
			&"care": int(e[4]),
		})
	blood_loss = float(data.get("blood_loss", 0.0))
	hunger = float(data.get("hunger", hunger))
	energy = float(data.get("energy", energy))
	recreation = float(data.get("recreation", recreation))
	for kind in data.get("rec_tolerance", {}):
		_rec_tolerance[StringName(kind)] = float(
			data["rec_tolerance"][kind]
		)
	mood = float(data.get("mood", mood))
	for f in data.get("facets", {}):
		facets[StringName(f)] = int(data["facets"][f])
	var now := colony.game_msec()
	for id in data.get("thoughts", {}):
		var stacks: Array = []
		for left in data["thoughts"][id]:
			stacks.append(now + int(float(left) * 1000.0))
		_thoughts[StringName(id)] = stacks
	var social_ago: Variant = data.get("social_ago")
	if social_ago != null:
		_last_social_at = now - int(float(social_ago) * 1000.0)
	specialize = bool(data.get("specialize", false))
	relieved = bool(data.get("relieved", false))
	drafted = bool(data.get("drafted", false))
	var post: Variant = data.get("order_post")
	_order_voxel = (
		Vector3i(int(post[0]), int(post[1]), int(post[2]))
		if post != null else Vector3i.MAX
	)
	for item_data: Array in data.get("worn", []):
		worn.append(DropItem.deserialize(item_data))
	for item_data: Array in data.get("hands", []):
		hands.append(DropItem.deserialize(item_data))
	var holstered_data: Array = data.get("holstered", [])
	# Slot-indexed: entries may be null (an empty reserved slot), and a
	# pre-slot save's dense list fills slots 0..n the same way.
	for i in holstered_data.size():
		var entry: Variant = holstered_data[i]
		holstered.append(
			DropItem.deserialize(entry) if entry != null else null
		)
	for p: Variant in data.get("holster_prefs", []):
		holster_prefs.append(StringName(String(p)))
	while holstered.size() < holster_count():
		holstered.append(null)
	while holster_prefs.size() < holster_count():
		holster_prefs.append(&"")
	var gear: Variant = data.get("equipment")
	if gear != null:
		# The old single provisional slot — a held item. A tool goes to
		# a hand; anything else was really just carried cargo.
		var legacy := DropItem.deserialize(gear)
		if DropItem.is_tool_item(legacy):
			hands.append(legacy)
		else:
			_carried.append(legacy)
	for pair: Array in data.get("skills", []):
		skills[int(pair[0])] = float(pair[1])
	# A legacy save's categorical traits fold into facet bands — the
	# `traits` key is no longer written, but an old record still lands.
	for t in data.get("traits", []):
		match StringName(t):
			&"ascetic":
				facets[&"immoderation"] = mini(facet(&"immoderation"), 25)
			&"gourmand":
				facets[&"immoderation"] = maxi(facet(&"immoderation"), 75)
			&"immoderation":
				facets[&"immoderation"] = maxi(facet(&"immoderation"), 85)
			&"iron_willed":
				facets[&"stress_vulnerability"] = mini(
					facet(&"stress_vulnerability"), 25
				)
	for item_data: Array in data.get("carried", []):
		_carried.append(DropItem.deserialize(item_data))
	var saved_state := int(data.get("state", State.IDLE))
	if saved_state != State.SLEEPING and saved_state != State.DOWNED:
		return
	# Transient states (moving, working, eating) re-derive from a fresh
	# IDLE; sleep and downed are the ones worth keeping — they hold the
	# bed claim.
	var bed_data: Variant = data.get("bed")
	if bed_data != null:
		var bed := colony.buildings.get(
			Vector3i(
				int(bed_data[0]), int(bed_data[1]), int(bed_data[2])
			)
		) as Building
		if bed != null:
			_rest_bed = bed
			bed.claim_bed(self)
	state = State.DOWNED if saved_state == State.DOWNED else State.SLEEPING


## Floating status caption — the same string the colonist bar shows,
## tinted by state so sleepers and loafers read at a glance.
func _process(_delta: float) -> void:
	if _status_label == null or _world == null:
		return
	var text := current_activity()
	if _status_label.text == text:
		return
	_status_label.text = text
	match state:
		State.SLEEPING:
			_status_label.modulate = Color(0.6, 0.75, 1.0)
		State.DOWNED:
			_status_label.modulate = Color(1.0, 0.55, 0.5)
		State.IDLE, State.YIELDING:
			_status_label.modulate = Color(1.0, 1.0, 1.0, 0.55)
		_:
			_status_label.modulate = Color.WHITE


## A random point along the pale → mid → dark skin-tone ramp.
static func _random_skin_tone() -> Color:
	var t := randf()
	if t < 0.5:
		return SKIN_TONE_PALE.lerp(SKIN_TONE_MID, t * 2.0)
	return SKIN_TONE_MID.lerp(SKIN_TONE_DARK, t * 2.0 - 1.0)


func _physics_process(delta: float) -> void:
	if _world == null:
		return

	_job_search_cooldown = maxf(_job_search_cooldown - delta, 0.0)
	_repath_cooldown = maxf(_repath_cooldown - delta, 0.0)
	_order_scan = maxf(_order_scan - delta, 0.0)

	if _colony.needs_enabled:
		# Downed in a bed is still rest — the body mends and the energy
		# bar refills just as sleep does.
		if state == State.SLEEPING or (
			state == State.DOWNED and _rest_bed != null
		):
			energy = minf(
				energy + delta / _rest_span() * _bed_quality_mult(), 1.0
			)
			if (
				state == State.SLEEPING and energy >= 1.0
				and not _bedrest_needed()
			):
				_wake()
		else:
			# A full bar lasts two thirds of a day awake — the rest of
			# the day is sleep, which is where the "a third of each day"
			# comes from.
			energy = maxf(energy - delta / (_colony.day_length() * 2.0 / 3.0), 0.0)
			if energy <= 0.0 and state != State.DOWNED:
				_collapse()
		# A full stomach lasts a day — sleep doesn't pause digestion.
		hunger = maxf(hunger - delta / _colony.day_length(), 0.0)
		# Recreation drains slower than hunger — a full bar lasts about a
		# day and a half — and pauses while a session is running.
		if state != State.RECREATING and (
			job == null or job.type != ColonyJob.Type.RECREATE
		):
			recreation = maxf(
				recreation - delta / (_colony.day_length() * 1.5), 0.0
			)
		# Surroundings beauty re-samples on a slow cadence — the room
		# score or the sight-line pass, whichever covers where the unit
		# stands. Units take the update in turns via the seeded offset.
		_beauty_elapsed -= delta
		if _beauty_elapsed <= 0.0:
			_beauty_elapsed = BEAUTY_REFRESH_SEC
			beauty = _colony.unit_beauty(
				global_position + Vector3(0.0, 0.9, 0.0), _standing_voxel()
			)
		var tolerance_forgotten: Array = []
		for kind: StringName in _rec_tolerance:
			_rec_tolerance[kind] = maxf(
				float(_rec_tolerance[kind])
					- delta * REC_TOLERANCE_DECAY / _colony.day_length(),
				0.0
			)
			if _rec_tolerance[kind] <= 0.0:
				tolerance_forgotten.append(kind)
		for kind in tolerance_forgotten:
			_rec_tolerance.erase(kind)
		_tick_mood(delta)
		_tick_wounds(delta)
		_wear_tick(delta)

	# A drafted unit fights on regardless of anything — until a critical
	# need or the wounds themselves say it's done. Personality shifts
	# the line; it never lifts it off the floor entirely.
	if drafted and _must_undraft():
		set_drafted(false)

	# A carried patient's wounds keep running above, but its body rides
	# on the rescuer — no self-driven motion or state work.
	if _carried_by != null:
		return
	if _carried_unit != null:
		# Keep the carried unit on the rescuer's shoulder.
		_carried_unit.global_position = (
			global_position + Vector3(0.0, 0.9, 0.0)
		)

	match state:
		State.IDLE:
			_tick_idle()
		State.MOVING:
			_tick_moving(delta)
		State.WORKING:
			_tick_working(delta)
		State.YIELDING:
			_tick_yielding(delta)
		State.SLEEPING:
			_tick_sleeping(delta)
		State.EATING:
			_tick_eating(delta)
		State.RECREATING:
			_tick_recreating(delta)
		State.DOWNED:
			_tick_downed(delta)

	_apply_motion(delta)


## Everything the unit is hauling or carrying goes down here — a job
## abandoned mid-haul drops the load, and so does a unit that turns to
## fight. A rescued patient gets set down, not spilled like an item.
func _drop_load() -> void:
	for item in _carried:
		_colony._drop_item(item, _standing_voxel())
	_carried.clear()
	if _carried_unit != null:
		_put_down_patient()


func abandon_job() -> void:
	if job != null:
		_note("job dropped: " + _job_label())
	_order_fighting = false
	_drop_load()
	job = null
	if _rest_bed != null:
		_rest_bed.release_bed(self)
		_rest_bed = null
	if _rec_building != null:
		if _rec_building.occupant == self:
			_rec_building.occupant = null
		_rec_building = null
	_rec_partner = null
	_rec_left = 0.0
	_session_gain = 0.0
	_in_break = false
	_rest_quality = RestQuality.POOR
	_path.clear()
	_door_wait = 0.0
	_door_paid = Vector3i.MAX
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_clear_budget = 0.0
	_fetching = false
	_delivering_craft = false
	_evict_elapsed = 0.0
	_detour = Vector3i.MAX
	_detour_delivering = false
	_detour_return = Vector3i.ZERO
	_detour_return_fetching = false
	_detour_opportunistic = false
	_detour_dest = Vector3i.MAX
	_eat_budget = 0.0
	state = State.IDLE


## Drafting on: the unit drops its work and its load where it stands
## and holds this spot. Off: the stance and any order dissolve — the
## unit falls back to the job board (or stays downed/asleep).
func set_drafted(on: bool) -> void:
	if on == drafted:
		return
	if on:
		if dead or is_downed():
			return
		if state == State.SLEEPING:
			_wake()
		drafted = true
		abandon_job()
		_order_voxel = _standing_voxel()
		_note("drafted")
	else:
		drafted = false
		_combat_target = null
		_order_voxel = Vector3i.MAX
		_note("undrafted")
		if state != State.DOWNED and state != State.SLEEPING:
			abandon_job()


## Overseer order: walk to [param cell] and hold it. Drafted units only
## — an idle worker has the job board instead.
func order_move(cell: Vector3i) -> void:
	if not drafted or dead:
		return
	_order_voxel = cell
	_combat_target = null
	_order_fighting = false
	_note("ordered to %s" % str(cell))
	if job != null:
		job = null
		state = State.IDLE


## Overseer order: engage [param target] in melee. Drafted units only;
## after the fight the unit returns to its post. Untyped like
## `_target_valid` — the cursor's pick may be a freed node.
func order_attack(target) -> void:
	if not drafted or dead or not _target_valid(target):
		return
	_combat_target = target
	_order_fighting = false
	_note("ordered to attack %s" % _target_label(target))
	if job != null:
		job = null
		state = State.IDLE


## Overseer order: batter [param building] to pieces — melee against a
## construction (a barricade in the way, a door that has to come down).
## Drafted units only; the unit walks to the nearest work spot and
## swings until the record's hit points run out.
func order_wreck(building: Building) -> void:
	if (
		not drafted or dead or building == null
		or _colony.buildings.get(building.voxel) != building
	):
		return
	_combat_target = null
	_order_fighting = false
	_note("ordered to wreck %s" % building.label())
	job = ColonyJob.new(ColonyJob.Type.ORDER, building.voxel)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	job.structure = building
	_goal_voxel = building.voxel
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if _repath_to_job():
		state = State.MOVING
	else:
		job = null


## A live target worth fighting — animals only for now; there is no
## unit-on-unit violence until factions exist. Untyped on purpose: the
## target is often a freed node by the time the check runs (an animal
## that died mid-fight), and a typed parameter rejects freed objects
## before `is_instance_valid` can see them.
func _target_valid(target) -> bool:
	return (
		target != null
		and is_instance_valid(target)
		and target is Animal
		and not (target as Animal).dead
	)


func _target_label(target: Node3D) -> String:
	return target.label() if target is Animal else str(target)


## The idle drafted unit: hold the post, or take the fight to whatever
## it's already engaged with. No jobs, no needs — `_must_undraft` owns
## the way out.
func _tick_drafted() -> void:
	if _target_valid(_combat_target):
		_start_fight()
		return
	_combat_target = null
	if _order_scan <= 0.0:
		_order_scan = ORDER_SCAN_SECONDS
		var threat := _nearest_threat()
		if threat != null:
			_combat_target = threat
			_note("engaging %s" % threat.label())
			_start_fight()
			return
	if (
		_order_voxel != Vector3i.MAX
		and _standing_voxel() != _order_voxel
	):
		_hold_post()


## The nearest hostile in charge range of the post — an animal is a
## threat once it has committed to an attack (State.ATTACKING); a
## predator prowling past isn't charged on sight.
func _nearest_threat() -> Animal:
	var best: Animal = null
	var best_d := GUARD_RANGE
	var anchor := global_position
	if _order_voxel != Vector3i.MAX:
		anchor = Vector3(_order_voxel) + Vector3(0.5, 0.5, 0.5)
	for animal in _colony.animals:
		if (
			not is_instance_valid(animal)
			or animal.dead
			or animal.state != Animal.State.ATTACKING
		):
			continue
		var d := anchor.distance_to(animal.global_position)
		if d < best_d:
			best = animal
			best_d = d
	return best


## The drafted breaking point: every bar is watched against one line,
## which `bravery` moves — timid units fold early, stalwarts fight into
## the red. Downed is always the end; nobody holds a post unconscious.
func _must_undraft() -> bool:
	var line := DRAFT_NEED_LINE * (2.0 - _facet_scale(&"bravery"))
	return (
		is_downed()
		or hunger <= line
		or energy <= line
		or recreation <= line
		or mood < _break_threshold()
		or health < _health_max() * line
	)


## Something hit the unit — drop everything carried and turn to face it.
## Works the same drafted or not: a load can't be hauled through a
## fight, and a sleeper has to wake for it.
func _engage(target) -> void:
	if dead or is_downed() or not _target_valid(target):
		return
	# Already fighting — a hit lands every frame it stays in reach, and
	# abandoning the order each time would livelock the unit into
	# re-minting it without ever swinging. A second attacker doesn't
	# steal a live engagement either: finishing the fight in hand beats
	# flinching between targets. This only holds while a fight order
	# actually stands — if the mint failed, the hit still drops the
	# load and tries again.
	if (
		job != null
		and job.type == ColonyJob.Type.ORDER
		and _target_valid(job.animal)
	):
		if state == State.SLEEPING:
			_wake()
		return
	_drop_load()
	_combat_target = target
	if state == State.SLEEPING:
		_wake()
	elif state == State.IDLE:
		_start_fight()
		return
	# Work states abandon their job — fighting wins over hauling.
	if (
		state == State.MOVING
		or state == State.WORKING
		or state == State.YIELDING
		or state == State.EATING
		or state == State.RECREATING
	):
		abandon_job()


## Mint the self-issued ORDER job that carries a fight — the chase is
## the same retarget machinery a HUNT uses, the kill is the same melee.
func _start_fight() -> void:
	if not _target_valid(_combat_target):
		_combat_target = null
		return
	var cell := Vector3i(_combat_target.global_position.floor())
	job = ColonyJob.new(ColonyJob.Type.ORDER, cell)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	job.animal = _combat_target as Animal
	_order_fighting = true
	_goal_voxel = cell
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if _repath_to_job():
		state = State.MOVING
	else:
		# Unreachable for now — stay; the target may come to us.
		job = null


## A newcomer's walk in from the site edge — a self-issued move order
## to [param cell], the same machinery the out-of-area return uses.
## On arrival the order completes and ordinary idle takes over.
func arrive(cell: Vector3i) -> void:
	if dead or drafted:
		return
	job = ColonyJob.new(ColonyJob.Type.ORDER, cell)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_note("arriving")
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = cell
	if _repath_to_job():
		state = State.MOVING
	else:
		# Can't walk the intercept — stay; the colony is where it lands.
		job = null


## Mint the self-issued ORDER job that walks the unit back to its post.
func _hold_post() -> void:
	job = ColonyJob.new(ColonyJob.Type.ORDER, _order_voxel)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_goal_voxel = _order_voxel
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if _repath_to_job():
		state = State.MOVING
	else:
		# Can't get back — the post becomes where the unit stands.
		job = null
		_order_voxel = _standing_voxel()


## An ORDER job's work: swing at the target while it's in melee reach,
## batter the structure a wreck order names, or stand the post and keep
## scanning for something to charge.
func _tick_order(delta: float) -> void:
	if job.structure != null:
		# The wreck is done when the record stops being what the colony
		# maps at the cell — teardown frees the object, so the map, not
		# validity, is the liveness check.
		if _colony.buildings.get(job.voxel_position) != job.structure:
			_finish_order()
			return
		if not _can_reach_from(
			global_position, job.voxel_position,
			_world.is_solid(job.voxel_position)
		):
			state = State.MOVING
			return
		_colony.damage_building(job.structure, _melee_dps() * delta)
		return
	var target := job.animal
	if target != null:
		if not is_instance_valid(target) or target.dead:
			_combat_target = null
			_finish_order()
			return
		if (
			global_position.distance_to(target.global_position)
				> Animal.MELEE_RANGE
		):
			# Drifted out of reach — chase it down again.
			state = State.MOVING
			return
		target.take_hit(_melee_dps() * delta, self)
		return
	if _order_fighting:
		# The order was an attack and its `animal` field now reads null —
		# the target died and freed; a freed reference compares == null
		# here, so the flag, not the field, says the fight is over.
		_combat_target = null
		_finish_order()
		return
	if _order_scan <= 0.0:
		_order_scan = ORDER_SCAN_SECONDS
		var threat := _nearest_threat()
		if threat != null:
			_combat_target = threat
			_note("engaging %s" % threat.label())
			_finish_order()
			_start_fight()


## The order's satisfied — self-issued jobs never hit the board, so they
## just dissolve and the idle tick decides what's next.
func _finish_order() -> void:
	_order_fighting = false
	job = null
	state = State.IDLE


## Unarmed melee damage-per-second — the species base scaled by the
## unit's frame and how well its arms still work. A weapon will add
## itself here once equipment does more than exist.
func _melee_dps() -> float:
	return (
		Species.field(species, &"melee", 6.0)
		* _facet_scale(&"strength")
		* manipulation()
	)


func current_activity() -> String:
	match state:
		State.MOVING:
			if _door_wait > 0.0:
				return "opening a door"
			if job == null:
				return "walking"
			if _detour != Vector3i.MAX:
				if _detour_opportunistic:
					return (
						"dropping it off en route" if _detour_delivering
						else "grabbing a load en route"
					)
				if _detour == job.voxel_position:
					return "hauling cleared items"
				return "hauling a blockage" if _detour_delivering else "clearing a blockage"
			if job.type == ColonyJob.Type.HAUL:
				return "fetching items" if _fetching else "hauling to stockpile"
			if job.type == ColonyJob.Type.DRESS:
				return "getting dressed"
			if job.type == ColonyJob.Type.BUILD and _fetching:
				return (
					"fetching floor materials"
					if job.face_dir != Vector3i.ZERO
					else "fetching wall materials"
				)
			if job.type == ColonyJob.Type.CRAFT:
				var move_recipe := Colony.recipe_of(job.recipe)
				if move_recipe.get(&"study", false):
					return (
						"fetching a specimen" if _fetching
						else "heading to the research bench"
					)
				if move_recipe.has("builds"):
					return (
						"fetching materials" if _fetching
						else "heading to the site"
					)
				return (
					"fetching materials" if _fetching
					else "heading to the crafting spot"
				)
			if job.type == ColonyJob.Type.UNINSTALL:
				return (
					"fetching packing material" if _fetching
					else "packing furniture"
				)
			if job.type == ColonyJob.Type.UNPACK:
				return "heading to a crate"
			if (
				(
					job.type == ColonyJob.Type.MINE
					or job.type == ColonyJob.Type.CHOP
				)
				and _fetching
			):
				return "fetching a tool"
			if job.type == ColonyJob.Type.REST:
				return "heading to bed"
			if job.type == ColonyJob.Type.EAT:
				return "seeking food"
			if job.type == ColonyJob.Type.FORAGE:
				return (
					"desperately foraging" if job.desperate
					else "heading to a berry bush"
				)
			if job.type == ColonyJob.Type.SOW:
				return (
					"fetching seeds" if _fetching
					else "heading to the field"
				)
			if job.type == ColonyJob.Type.REFUEL:
				return (
					"fetching fuel" if _fetching
					else "heading to the campfire"
				)
			if job.type == ColonyJob.Type.HUNT:
				return (
					"tracking a %s" % job.animal.label()
					if job.animal != null and is_instance_valid(job.animal)
					else "tracking"
				)
			if job.type == ColonyJob.Type.ORDER:
				return (
					"charging a %s" % job.animal.label()
					if job.animal != null and is_instance_valid(job.animal)
					else "moving to position"
				)
			if job.type == ColonyJob.Type.BUTCHER:
				return (
					"fetching a carcass" if _fetching
					else "hauling a carcass to the butcher spot"
				)
			if job.type == ColonyJob.Type.TEND:
				return (
					"fetching medicine" if _fetching
					else "hurrying to a patient"
				)
			if job.type == ColonyJob.Type.RESCUE:
				return (
					"carrying a patient" if _carried_unit != null
					else "heading to a patient"
				)
			if job.type == ColonyJob.Type.BURN:
				return "heading to the charcoal mound"
			if job.type == ColonyJob.Type.FIREFIGHT:
				return "running to a fire"
			if job.type == ColonyJob.Type.TEACH:
				return (
					"heading to teach %s" % job.patient.name
					if job.patient != null and is_instance_valid(job.patient)
					else "heading to a lesson"
				)
			if job.type == ColonyJob.Type.RECREATE:
				var rec_spec := _rec_spec(job.rec_activity)
				if bool(rec_spec.get(&"moves", false)):
					return String(rec_spec.get(&"label", "wandering"))
				if job.rec_activity == &"social":
					return "heading over to relax"
				if BlockRegistry.REC_SPECS.has(job.rec_activity):
					return "heading to the %s" % String(
						BlockRegistry.rec_label(job.rec_activity)
					).to_lower()
				return "finding a quiet spot"
			return "walking to %s" % str(_goal_voxel)
		State.YIELDING:
			return "stepping aside"
		State.SLEEPING:
			return (
				"sleeping" if _rest_quality == RestQuality.NORMAL
				else "sleeping on the ground"
			)
		State.EATING:
			return "eating"
		State.RECREATING:
			if job == null:
				return "relaxing"
			if REC_ACTIVITIES.has(job.rec_activity):
				return String(REC_ACTIVITIES[job.rec_activity][&"label"])
			return BlockRegistry.rec_activity_label(job.rec_activity)
		State.WORKING:
			if job == null:
				return "working"
			if job.type == ColonyJob.Type.CHOP:
				return "chopping a tree"
			if job.type == ColonyJob.Type.HAUL:
				return "loading items" if _fetching else "stockpiling items"
			if job.type == ColonyJob.Type.CLEAR:
				return "clearing %s" % str(job.voxel_position)
			if job.type == ColonyJob.Type.BUILD:
				if _fetching:
					return (
						"gathering floor materials"
						if job.face_dir != Vector3i.ZERO
						else "gathering wall materials"
					)
				if job.face_dir != Vector3i.ZERO:
					return "laying %s" % BlockRegistry.floor_label(
						job.build_spec
					).to_lower()
				if job.material == BlockRegistry.Resource_.NONE:
					return "building a wall"
				return "building %s" % BlockRegistry.block_name(job.block_id)
			if job.type == ColonyJob.Type.CRAFT:
				var work_recipe := Colony.recipe_of(job.recipe)
				if work_recipe.has("builds"):
					return (
						"fetching materials" if _fetching
						else String(work_recipe["label"]).to_lower()
					)
				if _fetching:
					return "fetching materials"
				if work_recipe.get(&"study", false):
					return "studying"
				var site := _colony.building_at(job.voxel_position)
				if (
					site != null
					and site.kind == Building.Kind.CAMPFIRE
					and not site.lit()
				):
					return "waiting for fuel"
				return "crafting"
			if job.type == ColonyJob.Type.REFUEL:
				return "gathering fuel" if _fetching else "stoking the campfire"
			if job.type == ColonyJob.Type.UNINSTALL:
				return (
					"fetching packing material" if _fetching
					else "packing furniture"
				)
			if job.type == ColonyJob.Type.UNPACK:
				return "unpacking a crate"
			if job.type == ColonyJob.Type.DECONSTRUCT:
				if job.face_dir != Vector3i.ZERO:
					return "stripping a surface"
				return "deconstructing %s" % (
					_colony.building_at(job.voxel_position).label()
					if _colony.building_at(job.voxel_position) != null
					else "a building"
				)
			if job.type == ColonyJob.Type.FORAGE:
				return "foraging for survival" if job.desperate else "foraging berries"
			if job.type == ColonyJob.Type.SOW:
				return "fetching seeds" if _fetching else "sowing"
			if job.type == ColonyJob.Type.HUNT:
				return (
					"fighting a %s" % job.animal.label()
					if job.animal != null and is_instance_valid(job.animal)
					else "hunting"
				)
			if job.type == ColonyJob.Type.BUTCHER:
				return (
					"lifting the carcass" if _fetching
					else "butchering a %s" % (
						_carried_form(DropItem.Form.CORPSE).species
						if _carried_form(DropItem.Form.CORPSE) != null
						else "carcass"
					)
				)
			if job.type == ColonyJob.Type.TEND:
				return (
					"fetching medicine" if _fetching
					else "tending a patient"
				)
			if job.type == ColonyJob.Type.RESCUE:
				return "lifting a patient"
			if job.type == ColonyJob.Type.BURN:
				return "tending the charcoal burn"
			if job.type == ColonyJob.Type.TEACH:
				return (
					"teaching %s" % job.patient.name
					if job.patient != null and is_instance_valid(job.patient)
					else "teaching"
				)
			if job.type == ColonyJob.Type.REPAIR:
				return "repairing %s" % (
					_colony.building_at(job.voxel_position).label()
					if _colony.building_at(job.voxel_position) != null
					else "a building"
				)
			if job.type == ColonyJob.Type.FIREFIGHT:
				return "beating out a fire"
			if job.type == ColonyJob.Type.ORDER:
				return (
					"wrecking %s" % job.structure.label()
					if job.structure != null
					else (
						"fighting a %s" % job.animal.label()
						if job.animal != null and is_instance_valid(job.animal)
						else "holding position"
					)
				)
			return "mining %s" % BlockRegistry.block_name(_world.get_block(job.voxel_position))
		State.DOWNED:
			return "downed"
		_:
			if drafted:
				return "standing guard"
			if _colony != null and _colony.needs_enabled and hunger <= 0.0:
				return "starving"
			return "idle"


## Seconds a full sleep takes at this rest quality — a bed refills the
## bar in a third of a day; the ground takes 25% longer (five twelfths).
func _rest_span() -> float:
	var third := _colony.day_length() / 3.0
	return third if _rest_quality == RestQuality.NORMAL else third * 1.25


## Craft-quality multiplier for whatever the rest-bed provides —
## 0.80 + 0.20·quality: an awful bed under-delivers, a masterwork one
## pays a fifth again. The spec's rest value scales it too — a
## sleeping spot is worse than a proper bed, a royal bed better —
## and bedroom furniture (end table, dresser) adds its aura on top.
## Rest gain and the medical care effects of lying in one both ride
## it. Ground sleep has no bed to rate.
func _bed_quality_mult() -> float:
	if _rest_bed == null:
		return 1.0
	var mult := 0.8 + 0.2 * _rest_bed.quality
	var spec := BlockRegistry.furniture_spec(_rest_bed.spec)
	mult *= float(spec.get(&"rest", 1.0))
	mult *= 1.0 + _colony.bed_bonus_at(_rest_bed)
	return mult


## A patient stays in a medical bed past a full bar — it's the facility
## that makes real treatment possible — until the wounds say they're
## well enough to work.
func _bedrest_needed() -> bool:
	return (
		_rest_bed != null
		and _rest_bed.medical
		and needs_medical_attention()
		# Nobody feeds a patient yet — a starving one gets up to eat.
		and hunger > _desperation_line()
	)


## Sleep done: hand the bed back and return to the board — and let the
## mood record how the night went (beds comfort, ground doesn't).
func _wake() -> void:
	add_thought(
		&"slept_in_bed"
		if _rest_quality == RestQuality.NORMAL
		else &"slept_on_ground"
	)
	if _rest_bed != null:
		_rest_bed.release_bed(self)
		_rest_bed = null
	job = null
	state = State.IDLE


## Out of energy mid-work: the unit sleeps where it stands — poor rest,
## no trip to a bed. The job goes back on the board first so it doesn't
## die on an assignee who's down for the count.
func _collapse() -> void:
	drafted = false
	_combat_target = null
	if job != null:
		_colony.release_job(job)
	abandon_job()
	_rest_quality = RestQuality.POOR
	state = State.SLEEPING


## The unit needs sleep: claim the nearest free bed and walk over —
## a REST job carries the goal through the usual moving machinery — or,
## when there's no bed, lie down on the ground right here. Ground rest
## is POOR: it takes a quarter again as long as a bed.
func _start_rest() -> void:
	_rest_quality = RestQuality.POOR
	var bed := _colony.nearest_free_bed(_standing_voxel(), allowed_area)
	if bed != null:
		bed.claim_bed(self)
		_rest_bed = bed
		if bed.footprint.has(_standing_voxel()):
			_rest_quality = RestQuality.NORMAL
			state = State.SLEEPING
			return
		job = ColonyJob.new(ColonyJob.Type.REST, bed.voxel)
		job.state = ColonyJob.State.ASSIGNED
		job.assignee = self
		_note("seeking bed " + _job_label())
		_stuck_elapsed = 0.0
		_best_goal_distance = INF
		_goal_voxel = bed.voxel
		state = State.MOVING
		if _repath_to_job():
			return
		# The bed can't be reached — take the floor where we stand.
		bed.release_bed(self)
		_rest_bed = null
		job = null
	state = State.SLEEPING


## Wounded and upright: claim the nearest free medical bed and lie in
## it — same REST-job walk as ordinary sleep, but the destination is a
## facility so a doctor's tend is real treatment, not first aid. With
## no medical bed in reach the unit stays on its feet (field care only
## stops bleeding anyway).
func _start_medical_rest() -> void:
	var bed := _colony.nearest_free_medical_bed(_standing_voxel(), allowed_area)
	if bed == null:
		return
	bed.claim_bed(self)
	_rest_bed = bed
	if bed.footprint.has(_standing_voxel()):
		_rest_quality = RestQuality.NORMAL
		state = State.SLEEPING
		return
	job = ColonyJob.new(ColonyJob.Type.REST, bed.voxel)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_note("seeking medical bed " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = bed.voxel
	state = State.MOVING
	if _repath_to_job():
		return
	bed.release_bed(self)
	_rest_bed = null
	job = null


## Asleep: hold still and recover — _physics_process refills the bar at
## the active rest quality and _wake() releases the unit at full.
func _tick_sleeping(_delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0


## The unit needs food: walk to the nearest pile holding something
## edible — an EAT job carries the goal through the usual moving
## machinery like a REST job does. With no food anywhere the unit just
## keeps working; starvation slows it but doesn't down it.
func _start_eat() -> void:
	var spot := _colony.nearest_food_pile(
		_standing_voxel(), _food_blacklist, allowed_area
	)
	if spot == Vector3i.MAX:
		return
	job = ColonyJob.new(ColonyJob.Type.EAT, spot)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_note("seeking food " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = spot
	if _repath_to_job():
		state = State.MOVING
	else:
		# The food can't be reached — remember it and stay hungry; the
		# next seek tries the next-best pile instead of hammering this one.
		_blacklist_food(spot)
		job = null
		_job_search_cooldown = 2.0


## Marks a food pile as recently failed — the next seek picks a
## different pile when one exists.
func _blacklist_food(spot: Vector3i) -> void:
	var record: Dictionary = _food_blacklist.get(spot, {})
	record["at"] = _colony.game_msec()
	record["n"] = int(record.get("n", 0)) + 1
	_food_blacklist[spot] = record


## The effective hunger thresholds — facets slide them (a gourmand
## seeks early, a steadfast unit digs deeper into starvation before
## breaking off).
func _food_seek() -> float:
	return food_seek * _facet_scale(&"immoderation")


func _desperation_line() -> float:
	return minf(
		desperation_seek
		* _facet_scale(&"immoderation")
		* _facet_scale(&"stress_vulnerability"),
		_food_seek()
	)


## Hunger to eat up to — a full stomach for an ordinary meal, the
## unit's own seek line for a desperation meal (an immoderate unit
## gorges; none can stop below the line or it would still count as
## hungry on the next tick).
func _meal_target() -> float:
	if _in_break:
		# A food binge eats to full.
		return 1.0
	var base := _food_seek() if job != null and job.desperate else 1.0
	return clampf(base * _facet_scale(&"immoderation"), _food_seek(), 1.0)


## Below the desperation line with no edible pile in reach: the unit
## self-issues a forage on the nearest un-designated ripe bush — the
## job never touches the colony board, and the meal after it eats just
## enough to cross the hunger line, dropping the rest.
func _start_desperate_forage() -> void:
	var root := _colony.nearest_ripe_bush(
		_standing_voxel(), _food_blacklist, allowed_area
	)
	if root == Vector3i.MAX:
		return
	job = ColonyJob.new(ColonyJob.Type.FORAGE, root)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_note("desperate forage " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = root
	if _repath_to_job():
		state = State.MOVING
	else:
		# The bush can't be reached — blacklist it like a failed pile.
		_blacklist_food(root)
		job = null
		_job_search_cooldown = 2.0


## The effective recreation threshold — the activity_level facet
## slides the base line: a restless unit goes looking for fun early.
func _recreation_seek() -> float:
	return recreation_seek * _facet_scale(&"activity_level")


## The activity record for a recreation id — free activities live in
## [constant REC_ACTIVITIES], building ones in
## [constant BlockRegistry.REC_SPECS] keyed by the building's spec.
func _rec_spec(activity: StringName) -> Dictionary:
	if REC_ACTIVITIES.has(activity):
		return REC_ACTIVITIES[activity]
	return BlockRegistry.REC_SPECS.get(activity, {})


## Recreation restored per second of [param activity] — the spec's
## session length spreads [constant REC_SESSION_FILL] across it.
func _rec_rate(activity: StringName) -> float:
	var spec := _rec_spec(activity)
	return (
		REC_SESSION_FILL
		* float(spec.get(&"power", 1.0))
		/ maxf(float(spec.get(&"seconds", 16.0)), 0.001)
	)


## Recreation-quality multiplier — 0.70 + 0.30·quality on the building
## hosting the session: a well-made board entertains faster, a splintered
## one barely passes the time. Free activities have no furniture to rate.
func _rec_quality_mult() -> float:
	return 0.7 + 0.3 * _rec_building.quality if _rec_building != null else 1.0


## Apply [param raw] recreation to the bar and grow the kind's
## tolerance by half the actual gain — repeating a kind pays less each
## time, so variety matters.
func _rec_gain(kind: StringName, raw: float) -> float:
	var tolerance := float(_rec_tolerance.get(kind, 0.0))
	var gained := raw * (1.0 - tolerance)
	recreation = minf(recreation + gained, 1.0)
	_rec_tolerance[kind] = minf(tolerance + gained * 0.5, 1.0)
	return gained


## How attractive [param spec] is right now — its power discounted by
## how played-out its kind is.
func _rec_weight_of(spec: Dictionary) -> float:
	var kind: StringName = spec.get(&"kind", &"solitary")
	return (
		float(spec.get(&"power", 1.0))
		* (1.0 - float(_rec_tolerance.get(kind, 0.0)))
	)


## Marks a recreation spot as recently failed — the next pick tries a
## different cell when one exists.
func _blacklist_rec(spot: Vector3i) -> void:
	var record: Dictionary = _rec_blacklist.get(spot, {})
	record["at"] = _colony.game_msec()
	record["n"] = int(record.get("n", 0)) + 1
	_rec_blacklist[spot] = record


## A standable cell to relax at: expanding rings between
## [param min_range] and [param max_range] voxels out, first valid cell
## wins. A `sky` spot must have a clear column overhead — skygazing
## under a roof is just standing around.
func _rec_spot(
	need_sky: bool, min_range := 4, max_range := 20, allow_here := true
) -> Vector3i:
	var here := _standing_voxel()
	var now := _colony.game_msec()
	for r in range(min_range, max_range):
		for dx in range(-r, r + 1):
			for dz in [-r, r]:
				var spot := _rec_spot_at(here, dx, dz, need_sky, now)
				if spot != Vector3i.MAX:
					return spot
		for dz in range(-r + 1, r):
			for dx in [-r, r]:
				var spot := _rec_spot_at(here, dx, dz, need_sky, now)
				if spot != Vector3i.MAX:
					return spot
	# No walk needed: the unit's own cell already qualifies (open sky
	# overhead for a skygaze that starts in place). A walk always wants
	# a destination — strolling to one's own cell isn't an outing.
	if allow_here and _rec_spot_ok(here, need_sky, now):
		return here
	return Vector3i.MAX


func _rec_spot_at(
	here: Vector3i, dx: int, dz: int, need_sky: bool, now: int
) -> Vector3i:
	var gy := _world.ground_height(here.x + dx, here.z + dz, here.y + 16)
	var spot := Vector3i(here.x + dx, gy + 1, here.z + dz)
	if not _rec_spot_ok(spot, need_sky, now):
		return Vector3i.MAX
	return spot


func _rec_spot_ok(spot: Vector3i, need_sky: bool, now: int) -> bool:
	var record: Dictionary = _rec_blacklist.get(spot, {})
	if not record.is_empty() and (
		now - int(record.get("at", 0)) < _colony.retry_delay_msec(record)
	):
		return false
	if not _is_standable(spot):
		return false
	if not Colony.in_area(allowed_area, spot):
		return false
	return not need_sky or _colony.sees_sky(spot)


## The nearest unit up for a chat — idle or already relaxing, within
## [constant REC_SOCIAL_SEEK] metres. Working, sleeping and walking
## units are busy.
func _rec_partner_candidate() -> Unit:
	var best: Unit = null
	var best_sq := REC_SOCIAL_SEEK * REC_SOCIAL_SEEK
	for unit in _colony.units:
		if (
			unit == self
			or unit == null
			or (
				unit.state != State.IDLE
				and unit.state != State.RECREATING
			)
			or not Colony.in_area(allowed_area, unit._standing_voxel())
		):
			continue
		var sq := global_position.distance_squared_to(unit.global_position)
		if sq < best_sq:
			best_sq = sq
			best = unit
	return best


## Everything available right now, weighted by power and freshness —
## tolerance suppresses a kind the unit just did. Returns {} when
## nothing's on (a buried unit with no partner can still always pray).
func _pick_recreation() -> Dictionary:
	var options: Array[Dictionary] = []
	var here := _standing_voxel()
	for building in _colony.free_rec_buildings():
		if not Colony.in_area(allowed_area, building.voxel):
			continue
		var spec: Dictionary = BlockRegistry.REC_SPECS.get(
			building.spec, {}
		)
		options.append({
			&"id": building.spec, &"at": building.voxel,
			&"building": building, &"weight": _rec_weight_of(spec),
		})
	var partner := _rec_partner_candidate()
	if partner != null:
		options.append({
			&"id": &"social", &"at": partner._standing_voxel(),
			&"partner": partner,
			&"weight": _rec_weight_of(REC_ACTIVITIES[&"social"]),
		})
	var sky := _rec_spot(true)
	if sky != Vector3i.MAX:
		options.append({
			&"id": &"skygaze", &"at": sky,
			&"weight": _rec_weight_of(REC_ACTIVITIES[&"skygaze"]),
		})
	var stroll := _rec_spot(false, 6, 22, false)
	if stroll != Vector3i.MAX:
		options.append({
			&"id": &"walk", &"at": stroll,
			&"weight": _rec_weight_of(REC_ACTIVITIES[&"walk"]),
		})
	for id: StringName in [&"pray", &"meditate", &"contemplate"]:
		options.append({
			&"id": id, &"at": here,
			&"weight": _rec_weight_of(REC_ACTIVITIES[id]),
		})
	var total := 0.0
	for option in options:
		total += float(option[&"weight"])
	if total <= 0.0:
		return {}
	var roll := randf() * total
	for option in options:
		roll -= float(option[&"weight"])
		if roll <= 0.0:
			return option
	return options.back()


## Resolve one activity to its destination — the partner's cell, a sky
## or stroll spot, the building's voxel, or right where the unit stands
## for pray and meditate. {} when the activity isn't available.
func _resolve_recreation(activity: StringName) -> Dictionary:
	var here := _standing_voxel()
	if BlockRegistry.REC_SPECS.has(activity):
		var best: Building = null
		var best_sq := INF
		for building in _colony.free_rec_buildings():
			if (
				building.spec != activity
				or not Colony.in_area(allowed_area, building.voxel)
			):
				continue
			var sq := Vector3(building.voxel - here).length_squared()
			if sq < best_sq:
				best_sq = sq
				best = building
		if best == null:
			return {}
		return {&"id": activity, &"at": best.voxel, &"building": best}
	match activity:
		&"social":
			var partner := _rec_partner_candidate()
			if partner == null:
				return {}
			return {
				&"id": activity, &"at": partner._standing_voxel(),
				&"partner": partner,
			}
		&"skygaze":
			var spot := _rec_spot(true)
			if spot == Vector3i.MAX:
				return {}
			return {&"id": activity, &"at": spot}
		&"walk":
			var spot := _rec_spot(false, 6, 22, false)
			if spot == Vector3i.MAX:
				return {}
			return {&"id": activity, &"at": spot}
		_:
			if bool(_rec_spec(activity).get(&"moves", false)):
				var stroll := _rec_spot(false, 6, 22, false)
				if stroll == Vector3i.MAX:
					return {}
				return {&"id": activity, &"at": stroll}
			return {&"id": activity, &"at": here}


## Bored at idle: pick a recreation, claim it (a building's `occupant`
## or the social partner) and go. The job is self-issued — never on the
## board — so a give-up just blacklists the spot.
func _start_recreation(force: StringName = &"") -> void:
	var pick := (
		_resolve_recreation(force)
		if force != &""
		else _pick_recreation()
	)
	if pick.is_empty():
		return
	var activity: StringName = pick[&"id"]
	var target: Vector3i = pick[&"at"]
	job = ColonyJob.new(ColonyJob.Type.RECREATE, target)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	job.rec_activity = activity
	_rec_left = float(_rec_spec(activity).get(&"seconds", 16.0))
	_session_gain = 0.0
	_rec_building = pick.get(&"building")
	if _rec_building != null:
		_rec_building.occupant = self
	_rec_partner = pick.get(&"partner")
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = target
	_note("recreation <- %s" % activity)
	if _repath_to_job():
		state = State.MOVING
	else:
		# The spot can't be reached — remember it and stay bored; the
		# next seek tries somewhere else.
		_blacklist_rec(target)
		_release_recreation()
		job = null
		_job_search_cooldown = 2.0


## Arrived at the recreation spot — re-check that it's still a spot
## (partner wandered, building torn down, sky roofed) and settle in.
func _begin_recreating() -> void:
	if job == null:
		state = State.IDLE
		return
	if job.rec_activity == &"social" and not _social_ok():
		_end_recreation("partner left")
		return
	if _rec_building != null and (
		_colony.building_at(job.voxel_position) != _rec_building
		or _rec_building.occupant != self
	):
		_end_recreation("building gone")
		return
	if _rec_needs_sky() and not _colony.sees_sky(job.voxel_position):
		_end_recreation("no sky overhead")
		return
	state = State.RECREATING


## True while the social partner is still worth talking to — nearby and
## not busy. A partner mid-recreation counts: two colonists relax
## together.
func _social_ok() -> bool:
	return (
		_rec_partner != null
		and is_instance_valid(_rec_partner)
		and (
			_rec_partner.state == State.IDLE
			or _rec_partner.state == State.RECREATING
		)
		and _rec_partner.global_position.distance_to(global_position)
			<= REC_SOCIAL_RANGE
	)


## Whether the running activity wants open sky — skygazing's own flag
## or a building spec's (the telescope).
func _rec_needs_sky() -> bool:
	if job == null:
		return false
	return bool(_rec_spec(job.rec_activity).get(&"sky", false))


## One recreation tick: fill the bar at the activity's rate through
## tolerance, share the gain with a chat partner at half rate, and stop
## when the session's spent, the bar's full, or urgent needs break it.
func _tick_recreating(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	if job == null or job.type != ColonyJob.Type.RECREATE:
		state = State.IDLE
		return
	if (
		not _in_break
		and (
			hunger <= _desperation_line()
			or energy <= rest_seek * 0.5
		)
	):
		_end_recreation("interrupted by a need")
		return
	if job.rec_activity == &"social":
		if not _social_ok():
			_end_recreation("partner left")
			return
	elif _rec_building != null:
		if (
			_colony.building_at(job.voxel_position) != _rec_building
			or _rec_building.occupant != self
		):
			_end_recreation("building gone")
			return
	if _rec_needs_sky() and not _colony.sees_sky(job.voxel_position):
		_end_recreation("sky roofed")
		return
	if not _can_clear_from(global_position, job.voxel_position):
		# Shoved or drifted out of the spot — walk back to it.
		state = State.MOVING
		return
	var spec := _rec_spec(job.rec_activity)
	var kind: StringName = spec.get(&"kind", &"solitary")
	_session_gain += _rec_gain(
		kind, _rec_rate(job.rec_activity) * _rec_quality_mult() * delta
	)
	if job.rec_activity == &"social" and _rec_partner != null:
		_rec_partner._rec_gain(kind, _rec_rate(job.rec_activity) * delta * 0.5)
	_rec_left -= delta
	if _rec_left <= 0.0 or recreation >= 1.0:
		_end_recreation()


## A recreation leg's waypoint ran out — another leg while the session
## has time left, else the outing's done.
func _rec_walk_leg() -> void:
	var power := float(_rec_spec(job.rec_activity).get(&"power", 1.0))
	if _rec_left <= 0.0 or (power > 0.0 and recreation >= 1.0):
		_end_recreation()
		return
	var next := _rec_spot(false, 6, 22, false)
	if next == Vector3i.MAX:
		_end_recreation("walked out")
		return
	_goal_voxel = next
	job.voxel_position = next
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if not _repath_to_job():
		_end_recreation("walked out")


## Release the activity's claims — the building's seat, the chat
## partner — without touching the job itself.
func _release_recreation() -> void:
	if _rec_building != null:
		if _rec_building.occupant == self:
			_rec_building.occupant = null
		_rec_building = null
	_rec_partner = null
	_rec_left = 0.0


## The session's over — gain keeps whatever accrued, the spot's claims
## free up, and the unit drops back to idle for the next decision. A
## session that actually paid out leaves a mood thought behind — a
## social one stamps both partners' last-social clock.
func _end_recreation(reason := "done") -> void:
	var activity: StringName = (
		job.rec_activity if job != null else &""
	)
	var partner := _rec_partner
	var gained := _session_gain
	if job != null:
		_note("recreation %s: %s" % [job.rec_activity, reason])
	_release_recreation()
	_session_gain = 0.0
	job = null
	state = State.IDLE
	if activity == &"contemplate" and gained > 0.0:
		_contemplate_insight()
	if gained > 0.0:
		add_thought(&"had_fun")
		if activity == &"social":
			add_thought(&"socialized")
			_last_social_at = _colony.game_msec()
			if partner != null:
				partner.add_thought(&"socialized")
				partner._last_social_at = _colony.game_msec()
	if _in_break:
		_end_break()


## A finished contemplation's small roll for insight: on a hit the unit
## gains a level-1 worth of XP in a skill drawn at random — possibly
## one nobody in the colony holds. That's how a colony bootstraps the
## gated crafts before manuals and trade exist. Mood, facets and the
## thinker's existing skills will later shape both the odds and the
## pool; for now every skill is a candidate.
func _contemplate_insight() -> void:
	if randf() >= CONTEMPLATE_INSIGHT_CHANCE:
		return
	var skill: int = ColonyJob.Skill.values()[randi() % ColonyJob.Skill.size()]
	gain_skill_xp(skill, SKILL_XP_BASE)
	_note("insight: %s" % ColonyJob.SKILL_NAMES.get(skill, "?"))


## A facet value, 0–100 — 50 when the facet was never rolled.
func facet(facet_name: StringName) -> int:
	return int(facets.get(facet_name, 50))


## Behavioural multiplier from a facet — average is ×1.0 and the ends
## of the scale run ×0.5 to ×1.5.
func _facet_scale(facet_name: StringName) -> float:
	return 0.5 + facet(facet_name) / 100.0


## Whether the spec's facet gate lets this unit have the thought at
## all — `facet_min`/`facet_max` read the spec's `facet` (or an
## explicit `gate_facet`) against the unit's value.
func _thought_gate(spec: Dictionary) -> bool:
	var gate_facet: StringName = spec.get(
		&"gate_facet", spec.get(&"facet", &"")
	)
	if gate_facet == &"":
		return true
	var value := facet(gate_facet)
	if spec.has(&"facet_min") and value < int(spec[&"facet_min"]):
		return false
	if spec.has(&"facet_max") and value > int(spec[&"facet_max"]):
		return false
	return true


## One stack's effective offset — the spec offset scaled by its
## intensity facet (flat when the spec names none).
func _thought_offset(id: StringName) -> float:
	var spec: Dictionary = THOUGHTS.get(id, {})
	var offset := float(spec.get(&"offset", 0.0))
	var mod_facet: StringName = spec.get(&"facet", &"")
	if mod_facet == &"":
		return offset
	return offset * _facet_scale(mod_facet)


## Record a stored thought — a fresh stack expiring `days` from now,
## capped at the spec's stack limit (oldest stack drops first).
## Gated thoughts silently don't apply to the wrong personality.
func add_thought(id: StringName) -> void:
	var spec: Dictionary = THOUGHTS.get(id, {})
	if spec.is_empty() or not spec.has(&"days"):
		return
	if not _thought_gate(spec):
		return
	var stacks: Array = _thoughts.get(id, []) as Array
	_prune_stacks(stacks)
	stacks.append(
		_colony.game_msec()
		+ int(float(spec[&"days"]) * _colony.day_length() * 1000.0)
	)
	while stacks.size() > int(spec.get(&"stack", 1)):
		stacks.pop_front()
	_thoughts[id] = stacks


func _prune_stacks(stacks: Array) -> void:
	var now := _colony.game_msec()
	var i := 0
	while i < stacks.size():
		if int(stacks[i]) <= now:
			stacks.remove_at(i)
		else:
			i += 1


## Is a state-driven thought on right now? These live in the tick, not
## the store — starving while the stomach's empty, bored while
## recreation sits at zero, lonely when a gregarious unit hasn't
## socialized in two days.
func _state_thought_on(id: StringName) -> bool:
	match id:
		&"starving":
			return hunger <= 0.0
		&"bored_stiff":
			return recreation <= 0.0
		&"craves_company":
			return (
				_colony.game_msec() - _last_social_at
				> int(2.0 * _colony.day_length() * 1000.0)
			)
		&"in_pain":
			return health < PATIENT_HEALTH or bleeding()
		&"in_medical_care":
			return _rest_bed != null and _rest_bed.medical
		&"drab_surroundings":
			return beauty < Colony.BEAUTY_DRAB
		&"pleasant_surroundings":
			return (
				beauty >= Colony.BEAUTY_PLEASANT
				and beauty < Colony.BEAUTY_IMPRESSIVE
			)
		&"impressive_surroundings":
			return beauty >= Colony.BEAUTY_IMPRESSIVE
	return false


## The bar's destination: base mood plus the colony's expectations
## cushion and every live thought's offset — stored stacks count each,
## state thoughts count once.
func mood_target() -> float:
	var value := MOOD_BASE + (
		_colony.expectations_bonus() if _colony != null else 0.0
	)
	for id: StringName in _thoughts:
		value += _thought_offset(id) * (_thoughts[id] as Array).size()
	for id: StringName in THOUGHTS:
		var spec: Dictionary = THOUGHTS[id]
		if spec.has(&"days") or not _thought_gate(spec):
			continue
		if _state_thought_on(id):
			value += _thought_offset(id)
	return clampf(value, 0.0, 1.0)


## One mood tick: expire dead stacks, drift the bar toward the target
## and roll the break while the unit's under the line. Sleep freezes
## the bar and the risk — RimWorld's rule.
func _tick_mood(delta: float) -> void:
	if _last_social_at < 0:
		_last_social_at = _colony.game_msec()
	var dead: Array = []
	for id: StringName in _thoughts:
		var stacks := _thoughts[id] as Array
		_prune_stacks(stacks)
		if stacks.is_empty():
			dead.append(id)
	for id in dead:
		_thoughts.erase(id)
	if state == State.SLEEPING:
		return
	var target := mood_target()
	var rate := MOOD_RISE if target > mood else MOOD_FALL
	mood = move_toward(
		mood, target, rate * 24.0 * delta / _colony.day_length()
	)
	if _in_break or mood >= _break_threshold():
		return
	if randf() < delta / _break_mtb_seconds():
		_start_break()


## Minor break threshold — 35% shifted ±10 points by
## stress_vulnerability, capped to RimWorld's 1–50% band.
func _break_threshold() -> float:
	return clampf(
		BREAK_MINOR + (facet(&"stress_vulnerability") - 50) * 0.002,
		0.01, 0.5,
	)


## Self-care mood lines — a unit under the therapy line goes to
## recreation even when its fun bar isn't low (the mood, not the need,
## is what needs treating), and the decompress latch holds until the
## bar clears the release margin so it doesn't break off mid-recovery
## for one shift's work.
func _mood_therapy_line() -> float:
	return _break_threshold() + 0.10


func _mood_release_line() -> float:
	return _break_threshold() + 0.30


## Mean seconds between breaks at the current mood tier — RimWorld's
## MTB table (4 / 0.8 / 0.5 days for minor/major/extreme) against the
## day length, times the debug scale.
func _break_mtb_seconds() -> float:
	var major := _break_threshold() * 4.0 / 7.0
	var days := BREAK_MTB_MINOR
	if mood < major / 4.0:
		days = BREAK_MTB_EXTREME
	elif mood < major:
		days = BREAK_MTB_MAJOR
	return maxf(days * _colony.day_length() * break_mtb_scale, 0.001)


## Mood below the threshold — the unit snaps. Minor moods binge on
## food when there's something edible in reach, or wander miserably;
## major and extreme spirals daze. Aggressive breaks need combat and
## arrest, which don't exist yet.
func _start_break() -> void:
	# A mental break ends any draft — the unit is past taking orders.
	set_drafted(false)
	var tier := (
		"extreme" if mood < _break_threshold() * 4.0 / 7.0 / 4.0
		else "major" if mood < _break_threshold() * 4.0 / 7.0
		else "minor"
	)
	_note(
		"%s mental break at %d%% mood" % [tier, int(mood * 100.0)]
	)
	abandon_job()
	_in_break = true
	if (
		tier == "minor"
		and hunger < 0.9
		and _colony.nearest_food_pile(
			_standing_voxel(), _food_blacklist, allowed_area
		) != Vector3i.MAX
	):
		_start_binge()
		if state != State.IDLE:
			return
	_start_recreation(&"daze")
	if state == State.IDLE:
		# Nowhere to wander — the break fizzles with mood unchanged.
		_in_break = false


## A minor-break food binge — an EAT job like a hungry unit's, but
## self-issued and driven past the seek line by `_meal_target`.
func _start_binge() -> void:
	var spot := _colony.nearest_food_pile(
		_standing_voxel(), _food_blacklist, allowed_area
	)
	if spot == Vector3i.MAX:
		return
	job = ColonyJob.new(ColonyJob.Type.EAT, spot)
	job.desperate = true
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_note("food binge " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = spot
	if _repath_to_job():
		state = State.MOVING
	else:
		_blacklist_food(spot)
		job = null


## The break's over — the catharsis thought cushions the aftermath so
## a marginal unit doesn't chain-break on the same stack of grief.
func _end_break() -> void:
	if not _in_break:
		return
	_in_break = false
	add_thought(&"catharsis")
	_note("the break passes")


## Bookkeeping when a meal ends — attach the food thought for what was
## actually eaten (a cooked meal comforts, raw food disappoints) and
## end a binge break if one was running.
func _finish_meal() -> void:
	if _meal_ate:
		add_thought(
			&"ate_cooked_meal" if _meal_cooked else &"ate_raw_food"
		)
		# The dining context lands with the meal — a table and a seat
		# within reach of the food pile count; hunched over a loose
		# pile on the ground is the complaint RimWorld owners know.
		var table := _colony.furniture_near(
			_meal_voxel, Building.Kind.TABLE, Colony.MEAL_AURA_RADIUS
		)
		var seat := _colony.furniture_near(
			_meal_voxel, Building.Kind.SEAT, Colony.MEAL_AURA_RADIUS
		)
		add_thought(
			&"ate_at_table" if table != null and seat != null
			else &"ate_without_table"
		)
	_meal_ate = false
	_meal_cooked = false
	_meal_voxel = Vector3i.MAX
	_end_break()


## At the food pile: a bite every BITE_SECONDS until full or the pile's
## food runs out. Bites are consumed where they stand — the pile shrinks
## by exactly what was eaten.
func _tick_eating(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var pile := _colony.item_pile_at(job.voxel_position)
	if _meal_voxel != job.voxel_position:
		# A new meal — reset what the mood will remember about it.
		_meal_voxel = job.voxel_position
		_meal_ate = false
		_meal_cooked = false
	if pile == null or hunger >= _meal_target():
		_finish_meal()
		job = null
		state = State.IDLE
		return
	if not _can_clear_from(global_position, job.voxel_position):
		# Drifted or shoved out of reach — walk back for another bite.
		state = State.MOVING
		return
	_eat_budget += delta
	var out_of_food := false
	while _eat_budget >= BITE_SECONDS and hunger < _meal_target():
		_eat_budget -= BITE_SECONDS
		var got := pile.take_up_to(
			BITE_CM3,
			func(item: DropItem) -> bool:
				return DropItem.is_food(item.material) and not item.forbidden
		)
		if got.is_empty():
			# The pile's edible part is gone — anything left isn't food.
			# A food-less pile won't answer the next seek, so ending the
			# meal here just sends a still-hungry unit to the next pile.
			out_of_food = true
			break
		for item in got:
			_meal_ate = true
			if item.material == BlockRegistry.Resource_.MEAL:
				_meal_cooked = true
			hunger = minf(hunger + item.nutrition_value(), 1.0)
		_colony.remove_pile_if_empty(job.voxel_position)
	if (
		hunger >= _meal_target()
		or out_of_food
		or _colony.item_pile_at(job.voxel_position) == null
	):
		_finish_meal()
		job = null
		state = State.IDLE


## Labour rate multiplier: a starving unit works at half speed —
## hunger bottoms out into a penalty, not a collapse — and skill in the
## current job's discipline speeds everything proportionally.
func _work_rate() -> float:
	var rate := 1.0
	if _colony.needs_enabled and hunger <= 0.0:
		rate *= STARVING_SPEED
	# Wrecked hands work slow — arm damage scales labour 60–100%.
	rate *= 0.6 + 0.4 * manipulation()
	if job != null:
		var skill: int = ColonyJob.SKILL_FOR.get(job.type, -1)
		if job.type == ColonyJob.Type.CRAFT and not Colony.recipe_of(job.recipe).is_empty():
			# A recipe may train a different discipline than the job
			# type's default — cooking is its own skill.
			skill = int(Colony.recipe_of(job.recipe).get("skill", skill))
		# Gated work runs at the gate's rating — an Electrician rewires
		# the generator fast, a novice never claims the bill at all.
		if job.required_skill >= 0:
			skill = job.required_skill
		rate *= skill_rate(skill)
	return rate


## Highest level whose cumulative XP requirement — X·L(L+1)/2 — has been
## met. Inverting that quadratic keeps level a pure function of XP, so
## no separate level counter can drift out of sync.
func skill_level(skill: int) -> int:
	var xp: float = skills.get(skill, 0.0)
	return floori((sqrt(1.0 + 8.0 * xp / SKILL_XP_BASE) - 1.0) / 2.0)


## Basic knowledge in [param skill] — level 1 — the gate the knowledge-
## bound crafts (charcoal, the smelts) check before a job may be claimed.
func knows(skill: int) -> bool:
	return skill >= 0 and skill_level(skill) >= 1


## The quality a craft lands with — normally distributed around the
## crafter's level in the recipe's discipline: mean level/10 + 0.25
## (0.25 at 0, 1.25 at 10, 2.25 at 20), standard deviation 0.25. A
## roll under zero is a botch — the craft fails outright.
func roll_craft_quality(skill: int) -> float:
	var level := skill_level(skill) if skill >= 0 else 0
	return randfn(level / 10.0 + 0.25, 0.25)


## A sub-zero quality roll ends the run in failure: no product, the
## escrowed inputs spill back to the floor, the bill requeues in the
## same hands — a fresh fetch, a fresh roll — and the crafter keeps
## half the lesson plus the memory of it.
func _botch_craft(recipe: Dictionary, craft_skill: int) -> void:
	var xp := float(recipe.get("xp", ColonyJob.XP_FOR.get(job.type, 0.0)))
	for item in job.components:
		_colony._drop_item(item, job.voxel_position)
	job.components.clear()
	job.delivered.clear()
	job.progress = 0.0
	if craft_skill >= 0:
		gain_skill_xp(craft_skill, xp * 0.5)
	add_thought(&"botched_craft")
	_note("botched " + _job_label())
	# Requeued in the same hands — pick the pieces up and start the
	# fetch over; the bill was never done and nobody else is blamed.
	_advance_craft_goal()


## Work-rate multiplier from skill — 2^(level / SKILL_DOUBLE_LEVELS):
## level 10 ≈ 2×, level 20 ≈ 4×. An unskilled type passes -1 → 1.0.
func skill_rate(skill: int) -> float:
	if skill < 0:
		return 1.0
	return pow(2.0, skill_level(skill) / SKILL_DOUBLE_LEVELS)


## XP the next level at [param level] still needs — X for 0→1, 2X for
## 1→2, 3X for 2→3.
static func skill_xp_next(level: int) -> float:
	return SKILL_XP_BASE * (level + 1)


## 0–1 progress through the current level — for the colonist panel's bar.
func skill_progress(skill: int) -> float:
	var level := skill_level(skill)
	var spent: float = skills.get(skill, 0.0) - SKILL_XP_BASE * level * (level + 1) / 2.0
	return clampf(spent / skill_xp_next(level), 0.0, 1.0)


## Award XP. The gain-rate hook is where attributes — aptitude, focus —
## will modulate learning speed once they exist.
func gain_skill_xp(skill: int, amount: float) -> void:
	if skill < 0:
		return
	skills[skill] = skills.get(skill, 0.0) + amount * skill_gain_rate(skill)


## Learning-speed multiplier — a flat 1.0 until attributes land.
func skill_gain_rate(_skill: int) -> float:
	return 1.0


func _tick_idle() -> void:
	# Combat outranks everything — a fight in progress (or a fresh
	# attacker from `_engage`) is the job now, drafted or not.
	if _target_valid(_combat_target):
		_start_fight()
		return
	_combat_target = null
	# Drafted units hold their post and watch for threats — they take no
	# board jobs and service no needs while the stance holds.
	if drafted:
		_tick_drafted()
		return
	if _job_search_cooldown > 0.0:
		return
	_job_search_cooldown = 0.5
	# A tool not needed right now goes to the belt rather than riding a
	# hand everywhere — holsters it can't take stay held.
	stow_tools()
	# A restricted unit outside its area walks home before anything else
	# — the same machinery `_hold_post` uses, aimed at the nearest in-
	# bounds cell. Needs are serviced once it's back inside.
	if (
		allowed_area != null
		and not allowed_area.cells.has(_standing_voxel())
	):
		var home := _colony.nearest_area_cell(_standing_voxel(), allowed_area)
		if home != Vector3i.MAX:
			job = ColonyJob.new(ColonyJob.Type.ORDER, home)
			job.desperate = true
			job.state = ColonyJob.State.ASSIGNED
			job.assignee = self
			_note("returning to area " + allowed_area.label)
			_stuck_elapsed = 0.0
			_best_goal_distance = INF
			_goal_voxel = home
			if _repath_to_job():
				state = State.MOVING
				return
			# Can't get back — keep working from where it stands.
			job = null
	if _colony.needs_enabled:
		if needs_medical_attention() and hunger > _desperation_line():
			# Wounded units seek the infirmary ahead of everything —
			# bleeding and open wounds don't wait for a nap. With no
			# medical bed free they keep working until care can reach
			# them; a starving patient leaves long enough to eat.
			_start_medical_rest()
			if state != State.IDLE:
				return
		# Colony alertness: while a patient waits for care nobody beds
		# down early or wanders off for fun — a tend left pending while
		# the colony sleeps is how people die. The floor lines still
		# hold: an exhausted or starving unit attends itself first.
		var emergency := _colony.care_pending()
		if energy <= rest_seek and not (
			emergency and energy > rest_seek * 0.5
		):
			_start_rest()
			return
		if hunger <= _food_seek():
			_start_eat()
			if state != State.IDLE:
				return
			if hunger <= _desperation_line():
				# No edible pile — self-forage rather than starve at work.
				_start_desperate_forage()
				if state != State.IDLE:
					return
			# No reachable food — keep working hungry. The work
			# penalty only bites at zero.
		# Mood therapy: a unit nearing its break line decompresses, and
		# the latch holds it there until the bar clears the release
		# margin, the fun bar tops out — or mood reaches its thought
		# ceiling and recreation has nothing left to give. A unit whose
		# thoughts cap it under the release line would binge forever
		# otherwise: emergent misery isn't fun-fixable.
		# Emergencies don't preempt it: a medic who snaps mid-tend
		# helps nobody.
		if _decompressing and (
			mood >= _mood_release_line()
			or mood >= mood_target()
			or recreation >= 1.0
		):
			_decompressing = false
			# Releasing still under the therapy line — fun bar topped
			# or the thought ceiling reached — spends the latch; only a
			# genuine release-margin clear leaves it free to re-arm.
			_decompress_spent = (
				recreation >= 1.0 or mood <= _mood_therapy_line()
			)
		elif _decompress_spent and (
			recreation <= _recreation_seek()
			or (
				mood <= _mood_therapy_line()
				and recreation <= REC_THERAPY_REFILL
				and mood_target() > mood
			)
		):
			# A critical mood re-arms therapy at the refill line — a
			# cycle short enough that `had_fun` stacks survive — but
			# only while the ceiling sits above the bar: no headroom
			# means the next session can't lift anything either.
			_decompress_spent = false
		elif (
			mood <= _mood_therapy_line() and recreation < 1.0
			and not _decompress_spent
		):
			_decompressing = true
		if (
			(recreation <= _recreation_seek() and not emergency)
			or _decompressing
		) and recreation < 1.0:
			_start_recreation()
			if state != State.IDLE:
				return
			# Nothing fun in reach — keep working bored (or bad).
	# Relieved units take no jobs — on leave they still self-manage
	# every need above, they just never reach for the board.
	if relieved:
		return
	job = _colony.claim_job(self)
	if job == null:
		if not _try_dress():
			_try_start_haul()
		return
	_note("claimed " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = job.voxel_position
	_fetching = false
	if job.type == ColonyJob.Type.BUILD and not _wall_full(job):
		# Nothing to deliver yet — head for the closest pile that has
		# what the recipe still needs.
		var next := _colony.nearest_wall_voxel(
			_standing_voxel(), job.material, _wall_need(job), allowed_area
		)
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.CRAFT:
		# Craft jobs fetch their inputs first — the goal starts at a pile.
		var next := _craft_fetch_voxel()
		if next == Vector3i.MAX:
			# No usable inputs anywhere — back on the board it goes.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.UNINSTALL:
		# The pack wants a sheet-material shell — a plank or a metal
		# sheet wraps the piece into its crate.
		var next := _uninstall_shell_voxel()
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.UNPACK:
		# Unpacking happens at the crate's pile — walk there.
		_goal_voxel = job.voxel_position
	elif job.type == ColonyJob.Type.FURNISH:
		# Migrated to CRAFT at load — a stray one goes back to the board.
		_give_up_on_job()
		return
	elif job.type == ColonyJob.Type.REFUEL:
		# Refuelling is fetch-and-feed: grab a load of fuel from the
		# best-scoring pile, carry it to the fire.
		var next := _colony.nearest_fuel_voxel(
			_standing_voxel(), {}, allowed_area
		)
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.SOW:
		# Sowing is fetch-and-plant: lift a seed packet of the field's
		# species, carry it to the cell.
		var next := _colony.nearest_seed_voxel(
			_standing_voxel(), job.species, allowed_area
		)
		if next == Vector3i.MAX:
			# The packet that opened this job is gone — suspend it and
			# let the farm scan revive it when a seed exists again.
			job.suspended = true
			if _colony.world.sim != null:
				_colony.world.sim.job_suspend(job.get_instance_id(), true)
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.FERTILIZE:
		# Fertilizing is fetch-and-spread: shovel loose compost from the
		# nearest pile that has it, carry it to the cell.
		var next := _colony.nearest_compost_voxel(
			_standing_voxel(), allowed_area
		)
		if next == Vector3i.MAX:
			# No compost anywhere — suspend like a seedless sow and let
			# the farm scan revive the job when rot pays out again.
			job.suspended = true
			if _colony.world.sim != null:
				_colony.world.sim.job_suspend(job.get_instance_id(), true)
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.HUNT:
		# The quarry is a live animal — the goal follows it; the chase
		# logic in _tick_moving repaths as it moves.
		if (
			job.animal == null
			or not is_instance_valid(job.animal)
			or job.animal.dead
		):
			_give_up_on_job()
			return
		_goal_voxel = Vector3i(job.animal.global_position.floor())
	elif job.type == ColonyJob.Type.BUTCHER:
		# Fetch-and-cut: lift a corpse the body can actually move, carry
		# it (or drag it) to the spot, work it there.
		var next := _colony.nearest_corpse_voxel(
			_standing_voxel(), _drag_kg(), allowed_area
		)
		if next == Vector3i.MAX:
			# Nothing within drag range anywhere — back on the board.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	elif job.type == ColonyJob.Type.TEND:
		# The doctor walks to the patient — with a medical-bed patient
		# and herb bundles in reach it detours to fetch one first.
		var patient: Unit = job.patient
		if not _patient_tendable(patient):
			_give_up_on_job()
			return
		if (
			_colony._patient_on_medical_bed(patient)
			and _carried_material(BlockRegistry.Resource_.MEDICINE) == null
		):
			var med := _colony.nearest_medicine_voxel(
				_standing_voxel(), allowed_area
			)
			if med != Vector3i.MAX:
				_fetching = true
				_goal_voxel = med
			else:
				_goal_voxel = Vector3i(patient.global_position.floor())
		else:
			_goal_voxel = Vector3i(patient.global_position.floor())
	elif job.type == ColonyJob.Type.RESCUE:
		var patient: Unit = job.patient
		if not _patient_rescuable(patient):
			_give_up_on_job()
			return
		_goal_voxel = Vector3i(patient.global_position.floor())
	elif job.type == ColonyJob.Type.TEACH:
		# The tutor walks to the student — the lesson's subject is picked
		# per tick by the widest skill gap, so a job needs no recipe leg.
		var student: Unit = job.patient
		if (
			student == null or not is_instance_valid(student)
			or student.dead
			or Colony.teachable_skill(self, student) < 0
		):
			_give_up_on_job()
			return
		_goal_voxel = Vector3i(student.global_position.floor())
	elif (
		job.type == ColonyJob.Type.MINE
		or job.type == ColonyJob.Type.CHOP
	):
		# Dig and fell want a tool in hand — fetch one when the unit
		# doesn't already carry something that qualifies. With none in
		# any pile the job goes back to the board like a starved build.
		var classes: Array = (
			Colony.required_tool(job, _world).get(&"classes", [])
		)
		if not classes.is_empty() and _tool_for(classes) == null:
			var next := _colony.nearest_tool_voxel(
				_standing_voxel(), classes, allowed_area
			)
			if next == Vector3i.MAX:
				_give_up_on_job()
				return
			_fetching = true
			_goal_voxel = next
	# A tool job keeps its iron in hand; everywhere else the unit
	# prefers the belt over a half-empty grip.
	if (
		job.type != ColonyJob.Type.MINE
		and job.type != ColonyJob.Type.CHOP
	):
		_stow_for_work()
	if _repath_to_job():
		state = State.MOVING
	else:
		_give_up_on_job()


func _tick_moving(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	# A moving activity's recreation IS the travel — the outing accrues
	# along the way and urgent needs can still cut it short. Zero-power
	# outings (a break's daze) spend `_rec_left` without paying out.
	var moves_spec: Dictionary = (
		_rec_spec(job.rec_activity)
		if job.type == ColonyJob.Type.RECREATE
		else {}
	)
	if bool(moves_spec.get(&"moves", false)):
		var power := float(moves_spec.get(&"power", 1.0))
		if power > 0.0:
			_session_gain += _rec_gain(
				moves_spec.get(&"kind", &"solitary"),
				_rec_rate(job.rec_activity) * delta
			)
		_rec_left -= delta
		if _rec_left <= 0.0 or (power > 0.0 and recreation >= 1.0):
			_end_recreation()
			return
		if not _in_break and (
			hunger <= _desperation_line() or energy <= rest_seek * 0.5
		):
			_end_recreation("interrupted by a need")
			return

	# A hunt's goal is a live animal — the chase retargets it whenever
	# the quarry crosses a cell boundary. An order's combat target chases
	# the same way.
	if job.animal != null:
		var quarry := job.animal
		if quarry == null or not is_instance_valid(quarry) or quarry.dead:
			# The colony marks a killed quarry's job done; anything else
			# (freed node, stale link) ends it here.
			if job.is_active():
				_give_up_on_job()
			return
		if (
			job.type == ColonyJob.Type.ORDER
			and global_position.distance_to(quarry.global_position)
				> ORDER_DISENGAGE
		):
			# Outraced — the fight's over, not a pursuit across the map.
			_combat_target = null
			_give_up_on_job()
			return
		var cell := Vector3i(quarry.global_position.floor())
		if cell != _goal_voxel:
			_goal_voxel = cell
			_stuck_elapsed = 0.0
			_best_goal_distance = INF
			if _repath_cooldown <= 0.0:
				_repath_to_job()

	# A tend, rescue or lesson walks to a person — the goal follows them
	# until the pickup/grab happens (a downed patient doesn't move, but
	# a wounded unit or a working student can wander off mid-chase).
	if (
		not _fetching
		and _carried_unit == null
		and (
			job.type == ColonyJob.Type.TEND
			or job.type == ColonyJob.Type.RESCUE
			or job.type == ColonyJob.Type.TEACH
		)
	):
		var patient: Unit = job.patient
		if patient == null or not is_instance_valid(patient) or patient.dead:
			_give_up_on_job()
			return
		var cell := Vector3i(patient.global_position.floor())
		if cell != _goal_voxel:
			_goal_voxel = cell
			_stuck_elapsed = 0.0
			_best_goal_distance = INF
			if _repath_cooldown <= 0.0:
				_repath_to_job()

	if _goal_in_reach():
		_path.clear()
		if _detour != Vector3i.MAX:
			_detour_arrived()
		elif bool(moves_spec.get(&"moves", false)):
			# A waypoint's just a leg — the outing picks another while
			# the session has time left.
			_rec_walk_leg()
		else:
			state = State.WORKING
		return

	# Watchdog: no meaningful progress toward the site for too long means
	# the path is physically blocked — drop the assignment for someone else.
	var goal_distance := global_position.distance_to(
		Vector3(_goal_voxel) + Vector3(0.5, 0.5, 0.5)
	)
	if goal_distance < _best_goal_distance - STUCK_PROGRESS:
		_best_goal_distance = goal_distance
		_stuck_elapsed = 0.0
	else:
		_stuck_elapsed += delta
		if _stuck_elapsed > stuck_timeout:
			if _detour != Vector3i.MAX:
				_fail_detour()
			else:
				_give_up_on_job()
			return

	if _path_index >= _path.size():
		if _repath_cooldown > 0.0:
			return
		if not _repath_to_job():
			if _detour != Vector3i.MAX:
				_fail_detour()
			else:
				_give_up_on_job()
		return

	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	var waypoint_cell := Vector3i(waypoint.floor())
	# A closed door costs its swing time: the unit pauses at the
	# threshold while it opens, walks through, and the door shuts
	# itself behind them — the pause *is* the opening.
	if (
		_door_paid != Vector3i.MAX
		and _standing_voxel() == _door_paid
	):
		# Through it — the next approach pays the swing again.
		_door_paid = Vector3i.MAX
	var door := _colony.door_at(waypoint_cell)
	if (
		door != null
		and waypoint_cell != _standing_voxel()
		and waypoint_cell != _door_paid
		and flat_distance < 1.6
	):
		_door_wait += delta
		velocity.x = 0.0
		velocity.z = 0.0
		if _door_wait < DOOR_OPEN_SECONDS:
			return
		_door_wait = 0.0
		_door_paid = waypoint_cell
		door.pass_count += 1
	else:
		_door_wait = 0.0
	# Arrival must cover this tick's travel: at high time_scale a single
	# step can carry past the waypoint without ever entering a small
	# radius — the unit would orbit the point until the watchdog fires.
	if flat_distance < maxf(0.35, move_speed * delta):
		# Straight up or down in the column — a ladder edge. A hop inside
		# the cell lifts the feet onto the rung's top surface; sinking at
		# climb_speed descends it under control. A vertical waypoint with
		# no ladder is a step-up marker: skip it — the horizontal push
		# that follows trips the jump on wall contact.
		var standing := _standing_voxel()
		if waypoint_cell.y > standing.y:
			if _colony.ladder_at(standing) or _colony.ladder_at(waypoint_cell):
				if _grounded:
					_want_jump = true
				_steer_toward_column(waypoint_cell)
				return
		elif (
			waypoint_cell.y < standing.y
			and _colony.ladder_at(waypoint_cell)
		):
			_want_descend = true
			_steer_toward_column(waypoint_cell)
			return
		_path_index += 1
		return

	# A packed item pile in the way (the astar can't see those): once close
	# enough to reach it, haul it to a stockpile when one has room —
	# otherwise shove its contents into neighbouring voxels.
	if flat_distance < 1.6:
		for cell in [waypoint_cell, waypoint_cell + Vector3i.UP]:
			if not _world.is_solid(cell) and _colony.is_packed(cell):
				if _detour == Vector3i.MAX and _start_detour(cell):
					break
				if cell != _detour:
					_colony.shove_pile(cell)

	# Wading through a mound's slope or a pile's clutter costs stride —
	# the cell being left and the one being entered both count.
	var crawl := minf(
		_colony.traversal_mult(waypoint_cell),
		_colony.traversal_mult(_standing_voxel())
	)
	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	velocity.x = direction.x * _move_speed() * crawl
	velocity.z = direction.z * _move_speed() * crawl
	if _grounded and (to_waypoint.y > 0.6 or _blocked_horiz):
		_want_jump = true


## Eases the capsule onto [param cell]'s centre column — keeps a climb
## or descent lined up with the rung so the foot samples stay over the
## ladder while the unit rises or sinks.
func _steer_toward_column(cell: Vector3i) -> void:
	var inward := Vector3(cell) + Vector3(0.5, 0.0, 0.5) - global_position
	velocity.x = inward.x * move_speed
	velocity.z = inward.z * move_speed


func _tick_working(delta: float) -> void:
	if job == null or not job.is_active():
		abandon_job()
		return

	velocity.x = 0.0
	velocity.z = 0.0

	if job.type == ColonyJob.Type.CLEAR:
		_tick_clearing(delta)
		return
	if job.type == ColonyJob.Type.BUILD:
		_tick_building(delta)
		return
	if job.type == ColonyJob.Type.HAUL:
		_tick_hauling(delta)
		return
	if job.type == ColonyJob.Type.DRESS:
		_tick_dress(delta)
		return
	if job.type == ColonyJob.Type.CHOP:
		_tick_chopping(delta)
		return
	if job.type == ColonyJob.Type.CRAFT:
		_tick_crafting(delta)
		return
	if job.type == ColonyJob.Type.UNINSTALL:
		_tick_uninstalling(delta)
		return
	if job.type == ColonyJob.Type.UNPACK:
		_tick_unpacking(delta)
		return
	if job.type == ColonyJob.Type.FURNISH:
		# Legacy saves convert these to CRAFT at load; a stray one just
		# goes back to the board rather than hanging the unit.
		_give_up_on_job()
		return
	if job.type == ColonyJob.Type.REST:
		# Arrived at the bed — lie down.
		_rest_quality = RestQuality.NORMAL
		state = State.SLEEPING
		return
	if job.type == ColonyJob.Type.EAT:
		# Arrived at the food pile — tuck in.
		state = State.EATING
		return
	if job.type == ColonyJob.Type.FORAGE:
		_tick_foraging(delta)
		return
	if job.type == ColonyJob.Type.SOW:
		_tick_sowing(delta)
		return
	if job.type == ColonyJob.Type.FERTILIZE:
		_tick_fertilizing(delta)
		return
	if job.type == ColonyJob.Type.DECONSTRUCT:
		if job.face_dir != Vector3i.ZERO:
			_tick_stripping(delta)
		else:
			_tick_deconstructing(delta)
		return
	if job.type == ColonyJob.Type.REFUEL:
		_tick_refueling(delta)
		return
	if job.type == ColonyJob.Type.RECREATE:
		# Arrived at the recreation spot — settle in.
		_begin_recreating()
		return
	if job.type == ColonyJob.Type.HUNT:
		_tick_hunting(delta)
		return
	if job.type == ColonyJob.Type.BUTCHER:
		_tick_butcher(delta)
		return
	if job.type == ColonyJob.Type.TEND:
		_tick_tending(delta)
		return
	if job.type == ColonyJob.Type.RESCUE:
		_tick_rescuing(delta)
		return
	if job.type == ColonyJob.Type.ORDER:
		_tick_order(delta)
		return
	if job.type == ColonyJob.Type.BURN:
		_tick_burning(delta)
		return
	if job.type == ColonyJob.Type.TEACH:
		_tick_teaching(delta)
		return
	if job.type == ColonyJob.Type.REPAIR:
		_tick_repairing(delta)
		return
	if job.type == ColonyJob.Type.FIREFIGHT:
		_tick_firefighting(delta)
		return

	if _fetching:
		_tick_tool_fetch(delta)
		return
	if not _can_mine(job.voxel_position):
		state = State.MOVING
		return

	var block_id := _world.get_block(job.voxel_position)
	if not BlockRegistry.is_solid(block_id):
		_colony.complete_job(job, block_id)
		abandon_job()
		return

	var req := Colony.required_tool(job, _world)
	var tool := _work_tool(req[&"classes"])
	if tool == null:
		_redirect_tool_fetch(req[&"classes"])
		return
	var progress := (
		mining_speed * delta * _work_rate()
		* DropItem.tool_use_speed(tool, req[&"use"])
	)
	job.progress += progress
	_wear_tool(tool, progress)
	if job.progress < BlockRegistry.hardness(block_id):
		return

	var mined := _world.mine(job.voxel_position)
	if mined == BlockRegistry.Block.AIR:
		# Area unloaded under us: put the job back on the board.
		_colony.release_job(job)
		abandon_job()
		return
	_colony.complete_job(job, mined)
	job = null
	state = State.IDLE


## Chopping work: the unit works the tree's root voxel — the reach rule
## follows whether the root is solid (a trunk) or not (a sapling) — and
## once the summed hardness of the whole tree is met, it all comes down
## at once as drops.
func _tick_chopping(delta: float) -> void:
	if _fetching:
		_tick_tool_fetch(delta)
		return
	var root := job.voxel_position
	var block_id := _world.get_block(root)
	if not _can_reach_from(global_position, root, BlockRegistry.is_solid(block_id)):
		state = State.MOVING
		return
	var work := _colony.forest.tree_work(root)
	if work <= 0.0:
		# The tree is gone — felled while the unit was walking over.
		_colony.complete_chop(job)
		job = null
		state = State.IDLE
		return
	var tool := _work_tool([&"axe"])
	if tool == null:
		_redirect_tool_fetch([&"axe"])
		return
	var progress := (
		mining_speed * delta * _work_rate()
		* DropItem.tool_use_speed(tool, &"chop")
	)
	job.progress += progress
	_wear_tool(tool, progress)
	if job.progress < work:
		return
	_colony.fell_tree(job)
	job = null
	state = State.IDLE


## Craft work: fetch the recipe's inputs from the nearest piles that have
## them — as many trips as the carry load takes — deliver each load into
## the job's escrow at the spot, then work the order. The inputs are only
## consumed when the order finishes, so a cancelled craft puts them back
## into the world intact.
func _tick_crafting(delta: float) -> void:
	if _delivering_craft:
		_tick_craft_deliver()
		return
	if _fetching:
		_tick_craft_fetch(delta)
		return
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	# Escrow whatever the unit is carrying that the recipe still needs —
	# a rejected-material item of the right form doesn't count and is
	# kept back to be set down with the strays. Loose material splits
	# down to exactly what's missing, like the wall delivery does.
	var kept: Array[DropItem] = []
	for item in _carried:
		# A crate matching the furniture bill escrows whole — its packed
		# contents ARE the building's components, so it can't split or be
		# remade into a copy the way loose material can.
		if item.form == DropItem.Form.CRATE and _craft_crate_admits(item):
			job.components.append(item)
			continue
		var want := _craft_need(_craft_slot(item.form))
		# A material-keyed loose input (smelting's ore and charcoal are
		# both LOOSE) counts against its own tally, not the form's.
		var loose_keyed := (
			item.form == DropItem.Form.LOOSE
			and _craft_loose_wants().has(item.material)
		)
		if loose_keyed:
			want = _craft_loose_need(item.material)
		var part := item.volume
		if item.form == DropItem.Form.LOOSE and want < part:
			part = want
		elif part > want:
			# A solid item that won't fit its slot can't join the escrow.
			part = 0
		if (
			part <= 0
			or not _craft_admits(item)
			or (job.order != null and not job.order.admits_material(item.material))
		):
			kept.append(item)
			continue
		# Solid substitutes tally under the slot they fill — the sheets
		# that paid a plank want count as plank delivered.
		var dkey: int = (
			DELIVERED_MATERIAL_OFF + int(item.material)
			if loose_keyed else _craft_slot(item.form)
		)
		job.delivered[dkey] = (
			int(job.delivered.get(dkey, 0)) + part
		)
		var escrowed := DropItem.new(item.material, item.form, part)
		escrowed.species = item.species
		# The item's own quality and nutrition ride the escrow — a
		# studied specimen comes back the thing it was, and a bed kit
		# keeps the craft roll its furnish reads. A garment's spec and
		# wear ride too — the repair bill reads the wear off this copy.
		escrowed.quality = item.quality
		escrowed.nutrition = item.nutrition
		escrowed.spec = item.spec
		escrowed.wear = item.wear
		job.components.append(escrowed)
		if (
			job.repair_loose != null and job.repair_loose.is_empty()
			and escrowed.form == DropItem.Form.GARMENT
		):
			# The garment's arrived — its wear sets the material bill.
			job.repair_loose = Colony.repair_loose_for(escrowed)
		elif (
			job.repair_loose != null and job.repair_loose.is_empty()
			and escrowed.form == DropItem.Form.TOOL
		):
			# Same for a worn tool — its wear prices the metal.
			job.repair_loose = Colony.tool_repair_loose_for(escrowed)
		if job.material == BlockRegistry.Resource_.NONE:
			job.material = item.material
		item.volume -= part
		if item.volume > 0:
			kept.append(item)
	_carried = kept
	if _craft_needs():
		# More inputs outstanding — back to the piles.
		_advance_craft_goal()
		return
	var site := _colony.building_at(job.voxel_position)
	if site != null and site.uses_fuel() and not site.lit():
		# A cold fire suspends the bill — the escrowed inputs stay put
		# and the unit waits; work resumes the moment it's fed again.
		# The toolmaker's forge gates the same way: no fuel, no work.
		return
	# Multi-site recipes run at the rate their `sites` table gives the
	# worksite kind under the job — sheet metal and wire crawl at a
	# bare crafting spot and flow on the metalworker's bench.
	var recipe: Dictionary = Colony.recipe_of(job.recipe)
	var site_rate := Colony.recipe_site_rate(
		recipe,
		site.kind if site != null else Building.Kind.WORKSITE
	)
	if site != null and site.kind == Building.Kind.TOOLMAKER:
		# The forge burns while it's worked — a second of fuel per
		# second of attention, so a cold bench costs nothing to keep.
		site.fuel = maxf(0.0, site.fuel - delta)
	job.progress += delta * _work_rate() * site_rate
	if job.progress < crafting_seconds:
		return
	# A study run ends without products or a quality roll: the
	# specimen goes back — or, on a fumbled examination, comes apart
	# into its make materials. The scaled lesson lands on completion.
	if recipe.get(&"study", false):
		for item in _carried:
			_colony._drop_item(item, job.voxel_position)
		_carried.clear()
		_colony.complete_study(job)
		job = null
		state = State.IDLE
		return
	# Garment work ends the same way — no products, no quality roll:
	# the mended garment goes back out, or the salvaged one comes apart
	# into a share of its make materials. A tool repair leaves the
	# re-forged head at the bench the same way.
	if (
		recipe.get(&"repair", false)
		or recipe.get(&"salvage", false)
		or recipe.get(&"tool_repair", false)
	):
		for item in _carried:
			_colony._drop_item(item, job.voxel_position)
		_carried.clear()
		if recipe.get(&"repair", false):
			_colony.complete_garment_repair(job)
		elif recipe.get(&"salvage", false):
			_colony.complete_garment_salvage(job)
		else:
			_colony.complete_tool_repair(job)
		job = null
		state = State.IDLE
		return
	# The quality roll decides the run: the crafter's level in the
	# recipe's discipline sets the mean (0.25 at level 0, 1.25 at 10,
	# 2.25 at 20), a quarter-point spread either way. Under zero the
	# run botches outright — no product, the escrowed inputs spill
	# back to the floor, the bill requeues for a fresh fetch, and the
	# crafter wears the memory plus half the lesson.
	var craft_skill := int(
		recipe.get("skill", ColonyJob.SKILL_FOR.get(job.type, -1))
	)
	var quality := roll_craft_quality(craft_skill)
	if quality < 0.0:
		_botch_craft(recipe, craft_skill)
		return
	job.quality = quality
	# The order completes: the escrowed inputs are consumed, the outputs
	# drop at the spot or ride to the bill's chosen destination, and the
	# offcut remainder drops at the spot regardless.
	var consumed := 0
	var material := job.material
	var input_nutrition := 0.0
	for item in job.components:
		consumed += item.volume
		input_nutrition += item.nutrition_value()
	var produced := 0
	var products: Array[DropItem] = []
	# `output_material` overrides the input class — extract-seed presses
	# fruit into seed packets, not more fruit.
	var out_material: BlockRegistry.Resource_ = recipe.get(
		"output_material", material
	)
	for output: Dictionary in recipe["outputs"]:
		for form: int in output:
			for i in int(output[form]):
				var volume := DropItem.form_volume(form)
				produced += volume
				var product := DropItem.new(out_material, form, volume)
				# Every output carries the maker's roll — quality-
				# bearing goods read it, raw goods ignore it.
				product.quality = quality
				# A cooked output carries the ingredients' summed
				# nutrition times the recipe's bonus — the meal
				# remembers what went in.
				if recipe.has("nutrition_mult"):
					product.nutrition = (
						float(recipe["nutrition_mult"]) * input_nutrition
					)
				# A seed packet keeps the species of the fruit it was
				# pressed from — oak acorns yield oak seeds.
				if form == DropItem.Form.SEED:
					product.species = DropItem.FRUIT_SPECIES.get(
						material, &""
					)
				# A manufactured good takes the spec the recipe names —
				# the garment or tool kind it becomes.
				if (
					form == DropItem.Form.GARMENT
					or form == DropItem.Form.TOOL
				):
					product.spec = StringName(
						recipe.get(&"output_spec", &"")
					)
				products.append(product)
	# `output_loose` pours bulk goods by volume — the smelted metals and
	# a crushed boulder's gravel tail land as loose items, not counts.
	# `output_tailings` pours the batch's waste the same way; it is a
	# byproduct, though — never a counted or studyable product.
	for key: StringName in [&"output_loose", &"output_tailings"]:
		var loose_out: Dictionary = recipe.get(key, {})
		for material_out: int in loose_out:
			var volume := int(loose_out[material_out])
			if volume <= 0:
				continue
			produced += volume
			var loose_product := DropItem.new(
				material_out, DropItem.Form.LOOSE, volume
			)
			loose_product.quality = quality
			products.append(loose_product)
	# The inputs are gone — consumed into the outputs — so a cancelled
	# run past this point has no escrow to hand back. A builds recipe's
	# escrow instead becomes the building: complete_construct reads the
	# components, so they have to survive to there.
	if not recipe.has("builds"):
		job.components.clear()
	if bool(recipe.get("waste", false)) and consumed > produced:
		_colony._drop_item(
			DropItem.new(material, DropItem.Form.LOOSE, consumed - produced),
			job.voxel_position
		)
	# Whatever the unit still holds wasn't needed — set it down.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	var dest := _craft_deliver_target(products)
	if dest == Vector3i.MAX:
		# Drop-at-feet (or nowhere better to take it): the old path.
		for product in products:
			_colony._drop_item(product, job.voxel_position)
		_colony.complete_craft(job)
		job = null
		state = State.IDLE
		return
	# The worker carries the products itself — what won't fit the load
	# still drops at the spot for haulers.
	for product in products:
		if _carried_volume() + product.volume <= carry_cap():
			_carried.append(product)
		else:
			_colony._drop_item(product, job.voxel_position)
	_delivering_craft = true
	_goal_voxel = dest
	_path.clear()
	state = State.MOVING


## Craft delivery: the worker ferries the just-made products to the
## bill's destination — the best stockpile, or a cell of the named
## zone. Depositing the load finishes the run.
func _tick_craft_deliver() -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	for item in _carried:
		_colony._drop_item(item, _goal_voxel)
	_carried.clear()
	_delivering_craft = false
	_colony.complete_craft(job)
	job = null
	state = State.IDLE


## Where this run's products go — Vector3i.MAX when they drop at the
## spot (the default, or when no stockpile will take them). A named
## zone ships to its nearest qualifying cell; a zone that vanished
## falls back to the best stockpile like the plain mode.
func _craft_deliver_target(products: Array[DropItem]) -> Vector3i:
	var order := job.order
	if order == null or order.deliver_mode == WorksiteOrder.Deliver.FEET:
		return Vector3i.MAX
	var mats: Array = []
	var load := 0
	for product in products:
		mats.append(product.material)
		load += product.volume
	if (
		order.deliver_mode == WorksiteOrder.Deliver.ZONE
		and order.deliver_target != Vector3i.MAX
	):
		var zone := _colony.stockpile_at(order.deliver_target)
		if zone != null:
			var cell := _nearest_zone_cell(zone, load, mats)
			if cell != Vector3i.MAX:
				return cell
		# The named zone is gone or can't take the load — fall through
		# to the best-stockpile rule rather than dumping at the spot.
	return _colony.nearest_stockpile_with_room(
		_standing_voxel(), load, {}, mats, allowed_area
	)


## The nearest cell of [param zone] with room for [param load] that
## admits all of [param mats] — the deliver target within a named zone.
func _nearest_zone_cell(
	zone: StockpileZone, load: int, mats: Array
) -> Vector3i:
	var best := Vector3i.MAX
	var best_sq := INF
	var origin := _standing_voxel()
	for cell: Vector3i in zone.cells:
		if not Colony.in_area(allowed_area, cell):
			continue
		if _colony.voxel_fill(cell) + load > _colony.voxel_capacity(cell):
			continue
		var admits := true
		for material in mats:
			if not _colony.stockpile_admits(cell, material):
				admits = false
				break
		if not admits:
			continue
		var sq := (Vector3(cell) - Vector3(origin)).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = cell
	return best


## Craft fetch: at the pile, lift items of the forms the recipe still
## needs until the load fills, then carry them to the spot.
func _tick_craft_fetch(delta: float) -> void:
	_stow_for_work()
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null:
		_advance_craft_goal()
		return
	# A furniture bill prefers its crate: the packed piece satisfies the
	# whole order. The crate is a single oversized item — volume means
	# nothing to it, mass is what gates the lift.
	if not BlockRegistry.furniture_spec(job.recipe).is_empty():
		var crate := pile.take_spec_item(DropItem.Form.CRATE, job.recipe)
		if crate != null:
			if _carried_mass() + crate.mass_kg() > _drag_kg():
				# Too heavy even to drag — back it goes; a stronger unit
				# will claim the job.
				pile.add_item(crate)
				_give_up_on_job()
				return
			_carried.append(crate)
			_spend_budget(crate.volume)
			_colony.remove_pile_if_empty(_goal_voxel)
			_advance_craft_goal()
			return
	if _craft_wanted_in(pile).is_empty():
		_advance_craft_goal()
		return
	var cap := mini(carry_cap() - _carried_volume(), _budget_cm3())
	var wanted := _craft_wanted_forms()
	var rejected: Dictionary = (
		job.order.rejected_materials if job.order != null else {}
	)
	var admit_input := func(item: DropItem) -> bool:
		return (
			wanted.has(item.form)
			and not item.forbidden
			and not rejected.get(int(item.material), false)
			and _craft_admits(item)
		)
	var took_items := _keep_liftable(
		pile.take_up_to(
			cap, admit_input, false, maxf(_drag_kg() - _carried_mass(), 0.0)
		),
		pile
	)
	for item in took_items:
		_carried.append(item)
		_spend_budget(item.volume)
	_colony.remove_pile_if_empty(_goal_voxel)
	if (
		not took_items.is_empty()
		or _carried_volume() >= carry_cap()
		or _carried_mass() >= _drag_kg()
	):
		_advance_craft_goal()
	elif _budget_cm3() >= carry_cap():
		# A full shovel and nothing takeable — unless strays the recipe
		# doesn't want are hogging the load: a leftover sliver leaves no
		# room for a whole log, say. Set the strays down and keep
		# fetching; wanted cargo rides to the site first.
		var held: Array[DropItem] = []
		var strays: Array[DropItem] = []
		for item in _carried:
			var want := _craft_need(_craft_slot(item.form))
			if (
				item.form == DropItem.Form.LOOSE
				and _craft_loose_wants().has(item.material)
			):
				want = _craft_loose_need(item.material)
			elif _craft_crate_admits(item):
				want = 1
			(held if want > 0 else strays).append(item)
		for item in strays:
			_colony._drop_item(item, _standing_voxel())
		_carried = held
		if _carried.is_empty() and strays.is_empty():
			# The inputs here are all heavier than a unit can carry.
			_give_up_on_job()
		else:
			_advance_craft_goal()


## `job.delivered` keys past this offset are material ids, not forms —
## where `input_loose` recipes (ore and charcoal are both LOOSE) keep
## their per-material tallies.
const DELIVERED_MATERIAL_OFF := 100


## cm³ of [param form] the craft order still wants — recipe inputs count
## whole items except where `input_cm3` measures a loose form directly;
## [member ColonyJob.delivered] tallies what's arrived.
func _craft_need(form: DropItem.Form) -> int:
	var recipe: Dictionary = Colony.recipe_of(job.recipe)
	var want := int(recipe["inputs"].get(form, 0)) * DropItem.form_volume(form)
	var volumes: Dictionary = recipe.get(&"input_cm3", {})
	if volumes.has(form):
		want = int(volumes[form])
	return maxi(want - int(job.delivered.get(form, 0)), 0)


## The recipe's material-keyed loose inputs — `input_loose` — or empty.
## A smelt takes malachite AND charcoal, both LOOSE form, so the usual
## per-form accounting can't tell them apart; their deliveries track
## under [constant DELIVERED_MATERIAL_OFF] + material.
func _craft_loose_wants() -> Dictionary:
	# A garment-repair job's loose bill is computed from the escrowed
	# garment's wear, not the recipe — the recipe can't know it.
	if job.repair_loose != null:
		return job.repair_loose
	return Colony.recipe_of(job.recipe).get(&"input_loose", {})


## cm³ of loose [param material] the order still wants — 0 when the
## recipe takes none of it.
func _craft_loose_need(material: int) -> int:
	var wants := _craft_loose_wants()
	if not wants.has(material):
		return 0
	var have := int(
		job.delivered.get(DELIVERED_MATERIAL_OFF + material, 0)
	)
	return maxi(int(wants[material]) - have, 0)


## The recipe's per-form pins — `input_material` material pins plus
## `input_spec` garment-spec pins (repair and salvage bills pin the
## garment to the spec they name). A pin is an int material or a
## StringName spec.
func _craft_pins() -> Dictionary:
	var recipe := Colony.recipe_of(job.recipe)
	var pins: Dictionary = recipe.get(&"input_material", {})
	var spec_pins: Dictionary = recipe.get(&"input_spec", {})
	if spec_pins.is_empty():
		return pins
	var merged := pins.duplicate()
	for form: int in spec_pins:
		merged[form] = spec_pins[form]
	return merged


## The recipe-input form [param form] fills — itself, or its
## substitute target when the recipe wants that (sheet metal pays a
## plank slot by volume). Delivery tallies key on the want form, so
## two sheets land in one plank's `delivered` count.
func _craft_slot(form: int) -> int:
	return DropItem.want_form_for(
		Colony.recipe_of(job.recipe)["inputs"], form
	)


## Whether [param item] satisfies the recipe's pin for the slot it
## fills — a form listed in `input_material` only counts in the pinned
## material, and the pin binds the *want* form: a plank slot pinned to
## wood takes no sheet, whatever its metal. Under an `input_loose`
## recipe a loose item must also still be needed — a pile can hold
## loose kinds the bill is already full of.
func _craft_admits(item: DropItem) -> bool:
	if (
		item.form == DropItem.Form.LOOSE
		and _craft_loose_wants().has(item.material)
	):
		return _craft_loose_need(item.material) > 0
	var pins := _craft_pins()
	var slot := _craft_slot(item.form)
	var pin: Variant = pins.get(slot)
	if pin == null:
		return true
	# A StringName pin is a garment spec; an int is a material; an
	# Array is a material set — the rod slot's "branches or bone".
	if pin is StringName:
		return item.spec == pin
	if pin is Array:
		return pin.has(item.material)
	return item.material == pin


## Whether [param item] is the crate this furniture bill wants — the
## packed piece whose spec matches the recipe. Reinstalling it stands
## in for every input at once.
func _craft_crate_admits(item: DropItem) -> bool:
	return (
		item.form == DropItem.Form.CRATE
		and not BlockRegistry.furniture_spec(job.recipe).is_empty()
		and item.spec == job.recipe
	)


## True while any recipe input is still missing — or until a matching
## crate is escrowed, since a packed piece satisfies the whole order.
func _craft_needs() -> bool:
	for item in job.components:
		if _craft_crate_admits(item):
			return false
	for form: int in Colony.recipe_of(job.recipe)["inputs"]:
		if _craft_need(form) > 0:
			return true
	for material: int in _craft_loose_wants():
		if _craft_loose_need(material) > 0:
			return true
	return false


## The forms the recipe still wants — the fetch query's filter. Any
## outstanding `input_loose` material wants the LOOSE form itself; the
## pile-side filters decide which loose items count. A want lists its
## filling forms, not just itself — a plank slot wants planks *and*
## sheets.
func _craft_wanted_forms() -> Array:
	var forms: Array = []
	for form: int in Colony.recipe_of(job.recipe)["inputs"]:
		if _craft_need(form) > 0:
			for fill: int in DropItem.fill_forms(form):
				if not forms.has(fill):
					forms.append(fill)
	for material: int in _craft_loose_wants():
		if _craft_loose_need(material) > 0:
			forms.append(DropItem.Form.LOOSE)
			break
	return forms


## The subset of a pile's stock the recipe still wants — intersected so
## the fetch tick only lifts what's needed, and only items the bill's
## material filter admits count.
func _craft_wanted_in(pile: ItemPile) -> Array:
	var forms: Array = []
	var rejected: Dictionary = (
		job.order.rejected_materials if job.order != null else {}
	)
	for form in _craft_wanted_forms():
		for item in pile.items:
			if (
				item.form == form
				and not item.forbidden
				and not rejected.get(int(item.material), false)
				and _craft_admits(item)
			):
				forms.append(form)
				break
	return forms


## Next craft-job goal: deliver the load to the spot when the unit holds
## inputs, or the recipe is complete; else fetch from the next-closest
## pile holding a wanted form.
func _advance_craft_goal() -> void:
	var carrying_needed := false
	for item in _carried:
		var want := _craft_need(_craft_slot(item.form))
		if (
			item.form == DropItem.Form.LOOSE
			and _craft_loose_wants().has(item.material)
		):
			want = _craft_loose_need(item.material)
		elif _craft_crate_admits(item):
			want = 1
		if want > 0:
			carrying_needed = true
			break
	if carrying_needed or not _craft_needs():
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		_stow_for_work()
		if carry_cap() <= 0:
			# Both hands full of tools and nowhere to stow them — this
			# unit physically can't carry a thing for the bill.
			_give_up_on_job()
			return
		var next := _craft_fetch_voxel()
		if next == Vector3i.MAX:
			# No usable inputs anywhere — back on the board it goes.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## The next input pile for the running craft bill — the recipe's wanted
## forms, honouring the bill's ingredient radius around the worksite
## and its material filter. A furniture bill prefers the matching
## crate wherever one exists: reinstalling skips the recipe's inputs
## entirely, so the fetch is the whole job.
func _craft_fetch_voxel() -> Vector3i:
	if not BlockRegistry.furniture_spec(job.recipe).is_empty():
		var crate := _colony.nearest_crate_voxel(
			_standing_voxel(), job.recipe, allowed_area
		)
		if crate != Vector3i.MAX:
			return crate
	var radius := 0.0
	var rejected: Dictionary = {}
	if job.order != null:
		radius = job.order.ingredient_radius
		rejected = job.order.rejected_materials
	# `_craft_pins` hands back the recipe's own table — copy it before
	# pinning, a mutation there would corrupt RECIPES for good.
	var pins := _craft_pins().duplicate()
	# A pin binds the want form; substitutes filling that slot carry it
	# too — the pile query keys on item forms, so mirror each pin onto
	# every form that can fill the want.
	for want: int in _craft_pins():
		for fill: int in DropItem.fill_forms(want):
			pins[fill] = pins[want]
	# Loose-material inputs pin LOOSE to the set of materials still
	# wanted — the fetch query admits a pile only when it holds one.
	# A form-keyed LOOSE slot may pin the same form (the tool recipes'
	# rod set): the wanted set unions onto it rather than replacing it.
	var loose_wants := _craft_loose_wants()
	if not loose_wants.is_empty():
		var wanted: Array = []
		var existing: Variant = pins.get(DropItem.Form.LOOSE)
		if existing is Array:
			wanted.append_array(existing)
		elif existing is int:
			wanted.append(existing)
		for material: int in loose_wants:
			if (
				_craft_loose_need(material) > 0
				and not wanted.has(material)
			):
				wanted.append(material)
		pins[DropItem.Form.LOOSE] = wanted
	return _colony.nearest_forms_voxel(
		_standing_voxel(), _craft_wanted_forms(),
		job.voxel_position, radius, rejected, pins, allowed_area
	)


## Refuelling: fetch a load of fuel from the best pile, carry it to the
## campfire, and feed it — the delivery is the whole job. Anything the
## unit carried that doesn't burn gets set down at the fire.
func _tick_refueling(delta: float) -> void:
	var site := _colony.building_at(job.voxel_position)
	if site == null or not site.uses_fuel():
		# The fire's gone — nothing left to feed.
		_give_up_on_job()
		return
	if _fetching:
		_tick_refuel_fetch(delta)
		return
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	var seconds := 0.0
	var leftovers: Array[DropItem] = []
	for item in _carried:
		var worth := DropItem.fuel_seconds_of(item)
		if worth > 0.0:
			seconds += worth
		else:
			leftovers.append(item)
	_carried.clear()
	for item in leftovers:
		_colony._drop_item(item, job.voxel_position)
	_colony.complete_refuel(job, seconds)
	job = null
	state = State.IDLE


## Charcoal burn: the mound needs constant attention — stand beside it
## and work the whole `burn_seconds`, gaining Charcoal burning XP at the
## burn's own rate. A supervisor who walks off mid-burn lets the job
## back onto the board via `release_job`, progress intact.
func _tick_burning(delta: float) -> void:
	var site := _colony.building_at(job.voxel_position)
	if site == null or site.kind != Building.Kind.CHARCOAL_MOUND:
		_give_up_on_job()
		return
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	job.progress += delta * _work_rate()
	if job.progress >= Colony.CHARCOAL_BURN_SECONDS:
		_colony.complete_burn(job)
		job = null
		state = State.IDLE


## Teaching: the tutor stands near the student and works the widest
## skill gap per tick — `teach_xp_per_second` from the teacher's side,
## the full drip to the student, capped at the teacher's competency.
func _tick_teaching(delta: float) -> void:
	var student: Unit = job.patient
	var subject := -1
	if student != null and is_instance_valid(student) and not student.dead:
		subject = Colony.teachable_skill(self, student)
	if subject < 0 or job.progress >= Colony.TEACH_SECONDS:
		_colony.complete_teach(job)
		job = null
		state = State.IDLE
		return
	var here := _standing_voxel()
	var target := Vector3i(student.global_position.floor())
	if (
		here == target
		or not _can_clear_from(global_position, target)
	):
		state = State.MOVING
		return
	job.progress += delta
	# Capped at the teacher's own XP — a tutor can't drill a student
	# past what they themselves know.
	var xp := minf(
		TEACH_XP_PER_SECOND * _work_rate() * delta,
		float(skills.get(subject, 0.0)) - float(student.skills.get(subject, 0.0))
	)
	if xp <= 0.0:
		_colony.complete_teach(job)
		job = null
		state = State.IDLE
		return
	student.gain_skill_xp(subject, xp)
	gain_skill_xp(subject, xp * 0.5)


## Repairing: stand beside the battered construction and put its hit
## points back — steady work until it stands whole. If the wreck came
## down (or the record went) the bill quietly ends.
func _tick_repairing(delta: float) -> void:
	var building: Building = _colony.buildings.get(job.voxel_position)
	if building == null:
		_colony.complete_repair(job)
		job = null
		state = State.IDLE
		return
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	var work := Colony.REPAIR_HP_PER_S * _work_rate() * delta
	job.progress += work
	building.hp = minf(building.hp + work, building.max_hp)
	if building.hp < building.max_hp:
		return
	_colony.complete_repair(job)
	job = null
	state = State.IDLE


## Firefighting: stand beside the burning cell — never in it — and beat
## the flames until the fire's fuel is gone. The cell may already be
## out (burned down, rained out, or another beater finished it); either
## way the bill ends once nothing burns there.
func _tick_firefighting(delta: float) -> void:
	if not _colony.is_burning(job.voxel_position):
		_colony.complete_firefight(job)
		job = null
		state = State.IDLE
		return
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	job.progress += delta
	if not _colony.beat_fire(
		job.voxel_position, Colony.FIRE_BEAT_RATE * _work_rate() * delta
	):
		# The last stomp put it out.
		_colony.complete_firefight(job)
		job = null
		state = State.IDLE


## Refuel fetch: at the pile, lift burnable items until the load fills,
## then carry them to the fire.
func _tick_refuel_fetch(delta: float) -> void:
	_stow_for_work()
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null:
		_advance_refuel_goal()
		return
	var cap := mini(carry_cap() - _carried_volume(), _budget_cm3())
	var admit_fuel := func(item: DropItem) -> bool:
		return DropItem.fuel_seconds_of(item) > 0.0 and not item.forbidden
	var took := _keep_liftable(
		pile.take_up_to(
			cap, admit_fuel, false, maxf(_drag_kg() - _carried_mass(), 0.0)
		),
		pile
	)
	for item in took:
		_carried.append(item)
		_spend_budget(item.volume)
	_colony.remove_pile_if_empty(_goal_voxel)
	if (
		not took.is_empty()
		or _carried_volume() >= carry_cap()
		or _carried_mass() >= _drag_kg()
	):
		_advance_refuel_goal()
	elif _budget_cm3() >= carry_cap():
		# A full shovel and nothing burnable — the job can't proceed.
		_give_up_on_job()


## Next refuel goal: deliver to the fire when the unit holds fuel, else
## fetch from the next-best fuel pile — or give up when nothing burns
## and nothing was gathered.
func _advance_refuel_goal() -> void:
	var carrying_fuel := false
	for item in _carried:
		if DropItem.fuel_seconds_of(item) > 0.0:
			carrying_fuel = true
			break
	if carrying_fuel:
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_fuel_voxel(
			_standing_voxel(), {}, allowed_area
		)
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## Furnishing: fetch the kit the building unpacks from, carry it to the
## anchor, and the building goes up — no terrain changes, just the
## footprint registering in the colony's buildings.
## Uninstalling: fetch a sheet-material shell — plank or metal sheet —
## carry it to the piece, then pack the whole thing into a crate at
## its site. The crate keeps the components whole, so nothing is lost.
func _tick_uninstalling(delta: float) -> void:
	var building := _colony.building_at(job.voxel_position)
	if building == null or not Colony.is_furniture(building):
		# The piece is gone — the order is moot.
		_give_up_on_job()
		return
	if _fetching:
		_stow_for_work()
		if not _can_clear_from(global_position, _goal_voxel):
			state = State.MOVING
			return
		_clear_budget += clearing_speed * delta * _work_rate()
		var pile := _colony.item_pile_at(_goal_voxel)
		if pile == null:
			_advance_uninstall_goal()
			return
		var lift := maxf(_drag_kg() - _carried_mass(), 0.0)
		var shell := pile.take_form(
			DropItem.Form.PLANK,
			mini(carry_cap() - _carried_volume(), _budget_cm3()),
			lift
		)
		if shell == null:
			shell = pile.take_form(
				DropItem.Form.SHEET,
				mini(carry_cap() - _carried_volume(), _budget_cm3()),
				lift
			)
		if shell == null:
			if (
				pile.form_volume(DropItem.Form.PLANK) <= 0
				and pile.form_volume(DropItem.Form.SHEET) <= 0
			):
				_advance_uninstall_goal()
			elif _budget_cm3() >= carry_cap():
				_give_up_on_job()
			return
		_carried.append(shell)
		_spend_budget(shell.volume)
		_colony.remove_pile_if_empty(_goal_voxel)
		_advance_uninstall_goal()
		return
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var shell := _carried_shell()
	if shell != null:
		# Delivered — the shell escrows into the job; it is the crate's
		# skin, so it no longer sits in the carried set.
		_carried.erase(shell)
		job.components.append(shell)
		# Anything else in hand isn't the crate's business — set it down.
		for item in _carried:
			_colony._drop_item(item, job.voxel_position)
		_carried.clear()
	elif _escrowed_shell(job) == null:
		# No shell in hand and none delivered yet — go find one.
		_advance_uninstall_goal()
		return
	# Packing is short work — fold the piece into its shell.
	job.progress += delta * _work_rate()
	if job.progress < deconstruct_seconds:
		return
	_colony.complete_uninstall(job)
	job = null
	state = State.IDLE


## The pile a packer fetches its shell from — the nearest holding a
## plank or a metal sheet.
func _uninstall_shell_voxel() -> Vector3i:
	return _colony.nearest_forms_voxel(
		_standing_voxel(),
		[DropItem.Form.PLANK, DropItem.Form.SHEET],
		Vector3i.MAX, 0.0, {}, {}, allowed_area
	)


## The first carried item usable as a crate shell — plank or sheet.
func _carried_shell() -> DropItem:
	for item in _carried:
		if (
			item.form == DropItem.Form.PLANK
			or item.form == DropItem.Form.SHEET
		):
			return item
	return null


## The shell already escrowed into an uninstall job — once the packer
## hands it over it counts as delivered, so the tick isn't asking for
## a second one every frame.
func _escrowed_shell(job: ColonyJob) -> DropItem:
	for item in job.components:
		if (
			item.form == DropItem.Form.PLANK
			or item.form == DropItem.Form.SHEET
		):
			return item
	return null


## Next uninstall-goal: deliver the shell to the piece once it's in
## hand — or straight back to the site when one is already escrowed —
## else fetch from the next-closest pile holding sheet goods.
func _advance_uninstall_goal() -> void:
	if _carried_shell() != null or _escrowed_shell(job) != null:
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _uninstall_shell_voxel()
		if next == Vector3i.MAX:
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## Unpacking: open the crate where it stands — the contents spill back
## into the world and the shell goods return as items.
func _tick_unpacking(delta: float) -> void:
	var pile := _colony.item_pile_at(job.voxel_position)
	var crate := false
	if pile != null:
		for item in pile.items:
			if item.form == DropItem.Form.CRATE and not item.forbidden:
				crate = true
				break
	if not crate:
		# The crate's gone — the order is moot.
		_give_up_on_job()
		return
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	job.progress += delta * _work_rate()
	if job.progress < deconstruct_seconds:
		return
	_colony.complete_unpack(job)
	job = null
	state = State.IDLE


## Sowing: fetch a seed packet of the field's species — the furnish
## pattern — carry it to the cell, then a short work tick plants it.
## The packet is consumed by the planting; a cell that filled up in the
## meantime hands it back (colony.complete_sow decides).
func _tick_sowing(delta: float) -> void:
	if _fetching:
		if not _can_clear_from(global_position, _goal_voxel):
			state = State.MOVING
			return
		_clear_budget += clearing_speed * delta * _work_rate()
		var pile := _colony.item_pile_at(_goal_voxel)
		if pile == null or _budget_cm3() <= 0:
			_advance_sow_goal()
			return
		var seed := pile.take_seed(job.species)
		if seed == null:
			_advance_sow_goal()
			return
		_carried.append(seed)
		_spend_budget(seed.volume)
		_colony.remove_pile_if_empty(_goal_voxel)
		_advance_sow_goal()
		return
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var seed := _carried_seed(job.species)
	if seed == null:
		# The packet went somewhere — fetch again.
		_advance_sow_goal()
		return
	job.progress += delta * _work_rate()
	if job.progress < sow_seconds:
		return
	_carried.erase(seed)
	# Anything else in hand isn't the field's business — set it down.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	_colony.complete_sow(job, seed)
	job = null
	state = State.IDLE


## Next sow-job goal: deliver the packet to the field cell once it's in
## hand, else fetch from the next-closest pile holding the species.
func _advance_sow_goal() -> void:
	if _carried_seed(job.species) != null:
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_seed_voxel(
			_standing_voxel(), job.species, allowed_area
		)
		if next == Vector3i.MAX:
			# No seeds of the species left — the job goes back suspended;
			# the farm scan revives it when a packet exists again.
			job.suspended = true
			if _colony.world.sim != null:
				_colony.world.sim.job_suspend(job.get_instance_id(), true)
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## The first carried seed packet of [param species], or null.
func _carried_seed(species: StringName) -> DropItem:
	for item in _carried:
		if item.form == DropItem.Form.SEED and item.species == species:
			return item
	return null


## The first carried item of [param form], or null.
func _carried_form(form: DropItem.Form) -> DropItem:
	for item in _carried:
		if item.form == form:
			return item
	return null


## Fertilizing: shovel loose compost at the fetch pile until the cell's
## shortfall is in hand, then stand at the cell and spread it — the
## compost's volume becomes soil fertility at the standard conversion.
func _tick_fertilizing(delta: float) -> void:
	if _fetching:
		if not _can_clear_from(global_position, _goal_voxel):
			state = State.MOVING
			return
		_clear_budget += clearing_speed * delta * _work_rate()
		var pile := _colony.item_pile_at(_goal_voxel)
		if pile == null or _budget_cm3() <= 0:
			_advance_fertilize_goal()
			return
		var want := mini(
			mini(
				_fertilize_need() - _carried_compost(), _budget_cm3()
			),
			carry_cap() - _carried_volume()
		)
		if want <= 0:
			_advance_fertilize_goal()
			return
		var got := pile.take_loose(BlockRegistry.Resource_.COMPOST, want)
		if got <= 0:
			_advance_fertilize_goal()
			return
		_carried.append(
			DropItem.new(
				BlockRegistry.Resource_.COMPOST, DropItem.Form.LOOSE, got
			)
		)
		_spend_budget(got)
		_colony.remove_pile_if_empty(_goal_voxel)
		_advance_fertilize_goal()
		return
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var held := _carried_compost()
	if held <= 0:
		if _fertilize_need() <= 0:
			# The soil reached target while the unit fetched — the
			# mark's work is done with nothing left to spread.
			_colony.complete_fertilize(job, 0)
			job = null
			state = State.IDLE
			return
		_advance_fertilize_goal()
		return
	job.progress += delta * _work_rate()
	if job.progress < fertilize_seconds:
		return
	# Everything compost in hand goes into the ground — the fetch sized
	# the load to the shortfall, so nothing is wasted.
	for item in _carried.duplicate():
		if (
			item.material == BlockRegistry.Resource_.COMPOST
			and item.form == DropItem.Form.LOOSE
		):
			_carried.erase(item)
	# Anything else in hand isn't the soil's business — set it down.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	_colony.complete_fertilize(job, held)
	job = null
	state = State.IDLE


## Next fertilize goal: the cell once enough compost is in hand, else
## the nearest pile holding loose compost. Like a sow's seed fetch, a
## larder with no compost suspends the job until rot pays out.
func _advance_fertilize_goal() -> void:
	if (
		_fertilize_need() <= _carried_compost()
		or _carried_volume() >= carry_cap()
	):
		# Full hands deliver a partial load — the scan reposts the rest.
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var next := _colony.nearest_compost_voxel(
			_standing_voxel(), allowed_area
		)
		if next == Vector3i.MAX:
			job.suspended = true
			if _colony.world.sim != null:
				_colony.world.sim.job_suspend(job.get_instance_id(), true)
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_path.clear()
	state = State.MOVING


## cm³ of compost still wanted to bring the job's soil up to its
## target — the fetch's sizing query.
func _fertilize_need() -> int:
	var soil := job.voxel_position + Vector3i.DOWN
	var shortfall := (
		job.fertilize_target - _colony.effective_fertility(soil)
	)
	if shortfall <= 0.0:
		return 0
	return int(ceil(shortfall / Colony.FERTILIZE_PER_CM3))


## cm³ of loose compost currently in hand.
func _carried_compost() -> int:
	var total := 0
	for item in _carried:
		if (
			item.material == BlockRegistry.Resource_.COMPOST
			and item.form == DropItem.Form.LOOSE
		):
			total += item.volume
	return total


## Hunting: in melee range of the quarry, lay into it. The colony
## finishes the job when the animal dies; a wounded hunter breaks off
## instead of being carried home.
func _tick_hunting(delta: float) -> void:
	var quarry := job.animal
	if quarry == null or not is_instance_valid(quarry) or quarry.dead:
		return
	if health <= HUNT_ABORT_FRACTION * Species.field(species, &"health", 100.0):
		# Mauled — the quarry wins this round.
		_note("hunt: too wounded, breaking off")
		_give_up_on_job()
		return
	if global_position.distance_to(quarry.global_position) > Animal.MELEE_RANGE:
		# It bolted — the chase resumes as a moving leg.
		state = State.MOVING
		return
	quarry.take_hit(
		Species.field(species, &"melee", 8.0) * _work_rate() * delta, self
	)


## Butchering: fetch a corpse the body can move (dragging counts), then
## stand at the spot and cut — species `butcher_seconds` of work, paced
## by the butchering skill rate.
func _tick_butcher(delta: float) -> void:
	if _fetching:
		if not _can_clear_from(global_position, _goal_voxel):
			state = State.MOVING
			return
		_clear_budget += clearing_speed * delta * _work_rate()
		var pile := _colony.item_pile_at(_goal_voxel)
		if pile == null or _budget_cm3() <= 0:
			_advance_butcher_goal()
			return
		var corpse := _take_corpse(pile)
		if corpse != null:
			_carried.append(corpse)
			_spend_budget(corpse.volume)
			_colony.remove_pile_if_empty(_goal_voxel)
		_advance_butcher_goal()
		return
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var corpse := _carried_form(DropItem.Form.CORPSE)
	if corpse != null:
		# The corpse goes on the slab; the rest of the load is unrelated
		# baggage — set it down beside the spot.
		_carried.erase(corpse)
		job.components.append(corpse)
		for item in _carried:
			_colony._drop_item(item, job.voxel_position)
		_carried.clear()
	else:
		for item in job.components:
			if item.form == DropItem.Form.CORPSE:
				corpse = item
				break
	if corpse == null:
		# Hands and slab both empty — fetch again.
		_advance_butcher_goal()
		return
	var seconds := Species.field(
		corpse.species, &"butcher_seconds", 60.0
	)
	job.progress += delta * _work_rate()
	if job.progress < seconds:
		return
	_colony.complete_butcher(job, self)
	job = null
	state = State.IDLE


## The corpse this unit can actually move out of [param pile] — the
## smallest carcass under the drag limit, or null when everything here
## is too heavy.
func _take_corpse(pile: ItemPile) -> DropItem:
	var admit_corpse := func(item: DropItem) -> bool:
		return item.form == DropItem.Form.CORPSE and not item.forbidden
	var got := _keep_liftable(
		pile.take_up_to(
			DropItem.BLOCK_CM3, admit_corpse, false,
			maxf(_drag_kg() - _carried_mass(), 0.0)
		),
		pile
	)
	for item in got:
		if item.form == DropItem.Form.CORPSE:
			return item
	return null


## Next butcher-job goal: carry a corpse to the slab, else fetch from
## the next corpse pile holding one the unit can lift. Nothing to fetch
## and nothing in hand ends the job.
func _advance_butcher_goal() -> void:
	if _carried_form(DropItem.Form.CORPSE) != null:
		_fetching = false
		_goal_voxel = job.voxel_position
		_path.clear()
		_stuck_elapsed = 0.0
		_best_goal_distance = INF
		if not _repath_to_job():
			_give_up_on_job()
		return
	var next := _colony.nearest_corpse_voxel(
		_standing_voxel(), _drag_kg(), allowed_area
	)
	if next == Vector3i.MAX:
		_give_up_on_job()
		return
	_goal_voxel = next
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if not _repath_to_job():
		_give_up_on_job()


## Whether [param patient] is a valid tend target — alive, still a unit
## here, and still carrying something a tend could treat.
func _patient_tendable(patient: Unit) -> bool:
	return (
		patient != null
		and patient != self
		and is_instance_valid(patient)
		and not patient.dead
		and not patient.wounds.is_empty()
	)


## Whether [param patient] can be picked up — downed, alive, not
## already in somebody else's arms, and under this unit's drag limit.
## The last gate is the whole hauling question: a unit too heavy to
## drag is too heavy to rescue.
func _patient_rescuable(patient: Unit) -> bool:
	return (
		patient != null
		and patient != self
		and is_instance_valid(patient)
		and not patient.dead
		and patient._carried_by == null
		and patient.state == State.DOWNED
		and patient.mass_kg() <= _drag_kg()
	)


## Tending: a short spell beside the patient — a doctor who fetched a
## bundle first can spend it if the patient is in a medical bed. Field
## care anywhere else only stops the bleeding.
func _tick_tending(delta: float) -> void:
	var patient: Unit = job.patient
	if not _patient_tendable(patient):
		_give_up_on_job()
		return
	if _fetching:
		# At the medicine pile — grab one bundle and head to the
		# patient. A pile that lost its medicine just walks on.
		var pile := _colony.item_pile_at(_goal_voxel)
		var bundle: DropItem = null
		var admit_med := func(item: DropItem) -> bool:
			return (
				item.material == BlockRegistry.Resource_.MEDICINE
				and not item.forbidden
			)
		if pile != null:
			var got := _keep_liftable(
				pile.take_up_to(
					DropItem.BLOCK_CM3, admit_med, false,
					maxf(_drag_kg() - _carried_mass(), 0.0)
				),
				pile
			)
			for item in got:
				if item.material == BlockRegistry.Resource_.MEDICINE:
					bundle = item
					break
			_colony.remove_pile_if_empty(_goal_voxel)
		if bundle != null:
			_carried.append(bundle)
		_fetching = false
		_goal_voxel = Vector3i(patient.global_position.floor())
		_path.clear()
		_stuck_elapsed = 0.0
		_best_goal_distance = INF
		state = State.MOVING
		if not _repath_to_job():
			_give_up_on_job()
		return
	# Cell distance, not float reach: `_goal_in_reach` fired on the
	# voxel-face metric and unit collision keeps the doctor off the bed
	# cell — two cells over sits exactly at `mine_reach`, where a
	# float comparison jitters between ticks. Chebyshev two is bedside.
	var away: Vector3i = (
		_standing_voxel() - Vector3i(patient.global_position.floor())
	).abs()
	if maxi(away.x, maxi(away.y, away.z)) > 2:
		# The patient moved — the chase resumes as a moving leg.
		state = State.MOVING
		return
	job.progress += delta * _work_rate()
	if job.progress < TEND_SECONDS:
		return
	_colony.complete_tend(job, self)
	job = null
	state = State.IDLE


## Seconds of bedside work a tend takes, before the doctor's skill.
const TEND_SECONDS := 4.0


## Rescue: reach the patient, lift them (the mass rides the carrier's
## drag capacity), haul them to a bed, set them down. A rescue that
## can't lift — or whose bed vanished — sets the patient back down and
## re-posts.
func _tick_rescuing(_delta: float) -> void:
	var patient: Unit = job.patient
	if _carried_unit == null:
		if not _patient_rescuable(patient):
			_give_up_on_job()
			return
		var away: Vector3i = (
			_standing_voxel() - Vector3i(patient.global_position.floor())
		).abs()
		if maxi(away.x, maxi(away.y, away.z)) > 2:
			state = State.MOVING
			return
		if not _pick_up_patient(patient):
			_give_up_on_job()
		return
	# Carrying — at the bed, set the patient down.
	var bed: Building = job.target_bed
	if bed == null:
		# No bed target ever got claimed — put them down here and let
		# the posting tick decide if they still need one.
		_put_down_patient()
		_give_up_on_job()
		return
	if not _goal_in_reach():
		state = State.MOVING
		return
	_deliver_patient()


## Lifts [param patient] and picks their bed: a free medical bed first —
## the facility a real tend needs — else any free bed, else nobody
## carries them anywhere and the job goes back. The bed is claimed for
## the patient immediately so nobody else sleeps in it en route.
func _pick_up_patient(patient: Unit) -> bool:
	var bed := _colony.nearest_free_medical_bed(
		_standing_voxel(), allowed_area
	)
	if bed == null:
		bed = _colony.nearest_free_bed(_standing_voxel(), allowed_area)
	if bed == null:
		return false
	bed.claim_bed(patient)
	patient._rest_bed = bed
	job.target_bed = bed
	patient._carried_by = self
	_carried_unit = patient
	if _world.sim != null and patient._sim_id != 0:
		_world.sim.unit_unregister(patient._sim_id)
	_goal_voxel = bed.voxel
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	state = State.MOVING
	return _repath_to_job()


## Sets the carried patient down where the rescuer stands — no bed —
## and drops the job's bed claim. The patient is downed again on the
## spot.
func _put_down_patient() -> void:
	var patient := _carried_unit
	_carried_unit = null
	if patient == null or not is_instance_valid(patient):
		return
	patient.global_position = global_position
	patient._carried_by = null
	if patient._rest_bed != null:
		patient._rest_bed.release_bed(patient)
		patient._rest_bed = null
	if _world.sim != null and patient._sim_id != 0:
		_world.sim.unit_register(patient._sim_id, patient.global_position)


## Carried patient arrives at the claimed bed — tuck them in. The bed
## keeps its occupant claim (the patient, not the rescuer).
func _deliver_patient() -> void:
	var patient := _carried_unit
	var bed: Building = job.target_bed
	_carried_unit = null
	if patient == null or not is_instance_valid(patient) or patient.dead:
		_give_up_on_job()
		return
	# The bed went away under the rescue — deconstructed or claimed by
	# somebody else — set the patient down here.
	if (
		bed == null
		or not bed.occupants.has(patient)
		or _colony.building_at(bed.voxel) != bed
	):
		_put_down_patient()
		_give_up_on_job()
		return
	patient._carried_by = null
	patient.global_position = (
		Vector3(bed.voxel) + Vector3(0.5, 0.9, 0.5)
	)
	patient._rest_quality = RestQuality.NORMAL
	if _world.sim != null and patient._sim_id != 0:
		_world.sim.unit_register(patient._sim_id, patient.global_position)
	_colony.complete_rescue(job, self)
	job = null
	state = State.IDLE


## Incoming damage — today the only attacker is a wounded animal whose
## fight temperament turned on its hunter.
## Damage lands on a body part, not the pooled bar: pick the part by
## coverage, the wound kind by the attacker's teeth, and open a wound
## there — or deepen an existing one of the same kind. Melee ticks in
## small slices, so wounds merge rather than stacking hundreds deep.
func take_hit(damage: float, attacker: Node3D) -> void:
	if dead or damage <= 0.0:
		return
	var part := _hit_part()
	var kind := &"bruise"
	if attacker != null and attacker.get(&"species") != null:
		kind = Species.spec(attacker.get(&"species")).get(
			&"wound_kind", &"bite"
		)
	add_wound(part, kind, damage)
	# Stray force lands around the scuffle — cover, walls and ground
	# near the victim erode while the fight goes on.
	if _colony != null:
		var from := (
			attacker.global_position
			if attacker != null and is_instance_valid(attacker)
			else global_position
		)
		_colony.combat_splash(global_position, from, damage)
	# Being mauled IS the order to fight — no requisition needed.
	_engage(attacker)


## Applies [param severity] damage to [param part] as a wound of
## [param kind] — the entry point for tests and future damage sources
## (falls, work accidents) that don't come through `take_hit`.
func add_wound(part: StringName, kind: StringName, severity: float) -> void:
	if dead:
		return
	var bleed_rate := float(WOUND_BLEED.get(kind, 0.05))
	for wound: Dictionary in wounds:
		if wound[&"part"] == part and wound[&"kind"] == kind:
			wound[&"severity"] = float(wound[&"severity"]) + severity
			wound[&"bleed"] = bleed_rate * float(wound[&"severity"])
			_health_update(true)
			return
	wounds.append({
		&"part": part, &"kind": kind, &"severity": severity,
		&"bleed": bleed_rate * severity, &"care": 0,
	})
	_health_update(true)


## The weighted roll for where a hit lands — coverage is the share.
func _hit_part() -> StringName:
	var roll := randf()
	var acc := 0.0
	for part: StringName in BODY_PARTS:
		acc += float(BODY_PARTS[part][&"coverage"])
		if roll < acc:
			return part
	return &"torso"


## Damage summed over [param part]'s wounds.
func part_damage(part: StringName) -> float:
	var total := 0.0
	for wound: Dictionary in wounds:
		if wound[&"part"] == part:
			total += float(wound[&"severity"])
	return total


## True while any wound is still open enough to bleed — or is bleeding.
func bleeding() -> bool:
	for wound: Dictionary in wounds:
		if float(wound[&"bleed"]) > 0.0:
			return true
	return false


## A wound no care tier has touched yet — first aid hasn't even stopped
## its bleeding.
func untended_wounds() -> bool:
	for wound: Dictionary in wounds:
		if int(wound[&"care"]) == 0:
			return true
	return false


## The unit can't stand: below the downed health line, bleeding badly,
## or a leg destroyed outright. Derived from the wounds — nothing here
## tracks its own state flag.
func is_downed() -> bool:
	if health <= DOWNED_HEALTH or blood_loss >= DOWNED_BLOOD_LOSS:
		return true
	for part: StringName in BODY_PARTS:
		var spec: Dictionary = BODY_PARTS[part]
		if spec.get(&"moves", false) and part_damage(part) >= float(spec[&"hp"]):
			return true
	return false


## The unit should be in a medical bed — hurt past the patient line,
## still bleeding, or carrying care nobody's given.
func needs_medical_attention() -> bool:
	return health < PATIENT_HEALTH or bleeding() or untended_wounds()


## Fatal: the bar's gone, a vital part is destroyed, or the blood's
## run out.
func _lethal() -> bool:
	if health <= 0.0 or blood_loss >= 1.0:
		return true
	for part: StringName in BODY_PARTS:
		var spec: Dictionary = BODY_PARTS[part]
		if spec.get(&"vital", false) and part_damage(part) >= float(spec[&"hp"]):
			return true
	return false


## Recompute the pooled health bar and act on what the wounds now say —
## sleep broken by fresh pain, a collapse into DOWNED, or death. Healing
## ticks call this too, but they must not wake a sleeper — a wounded
## unit in a medical bed would thrash awake on every tick otherwise.
func _health_update(worsened: bool = false) -> void:
	health = maxf(_health_max() - _total_severity(), 0.0)
	if _lethal():
		die()
		return
	if is_downed():
		if state != State.DOWNED:
			_go_down()
	elif worsened and state == State.SLEEPING:
		# Pain wakes a sleeper — RimWorld wakes pawns under attack.
		_wake()
	elif (
		job != null
		and job.type == ColonyJob.Type.HUNT
		and job.is_active()
		and health <= HUNT_ABORT_FRACTION * _health_max()
	):
		_give_up_on_job()


## The whole body plan's pool — what `health` counts down from.
func _health_max() -> float:
	var total := 0.0
	for part: StringName in BODY_PARTS:
		total += float(BODY_PARTS[part][&"hp"])
	return total


func _total_severity() -> float:
	var total := 0.0
	for wound: Dictionary in wounds:
		total += float(wound[&"severity"])
	return total


## Wound bookkeeping per tick: open wounds bleed and knit at their
## care tier's rate; blood comes back once nothing bleeds. Then the
## derived consequences — downed, dead, or healed enough to stand.
func _tick_wounds(delta: float) -> void:
	if wounds.is_empty() and blood_loss <= 0.0:
		return
	var day := _colony.day_length()
	var bedded := _rest_bed != null
	var closed: Array = []
	for wound: Dictionary in wounds:
		blood_loss += float(wound[&"bleed"]) * delta / day
		var mult: float = CARE_HEAL_MULT[int(wound[&"care"])]
		if bedded:
			# A well-made bed mends faster — the furniture's craft
			# quality rides the care it can give.
			mult *= BED_HEAL_MULT * _bed_quality_mult()
		wound[&"severity"] = float(wound[&"severity"]) - (
			WOUND_HEAL_PER_DAY * mult * delta / day
		)
		if float(wound[&"severity"]) <= 0.0:
			closed.append(wound)
	for wound: Dictionary in closed:
		wounds.erase(wound)
	if not bleeding():
		blood_loss = maxf(blood_loss - BLOOD_RECOVERY_PER_DAY * delta / day, 0.0)
	_health_update()


## Into DOWNED: drop the job and whatever's in hand, keep the bed claim
## if the collapse happened in one, and lie there until the wounds say
## otherwise or someone carries the unit to care.
func _go_down() -> void:
	if dead or state == State.DOWNED:
		return
	# The fight's over — a downed unit holds no target and no draft.
	_combat_target = null
	var bed := _rest_bed
	if job != null:
		_colony.release_job(job)
	abandon_job()
	if bed != null:
		_rest_bed = bed
		bed.occupant = self
	state = State.DOWNED
	_note("downed")


## Downed: hold still, heal at whatever care the wounds carry, and stand
## back up when the body can — into the bed it already claims, or idle
## on the ground where it fell.
func _tick_downed(_delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	if _carried_by != null or is_downed():
		return
	if _rest_bed != null:
		_rest_quality = RestQuality.NORMAL
		state = State.SLEEPING
	else:
		state = State.IDLE


## Dead: everything in hand drops, the job and bed go back, and the
## colony turns the body into a physical corpse item. A carried patient
## drops out of its rescuer's arms first.
func die() -> void:
	if dead:
		return
	dead = true
	drafted = false
	_combat_target = null
	var rescuer := _carried_by
	if rescuer != null:
		rescuer._carried_unit = null
		_carried_by = null
	if job != null:
		_colony.release_job(job)
	# The body keeps nothing — worn clothing, held tools and holstered
	# tools all drop with the corpse until dead pawns keep inventories.
	for item in worn + hands + holstered:
		if item != null:
			_colony._drop_item(item, _standing_voxel())
	worn.clear()
	hands.clear()
	holstered.clear()
	abandon_job()
	_colony._unit_died(self)


## Total mass the unit's body contributes to a hauler's load — its own
## body plus whatever it happened to be carrying.
func mass_kg() -> float:
	return Species.field(species, &"mass_kg", 75.0) + _carried_mass()


## The first carried item of [param material], or null.
func _carried_material(material: BlockRegistry.Resource_) -> DropItem:
	for item in _carried:
		if item.material == material:
			return item
	return null


## A doctor's pass over the wounds — every open wound stops bleeding;
## what happens next depends on where the patient lies. Field care can
## only stop the bleeding (care 1). In a medical bed the wounds are
## actually treated (care 2, heals 3x); with a medicine bundle spent,
## sealed a share instantly and cared for better (care 3, heals 4x).
func apply_tend(medical: bool, medicine: bool) -> void:
	for wound: Dictionary in wounds:
		wound[&"bleed"] = 0.0
		if not medical:
			wound[&"care"] = maxi(int(wound[&"care"]), 1)
			continue
		if medicine:
			wound[&"care"] = 3
			# A better bed treats better — the seal share scales with
			# the furniture's craft quality like its heal rate does.
			wound[&"severity"] = float(wound[&"severity"]) * (
				1.0 - TEND_MEDICINE_SEAL * _bed_quality_mult()
			)
		else:
			wound[&"care"] = maxi(int(wound[&"care"]), 2)
	_sync_health()


## Resync the pooled health bar without re-running the state rules —
## for tend paths where down/dead can't change.
func _sync_health() -> void:
	health = maxf(_health_max() - _total_severity(), 0.0)


## Clearing work: empty the job voxel's pile a little at a time. With a
## stockpile that has room the items are carried there — a load at a time,
## walking back between trips — otherwise they're shoveled into adjoining
## voxels like before.
func _tick_clearing(delta: float) -> void:
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	var pile := _colony.item_pile_at(job.voxel_position)
	if pile == null or pile.items.is_empty():
		_colony.complete_clear(job)
		job = null
		state = State.IDLE
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), 1, _haul_blacklist, pile.takeable_materials(),
		allowed_area
	)
	if sp != Vector3i.MAX:
		var room := _colony.voxel_capacity(sp) - _colony.voxel_fill(sp)
		var admit := func(item: DropItem) -> bool:
			return (
				_colony.stockpile_admits(sp, item.material)
				and not item.forbidden
				and (
					item.form == DropItem.Form.LOOSE
					or item.volume <= room
				)
			)
		var want := mini(carry_cap(), room) - _carried_volume()
		while want > 0 and _budget_cm3() > 0:
			var got := _keep_liftable(
				pile.take_up_to(
					mini(want, _budget_cm3()), admit, false,
					maxf(_drag_kg() - _carried_mass(), 0.0)
				),
				pile
			)
			if got.is_empty():
				break
			var volume := 0
			for item in got:
				volume += item.volume
			_carried.append_array(got)
			_spend_budget(volume)
			want = mini(carry_cap(), room) - _carried_volume()
		_colony.remove_pile_if_empty(job.voxel_position)
		if _carried_volume() > 0:
			# A delivery leg — the detour machinery walks the load to the
			# stockpile, then repaths back here to keep clearing.
			_detour = job.voxel_position
			_detour_return = job.voxel_position
			_detour_delivering = true
			_detour_opportunistic = false
			_detour_dest = Vector3i.MAX
			_goal_voxel = sp
			_path.clear()
			_stuck_elapsed = 0.0
			_best_goal_distance = INF
			state = State.MOVING
			if not _repath_to_job():
				_fail_detour()
			return
		# Nothing fits the carry load (oversized solid items) — scatter
		# what's left like there's no stockpile.
	while _clear_budget > 0.0:
		var item := _colony.move_pile_item(job.voxel_position)
		if item == null:
			if _colony.item_pile_at(job.voxel_position) == null:
				_colony.complete_clear(job)
				job = null
				state = State.IDLE
			else:
				# Every adjoining voxel is packed — the pile can't shrink.
				_give_up_on_job()
			return
		_spend_budget(item.volume)


## Build work is a hauling loop: fetch wall material from the closest
## pile that has what the recipe still needs (no distance limit — the
## unit walks to wherever it is), carry a load back to the site, repeat
## until every form the recipe calls for has arrived — `job.delivered`
## tallies the cm³ absorbed per form, `job.components` keeps the actual
## items so the finished wall knows what it was built of. The first load
## a unit picks commits the job's material (and so the block it builds)
## — permanently: a wall is one recipe, and a material that runs out
## sends the job back to the board rather than switching it to another.
## Then displace whatever sits in the voxel and place the block.
func _tick_building(delta: float) -> void:
	if job.face_dir != Vector3i.ZERO:
		if job.build_spec == &"conduit":
			var wired := _colony.building_at(job.voxel_position + job.face_dir)
			if wired == null or wired.conduit:
				# The wall went away or is already wired — the job is
				# moot and its delivered wire refunds.
				_colony.complete_conduit(job)
				job = null
				state = State.IDLE
				return
		else:
			var face := Flooring.face_index(job.face_dir)
			if face < 0 or (
				_colony.flooring.covering_at(job.voxel_position, face) != &""
			):
				# The face is already dressed — whoever did it, the job is
				# moot and its delivered material refunds.
				_colony.complete_pave(job)
				job = null
				state = State.IDLE
				return
	elif _world.is_solid(job.voxel_position):
		# The block is already there — the job is moot.
		_colony.complete_build(job)
		job = null
		state = State.IDLE
		return
	if _fetching:
		_tick_fetching(delta)
	else:
		_tick_delivering(delta)


## The recipe a build job is filling — a floor spec's for a surface
## job, the spec's table entry for a wall, or the canonical wall of its
## material for a job that predates spec keys.
func _build_recipe(build_job: ColonyJob) -> Dictionary:
	if build_job.build_spec == &"conduit":
		# Conduit isn't a floor spec — it wires a wall's face with one
		# coil of copper.
		return {DropItem.Form.WIRE: Colony.CONDUIT_WIRE_CM3}
	if build_job.face_dir != Vector3i.ZERO:
		return BlockRegistry.floor_recipe(build_job.build_spec)
	var recipe := BlockRegistry.build_recipe(build_job.build_spec)
	if recipe.is_empty():
		recipe = BlockRegistry.wall_recipe(build_job.material)
	return recipe


## True when a build job has gathered every form and volume its wall's
## recipe calls for — impossible until a material is committed.
func _wall_full(build_job: ColonyJob) -> bool:
	var recipe := _build_recipe(build_job)
	if recipe.is_empty():
		return false
	for form in recipe:
		if int(build_job.delivered.get(form, 0)) < int(recipe[form]):
			return false
	return true


## What the wall's recipe is still missing once the carried load arrives:
## form → cm³, forms already covered left out.
func _wall_need(build_job: ColonyJob, load: Array[DropItem] = []) -> Dictionary:
	var covered := build_job.delivered.duplicate()
	for item in load:
		covered[item.form] = int(covered.get(item.form, 0)) + item.volume
	var need := {}
	var recipe := _build_recipe(build_job)
	for form in recipe:
		var missing := int(recipe[form]) - int(covered.get(form, 0))
		if missing > 0:
			need[form] = missing
	return need


## Fetching: at the pile, take wall material into the carried load until
## the load, the shovel budget or the remaining need runs out — then head
## back.
func _tick_fetching(delta: float) -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null:
		_advance_build_goal()
		return
	var need := _wall_need(job, _carried)
	if need.is_empty():
		# The load already in hand finishes the recipe — deliver it.
		_advance_build_goal()
		return
	var got := _keep_liftable(
		pile.take_wall(
			job.material,
			need,
			mini(carry_cap() - _carried_volume(), _budget_cm3()),
			maxf(_drag_kg() - _carried_mass(), 0.0)
		),
		pile
	)
	var taken := 0
	for item in got:
		taken += item.volume
	_carried.append_array(got)
	_spend_budget(taken)
	_colony.remove_pile_if_empty(_goal_voxel)
	if (
		_carried_volume() >= carry_cap()
		or pile.wall_need_volume(job.material, need) <= 0
		or (got.is_empty() and _carried_volume() > 0)
	):
		# Loaded, this pile has nothing more the recipe wants, or the
		# rest won't fit this trip.
		_advance_build_goal()
	elif got.is_empty() and _budget_cm3() >= carry_cap():
		# A full shovel budget and still nothing takeable — the pile's
		# needed items are all heavier than a unit can carry.
		_give_up_on_job()


## Delivering: at the site, each carried item of the ordered material
## joins the wall — whole items when their form's recipe slot fits them,
## loose material split down to exactly what's missing. Items of a form
## the recipe doesn't want stay in hand and get dropped beside the site.
## Fetch again until the recipe is complete, then place the block.
func _tick_delivering(delta: float) -> void:
	var here := _standing_voxel()
	if (
		here == job.voxel_position
		or here + Vector3i.UP == job.voxel_position
		or not _can_clear_from(global_position, job.voxel_position)
	):
		state = State.MOVING
		return
	var recipe := _build_recipe(job)
	var kept: Array[DropItem] = []
	for item in _carried:
		var missing := (
			int(recipe.get(item.form, 0))
			- int(job.delivered.get(item.form, 0))
		)
		if item.material != job.material or missing <= 0:
			kept.append(item)
			continue
		var part := item.volume
		if item.form == DropItem.Form.LOOSE:
			part = mini(missing, item.volume)
		elif missing < item.volume:
			# A solid item that won't fit its slot can't join the wall.
			kept.append(item)
			continue
		job.delivered[item.form] = int(job.delivered.get(item.form, 0)) + part
		var escrowed := DropItem.new(item.material, item.form, part)
		escrowed.species = item.species
		# The item's own quality and nutrition ride the escrow — a
		# studied specimen comes back the thing it was, and a bed kit
		# keeps the craft roll its furnish reads.
		escrowed.quality = item.quality
		escrowed.nutrition = item.nutrition
		escrowed.spec = item.spec
		escrowed.wear = item.wear
		job.components.append(escrowed)
		item.volume -= part
		if item.volume > 0:
			kept.append(item)
	_carried = kept
	if not _wall_full(job):
		_advance_build_goal()
		return
	if job.face_dir != Vector3i.ZERO:
		# A face job delivers to a face, not a block — nothing to hang,
		# nobody to bury. Leftovers drop; the covering or line goes on.
		for item in _carried:
			_colony._drop_item(item, job.voxel_position)
		_carried.clear()
		if job.build_spec == &"conduit":
			_colony.complete_conduit(job)
		else:
			_colony.complete_pave(job)
		job = null
		state = State.IDLE
		return
	if not _colony.would_be_supported(job.voxel_position):
		# Nothing to hang the block from — the job suspends until an
		# adjacent placement anchors it. The escrowed material stays in
		# the job; only the loose carry drops where the unit stands.
		_colony.suspend_build_job(job)
		abandon_job()
		return
	# Leftovers the recipe didn't want — drop them beside the site
	# rather than burying them in the block.
	for item in _carried:
		_colony._drop_item(item, job.voxel_position)
	_carried.clear()
	var is_door := BlockRegistry.spec_is_door(job.build_spec)
	if not is_door:
		# A unit in the voxel would be buried — a capsule spans its
		# standing voxel and the one above, so both count. Idle occupants
		# get shoved aside like path-blockers; one that can't move (or
		# won't leave in time) fails the job rather than getting buried.
		# A door is hung, not placed — nobody gets buried by it.
		var blocked := false
		for u in _colony.units:
			if not _occupies_voxel(u, job.voxel_position):
				continue
			if u == self:
				# Head inside the target — back out to a proper work spot.
				state = State.MOVING
				return
			if u.state == State.IDLE:
				u.yield_to(self)
				if u.state != State.YIELDING:
					# Nowhere to step — the voxel can't be cleared.
					_give_up_on_job()
					return
			blocked = true
		if blocked:
			_evict_elapsed += delta
			if _evict_elapsed > 4.0:
				_give_up_on_job()
			return
	_evict_elapsed = 0.0
	# Push whatever piled up in the voxel while hauling into the neighbours.
	while _colony.item_pile_at(job.voxel_position) != null:
		if _colony.move_pile_item(job.voxel_position) == null:
			_give_up_on_job()
			return
	if is_door:
		if _world.get_block(job.voxel_position + Vector3i.UP) != BlockRegistry.Block.AIR:
			# Something filled the doorway's headroom — the door can't
			# hang. Return the escrowed material and let it retry when
			# the opening's clear again.
			_colony.suspend_build_job(job)
			abandon_job()
			return
		# The doorway hangs open air — the building record goes up over
		# the cell and the offcut falls out in complete_build.
		_colony.complete_build(job)
		job = null
		state = State.IDLE
		return
	if not _world.place(job.voxel_position, job.block_id):
		_colony.release_job(job)
		abandon_job()
		return
	_colony.complete_build(job)
	job = null
	state = State.IDLE


## Picks the next build-job goal: carry the load to the site if the unit
## holds any, else fetch from the next-closest pile that has what the
## recipe still needs. With a full wall and no load the delivery tick
## takes it from there.
func _advance_build_goal() -> void:
	if _carried_volume() > 0 or _wall_full(job):
		_fetching = false
		_goal_voxel = job.voxel_position
	else:
		var need := _wall_need(job)
		var next := _colony.nearest_wall_voxel(
			_standing_voxel(), job.material, need, allowed_area
		)
		if next == Vector3i.MAX:
			# The material was ordered — nothing usable anywhere means
			# the wall waits for its recipe, not for a different material.
			_give_up_on_job()
			return
		_fetching = true
		_goal_voxel = next
	_note(
		"build goal <- %s (%s)" % [
			_goal_voxel, "fetch" if _fetching else "deliver"
		]
	)
	_path.clear()
	state = State.MOVING


## Foraging: strip a ripe bush's yield — a short work like a chop, but
## the plant stays and regrows rather than coming down.
func _tick_foraging(delta: float) -> void:
	var root := _colony.plants.bush_at(job.voxel_position)
	if root == Vector3i.MAX:
		# The bush is gone — dug out or built over mid-walk.
		_colony.complete_forage(job)
		job = null
		state = State.IDLE
		return
	if not _can_clear_from(global_position, root):
		state = State.MOVING
		return
	var work := _colony.plants.forage_work(root)
	if work <= 0.0:
		_colony.complete_forage(job)
		job = null
		state = State.IDLE
		return
	job.progress += mining_speed * delta * _work_rate()
	if job.progress < work:
		return
	var bush := job.voxel_position
	_colony.complete_forage(job)
	if job.desperate:
		# Stripped it ourselves — the yield lands in a pile at the bush
		# and the meal starts right here, eating just past the hunger
		# line; what's left stays dropped.
		var meal := ColonyJob.new(ColonyJob.Type.EAT, bush)
		meal.desperate = true
		meal.state = ColonyJob.State.ASSIGNED
		meal.assignee = self
		job = meal
		_eat_budget = 0.0
		_goal_voxel = bush
		state = State.EATING
		return
	job = null
	state = State.IDLE


## Deconstruction: work the building for its seconds, then it comes apart
## — the block leaves terrain and the exact items it was built of drop.
func _tick_deconstructing(delta: float) -> void:
	var building := _colony.building_at(job.voxel_position)
	if building == null:
		# The construction is already gone — the job is moot.
		_colony.complete_deconstruct(job)
		job = null
		state = State.IDLE
		return
	var solid := building.block_id != BlockRegistry.Block.AIR
	if not _can_reach_from(global_position, job.voxel_position, solid):
		state = State.MOVING
		return
	job.progress += delta * _work_rate()
	if job.progress < deconstruct_seconds:
		return
	_colony.complete_deconstruct(job)
	job = null
	state = State.IDLE


## Stripping: scrape the covering off the face the job names — half the
## work of taking a wall apart, and nothing comes back.
func _tick_stripping(delta: float) -> void:
	var face := Flooring.face_index(job.face_dir)
	if face < 0 or _colony.flooring.covering_at(job.voxel_position, face) == &"":
		# The covering's already gone — the job is moot.
		_colony.complete_pave_strip(job)
		job = null
		state = State.IDLE
		return
	if not _can_clear_from(global_position, job.voxel_position):
		state = State.MOVING
		return
	job.progress += delta * _work_rate()
	if job.progress < deconstruct_seconds * 0.5:
		return
	_colony.complete_pave_strip(job)
	job = null
	state = State.IDLE


## Idle fallback before hauling: a unit with a free apparel layer picks
## up a garment it can wear — RimWorld's self-dressing, minus the
## policy table. The dress is an off-board job like the idle haul, so
## pathing and the stuck watchdog work on it unchanged. True when a
## dress job got going.
func _try_dress() -> bool:
	var wearable := func(item: DropItem) -> bool: return wants_garment(item)
	var source := _colony.nearest_forms_voxel(
		_standing_voxel(), [DropItem.Form.GARMENT],
		Vector3i.MAX, 0.0, {}, {DropItem.Form.GARMENT: wearable}, allowed_area
	)
	if source == Vector3i.MAX:
		return false
	# A pile that recently beat a dress attempt goes quiet for a while —
	# the haul blacklist doubles as the self-errand one.
	var record: Dictionary = _haul_blacklist.get(source, {})
	if not record.is_empty() and (
		_colony.game_msec() - int(record.get("at", 0))
		< _colony.retry_delay_msec(record)
	):
		return false
	job = ColonyJob.new(ColonyJob.Type.DRESS, source)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	# Self-issued, like the idle haul — a give-up blacklists the pile
	# rather than reposting the errand.
	job.desperate = true
	_note("idle dress " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_goal_voxel = source
	if not _repath_to_job():
		_give_up_on_job()
	else:
		state = State.MOVING
	return true


## Dressing work: lift a garment the unit can wear out of the pile and
## put it on — one garment per trip, the simplest self-errand there is.
func _tick_dress(delta: float) -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	_clear_budget += clearing_speed * delta * _work_rate()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null or _budget_cm3() < DropItem.GARMENT_CM3:
		return
	var got := pile.take_up_to(
		DropItem.GARMENT_CM3,
		func(item: DropItem) -> bool:
			return item.form == DropItem.Form.GARMENT and wants_garment(item)
	)
	_colony.remove_pile_if_empty(_goal_voxel)
	if got.is_empty():
		# The pile's garments all collide with something worn, or are
		# gone — nothing here for this unit.
		_give_up_on_job()
		return
	var garment: DropItem = got[0]
	_spend_budget(garment.volume)
	# An upgrade swap: the displaced garments come off and land at the
	# unit's feet — the pile they make is what a repair or salvage bill
	# works over.
	for conflict in garment_conflicts(garment):
		strip_garment(conflict)
		_colony._drop_item(conflict, _standing_voxel())
	if wear_garment(garment):
		job = null
		state = State.IDLE
	else:
		# Another garment claimed a layer mid-walk — put it back.
		_colony._drop_item(garment, _standing_voxel())
		_give_up_on_job()


## Idle fallback: with no designated job to claim, haul loose items to a
## stockpile — the nearest pile that isn't already in one, to the nearest
## stockpile tile with room. The haul is an off-board job so pathing and
## the stuck watchdog work on it unchanged.
func _try_start_haul() -> void:
	# Free the hands for the load — a belted unit pockets its tools in
	# the holsters; one without a belt hauls at half capacity, or not
	# at all with both hands full.
	_stow_for_work()
	if carry_cap() <= 0:
		return
	var source := _colony.nearest_haulable_pile(
		_standing_voxel(), _haul_blacklist, allowed_area
	)
	if source == Vector3i.MAX:
		return
	var pile := _colony.item_pile_at(source)
	var mats := _haulable_materials(pile, source)
	if (
		_colony.nearest_stockpile_with_room(
			_standing_voxel(), 1, _haul_blacklist, mats, allowed_area,
			_haulable_forms(pile, source)
		) == Vector3i.MAX
	):
		return
	job = ColonyJob.new(ColonyJob.Type.HAUL, source)
	job.state = ColonyJob.State.ASSIGNED
	job.assignee = self
	_note("idle haul " + _job_label())
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_fetching = true
	_goal_voxel = source
	if not _repath_to_job():
		_give_up_on_job()
	else:
		state = State.MOVING


## Hauling work: load items off the source pile, carry them to a stockpile.
func _tick_hauling(delta: float) -> void:
	if _fetching:
		_tick_haul_fetch(delta)
	else:
		_tick_haul_deliver()


## The materials a pile wants moved: everything in it, or — when it sits
## on a stockpile tile — only what the tile's filter rejects, so the rest
## stays put.
func _haulable_materials(pile: ItemPile, voxel: Vector3i) -> Array:
	if not _colony.is_stockpile(voxel):
		return pile.takeable_materials()
	var rejected: Array = []
	for item in pile.items:
		if (
			not item.forbidden
			and not _colony.stockpile_admits_item(voxel, item)
			and not rejected.has(item.material)
		):
			rejected.append(item.material)
	return rejected


## The item forms a pile wants moved — the destination query's
## goods-class filter: a crate among the haulables is only ever served
## by a warehouse cell.
func _haulable_forms(pile: ItemPile, voxel: Vector3i) -> Array:
	var forms: Array = []
	var on_zone := _colony.is_stockpile(voxel)
	for item in pile.items:
		if item.forbidden or forms.has(int(item.form)):
			continue
		if on_zone and _colony.stockpile_admits_item(voxel, item):
			continue
		forms.append(int(item.form))
	return forms


## The filter for what this fetch may pick up: the destination has to
## store it, and an eviction haul takes only what the source tile rejects.
func _haul_fetch_admits(pile: ItemPile, voxel: Vector3i, sp: Vector3i) -> Callable:
	return func(item: DropItem) -> bool:
		return (
			_colony.stockpile_admits_item(sp, item)
			and (
				not _colony.is_stockpile(voxel)
				or not _colony.stockpile_admits_item(voxel, item)
			)
		)


## At the source pile: load items until the load reaches what fits in the
## destination stockpile (capacity-limited — big piles take several trips).
func _tick_haul_fetch(delta: float) -> void:
	_stow_for_work()
	var pile := _colony.item_pile_at(_goal_voxel)
	if pile == null or pile.items.is_empty():
		if _carried_volume() > 0:
			_set_haul_destination()
			return
		# The pile was emptied before we arrived — find another one.
		var next := _colony.nearest_haulable_pile(
			_standing_voxel(), _haul_blacklist, allowed_area
		)
		if next == Vector3i.MAX:
			job = null
			state = State.IDLE
		else:
			_goal_voxel = next
			_path.clear()
			state = State.MOVING
		return
	var mats := _haulable_materials(pile, _goal_voxel)
	var forms := _haulable_forms(pile, _goal_voxel)
	var sp := Vector3i.MAX
	var room := 0
	var admit := Callable()
	while true:
		sp = _colony.nearest_stockpile_with_room(
			_standing_voxel(), 1, _haul_blacklist, mats, allowed_area,
			forms
		)
		if sp == Vector3i.MAX:
			# No stockpile admits this pile's contents — the haul is
			# impossible for now.
			_give_up_on_job()
			return
		room = _colony.voxel_capacity(sp) - _colony.voxel_fill(sp)
		var base_admit := _haul_fetch_admits(pile, _goal_voxel, sp)
		admit = func(item: DropItem) -> bool:
			return (
				base_admit.call(item)
				and (
					item.form == DropItem.Form.LOOSE
					or item.volume <= room
				)
			)
		# A tile is only useful when it can hold at least one admissible
		# item — a solid needs its whole volume, while loose material
		# shaves down to whatever room is left. A nearly-full tile that
		# can't fit the smallest boulder would stall the take loop
		# forever, so skip it.
		var takeable := false
		for item in pile.items:
			if (
				not item.forbidden
				and admit.call(item)
				and (item.form == DropItem.Form.LOOSE or item.volume <= room)
			):
				takeable = true
				break
		if takeable:
			break
		var record: Dictionary = _haul_blacklist.get(sp, {})
		record["at"] = _colony.game_msec()
		record["n"] = int(record.get("n", 0)) + 1
		_haul_blacklist[sp] = record
	var want_cap := mini(carry_cap(), room)
	var want := want_cap - _carried_volume()
	_clear_budget += clearing_speed * delta * _work_rate()
	while want > 0 and _budget_cm3() > 0:
		var got := _keep_liftable(
			pile.take_up_to(
				mini(want, _budget_cm3()), admit, false,
				maxf(_drag_kg() - _carried_mass(), 0.0)
			),
			pile
		)
		if got.is_empty():
			break
		var volume := 0
		for item in got:
			volume += item.volume
		_carried.append_array(got)
		_spend_budget(volume)
		want = want_cap - _carried_volume()
	# A crate never answers a volume-bounded take — it's dragged, not
	# carried: the destination admits it, the mass limit says whether
	# this unit can.
	for i in range(pile.items.size() - 1, -1, -1):
		var item := pile.items[i]
		if item.form != DropItem.Form.CRATE or not admit.call(item):
			continue
		if _carried_mass() + item.mass_kg() > _drag_kg():
			continue
		_carried.append(pile.take_spec_item(DropItem.Form.CRATE, item.spec))
	_colony.remove_pile_if_empty(_goal_voxel)
	var more := false
	for item in pile.items:
		if (
			not item.forbidden
			and admit.call(item)
			and (item.form == DropItem.Form.LOOSE or item.volume <= want)
		):
			more = true
			break
	if _carried.is_empty() and not more:
		# Nothing admissible fits the remaining trip room — a solid too
		# big for the budget still counts, since the budget accrues.
		_give_up_on_job()
		return
	if _carried_volume() >= want_cap or (not more and _carried_volume() > 0):
		_set_haul_destination()


## Pours carried items into [param voxel]'s pile until it is full — loose
## items split to fit the remaining room, solids move only whole. The
## carried list keeps whatever would not fit — and whatever the tile's
## filter stopped admitting while the load was in flight.
func _pour_carried_into(voxel: Vector3i) -> void:
	for i in range(_carried.size() - 1, -1, -1):
		var item: DropItem = _carried[i]
		if (
			_colony.is_stockpile(voxel)
			and not _colony.stockpile_admits_item(voxel, item)
		):
			continue
		var room := _colony.voxel_capacity(voxel) - _colony.voxel_fill(voxel)
		if item.form == DropItem.Form.LOOSE:
			var pour := mini(item.volume, room)
			if pour > 0:
				var poured := DropItem.new(item.material, item.form, pour)
				poured.species = item.species
				_colony._deposit_item(poured, voxel)
				item.volume -= pour
		elif item.volume <= room:
			# A solid moves whole — the item itself, not a copy, so
			# spec, wear, quality and a crate's contents survive.
			_carried.remove_at(i)
			_colony._deposit_item(item, voxel)
			continue
		if item.volume <= 0:
			_carried.remove_at(i)


## At the stockpile: unload the carried items into its voxel.
func _tick_haul_deliver() -> void:
	if not _can_clear_from(global_position, _goal_voxel):
		state = State.MOVING
		return
	# The tile may have filled while we walked — pour what still fits and
	# take the rest elsewhere rather than force-dumping the whole load.
	_pour_carried_into(_goal_voxel)
	if _carried.is_empty():
		job = null
		state = State.IDLE
		return
	_set_haul_destination()


## Picks the stockpile tile this haul's load goes to — the nearest with
## room for it that admits at least some of it. With nowhere that fits,
## the job is dropped (and the load with it).
func _set_haul_destination() -> void:
	# A tile qualifies when it can hold the biggest unsplittable item —
	# loose material pours into whatever room is left at delivery, so any
	# nonempty room counts.
	var load := 1
	var mats: Array = []
	var forms: Array = []
	for item in _carried:
		if item.form != DropItem.Form.LOOSE:
			load = maxi(load, item.volume)
		if not mats.has(item.material):
			mats.append(item.material)
		if not forms.has(int(item.form)):
			forms.append(int(item.form))
	var sp := _colony.nearest_stockpile_with_room(
		_standing_voxel(), load, _haul_blacklist, mats, allowed_area,
		forms
	)
	if sp == Vector3i.MAX:
		_give_up_on_job()
		return
	_fetching = false
	_goal_voxel = sp
	_note("haul dest <- %s" % sp)
	_path.clear()
	state = State.MOVING


## A pile on or beside the path is worth a detour when a stockpile can
## take a load — for a packed waypoint that's the nearest tile with room;
## an opportunistic grab passes its own prevalidated [param dest] (near
## the job's goal) and sets [member _detour_opportunistic]. The detour
## borrows _goal_voxel and the path, so the reach rule, repathing and the
## stuck watchdog all keep working on it.
func _start_detour(cell: Vector3i, dest: Vector3i = Vector3i.MAX) -> bool:
	if _detour != Vector3i.MAX:
		return false
	if not Colony.in_area(allowed_area, cell):
		return false
	var record: Dictionary = _haul_blacklist.get(cell, {})
	if not record.is_empty() and (
		_colony.game_msec() - int(record.get("at", 0))
		< _colony.retry_delay_msec(record)
	):
		return false
	var pile := _colony.item_pile_at(cell)
	if pile == null or pile.items.is_empty():
		return false
	if (
		dest == Vector3i.MAX
		and _colony.nearest_stockpile_with_room(
			_standing_voxel(), 1, _haul_blacklist, pile.takeable_materials(),
			allowed_area
		) == Vector3i.MAX
	):
		return false
	_detour = cell
	_detour_return = _goal_voxel
	_detour_return_fetching = _fetching
	_detour_delivering = false
	_detour_opportunistic = dest != Vector3i.MAX
	_detour_dest = dest
	_goal_voxel = cell
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	_note("detour <- pile %s (goal was %s)" % [cell, _detour_return])
	DLog.log("unit %d detours to pile %s (job %s)" % [_sim_id, cell, _detour_return])
	return true


## Opportunistic haul scan, run when a fresh clear path is found: walk
## the route's cells for a pile that wants hauling, and when a stockpile
## that admits its goods sits near the job's goal, start a detour for it
## — hauling throughput from a trip that happens anyway. Returns true
## once a detour has taken the goal; the caller repaths onto it.
func _try_opportunistic_detour() -> bool:
	if not _can_opportunistic():
		return false
	var reach := _detour_reach()
	# Cells off the route's own steps count as "passed by" — a generalist
	# strays a cell either side; a specialist only takes what the path
	# runs straight through.
	var ring := 0 if specialize else 1
	var seen := {}
	for i in range(_path_index, _path.size()):
		var step := Vector3i(_path[i].floor())
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				for dz in range(-ring, ring + 1):
					var cell := step + Vector3i(dx, dy, dz)
					if seen.has(cell):
						continue
					seen[cell] = true
					if _opportunistic_detour_at(cell, reach):
						return true
	return false


## Whether the unit may take an opportunistic haul detour at all: it must
## be empty-handed on real work. A haul job's whole purpose is hauling —
## a mid-route search can't beat its own assignment — and a unit on a
## self-issued errand to food or bed isn't to be waylaid.
func _can_opportunistic() -> bool:
	if _detour != Vector3i.MAX or job == null or not _carried.is_empty():
		return false
	if job.desperate:
		return false
	match job.type:
		ColonyJob.Type.HAUL, ColonyJob.Type.REST, ColonyJob.Type.EAT:
			return false
	return true


## How far from the job's goal a stockpile may sit for a grab to count
## as "on the way" — an industrious unit ranges further to grab one;
## [member specialize] caps the radius.
func _detour_reach() -> float:
	var reach := DETOUR_GOAL_REACH * _facet_scale(&"activity_level")
	if specialize:
		reach *= DETOUR_SPECIALIST_REACH
	return reach


## The pile at [param cell] is an opportunistic grab when it wants
## hauling (nearest_haulable_pile's eligibility — a pile whose own
## stockpile tile admits everything is already home), it isn't the
## goal's fetch target, it isn't blacklisted, and a stockpile admitting
## its haulable materials has room within [param reach] of the goal.
## On success the detour starts.
func _opportunistic_detour_at(cell: Vector3i, reach: float) -> bool:
	if cell == _goal_voxel:
		return false
	var pile := _colony.item_pile_at(cell)
	if pile == null or pile.items.is_empty():
		return false
	if _colony.is_stockpile(cell) and not _colony._pile_rejected_here(cell):
		return false
	var record: Dictionary = _haul_blacklist.get(cell, {})
	if not record.is_empty() and (
		_colony.game_msec() - int(record.get("at", 0))
		< _colony.retry_delay_msec(record)
	):
		return false
	var mats := _haulable_materials(pile, cell)
	if mats.is_empty():
		return false
	var sp := _colony.nearest_stockpile_with_room(
		_goal_voxel, 1, _haul_blacklist, mats, allowed_area,
		_haulable_forms(pile, cell)
	)
	if sp == Vector3i.MAX:
		return false
	if Vector3(sp).distance_to(Vector3(_goal_voxel)) > reach:
		return false
	return _start_detour(cell, sp)


## The stockpile a detour's load goes to: an opportunistic grab delivers
## only to the tile it was validated against — picked for sitting near
## the job's goal, so a substitute could drag the unit far off route —
## while a blocking pile takes the nearest tile with room.
func _detour_stockpile(pile: ItemPile) -> Vector3i:
	if _detour_opportunistic:
		return _detour_dest if _detour_dest_ok(pile) else Vector3i.MAX
	return _colony.nearest_stockpile_with_room(
		_standing_voxel(), 1, _haul_blacklist, pile.takeable_materials(),
		allowed_area, _haulable_forms(pile, pile.voxel_position)
	)


## What a detour may lift from its pile: an opportunistic grab takes only
## what a real haul would move — a pile on a stockpile tile keeps what
## its filter admits — while a blocking pile comes out wholesale.
func _detour_admits(pile: ItemPile, sp: Vector3i) -> Callable:
	if _detour_opportunistic:
		return _haul_fetch_admits(pile, _detour, sp)
	return func(item: DropItem) -> bool:
		return (
			_colony.stockpile_admits_item(sp, item)
			and not item.forbidden
		)


## Whether the tile an opportunistic grab was validated against still
## takes this pile — the zone removed, filled, or refiltered while the
## unit walked over.
func _detour_dest_ok(pile: ItemPile) -> bool:
	if not _colony.is_stockpile(_detour_dest):
		return false
	if _colony.voxel_fill(_detour_dest) >= _colony.voxel_capacity(_detour_dest):
		return false
	var admit := _detour_admits(pile, _detour_dest)
	for item in pile.items:
		if not item.forbidden and admit.call(item):
			return true
	return false


## Reached the detour's current goal: shovel the obstructing pile into the
## carried load, or unload at the stockpile and resume the real job.
func _detour_arrived() -> void:
	if not _detour_delivering:
		var pile := _colony.item_pile_at(_detour)
		var sp := Vector3i.MAX
		if pile != null and not pile.items.is_empty():
			sp = _detour_stockpile(pile)
		if sp == Vector3i.MAX:
			# Someone else cleared the pile, the opportunistic target
			# soured, or nowhere has room after all — either way, back to
			# the job's own path.
			_note("detour: pile %s gone or no stockpile" % _detour)
			_end_detour()
			return
		var room := _colony.voxel_capacity(sp) - _colony.voxel_fill(sp)
		var base_admit := _detour_admits(pile, sp)
		var admit := func(item: DropItem) -> bool:
			return (
				base_admit.call(item)
				and (
					item.form == DropItem.Form.LOOSE
					or item.volume <= room
				)
			)
		var want := mini(carry_cap(), room) - _carried_volume()
		if want > 0:
			_carried.append_array(
				_keep_liftable(
					pile.take_up_to(
						want, admit, false,
						maxf(_drag_kg() - _carried_mass(), 0.0)
					),
					pile
				)
			)
			_colony.remove_pile_if_empty(_detour)
		if _carried.is_empty():
			# Nothing came out — the stockpile's room is smaller than the
			# pile's smallest admitted item (a near-full tile still passes
			# `with_room` on a single cm³), or a filter flipped mid-walk.
			# Same handling as an unreachable detour: blacklist the pile so
			# the movement loop shoves it aside instead of re-asking.
			_note("detour: nothing grabbable at %s" % _detour)
			_fail_detour()
			return
		_note("detour: grabbed %dcm3, deliver to %s" % [_carried_volume(), sp])
		_detour_delivering = true
		_goal_voxel = sp
		_path.clear()
		_stuck_elapsed = 0.0
		_best_goal_distance = INF
		if not _repath_to_job():
			_fail_detour()
		return
	_pour_carried_into(_goal_voxel)
	if _carried.is_empty():
		_end_detour()
		return
	# The tile filled while we walked — retarget the leftovers instead of
	# overfilling it and kicking off a spill cascade.
	_note("detour: %dcm3 wouldn't fit %s, retargeting" % [_carried_volume(), _goal_voxel])
	_set_haul_destination()


## Detour finished: restore the job's own goal and repath to it.
func _end_detour() -> void:
	_detour = Vector3i.MAX
	_detour_delivering = false
	_detour_opportunistic = false
	_detour_dest = Vector3i.MAX
	_goal_voxel = _detour_return
	_fetching = _detour_return_fetching
	_detour_return = Vector3i.ZERO
	_note("detour done: goal %s fetching=%s" % [_goal_voxel, _fetching])
	_path.clear()
	_stuck_elapsed = 0.0
	_best_goal_distance = INF
	if not _repath_to_job():
		_give_up_on_job()


## The detour's current goal proved unreachable: blacklist it, drop the
## load where the unit stands and go back to the job's own path — the pile
## it was clearing is dealt with by a shove instead.
func _fail_detour() -> void:
	var record: Dictionary = _haul_blacklist.get(_goal_voxel, {})
	record["at"] = _colony.game_msec()
	record["n"] = int(record.get("n", 0)) + 1
	_haul_blacklist[_goal_voxel] = record
	for item in _carried:
		_colony._drop_item(item, _standing_voxel())
	_carried.clear()
	_end_detour()


## Asks this unit to step aside for [param pusher] — only idle units can be
## shoved; a busy unit is already going somewhere. The unit walks to a
## standable neighbour that's off the pusher's path and unoccupied, then
## returns to idle. If no such spot exists it simply stays put and the
## pusher's stuck watchdog deals with the blockage.
func yield_to(pusher: Unit) -> void:
	if state != State.IDLE:
		return
	DLog.log("unit %d yields to %d at %s" % [_sim_id, pusher._sim_id, _standing_voxel()])
	var pusher_cells := {
		pusher._standing_voxel(): true,
		pusher._goal_voxel: true,
	}
	for i in range(pusher._path_index, pusher._path.size()):
		pusher_cells[Vector3i(pusher._path[i].floor())] = true
	var occupied := {}
	for unit in _colony.units:
		occupied[unit._standing_voxel()] = true
	var here := _standing_voxel()
	var candidates: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var spot := here + Vector3i(dx, dy, dz)
				if (
					_is_standable(spot)
					and _colony.voxel_fill(spot) <= 0
					and not occupied.has(spot)
				):
					candidates.append(spot)
	# Prefer spots off the pusher's path, then farthest from the pusher.
	var from := pusher.global_position
	candidates.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			var sa := Vector3(a).distance_squared_to(from) - (1000.0 if pusher_cells.has(a) else 0.0)
			var sb := Vector3(b).distance_squared_to(from) - (1000.0 if pusher_cells.has(b) else 0.0)
			return sa > sb
	)
	for spot in candidates:
		var path := _world.find_path(here, spot)
		if path.is_empty():
			continue
		_path = path
		_path_index = 0
		_yield_elapsed = 0.0
		state = State.YIELDING
		return


## Sidestepping: follow the yield path, then go back to idle. A short
## timeout covers the case where the spot can't actually be reached.
func _tick_yielding(delta: float) -> void:
	_yield_elapsed += delta
	if _path_index >= _path.size() or _yield_elapsed > 2.0:
		state = State.IDLE
		return
	var waypoint := _path[_path_index]
	var to_waypoint := waypoint - global_position
	var flat_distance := Vector2(to_waypoint.x, to_waypoint.z).length()
	# Same overshoot guard as _tick_moving: the radius has to cover one
	# tick's travel or a fast clock makes the unit orbit the waypoint.
	if flat_distance < maxf(0.35, move_speed * delta):
		_path_index += 1
		return
	var direction := Vector3(to_waypoint.x, 0.0, to_waypoint.z).normalized()
	var crawl := minf(
		_colony.traversal_mult(Vector3i(waypoint.floor())),
		_colony.traversal_mult(_standing_voxel())
	)
	velocity.x = direction.x * _move_speed() * crawl
	velocity.z = direction.z * _move_speed() * crawl
	if _grounded and (to_waypoint.y > 0.6 or _blocked_horiz):
		_want_jump = true


## True when the current goal voxel's face is reachable from where the
## unit stands — mining requires a solid target, everything else a
## non-solid one; a unit can't build the block it's standing in.
## True when any part of [param unit]'s capsule intersects [param voxel].
## The capsule is 1.8 m tall, so a unit always spans its feet voxel and the
## head voxel above it — checking only the standing voxel misses burials.
## True when this unit's capsule fills [param voxel_position] — feet voxel
## or head voxel. Growth uses it to avoid growing a tree into a unit.
func occupies(voxel_position: Vector3i) -> bool:
	return _occupies_voxel(self, voxel_position)


static func _occupies_voxel(u: Unit, voxel: Vector3i) -> bool:
	var bottom := (u.global_position - Vector3(0.0, 0.9, 0.0)).floor()
	var top := (u.global_position + Vector3(0.0, 0.9, 0.0)).floor()
	return (
		int(bottom.x) == voxel.x
		and int(bottom.z) == voxel.z
		and voxel.y >= int(bottom.y)
		and voxel.y <= int(top.y)
	)


func _goal_in_reach() -> bool:
	if not _grounded:
		# Reach opens mid-climb or mid-hop before the unit lands — don't
		# start work (or shortcut pathing) from the air; a falling unit
		# sinks out of reach and ping-pongs between states instead.
		return false
	if _detour != Vector3i.MAX:
		return _can_clear_from(global_position, _goal_voxel)
	if job.type == ColonyJob.Type.REST:
		# The unit sleeps *in* the bed — either cell of its footprint.
		return (
			_rest_bed != null
			and _rest_bed.footprint.has(_standing_voxel())
		)
	if job.type == ColonyJob.Type.MINE and not _fetching:
		return _can_mine(job.voxel_position)
	if job.type == ColonyJob.Type.CHOP and not _fetching:
		return _can_reach_from(
			global_position, job.voxel_position, _world.is_solid(job.voxel_position)
		)
	if job.type == ColonyJob.Type.DECONSTRUCT:
		return _can_reach_from(
			global_position, job.voxel_position, _world.is_solid(job.voxel_position)
		)
	if job.animal != null:
		# The goal is a live animal — quarry or combat target — and in
		# reach means inside melee range.
		return (
			is_instance_valid(job.animal)
			and not job.animal.dead
			and global_position.distance_to(job.animal.global_position)
				<= Animal.MELEE_RANGE
		)
	var here := _standing_voxel()
	if job.type == ColonyJob.Type.ORDER:
		if job.structure != null:
			# A wreck order reaches the construction from beside it —
			# the reach rule a wall's solidity dictates.
			return _can_reach_from(
				global_position, job.voxel_position,
				_world.is_solid(job.voxel_position)
			)
		# A move order wants the unit ON its post — an adjacent stand
		# only counts when the post itself can't be stood in.
		return (
			here == job.voxel_position
			or (
				not _is_standable(job.voxel_position)
				and _can_clear_from(global_position, _goal_voxel)
			)
		)
	if (
		(
			job.type == ColonyJob.Type.BUILD
			or job.type == ColonyJob.Type.CRAFT
			or job.type == ColonyJob.Type.REFUEL
			or job.type == ColonyJob.Type.BUTCHER
			or job.type == ColonyJob.Type.BURN
			or job.type == ColonyJob.Type.REPAIR
			or job.type == ColonyJob.Type.FIREFIGHT
		)
		and not _fetching
		and (here == job.voxel_position or here + Vector3i.UP == job.voxel_position)
	):
		return false
	return _can_clear_from(global_position, _goal_voxel)


func _apply_motion(delta: float) -> void:
	if _world.sim == null:
		# No kinematic body left — without DelveSim the unit holds still.
		return
	_apply_sim_motion(delta)


## Sim-driven motion: the intended velocity goes to DelveSim, which resolves
## it against voxel occupancy, pile fill heights and other units — the same
## job move_and_slide did, but without a physics body, and identically when
## no scene is instantiated. The node's transform follows the sim position
## verbatim; all position queries keep working.
func _apply_sim_motion(delta: float) -> void:
	# External teleports (tests, future tools) write global_position —
	# forward them into the sim or the body would snap back next step.
	var sim_pos: Vector3 = _world.sim.unit_pos(_sim_id)
	if global_position.distance_squared_to(sim_pos) > 0.0025:
		DLog.log("unit %d teleported %s -> %s" % [_sim_id, sim_pos, global_position])
		_world.sim.unit_register(_sim_id, global_position)
	var heading := Vector3(velocity.x, 0.0, velocity.z)
	if (
		state == State.IDLE
		or state == State.WORKING
		or state == State.RECREATING
	):
		heading = heading.move_toward(Vector3.ZERO, move_speed)
	var res: Dictionary = _world.sim.unit_step(
		_sim_id, heading, jump_speed if _want_jump else 0.0, gravity, delta,
		climb_speed if _want_descend else 0.0
	)
	_want_jump = false
	_want_descend = false
	global_position = res["pos"]
	_grounded = res["grounded"]
	_blocked_horiz = res["blocked"]
	velocity = Vector3(heading.x, res["vel_y"], heading.z)
	# Foot traffic wears the grass underfoot — one wear per ground cell
	# entered, so a unit standing still never grinds cover down.
	if _grounded and _colony.grass != null:
		var under := Vector3i(
			floori(global_position.x),
			floori(global_position.y - 0.901),
			floori(global_position.z)
		)
		if under != _trample_cell:
			_trample_cell = under
			_colony.grass.trample(under)
	var hit_unit: int = res["hit_unit"]
	if (
		hit_unit >= 0
		and state == State.MOVING
		and job != null
		and heading.length_squared() > 0.01
	):
		var blocker := instance_from_id(hit_unit) as Unit
		if blocker != null and blocker.state == State.IDLE:
			blocker.yield_to(self)


## True when the unit can mine [param voxel_position] from where it stands.
func _can_mine(voxel_position: Vector3i) -> bool:
	return _can_mine_from(global_position, voxel_position)


## The mining rule: the unit's centre must be within [member mine_reach] of
## the block's nearest face, and no other solid voxel may sit between them —
## blocks behind, above or below another block relative to the unit are out.
func _can_mine_from(from: Vector3, voxel_position: Vector3i) -> bool:
	return _can_reach_from(from, voxel_position, true)


## Same reach rule for a non-solid target — a voxel holding an item pile.
## The ray passes through it, so the packed-cell march alone checks that no
## solid or packed voxel sits between the unit and the pile.
func _can_clear_from(from: Vector3, voxel_position: Vector3i) -> bool:
	return _can_reach_from(from, voxel_position, false)


## Shared reach rule: within [member mine_reach] of the voxel's nearest face,
## with no solid or packed voxel in between. For a solid target the face ray
## must also land on the target itself.
func _can_reach_from(from: Vector3, voxel_position: Vector3i, solid_target: bool) -> bool:
	if _world.sim != null:
		return _world.sim.can_reach_from(from, voxel_position, solid_target, mine_reach)
	var nearest := from.clamp(Vector3(voxel_position), Vector3(voxel_position) + Vector3.ONE)
	var to_face := nearest - from
	var distance := to_face.length()
	if distance > mine_reach:
		return false
	if distance < 0.01:
		return true
	var direction := to_face / distance
	if solid_target:
		var hit := _world.raycast(from, direction, distance + 0.5)
		if hit == null or hit.position != voxel_position:
			return false
	# A voxel packed full of items occludes like a solid block — this march
	# also catches solid voxels, since is_packed covers both.
	var travelled := 0.0
	while travelled < distance - 0.2:
		var cell := Vector3i((from + direction * travelled).floor())
		if cell != Vector3i(from.floor()) and _colony.is_packed(cell):
			return false
		travelled += 0.25
	return true


func _repath_to_job() -> bool:
	_repath_cooldown = 1.0
	_path.clear()
	_path_index = 0
	if job == null:
		return false

	# Already in reach — standing on a pile beside the goal, say — so no
	# path is needed at all: the next move tick sees the goal in reach
	# and starts work. Skip the spot scan entirely; a pile-hemmed target
	# might offer no spot the pathfinder accepts even from up close.
	if _goal_in_reach():
		_note("repath: already in reach of %s" % _goal_voxel)
		return true
	var start := _standing_voxel()
	if job.type == ColonyJob.Type.REST:
		# The sleeper walks into the bed's own cell — a standable air
		# voxel over the floor the bed sits on.
		_path = _world.find_path(start, _goal_voxel)
		return not _path.is_empty()
	if job.type == ColonyJob.Type.ORDER and job.animal == null and job.structure == null:
		# A move order means ON the post — path to the cell itself, never
		# a work spot beside it: arriving adjacent then re-pathing to the
		# same spot would oscillate forever. An unreachable post fails
		# outright and `_hold_post` holds the spot the unit stands on.
		_path = _world.find_path(start, _goal_voxel)
		return not _path.is_empty()
	var blocked_path := PackedVector3Array()
	# A detour goal is a pile or stockpile tile — always a non-solid target.
	# A chop target is solid once the root is trunk, not while a sapling.
	# A wreck order's wall is solid the same way.
	var solid_target := _detour == Vector3i.MAX and not _fetching and (
		job.type == ColonyJob.Type.MINE
		or (
			(
				job.type == ColonyJob.Type.CHOP
				or job.type == ColonyJob.Type.DECONSTRUCT
				or job.type == ColonyJob.Type.REPAIR
				or job.type == ColonyJob.Type.FIREFIGHT
			)
			and _world.is_solid(job.voxel_position)
		)
		or (
			job.type == ColonyJob.Type.ORDER
			and job.structure != null
			and _world.is_solid(job.voxel_position)
		)
	)
	# A unit can't deliver from inside the block it's building — or from
	# directly beneath it, where its head would be buried. A craft spot is
	# worked from beside it too: standing in the workstation puts dropped
	# products under the unit's feet. Same for repairs — and a wrecked
	# wall can't be swung at from inside its own cell.
	var exclude_self := (
		(
			job.type == ColonyJob.Type.BUILD
			or job.type == ColonyJob.Type.CRAFT
			or job.type == ColonyJob.Type.REFUEL
			or job.type == ColonyJob.Type.BUTCHER
			or job.type == ColonyJob.Type.BURN
			or job.type == ColonyJob.Type.REPAIR
			or job.type == ColonyJob.Type.FIREFIGHT
			or (
				job.type == ColonyJob.Type.ORDER
				and job.structure != null
			)
		)
		and _detour == Vector3i.MAX
		and _goal_voxel == job.voxel_position
	)
	var spots := _work_spots(_goal_voxel, solid_target, exclude_self)
	# Each candidate costs an A* run (~0.05-1.3 ms); a target hemmed in by
	# blocked spots would otherwise burn a path per spot per repath. Cap the
	# attempts — the next repath retries with fresh geometry, and a
	# pile-crossing path is better than none anyway.
	var attempts := 0
	for target in spots:
		if attempts >= MAX_PATH_ATTEMPTS:
			break
		attempts += 1
		var path := _world.find_path(start, target)
		if path.is_empty():
			continue
		if _path_is_clear(path):
			_path = path
			if _try_opportunistic_detour():
				# The route passes a pile worth grabbing — repath onto the
				# detour. If the pile proves unreachable after all, blacklist
				# it (so the next scan doesn't pick it again) and keep the
				# job's own path.
				if not _repath_to_job():
					_fail_detour()
			return true
		if blocked_path.is_empty():
			blocked_path = path
	# No clear route: take a pile-crossing one and shove obstructions aside
	# as they come within reach.
	if not blocked_path.is_empty():
		_path = blocked_path
		_note("repath: pile-crossing path to %s" % _goal_voxel)
		return true
	_note("repath: no route to %s" % _goal_voxel)
	return false


## Voxel the unit currently stands in — the cell holding the feet. On a
## partial pile that's the pile's own cell (the feet are inside it), not
## the cell above.
func _standing_voxel() -> Vector3i:
	return Vector3i(
		floori(global_position.x),
		floori(global_position.y - 0.9 + 0.001),
		floori(global_position.z)
	)


## True when a voxel blocks a unit: solid terrain, packed full of items,
## or choked with enough discrete clutter to wall the cell off.
func _is_blocked(voxel_position: Vector3i) -> bool:
	if _world.sim != null:
		return _world.sim.is_blocked(voxel_position)
	return (
		_world.is_solid(voxel_position)
		or _colony.is_packed(voxel_position)
		or _colony.is_dense_pile(voxel_position)
	)


## Standable for a unit: support at feet level — a blocked cell below, a
## ladder below or in the cell, or a partial pile in the cell whose
## surface the unit stands on — and headroom for the capsule at that
## height. On a pile past a fifth full the head pokes into the cell two
## up, which must be free too.
func _is_standable(voxel_position: Vector3i) -> bool:
	if _world.sim != null:
		return _world.sim.is_unit_standable(voxel_position)
	if _is_blocked(voxel_position) or _is_blocked(voxel_position + Vector3i.UP):
		return false
	var fill := _colony.pile_loose_fill(voxel_position)
	if (
		not _colony.is_flooring(voxel_position + Vector3i.DOWN)
		and not _colony.ladder_at(voxel_position + Vector3i.DOWN)
		and not _colony.ladder_at(voxel_position)
		and fill <= 0
	):
		return false
	return fill <= DropItem.BLOCK_CM3 / 5 or not _is_blocked(
		voxel_position + Vector3i(0, 2, 0)
	)


## True when no path cell runs through a blocked voxel. The voxel astar does
## not know about item fill, so a path can nominally pass through a packed
## pile — the unit shoves those aside on approach, but a clear path is
## preferred when one exists.
func _path_is_clear(path: PackedVector3Array) -> bool:
	for i in range(1, path.size()):
		if _is_blocked(Vector3i(path[i].floor())):
			return false
	return true


## Standable voxels a unit could work [param target] from, nearest first.
## Scans the box of spots whose centre is plausibly in reach — a spot counts
## only if reaching the target from it passes the same check the unit uses.
## A pile cell is a valid spot: the unit stands on the pile's surface, so
## reach is measured from an eye lifted by the fill — a pile ringed by
## other piles is still reachable.
## [param exclude_self] keeps a unit from working from inside the target
## voxel or the one beneath it — a unit can't build the block it stands in,
## and standing directly under it puts its head inside.
func _work_spots(target: Vector3i, solid_target: bool = true, exclude_self: bool = false) -> Array[Vector3i]:
	if _world.sim != null:
		var native: Array[Vector3i] = []
		for spot in _world.sim.work_spots(
			target, global_position, solid_target, exclude_self, mine_reach
		):
			native.append(Vector3i(spot))
		return native
	var reachable: Array[Vector3i] = []
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				var spot := target + Vector3i(dx, dy, dz)
				if exclude_self and (spot == target or spot == target + Vector3i.DOWN):
					continue
				if not _is_standable(spot):
					continue
				var lift := float(_colony.pile_loose_fill(spot)) / DropItem.BLOCK_CM3
				if _can_reach_from(
					Vector3(spot) + Vector3(0.5, 0.9 + lift, 0.5), target, solid_target
				):
					reachable.append(spot)
	var here := global_position
	reachable.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return Vector3(a).distance_squared_to(here) < Vector3(b).distance_squared_to(here)
	)
	return reachable


## Records one decision in the trail — timestamped with game time so a
## single-stepped session lines up with what the player saw.
func _note(text: String) -> void:
	var at := _colony.game_msec() if _colony != null else Time.get_ticks_msec()
	_decisions.append("%d %s" % [at, text])
	while _decisions.size() > DECISION_TRAIL_MAX:
		_decisions.remove_at(0)


## The job as a one-word trail label: "BUILD@(x,y,z)", or "-" when idle.
func _job_label() -> String:
	if job == null:
		return "-"
	if job.face_dir != Vector3i.ZERO:
		var verb := (
			"PAVE" if job.type == ColonyJob.Type.BUILD else "STRIP"
		)
		return "%s %s@%s" % [verb, job.build_spec, job.voxel_position]
	return "%s@%s" % [ColonyJob.Type.keys()[job.type], job.voxel_position]


## The unit's decision trail as text — a snapshot line then the recorded
## decisions, with runs of identical entries collapsed so a per-frame
## flicker reads as "MOVING -> WORKING x40" instead of flooding the log.
func decision_trail() -> String:
	var lines := PackedStringArray()
	lines.append(
		"unit %d pos=%s state=%s job=%s goal=%s fetching=%s carried=%d detour=%s" % [
			_sim_id, _standing_voxel(), State.keys()[state], _job_label(),
			_goal_voxel, _fetching, _carried_volume(), _detour,
		]
	)
	var last := ""
	var count := 0
	for entry in _decisions:
		var text := entry.substr(entry.find(" ") + 1)
		if text == last:
			count += 1
			continue
		if count > 0:
			lines.append("  x%d" % count)
			count = 0
		lines.append("  " + entry)
		last = text
	if count > 0:
		lines.append("  x%d" % count)
	return "\n".join(lines)


func _give_up_on_job() -> void:
	_note("gave up: " + _job_label())
	DLog.log("unit %d gave up: state=%d job=%s pos=%s" % [
		_sim_id, state,
		job.voxel_position if job != null else Vector3i.MAX,
		_standing_voxel(),
	])
	if job != null:
		if job.type == ColonyJob.Type.HAUL or job.type == ColonyJob.Type.DRESS:
			# Whatever we failed to reach goes quiet for a while — longer
			# with each consecutive failure. Dress errands share the haul
			# blacklist — a pile that beat the seek goes quiet either way.
			var record: Dictionary = _haul_blacklist.get(_goal_voxel, {})
			record["at"] = _colony.game_msec()
			record["n"] = int(record.get("n", 0)) + 1
			_haul_blacklist[_goal_voxel] = record
		elif job.type == ColonyJob.Type.EAT:
			_blacklist_food(_goal_voxel)
		if job.desperate:
			# Self-issued — nothing to hand back to the board; just
			# remember the target failed so the next seek tries another.
			# An order isn't a meal — a failed charge blacklists nothing.
			if job.type == ColonyJob.Type.RECREATE:
				_blacklist_rec(_goal_voxel)
			elif job.type != ColonyJob.Type.ORDER:
				_blacklist_food(_goal_voxel)
			elif _order_fighting:
				# A quarry it can't catch — or one that died mid-chase —
				# stops being its fight. The post stays where it was.
				_combat_target = null
			elif _order_voxel != Vector3i.MAX:
				# Ordered onto a cell it physically can't take — a body
				# or a pile in the way. Holding where it got to beats
				# re-minting the same unreachable post every watchdog.
				_order_voxel = _standing_voxel()
		else:
			_colony.release_job(job)
	_job_search_cooldown = 1.5
	abandon_job()
