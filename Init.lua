-- Init.lua
-- Boots BossTracker after SavedVariables are available and starts modules in a
-- deliberate order: persistence, diagnostics, capture, learning runtime, UI.

local addon = _G.BossTracker
local started = false

local function startModules()
	local boundary = addon.Core.ErrorBoundary
	boundary.safeStart("EncounterState", addon.Capture.EncounterState)
	boundary.safeStart("AbilityLearner", addon.Learning.AbilityLearner)
	boundary.safeStart("TimerScheduler", addon.Runtime.TimerScheduler)
	boundary.safeStart("CombatLog", addon.Capture.CombatLog)
	boundary.safeStart("TimerFrame", addon.UI.TimerFrame)
	boundary.safeStart("SlashCommand", addon.UI.SlashCommand)
end

local function boot()
	if started then
		return
	end
	started = true

	addon.Core.SavedVariables.init()
	addon.Core.Logger.startRun()
	addon.Core.Logger.info("Init", "BossTracker boot", {
		version = addon.Core.Constants.VERSION,
	})

	startModules()
	addon.Core.Logger.chat("v" .. addon.Core.Constants.VERSION .. " loaded. /bt status")
end

local function shutdown()
	if addon.Capture and addon.Capture.EncounterState then
		addon.Capture.EncounterState.finish("logout")
	end
	if addon.Core.Logger then
		addon.Core.Logger.finishRun("logout")
	end
end

local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:RegisterEvent("PLAYER_LOGOUT")
bootFrame:SetScript("OnEvent", function(self, eventName, arg1)
	if eventName == "ADDON_LOADED" and arg1 == addon.name then
		local ok, err = xpcall(boot, function(errorMessage)
			if addon.Core.Logger then
				addon.Core.Logger.error("Init", "Boot failed", {
					error = tostring(errorMessage),
					stack = type(debugstack) == "function" and debugstack(2, 12, 12) or nil,
				})
			end
			return errorMessage
		end)
		if not ok and DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage("|cffff5555BossTracker failed to load. The error was saved if diagnostics were initialized.|r")
		end
	elseif eventName == "PLAYER_LOGOUT" then
		shutdown()
	end
end)
