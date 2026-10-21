--!strict
-- Hatamoto VIP (game pass `pass.VIP`, cosmetic only, no boosts; the module, the plate id and the
-- sheath keep the old name "Ronin" so saves and tooling don't break): an exclusive black-lacquer
-- sheath with wisteria cord and gold fittings on the left hip, with a faint wisteria aura.
-- The rest of the pass lives elsewhere: the Hatamoto nameplate frame (`plate.Ronin`, granted by
-- server/Monetization) and the chat tag: client/ChatTags with TextChatService, or the speaker
-- tag below while the place still runs the legacy chat (TextChatService.ChatVersion). Keyed
-- on the player's `VIP` attribute (Monetization), so it appears the moment the pass is bought.

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")

local Ronin = {}

local NAME = "RoninSheath"
local LACQUER = Color3.fromRGB(22, 16, 26)
local WISTERIA = Color3.fromRGB(186, 120, 236)
local GOLD = Color3.fromRGB(214, 168, 80)
-- In LowerTorso space: the mouth by the front of the left hip, the tip down and behind.
local MOUTH = Vector3.new(-1.05, 0.1, -0.75)
local TIP = Vector3.new(-1.2, -0.85, 1.6)

local function part(name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.CastShadow = false
	return p
end

local function weld(holder: Instance, a: BasePart, b: BasePart, c0: CFrame)
	local w = Instance.new("Weld")
	w.Part0 = a
	w.Part1 = b
	w.C0 = c0
	w.Parent = holder
end

local function build(lower: BasePart): Model
	local model = Instance.new("Model")
	model.Name = NAME
	local axis = CFrame.lookAt((MOUTH + TIP) / 2, MOUTH) -- -Z (front) is the mouth end
	local length = (TIP - MOUTH).Magnitude
	local body = part("Saya", Vector3.new(0.24, 0.15, length), LACQUER)
	body.Reflectance = 0.03
	body.Parent = model
	weld(model, lower, body, axis)
	-- Gold collar at the mouth, gold cap at the tip, a wisteria cord tied near the mouth.
	local collar = part("Koiguchi", Vector3.new(0.28, 0.19, 0.12), GOLD, Enum.Material.Metal)
	collar.Parent = model
	weld(model, body, collar, CFrame.new(0, 0, -length / 2 + 0.06))
	local cap = part("Kojiri", Vector3.new(0.28, 0.19, 0.14), GOLD, Enum.Material.Metal)
	cap.Parent = model
	weld(model, body, cap, CFrame.new(0, 0, length / 2 - 0.07))
	local cord = part("Sageo", Vector3.new(0.27, 0.18, 0.1), WISTERIA, Enum.Material.Fabric)
	cord.Parent = model
	weld(model, body, cord, CFrame.new(0, 0, -length / 2 + 0.42))
	-- The aura: a few slow wisteria motes along the lacquer.
	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Aura"
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(WISTERIA)
	motes.LightEmission = 0.8
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0) })
	motes.Transparency = NumberSequence.new(0.2, 1)
	motes.Lifetime = NumberRange.new(1, 1.6)
	motes.Rate = 3
	motes.Speed = NumberRange.new(0.2, 0.4)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Parent = body
	return model
end

-- Legacy chat only: the [Hatamoto] tag on the player's speaker (ChatServiceRunner's ChatService).
local legacyChat: any = nil
local function legacyTag(player: Player)
	if TextChatService.ChatVersion ~= Enum.ChatVersion.LegacyChatService then
		return
	end
	if not legacyChat then
		local runner = ServerScriptService:FindFirstChild("ChatServiceRunner")
		local module = runner and runner:WaitForChild("ChatService", 10)
		if not module then
			return
		end
		local ok, loaded = pcall(require, module)
		if not ok then
			return
		end
		legacyChat = loaded
	end
	task.spawn(function()
		local speaker = nil
		for _ = 1, 40 do
			speaker = legacyChat:GetSpeaker(player.Name)
			if speaker or not player.Parent then
				break
			end
			task.wait(0.25)
		end
		if speaker then
			local tags = if player:GetAttribute("VIP") == true
				then { { TagText = "Hatamoto", TagColor = WISTERIA } }
				else {}
			speaker:SetExtraData("Tags", tags)
		end
	end)
end

local function refresh(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local existing = character:FindFirstChild(NAME)
	local vip = player:GetAttribute("VIP") == true
	if vip and not existing then
		local lower = character:FindFirstChild("LowerTorso")
		if lower and lower:IsA("BasePart") then
			build(lower).Parent = character
		end
	elseif not vip and existing then
		existing:Destroy()
	end
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("LowerTorso", 10)
		refresh(player)
	end)
	player:GetAttributeChangedSignal("VIP"):Connect(function()
		refresh(player)
		legacyTag(player)
	end)
	refresh(player)
	legacyTag(player)
end

function Ronin.start()
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return Ronin
