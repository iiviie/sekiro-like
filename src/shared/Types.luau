--!strict
export type CombatState = "Idle" | "Windup" | "Recovery" | "Staggered" | "Broken" | "Drinking" | "Dead"
export type Action = "Attack" | "Perilous" | "Sweep" | "BlockDown" | "BlockUp" | "Dodge" | "Jump" | "Heal"

local Types = {
	-- CollectionService tag on every model the combat system manages (players and bots).
	Tag = "Combatant",
	Actions = { "Attack", "Perilous", "Sweep", "BlockDown", "BlockUp", "Dodge", "Jump", "Heal" } :: { Action },
}

return Types
