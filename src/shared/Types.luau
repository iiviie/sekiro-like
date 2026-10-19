--!strict
export type CombatState = "Idle" | "Windup" | "Recovery" | "Staggered" | "Broken" | "Dead"
export type Action = "Attack" | "Perilous" | "BlockDown" | "BlockUp" | "Dodge"

local Types = {
	-- CollectionService tag on every model the combat system manages (players and bots).
	Tag = "Combatant",
	Actions = { "Attack", "Perilous", "BlockDown", "BlockUp", "Dodge" } :: { Action },
}

return Types
