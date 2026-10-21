--!strict
-- Robux purchases: developer products through an idempotent ProcessReceipt, game passes with
-- cached ownership, PolicyService per player, and a Studio-only mock path so the whole flow
-- can be tested before the place is published.
--
--   Monetization.prompt(player, key)          -> (boolean, string?)  ask Roblox to sell `key`
--   Monetization.ownsPass(player, key)        -> boolean             game pass, cached
--   Monetization.paidRandomRestricted(player) -> boolean             PolicyService, cached
--   Monetization.setGrant(key, handler)       replace what a product grants (part S: the pass)
--   Monetization.mockReceipt(player, key, purchaseId?) -> Enum.ProductPurchaseDecision (Studio)
--   Monetization.mockPass(player, key)        -> boolean             Studio
--   Monetization.mockPolicy(player, restricted)  stub ArePaidRandomItemsRestricted (Studio)
--
-- Keys and ids: Shared/Catalog.Products (ids 0 until the products exist). The client asks
-- with LobbyAction ("Purchase", key); every rule is checked here.
--
-- Receipts: a purchase is granted once. The PurchaseId goes into the profile's ledger in the
-- same step as the grant, and ProcessReceipt answers PurchaseGranted only after a save that
-- includes it has committed; a receipt for a player whose profile isn't loaded (or can't
-- save) is NotProcessedYet, so Roblox retries it later. A repeat of a ledgered PurchaseId
-- grants nothing and just confirms the save.
--
-- Published per player: Passes (owned pass keys, comma separated), VIP, LoadoutSlots,
-- TitleSlots, VictoryCry, PaidRandomRestricted, SeasonPremium (this season bought).
-- Each purchase also tells the buyer what it granted: Progress "Purchased" { key, items,
-- equipped, gems?, coins? } (client/StoreUI plays the thank-you reveal). Items whose Catalog
-- status is "soon" (or whose category isn't Ready) are refused before any prompt.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Text = require(ReplicatedStorage.Shared.Text)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Economy = require(script.Parent.Economy)
local StatsService = require(script.Parent.StatsService)

type Data = StatsService.Data
-- Applies a product's contents to the profile. Must not yield (it runs between the ledger
-- check and the ledger write).
export type GrantHandler = (player: Player, d: Data, key: string) -> ()

local Monetization = {}

local passes: { [Player]: { [string]: boolean } } = {}
local restricted: { [Player]: boolean } = {}
local grants: { [string]: GrantHandler } = {}
local IS_STUDIO = RunService:IsStudio()

local function tell(player: Player, kind: string, payload: { [string]: any })
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local progress = remotes and remotes:FindFirstChild("Progress")
	if progress and progress:IsA("RemoteEvent") then
		progress:FireClient(player, kind, payload)
	end
end

local function notice(player: Player, text: string)
	tell(player, "Notice", { text = text })
end

-- What a purchase granted, for the client's thank-you reveal: Progress "Purchased" { key,
-- items, gems, coins, equipped } (items newly owned, equipped = the ones put on over a default).
-- Deferred so the grant's attributes have replicated first.
local function announce(
	player: Player,
	key: string,
	items: { string },
	equipped: { string },
	gems: number?,
	coins: number?
)
	task.defer(tell, player, "Purchased", { key = key, items = items, equipped = equipped, gems = gems, coins = coins })
end

local function contents(player: Player, d: Data, key: string)
	local item = Catalog.get(key)
	local c = item and item.contents
	if not item or not c then
		return
	end
	if item.once then
		-- A once-per-account bundle is itself owned, so it's never offered again. (A second
		-- paid receipt still pays its currencies; owned items are skipped.)
		Economy.own(player, key, "robux", true)
	end
	if c.gems then
		Economy.grant(player, "Gems", c.gems, key, "IAP", true)
	end
	if c.coins then
		Economy.grant(player, "Coins", c.coins, key, "IAP", true)
	end
	local owned, equipped = {}, {}
	for _, id in c.items or {} do
		if Economy.own(player, id, "robux", true) then
			table.insert(owned, id)
		end
		if c.lineLevel and Catalog.get(id) and (Catalog.get(id) :: Catalog.Item).category == "bladeLine" then
			d.LineLevels[id] = math.max(d.LineLevels[id] or 1, c.lineLevel)
		end
	end
	-- The bundle's blade and title go straight on over the defaults (the reveal offers the rest).
	for _, id in owned do
		if Economy.equipIfDefault(player, id) then
			table.insert(equipped, id)
		end
	end
	announce(player, key, owned, equipped, c.gems, c.coins)
end

