-- AbilityLearner.lua
-- Maintains automatic boss ability models. Combat capture is intentionally
-- broad, but durable learning is written only after a hostile source context
-- has enough evidence to look like an actual boss encounter.

local addon = _G.BossTracker
local C = addon.Core.Constants
local Util = addon.Core.Util

local AbilityLearner = {}
addon.Learning.AbilityLearner = AbilityLearner

local currentPullState = nil
local runStats = nil
local learningBlocked = false
local dependencyWarningShown = false

local function countKeys(tbl)
	local count = 0
	if type(tbl) ~= "table" then
		return count
	end
	for _ in pairs(tbl) do
		count = count + 1
	end
	return count
end

local function warnRestartRequired()
	if dependencyWarningShown then
		return
	end
	dependencyWarningShown = true
	local message = "BossTracker update needs a full client restart. Boss learning is paused for this session; /reload is not enough after new addon files were added."
	if addon.Core.Logger then
		addon.Core.Logger.warn("AbilityLearner", "Required module missing", {
			missingModule = "EncounterClassifier",
			action = "restart_client",
		})
		addon.Core.Logger.chat(message)
	elseif DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00" .. message .. "|r")
	end
end

local function dependenciesReady()
	local classifier = addon.Learning and addon.Learning.EncounterClassifier
	if classifier and type(classifier.scoreContext) == "function" then
		return true
	end

	learningBlocked = true
	warnRestartRequired()
	return false
end

local function currentRunId()
	local run = addon.Core.Logger and addon.Core.Logger.getRun()
	return run and run.id or 0
end

local function ensureRunStats()
	local runId = currentRunId()
	if runStats and runStats.runId == runId then
		return runStats
	end

	runStats = {
		runId = runId,
		models = {},
	}
	return runStats
end

local function noteModelContext(bossKey, actorKey)
	local stats = ensureRunStats()
	local model = stats.models[bossKey]
	if not model then
		model = {
			bossKey = bossKey,
			contextCount = 0,
			actors = {},
			uniqueActorCount = 0,
		}
		stats.models[bossKey] = model
	end

	model.contextCount = model.contextCount + 1
	if actorKey and not model.actors[actorKey] then
		model.actors[actorKey] = true
		model.uniqueActorCount = model.uniqueActorCount + 1
	end
	return model
end

local function getModelStats(bossKey)
	local stats = ensureRunStats()
	return stats.models[bossKey]
end

local function buildPullDecisionStats(pullState, pull)
	local stats = {
		contextCount = 0,
		worldbossCount = 0,
	}

	for actorKey, bossState in pairs(pullState.bosses or {}) do
		if bossState.eventCount and bossState.eventCount > 0 then
			local context = pull and pull.bossContexts and pull.bossContexts[actorKey] or nil
			stats.contextCount = stats.contextCount + 1
				if context and (
					context.unitClassification == "worldboss"
					or context.sawBossUnit == true
					or (type(context.bossUnitToken) == "string" and string.sub(context.bossUnitToken, 1, 4) == "boss")
					or (type(context.lastUnitToken) == "string" and string.sub(context.lastUnitToken, 1, 4) == "boss")
					or (
						type(context.lastUnitSource) == "string"
					and string.sub(context.lastUnitSource, 1, 9) == "boss_unit"
				)
			) then
				stats.worldbossCount = stats.worldbossCount + 1
			end
		end
	end

	return stats
end

local function decisionModelStats(bossState, pullDecisionStats)
	local modelStats = getModelStats(bossState.bossKey) or {}
	return {
		bossKey = bossState.bossKey,
		contextCount = modelStats.contextCount or 1,
		uniqueActorCount = modelStats.uniqueActorCount or 1,
		pullContextCount = pullDecisionStats and pullDecisionStats.contextCount or 0,
		pullWorldbossCount = pullDecisionStats and pullDecisionStats.worldbossCount or 0,
	}
end

local function ensureZone(zoneInfo)
	local zones = addon.db.learned.zones
	local zoneKey = zoneInfo and zoneInfo.key or "unknown"
	local zone = zones[zoneKey]
	if not zone then
		zone = {
			key = zoneKey,
			name = zoneInfo and zoneInfo.name or "Unknown Zone",
			createdAt = Util.wallTime(),
			lastSeenAt = Util.wallTime(),
			bosses = {},
		}
		zones[zoneKey] = zone
	end
	zone.lastSeenAt = Util.wallTime()
	zone.name = zoneInfo and zoneInfo.name or zone.name
	return zone
end

local function ensureBoss(zone, bossKey, bossName)
	bossKey = bossKey or "unknown_boss"
	local boss = zone.bosses[bossKey]
	if not boss then
		boss = {
			key = bossKey,
			name = bossName or "Unknown Boss",
			createdAt = Util.wallTime(),
			lastSeenAt = Util.wallTime(),
			pullCount = 0,
			abilities = {},
			encounterConfidence = 0,
			encounterEvidenceVersion = 2,
		}
		zone.bosses[bossKey] = boss
	end
	boss.name = bossName or boss.name
	boss.lastSeenAt = Util.wallTime()
	boss.suppressed = nil
	return boss
end

local function ensureAbility(boss, recordOrState)
	local key = recordOrState.key or recordOrState.spellKey
	local ability = boss.abilities[key]
	if not ability then
		ability = {
			key = key,
			spellId = recordOrState.spellId,
			spellName = recordOrState.spellName,
			createdAt = Util.wallTime(),
			lastSeenAt = Util.wallTime(),
			eventCount = 0,
			occurrenceCount = 0,
			pullSeenCount = 0,
			intervalSamples = 0,
			minInterval = nil,
			maxInterval = nil,
			avgInterval = nil,
			minFirstOffset = nil,
			maxFirstOffset = nil,
			avgFirstOffset = nil,
			firstOffsetSamples = 0,
			hpSamples = 0,
			minHpPct = nil,
			maxHpPct = nil,
			avgHpPct = nil,
			classification = "unknown",
			confidence = 0,
			mismatchCount = 0,
			events = {},
		}
		boss.abilities[key] = ability
	end
	ability.spellId = ability.spellId or recordOrState.spellId
	ability.spellName = recordOrState.spellName or ability.spellName
	ability.lastSeenAt = Util.wallTime()
	ability.events = type(ability.events) == "table" and ability.events or {}
	return ability
