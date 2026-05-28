-- SavedVariables.lua
-- Initializes and bounds all persistent state. The debug store is deliberately
-- generous for alpha testing, but every collection has a hard cap.

local addon = _G.BossTracker
local C = addon.Core.Constants
local RingBuffer = addon.Core.RingBuffer

local SavedVariables = {}
addon.Core.SavedVariables = SavedVariables

local function copyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			copyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

local function trimArray(array, maxEntries)
	if type(array) ~= "table" then
		return {}
	end
	while #array > maxEntries do
		table.remove(array, 1)
	end
	return array
end

local function appendMigration(db, migration)
	db.migrations = trimArray(type(db.migrations) == "table" and db.migrations or {}, 20)
	db.migrations[#db.migrations + 1] = migration
	trimArray(db.migrations, 20)
end

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

local function clampScore(score)
	if score < 0 then
		return 0
	end
	if score > 1 then
		return 1
	end
	return score
end

local function legacyAbilityEvidence(boss)
	local abilityCount = 0
	local hpSamples = 0
	if type(boss) ~= "table" or type(boss.abilities) ~= "table" then
		return abilityCount, hpSamples
	end
	for _, ability in pairs(boss.abilities) do
		abilityCount = abilityCount + 1
		hpSamples = hpSamples + (tonumber(ability.hpSamples) or 0)
	end
	return abilityCount, hpSamples
end

local function legacyBossConfidence(boss)
	if type(boss) ~= "table" then
		return 0
	end

	local abilityCount, hpSamples = legacyAbilityEvidence(boss)
	local pullCount = tonumber(boss.pullCount) or 0
	local duration = tonumber(boss.lastDuration) or 0
	local killed = boss.lastEndReason == "unit_died"
	local score = 0

	if killed then
		score = score + 0.20
	else
		score = score - 0.20
	end
	if pullCount > 0 and pullCount <= 2 then
		score = score + 0.15
	elseif pullCount >= 4 then
		score = score - 0.35
	end
	if duration >= 60 then
		score = score + 0.35
	elseif duration >= 45 then
		score = score + 0.25
	elseif duration >= 30 then
		score = score + 0.15
	end
	if abilityCount >= 5 then
		score = score + 0.20
	elseif abilityCount >= 3 then
		score = score + 0.12
	elseif abilityCount >= 1 then
		score = score + 0.05
	end
	if hpSamples > 0 then
		score = score + 0.15
	end

	return clampScore(score)
end

local function migrateLegacyBossQualification(db, previousSchemaVersion)
	local learned = db.learned
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return
	end

	local kept = 0
	local removed = 0
	local minimum = C.BOSS_CONTEXT_MIN_CONFIDENCE or 0.55

	for zoneKey, zone in pairs(learned.zones) do
		if type(zone) == "table" and type(zone.bosses) == "table" then
			for bossKey, boss in pairs(zone.bosses) do
				local confidence = legacyBossConfidence(boss)
				if confidence >= minimum then
					boss.encounterConfidence = confidence
					boss.encounterEvidenceVersion = 1
					boss.legacyQualified = true
					kept = kept + 1
				else
					zone.bosses[bossKey] = nil
					removed = removed + 1
				end
			end
			if next(zone.bosses) == nil then
				learned.zones[zoneKey] = nil
			end
		end
	end

	appendMigration(db, {
		from = previousSchemaVersion,
		to = 3,
		at = type(time) == "function" and time() or nil,
		reason = "Kept only likely boss models after adding encounter qualification.",
		kept = kept,
		removed = removed,
	})
end

local function stringContains(value, needle)
	return type(value) == "string" and string.find(value, needle, 1, true) ~= nil
end

local function isSevenRelKey(bossKey)
	return type(bossKey) == "string" and string.sub(bossKey, -4) == "_rel"
end

local function migratePullWideEncounterQualification(db, previousSchemaVersion)
	local learned = db.learned
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return
	end

	local kept = 0
	local removed = 0
	for zoneKey, zone in pairs(learned.zones) do
		if type(zone) == "table" and type(zone.bosses) == "table" then
			for bossKey, boss in pairs(zone.bosses) do
				local decision = type(boss) == "table" and boss.lastEncounterDecision or nil
				local reasons = type(decision) == "table" and tostring(decision.reasons or "") or ""
				local modelContextCount = type(decision) == "table" and (tonumber(decision.modelContextCount) or 1) or 1
				local hasWorldbossClassification = stringContains(reasons, "worldboss_classification")
				local keep = true

				if type(decision) == "table"
					and not hasWorldbossClassification
					and not isSevenRelKey(bossKey)
					and modelContextCount > 1 then
					keep = false
				end

				if keep then
					kept = kept + 1
				else
					zone.bosses[bossKey] = nil
					removed = removed + 1
				end
			end
			if next(zone.bosses) == nil then
				learned.zones[zoneKey] = nil
			end
		end
	end

	appendMigration(db, {
		from = previousSchemaVersion,
		to = 4,
		at = type(time) == "function" and time() or nil,
		reason = "Removed alpha models that were promoted before pull-wide encounter qualification.",
		kept = kept,
		removed = removed,
	})
end

local function hasStrongBossFrameDecision(bossKey, decision)
	local reasons = type(decision) == "table" and tostring(decision.reasons or "") or ""
	return isSevenRelKey(bossKey)
		or stringContains(reasons, "worldboss_classification")
		or stringContains(reasons, "boss_unit_frame")
		or (type(decision) == "table" and decision.bossUnitSignal == true)
end

local function migrateBossFrameCohortQualification(db, previousSchemaVersion)
	local learned = db.learned
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return
	end

	local kept = 0
	local removed = 0
	for zoneKey, zone in pairs(learned.zones) do
		if type(zone) == "table" and type(zone.bosses) == "table" then
			for bossKey, boss in pairs(zone.bosses) do
				local decision = type(boss) == "table" and boss.lastEncounterDecision or nil
				local evidenceVersion = type(boss) == "table" and tonumber(boss.encounterEvidenceVersion) or nil
				local keep = true

				if evidenceVersion == 2
					and type(decision) == "table"
					and not hasStrongBossFrameDecision(bossKey, decision) then
					local reasons = tostring(decision.reasons or "")
					local modelContextCount = tonumber(decision.modelContextCount) or 1
					local confidence = tonumber(boss.encounterConfidence)
						or tonumber(decision.confidence)
						or 0

					if stringContains(reasons, "worldboss_encounter_cohort")
						or modelContextCount > 1
						or confidence < (C.FALLBACK_BOSS_CONTEXT_MIN_CONFIDENCE or 0.85) then
						keep = false
					end
				end

				if keep then
					kept = kept + 1
				else
					zone.bosses[bossKey] = nil
					removed = removed + 1
				end
			end
			if next(zone.bosses) == nil then
				learned.zones[zoneKey] = nil
			end
		end
	end

	appendMigration(db, {
		from = previousSchemaVersion,
		to = 5,
		at = type(time) == "function" and time() or nil,
		reason = "Removed boss-frame cohort false positives from alpha learned data.",
		kept = kept,
		removed = removed,
	})
end

local function isKnownRoutineAbilityName(spellName)
	local name = string.lower(tostring(spellName or ""))
	return name == "fierce blow" or name == "auto shot"
end

local function shouldAutoSuppressAbility(ability, sharedBossCount)
	if type(ability) ~= "table" then
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

local function refreshRoutineAbilitySuppression(learned)
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return
	end

	for _, zone in pairs(learned.zones) do
		local abilitiesByKey = {}
		if type(zone) == "table" and type(zone.bosses) == "table" then
			for _, boss in pairs(zone.bosses) do
				if type(boss) == "table" and not boss.suppressed and type(boss.abilities) == "table" then
					for spellKey, ability in pairs(boss.abilities) do
						local entry = abilitiesByKey[spellKey]
						if not entry then
							entry = { count = 0, abilities = {} }
							abilitiesByKey[spellKey] = entry
						end
						entry.count = entry.count + 1
						entry.abilities[#entry.abilities + 1] = ability
					end
				end
			end

			for _, entry in pairs(abilitiesByKey) do
				for index = 1, #entry.abilities do
					local ability = entry.abilities[index]
						ability.sharedBossCount = entry.count
						if shouldAutoSuppressAbility(ability, entry.count) then
							ability.autoSuppressed = true
							ability.suppressionReason = isKnownRoutineAbilityName(ability.spellName) and "routine_ability" or "routine_shared_ability"
						elseif ability.autoSuppressed and (ability.suppressionReason == "routine_shared_ability" or ability.suppressionReason == "routine_ability") then
							ability.autoSuppressed = nil
							ability.suppressionReason = nil
						end
				end
			end
		end
	end
end

local function removeOneKey(tbl)
	local removeKey
	local oldestSeenAt
	for key, value in pairs(tbl) do
		local seenAt = type(value) == "table" and (value.lastSeenAt or value.updatedAt or value.createdAt) or nil
		if not removeKey or not seenAt or not oldestSeenAt or seenAt < oldestSeenAt then
			removeKey = key
			oldestSeenAt = seenAt
		end
	end
	if removeKey then
		tbl[removeKey] = nil
	end
end

local function boundLearnedData(learned)
	if type(learned.zones) ~= "table" then
		learned.zones = {}
	end
	while countKeys(learned.zones) > C.MAX_LEARNED_ZONES do
		removeOneKey(learned.zones)
	end
	for _, zone in pairs(learned.zones) do
		if type(zone.bosses) ~= "table" then
			zone.bosses = {}
		end
		while countKeys(zone.bosses) > C.MAX_LEARNED_BOSSES_PER_ZONE do
			removeOneKey(zone.bosses)
		end
		for _, boss in pairs(zone.bosses) do
			if type(boss.abilities) ~= "table" then
				boss.abilities = {}
			end
			while countKeys(boss.abilities) > C.MAX_LEARNED_ABILITIES_PER_BOSS do
				removeOneKey(boss.abilities)
			end
		end
	end
end

function SavedVariables.init()
	_G.BossTrackerDB = type(_G.BossTrackerDB) == "table" and _G.BossTrackerDB or {}
	_G.BossTrackerCharDB = type(_G.BossTrackerCharDB) == "table" and _G.BossTrackerCharDB or {}

	local db = _G.BossTrackerDB
	local previousSchemaVersion = tonumber(db.schemaVersion) or 0

	local hasExistingLearnedData = type(db.learned) == "table" and type(db.learned.zones) == "table" and next(db.learned.zones) ~= nil
	if previousSchemaVersion < 2 and hasExistingLearnedData then
		db.learned = { zones = {} }
		appendMigration(db, {
			from = previousSchemaVersion,
			to = 2,
			at = type(time) == "function" and time() or nil,
			reason = "Reset alpha learned data after adding multi-boss combat contexts.",
		})
	end
	if previousSchemaVersion < 3 and type(db.learned) == "table" and type(db.learned.zones) == "table" and next(db.learned.zones) ~= nil then
		migrateLegacyBossQualification(db, previousSchemaVersion)
	end
	if previousSchemaVersion < 4 and type(db.learned) == "table" and type(db.learned.zones) == "table" and next(db.learned.zones) ~= nil then
		migratePullWideEncounterQualification(db, previousSchemaVersion)
	end
	if previousSchemaVersion < 5 and type(db.learned) == "table" and type(db.learned.zones) == "table" and next(db.learned.zones) ~= nil then
		migrateBossFrameCohortQualification(db, previousSchemaVersion)
	end

	db.schemaVersion = C.SCHEMA_VERSION
	db.version = C.VERSION
	db.config = type(db.config) == "table" and db.config or {}
	copyDefaults(db.config, C.DEFAULT_CONFIG)
	db.learned = type(db.learned) == "table" and db.learned or {}
	db.learned.zones = type(db.learned.zones) == "table" and db.learned.zones or {}

	db.debug = type(db.debug) == "table" and db.debug or {}
	db.debug.runs = trimArray(db.debug.runs, C.MAX_DEBUG_RUNS)
	db.debug.errors = RingBuffer.ensure(db.debug.errors, C.MAX_DEBUG_ERRORS)
	db.debug.logs = RingBuffer.ensure(db.debug.logs, C.MAX_DEBUG_LOGS)
	db.debug.nextRunId = db.debug.nextRunId or 1

	local charDB = _G.BossTrackerCharDB
	charDB.config = type(charDB.config) == "table" and charDB.config or {}
	copyDefaults(charDB.config, C.DEFAULT_CHAR_CONFIG)

	boundLearnedData(db.learned)
	refreshRoutineAbilitySuppression(db.learned)

	addon.db = db
	addon.charDB = charDB
	return db, charDB
end

function SavedVariables.clearLearnedData(reason)
	if not addon.db then
		return
	end
	addon.db.learned = { zones = {} }
	appendMigration(addon.db, {
		from = C.SCHEMA_VERSION,
		to = C.SCHEMA_VERSION,
		at = type(time) == "function" and time() or nil,
		reason = reason or "Manual learned data reset.",
	})
end

function SavedVariables.boundLearnedData()
	if addon.db and addon.db.learned then
		boundLearnedData(addon.db.learned)
	end
end
