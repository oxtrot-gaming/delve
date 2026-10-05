class_name PlantGrowth
extends RefCounted

## Growth-rate environment math shared by [Plants] and [Forest].
##
## A species entry declares the light band it tolerates —
## `light_min`/`light_low`/`light_high`/`light_max`, in sun-intensity
## units (the sine of the sun's altitude: ~0.05 at dawn/dusk, ~0.66
## mid-morning, ~0.94 this site's noon, 1.0 at zenith) — plus a
## `fertility_sensitivity` scaling how much the soil under it matters.
##
## Item 40 adds the second growth axis and the damage model. Temperature
## gets three nested °C ranges: `temp_opt_min`..`temp_opt_max` grows at
## full rate, `temp_grow_min`..`temp_grow_max` grows slowly (ramping
## down to the bound), and `temp_dorm_min`..`temp_dorm_max` stalls
## growth without harm — outside it, damage accrues per °C of
## overshoot. Light stress runs on grace periods: a plant below
## `light_min` or above `light_max` starts counting `dark`/`glare`
## game-seconds on its record, decays them at half rate while in-band,
## and takes damage once past `shade_grace_s`/`glare_grace_s` — shade
## grace is long (an ordinary night never reaches it) while glare bites
## fast. Damage accumulates on the record in hit points; at
## `hit_points` the plant dies, and a survivor's harvest scales by its
## remaining health fraction via [method yield_factor].

## The standard daytime curve — every current species uses it. `low`
## marks mid-morning at this site's latitude, `high` full noon; `max`
## sits 25% past noon, which this site can't produce — headroom for
## sunnier latitudes and future seasons.
const LIGHT_MIN := 0.05
const LIGHT_LOW := 0.66
const LIGHT_HIGH := 0.94
const LIGHT_MAX := 1.17

## Temperate-plant temperature defaults, °C: a warm-band optimum, a
## shoulder band that still grows, and a dormant band that merely
## stalls. This site's climate (Weather.MEAN_C 15 ± 12 annual, ±5
## diurnal, ±6 noise) lands inside the dormant band on ordinary years —
## only heat waves and cold snaps (~±15° events) do damage.
const TEMP_OPT_MIN := 10.0
const TEMP_OPT_MAX := 28.0
const TEMP_GROW_MIN := 4.0
const TEMP_GROW_MAX := 36.0
const TEMP_DORM_MIN := -8.0
const TEMP_DORM_MAX := 45.0

## Hit points when a species doesn't declare them.
const HIT_POINTS := 100.0
## Fraction of hit points of damage per game-second per °C outside the
## dormant band — a 10° overshoot kills in about half a game-day.
const TEMP_FRAC_DPS := 0.0008
## Game-seconds of below-band light before shade damage starts — ~2.5
## nights' worth, so a single night or even an overcast dark day can't
## hurt anything. In-band light bleeds the accumulator off at half rate.
const SHADE_GRACE_S := 300.0
## hp-fraction per game-second of post-grace shade — dead in ~2 days of
## unbroken darkness.
const SHADE_FRAC_DPS := 0.002
## Game-seconds of over-band light before glare damage starts — a
## quarter-day, so a briefly left-on lamp is survivable; then dead in
## about half a game-day.
const GLARE_GRACE_S := 60.0
const GLARE_FRAC_DPS := 0.01
## Game-seconds a dead plant stands before it collapses into compost —
## three quarters of a game-day, quick enough that kill-offs don't
## linger.
const DECAY_SECONDS := 180.0
## Compost a dead plant leaves — a small bush's biomass.
const COMPOST_VOLUME := 30_000
## Dead plants render in dead-plant brown regardless of species.
const DEAD_COLOR := Color(0.30, 0.20, 0.09)


## The daylight multiplier on growth rate: 0 outside the species'
## minimum–maximum band, 1 across the optimal band, lerped through the
## dawn-side and scorch-side transitions.
static func light_factor(sp: Dictionary, level: float) -> float:
	var lo := float(sp.get(&"light_min", LIGHT_MIN))
	var opt_lo := float(sp.get(&"light_low", LIGHT_LOW))
	var opt_hi := float(sp.get(&"light_high", LIGHT_HIGH))
	var hi := float(sp.get(&"light_max", LIGHT_MAX))
	if level <= lo or level >= hi:
		return 0.0
	if level >= opt_lo and level <= opt_hi:
		return 1.0
	if level < opt_lo:
		return (level - lo) / maxf(opt_lo - lo, 0.0001)
	return 1.0 - (level - opt_hi) / maxf(hi - opt_hi, 0.0001)


