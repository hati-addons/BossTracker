-- TimerScheduler.lua
-- Compatibility facade for the UI. PredictionEngine owns the actual rule-based
-- timer construction; this module preserves the small public API used by the
-- existing timer frame.

local addon = _G.BossTracker

local TimerScheduler = {}
addon.Runtime.TimerScheduler = TimerScheduler

function TimerScheduler.getPredictions(force)
	if addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.getPredictions then
		return addon.Runtime.PredictionEngine.getPredictions(force)
	end
	return {}
end

function TimerScheduler.start()
	if addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.start then
		addon.Runtime.PredictionEngine.start()
	end
end
