-- ErrorBoundary.lua
-- Guards module entry points so one failing feature does not break testing or
-- force the player to disable the whole addon mid-dungeon.

local addon = _G.BossTracker
local C = addon.Core.Constants

local ErrorBoundary = {}
addon.Core.ErrorBoundary = ErrorBoundary

local moduleErrors = {}

local function stackTrace()
	if type(debugstack) == "function" then
		return debugstack(3, 12, 12)
	end
	return nil
end

local function disableModule(moduleName, reason)
	addon.disabledModules[moduleName] = true
	addon.UnregisterModuleEvents(moduleName)
	if addon.Core.Logger then
		addon.Core.Logger.error(moduleName, "Module disabled after repeated errors", { reason = reason })
	end
	if moduleName == "TimerFrame" and addon.UI.TimerFrame then
		addon.UI.TimerFrame.hide()
	end
end

function ErrorBoundary.record(moduleName, context, err)
	moduleName = moduleName or "Unknown"
	local count = (moduleErrors[moduleName] or 0) + 1
	moduleErrors[moduleName] = count

	if addon.Core.Logger then
		addon.Core.Logger.error(moduleName, "Protected call failed", {
			context = context,
			error = tostring(err),
			stack = stackTrace(),
			count = count,
		})
	end

	if count >= C.MODULE_ERROR_LIMIT then
		disableModule(moduleName, "error_limit")
	end
end

function ErrorBoundary.call(moduleName, context, fn, ...)
	if addon.disabledModules[moduleName] then
		return nil
	end

	local ok, result1, result2, result3 = pcall(fn, ...)

	if ok then
		return result1, result2, result3
	end
	ErrorBoundary.record(moduleName, context, result1)
	return nil
end

function ErrorBoundary.safeStart(moduleName, module)
	if not module or type(module.start) ~= "function" then
		if addon.Core.Logger then
			addon.Core.Logger.error(moduleName, "Missing start function")
		end
		return false
	end

	local ok = xpcall(function()
		module.start()
	end, function(err)
		ErrorBoundary.record(moduleName, "start", err)
		return err
	end)

	if ok and addon.Core.Logger then
		addon.Core.Logger.debug(moduleName, "Module started")
	end
	return ok
end

function ErrorBoundary.reset(moduleName)
	if moduleName then
		moduleErrors[moduleName] = nil
		addon.disabledModules[moduleName] = nil
	else
		moduleErrors = {}
		addon.disabledModules = {}
	end
end
