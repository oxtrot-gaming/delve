class_name DayCycle
extends Node3D

## The planet clock and this site's sun. `planet_time` is global —
## accumulated game seconds since the epoch — and the site's latitude /
## longitude turn it into a local solar position: latitude tilts the
## sun's arc across the sky, longitude shifts local time against the
## planet's (sunrise is longitude-dependent). When several colony sites
## run at once they each carry their own coordinates over a shared
## planet clock; promoting `planet_time` to a region-level clock is a
## small refactor once a second site exists.
##
## Time freezes while the tree is paused and scales with
## `Engine.time_scale`, so the speed controls already apply.

## Hours the calendar counts per rotation.
const HOURS_PER_DAY := 24.0
## Where a fresh game starts on the day cycle — morning, just after
## sunrise, so the first moments are lit.
const START_FRACTION := 0.32
## The sky never goes fully dark — night is dim, not pitch black.
const NIGHT_SKY_FLOOR := 0.18
## Ambient fill at night. A procedural night sky renders near-black, so
## "dim" comes from this color while the sky contribution fades out.
const NIGHT_AMBIENT := Color(0.09, 0.11, 0.17)

## Real seconds (at 1x speed) per planetary day. Sized so a unit (~4 m/s)
## can cross a normal-sized colony site and back inside one day's
## daylight.
@export var day_length_seconds := 240.0
## The site's place on the planet — latitude tilts the sun's path (near
## the poles it skims the horizon), longitude offsets local time.
@export var site_latitude_deg := 20.0
@export var site_longitude_deg := 0.0
## Axial tilt's contribution to the sun's path. Seasons don't exist yet —
## the sun runs the equinox track (declination 0) until they do.
@export var solar_declination_deg := 0.0
@export var sun_path: NodePath = NodePath("../DirectionalLight3D")
@export var environment_path: NodePath = NodePath("../WorldEnvironment")

@onready var sun: DirectionalLight3D = get_node(sun_path)
@onready var world_environment: WorldEnvironment = get_node(environment_path)

## Game seconds since the epoch — the planet clock, not the site's local
## time (longitude shifts that).
var planet_time := 0.0
## The sun's current position over the site, radians — altitude above the
## horizon (negative = night), azimuth clockwise from north.
var sun_altitude := 0.0
var sun_azimuth := 0.0


func _ready() -> void:
	# A fresh game opens on a lit morning. (A restored save would set
	# planet_time before the node is readied — don't stomp it.)
	if planet_time == 0.0:
		start_fresh()
	var env := world_environment.environment
	if env != null:
		# Blend ambient between the sky (day) and a dim color (night).
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_color = NIGHT_AMBIENT
	_apply_sun()


## A new game opens mid-morning, just after sunrise.
func start_fresh() -> void:
	planet_time = day_length_seconds * START_FRACTION
	_apply_sun()


func _process(delta: float) -> void:
	# `delta` is already game-scaled (time_scale multiplies it, and the
	# tree stops feeding it while paused).
	advance(delta)


## Advances the planet clock — also the test hook for jumping ahead.
func advance(game_seconds: float) -> void:
	planet_time += game_seconds
	_apply_sun()


## The site's local time as a fraction of its day — 0 is local midnight,
## 0.5 is local noon.
func day_fraction() -> float:
	return wrapf(
		planet_time / day_length_seconds + site_longitude_deg / 360.0,
		0.0, 1.0
	)


func day_number() -> int:
	return floori(
		planet_time / day_length_seconds + site_longitude_deg / 360.0
	) + 1


func local_hours() -> float:
	return day_fraction() * HOURS_PER_DAY


func is_daylight() -> bool:
	return sun_altitude > 0.0


## Solar irradiance proxy for plant growth — the sine of the sun's
## altitude: 0 at or below the horizon, ~0.66 mid-morning, ~0.94 at this
## site's noon. Unlike `sun.light_energy` (a twilight ramp that
## saturates by mid-morning for the display), this tracks the true
## angle, so dawn, mid-morning and noon stay distinguishable.
func sun_intensity() -> float:
	return maxf(0.0, sin(sun_altitude))


## The game clock in milliseconds — the monotone counter every gameplay
## timer (plant growth, job retries, blacklist cool-offs) compares
## against, so speed controls and pauses apply to all of them alike.
func game_msec() -> int:
	return int(planet_time * 1000.0)


## The HUD's clock readout.
func clock_text() -> String:
	var hours := local_hours()
	return "Day %d, %02d:%02d" % [
		day_number(), int(hours), int(fmod(hours, 1.0) * 60.0)
	]


## Recomputes the sun from planet time and the site's coordinates, then
## points the light and dims the sky — standard horizontal-frame solar
## math: hour angle from local time, altitude and azimuth from latitude
## and the solar declination.
func _apply_sun() -> void:
	var hour_angle := (day_fraction() - 0.5) * TAU
	var lat := deg_to_rad(site_latitude_deg)
	var decl := deg_to_rad(solar_declination_deg)
	var sin_alt := clampf(
		sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hour_angle),
		-1.0, 1.0
	)
	sun_altitude = asin(sin_alt)
	var cos_az := clampf(
		(sin(decl) - sin_alt * sin(lat))
			/ maxf(cos(sun_altitude) * cos(lat), 0.0001),
		-1.0, 1.0
	)
	sun_azimuth = acos(cos_az)
	if sin(hour_angle) > 0.0:
		# Afternoon — the azimuth swings from east round to west.
		sun_azimuth = TAU - sun_azimuth
	var dir := Vector3(
		sin(sun_azimuth) * cos(sun_altitude),
		sin(sun_altitude),
		-cos(sun_azimuth) * cos(sun_altitude)
	)
	# The light shines along its -Z, so aim -Z down the sun's rays.
	sun.transform.basis = Basis.looking_at(-dir)
	# Twilight ramps brightness instead of snapping it.
	var day_factor := clampf((sin_alt + 0.02) * 6.0, 0.0, 1.0)
	sun.light_energy = day_factor
	var env := world_environment.environment
	if env != null:
		env.ambient_light_sky_contribution = day_factor
		if env.sky != null:
			var sky_material := env.sky.sky_material as ProceduralSkyMaterial
			if sky_material != null:
				sky_material.sky_energy_multiplier = lerpf(
					NIGHT_SKY_FLOOR, 1.0, day_factor
				)
				sky_material.ground_energy_multiplier = \
					sky_material.sky_energy_multiplier
