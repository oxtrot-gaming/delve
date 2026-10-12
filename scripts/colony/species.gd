class_name Species
extends RefCounted

## Species definitions — the runtime-spec seam for wildlife (and the
## colonist's own body norms). Each entry is a plain Dictionary so the
## table can later be loaded from data files without code changes;
## everything derived (corpse volume, butcher yields, capacities) keys
## off these fields.
##
## Fields:
##   label        display name
##   mass_kg      adult body mass — also the corpse's mass, converted to
##                cm³ at flesh density (~1 kg/L) when the animal dies
##   health       hit points; a hunt delivers melee dps against this
##   speed        m/s movement speed
##   diet         herbivore (grazes grass), omnivore (grass + corpses),
##                carnivore (corpses + hunts `hunts` species)
##   temperament  flee (runs when hurt or a threat closes) or fight
##                (turns and attacks its attacker)
##   melee        damage-per-second the animal deals when attacking
##   wound_kind   the wound a hit opens — bite/gore bleed, bruise
##                doesn't (default bite)
##   flee_range   metres at which a flee-temperament animal bolts
##   hunger_days  game-days a full stomach lasts
##   butcher_seconds  base real-seconds a butcher works the corpse —
##                divided by the worker's butchering skill rate
##   yields       fractions of the corpse's mass that butcher into
##                meat / leather / bone; the remainder (plus whatever
##                a clumsy butcher wastes) becomes butchering scraps,
##                which rot into compost — matter is conserved
##   extras       species-unique drops: [{material, cm3, count}]
##   color/scale  presentation for the capsule placeholder
##   carry_kg     carried without penalty; above it a load is dragged
##   drag_kg      the heaviest single load (and total load) the species
##                can move at all — above it, no haul
##   comfort_min/max   the air-temperature band (°C) the species finds
##                comfortable — below the floor a colonist feels cold,
##                above the ceiling hot; deeper past either edge the
##                exposure wounds start accruing. Fur-bearing wildlife
##                runs a cold-shifted band: fur sheds winter but cooks
##                in summer.