end

local function updateAverage(currentAverage, currentSamples, value)
	if not value then
		return currentAverage, currentSamples
	end
	currentSamples = currentSamples or 0
	if not currentAverage or currentSamples <= 0 then
		return value, 1
	end
	local nextSamples = currentSamples + 1
	return currentAverage + ((value - currentAverage) / nextSamples), nextSamples
end

local function mergeAverage(currentAverage, currentSamples, addedAverage, addedSamples)
	currentSamples = currentSamples or 0
	addedSamples = addedSamples or 0
	if not addedAverage or addedSamples <= 0 then
		return currentAverage, currentSamples
	end
	if not currentAverage or currentSamples <= 0 then
		return addedAverage, addedSamples
	end
	local totalSamples = currentSamples + addedSamples
	return ((currentAverage * currentSamples) + (addedAverage * addedSamples)) / totalSamples, totalSamples
end

local function updateMinMax(ability, fieldMin, fieldMax, value)
	if not value then
		return
	end
	if not ability[fieldMin] or value < ability[fieldMin] then
		ability[fieldMin] = value
	end
	if not ability[fieldMax] or value > ability[fieldMax] then
		ability[fieldMax] = value
	end
end

local function mergeMinMax(target, targetMin, targetMax, source, sourceMin, sourceMax)
	if source[sourceMin] then
		updateMinMax(target, targetMin, targetMax, source[sourceMin])
	end
	if source[sourceMax] then
		updateMinMax(target, targetMin, targetMax, source[sourceMax])
	end
end

local function classify(ability)
	local confidence = 0
	local classification = "unknown"

	if ability.intervalSamples and ability.intervalSamples >= 1 and ability.minInterval and ability.minInterval >= C.MIN_INTERVAL_SECONDS then
		classification = "time"
		confidence = math.min(0.95, 0.25 + ability.intervalSamples * 0.12)
	elseif ability.pullSeenCount and ability.pullSeenCount >= 1 and ability.occurrenceCount == ability.pullSeenCount and ability.minFirstOffset then
		classification = "one_time"
		confidence = math.min(0.80, 0.15 + ability.pullSeenCount * 0.10)
	end

	if classification ~= "time" and ability.hpSamples and ability.hpSamples >= 2 and ability.minHpPct and ability.maxHpPct then
		local hpSpread = ability.maxHpPct - ability.minHpPct
		if hpSpread <= 7 and ability.hpSamples >= ability.intervalSamples then
			classification = "hp"
			confidence = math.max(confidence, math.min(0.75, 0.25 + ability.hpSamples * 0.08))
		end
	end

	if ability.mismatchCount and ability.mismatchCount > 0 then
		confidence = math.max(0, confidence - math.min(0.40, ability.mismatchCount * 0.08))
	end

	ability.classification = classification
	ability.confidence = confidence
end

local function isKnownRoutineAbilityName(spellName)
	local name = string.lower(tostring(spellName or ""))
	return name == "fierce blow" or name == "auto shot"
end

local function isCastStartResolutionEvent(eventType)
	return eventType == "SPELL_CAST_SUCCESS"
		or eventType == "SPELL_DAMAGE"
		or eventType == "SPELL_MISSED"
		or eventType == "SPELL_AURA_APPLIED"
		or eventType == "SPELL_AURA_REFRESH"
		or eventType == "SPELL_HEAL"
		or eventType == "SPELL_SUMMON"
end

local function isCastSuccessFollowupEvent(eventType)
	return eventType == "SPELL_DAMAGE"
		or eventType == "SPELL_MISSED"
		or eventType == "SPELL_AURA_APPLIED"
		or eventType == "SPELL_AURA_REFRESH"
		or eventType == "SPELL_HEAL"
		or eventType == "SPELL_SUMMON"
end

local function isAuraLifecycleEffectEvent(eventType)
	return eventType == "SPELL_DAMAGE"
		or eventType == "SPELL_MISSED"
		or eventType == "SPELL_HEAL"
		or eventType == "SPELL_SUMMON"
end

local function isSelfAuraEvent(record)
	return record
		and record.sourceGUID
		and record.destGUID
		and record.sourceGUID == record.destGUID
		and (
			record.eventType == "SPELL_AURA_APPLIED"
			or record.eventType == "SPELL_AURA_REFRESH"
			or record.eventType == "SPELL_AURA_REMOVED"
		)
end

local function hasCastStartEvent(ability)
	return ability and ability.events and (ability.events.SPELL_CAST_START or 0) > 0
end

local function hasCastSuccessEvent(ability)
	return ability and ability.events and (ability.events.SPELL_CAST_SUCCESS or 0) > 0
end

local function hasAuraLifecycleEvidence(ability)
	return ability and ability.events
		and (ability.events.SPELL_AURA_APPLIED or 0) > 0
		and (ability.events.SPELL_AURA_REMOVED or 0) > 0
end

local function hasCastResolutionEvidence(ability)
	if not ability or not ability.events then
		return false
	end
	return (ability.events.SPELL_DAMAGE or 0) > 0
		or (ability.events.SPELL_CAST_SUCCESS or 0) > 0
		or (ability.events.SPELL_MISSED or 0) > 0
		or (ability.events.SPELL_AURA_APPLIED or 0) > 0
		or (ability.events.SPELL_AURA_REFRESH or 0) > 0
		or (ability.events.SPELL_HEAL or 0) > 0
		or (ability.events.SPELL_SUMMON or 0) > 0
