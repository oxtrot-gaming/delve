class_name StockpileZone
extends RefCounted

## A storage zone: a set of cells plus the shared admission filter —
## every cell in the zone accepts and rejects the same materials, and
## the inspector edits the one record. `Colony.stockpiles` maps every
## cell back to this record, like `FarmField` for growing zones:
## contiguous designations merge into the neighbouring zone, and the
## record survives losing cells until the last one is undesignated.

## Storage priority ranks — RimWorld's ladder. "Best stockpile" picks
## the highest-ranked admitting zone, ties broken by distance.
enum Priority { VERY_LOW, LOW, NORMAL, HIGH, CRITICAL }
const PRIORITY_NAMES: Array[String] = [
	"Very low", "Low", "Normal", "High", "Critical",
]

## The cells the zone covers — the reverse index lives on the colony.
var cells: Dictionary = {}
## Rejected material ints — an empty set admits everything.
var rejected: Dictionary = {}
## Where this zone sits on the priority ladder — the deliver-to-best
## query's primary sort.
var priority: Priority = Priority.NORMAL
## A warehouse is bulk storage — the zone that takes furniture crates
## and other oversized goods ordinary stockpiles refuse, stacking them
## twice as deep. Filters work the same; admission is broader, not
## narrower.
var warehouse := false


## The filter's identity — two zones with the same signature store the
## same reject set. Deserialize uses it to keep distinct per-tile
## filters from old saves in distinct zones while merging identical
## neighbours the way a shared zone would have. Priority rides along so
## a reloaded zone keeps its rank's grouping too — and the warehouse
## flag, since a rack and a floor pile are never the same zone.
func signature() -> String:
	return (
		filter_signature(rejected)
		+ "|" + str(int(priority))
		+ ("|warehouse" if warehouse else "")
	)


static func filter_signature(rejected: Dictionary) -> String:
	var keys := rejected.keys()
	keys.sort()
	return str(keys)
