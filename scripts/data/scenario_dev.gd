class_name DevScenario
extends RefCounted

## The debug embark — the bare landing the test suite and the direct
## main.tscn boot use: three settlers, no gear, no animals. Nothing the
## scenario layer adds changes behaviour here.


static func scenario() -> Dictionary:
	return {
		&"id": &"dev",
		&"package": &"vanilla",
		&"name": "Debug landing",
		&"description": (
			"Three settlers, empty-handed — the smoke test's zero-"
			+ "frills start."
		),
		&"settler_count": 3,
		&"entry": {&"kind": &"periphery"},
	}
