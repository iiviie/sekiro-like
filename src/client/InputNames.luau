--!strict
-- What each fight input is called on the player's current controls (keyboard and mouse,
-- gamepad or touch), so the Guide and the Coach name what's actually under their hands.
-- The bindings themselves live in CombatInput and TouchHUD (whose buttons carry these
-- names); the README's controls table lists all three.

local UserInputService = game:GetService("UserInputService")

export type Scheme = "Keyboard" | "Gamepad" | "Touch"
export type Names = {
	block: string,
	attack: string,
	dodge: string,
	heal: string,
	thrust: string,
	sweep: string,
	jump: string,
	lock: string,
}

local NAMES: { [Scheme]: Names } = {
	Keyboard = {
		block = "F",
		attack = "click",
		dodge = "Q",
		heal = "G",
		thrust = "E",
		sweep = "C",
		jump = "Space",
		lock = "R",
	},
	Gamepad = {
		block = "L1",
		attack = "R1",
		dodge = "B",
		heal = "D-pad up",
		thrust = "Y",
		sweep = "X",
		jump = "A",
		lock = "R3",
	},
	-- TouchHUD's button labels.
	Touch = {
		block = "Deflect",
		attack = "Slash",
		dodge = "Dodge",
		heal = "Heal",
		thrust = "Thrust",
		sweep = "Sweep",
		jump = "Jump",
		lock = "Lock",
	},
}

local InputNames = {}

function InputNames.scheme(): Scheme
	if workspace:GetAttribute("ForceTouchHUD") == true then
		return "Touch" -- test aid: the phone controls with a mouse in Studio
	end
	-- PreferredInput follows the device in use (newer engines); fall back to the last input.
	local ok, preferred = pcall(function(): any
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(preferred) == "EnumItem" then
		if preferred.Name == "Touch" then
			return "Touch"
		elseif preferred.Name == "Gamepad" then
			return "Gamepad"
		end
		return "Keyboard"
	end
	local last = UserInputService:GetLastInputType()
	if last.Name:match("^Gamepad") then
		return "Gamepad"
	elseif last == Enum.UserInputType.Touch then
		return "Touch"
	end
	local other = last == Enum.UserInputType.Keyboard or last.Name:match("^Mouse") ~= nil
	return if UserInputService.TouchEnabled
			and not UserInputService.KeyboardEnabled
			and not other
		then "Touch"
		else "Keyboard"
end

-- Every input's name on the current controls ("F", "L1", "Deflect", ...).
function InputNames.get(): Names
	return NAMES[InputNames.scheme()]
end

return InputNames
