-- TimerScheduler.lua
-- Converts learned ability models and current-pull observations into the small
-- ordered timer list consumed by the UI.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local TimerScheduler = {}
addon.Runtime.TimerScheduler = TimerScheduler

local predictions = {}
local lastUpdateAt = 0

local function clearPredictions()
	for index = #predictions, 1, -1 do
		predictions[index] = nil
	end
end

local function abilityDisplayName(ability)
	return ability.spellName or ability.key or "Unknown Ability"
end

local function timerIdentity(context, ability)
	return tostring(context and context.actorKey or context and context.modelKey or "unknown")
		.. "|"
		.. tostring(ability and ability.key or "unknown")
end

local function addTimer(ability, pullAbility, context, nextAt, mode, scheduledKeys)
	local now = Util.now()
	local remaining = nextAt and (nextAt - now) or nil
	if remaining and remaining < -8 then
		return
	end
	if scheduledKeys then
		local identity = timerIdentity(context, ability)
		if scheduledKeys[identity] then
			return
		end
		scheduledKeys[identity] = true
	end

	local duration = ability.minInterval or ability.minFirstOffset or 10
	if duration < 1 then
		duration = 1
	end

	predictions[#predictions + 1] = {
		key = ability.key,
		spellId = ability.spellId,
		spellName = abilityDisplayName(ability),
		classification = ability.classification,
		confidence = ability.confidence or 0,
		mode = mode,
		nextAt = nextAt,
		remaining = remaining,
		duration = duration,
			provisional = ability.provisional == true,
			encounterAssociated = ability.encounterAssociated == true,
			sourceName = ability.associatedSourceName,
			seenThisPull = pullAbility and pullAbility.occurrences and pullAbility.occurrences > 0 or false,
			hpPct = ability.avgHpPct,
			bossName = context and context.name,
	}
end

local function isBossUnitToken(unit)
	return type(unit) == "string" and string.sub(unit, 1, 4) == "boss"
end

local function hasBossUnitSignal(context)
	return context and (
		context.sawBossUnit == true
		or isBossUnitToken(context.bossUnitToken)
		or isBossUnitToken(context.lastUnitToken)
		or (
			type(context.lastUnitSource) == "string"
			and string.sub(context.lastUnitSource, 1, 9) == "boss_unit"
		)
	)
end

local function isBossSignalContext(context)
	return context and (
		context.unitClassification == "worldboss"
		or hasBossUnitSignal(context)
	)
end

local function countActiveBossSignalContexts(contexts)
	local count = 0
	for _, context in pairs(contexts or {}) do
		if context.active and isBossSignalContext(context) then
			count = count + 1
		end
	end
	return count
end

local function isKnownRoutineAbilityName(spellName)
	local name = string.lower(tostring(spellName or ""))
	return name == "fierce blow" or name == "auto shot"
end

local function liveTimeAbility(pullAbility)
	if not pullAbility
		or isKnownRoutineAbilityName(pullAbility.spellName)
		or not pullAbility.intervalSamples
		or pullAbility.intervalSamples < 1
		or not pullAbility.minInterval
		or pullAbility.minInterval < C.MIN_INTERVAL_SECONDS then
		return nil
	end

	return {
		key = pullAbility.key,
		spellId = pullAbility.spellId,
		spellName = pullAbility.spellName,
		classification = "time",
		confidence = math.min(0.95, 0.25 + pullAbility.intervalSamples * 0.12),
			minInterval = pullAbility.minInterval,
			avgHpPct = pullAbility.avgHpPct,
			encounterAssociated = pullAbility.encounterAssociated == true,
			associatedSourceName = pullAbility.associatedSourceName,
			provisional = true,
		}
end

local function liveScoreContext(context, now)
	return {
		actorKey = context.actorKey,
		modelKey = context.modelKey,
		name = context.name,
		guid = context.guid,
		unitClassification = context.unitClassification,
		lastUnitSource = context.lastUnitSource,
		lastUnitToken = context.lastUnitToken,
		sawBossUnit = context.sawBossUnit,
		bossUnitToken = context.bossUnitToken,
		lastHpPct = context.lastHpPct,
		endReason = "active",
		duration = now - (context.startedAtSession or now),
	}
