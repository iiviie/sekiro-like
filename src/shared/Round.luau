--!strict
-- Round state shared by server and clients. The server writes a few attributes on
-- ReplicatedStorage.RoundState when a phase starts; clients derive everything else
-- (timers, the ring's current radius) from those and the synced clock, so nothing
-- needs to be sent per frame.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Phase = "Intermission" | "Match" | "Results"

local Round = {}

function Round.state(): Folder
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild("RoundState")
		if existing and existing:IsA("Folder") then
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = "RoundState"
		folder.Parent = ReplicatedStorage
		return folder
	end
	return ReplicatedStorage:WaitForChild("RoundState") :: Folder
end

function Round.phase(): Phase
	return (Round.state():GetAttribute("Phase") or "Intermission") :: Phase
end

function Round.endsAt(): number
	return Round.state():GetAttribute("EndsAt") or 0
end

-- The ring's centre and radius at server time `t`. Radius is math.huge outside a match.
function Round.zone(t: number): (Vector3, number)
	local state = Round.state()
	local center: Vector3 = state:GetAttribute("ZoneCenter") or Vector3.zero
	if state:GetAttribute("Phase") ~= "Match" then
		return center, math.huge
	end
	local startRadius: number = state:GetAttribute("ZoneStartRadius") or math.huge
	local endRadius: number = state:GetAttribute("ZoneEndRadius") or startRadius
	local shrinkStart: number = state:GetAttribute("ZoneShrinkStart") or math.huge
	local shrinkEnd: number = state:GetAttribute("ZoneShrinkEnd") or shrinkStart
	local alpha = math.clamp((t - shrinkStart) / math.max(shrinkEnd - shrinkStart, 1e-3), 0, 1)
	return center, startRadius + (endRadius - startRadius) * alpha
end

return Round
