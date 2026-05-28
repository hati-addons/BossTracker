-- Logger.lua
-- Persists bounded diagnostics into SavedVariables. Chat output is minimal;
-- the durable record is the debug store that can be inspected after testing.

local addon = _G.BossTracker
local C = addon.Core.Constants
local RingBuffer = addon.Core.RingBuffer

local Logger = {}
addon.Core.Logger = Logger

local activeRun

local function now()
	if type(GetTime) == "function" then
		return GetTime()
	end
	return time()
end

local function wallTime()
	if type(time) == "function" then
		return time()
	end
	return now()
end

local function shouldDebug()
	return addon.db and addon.db.config and addon.db.config.debugEnabled
end

local function trimRuns()
	local runs = addon.db.debug.runs
	while #runs > C.MAX_DEBUG_RUNS do
		table.remove(runs, 1)
	end
end

function Logger.startRun()
	if not addon.db then
		return nil
	end

	local debugStore = addon.db.debug
	local runId = debugStore.nextRunId or 1
	debugStore.nextRunId = runId + 1

	activeRun = {
		id = runId,
		version = C.VERSION,
		startedAt = wallTime(),
		startedAtSession = now(),
		client = GetBuildInfo and GetBuildInfo() or nil,
		realm = GetRealmName and GetRealmName() or nil,
		player = UnitName and UnitName("player") or nil,
		events = RingBuffer.ensure(nil, C.MAX_DEBUG_EVENTS_PER_RUN),
		bossContexts = RingBuffer.ensure(nil, C.MAX_DEBUG_CONTEXTS_PER_RUN),
		logs = RingBuffer.ensure(nil, C.MAX_DEBUG_LOGS),
		pulls = {},
		counters = {},
	}

	debugStore.runs[#debugStore.runs + 1] = activeRun
	trimRuns()
	return activeRun
end

function Logger.finishRun(reason)
	if activeRun then
		activeRun.endedAt = wallTime()
		activeRun.endedAtSession = now()
		activeRun.endReason = reason or "unknown"
	end
	activeRun = nil
end

function Logger.getRun()
	return activeRun
end

function Logger.log(level, moduleName, message, data)
	if not addon.db then
		return
	end

	local record = {
		t = now(),
		wall = wallTime(),
		level = level,
		module = moduleName or "Core",
		message = tostring(message or ""),
		data = data,
	}

	addon.db.debug.logs = RingBuffer.push(addon.db.debug.logs, record, C.MAX_DEBUG_LOGS)
	if activeRun then
		activeRun.logs = RingBuffer.push(activeRun.logs, record, C.MAX_DEBUG_LOGS)
	end
end

function Logger.debug(moduleName, message, data)
	if shouldDebug() then
		Logger.log("debug", moduleName, message, data)
	end
end

function Logger.info(moduleName, message, data)
	Logger.log("info", moduleName, message, data)
end

function Logger.warn(moduleName, message, data)
	Logger.log("warn", moduleName, message, data)
end

function Logger.error(moduleName, message, data)
	Logger.log("error", moduleName, message, data)
	if addon.db then
		addon.db.debug.errors = RingBuffer.push(addon.db.debug.errors, {
			t = now(),
			wall = wallTime(),
			module = moduleName or "Core",
			message = tostring(message or ""),
			data = data,
		}, C.MAX_DEBUG_ERRORS)
	end
end

function Logger.event(record)
	if not shouldDebug() or not activeRun or type(record) ~= "table" then
		return
	end

	record.t = record.t or now()
	activeRun.events = RingBuffer.push(activeRun.events, record, C.MAX_DEBUG_EVENTS_PER_RUN)
end

function Logger.bossContext(record)
	if not shouldDebug() or not activeRun or type(record) ~= "table" then
		return
	end

	record.t = record.t or now()
	activeRun.bossContexts = RingBuffer.push(activeRun.bossContexts, record, C.MAX_DEBUG_CONTEXTS_PER_RUN)
end

function Logger.counter(name, amount)
	if not activeRun or type(name) ~= "string" then
		return
	end
	local counters = activeRun.counters
	counters[name] = (counters[name] or 0) + (amount or 1)
end

function Logger.chat(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff4ec3ffBossTracker:|r " .. tostring(message))
	end
end
