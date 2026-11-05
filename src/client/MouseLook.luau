--!strict
-- Ctrl toggles mouse look, Sekiro's PC camera: the cursor is hidden and held in the middle of
-- the screen, so moving the mouse always turns the camera (no right-click needed). Tapping Ctrl
-- again frees the cursor to use the menus. Unlike Roblox's shift lock, your body doesn't turn
-- to face the camera: you still turn toward where you run, and lock-on still drives the view.
--
-- While a menu panel or sheet, Roblox's own menu or a text box is open, the cursor is let go
-- by itself and comes back when it closes, so a menu is never unclickable.
--
-- Roblox's camera writes MouseBehavior every frame, so this writes it right after the camera
-- each frame while it's on.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Panels = require(script.Parent.Panels)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local MouseLook = {}

local enabled = false
local holding = false -- whether we're the ones holding the cursor right now

local function suspended(): boolean
	return Panels.isOpen()
		or UI.sheetOpen()
		or GuiService.MenuIsOpen
		or UserInputService:GetFocusedTextBox() ~= nil
end

local function release()
	if holding then
		holding = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

function MouseLook.enabled(): boolean
	return enabled
end

function MouseLook.set(on: boolean)
	enabled = on
	player:SetAttribute("MouseLook", on)
	if not on then
		release()
	end
end

function MouseLook.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return -- typing in chat or a text box
		end
		if input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
			MouseLook.set(not enabled)
		end
	end)
	RunService:BindToRenderStep("SekiroMouseLook", Enum.RenderPriority.Camera.Value + 2, function()
		if not enabled then
			return
		end
		if suspended() then
			release()
		else
			holding = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
		end
	end)
end

return MouseLook
