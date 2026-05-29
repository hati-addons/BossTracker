-- SavedVariables.lua
-- Initializes persistent configuration, learned encounter models, and bounded
-- diagnostics. Alpha learned data is intentionally reset on schema changes.

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

local COMBAT_LOG_SUBEVENT_NAMES = {
	SPELL_CAST_START = true,
	SPELL_CAST_SUCCESS = true,
	SPELL_AURA_APPLIED = true,
	SPELL_AURA_REFRESH = true,
	SPELL_AURA_REMOVED = true,
	SPELL_DAMAGE = true,
	SPELL_MISSED = true,
	SPELL_HEAL = true,
	SPELL_INTERRUPT = true,
	SPELL_SUMMON = true,
	SPELL_PERIODIC_DAMAGE = true,
	SPELL_PERIODIC_MISSED = true,
	SPELL_PERIODIC_HEAL = true,
	SPELL_PERIODIC_AURA_APPLIED = true,
	SPELL_PERIODIC_AURA_REMOVED = true,
	RANGE_DAMAGE = true,
	RANGE_MISSED = true,
	SWING_DAMAGE = true,
	SWING_MISSED = true,
	UNIT_DIED = true,
}

local function clearAbilityOverride(db, zoneKey, encounterKey, abilityKey)
	local overrides = db
		and db.config
		and db.config.overrides
		and db.config.overrides.zones
		and db.config.overrides.zones[zoneKey]
	local encounter = overrides and overrides.encounters and overrides.encounters[encounterKey] or nil
	if encounter and encounter.abilities then
		encounter.abilities[abilityKey] = nil
	end
end

local function removeEmptyOverrideContainers(db)
	local zones = db
		and db.config
		and db.config.overrides
		and db.config.overrides.zones
	if type(zones) ~= "table" then
		return
	end

	for zoneKey, zone in pairs(zones) do
		for encounterKey, encounter in pairs(zone.encounters or {}) do
			local hasAbilityOverride = false
			for _ in pairs(encounter.abilities or {}) do
				hasAbilityOverride = true
				break
			end
			if not hasAbilityOverride then
				zone.encounters[encounterKey] = nil
			end
		end
		local hasEncounterOverride = false
		for _ in pairs(zone.encounters or {}) do
			hasEncounterOverride = true
			break
		end
		if not hasEncounterOverride then
			zones[zoneKey] = nil
		end
	end
end

local function abilityLooksLikeCombatLogSubevent(ability)
	if type(ability) ~= "table" then
		return false
	end
	local spellName = ability.spellName
	if type(spellName) ~= "string" or not COMBAT_LOG_SUBEVENT_NAMES[spellName] then
		return false
	end
	local spellKey = "name:" .. string.lower(string.gsub(spellName, "[^%w]+", "_"))
	return ability.spellKey == spellKey or ability.key == spellKey or type(ability.spellId) == "number"
end

local function cleanupCombatLogSubeventAbilities(db)
	local learned = db and db.learned
	local removedAbilities = 0
	local removedEncounters = 0
	if type(learned) ~= "table" or type(learned.zones) ~= "table" then
		return 0, 0
	end

	for zoneKey, zone in pairs(learned.zones) do
		for encounterKey, encounter in pairs(zone.encounters or {}) do
			for abilityKey, ability in pairs(encounter.abilities or {}) do
				if abilityLooksLikeCombatLogSubevent(ability) then
					encounter.abilities[abilityKey] = nil
					clearAbilityOverride(db, zoneKey, encounterKey, abilityKey)
					removedAbilities = removedAbilities + 1
				end
			end
			encounter.abilityCount = countKeys(encounter.abilities)
			if encounter.abilityCount == 0 then
				zone.encounters[encounterKey] = nil
				removedEncounters = removedEncounters + 1
			end
		end
	end

	if removedAbilities > 0 then
		removeEmptyOverrideContainers(db)
	end
	return removedAbilities, removedEncounters
end

