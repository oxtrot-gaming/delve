class_name PlantGrowth
extends RefCounted

## Growth-rate environment math shared by [Plants] and [Forest].
##
## A species entry declares the light band it tolerates —
## `light_min`/`light_low`/`light_high`/`light_max`, in sun-intensity
## units (the sine of the sun's altitude: ~0.05 at dawn/dusk, ~0.66
## mid-morning, ~0.94 this site's noon, 1.0 at zenith) — plus a
## `fertility_sensitivity` scaling how much the soil under it matters.
## Out-of-band light currently just stalls growth; damage and death
## from sustained darkness or glare — with per-species grace periods,
## glare typically killing faster — are roadmap item 39.

## The standard daytime curve — every current species uses it. `low`
## marks mid-morning at this site's latitude, `high` full noon; `max`
## sits 25% past noon, which this site can't produce — headroom for
## sunnier latitudes and future seasons.
const LIGHT_MIN := 0.05
const LIGHT_LOW := 0.66
const LIGHT_HIGH := 0.94
const LIGHT_MAX := 1.17


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


## The soil multiplier on growth rate: effective fertility (1.0 = plain
## dirt) raised to the species' sensitivity — sensitivity 1 doubles
## growth on 200% fertility and halves it on 50%, 0 ignores fertility
## entirely, and values past 1 are legal for greedier species. Never
## negative — a plant on dead soil stalls rather than shrinking.
static func fertility_factor(effective: float, sensitivity: float) -> float:
	return clampf(pow(maxf(effective, 0.0), sensitivity), 0.0, 1e6)


## The combined environment multiplier for a plant of species [param sp]
## seeing [param light] on soil of [param effective_fertility].
static func growth_factor(
	sp: Dictionary, light: float, effective_fertility: float
) -> float:
	return maxf(
		0.0,
		light_factor(sp, light)
		* fertility_factor(
			effective_fertility, float(sp.get(&"fertility_sensitivity", 0.0))
		)
	)
