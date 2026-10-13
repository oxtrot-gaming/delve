class_name GameOptions
extends RefCounted

## Player-facing settings (PLAN item 63). The Menu's Options panel
## writes these and they persist to user://options.cfg, so the title
## screen and the colony scene share the same knobs. Statics only —
## nothing instantiates this.

const PATH := "user://options.cfg"

## Master-bus loudness; 0 dB is unity, the slider floors at -60.
static var volume_db := 0.0
## Autosave cadence in minutes of wall time — 0 disables.
static var autosave_minutes := 10
## Show the frame/perf readout on the inspect pane.
static var perf_overlay := true

static var _loaded := false


## First-run config load — idempotent; both the title scene and the
## HUD call it at boot so either entry point finds the file applied.
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	load_file(PATH)
	apply_volume()


## Read a config file into the statics — absent keys keep defaults.
static func load_file(path: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	volume_db = float(cfg.get_value("audio", "volume_db", volume_db))
	autosave_minutes = int(
		cfg.get_value("saves", "autosave_minutes", autosave_minutes)
	)
	perf_overlay = bool(cfg.get_value("ui", "perf_overlay", perf_overlay))


## Persist the statics — the Options panel calls this per change.
static func save_file(path: String = PATH) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "volume_db", volume_db)
	cfg.set_value("saves", "autosave_minutes", autosave_minutes)
	cfg.set_value("ui", "perf_overlay", perf_overlay)
	var err := cfg.save(path)
	if err != OK:
		push_error("cannot write %s: %s" % [path, error_string(err)])


static func apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, volume_db)


## The option's choices for the autosave cadence — label, minutes.
static var autosave_choices: Array[Dictionary] = [
	{"label": "Never", "minutes": 0},
	{"label": "5 min", "minutes": 5},
	{"label": "10 min", "minutes": 10},
	{"label": "20 min", "minutes": 20},
]