end

local function liveModelStats(context, bossState, pullWorldbossCount)
	local modelStats = bossState and bossState.modelStats or nil
	return {
		bossKey = context and context.modelKey or bossState and bossState.bossKey,
		contextCount = modelStats and modelStats.contextCount or 1,
		uniqueActorCount = modelStats and modelStats.uniqueActorCount or 1,
		pullWorldbossCount = pullWorldbossCount or 0,
	}
end

local function liveBossQualifies(context, bossState, pullWorldbossCount, now)
	local classifier = addon.Learning and addon.Learning.EncounterClassifier
	if not classifier or type(classifier.scoreContext) ~= "function" then
		return false
	end
	if not context or not bossState or not bossState.abilities or (bossState.eventCount or 0) <= 0 then
		return false
	end

	local decision = classifier.scoreContext(liveScoreContext(context, now), bossState, liveModelStats(context, bossState, pullWorldbossCount))
	return decision and decision.isBoss == true
end

local function unitMatchesContext(unit, context)
	if not context or not UnitExists or not UnitExists(unit) then
		return false
	end
	if context.guid and UnitGUID and UnitGUID(unit) == context.guid then
		return true
	end
	return not context.guid and context.name and UnitName and UnitName(unit) == context.name
end

local function unitInCombat(unit)
	return UnitExists
		and UnitExists(unit)
		and UnitAffectingCombat
		and UnitAffectingCombat(unit)
end

local function contextUnitInCombat(context)
	if not context then
		return false
	end
	if context.bossUnitToken and unitMatchesContext(context.bossUnitToken, context) and unitInCombat(context.bossUnitToken) then
		return true
	end
	if UnitExists then
		local maxBossFrames = tonumber(_G.MAX_BOSS_FRAMES) or C.MAX_BOSS_UNIT_FRAMES or 5
		for index = 1, maxBossFrames do
			local unit = "boss" .. index
			if unitMatchesContext(unit, context) and unitInCombat(unit) then
				return true
			end
		end
	end
	if context.lastUnitToken and unitMatchesContext(context.lastUnitToken, context) and unitInCombat(context.lastUnitToken) then
		return true
	end
	if unitMatchesContext("target", context) and unitInCombat("target") then
		return true
	end
	if unitMatchesContext("focus", context) and unitInCombat("focus") then
		return true
	end
	return false
end

local function contextHasCombatEvidence(context, bossState)
	return (bossState and (bossState.eventCount or 0) > 0)
		or ((context and context.eventCount or 0) > 0)
		or contextUnitInCombat(context)
end

local function currentContextHp(context)
	if not context then
		return nil
	end
	if context.bossUnitToken and unitMatchesContext(context.bossUnitToken, context) then
		return Util.unitHpPct(context.bossUnitToken)
	end
	if UnitExists then
		local maxBossFrames = tonumber(_G.MAX_BOSS_FRAMES) or C.MAX_BOSS_UNIT_FRAMES or 5
		for index = 1, maxBossFrames do
			local unit = "boss" .. index
			if unitMatchesContext(unit, context) then
				return Util.unitHpPct(unit)
			end
		end
	end
	if context.lastUnitToken and unitMatchesContext(context.lastUnitToken, context) then
		return Util.unitHpPct(context.lastUnitToken)
	end
	if unitMatchesContext("target", context) then
		return Util.unitHpPct("target")
	end
	if unitMatchesContext("focus", context) then
		return Util.unitHpPct("focus")
	end
	return context.lastHpPct
end

