class_name Weather
extends RefCounted

## The site's sky — a provisional single-site weather model (PLAN item
## 32) pending region-level generation: the working site is assumed to
## sit in a warm-temperate (Cfa) climate and the whole site shares one
## state. Synoptic-scale patterns and per-region modulation come later;
## the state serializes inside the colony payload, which rides inside
## the region file, so the save unit is already the right one.
##
## Seasons: 4 × 15 days = a 60-day year starting in spring. Temperature
## is a sum of three terms plus an event bias:
##   annual mean — 15 °C ± 12 °C on a cosine peaking in late summer and
##     bottoming in late winter (27 °C / 3 °C at the extrema);
##   diurnal — ±5 °C, the low a few hours before sunrise, the high a
##     few hours before sunset;
##   perturb — an Ornstein–Uhlenbeck wobble that wanders but is pulled
##     back toward the mean;
##   event — a heat wave (+15 °C) or cold snap (−15 °C) lasting 1.5–3.5
##     days, ramping 0.5 day in and out.
##
## Precipitation is a small Markov machine: CLEAR about 60% of the
## time, RAIN/SNOW (temperature decides) the rest. A clear→wet
## transition opens with a thunderstorm 25% of the time in spring and
## autumn, 50% in summer, never in winter; the storm is wet 75% of the
## time and dry-turning-wet 25%. Dry storms are the fire risk — their
## lightning strikes with nothing to quench what it starts.

enum State { CLEAR, RAIN, SNOW, STORM_DRY, STORM_WET }

const SEASON_NAMES: Array[String] = ["spring", "summer", "autumn", "winter"]
const DAYS_PER_SEASON := 15
## The calendar year's length — four seasons of fifteen days.
const YEAR_DAYS := 60

## Seasonal extremes for the assumed Cfa site — the defaults the
## fields below start from, and the reference the site climate is
## derived against (item 39's macro→micro link treats this model as a
## 100 cm/yr warm-temperate site).
const MEAN_C := 15.0
const MEAN_AMPLITUDE_C := 12.0
## The wet share the stock Markov produces — mean clear 1.5 d vs mean
## precip 1.0 d — taken to represent 100 cm of annual rain.
const REFERENCE_PRECIP_SHARE := 0.4
const REFERENCE_PRECIP_CM := 100.0
## Cap on the wet share — even the wettest climates still see dry
## breaks (the Seattle-vs-Chicago modality problem is deferred).
const MAX_PRECIP_SHARE := 0.85
## Day-of-year the annual mean peaks — late summer under this calendar.
const SUMMER_PEAK_DAY := 26.25
## The day fraction the diurnal cycle peaks at — a few hours before
## sunset (which sits at 0.75 on the equinox track the site runs).
const DIURNAL_PEAK_FRACTION := 0.625
const DIURNAL_AMPLITUDE_C := 5.0

## OU noise: reverts toward zero on this time constant, steps with this
## per-second volatility — bounded wobble, never a random walk.
const NOISE_REVERT_SEC := 120.0
const NOISE_STEP_C := 0.35
const NOISE_CAP_C := 6.0

## Mean episode lengths in game days — the stationary split lands near
## 60% clear / 40% precip, per the spec.
const MEAN_CLEAR_DAYS := 1.5
const MEAN_PRECIP_DAYS := 1.0
const MEAN_STORM_DRY_DAYS := 0.08
const MEAN_STORM_WET_DAYS := 0.15

## Season-indexed chance a clear→wet transition opens with a storm:
## spring/autumn a quarter, summer half, winter never.
const STORM_CHANCE := [0.25, 0.5, 0.25, 0.0]
const STORM_STARTS_WET := 0.75

## Mean gap between temperature events, and the bias they carry.
const EVENT_MTB_DAYS := 8.0
const EVENT_BIAS_C := 15.0
const EVENT_RAMP_DAYS := 0.5
const EVENT_MIN_DAYS := 1.5
const EVENT_MAX_DAYS := 3.5

## Lightning: each storm tick rolls a flash at this rate; a fraction of
## flashes strike ground inside the site and can start fires.
const FLASHES_PER_DAY := 40.0
const STRIKE_CHANCE := 0.08

