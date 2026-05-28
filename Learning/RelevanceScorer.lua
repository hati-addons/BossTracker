-- RelevanceScorer.lua
-- Scores learned abilities for automatic suppression. It keeps player-facing
-- decisions simple by hiding routine filler unless later evidence makes the
-- ability clearly encounter-relevant.

local addon = _G.BossTracker

local RelevanceScorer = {}
addon.Learning.RelevanceScorer = RelevanceScorer

local function lowerName(spellName)
	return string.lower(tostring(spellName or ""))
end

local function knownRoutineReason(spellName)
	local name = lowerName(spellName)
	if name == "fierce blow" or name == "auto shot" then
		return "known_routine_ability"
	end
	return nil
end

function RelevanceScorer.applyRoutineCandidate(ability, candidate)
	if type(ability) ~= "table" or type(candidate) ~= "function" then
		return
	end

	local knownReason = knownRoutineReason(ability.spellName)
	if knownReason then
		candidate(ability, "routine_noise", 1.0, {
			reason = knownReason,
		})
		return
	end

	if ability.encounterAssociated then
		return
	end

	local sharedCount = tonumber(ability.sharedAbilityCount) or 0
	if sharedCount >= 4
		and ability.minInterval
		and ability.minInterval <= 8
		and ability.intervalSamples
		and ability.intervalSamples >= 1 then
		candidate(ability, "routine_noise", 0.88, {
			reason = "shared_short_interval",
			sharedAbilityCount = sharedCount,
		})
		return
	end

	if (ability.activationCount or 0) >= 8
		and ability.minInterval
		and ability.minInterval <= 5
		and (ability.hpSamples or 0) <= 1 then
		candidate(ability, "routine_noise", 0.66, {
			reason = "frequent_short_interval",
		})
	end
end

function RelevanceScorer.refreshZone(zone)
	if type(zone) ~= "table" or type(zone.encounters) ~= "table" then
		return
	end

	local spellCounts = {}
	for _, encounter in pairs(zone.encounters) do
		if type(encounter) == "table" and not encounter.suppressed and type(encounter.abilities) == "table" then
			local seenInEncounter = {}
			for _, ability in pairs(encounter.abilities) do
				if type(ability) == "table" and ability.spellKey and not seenInEncounter[ability.spellKey] then
					seenInEncounter[ability.spellKey] = true
					spellCounts[ability.spellKey] = (spellCounts[ability.spellKey] or 0) + 1
				end
			end
		end
	end

	for _, encounter in pairs(zone.encounters) do
		if type(encounter) == "table" and type(encounter.abilities) == "table" then
			for _, ability in pairs(encounter.abilities) do
				if type(ability) == "table" then
					ability.sharedAbilityCount = spellCounts[ability.spellKey] or 0
					if addon.Learning.RuleLearner then
						addon.Learning.RuleLearner.refreshRules(ability)
					end
				end
			end
		end
	end
end

function RelevanceScorer.start()
end