local function addBossPredictions(context, boss, bossState, minConfidence, now, scheduledKeys)
	if not context or not boss or not boss.abilities then
		return
	end

	for key, ability in pairs(boss.abilities) do
		if not ability.autoSuppressed and not ability.hidden and ability.confidence and ability.confidence >= minConfidence then
			local pullAbility = bossState and bossState.abilities and bossState.abilities[key] or nil
			local nextAt
			local mode = ability.classification

			if ability.classification == "time" and ability.minInterval then
				if pullAbility and pullAbility.lastOccurrenceAt then
					nextAt = pullAbility.lastOccurrenceAt + ability.minInterval
				elseif ability.minFirstOffset and context.startedAtSession then
					nextAt = context.startedAtSession + ability.minFirstOffset
				end
			elseif ability.classification == "one_time" and ability.minFirstOffset and context.startedAtSession then
				if not pullAbility or not pullAbility.lastOccurrenceAt then
					nextAt = context.startedAtSession + ability.minFirstOffset
				end
			elseif ability.classification == "hp" and ability.avgHpPct then
				local currentHp = currentContextHp(context)
				if not currentHp or currentHp >= ability.avgHpPct - 2 then
					addTimer(ability, pullAbility, context, nil, "hp", scheduledKeys)
				end
			end

			if nextAt and nextAt >= now - 8 then
				addTimer(ability, pullAbility, context, nextAt, mode, scheduledKeys)
			end
		end
	end
end

local function addLiveBossPredictions(context, boss, bossState, minConfidence, now, pullWorldbossCount, scheduledKeys)
	if not liveBossQualifies(context, bossState, pullWorldbossCount, now) then
		return
	end

	for key, pullAbility in pairs(bossState.abilities or {}) do
		local learnedAbility = boss and boss.abilities and boss.abilities[key] or nil
		if not learnedAbility or (not learnedAbility.hidden and not learnedAbility.autoSuppressed) then
			local ability = liveTimeAbility(pullAbility)
			if ability and ability.confidence >= minConfidence and pullAbility.lastOccurrenceAt then
				local nextAt = pullAbility.lastOccurrenceAt + ability.minInterval
				if nextAt >= now - 8 then
					addTimer(ability, pullAbility, context, nextAt, "time", scheduledKeys)
				end
			end
		end
	end
end

local function buildPredictions()
	clearPredictions()

	if not addon.db or not addon.db.config.enabled or not addon.db.config.timersEnabled then
		return predictions
	end
	if addon.charDB and addon.charDB.config and addon.charDB.config.panic then
		return predictions
	end

	local pull = addon.Capture.EncounterState.getCurrent()
	if not pull or not pull.zone then
		return predictions
	end

	local contexts = addon.Capture.EncounterState.getActiveBossContexts()
	if not contexts then
		return predictions
	end

	local pullState = addon.Learning.AbilityLearner.getCurrentPullState()
	local minConfidence = addon.db.config.minTimerConfidence or C.DEFAULT_CONFIG.minTimerConfidence
	local now = Util.now()
	local pullWorldbossCount = countActiveBossSignalContexts(contexts)
	local scheduledKeys = {}

	for actorKey, context in pairs(contexts) do
		if context.active and context.modelKey then
			local boss = addon.Learning.AbilityLearner.getBossModel(pull.zone.key, context.modelKey)
			local bossState = pullState and pullState.bosses and pullState.bosses[actorKey] or nil
			if contextHasCombatEvidence(context, bossState) then
				addBossPredictions(context, boss, bossState, minConfidence, now, scheduledKeys)
				addLiveBossPredictions(context, boss, bossState, minConfidence, now, pullWorldbossCount, scheduledKeys)
			end
		end
	end

	table.sort(predictions, function(a, b)
		if a.nextAt and b.nextAt then
			return a.nextAt < b.nextAt
		end
		if a.nextAt then
			return true
		end
		if b.nextAt then
			return false
		end
		return (a.hpPct or 0) > (b.hpPct or 0)
	end)

	local maxBars = addon.db.config.maxBars or C.DEFAULT_CONFIG.maxBars
	for index = #predictions, maxBars + 1, -1 do
		predictions[index] = nil
	end

	return predictions
end

function TimerScheduler.getPredictions(force)
	local now = Util.now()
	if force or now - lastUpdateAt >= C.TIMER_UPDATE_SECONDS then
		lastUpdateAt = now
		buildPredictions()
	end
	return predictions
end

function TimerScheduler.start()
	clearPredictions()
end