## Rain's grip on the ground: saturation climbs toward 1 while
## precipitation falls and dries out over this many days once it
## stops. Ignition and spread odds sink as it soaks.
const SATURATION_WET_RATE := 0.4
const SATURATION_DRY_DAYS := 1.5

## Precipitation's cut to sunlight for plant growth — an overcast sky.
const LIGHT_FACTORS: Dictionary = {
	State.CLEAR: 1.0,
	State.RAIN: 0.35,
	State.SNOW: 0.45,
	State.STORM_DRY: 0.55,
	State.STORM_WET: 0.25,
}

## The axial tilt this site's seasons swing the sun through — the
## summer/winter extremes of the day-length arc.
const AXIAL_TILT_DEG := 23.44

## Site climate — written from the world tile's mesoscale data before
## the first tick (`set_climate`); the defaults reproduce the legacy
## Cfa constants for scenes that never set them.
var mean_c := MEAN_C
## Signed seasonal swing — the ±12 °C mid-latitude anchor scaled by
## sin(lat)·(tilt/reference tilt). Negative in the southern hemisphere,
## which flips the annual swing half a year on its own.
var seasonal_amplitude_c := MEAN_AMPLITUDE_C
## The site's axial tilt — drives the sun's declination swing.
var axial_tilt_deg := AXIAL_TILT_DEG
## Mean clear-episode length — solved from the site's precipitation
## share, not a constant: drier tiles wait longer between rains.
var mean_clear_days := MEAN_CLEAR_DAYS
## A southern site's calendar runs flipped — its local summer is the
## northern hemisphere's winter.
var south := false

## Current sky state.
var state: State = State.CLEAR
## Game seconds left in the current state — decremented by tick.
var remaining := 0.0
## Mean-reverting temperature noise, °C.
var perturb := 0.0
## Active temperature event: signed bias target (0 = none) and the
## total event length; `event_elapsed` walks 0→total over the event.
var event_bias := 0.0
var event_total := 0.0
var event_elapsed := 0.0
## How soaked the ground is, 0–1 — rain's memory, drying slowly. Fire
## rolls against it; plants will too (item 40).
var saturation := 0.0
## The colony we report to — lightning ignites through it.
var _colony: Colony


## The site's climate tuple from its world data (item 39's
## macro→micro link): the mesoscale mean becomes the annual
## temperature, latitude scales the seasonal swing (sin(lat), anchored
## at ±12 °C for 45° under Earth's tilt — equatorial sites barely
## swing, polar sites swing hard) and annual cm scales the wet share
## off the reference model, capped so wet climates still see dry
## spells. Rain *modality* — Seattle's drizzle vs Chicago's bursts —
## is deferred; for now one shape fits all.
static func site_climate(
	lat_deg: float, site_mean_c: float, precip_cm: float, tilt_deg: float
) -> Dictionary:
	var share := clampf(
		REFERENCE_PRECIP_SHARE * precip_cm / REFERENCE_PRECIP_CM,
		0.0, MAX_PRECIP_SHARE
	)
	return {
		&"mean_c": site_mean_c,
		&"amplitude_c": (
			MEAN_AMPLITUDE_C * sin(deg_to_rad(lat_deg)) / sin(PI * 0.25)
			* tilt_deg / AXIAL_TILT_DEG
		),
		&"mean_clear_days": (
			MEAN_PRECIP_DAYS * (1.0 - share) / maxf(share, 0.02)
		),
		&"tilt_deg": tilt_deg,
		&"south": lat_deg < 0.0,
	}


## Applies a [method site_climate] tuple. Deterministic from seed +
## tile, so it isn't serialized — a load recomputes it.
func set_climate(climate: Dictionary) -> void:
	mean_c = climate[&"mean_c"]
	seasonal_amplitude_c = climate[&"amplitude_c"]
	mean_clear_days = climate[&"mean_clear_days"]
	axial_tilt_deg = climate[&"tilt_deg"]
	south = climate[&"south"]


func setup(colony: Colony) -> void:
	_colony = colony
	# A fresh game opens on clear sky with most of the episode ahead.
	if remaining <= 0.0:
		remaining = mean_clear_days * _day_seconds() * randf_range(0.8, 1.6)


