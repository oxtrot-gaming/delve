class_name TribalScenario
extends RefCounted

## The Lost Tribe start — the game's reference scenario. Five settlers
## walk in with stone-age gear, a little food, and three head of
## livestock; they know fire and charcoal but no metallurgy. Per-settler
## rolls give each a trade; every ungated skill also rolls in the
## background band so nobody is dead weight.


static func scenario() -> Dictionary:
	return {
		&"id": &"lost_tribe",
		&"package": &"vanilla",
		&"name": "Lost Tribe",
		&"description": (
			"Five tribal settlers and three head of swine, with knapped "
			+ "tools and a food store. No metal, no machines."
		),
		&"settler_count": 5,
		# Every ungated skill rolls in this band — background competence;
		# the roster entries below layer a trade on top.
		&"skill_range": [0, 2],
		&"settlers": [
			{&"skills": {&"plants": [3, 5], &"cooking": [1, 3]}},
			{&"skills": {&"mining": [3, 4], &"construction": [2, 3]}},
			{&"skills": {&"animals": [3, 4], &"plants": [1, 2]}},
			{&"skills": {&"crafting": [3, 4], &"cooking": [1, 2]}},
			{&"skills": {&"medicine": [2, 4], &"butchering": [1, 2]}},
		],
		# Tribal common knowledge — fire-kept charcoal; nothing metallic.
		&"knowledge": [&"charcoal_burning"],
		# The founding herd — domestic stock, penned by the player.
		&"animals": [{&"species": &"boar", &"count": 3, &"domestic": true}],
		# The landing scatter: pemmican for the first days, a few heal-all
		# bundles for the first wounds, and a knapped tool apiece where it
		# matters — axe for timber, pick for the first dig, shovel for
		# the tailings.
		&"items": [
			{&"form": &"meal", &"material": &"pemmican", &"count": 24},
			{&"form": &"fruit", &"material": &"medicine", &"count": 6},
			{&"form": &"tool", &"spec": &"stone_axe", &"count": 1},
			{&"form": &"tool", &"spec": &"stone_pick", &"count": 1},
			{&"form": &"tool", &"spec": &"stone_shovel", &"count": 1},
			{&"form": &"loose", &"material": &"branch", &"cm3": 120_000},
		],
		# Newcomers enter where their travel line crosses the site edge.
		&"entry": {&"kind": &"periphery"},
	}
