class_name FarmField
extends RefCounted

## A growing zone: a set of surface cells plus the crop assigned to
## them. `Colony.farms` maps every cell back to this record, and the
## colony's farm scan turns an assigned field into work — a SOW job per
## sowable cell (gated on a seed existing), a FORAGE job per ripe shrub,
## and a CHOP job per mature tree when [member auto_chop] is on.

## What the field grows: a [constant Plants.SPECIES] or
## [constant Forest.SPECIES] key — empty while unassigned, so a fresh
## zone idles until the player picks a crop.
var species: StringName = &""
## The cells the zone covers — the reverse index lives on the colony.
var cells: Dictionary = {}
## Tree fields only: designate a felling job the moment a tree matures.
## Off means mature trees just stand — and keep fruiting.
var auto_chop := false