local function boundLearnedData(learned)
	if type(learned.zones) ~= "table" then
		learned.zones = {}
	end

	while countKeys(learned.zones) > C.MAX_LEARNED_ZONES do
		removeOneKey(learned.zones)
	end

	for _, zone in pairs(learned.zones) do
		if type(zone.encounters) ~= "table" then
			zone.encounters = {}
		end
		while countKeys(zone.encounters) > C.MAX_LEARNED_ENCOUNTERS_PER_ZONE do
			removeOneKey(zone.encounters)
		end
		for _, encounter in pairs(zone.encounters) do
			if type(encounter.actors) ~= "table" then
				encounter.actors = {}
			end
			if type(encounter.abilities) ~= "table" then
				encounter.abilities = {}
			end
			while countKeys(encounter.actors) > C.MAX_LEARNED_ACTORS_PER_ENCOUNTER do
				removeOneKey(encounter.actors)
			end
			while countKeys(encounter.abilities) > C.MAX_LEARNED_ABILITIES_PER_BOSS do
				removeOneKey(encounter.abilities)
			end
		end
	end
end

local function resetLearnedDataForSchema(db, previousSchemaVersion)
	db.learned = {
		zones = {},
	}
	appendMigration(db, {
		from = previousSchemaVersion,
		to = C.SCHEMA_VERSION,
		at = type(time) == "function" and time() or nil,
		reason = "Reset alpha learned data for phase-aware encounter model schema.",
	})
end

function SavedVariables.init()
	_G.BossTrackerDB = type(_G.BossTrackerDB) == "table" and _G.BossTrackerDB or {}
	_G.BossTrackerCharDB = type(_G.BossTrackerCharDB) == "table" and _G.BossTrackerCharDB or {}

	local db = _G.BossTrackerDB
	local previousSchemaVersion = tonumber(db.schemaVersion) or 0

	if previousSchemaVersion ~= C.SCHEMA_VERSION then
		resetLearnedDataForSchema(db, previousSchemaVersion)
	end

	db.schemaVersion = C.SCHEMA_VERSION
	db.version = C.VERSION
	db.config = type(db.config) == "table" and db.config or {}
	copyDefaults(db.config, C.DEFAULT_CONFIG)
	db.learned = type(db.learned) == "table" and db.learned or { zones = {} }
	db.learned.zones = type(db.learned.zones) == "table" and db.learned.zones or {}
	local removedAbilities, removedEncounters = cleanupCombatLogSubeventAbilities(db)
	if removedAbilities > 0 then
		appendMigration(db, {
			from = C.SCHEMA_VERSION,
			to = C.SCHEMA_VERSION,
			at = type(time) == "function" and time() or nil,
			reason = "Removed learned abilities created from combat-log subevent names after parser regression.",
			removedAbilities = removedAbilities,
			removedEncounters = removedEncounters,
		})
	end

	db.debug = type(db.debug) == "table" and db.debug or {}
	db.debug.runs = trimArray(db.debug.runs, C.MAX_DEBUG_RUNS)
	db.debug.errors = RingBuffer.ensure(db.debug.errors, C.MAX_DEBUG_ERRORS)
	db.debug.logs = RingBuffer.ensure(db.debug.logs, C.MAX_DEBUG_LOGS)
	db.debug.nextRunId = db.debug.nextRunId or 1

	local charDB = _G.BossTrackerCharDB
	charDB.config = type(charDB.config) == "table" and charDB.config or {}
	copyDefaults(charDB.config, C.DEFAULT_CHAR_CONFIG)

	boundLearnedData(db.learned)

	addon.db = db
	addon.charDB = charDB
	return db, charDB
end

function SavedVariables.clearLearnedData(reason)
	if not addon.db then
		return
	end
	addon.db.learned = { zones = {} }
	if addon.db.config and addon.db.config.overrides then
		addon.db.config.overrides = { zones = {} }
	end
	if addon.Learning and addon.Learning.RelevanceScorer and addon.Learning.RelevanceScorer.markRoutineIndexDirty then
		addon.Learning.RelevanceScorer.markRoutineIndexDirty()
	end
	appendMigration(addon.db, {
		from = C.SCHEMA_VERSION,
		to = C.SCHEMA_VERSION,
		at = type(time) == "function" and time() or nil,
		reason = reason or "Manual learned data reset.",
	})
	if addon.Runtime and addon.Runtime.PredictionEngine and addon.Runtime.PredictionEngine.reset then
		addon.Runtime.PredictionEngine.reset()
	end
	if addon.UI and addon.UI.TimerFrame and addon.UI.TimerFrame.refresh then
		addon.UI.TimerFrame.refresh()
	end
end

function SavedVariables.boundLearnedData()
	if addon.db and addon.db.learned then
		boundLearnedData(addon.db.learned)
	end
end
