--!strict
-- The thin ink outline on blades, drawn locally. server/SwordRig tags every sword
-- "BladeOutline" and Shared/Cosmetics/BladeLook puts the look's colours on it as attributes.
-- Each Highlight is a full-screen pass and the engine draws at most 31 at once, so only the
-- MAX blades nearest the camera (within RANGE) get one: the perilous tell's Highlight
-- (client/CombatVisuals) always has room, however full the server is. Under Fewer particles
-- (SettingReducedEffects, on by default on low-end phones: client/init) only MAX_REDUCED.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local BladeOutlines = {}

local TAG = "BladeOutline"
local RANGE = 60
local MAX = 12
local MAX_REDUCED = 4
local INTERVAL = 0.2
local OUTLINE = Color3.fromRGB(20, 18, 22)
local FILL = Color3.fromRGB(235, 240, 255)

local outlines: { [BasePart]: Highlight } = {}

local function make(sword: BasePart): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "BladeOutline"
	highlight.Adornee = sword
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0.15
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = sword
	return highlight
end

local function refresh()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local near: { { sword: BasePart, distance: number } } = {}
	for _, instance in CollectionService:GetTagged(TAG) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(workspace) then
			local distance = (instance.Position - eye).Magnitude
			if distance <= RANGE then
				table.insert(near, { sword = instance, distance = distance })
			end
		end
	end
	table.sort(near, function(a, b)
		return a.distance < b.distance
	end)
	local reduced = Players.LocalPlayer:GetAttribute("SettingReducedEffects") == true
	local keep: { [BasePart]: boolean } = {}
	for i = 1, math.min(#near, if reduced then MAX_REDUCED else MAX) do
		keep[near[i].sword] = true
	end
	for sword, highlight in outlines do
		if not keep[sword] then
			highlight:Destroy()
			outlines[sword] = nil
		end
	end
	for sword in keep do
		local highlight = outlines[sword]
		if not highlight or highlight.Parent ~= sword then
			highlight = make(sword)
			outlines[sword] = highlight
		end
		local outline, fill = sword:GetAttribute("OutlineColor"), sword:GetAttribute("OutlineFill")
		highlight.OutlineColor = if typeof(outline) == "Color3" then outline else OUTLINE
		highlight.FillColor = if typeof(fill) == "Color3" then fill else FILL
	end
end

function BladeOutlines.start()
	task.spawn(function()
		while true do
			refresh()
			task.wait(INTERVAL)
		end
	end)
end

return BladeOutlines