## The temperature multiplier on growth rate — the same trapezoid shape
## as [method light_factor] over the grow/optimal bounds. Between the
## grow bound and the dormant bound the plant is asleep (factor 0) but
## unharmed; past dormant it takes damage (see [method
## temperature_overshoot]).
static func temperature_factor(sp: Dictionary, temp_c: float) -> float:
	var gmin := float(sp.get(&"temp_grow_min", TEMP_GROW_MIN))
	var omin := float(sp.get(&"temp_opt_min", TEMP_OPT_MIN))
	var omax := float(sp.get(&"temp_opt_max", TEMP_OPT_MAX))
	var gmax := float(sp.get(&"temp_grow_max", TEMP_GROW_MAX))
	if temp_c <= gmin or temp_c >= gmax:
		return 0.0
	if temp_c >= omin and temp_c <= omax:
		return 1.0
	if temp_c < omin:
		return (temp_c - gmin) / maxf(omin - gmin, 0.0001)
	return 1.0 - (temp_c - omax) / maxf(gmax - omax, 0.0001)


## °C by which [param temp_c] exceeds the species' dormant band — 0
## while dormant or growing. Thermal damage scales with this.
static func temperature_overshoot(sp: Dictionary, temp_c: float) -> float:
	var dmin := float(sp.get(&"temp_dorm_min", TEMP_DORM_MIN))
	var dmax := float(sp.get(&"temp_dorm_max", TEMP_DORM_MAX))
	return maxf(0.0, maxf(dmin - temp_c, temp_c - dmax))


## The species' cumulative-damage death threshold, in hit points.
static func hit_points(sp: Dictionary) -> float:
	return float(sp.get(&"hit_points", HIT_POINTS))


## The soil multiplier on growth rate: effective fertility (1.0 = plain
## dirt) raised to the species' sensitivity — sensitivity 1 doubles
## growth on 200% fertility and halves it on 50%, 0 ignores fertility
## entirely, and values past 1 are legal for greedier species. Never
## negative — a plant on dead soil stalls rather than shrinking.
static func fertility_factor(effective: float, sensitivity: float) -> float:
	return clampf(pow(maxf(effective, 0.0), sensitivity), 0.0, 1e6)


## The combined environment multiplier for a plant of species [param sp]
## seeing [param light] at [param temp_c] on soil of [param
## effective_fertility]. Temperature multiplies in with light — frozen
## or scorched plants don't grow whatever the sky does.
static func growth_factor(
	sp: Dictionary, light: float, temp_c: float, effective_fertility: float
) -> float:
	return maxf(
		0.0,
		light_factor(sp, light)
		* temperature_factor(sp, temp_c)
		* fertility_factor(
			effective_fertility, float(sp.get(&"fertility_sensitivity", 0.0))
		)
	)


## One interval of environmental stress for a living plant: returns the
## hit points of damage sustained over [param elapsed] game-seconds and
## updates the record's `dark`/`glare` accumulators (game-seconds of
## sustained out-of-band light; they bleed off at half rate in-band, so
## an ordinary day/night cycle never reaches the shade grace). Thermal
## damage is immediate — there's no grace for being frozen or cooked.
static func stress_tick(
	sp: Dictionary, rec: Dictionary, light: float, temp_c: float,
	elapsed: float
) -> float:
	var hp := hit_points(sp)
	var dmg := (
		temperature_overshoot(sp, temp_c)
		* float(sp.get(&"temp_frac_dps", TEMP_FRAC_DPS)) * hp * elapsed
	)
	var lo := float(sp.get(&"light_min", LIGHT_MIN))
	var hi := float(sp.get(&"light_max", LIGHT_MAX))
	if light <= lo:
		rec[&"dark"] = float(rec.get(&"dark", 0.0)) + elapsed
		# Only violating time past the grace pays — a tick that crosses
		# the boundary pro-rates, and a lit interval never damages no
		# matter how much dark timer is still bleeding off.
		var dark_over := minf(
			elapsed,
			float(rec[&"dark"])
				- float(sp.get(&"shade_grace_s", SHADE_GRACE_S))
		)
		if dark_over > 0.0:
			dmg += (
				float(sp.get(&"shade_frac_dps", SHADE_FRAC_DPS))
				* hp * dark_over
			)
	else:
		rec[&"dark"] = maxf(
			0.0, float(rec.get(&"dark", 0.0)) - elapsed * 0.5
		)
	if light >= hi:
		rec[&"glare"] = float(rec.get(&"glare", 0.0)) + elapsed
		var glare_over := minf(
			elapsed,
			float(rec[&"glare"])
				- float(sp.get(&"glare_grace_s", GLARE_GRACE_S))
		)
		if glare_over > 0.0:
			dmg += (
				float(sp.get(&"glare_frac_dps", GLARE_FRAC_DPS))
				* hp * glare_over
			)
	else:
		rec[&"glare"] = maxf(
			0.0, float(rec.get(&"glare", 0.0)) - elapsed * 0.5
		)
	return dmg


## The harvest multiplier a plant with [param damage] hit points of
## accumulated damage still yields — health fraction: a plant at the
## brink of death harvests almost nothing.
static func yield_factor(sp: Dictionary, damage: float) -> float:
	return maxf(0.0, 1.0 - damage / maxf(hit_points(sp), 1.0))
