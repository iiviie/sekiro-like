--!strict
export type CombatState =
	"Idle"
	| "Windup"
	| "Recovery"
	| "Staggered"
	| "Broken"
	| "Drinking"
	| "Dodging"
	| "Downed"
	| "Dead"
export type Action =
	"Attack"
	| "Perilous"
	| "Sweep"
	| "BlockDown"
	| "BlockUp"
	| "Dodge"
	| "Jump"
	| "Stomp" -- a second jump press in the air (over a sweeper)
	| "Heal"
	| "Ready"

local Types = {
	-- CollectionService tag on every model the combat system manages (players and bots).
	Tag = "Combatant",
	Actions = {
		"Attack",
		"Perilous",
		"Sweep",
		"BlockDown",
		"BlockUp",
		"Dodge",
		"Jump",
		"Stomp",
		"Heal",
		"Ready",
	} :: { Action },
}

return Types