## Day-of-year index in [0, YEAR_DAYS) under this site's calendar —
## day 1 of a fresh game is the first day of spring.
func year_day(day_cycle: DayCycle) -> float:
	if day_cycle == null:
		return 0.0
	return fposmod(
			day_cycle.planet_time / day_cycle.day_length_seconds, YEAR_DAYS
		)


## Season index (0 spring … 3 winter) at the current clock — the
## *site's* season: a southern hemisphere site shifts half a year so
## its labels and storm rates stay aligned to local weather.
func season(day_cycle: DayCycle) -> int:
	var offset := 2 if south else 0
	return (
		int(year_day(day_cycle) / DAYS_PER_SEASON + offset)
		% SEASON_NAMES.size()
	)


func season_name(day_cycle: DayCycle) -> String:
	return SEASON_NAMES[season(day_cycle)]


## Ambient air temperature in °C — annual mean + diurnal swing + the
## mean-reverting wobble + any live heat-wave/cold-snap bias.
func temperature_c(day_cycle: DayCycle) -> float:
	var d := year_day(day_cycle)
	var f := day_cycle.day_fraction() if day_cycle != null else 0.0
	var annual := mean_c + seasonal_amplitude_c * cos(
		TAU * (d - SUMMER_PEAK_DAY) / YEAR_DAYS
	)
	var diurnal := DIURNAL_AMPLITUDE_C * cos(
		TAU * (f - DIURNAL_PEAK_FRACTION)
	)
	return annual + diurnal + perturb + _event_bias_now()


## The event's instantaneous bias — linear ramps in and out over
## EVENT_RAMP_DAYS, flat between.
func _event_bias_now() -> float:
	if event_total <= 0.0 or event_bias == 0.0:
		return 0.0
	var day_secs := _day_seconds()
	var in_t := minf(event_elapsed, EVENT_RAMP_DAYS * day_secs)
	var out_t := minf(event_total - event_elapsed, EVENT_RAMP_DAYS * day_secs)
	return event_bias * clampf(
		minf(in_t, out_t) / (EVENT_RAMP_DAYS * day_secs), 0.0, 1.0
	)


## True while precipitation falls — rain, snow or a wet storm all wet
## the ground and fight fires.
func precipitating() -> bool:
	return state == State.RAIN or state == State.SNOW or state == State.STORM_WET


## Sunlight multiplier under the present sky — overcast cuts the light
## plants see, which is how weather gates growth through item 20's
## environment model.
func light_factor() -> float:
	return float(LIGHT_FACTORS.get(state, 1.0))


## Player-facing sky name.
func label() -> String:
	match state:
		State.CLEAR:
			return "clear"
		State.RAIN:
			return "rain"
		State.SNOW:
			return "snow"
		State.STORM_DRY:
			return "dry thunderstorm"
		State.STORM_WET:
			return "thunderstorm"
	return "clear"


## Advances the whole sky by [param delta] game seconds: state
## transitions, temperature noise, event drift, ground wetting and
## storm lightning. Called from the colony's physics tick, so delta is
## already pause/speed-scaled.
func tick(delta: float, day_cycle: DayCycle) -> void:
	_tick_noise(delta)
	_tick_event(delta, day_cycle)
	_tick_saturation(delta)
	if day_cycle == null:
		return
	# Seasons drive the sun's declination — longer summer days, shorter
	# winter ones — on top of the annual temperature swing.
	day_cycle.solar_declination_deg = axial_tilt_deg * cos(
		TAU * (year_day(day_cycle) - SUMMER_PEAK_DAY) / YEAR_DAYS
	)
	_tick_state(delta, day_cycle)
	_tick_lightning(delta, day_cycle)


func _tick_noise(delta: float) -> void:
	# OU step: deterministic pull to zero plus a scaled random kick.
	perturb -= perturb * delta / NOISE_REVERT_SEC
	perturb += randfn(0.0, NOISE_STEP_C) * sqrt(delta)
	perturb = clampf(perturb, -NOISE_CAP_C, NOISE_CAP_C)