const SPECIES: Dictionary = {
	&"colonist": {
		&"label": "colonist",
		&"mass_kg": 75.0,
		&"health": 100.0,
		&"carry_kg": 40.0,
		&"drag_kg": 1500.0,
		&"melee": 8.0,
		# Fists bruise — no bleeding under the skin.
		&"wound_kind": &"bruise",
		# The naked-ape band: freezing underfoot is where discomfort
		# starts, a real summer afternoon is where heat does.
		&"comfort_min": Colony.TEMP_COLD_FLOOR,
		&"comfort_max": 28.0,
	},
	# Small prey herbivore — the wolf's meal and the tutorial hunt.
	&"rabbit": {
		&"label": "rabbit",
		&"mass_kg": 4.0,
		&"health": 15.0,
		&"speed": 5.5,
		&"diet": &"herbivore",
		&"temperament": &"flee",
		&"melee": 0.0,
		&"flee_range": 9.0,
		&"hunger_days": 0.6,
		&"butcher_seconds": 20.0,
		&"yields": {&"meat": 0.45, &"leather": 0.10, &"bone": 0.10},
		&"comfort_min": -15.0, &"comfort_max": 20.0,
		&"color": Color(0.75, 0.70, 0.62),
		&"scale": 0.22,
	},
	# Herd grazer — the standard hunt; antlers are its unique drop.
	&"deer": {
		&"label": "deer",
		&"mass_kg": 120.0,
		&"health": 60.0,
		&"speed": 5.0,
		&"diet": &"herbivore",
		&"temperament": &"flee",
		&"melee": 0.0,
		&"flee_range": 14.0,
		&"hunger_days": 1.0,
		&"butcher_seconds": 90.0,
		&"yields": {&"meat": 0.55, &"leather": 0.12, &"bone": 0.15},
		&"extras": [{&"material": BlockRegistry.Resource_.ANTLER, &"cm3": 3000, &"count": 2}],
		&"comfort_min": -25.0, &"comfort_max": 22.0,
		&"color": Color(0.55, 0.40, 0.25),
		&"scale": 0.85,
	},
	# Omnivore that fights back — a risky hunt; tusks are its drop.
	&"boar": {
		&"label": "boar",
		&"mass_kg": 90.0,
		&"health": 80.0,
		&"speed": 4.5,
		&"diet": &"omnivore",
		&"temperament": &"fight",
		&"melee": 7.0,
		# Tusks gore — a bleeding cut, not a bite.
		&"wound_kind": &"gore",
		&"flee_range": 0.0,
		&"hunger_days": 1.0,
		&"butcher_seconds": 70.0,
		&"yields": {&"meat": 0.50, &"leather": 0.10, &"bone": 0.12},
		&"extras": [{&"material": BlockRegistry.Resource_.TUSK, &"cm3": 1200, &"count": 2}],
		&"comfort_min": -20.0, &"comfort_max": 24.0,
		&"color": Color(0.35, 0.28, 0.22),
		&"scale": 0.6,
	},
	# Carnivore predator — hunts rabbits and deer when hungry, fights
	# when cornered.
	&"wolf": {
		&"label": "wolf",
		&"mass_kg": 45.0,
		&"health": 70.0,
		&"speed": 6.0,
		&"diet": &"carnivore",
		&"temperament": &"fight",
		&"melee": 11.0,
		&"wound_kind": &"bite",
		&"flee_range": 0.0,
		&"hunger_days": 1.2,
		&"butcher_seconds": 60.0,
		&"yields": {&"meat": 0.40, &"leather": 0.15, &"bone": 0.12},
		&"hunts": [&"rabbit", &"deer"],
		&"comfort_min": -30.0, &"comfort_max": 20.0,
		&"color": Color(0.45, 0.45, 0.50),
		&"scale": 0.55,
	},
	# Large omnivore — the dangerous hunt, and the heaviest corpse the
	# colony is likely to drag home.
	&"bear": {
		&"label": "bear",
		&"mass_kg": 300.0,
		&"health": 200.0,
		&"speed": 4.5,
		&"diet": &"omnivore",
		&"temperament": &"fight",
		&"melee": 20.0,
		&"wound_kind": &"bite",
		&"flee_range": 0.0,
		&"hunger_days": 1.4,
		&"butcher_seconds": 180.0,
		&"yields": {&"meat": 0.50, &"leather": 0.18, &"bone": 0.15},
		&"extras": [{&"material": BlockRegistry.Resource_.TUSK, &"cm3": 1500, &"count": 1}],
		&"comfort_min": -30.0, &"comfort_max": 18.0,
		&"color": Color(0.30, 0.22, 0.16),
		&"scale": 1.1,
	},
}


## The installed pack's table — empty until [class DataPackage]
## installs one, then [member SPECIES] is the built-in fallback.
static var _installed: Dictionary = {}


## The active species table: the package-installed one when a pack is
## selected, else the vanilla defaults this file still carries.
static func species_table() -> Dictionary:
	if _installed.is_empty():
		return DataPackage.animals_table()
	return _installed


## Installs a pack's `animals` section — DataPackage calls this on
## selection; an empty table hands control back to the fallback.
static func install(table: Dictionary) -> void:
	_installed = table


## The spec for [param species], or the colonist defaults for an
## unknown id — callers can always read fields defensively.
static func spec(species: StringName) -> Dictionary:
	var table := species_table()
	return table.get(species, table.get(&"colonist", SPECIES[&"colonist"]))


static func label(species: StringName) -> String:
	return spec(species).get(&"label", String(species))


## A field read with a default — spec consumers don't have to know
## which keys a given species sets.
static func field(species: StringName, key: StringName, fallback: float) -> float:
	return float(spec(species).get(key, fallback))


## The corpse item's volume in cm³ — flesh runs about a kilogram per
## litre, so body mass is the volume.
static func corpse_cm3(species: StringName) -> int:
	return int(field(species, &"mass_kg", 75.0) * 1000.0)
