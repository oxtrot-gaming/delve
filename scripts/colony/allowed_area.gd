class_name AllowedArea
extends RefCounted

## A named set of voxels the player paints and assigns colonists and
## animals to. Units inside an area only work cells that belong to it;
## a unit with no area is unrestricted. A cell belongs to at most one
## area — repainting moves it.

var label: String = ""
var cells: Dictionary = {} # Vector3i -> true


func has_cell(voxel: Vector3i) -> bool:
	return cells.has(voxel)


## Serialized form: {label, cells}.
func serialize() -> Dictionary:
	var list: Array = []
	for cell: Vector3i in cells:
		list.append([cell.x, cell.y, cell.z])
	return {"label": label, "cells": list}


static func deserialize(data: Dictionary) -> AllowedArea:
	var area := AllowedArea.new()
	area.label = String(data.get("label", ""))
	for e: Array in data.get("cells", []):
		if e.size() >= 3:
			area.cells[Vector3i(int(e[0]), int(e[1]), int(e[2]))] = true
	return area