func _tick_event(delta: float, day_cycle: DayCycle) -> void:
	if event_total > 0.0:
		event_elapsed += delta
		if event_elapsed >= event_total:
			event_bias = 0.0
			event_total = 0.0
			event_elapsed = 0.0
		return
	var day_secs := _day_seconds()
	if day_cycle != null and randf() < delta / (EVENT_MTB_DAYS * day_secs):
		# Season-weighted sign: heat waves favour summer, cold snaps
		# winter — shoulder seasons split even.
		var hot_chance: float = [0.5, 0.75, 0.5, 0.25][season(day_cycle)]
		var hot: bool = randf() < hot_chance
		event_bias = EVENT_BIAS_C if hot else -EVENT_BIAS_C
		event_total = randf_range(EVENT_MIN_DAYS, EVENT_MAX_DAYS) * day_secs
		event_elapsed = 0.0


func _tick_saturation(delta: float) -> void:
	var day_secs := _day_seconds()
	if precipitating():
		saturation = minf(1.0, saturation + SATURATION_WET_RATE * delta)
	else:
		saturation = maxf(
			0.0, saturation - delta / (SATURATION_DRY_DAYS * day_secs)
		)


func _tick_state(delta: float, day_cycle: DayCycle) -> void:
	remaining -= delta
	# Snow that outlives its cold snap turns to rain instead of ending.
	if (
		state == State.SNOW
		and temperature_c(day_cycle) > 1.0
	):
		_enter(State.RAIN, MEAN_PRECIP_DAYS)
	var day_secs := _day_seconds()
	match state:
		State.CLEAR:
			if remaining <= 0.0:
				_clear_breaks(day_cycle)
		State.RAIN, State.SNOW:
			if remaining <= 0.0:
				_enter(State.CLEAR, mean_clear_days)
		State.STORM_DRY:
			# A dry storm always wets — the spec's 25% path.
			if remaining <= 0.0:
				_enter(State.STORM_WET, MEAN_STORM_WET_DAYS)
		State.STORM_WET:
			if remaining <= 0.0:
				if randf() < 0.4:
					_enter(State.RAIN, MEAN_PRECIP_DAYS)
				else:
					_enter(State.CLEAR, mean_clear_days)


## The clear state expired — pick what follows it: a thunderstorm at
## the season's rate (wet three times out of four), snow when the air
## is freezing, else plain rain.
func _clear_breaks(day_cycle: DayCycle) -> void:
	var temp := temperature_c(day_cycle)
	var storm_chance: float = STORM_CHANCE[season(day_cycle)]
	if temp <= 0.0:
		_enter(State.SNOW, MEAN_PRECIP_DAYS)
	elif randf() < storm_chance:
		if randf() < STORM_STARTS_WET:
			_enter(State.STORM_WET, MEAN_STORM_WET_DAYS)
		else:
			_enter(State.STORM_DRY, MEAN_STORM_DRY_DAYS)
	else:
		_enter(State.RAIN, MEAN_PRECIP_DAYS)


func _enter(next: State, mean_days: float) -> void:
	state = next
	# Exponential-ish episode lengths around the mean.
	remaining = mean_days * _day_seconds() * randf_range(0.4, 1.6)


## Storm lightning — flashes roll each tick; a small share strike the
## site and try to start a fire through the colony's ignition gate
## (wet ground and falling rain resist).
func _tick_lightning(delta: float, day_cycle: DayCycle) -> void:
	if state != State.STORM_DRY and state != State.STORM_WET:
		return
	if _colony == null:
		return
	var day_secs := _day_seconds()
	if randf() >= delta * FLASHES_PER_DAY / day_secs:
		return
	if randf() >= STRIKE_CHANCE:
		return
	_colony.lightning_strike()


func _day_seconds() -> float:
	var dc := _colony_day_cycle()
	return dc.day_length_seconds if dc != null else 240.0


func _colony_day_cycle() -> DayCycle:
	return _colony.day_cycle if _colony != null else null


func serialize() -> Dictionary:
	return {
		"state": int(state),
		"remaining": remaining,
		"perturb": perturb,
		"event_bias": event_bias,
		"event_total": event_total,
		"event_elapsed": event_elapsed,
		"saturation": saturation,
	}


func deserialize(data: Dictionary) -> void:
	state = int(data.get("state", int(State.CLEAR)))
	remaining = float(data.get("remaining", 0.0))
	perturb = float(data.get("perturb", 0.0))
	event_bias = float(data.get("event_bias", 0.0))
	event_total = float(data.get("event_total", 0.0))
	event_elapsed = float(data.get("event_elapsed", 0.0))
	saturation = float(data.get("saturation", 0.0))