-- Default grants: gem packs and bundles pay their contents; the season products record
-- what was bought for part S's PassService to apply (it can replace these with setGrant).
for _, item in Catalog.Items do
	if item.category == "gemPack" or item.category == "bundle" then
		grants[item.id] = contents
	end
end
grants["pass.Premium"] = function(_player, d, _key)
	d.SeasonPremium[EconomyConfig.Season] = os.time()
end
grants["pass.TierSkip"] = function(_player, d, _key)
	d.PassTierSkips += 1
end
grants["pass.Tiers10"] = function(_player, d, _key)
	d.PassTierSkips += 10
end

-- A grant that isn't a bundle or gem pack (contents() announces those): say what was bought.
local function withAnnounce(key: string, handler: GrantHandler): GrantHandler
	local item = Catalog.get(key)
	if item and item.contents then
		return handler
	end
	return function(player, d, k)
		handler(player, d, k)
		announce(player, key, {}, {}, nil, nil)
	end
end

function Monetization.setGrant(key: string, handler: GrantHandler)
	grants[key] = handler
end

-- Whether `player` may buy `key` right now, and why not.
local function eligible(player: Player, key: string): (boolean, string?)
	local item = Catalog.get(key)
	local product = Catalog.Products[key]
	if not item or not product then
		return false, "That isn't for sale."
	end
	if not StatsService.canTransact(player) then
		return false, Text.ProgressFailed
	end
	if not Catalog.isReady(item) then
		return false, "Coming soon."
	end
	local d = StatsService.get(player) :: Data
	if product.kind == "gamepass" then
		if Monetization.ownsPass(player, key) then
			return false, "You already own this."
		end
	elseif key == "bundle.Initiate" then
		local onOffer = Economy.initiateOffer(player)
		if not onOffer then
			return false, "The Initiate's Bundle is no longer on offer."
		end
	elseif item.once and d.Inventory[key] ~= nil then
		return false, "You already own this."
	elseif key == "pass.Premium" and d.SeasonPremium[EconomyConfig.Season] then
		return false, "You already have this season's premium pass."
	end
	return true, nil
end

local function useMock(product: Catalog.Product): boolean
	return IS_STUDIO and (product.id == 0 or ServerStorage:GetAttribute("MockPurchases") == true)
end

local function logPrompt(player: Player, key: string)
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "PurchasePrompt", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = key,
		})
	end)
end

local function publish(player: Player)
	local owned = passes[player] or {}
	local keys = {}
	for key, has in owned do
		if has then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	player:SetAttribute("Passes", table.concat(keys, ","))
	player:SetAttribute("VIP", owned["pass.VIP"] == true)
	player:SetAttribute("LoadoutSlots", if owned["pass.Loadouts"] then 6 else 3)
	player:SetAttribute("TitleSlots", if owned["pass.TitleSlot"] then 2 else 1)
	player:SetAttribute("VictoryCry", owned["pass.VictoryCry"] == true)
	player:SetAttribute("PaidRandomRestricted", restricted[player] ~= false)
	local d = StatsService.get(player)
	player:SetAttribute("SeasonPremium", d ~= nil and d.SeasonPremium[EconomyConfig.Season] ~= nil)
end

-- Hands out what every owned pass carries (once the profile is loaded).
local function passItems(player: Player)
	if not StatsService.get(player) then
		return
	end
	for key, has in passes[player] or {} do
		local item = Catalog.get(key)
		for _, id in (has and item and item.contents and item.contents.items) or {} do
			Economy.own(player, id, "vip", true)
		end
	end
	StatsService.commit(player)
end

-- A game pass is owned: cache it and hand out what it carries (`bought`: just now, so the
-- client gets its thank-you).
local function applyPass(player: Player, key: string, bought: boolean?)
	local owned = passes[player] or {}
	passes[player] = owned
	local had = owned[key] == true
	owned[key] = true
	passItems(player)
	publish(player)
	if bought and not had then
		local item = Catalog.get(key)
		announce(player, key, table.clone((item and item.contents and item.contents.items) or {}), {}, nil, nil)
	end
end

function Monetization.ownsPass(player: Player, key: string): boolean
	local owned = passes[player]
	return owned ~= nil and owned[key] == true
end

-- True when this player must not get paid random items (and while unknown).
function Monetization.paidRandomRestricted(player: Player): boolean
	return restricted[player] ~= false
end

-- Studio: stub PolicyService's ArePaidRandomItemsRestricted for `player` (tests both branches).
function Monetization.mockPolicy(player: Player, isRestricted: boolean)
	assert(IS_STUDIO, "policy stubs are Studio-only")
	restricted[player] = isRestricted
	publish(player)
end

