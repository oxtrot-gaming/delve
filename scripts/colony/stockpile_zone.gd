class_name StockpileZone
extends RefCounted

## A storage zone: a set of cells plus the shared admission filter —
## every cell in the zone accepts and rejects the same materials, and
## the inspector edits the one record. `Colony.stockpiles` maps every
## cell back to this record, like `FarmField` for growing zones:
## contiguous designations merge into the neighbouring zone, and the
## record survives losing cells until the last one is undesignated.

## The cells the zone covers — the reverse index lives on the colony.
var cells: Dictionary = {}
## Rejected material ints — an empty set admits everything.
var rejected: Dictionary = {}


## The filter's identity — two zones with the same signature store the
## same reject set. Deserialize uses it to keep distinct per-tile
## filters from old saves in distinct zones while merging identical
## neighbours the way a shared zone would have.
func signature() -> String:
	return filter_signature(rejected)


static func filter_signature(rejected: Dictionary) -> String:
	var keys := rejected.keys()
	keys.sort()
	return str(keys)
