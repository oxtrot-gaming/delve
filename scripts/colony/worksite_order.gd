class_name WorksiteOrder
extends RefCounted

## One queued bill on a worksite — RimWorld's bill model: a recipe plus
## the condition that decides when it's done ordering. The queue itself
## lives on the worksite's [Building] record; an order carries no
## inputs — items escrow into the *job* once it runs, so a queued order
## is pure intent and a cancelled one loses nothing.
enum Condition {
	## Run the recipe [member target] more times, then leave the queue.
	TIMES,
	## Keep the recipe running while the colony holds fewer than
	## [member target] of the recipe's output; pauses in place while
	## stocked, resumes when the count drops.
	UNTIL_HAVE,
	## Run the recipe whenever inputs exist, forever.
	FOREVER,
}

## Which entry in [constant Colony.RECIPES] this order runs.
var recipe: StringName = &""
var condition: Condition = Condition.TIMES
## Run count for [constant TIMES], stock target for [constant UNTIL_HAVE];
## ignored by [constant FOREVER].
var target: int = 1
## Successful runs so far — what [constant TIMES] counts against.
var done: int = 0


## Whether this order wants work right now — a satisfied UNTIL_HAVE
## isn't unperformable, it's parked: it keeps its place in line and
## waits for the stock count to dip.
func wants_work(have: int) -> bool:
	return (
		condition == Condition.FOREVER
		or (condition == Condition.TIMES and done < target)
		or (condition == Condition.UNTIL_HAVE and have < target)
	)


## Player-facing summary for the queue row — "×3 (1/3)",
## "≥6 (4 there)", "∞ (7 done)".
func summary(have: int) -> String:
	match condition:
		Condition.TIMES:
			return "×%d (%d/%d)" % [target, done, target]
		Condition.UNTIL_HAVE:
			return "≥%d (%d there)" % [target, have]
		Condition.FOREVER:
			return "∞ (%d done)" % done
	return ""
