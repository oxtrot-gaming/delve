extends SceneTree

## Focused check for item 48's recipe-table retool — wall/floor specs
## and the fit predicates, no world needed.


func _init() -> void:
	var fails := 0
	var ok := func(cond: bool, label: String) -> void:
		if cond:
			print("  ok: " + label)
		else:
			fails += 1
			print("  FAILED: " + label)

	var block := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.BLOCK,
		DropItem.STONE_BLOCK_CM3
	)
	var boulder := DropItem.new(
		BlockRegistry.Resource_.STONE, DropItem.Form.BOULDER,
		DropItem.BOULDER_CM3
	)
	ok.call(
		BlockRegistry.item_fits_wall(block, BlockRegistry.Resource_.STONE),
		"dressed blocks are wall material"
	)
	ok.call(
		not BlockRegistry.item_fits_wall(
			boulder, BlockRegistry.Resource_.STONE
		),
		"boulders no longer wall"
	)
	ok.call(
		BlockRegistry.build_recipe(&"stone_wall")
			== {DropItem.Form.BLOCK: 600_000},
		"a stone wall is 120 blocks"
	)
	ok.call(
		BlockRegistry.build_recipe(&"stone_door")
			== {DropItem.Form.BLOCK: 750_000},
		"a stone door is 150 blocks"
	)
	ok.call(
		BlockRegistry.spec_offcut(&"stone_door") == 0,
		"a stone door drops no offcut"
	)
	ok.call(
		BlockRegistry.floor_recipe(&"flagstone")
			== {DropItem.Form.BLOCK: 100_000},
		"flagstone takes 20 blocks"
	)
	ok.call(
		BlockRegistry.item_fits_floor(block, &"flagstone")
			and not BlockRegistry.item_fits_floor(boulder, &"flagstone"),
		"blocks pave, boulders don't"
	)
	ok.call(
		Colony.recipe_site_rate(
			Colony.recipe_of(&"cut_blocks_boulder"),
			Building.Kind.STONECUTTER
		) == 1.0
			and Colony.recipe_site_rate(
				Colony.recipe_of(&"cut_blocks_boulder"),
				Building.Kind.WORKSITE
			) == 0.0,
		"cut bills pin to the stonecutter"
	)
	ok.call(
		Colony.RECIPES[&"stonecutter_bench"]["builds"]
			== Building.Kind.STONECUTTER,
		"the bench builds a STONECUTTER"
	)
	var bench := Building.new(Building.Kind.STONECUTTER, Vector3i.ZERO)
	ok.call(bench.is_worksite(), "the stonecutter is a worksite")
	ok.call(
		bench.label() == "Stonecutter's bench", "the bench is labelled"
	)

	print("BLOCK PROBE %s" % ("PASSED" if fails == 0 else "FAILED %d" % fails))
	quit(1 if fails > 0 else 0)
