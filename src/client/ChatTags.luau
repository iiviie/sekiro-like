--!strict
-- Chat tags: Ronin VIP owners (the `VIP` attribute from server/Monetization) get a wisteria
-- [Ronin] before their name in chat, in their nameplate frame's colour (Shared/Flair).
-- Cosmetic only; the only TextChatService.OnIncomingMessage callback in the game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Flair = require(ReplicatedStorage.Shared.Flair)

local ChatTags = {}

function ChatTags.start()
	local tag = `<font color="#{Flair.plate("Ronin").edge:ToHex()}">[Ronin]</font> `
	TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties?
		local source = message.TextSource
		local speaker = source and Players:GetPlayerByUserId(source.UserId)
		if speaker and speaker:GetAttribute("VIP") == true then
			local properties = Instance.new("TextChatMessageProperties")
			properties.PrefixText = tag .. message.PrefixText
			return properties
		end
		return nil
	end
end

return ChatTags
