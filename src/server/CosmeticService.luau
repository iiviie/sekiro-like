--!strict
-- Keeps each player's equipped cosmetics on their character, in the lobby and in matches:
-- the outfit (server/Outfit.wearPlayer), the blade look (SwordRig.applySkin: skin or blade
-- line at its level, weapon Mastery evolutions) and the finisher their deathblows play (the
-- character's Finisher attribute, read by client/CombatVisuals). Re-dresses when the Loadout,
-- LineLevels or WeaponMastery attributes change and when a new character loads. Also publishes
-- WeaponMastery (per-weapon Mastery levels from the saved WeaponXP) for the evolutions.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Wear = require(ReplicatedStorage.Shared.Cosmetics.Wear)
local Outfit = require(script.Parent.Outfit)
local StatsService = require(script.Parent.StatsService)
local SwordRig = require(script.Parent.SwordRig)

local CosmeticService = {}

local APPEARANCE_TIMEOUT = 15

local function dressBlade(player: Player, character: Model)
	local weapon = character:GetAttribute("Weapon")
	local id, level, mastery = Cosmetics.bladeOf(player, if typeof(weapon) == "string" then weapon else nil)
	local sword = character:FindFirstChild("Sword")
	if not sword then
		return
	end
	if
		sword:GetAttribute("Look") == Cosmetics.Blades.look(id, level, mastery).id
		and character:GetAttribute("BladeLevel") == level
		and character:GetAttribute("BladeMastery") == mastery
	then
		return -- already wearing exactly this
	end
	SwordRig.applySkin(character)
end

local function dress(player: Player)
	local character = player.Character
	if not character or not character.Parent then
		return
	end
	character:SetAttribute("Finisher", Cosmetics.equippedRef(player, "finisher") or "Default")
	if player:GetAttribute("DataLoaded") == true or player:GetAttribute("DataFailed") == true then
		Outfit.wearPlayer(character, Cosmetics.equippedRef(player, "outfit"))
	end
	dressBlade(player, character)
end

local function onCharacter(player: Player, character: Model)
	-- Wait for the avatar's own clothes to arrive, so the outfit goes on over them (not under).
	local deadline = os.clock() + APPEARANCE_TIMEOUT
	while not (player:HasAppearanceLoaded() and character:IsDescendantOf(workspace)) do
		if os.clock() > deadline or player.Character ~= character then
			break
		end
		task.wait(0.2)
	end
	if player.Character ~= character then
		return
	end
	dress(player)
	-- Avatar loading can add clothes after that: keep them off while the outfit is on.
	character.ChildAdded:Connect(function(child)
		if Wear.current(character) ~= "" and Wear.isClothing(child) then
			task.defer(Outfit.cover, character, child)
		end
	end)
	-- A re-rigged sword (weapon swap, respawn grip) is dressed by SwordRig.attach itself.
	character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(game) then
			Outfit.forget(character)
		end
	end)
end

local function onPlayer(player: Player)
	for _, name in { "Loadout", "LineLevels", "WeaponMastery", "DataLoaded" } do
		player:GetAttributeChangedSignal(name):Connect(function()
			dress(player)
		end)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

function CosmeticService.start()
	StatsService.onPublish(function(player: Player, d: StatsService.Data)
		local levels = {}
		for weapon, xp in d.WeaponXP do
			levels[weapon] = Cosmetics.masteryLevel(xp)
		end
		player:SetAttribute("WeaponMastery", HttpService:JSONEncode(levels))
	end)
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return CosmeticService