end

local function hasEffectResolutionEvidence(ability)
	if not ability or not ability.events then
		return false
	end
	return (ability.events.SPELL_DAMAGE or 0) > 0
		or (ability.events.SPELL_MISSED or 0) > 0
		or (ability.events.SPELL_HEAL or 0) > 0
		or (ability.events.SPELL_SUMMON or 0) > 0
end

local function repairCastResolutionInterval(ability)
	if not hasCastResolutionEvidence(ability) then
		return false
	end
	if not ability.minInterval or not ability.maxInterval then
		return false
	end

	local hasCastStartPollution = hasCastStartEvent(ability)
		and ability.minInterval <= C.CAST_RESOLUTION_DEDUPE_SECONDS
		and ability.maxInterval >= C.CAST_RESOLUTION_DEDUPE_SECONDS * 2
	local hasAuraLifecyclePollution = not hasCastStartEvent(ability)
		and hasCastSuccessEvent(ability)
		and hasAuraLifecycleEvidence(ability)
		and hasEffectResolutionEvidence(ability)
		and ability.minInterval <= C.AURA_LIFECYCLE_DEDUPE_SECONDS
		and ability.maxInterval >= ability.minInterval + C.MIN_INTERVAL_SECONDS
	if not hasCastStartPollution and not hasAuraLifecyclePollution then
		return false
	end

	ability.originalMinInterval = ability.originalMinInterval or ability.minInterval
	ability.originalAvgInterval = ability.originalAvgInterval or ability.avgInterval
	ability.castResolutionAdjusted = true
	ability.minInterval = ability.maxInterval
	ability.avgInterval = ability.maxInterval
	return true
end

local function shouldAcceptOccurrence(pullAbility, record)
	if not pullAbility.lastOccurrenceAt then
		return true
	end

	local delta = record.t - pullAbility.lastOccurrenceAt
	if delta < C.EVENT_DEDUPE_SECONDS then
		return false
	end

	if pullAbility.lastOccurrenceEventType == "SPELL_CAST_START"
		and isCastStartResolutionEvent(record.eventType)
		and delta <= C.CAST_RESOLUTION_DEDUPE_SECONDS then
		return false
	end

	if pullAbility.lastOccurrenceEventType == "SPELL_CAST_SUCCESS"
		and isCastSuccessFollowupEvent(record.eventType)
		and delta <= C.CAST_RESOLUTION_DEDUPE_SECONDS then
		return false
	end

	if pullAbility.activeSelfAura
		and isAuraLifecycleEffectEvent(record.eventType)
		and pullAbility.activeSelfAuraStartedAt then
		local auraAge = record.t - pullAbility.activeSelfAuraStartedAt
		if auraAge >= 0 and auraAge <= C.AURA_LIFECYCLE_DEDUPE_SECONDS then
			return false
		end
	end

	return true
end

local function eventPriority(ability)
	local events = ability and ability.events or nil
	if not events then
		return 0
	end
	if (events.SPELL_CAST_START or 0) > 0 then
		return 4
	end
	if (events.SPELL_CAST_SUCCESS or 0) > 0 then
		return 3
	end
	if (events.SPELL_AURA_APPLIED or 0) > 0 or (events.SPELL_AURA_REFRESH or 0) > 0 then
		return 2
	end
	if (events.SPELL_DAMAGE or 0) > 0 or (events.SPELL_MISSED or 0) > 0 then
		return 1
	end
	return 0
end

local function copyTimingFields(target, source)
	target.spellId = source.spellId or target.spellId
	target.spellName = source.spellName or target.spellName
	target.occurrenceCount = math.max(tonumber(target.occurrenceCount) or 0, tonumber(source.occurrenceCount) or 0)
	target.pullSeenCount = math.max(tonumber(target.pullSeenCount) or 0, tonumber(source.pullSeenCount) or 0)
	target.intervalSamples = tonumber(source.intervalSamples) or target.intervalSamples
	target.minInterval = source.minInterval or target.minInterval
	target.maxInterval = source.maxInterval or target.maxInterval
	target.avgInterval = source.avgInterval or target.avgInterval
	target.minFirstOffset = source.minFirstOffset or target.minFirstOffset
	target.maxFirstOffset = source.maxFirstOffset or target.maxFirstOffset
	target.avgFirstOffset = source.avgFirstOffset or target.avgFirstOffset
	target.firstOffsetSamples = source.firstOffsetSamples or target.firstOffsetSamples
	target.hpSamples = source.hpSamples or target.hpSamples
	target.minHpPct = source.minHpPct or target.minHpPct
	target.maxHpPct = source.maxHpPct or target.maxHpPct
	target.avgHpPct = source.avgHpPct or target.avgHpPct
end

local function mergeDuplicateAbility(target, source)
	local targetPriority = eventPriority(target)
	local sourcePriority = eventPriority(source)
	target.eventCount = (tonumber(target.eventCount) or 0) + (tonumber(source.eventCount) or 0)
	target.events = type(target.events) == "table" and target.events or {}
	for eventType, count in pairs(source.events or {}) do
		target.events[eventType] = (target.events[eventType] or 0) + count
	end
	target.createdAt = math.min(tonumber(target.createdAt) or Util.wallTime(), tonumber(source.createdAt) or Util.wallTime())
	target.lastSeenAt = math.max(tonumber(target.lastSeenAt) or 0, tonumber(source.lastSeenAt) or 0)
	target.duplicateSpellIds = type(target.duplicateSpellIds) == "table" and target.duplicateSpellIds or {}
	if target.spellId then
		target.duplicateSpellIds[tostring(target.spellId)] = true
	end
	if source.spellId then
		target.duplicateSpellIds[tostring(source.spellId)] = true
	end

	if sourcePriority > targetPriority
		or (sourcePriority == targetPriority and (tonumber(source.intervalSamples) or 0) > (tonumber(target.intervalSamples) or 0)) then
		copyTimingFields(target, source)
	else
		target.occurrenceCount = math.max(tonumber(target.occurrenceCount) or 0, tonumber(source.occurrenceCount) or 0)
		target.pullSeenCount = math.max(tonumber(target.pullSeenCount) or 0, tonumber(source.pullSeenCount) or 0)
	end
