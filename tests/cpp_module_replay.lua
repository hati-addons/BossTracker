-- cpp_module_replay.lua
-- Converts common AzerothCore boss C++ script patterns into headless
-- BossTracker replay events. The adapter is intentionally approximate: it
-- tests whether the addon can learn from the client-visible shape of a boss
-- script, not whether the server module is executed byte-for-byte.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon

local DEFAULT_CPP_FILES = {
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/BlackrockMountain/BlackrockSpire/boss_warmaster_voone.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/Deadmines/boss_mr_smite.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/BlackrockMountain/BlackrockSpire/boss_overlord_wyrmthalak.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/Northrend/Naxxramas/boss_anubrekhan.cpp",
	"/home/two/projects/azerothcore-wotlk/src/server/scripts/Outland/boss_doomwalker.cpp",
}

local function readFile(path)
	local file, err = io.open(path, "r")
	if not file then
		error("cannot read C++ boss script " .. tostring(path) .. ": " .. tostring(err), 2)
	end
	local data = file:read("*a")
	file:close()
	return data
end

local function basename(path)
	return tostring(path):match("([^/\\]+)$") or tostring(path)
end

local function stripExtension(name)
	return (name:gsub("%.[^.]+$", ""))
end

local function titleCaseWords(value)
	value = tostring(value or "")
	value = value:gsub("^SPELL_", ""):gsub("^EVENT_", ""):gsub("^NPC_", ""):gsub("^DATA_", ""):gsub("^SAY_", "")
	value = value:gsub("_+", " ")
	value = value:gsub("%s+", " ")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	value = string.lower(value)
	value = value:gsub("(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. rest
	end)
	return value ~= "" and value or "Unknown"
end

local function bossNameFromPath(path)
	local name = stripExtension(basename(path))
	name = name:gsub("^boss_", "")
	return titleCaseWords(name)
end

local function stripComments(text)
	text = text:gsub("/%*.-%*/", function(block)
		local _, newlines = block:gsub("\n", "\n")
		return string.rep("\n", newlines)
	end)
	text = text:gsub("//[^\n]*", "")
	return text
end

local function parseDurationToken(token)
	token = tostring(token or "")
	local number, suffix = token:match("(%d+%.?%d*)%s*(ms)")
	if number then
		return tonumber(number) / 1000
	end
	number, suffix = token:match("(%d+%.?%d*)%s*(min)")
	if number then
		return tonumber(number) * 60
	end
	number, suffix = token:match("(%d+%.?%d*)%s*(s)")
	if number then
		return tonumber(number)
	end
	number = token:match("^%s*(%d+%.?%d*)%s*$")
	if number then
		local value = tonumber(number)
		if value and value >= 1000 then
			return value / 1000
		end
		return value
	end
	return nil
end

