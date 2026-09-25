class_name DLog
extends RefCounted

## Crash-forensic breadcrumbs — appended and flushed per line so the file
## (user://delve_debug.log) survives a hard engine crash. For sparse events
## only: spawning, designations, teleports, job transitions. Never call in
## a per-tick path — a file flush per frame is not free.
##
## The native side logs to user://delve_native.log (see DelveSim.dlog) and
## Godot's own crash log lands in %APPDATA%/Godot/app_userdata/Delve/logs.

static var _file: FileAccess = null


static func open() -> void:
	if _file != null:
		return
	_file = FileAccess.open("user://delve_debug.log", FileAccess.WRITE)
	if _file == null:
		return
	_file.store_line("== delve debug log, pid %d ==" % OS.get_process_id())
	_file.flush()


static func log(msg: String) -> void:
	if _file == null:
		return
	_file.store_line("%dms %s" % [Time.get_ticks_msec(), msg])
	_file.flush()