end

local function canonicalizeLearnedAbilityModels()
	if not addon.db or not addon.db.learned or type(addon.db.learned.zones) ~= "table" then
		return
	end

	local merged = 0
	local repaired = 0
	for _, zone in pairs(addon.db.learned.zones) do
		if type(zone) == "table" and type(zone.bosses) == "table" then
			for _, boss in pairs(zone.bosses) do
				if type(boss) == "table" and type(boss.abilities) == "table" then
					local canonicalAbilities = {}
					local changed = false
					for key, ability in pairs(boss.abilities) do
						if type(ability) == "table" then
							local canonicalKey = Util.timerAbilityKey(ability.spellId, ability.spellName)
							ability.key = canonicalKey
							if canonicalAbilities[canonicalKey] then
								mergeDuplicateAbility(canonicalAbilities[canonicalKey], ability)
								merged = merged + 1
								changed = true
							else
								canonicalAbilities[canonicalKey] = ability
								if canonicalKey ~= key then
									changed = true
								end
							end
						end
					end
					if changed then
						boss.abilities = canonicalAbilities
					end
					for _, ability in pairs(boss.abilities) do
						if repairCastResolutionInterval(ability) then
							repaired = repaired + 1
						end
					end
				end
			end
		end
	end

	if (merged > 0 or repaired > 0) and addon.Core.Logger and addon.Core.Logger.event then
		addon.Core.Logger.event({
			kind = "learner_canonicalized_abilities",
			merged = merged,
			repairedCastResolutionIntervals = repaired,
		})
	end
end

local function shouldAutoSuppressAbility(ability, sharedBossCount)
	if not ability then
		return false
	end
	sharedBossCount = sharedBossCount or 0
	if isKnownRoutineAbilityName(ability.spellName) then
		return true
	end
	return sharedBossCount >= 4
		and ability.classification == "time"
		and ability.minInterval
		and ability.minInterval <= 8
end

