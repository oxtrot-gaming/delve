class_name FilterPresets
extends RefCounted

## Player-preference storage for stockpile filters — named reject sets
## saved to user://filter_presets.json. A preset is just the reject list;
## a zone's priority stays its own. Stockpiles and shelves share the one
## filter model, so one table serves both.

const PATH := "user://filter_presets.json"


## The saved preset names, sorted — the load menu's order.
static func names() -> Array[String]:
	var found: Array[String] = []
	found.assign(_load_all().keys())
	found.sort()
	return found


## A preset's reject set, or {} for an unknown name.
static func preset(name: String) -> Dictionary:
	var out := {}
	for m in _load_all().get(name, []):
		out[int(m)] = true
	return out


## Saves [param rejected] under [param name] — overwrites in place.
static func save(name: String, rejected: Dictionary) -> void:
	if name.strip_edges() == "":
		return
	var all := _load_all()
	var keys := rejected.keys()
	keys.sort()
	all[name] = keys
	_store_all(all)


## Drops a preset — the panel's delete button.
static func erase(name: String) -> void:
	var all := _load_all()
	if all.erase(name):
		_store_all(all)


static func _load_all() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


static func _store_all(all: Dictionary) -> void:
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(all, "  "))