local function parseDurations(text)
	local durations = {}
	for token in tostring(text or ""):gmatch("%d+%.?%d*%s*ms") do
		durations[#durations + 1] = parseDurationToken(token)
	end
	for token in tostring(text or ""):gmatch("%d+%.?%d*%s*min") do
		durations[#durations + 1] = parseDurationToken(token)
	end
	for token in tostring(text or ""):gmatch("%d+%.?%d*%s*s") do
		if not token:match("ms$") then
			durations[#durations + 1] = parseDurationToken(token)
		end
	end
	for token in tostring(text or ""):gmatch("[,(]%s*(%d+%.?%d*)%s*[,)]") do
		durations[#durations + 1] = parseDurationToken(token)
	end
	return durations
end

local function minDuration(text)
	local durations = parseDurations(text)
	local selected = nil
	for index = 1, #durations do
		local value = durations[index]
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	return selected
end

local function splitArguments(argumentText)
	local args = {}
	local depth = 0
	local start = 1
	for index = 1, #argumentText do
		local ch = argumentText:sub(index, index)
		if ch == "(" then
			depth = depth + 1
		elseif ch == ")" then
			depth = depth - 1
		elseif ch == "," and depth == 0 then
			args[#args + 1] = argumentText:sub(start, index - 1)
			start = index + 1
		end
	end
	args[#args + 1] = argumentText:sub(start)
	return args
end

local function stripOuterWhitespace(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function findMatchingBrace(text, openPos)
	local depth = 0
	for index = openPos, #text do
		local ch = text:sub(index, index)
		if ch == "{" then
			depth = depth + 1
		elseif ch == "}" then
			depth = depth - 1
			if depth == 0 then
				return index
			end
		end
	end
	return nil
end

local function findMatchingParen(text, openPos)
	local depth = 0
	for index = openPos, #text do
		local ch = text:sub(index, index)
		if ch == "(" then
			depth = depth + 1
		elseif ch == ")" then
			depth = depth - 1
			if depth == 0 then
				return index
			end
		end
	end
	return nil
end

local function inRanges(position, ranges)
	for index = 1, #ranges do
		local range = ranges[index]
		if position >= range.startPos and position <= range.endPos then
			return range
		end
	end
	return nil
end

local function addUnique(list, seen, value)
	if value and not seen[value] then
		seen[value] = true
		list[#list + 1] = value
	end
end

local function parseSymbols(text)
	local symbols = {}
	for enumBody in text:gmatch("enum%s+[%w_:]*%s*{(.-)}%s*;") do
		for entry in enumBody:gmatch("([^,]+)") do
			entry = entry:gsub("\n", " ")
			local identifier = entry:match("([A-Z][A-Z0-9_]+)")
			if identifier then
				local value = entry:match("=%s*([0-9]+)")
				local kind = identifier:match("^(%u+)_") or "CONST"
				symbols[identifier] = {
					identifier = identifier,
					kind = kind,
					value = tonumber(value),
					label = titleCaseWords(identifier),
				}
			end
		end
	end
	return symbols
end

local function labelFor(symbols, identifier)
	if not identifier then
		return nil
	end
	return symbols[identifier] and symbols[identifier].label or titleCaseWords(identifier)
end

local function spellIdFor(symbols, identifier)
	return symbols[identifier] and symbols[identifier].value or nil
end

local function hasSpace(value)
	return type(value) == "string" and value:find("%s") ~= nil
end

local function displaySpellName(symbols, spellIdentifier, eventIdentifier)
	local spellLabel = labelFor(symbols, spellIdentifier)
	local eventLabel = labelFor(symbols, eventIdentifier)
	if eventLabel and hasSpace(eventLabel) and not hasSpace(spellLabel) and not eventLabel:match("^Check Health") then
		return eventLabel
	end
	return spellLabel
end

local function findSpellCasts(block)
	local list = {}
	local seen = {}
	for spell in tostring(block or ""):gmatch("DoCast%w*%s*%(%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	for spell in tostring(block or ""):gmatch("DoCast%s*%([^;]-[, ]%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	for spell in tostring(block or ""):gmatch("CastSpell%s*%([^;]-[, ]%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	for spell in tostring(block or ""):gmatch("CastCustomSpell%s*%([^;]-[, ]%s*(SPELL_[A-Z0-9_]+)") do
		addUnique(list, seen, spell)
	end
	return list
end

local function findSummons(block)
	local list = {}
	local seen = {}
	for npc in tostring(block or ""):gmatch("SummonCreature%s*%(%s*(NPC_[A-Z0-9_]+)") do
		addUnique(list, seen, npc)
	end
	for npc in tostring(block or ""):gmatch("DoSummon%s*%(%s*(NPC_[A-Z0-9_]+)") do
		addUnique(list, seen, npc)
	end
	return list
end

local function findHpThreshold(block)
	local threshold = tostring(block or ""):match("HealthBelowPctDamaged%s*%(%s*(%d+)")
		or tostring(block or ""):match("HealthBelowPct%s*%(%s*(%d+)")
	if threshold then
		return tonumber(threshold), "below"
	end
	threshold = tostring(block or ""):match("!%s*HealthAbovePct%s*%(%s*(%d+)")
	if threshold then
		return tonumber(threshold), "below"
	end
	return nil, nil
end

local function parseHpBlocks(text)
	local blocks = {}
	local searchFrom = 1
	while true do
		local startPos, endPos, threshold = text:find("HealthBelowPctDamaged%s*%(%s*(%d+)", searchFrom)
		local mode = "below"
		local altStart, altEnd, altThreshold = text:find("HealthBelowPct%s*%(%s*(%d+)", searchFrom)
		if altStart and (not startPos or altStart < startPos) then
			startPos, endPos, threshold = altStart, altEnd, altThreshold
		end
		altStart, altEnd, altThreshold = text:find("!%s*HealthAbovePct%s*%(%s*(%d+)", searchFrom)
		if altStart and (not startPos or altStart < startPos) then
			startPos, endPos, threshold, mode = altStart, altEnd, altThreshold, "below"
		end
		if not startPos then
			break
		end
		local openPos = text:find("{", endPos, true)
		local closePos = openPos and findMatchingBrace(text, openPos) or nil
		if openPos and closePos then
			blocks[#blocks + 1] = {
				startPos = startPos,
				endPos = closePos,
				body = text:sub(openPos + 1, closePos - 1),
				threshold = tonumber(threshold),
				mode = mode,
			}
			searchFrom = closePos + 1
		else
			searchFrom = endPos + 1
		end
	end
	return blocks
end

local function parseCaseBlocks(text)
	local blocks = {}
	local searchFrom = 1
	while true do
		local startPos, labelEnd, eventIdentifier = text:find("case%s+([A-Z][A-Z0-9_]+)%s*:", searchFrom)
		if not startPos then
			break
		end
		local breakStart = text:find("break%s*;", labelEnd + 1)
		local nextCase = text:find("\n%s*case%s+[A-Z][A-Z0-9_]+%s*:", labelEnd + 1)
		local endPos
		if breakStart and (not nextCase or breakStart < nextCase) then
			endPos = breakStart
		else
			endPos = (nextCase and nextCase - 1) or #text
		end
		blocks[#blocks + 1] = {
			startPos = startPos,
			endPos = endPos,
			eventIdentifier = eventIdentifier,
			body = text:sub(labelEnd + 1, endPos),
		}
		searchFrom = endPos + 1
	end
	return blocks
end

local function ensureEventAction(model, eventIdentifier)
	local action = model.events[eventIdentifier]
	if not action then
		action = {
			kind = "event",
			eventIdentifier = eventIdentifier,
			source = "event_case",
			occurrences = 0,
		}
		model.events[eventIdentifier] = action
	end
	return action
end

local function parseRepeatSeconds(block, eventIdentifier)
	local selected = nil
	for args in tostring(block or ""):gmatch("%.Repeat%s*%((.-)%)") do
		local value = minDuration(args)
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	for args in tostring(block or ""):gmatch("ScheduleEvent%s*%(%s*" .. eventIdentifier .. "%s*,(.-)%)") do
		local value = minDuration(args)
		if value and (not selected or value < selected) then
			selected = value
		end
	end
	return selected
end

local function parseScheduleEventCalls(text, model, caseRanges, hpBlocks)
	local searchFrom = 1
	while true do
		local startPos, openEnd = text:find("ScheduleEvent%s*%(", searchFrom)
		local rescheduleStart, rescheduleOpenEnd = text:find("RescheduleEvent%s*%(", searchFrom)
		if rescheduleStart and (not startPos or rescheduleStart < startPos) then
			startPos, openEnd = rescheduleStart, rescheduleOpenEnd
		end
		if not startPos then
			break
		end
		local openPos = openEnd
		local closePos = findMatchingParen(text, openPos)
		if not closePos then
			break
		end
		local argsText = text:sub(openPos + 1, closePos - 1)
		local args = splitArguments(argsText)
		local eventIdentifier = stripOuterWhitespace(args[1]):match("([A-Z][A-Z0-9_]+)")
		local delay = minDuration(table.concat(args, ",", 2))
		if eventIdentifier and delay then
			if not inRanges(startPos, caseRanges) then
				local hpBlock = inRanges(startPos, hpBlocks)
				if hpBlock then
					model.hpSchedules[#model.hpSchedules + 1] = {
						eventIdentifier = eventIdentifier,
						delay = delay,
						hpThreshold = hpBlock.threshold,
						source = "hp_schedule",
					}
				else
					model.initialSchedules[#model.initialSchedules + 1] = {
						eventIdentifier = eventIdentifier,
						delay = delay,
						source = "initial_schedule",
					}
				end
			end
		end
		searchFrom = closePos + 1
	end
end

local function parseCaseActions(text, model, caseBlocks)
	for index = 1, #caseBlocks do
		local caseBlock = caseBlocks[index]
		local action = ensureEventAction(model, caseBlock.eventIdentifier)
		local spells = findSpellCasts(caseBlock.body)
		if spells[1] then
			action.spellIdentifier = spells[1]
			action.spellId = spellIdFor(model.symbols, spells[1])
			action.spellName = displaySpellName(model.symbols, spells[1], caseBlock.eventIdentifier)
		end
		action.repeatSeconds = parseRepeatSeconds(caseBlock.body, caseBlock.eventIdentifier) or action.repeatSeconds
		action.hpThreshold = findHpThreshold(caseBlock.body) or action.hpThreshold
		action.summons = findSummons(caseBlock.body)
		action.body = caseBlock.body
	end
end

local function parseDirectHpActions(text, model, hpBlocks, caseRanges)
	for index = 1, #hpBlocks do
		local block = hpBlocks[index]
		if not inRanges(block.startPos, caseRanges) then
			local spells = findSpellCasts(block.body)
			for spellIndex = 1, #spells do
				model.directSchedules[#model.directSchedules + 1] = {
					kind = "direct_hp_cast",
					spellIdentifier = spells[spellIndex],
					spellId = spellIdFor(model.symbols, spells[spellIndex]),
					spellName = displaySpellName(model.symbols, spells[spellIndex], nil),
					hpThreshold = block.threshold,
					initialDelay = 0,
					source = "hp_direct_cast",
				}
			end
			local summons = findSummons(block.body)
			for summonIndex = 1, #summons do
				model.directSchedules[#model.directSchedules + 1] = {
					kind = "direct_hp_summon",
					spellName = "Summon " .. labelFor(model.symbols, summons[summonIndex]),
					hpThreshold = block.threshold,
					initialDelay = 0,
					eventType = "SPELL_SUMMON",
					source = "hp_direct_summon",
				}
			end
		end
	end
end

local function parseLambdaSchedules(text, model)
	local searchFrom = 1
	local lambdaIndex = 0
	while true do
		local startPos, openEnd = text:find("ScheduleTimedEvent%s*%(", searchFrom)
		local scheduleStart, scheduleOpenEnd = text:find("[%.%w_]Schedule%s*%(", searchFrom)
		if scheduleStart and (not startPos or scheduleStart < startPos) then
			startPos, openEnd = scheduleStart, scheduleOpenEnd
		end
		if not startPos then
			break
		end

		local lambdaStart = text:find("%[[^%]]*%]%s*%([^)]*%)%s*{", openEnd)
			or text:find("%[[^%]]*%]%s*{", openEnd)
		if not lambdaStart then
			searchFrom = openEnd + 1
		else
			local bodyOpen = text:find("{", lambdaStart, true)
			local bodyClose = bodyOpen and findMatchingBrace(text, bodyOpen) or nil
			if not bodyClose then
				searchFrom = openEnd + 1
			else
				lambdaIndex = lambdaIndex + 1
				local preArgs = text:sub(openEnd + 1, lambdaStart - 1)
				local body = text:sub(bodyOpen + 1, bodyClose - 1)
				local tail = text:sub(bodyClose + 1, math.min(#text, bodyClose + 120))
				local spells = findSpellCasts(body)
				local summons = findSummons(body)
				local repeatSeconds = minDuration(body:match("%.Repeat%s*%((.-)%)") or "") or minDuration(tail)
				local hpThreshold = findHpThreshold(body)
				local initialDelay = minDuration(preArgs) or 1
				if spells[1] or summons[1] then
					model.directSchedules[#model.directSchedules + 1] = {
						kind = "lambda_schedule",
						spellIdentifier = spells[1],
						spellId = spellIdFor(model.symbols, spells[1]),
						spellName = spells[1] and displaySpellName(model.symbols, spells[1], nil)
							or ("Summon " .. labelFor(model.symbols, summons[1])),
						initialDelay = initialDelay,
						repeatSeconds = repeatSeconds,
						hpThreshold = hpThreshold,
						eventType = spells[1] and "SPELL_CAST_SUCCESS" or "SPELL_SUMMON",
						source = "lambda_schedule_" .. tostring(lambdaIndex),
					}
				end
				searchFrom = bodyClose + 1
			end
		end
	end
end

local function parseCppModel(path)
	local text = stripComments(readFile(path))
	local model = {
		path = path,
		fileName = basename(path),
		bossName = bossNameFromPath(path),
		symbols = parseSymbols(text),
		events = {},
		initialSchedules = {},
		hpSchedules = {},
		directSchedules = {},
		fallback = false,
	}
	local hpBlocks = parseHpBlocks(text)
	local caseBlocks = parseCaseBlocks(text)
	parseCaseActions(text, model, caseBlocks)
	parseScheduleEventCalls(text, model, caseBlocks, hpBlocks)
	parseDirectHpActions(text, model, hpBlocks, caseBlocks)
	parseLambdaSchedules(text, model)
	return model
end

local function hpAtTime(timeValue, duration)
	local hp = 100 - ((timeValue / duration) * 99)
	if hp < 1 then
		return 1
	end
	if hp > 100 then
		return 100
	end
	return math.floor(hp * 10 + 0.5) / 10
end

local function timeForHp(threshold, duration)
	if not threshold then
		return nil
	end
	return ((100 - threshold) / 99) * duration
end

local function queuePush(queue, item)
	queue[#queue + 1] = item
end

local function queuePop(queue)
	table.sort(queue, function(left, right)
		return left.t < right.t
	end)
	local item = queue[1]
	table.remove(queue, 1)
	return item
end

local function actionHasVisibleEvent(action)
	return action and (action.spellName or (action.summons and action.summons[1]))
end

local function addActionSchedule(queue, action, timeValue, source)
	if actionHasVisibleEvent(action) then
		queuePush(queue, {
			t = timeValue,
			action = action,
			source = source or action.source,
		})
	end
end

local function buildInitialQueue(model, duration)
	local queue = {}
	for index = 1, #model.initialSchedules do
		local schedule = model.initialSchedules[index]
		local action = model.events[schedule.eventIdentifier]
		if actionHasVisibleEvent(action) then
			local scheduledAt = schedule.delay
			local hpTime = timeForHp(action.hpThreshold, duration)
			if hpTime and hpTime > scheduledAt then
				scheduledAt = hpTime
			end
			addActionSchedule(queue, action, scheduledAt, schedule.source)
		end
	end
	for index = 1, #model.hpSchedules do
		local schedule = model.hpSchedules[index]
		local action = model.events[schedule.eventIdentifier]
		if actionHasVisibleEvent(action) then
			local scheduledAt = (timeForHp(schedule.hpThreshold, duration) or 0) + (schedule.delay or 0)
			addActionSchedule(queue, action, scheduledAt, schedule.source)
		end
	end
	for index = 1, #model.directSchedules do
		local action = model.directSchedules[index]
		local scheduledAt = action.initialDelay or 0
		local hpTime = timeForHp(action.hpThreshold, duration)
		if hpTime and hpTime > scheduledAt then
			scheduledAt = hpTime
		end
		addActionSchedule(queue, action, scheduledAt, action.source)
	end
	return queue
end

local function addFallbackQueue(model, queue)
	model.fallback = true
	local emitted = 0
	for identifier, symbol in pairs(model.symbols) do
		if symbol.kind == "SPELL" then
			emitted = emitted + 1
			queuePush(queue, {
				t = emitted * 8,
				action = {
					kind = "fallback_spell",
					spellIdentifier = identifier,
					spellId = symbol.value,
					spellName = labelFor(model.symbols, identifier),
					repeatSeconds = emitted <= 2 and 18 or nil,
					source = "fallback_spell",
					occurrences = 0,
				},
				source = "fallback",
			})
			if emitted >= 5 then
				break
			end
		end
	end
end

local function emitAction(model, action, timeValue, bossName, bossGuid, ownerPull, ownerContext, duration, summary)
	local hp = hpAtTime(timeValue, duration)
	if action.hpThreshold and hp > action.hpThreshold + 1 then
		return nil, "before_hp_gate"
	end

	if not action.spellName and action.summons and action.summons[1] then
		action.spellName = "Summon " .. labelFor(model.symbols, action.summons[1])
		action.eventType = "SPELL_SUMMON"
	end

	if not action.spellName then
		return nil, "no_visible_spell"
	end

	local pull, context = Harness.emitSpell({
		t = timeValue,
		sourceName = bossName,
		sourceGUID = bossGuid,
		spellId = action.spellId,
		spellName = action.spellName,
		eventType = action.eventType or "SPELL_CAST_SUCCESS",
		hp = hp,
		selfTarget = action.selfTarget,
	})
	summary.emittedSpellCount = summary.emittedSpellCount + 1
	summary.emitted[action.spellName] = (summary.emitted[action.spellName] or 0) + 1
	return pull or ownerPull, context or ownerContext, nil
end

local function simulateModel(model)
	local duration = 180
	local bossName = model.bossName
	local bossGuid = Harness.makeGuid(bossName, 7000)
	local queue = buildInitialQueue(model, duration)
	local summary = {
		path = model.path,
		fileName = model.fileName,
		bossName = bossName,
		fallback = false,
		emittedSpellCount = 0,
		emitted = {},
		parsedEventCount = 0,
		parsedInitialScheduleCount = #model.initialSchedules,
		parsedHpScheduleCount = #model.hpSchedules,
		parsedDirectScheduleCount = #model.directSchedules,
	}

	for _ in pairs(model.events) do
		summary.parsedEventCount = summary.parsedEventCount + 1
	end

	local function runQueue(activeQueue)
		local ownerPull = nil
		local ownerContext = nil
		local totalEvents = 0
		while #activeQueue > 0 and totalEvents < 240 do
			local item = queuePop(activeQueue)
			if item.t > duration then
				break
			end
			local action = item.action
			local pull, context, skipReason = emitAction(model, action, item.t, bossName, bossGuid, ownerPull, ownerContext, duration, summary)
			if pull then
				ownerPull = pull
				ownerContext = context
			end
			if skipReason == "before_hp_gate" and action.hpThreshold then
				addActionSchedule(activeQueue, action, timeForHp(action.hpThreshold, duration), "hp_gate_retry")
			elseif not skipReason then
				totalEvents = totalEvents + 1
				action.occurrences = (action.occurrences or 0) + 1
				if action.repeatSeconds and action.repeatSeconds >= 0.5 and action.occurrences < 12 then
					addActionSchedule(activeQueue, action, item.t + action.repeatSeconds, "repeat")
				end
			end
		end
	end

	if #queue == 0 then
		addFallbackQueue(model, queue)
		summary.fallback = true
	end

	Harness.resetState("CPP Replay: " .. bossName)
	runQueue(queue)

	if summary.emittedSpellCount == 0 and not summary.fallback then
		queue = {}
		addFallbackQueue(model, queue)
		summary.fallback = true
		Harness.resetState("CPP Replay: " .. bossName)
		runQueue(queue)
	end

	Harness.finishPull(duration + 5, "unit_died")
	summary.learnedEncounterCount = Harness.encounterCount()
	summary.learnedAbilityCount = Harness.abilityCount()
	return summary
end

local function assertReplaySummary(summary)
	Harness.assertTrue(summary.emittedSpellCount > 0, summary.fileName .. " should emit at least one simulated boss spell")
	Harness.assertTrue(summary.learnedEncounterCount > 0, summary.fileName .. " should promote a learned encounter")
	Harness.assertTrue(summary.learnedAbilityCount > 0, summary.fileName .. " should promote at least one learned ability")
end

local function assertKnownFixture(summary)
	if summary.fileName == "boss_warmaster_voone.cpp" then
		local cleave = Harness.findFirstAbilityByName("Cleave")
		Harness.assertTrue(cleave ~= nil, "Warmaster Voone should learn Cleave")
		local hasHpSegment = false
		for segmentKey in pairs(cleave.segmentStats or {}) do
			if tostring(segmentKey):match("^hp_") then
				hasHpSegment = true
			end
		end
		Harness.assertTrue(hasHpSegment, "Warmaster Voone Cleave should be tied to an HP phase")
	elseif summary.fileName == "boss_mr_smite.cpp" then
		local stomp = Harness.findFirstAbilityByName("Smite Stomp")
		Harness.assertTrue(stomp ~= nil, "Mr. Smite should learn Smite Stomp")
		local hasHpSegment = false
		for segmentKey in pairs(stomp.segmentStats or {}) do
			if tostring(segmentKey):match("^hp_") then
				hasHpSegment = true
			end
		end
		Harness.assertTrue(hasHpSegment, "Mr. Smite transition stomp should carry HP-segment evidence")
	elseif summary.fileName == "boss_overlord_wyrmthalak.cpp" then
		local blastWave = Harness.findFirstAbilityByName("Blast Wave")
		Harness.assertTrue(blastWave ~= nil, "Overlord Wyrmthalak should learn Blast Wave")
		Harness.assertTrue(blastWave.minInterval and blastWave.minInterval >= 19 and blastWave.minInterval <= 21, "Overlord Wyrmthalak Blast Wave should preserve its repeat interval evidence")
	end
end

local function replayPath(path)
	local model = parseCppModel(path)
	local summary = simulateModel(model)
	assertReplaySummary(summary)
	assertKnownFixture(summary)
	print(
		"cpp replay passed: "
		.. summary.fileName
		.. " events=" .. tostring(summary.parsedEventCount)
		.. " schedules=" .. tostring(summary.parsedInitialScheduleCount + summary.parsedHpScheduleCount + summary.parsedDirectScheduleCount)
		.. " emitted=" .. tostring(summary.emittedSpellCount)
		.. " learned=" .. tostring(summary.learnedAbilityCount)
		.. " fallback=" .. tostring(summary.fallback)
	)
end

local paths = {}
if arg and #arg > 0 then
	for index = 1, #arg do
		paths[#paths + 1] = arg[index]
	end
else
	for index = 1, #DEFAULT_CPP_FILES do
		paths[#paths + 1] = DEFAULT_CPP_FILES[index]
	end
end

for index = 1, #paths do
	replayPath(paths[index])
end
