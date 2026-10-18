class_name Perf
extends RefCounted

## Per-frame section accounting behind the HUD's perf line — the
## answer to "what was in that hitch". Callers wrap a section with a
## pair of clock reads:
##
##     var t0 := Time.get_ticks_usec()
##     _do_the_thing()
##     Perf.sample(&"my.thing", Time.get_ticks_usec() - t0)
##
## The tracker rolls its accumulation on each rendered frame (an
## engine counter, so it works while paused, headless, or when no
## instrumented node happens to tick); the worst frame of each window
## keeps its top sections so the readout names the offender, not just
## the spike. Work in physics ticks between two rendered frames folds
## into the frame they precede — what a hitch actually feels like.
## Uninstrumented time — engine rendering, streaming mesh builds —
## shows up as worst-frame total minus the accounted sum.

## Seconds per accounting window, matching the HUD's worst-frame pane.
const WINDOW_SEC := 2.0
## How many sections of the worst frame to keep.
const TOP_N := 3

static var _frame_us: Dictionary = {}
static var _frame_total_us := 0
static var _frame_id := -1
static var _worst_total_us := 0
static var _worst_top: Array = []
static var _window_end_msec := 0

## Worst instrumented frame of the last finished window.
static var worst_ms := 0.0
## Its top sections — [[usec, section], ...] longest first.
static var worst_top: Array = []


static func sample(section: StringName, usec: int) -> void:
	var fid := int(Engine.get_process_frames())
	if fid != _frame_id:
		_roll()
		_frame_id = fid
	_frame_us[section] = int(_frame_us.get(section, 0)) + usec
	_frame_total_us += usec


## Closes the accumulation the next frame's samples just ended —
## publishes the finished frame against the window's worst.
static func _roll() -> void:
	if _frame_total_us > _worst_total_us:
		_worst_total_us = _frame_total_us
		var pairs: Array = []
		for section in _frame_us:
			pairs.append([int(_frame_us[section]), section])
		pairs.sort_custom(
			func(a: Array, b: Array) -> bool: return a[0] > b[0]
		)
		_worst_top = pairs.slice(0, TOP_N)
	_frame_us.clear()
	_frame_total_us = 0
	var now := Time.get_ticks_msec()
	if now >= _window_end_msec:
		worst_ms = _worst_total_us / 1000.0
		worst_top = _worst_top
		_worst_total_us = 0
		_worst_top = []
		_window_end_msec = now + int(WINDOW_SEC * 1000.0)


## "sim.tick 12.3ms, forest 4.1ms" — the worst frame's accounted
## offenders, for the perf line. Empty when nothing was instrumented.
static func top_text() -> String:
	var parts: PackedStringArray = []
	for pair in worst_top:
		parts.append("%s %.1fms" % [pair[1], pair[0] / 1000.0])
	return ", ".join(parts)
