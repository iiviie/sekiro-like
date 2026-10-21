--!strict
-- What the local player's block button has been doing, mirrored from the server's rules,
-- so an incoming swing's outcome can be shown on screen the instant it lands instead of
-- a round trip later. The server still decides; this only drives effects. Whenever the
-- server opens a deflect window it publishes it (DeflectAt / DeflectWindow attributes), and
-- that replaces the local guess, so buffered presses and re-raised guards mirror exactly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Weapons = require(ReplicatedStorage.Shared.Weapons)

export type Defence = "Perfect" | "Deflect" | "Guard"
-- Our own latest swing, on the server clock (set by CombatVisuals as it starts; confirmed
-- once the server's Windup for it arrives).
export type Swing = { kind: Config.AttackKind, startedAt: number, hitAt: number, confirmed: boolean }

local LocalCombat = {
	deflectStamp = -math.huge, -- server-clock time the latest deflect window opened
	deflectWindow = Config.Deflect.Window,
	pressStamp = -math.huge, -- when the latest press was made (before any re-press delay)
	pressDelayed = false, -- that press was a re-press too soon after lowering guard
	blocking = false,
	lastReleaseAt = -math.huge, -- server-clock times, mirroring CombatService's anti-mash rule
	lastContactAt = -math.huge,
	lastDefendAt = -math.huge,
	riposteUntil = -math.huge, -- server-clock time a slash still counts as a Riposte
	mikiriUntil = -math.huge, -- ...as a MikiriSlash
	dodgeAt = -math.huge, -- ...when our latest dodge started (DodgeSlash)
	lastSlashLanded = false, -- our previous swing hit cleanly, so the string speeds up
	idleSince = 0, -- os.clock() when our character last became free to act
	attackingUntil = 0, -- os.clock() until which our predicted (unconfirmed) swing commits us
	swing = nil :: Swing?,
}

-- Whether our own swing commits us right now: the server says Windup or Recovery, or we
-- predicted one the server hasn't confirmed yet.
function LocalCombat.swinging(character: Model): boolean
	local state = character:GetAttribute("CombatState")
	if state == "Windup" or state == "Recovery" then
		return LocalCombat.swing ~= nil
	end
	local swing = LocalCombat.swing
	return swing ~= nil and not swing.confirmed and state == "Idle" and os.clock() < LocalCombat.attackingUntil
end

-- Whether our character may act on `input` now, mirroring CombatService.free: never in a
-- windup; in recovery only from the move's own cancel point for that input.
function LocalCombat.canAct(character: Model, input: "Attack" | "Block" | "Dodge" | "Jump" | "Heal"): boolean
	local swing = LocalCombat.swing
	if swing and LocalCombat.swinging(character) then
		local t = workspace:GetServerTimeNow()
		if character:GetAttribute("CombatState") == "Windup" or t < swing.hitAt then
			return false
		end
		local at = (Weapons.spec(Weapons.of(character), swing.kind).cancel :: any)[input] :: number?
		return at ~= nil and t >= swing.hitAt + at
	end
	return character:GetAttribute("CombatState") == "Idle"
end

-- Mirrors CombatService.armDeflect: a re-press soon after lowering guard opens late, a
-- press soon after our own deflect or guarded hit opens at once.
function LocalCombat.pressBlock(stamp: number)
	local rules = Config.Deflect
	local delayed = stamp - LocalCombat.lastDefendAt > rules.ChainPress
		and stamp - LocalCombat.lastReleaseAt <= rules.RepressLockout
		and LocalCombat.lastContactAt < LocalCombat.lastReleaseAt
	LocalCombat.pressStamp = stamp
	LocalCombat.pressDelayed = delayed
	LocalCombat.deflectStamp = stamp + (if delayed then rules.RepressDelay else 0)
	LocalCombat.deflectWindow = rules.Window
	LocalCombat.blocking = true
end

-- The server opened a window (an attribute arrived): trust its stamp over our guess.
function LocalCombat.confirm(stamp: number, window: number)
	LocalCombat.deflectStamp = stamp
	LocalCombat.deflectWindow = window
	if stamp > LocalCombat.pressStamp + Config.Deflect.RepressDelay + 0.01 then
		-- A buffered press or a re-raised guard: the window opened later than our press.
		LocalCombat.pressStamp = stamp
		LocalCombat.pressDelayed = false
	end
end

function LocalCombat.releaseBlock(stamp: number)
	if LocalCombat.blocking then
		LocalCombat.lastReleaseAt = stamp
	end
	LocalCombat.blocking = false
end

-- A blow reached us (whatever the outcome).
function LocalCombat.contact()
	LocalCombat.lastContactAt = workspace:GetServerTimeNow()
end

-- We deflected or guarded: the next press opens at once. A deflect that recoiled the
-- attacker (or broke them) opens the Riposte (mirrors the server).
function LocalCombat.defended(recoil: boolean)
	local t = workspace:GetServerTimeNow()
	LocalCombat.lastDefendAt = t
	LocalCombat.lastContactAt = t
	if recoil then
		LocalCombat.riposteUntil = t + Config.Deflect.RiposteWindow
	end
end

-- How a blockable swing landing at `hitAt` would be met, or nil for a clean hit.
function LocalCombat.predictDefence(hitAt: number): Defence?
	local since = hitAt - LocalCombat.deflectStamp
	local window = LocalCombat.deflectWindow
	if since >= -Config.Deflect.LateTolerance and since <= window then
		return if since <= math.min(Config.Deflect.PerfectWindow, window) then "Perfect" else "Deflect"
	end
	return if LocalCombat.blocking then "Guard" else nil
end

return LocalCombat