local function refreshSharedAbilitySuppression(zone, touchedKeys)
	if not zone or not zone.bosses or not touchedKeys then
		return
	end

	for spellKey in pairs(touchedKeys) do
		local abilities = {}
		local sharedBossCount = 0
		for _, boss in pairs(zone.bosses) do
			if type(boss) == "table" and not boss.suppressed and type(boss.abilities) == "table" then
				local ability = boss.abilities[spellKey]
				if ability then
					sharedBossCount = sharedBossCount + 1
					abilities[#abilities + 1] = ability
				end
			end
		end

		for index = 1, #abilities do
			local ability = abilities[index]
			ability.sharedBossCount = sharedBossCount
			if shouldAutoSuppressAbility(ability, sharedBossCount) then
				ability.autoSuppressed = true
				ability.suppressionReason = isKnownRoutineAbilityName(ability.spellName) and "routine_ability" or "routine_shared_ability"
			elseif ability.autoSuppressed and (ability.suppressionReason == "routine_shared_ability" or ability.suppressionReason == "routine_ability") then
				ability.autoSuppressed = nil
				ability.suppressionReason = nil
			end
		end
	end
end

local function refreshLearnedAbilityClassifications()
	if not addon.db or not addon.db.learned or type(addon.db.learned.zones) ~= "table" then
		return
	end

	local zoneCount = 0
	local bossCount = 0
	local abilityCount = 0
	for _, zone in pairs(addon.db.learned.zones) do
		if type(zone) == "table" and type(zone.bosses) == "table" then
			local touchedKeys = {}
			local zoneTouched = false
			for _, boss in pairs(zone.bosses) do
				if type(boss) == "table" and type(boss.abilities) == "table" then
					bossCount = bossCount + 1
					for key, ability in pairs(boss.abilities) do
						if type(ability) == "table" then
							classify(ability)
							touchedKeys[key] = true
							zoneTouched = true
							abilityCount = abilityCount + 1
						end
					end
				end
			end
			if zoneTouched then
				zoneCount = zoneCount + 1
				refreshSharedAbilitySuppression(zone, touchedKeys)
			end
		end
	end

	if abilityCount > 0 and addon.Core.Logger and addon.Core.Logger.event then
		addon.Core.Logger.event({
			kind = "learner_refresh_classifications",
			zoneCount = zoneCount,
			bossCount = bossCount,
			abilityCount = abilityCount,
		})
	end
end

local function ensureCurrentPull(pull)
	if currentPullState and currentPullState.pullId == pull.id then
		return currentPullState
	end

	currentPullState = {
		pullId = pull.id,
		runId = currentRunId(),
		startedAtSession = pull.startedAtSession,
		zone = pull.zone,
		bosses = {},
	}
	return currentPullState
end

local function ensureBossState(pullState, record, pull)
	local context = record.bossContext
	local actorKey = context and context.actorKey or record.sourceActorKey or Util.actorKey(record.sourceName, record.sourceGUID)
	local bossKey = context and context.modelKey or record.bossKey or record.sourceBossKey or Util.bossKey(record.sourceName, record.sourceGUID)
	local bossName = context and context.name or record.bossName or record.sourceName or pull.bossName or "Unknown Boss"
	if not actorKey or not bossKey then
		return nil
	end

	local bossState = pullState.bosses[actorKey]
	if not bossState then
		bossState = {
			actorKey = actorKey,
			bossKey = bossKey,
			bossName = bossName,
			startedAtSession = context and context.startedAtSession or record.bossStartedAtSession or record.t or pull.startedAtSession,
			firstSeenAt = record.t,
			lastSeenAt = record.t,
			eventCount = 0,
			occurrenceCount = 0,
			abilities = {},
			modelStats = noteModelContext(bossKey, actorKey),
		}
		pullState.bosses[actorKey] = bossState
	end

	bossState.bossKey = bossKey or bossState.bossKey
	bossState.bossName = bossName or bossState.bossName
	bossState.lastSeenAt = record.t or bossState.lastSeenAt
	bossState.lastHpPct = record.hpPct or context and context.lastHpPct or bossState.lastHpPct
	return bossState
end

local function noteBossAbility(bossState, record, primaryEvent)
	local state = bossState.abilities[record.spellKey]
	if not state then
		state = {
			key = record.spellKey,
			spellId = record.spellId,
			spellName = record.spellName,
			firstSeenAt = record.t,
			lastSeenAt = record.t,
			lastOccurrenceAt = nil,
			previousOccurrenceAt = nil,
			firstOccurrenceAt = nil,
			occurrences = 0,
			eventCount = 0,
			events = {},
			acceptedEvents = 0,
			sourceName = record.sourceName,
			encounterAssociated = false,
			associatedSourceName = nil,
			hpPct = record.hpPct,
			intervalSamples = 0,
			minInterval = nil,
			maxInterval = nil,
			avgInterval = nil,
			firstOffset = nil,
			hpSamples = 0,
			minHpPct = nil,
			maxHpPct = nil,
			avgHpPct = nil,
			activeSelfAura = false,
			activeSelfAuraStartedAt = nil,
			activeSelfAuraEndedAt = nil,
		}
		bossState.abilities[record.spellKey] = state
	end

	state.lastSeenAt = record.t
	state.eventCount = state.eventCount + 1
	state.events[record.eventType] = (state.events[record.eventType] or 0) + 1
	state.sourceName = state.sourceName or record.sourceName
	if record.eventType == "SPELL_CAST_START" and record.spellId then
		state.spellId = record.spellId
	end
	if record.associatedWithBoss then
		state.encounterAssociated = true
		state.associatedSourceName = record.associatedSourceName or state.associatedSourceName or record.sourceName
	end
	if isSelfAuraEvent(record) then
		if record.eventType == "SPELL_AURA_REMOVED" then
			state.activeSelfAura = false
			state.activeSelfAuraEndedAt = record.t
		else
			state.activeSelfAura = true
			state.activeSelfAuraStartedAt = record.t
		end
	end
	state.hpPct = record.hpPct or state.hpPct
	if primaryEvent then
		state.acceptedEvents = state.acceptedEvents + 1
	end
	return state
end

local function noteOccurrence(bossState, pullAbility, record)
	pullAbility.occurrences = pullAbility.occurrences + 1
	pullAbility.previousOccurrenceAt = pullAbility.lastOccurrenceAt
	pullAbility.lastOccurrenceAt = record.t
	pullAbility.lastOccurrenceEventType = record.eventType
	bossState.occurrenceCount = bossState.occurrenceCount + 1
	if not pullAbility.firstOccurrenceAt then
		pullAbility.firstOccurrenceAt = record.t
		pullAbility.firstOffset = record.t - (bossState.startedAtSession or record.t)
	end

	if pullAbility.previousOccurrenceAt then
		local interval = record.t - pullAbility.previousOccurrenceAt
		if interval >= C.MIN_INTERVAL_SECONDS and interval <= C.MAX_REASONABLE_INTERVAL_SECONDS then
			pullAbility.avgInterval, pullAbility.intervalSamples = updateAverage(pullAbility.avgInterval, pullAbility.intervalSamples, interval)
			updateMinMax(pullAbility, "minInterval", "maxInterval", interval)
		end
	end

	if record.hpPct then
		pullAbility.avgHpPct, pullAbility.hpSamples = updateAverage(pullAbility.avgHpPct, pullAbility.hpSamples, record.hpPct)
		updateMinMax(pullAbility, "minHpPct", "maxHpPct", record.hpPct)
	end
end

local function orderedRingItems(buffer)
	local wrapped = {}
	if type(buffer) ~= "table" then
		return {}
	end

	local items = type(buffer.items) == "table" and buffer.items or buffer
	local size = tonumber(buffer.size) or #items
	local sequence = 0
	if type(buffer.items) == "table" and size > 0 then
		local maxEntries = tonumber(buffer.max) or size
		local startIndex = (tonumber(buffer.next) or 1) - size
		while startIndex <= 0 do
			startIndex = startIndex + maxEntries
		end
		for offset = 0, size - 1 do
			local index = startIndex + offset
			while index > maxEntries do
				index = index - maxEntries
			end
			local value = items[index]
			if type(value) == "table" then
				sequence = sequence + 1
				wrapped[#wrapped + 1] = {
					record = value,
					order = sequence,
				}
			end
		end
	else
		for index = 1, #items do
			if type(items[index]) == "table" then
				sequence = sequence + 1
				wrapped[#wrapped + 1] = {
					record = items[index],
					order = sequence,
				}
			end
		end
	end

	table.sort(wrapped, function(left, right)
		local leftTime = left.record.t or left.record.combatTimestamp or 0
		local rightTime = right.record.t or right.record.combatTimestamp or 0
		if leftTime == rightTime then
			return left.order < right.order
		end
		return leftTime < rightTime
	end)

	local ordered = {}
	for index = 1, #wrapped do
		ordered[index] = wrapped[index].record
	end
	return ordered
end

local function abilityEvidenceKey(zoneKey, bossKey, spellKey)
	return tostring(zoneKey or "unknown")
		.. "\031"
		.. tostring(bossKey or "unknown")
		.. "\031"
		.. tostring(spellKey or "unknown")
end

local function normalizedReplayRecord(record)
	if type(record) ~= "table" or not record.eventType or not record.t then
		return nil
	end

	local spellKey = record.spellKey
	if record.spellName or record.spellId then
		spellKey = Util.timerAbilityKey(record.spellId, record.spellName)
	end
	if not spellKey then
		return nil
	end

	local bossKey = record.bossKey
		or record.sourceBossKey
		or (record.bossContext and record.bossContext.modelKey)
		or Util.bossKey(record.bossName or record.sourceName, record.sourceGUID)
	if not bossKey then
		return nil
	end

	local copy = {}
	for key, value in pairs(record) do
		copy[key] = value
	end
	copy.spellKey = spellKey
	copy.bossKey = bossKey
	copy.bossName = record.bossName or record.sourceName or "Unknown Boss"
	return copy
end

local function mergePullAbilityEvidence(target, pullAbility)
	if not pullAbility or (pullAbility.intervalSamples or 0) <= 0 then
		return
	end

	target.spellId = pullAbility.spellId or target.spellId
	target.spellName = pullAbility.spellName or target.spellName
	target.occurrenceCount = (target.occurrenceCount or 0) + (pullAbility.occurrences or 0)
	target.pullSeenCount = (target.pullSeenCount or 0) + 1
	target.avgInterval, target.intervalSamples = mergeAverage(
		target.avgInterval,
		target.intervalSamples,
		pullAbility.avgInterval,
		pullAbility.intervalSamples
	)
	mergeMinMax(target, "minInterval", "maxInterval", pullAbility, "minInterval", "maxInterval")
	target.avgFirstOffset, target.firstOffsetSamples = updateAverage(
		target.avgFirstOffset,
		target.firstOffsetSamples,
		pullAbility.firstOffset
	)
	updateMinMax(target, "minFirstOffset", "maxFirstOffset", pullAbility.firstOffset)

	target.events = type(target.events) == "table" and target.events or {}
	for eventType, count in pairs(pullAbility.events or {}) do
		target.events[eventType] = (target.events[eventType] or 0) + count
	end
end

local function buildDebugAbilityEvidence()
	local evidenceByKey = {}
	local debug = addon.db and addon.db.debug
	if not debug or type(debug.runs) ~= "table" then
		return evidenceByKey
	end

	for _, run in ipairs(debug.runs) do
		if type(run) == "table" and type(run.pulls) == "table" then
			for _, pull in ipairs(run.pulls) do
				if type(pull) == "table" and pull.zone and pull.zone.key then
					local bossStates = {}
					local records = orderedRingItems(pull.events)
					for index = 1, #records do
						local record = normalizedReplayRecord(records[index])
						if record then
							local bossState = bossStates[record.bossKey]
							if not bossState then
								bossState = {
									bossKey = record.bossKey,
									bossName = record.bossName,
									startedAtSession = record.bossStartedAtSession
										or (record.bossContext and record.bossContext.startedAtSession)
										or pull.startedAtSession
										or record.t,
									occurrenceCount = 0,
									abilities = {},
								}
								bossStates[record.bossKey] = bossState
							end

							local occurrenceCandidate = addon.Learning.Relevance.isPrimaryOccurrence(record.eventType)
							local pullAbility = noteBossAbility(bossState, record, occurrenceCandidate)
							if occurrenceCandidate and shouldAcceptOccurrence(pullAbility, record) then
								noteOccurrence(bossState, pullAbility, record)
							end
						end
					end

					for bossKey, bossState in pairs(bossStates) do
						for spellKey, pullAbility in pairs(bossState.abilities or {}) do
							if (pullAbility.intervalSamples or 0) > 0 then
								local key = abilityEvidenceKey(pull.zone.key, bossKey, spellKey)
								local evidence = evidenceByKey[key]
								if not evidence then
									evidence = {
										key = spellKey,
										bossKey = bossKey,
										zoneKey = pull.zone.key,
										events = {},
										intervalSamples = 0,
										firstOffsetSamples = 0,
									}
									evidenceByKey[key] = evidence
								end
								mergePullAbilityEvidence(evidence, pullAbility)
							end
						end
					end
				end
			end
		end
	end

	return evidenceByKey
end

local function shouldRepairFromDebugEvidence(ability, evidence)
	if not ability or not evidence or (evidence.intervalSamples or 0) <= 0 then
		return false
	end
	if not hasCastResolutionEvidence(ability) then
		return false
	end
	if ability.minInterval and evidence.minInterval and evidence.minInterval <= ability.minInterval + 0.75 then
		return false
	end
	if hasCastStartEvent(ability) and ability.minInterval and ability.minInterval <= C.CAST_RESOLUTION_DEDUPE_SECONDS then
		return true
	end
	if hasAuraLifecycleEvidence(ability)
		and hasEffectResolutionEvidence(ability)
		and ability.minInterval
		and ability.minInterval <= C.AURA_LIFECYCLE_DEDUPE_SECONDS then
		return true
	end
	if hasAuraLifecycleEvidence(evidence)
		and hasEffectResolutionEvidence(evidence)
		and ability.minInterval
		and evidence.minInterval
		and evidence.minInterval >= ability.minInterval * 1.35 then
		return true
	end
	return false
end

local function repairLearnedAbilityModelsFromDebugRuns()
	if not addon.db or not addon.db.learned or type(addon.db.learned.zones) ~= "table" then
		return
	end

	local evidenceByKey = buildDebugAbilityEvidence()
	local repaired = 0
	for zoneKey, zone in pairs(addon.db.learned.zones) do
		if type(zone) == "table" and type(zone.bosses) == "table" then
			for bossKey, boss in pairs(zone.bosses) do
				if type(boss) == "table" and type(boss.abilities) == "table" then
					for spellKey, ability in pairs(boss.abilities) do
						if type(ability) == "table" then
							local evidence = evidenceByKey[abilityEvidenceKey(zoneKey, bossKey, spellKey)]
							if shouldRepairFromDebugEvidence(ability, evidence) then
								ability.originalMinInterval = ability.originalMinInterval or ability.minInterval
								ability.originalMaxInterval = ability.originalMaxInterval or ability.maxInterval
								ability.originalAvgInterval = ability.originalAvgInterval or ability.avgInterval
								ability.originalIntervalSamples = ability.originalIntervalSamples or ability.intervalSamples
								ability.lifecycleRepaired = true
								ability.lifecycleRepairSource = "debug_pull_replay"
								ability.minInterval = evidence.minInterval
								ability.maxInterval = evidence.maxInterval
								ability.avgInterval = evidence.avgInterval
								ability.intervalSamples = evidence.intervalSamples
								ability.minFirstOffset = evidence.minFirstOffset or ability.minFirstOffset
								ability.maxFirstOffset = evidence.maxFirstOffset or ability.maxFirstOffset
								ability.avgFirstOffset = evidence.avgFirstOffset or ability.avgFirstOffset
								ability.firstOffsetSamples = evidence.firstOffsetSamples or ability.firstOffsetSamples
								repaired = repaired + 1
							end
						end
					end
				end
			end
		end
	end

	if repaired > 0 and addon.Core.Logger and addon.Core.Logger.event then
		addon.Core.Logger.event({
			kind = "learner_debug_repaired_lifecycle_intervals",
			repaired = repaired,
		})
	end
end

local function mergeAbilityState(boss, pullAbility)
	local ability = ensureAbility(boss, pullAbility)
	ability.eventCount = (ability.eventCount or 0) + (pullAbility.eventCount or 0)
	ability.occurrenceCount = (ability.occurrenceCount or 0) + (pullAbility.occurrences or 0)

	for eventType, count in pairs(pullAbility.events or {}) do
		ability.events[eventType] = (ability.events[eventType] or 0) + count
	end

	if pullAbility.encounterAssociated then
		ability.encounterAssociated = true
		ability.associatedSourceName = pullAbility.associatedSourceName or ability.associatedSourceName
		ability.sourceType = "encounter_add"
	end

	if pullAbility.occurrences and pullAbility.occurrences > 0 then
		ability.pullSeenCount = (ability.pullSeenCount or 0) + 1
		ability.avgFirstOffset, ability.firstOffsetSamples = updateAverage(
			ability.avgFirstOffset,
			ability.firstOffsetSamples,
			pullAbility.firstOffset
		)
		updateMinMax(ability, "minFirstOffset", "maxFirstOffset", pullAbility.firstOffset)
	end

	if ability.classification == "time" and ability.minInterval and pullAbility.avgInterval then
		if math.abs(pullAbility.avgInterval - ability.minInterval) > math.max(8, ability.minInterval * 0.40) then
			ability.mismatchCount = (ability.mismatchCount or 0) + 1
		end
	end

	ability.avgInterval, ability.intervalSamples = mergeAverage(
		ability.avgInterval,
		ability.intervalSamples,
		pullAbility.avgInterval,
		pullAbility.intervalSamples
	)
	mergeMinMax(ability, "minInterval", "maxInterval", pullAbility, "minInterval", "maxInterval")

	ability.avgHpPct, ability.hpSamples = mergeAverage(
		ability.avgHpPct,
		ability.hpSamples,
		pullAbility.avgHpPct,
		pullAbility.hpSamples
	)
	mergeMinMax(ability, "minHpPct", "maxHpPct", pullAbility, "minHpPct", "maxHpPct")

	classify(ability)
end

local function promoteBossState(pullState, bossState, decision)
	local zone = ensureZone(pullState.zone)
	local boss = ensureBoss(zone, bossState.bossKey, bossState.bossName)
	local touchedKeys = {}
	boss.pullCount = (boss.pullCount or 0) + 1
	boss.lastEndReason = bossState.endReason
	boss.lastDuration = bossState.duration
	boss.lastEndHpPct = decision.endHpPct
	boss.encounterConfidence = decision.confidence
	boss.encounterEvidenceVersion = 2
	boss.lastEncounterDecision = {
		confidence = decision.confidence,
		minimum = decision.minimum,
		score = decision.score,
		reasons = decision.reasonText,
		classification = decision.classification,
		endHpPct = decision.endHpPct,
		partialAttempt = decision.partialAttempt,
		incompleteHighHp = decision.incompleteHighHp,
		unconfirmedHighHp = decision.unconfirmedHighHp,
		bossUnitSignal = decision.bossUnitSignal,
		councilSignal = decision.councilSignal,
		otherBossFramePresent = decision.otherBossFramePresent,
		duration = decision.duration,
		eventCount = decision.eventCount,
		occurrenceCount = decision.occurrenceCount,
		abilityCount = decision.abilityCount,
		modelContextCount = decision.modelContextCount,
		pullWorldbossCount = decision.pullWorldbossCount,
	}

	for _, pullAbility in pairs(bossState.abilities or {}) do
		mergeAbilityState(boss, pullAbility)
		touchedKeys[pullAbility.key] = true
	end
	refreshSharedAbilitySuppression(zone, touchedKeys)

	return boss
end

local function finishBossState(pullState, bossState, zoneInfo, reason, context, pullDecisionStats)
	if not bossState or bossState.finished then
		return
	end

	bossState.finished = true
	bossState.endReason = bossState.endReason or context and context.endReason or reason or "unknown"
	bossState.endedAtSession = bossState.endedAtSession or context and context.endedAtSession or Util.now()
	bossState.duration = bossState.endedAtSession - (bossState.startedAtSession or bossState.endedAtSession)

	if bossState.eventCount <= 0 then
		return
	end
	if learningBlocked or not dependenciesReady() then
		return
	end

	local modelStats = decisionModelStats(bossState, pullDecisionStats)
	local decision = addon.Learning.EncounterClassifier.scoreContext(context, bossState, modelStats)
	local promotedBoss = nil
	if decision.isBoss then
		promotedBoss = promoteBossState(pullState, bossState, decision)
	end

	addon.Core.Logger.event({
		kind = "learner_finish_boss",
		pullId = pullState.pullId,
		actorKey = bossState.actorKey,
		bossKey = bossState.bossKey,
		bossName = bossState.bossName,
		reason = bossState.endReason,
		duration = bossState.duration,
		eventCount = bossState.eventCount,
		occurrenceCount = bossState.occurrenceCount,
		qualified = decision.isBoss,
		encounterConfidence = decision.confidence,
		encounterReasons = decision.reasonText,
	})
	addon.Core.Logger.bossContext({
			kind = "learner_boss_decision",
			pullId = pullState.pullId,
			actorKey = bossState.actorKey,
			bossKey = bossState.bossKey,
			bossName = bossState.bossName,
			qualified = decision.isBoss,
			encounterConfidence = decision.confidence,
			encounterMinimum = decision.minimum,
			encounterReasons = decision.reasonText,
			endHpPct = decision.endHpPct,
			partialAttempt = decision.partialAttempt,
			incompleteHighHp = decision.incompleteHighHp,
			unconfirmedHighHp = decision.unconfirmedHighHp,
			duration = decision.duration,
			eventCount = decision.eventCount,
			occurrenceCount = decision.occurrenceCount,
			abilityCount = decision.abilityCount,
			modelContextCount = decision.modelContextCount,
			pullWorldbossCount = decision.pullWorldbossCount,
			bossUnitSignal = decision.bossUnitSignal,
			councilSignal = decision.councilSignal,
			otherBossFramePresent = decision.otherBossFramePresent,
			persistentAbilityCount = promotedBoss and countKeys(promotedBoss.abilities) or 0,
		})

	addon.Core.SavedVariables.boundLearnedData()
end

function AbilityLearner.observe(record, pull)
	if not addon.db or not record or not pull or not record.spellKey then
		return
	end
	if learningBlocked or not dependenciesReady() then
		return
	end

	local pullState = ensureCurrentPull(pull)
	local bossState = ensureBossState(pullState, record, pull)
	if not bossState then
		return
	end

	local occurrenceCandidate = addon.Learning.Relevance.isPrimaryOccurrence(record.eventType)
	local pullAbility = noteBossAbility(bossState, record, occurrenceCandidate)
	local acceptedOccurrence = false

	bossState.eventCount = bossState.eventCount + 1

	if occurrenceCandidate then
		if shouldAcceptOccurrence(pullAbility, record) then
			acceptedOccurrence = true
			noteOccurrence(bossState, pullAbility, record)
		end
	end

	addon.Core.Logger.event({
		kind = "learner_observe",
		pullId = pull.id,
		actorKey = bossState.actorKey,
		bossKey = bossState.bossKey,
		bossName = bossState.bossName,
		spellKey = record.spellKey,
		spellId = record.spellId,
		spellName = record.spellName,
		eventType = record.eventType,
		accepted = acceptedOccurrence,
		associatedWithBoss = record.associatedWithBoss,
		associatedSourceName = record.associatedSourceName,
		currentOccurrences = pullAbility.occurrences,
		currentMinInterval = pullAbility.minInterval,
		currentFirstOffset = pullAbility.firstOffset,
		hp = record.hpPct,
	})
end

function AbilityLearner.finishBossContext(pull, context, reason)
	if not currentPullState or not pull or currentPullState.pullId ~= pull.id or not context then
		return
	end
	if learningBlocked or not dependenciesReady() then
		return
	end

	local bossState = currentPullState.bosses[context.actorKey]
	if not bossState then
		return
	end
	bossState.endedAtSession = context.endedAtSession or Util.now()
	bossState.endReason = reason or bossState.endReason
end

function AbilityLearner.finishPull(pull, reason)
	if not currentPullState or currentPullState.pullId ~= pull.id then
		return
	end
	if learningBlocked or not dependenciesReady() then
		currentPullState = nil
		return
	end

	local bossCount = 0
	local pullDecisionStats = buildPullDecisionStats(currentPullState, pull)
	for _, bossState in pairs(currentPullState.bosses) do
		local context = pull.bossContexts and pull.bossContexts[bossState.actorKey] or nil
		finishBossState(currentPullState, bossState, pull.zone, reason, context, pullDecisionStats)
		bossCount = bossCount + 1
	end
	addon.Core.Logger.event({
		kind = "learner_finish_pull",
		pullId = pull.id,
		reason = reason,
		bossCount = bossCount,
	})
	addon.Core.SavedVariables.boundLearnedData()
	currentPullState = nil
end

function AbilityLearner.getCurrentPullState()
	return currentPullState
end

function AbilityLearner.getBossModel(zoneKey, bossKey)
	if not addon.db or not addon.db.learned or not zoneKey or not bossKey then
		return nil
	end
	local zone = addon.db.learned.zones[zoneKey]
	if not zone then
		return nil
	end
	local boss = zone.bosses and zone.bosses[bossKey] or nil
	if boss and boss.suppressed then
		return nil
	end
	if boss and boss.encounterConfidence and addon.db.config and boss.encounterConfidence < (addon.db.config.minEncounterConfidence or C.BOSS_CONTEXT_MIN_CONFIDENCE) then
		return nil
	end
	return boss
end

function AbilityLearner.start()
	currentPullState = nil
	runStats = nil
	learningBlocked = false
	dependencyWarningShown = false
	dependenciesReady()
	canonicalizeLearnedAbilityModels()
	repairLearnedAbilityModelsFromDebugRuns()
	refreshLearnedAbilityClassifications()
end