-- Commits the profile: true once a save including the grant has landed. A Studio test
-- session never writes a real save, so there the in-memory grant is the commit.
local function commit(player: Player): boolean
	if StatsService.saveNow(player) then
		return true
	end
	return IS_STUDIO and StatsService.usingRealStore()
end

local function processReceipt(receipt: { [string]: any }, mockKey: string?): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local key = mockKey or Catalog.productKey("product", receipt.ProductId)
	if not player or not key then
		if not key then
			warn(`[Monetization] receipt for unknown product {receipt.ProductId}`)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local d = StatsService.get(player)
	if not d or not StatsService.canTransact(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = tostring(receipt.PurchaseId)
	if IS_STUDIO then
		StatsService.markTest(player) -- Studio purchases are free tests: never into a real save
	end
	if d.Purchases[purchaseId] == nil then
		-- Ledger and grant in one step (no yields between the check and the write).
		d.Purchases[purchaseId] = { k = key, t = os.time() }
		local handler = grants[key]
		if handler then
			withAnnounce(key, handler)(player, d, key)
		else
			warn(`[Monetization] no grant for {key}`)
		end
		pcall(function()
			AnalyticsService:LogCustomEvent(player, "PurchaseGranted", tonumber(receipt.CurrencySpent) or 0, {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = key,
			})
		end)
		StatsService.commit(player)
	end
	if not commit(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Asks Roblox to sell `key` to `player` (in Studio, with a 0 id: a mock purchase that runs
-- the same receipt path). Returns false with a reason it refused before prompting.
function Monetization.prompt(player: Player, key: string): (boolean, string?)
	local ok, why = eligible(player, key)
	if not ok then
		notice(player, why or "Can't buy that right now.")
		return false, why
	end
	local product = Catalog.Products[key]
	logPrompt(player, key)
	if useMock(product) then
		task.delay(0.3, function()
			if not player.Parent then
				return
			end
			if product.kind == "gamepass" then
				Monetization.mockPass(player, key)
			else
				Monetization.mockReceipt(player, key)
			end
		end)
		return true, nil
	end
	local prompted = pcall(function()
		if product.kind == "gamepass" then
			MarketplaceService:PromptGamePassPurchase(player, product.id)
		else
			MarketplaceService:PromptProductPurchase(player, product.id)
		end
	end)
	return prompted, if prompted then nil else "prompt failed"
end

-- Studio: a fake receipt for `key` through the real ProcessReceipt logic. Passing the same
-- `purchaseId` twice must grant once.
function Monetization.mockReceipt(player: Player, key: string, purchaseId: string?): Enum.ProductPurchaseDecision
	assert(IS_STUDIO, "mock purchases are Studio-only")
	local product = Catalog.Products[key]
	assert(product and product.kind == "product", `[Monetization] {key} is not a developer product`)
	return processReceipt({
		PlayerId = player.UserId,
		ProductId = product.id,
		PurchaseId = purchaseId or `mock-{HttpService:GenerateGUID(false)}`,
		CurrencySpent = product.robux,
		CurrencyType = Enum.CurrencyType.Robux,
		PlaceIdWherePurchased = game.PlaceId,
	}, key)
end

-- Studio: pretend the player bought game pass `key`.
function Monetization.mockPass(player: Player, key: string): boolean
	assert(IS_STUDIO, "mock purchases are Studio-only")
	local product = Catalog.Products[key]
	if not product or product.kind ~= "gamepass" then
		return false
	end
	StatsService.markTest(player)
	applyPass(player, key, true)
	return true
end

local function refreshPasses(player: Player)
	for key, product in Catalog.Products do
		if product.kind == "gamepass" and product.id ~= 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, product.id)
			end)
			if ok and owns and player.Parent then
				applyPass(player, key)
			end
		end
	end
end

local function onPlayerAdded(player: Player)
	passes[player] = passes[player] or {}
	task.spawn(function()
		local ok, info = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		if player.Parent then
			restricted[player] = if ok and typeof(info) == "table"
				then info.ArePaidRandomItemsRestricted == true
				else true
			publish(player)
		end
	end)
	task.spawn(refreshPasses, player)
	publish(player)
end

function Monetization.start()
	MarketplaceService.ProcessReceipt = function(receipt)
		return processReceipt(receipt :: any, nil)
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		local key = Catalog.productKey("gamepass", passId)
		if not key then
			return
		end
		if purchased then
			applyPass(player, key, true)
		else
			task.spawn(refreshPasses, player) -- re-check in case the cache is stale
		end
	end)
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		passes[player] = nil
		restricted[player] = nil
	end)
	-- Profiles load after join: republish when they do (SeasonPremium, items from passes).
	StatsService.onLoaded(function(player)
		task.defer(function()
			passItems(player)
			publish(player)
		end)
	end)
end

return Monetization
