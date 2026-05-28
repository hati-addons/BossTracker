-- replay_scenarios.lua
-- Headless replay tests for the BossTracker learning pipeline. The scenarios
-- are inspired by common AzerothCore encounter patterns: channeled lifecycles,
-- HP phase swaps, transition delays, councils, and encounter-owned add casts.

local Harness = dofile("tests/replay_harness.lua")
local addon = Harness.addon

local function scenarioChannelLifecycle()
	Harness.resetState("Replay Herod")
	local boss = "Herod"
	local guid = Harness.makeGuid(boss, 100)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 100 })
	Harness.emitSpell({ t = 0.1, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 100, eventType = "SPELL_AURA_APPLIED", selfTarget = true })
	Harness.emitSpell({ t = 3, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 96, eventType = "SPELL_DAMAGE" })
	Harness.emitSpell({ t = 6, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 92, eventType = "SPELL_DAMAGE" })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 90, eventType = "SPELL_AURA_REMOVED", selfTarget = true })
	Harness.emitSpell({ t = 24, sourceName = boss, sourceGUID = guid, spellName = "Whirlwind", spellId = 8989, hp = 80 })

	local pullState = addon.Learning.AbilityLearner.getCurrentPullState()
	local bossState = pullState.bosses[addon.Core.Util.actorKey(boss, guid)]
	local learned = bossState.abilities[addon.Core.Util.timerAbilityKey(nil, "Whirlwind")]
	Harness.assertTrue(learned.activationCount == 2, "Whirlwind channel should have two activations")
	Harness.assertNear(learned.minInterval, 24, 0.01, "Whirlwind interval should use activation-to-activation timing")

	local timer = Harness.firstPredictionByName("Whirlwind")
	Harness.assertTrue(timer ~= nil, "Whirlwind live timer should be visible after the second activation")
	Harness.assertNear(timer.remaining, 24, 0.2, "Whirlwind live timer should predict the next activation")
end

local function scenarioPhaseHpRules()
	Harness.resetState("Replay LBRS")
	local boss = "Warmaster Voone"
	local guid = Harness.makeGuid(boss, 200)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Throw Axe", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = boss, sourceGUID = guid, spellName = "Throw Axe", hp = 90 })
	Harness.emitSpell({ t = 16, sourceName = boss, sourceGUID = guid, spellName = "Throw Axe", hp = 74 })
	Harness.emitSpell({ t = 30, sourceName = boss, sourceGUID = guid, spellName = "Cleave", hp = 64 })
	Harness.emitSpell({ t = 42, sourceName = boss, sourceGUID = guid, spellName = "Mortal Strike", hp = 60 })
	Harness.emitSpell({ t = 62, sourceName = boss, sourceGUID = guid, spellName = "Snap Kick", hp = 39 })
	Harness.finishPull(80)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	Harness.assertTrue(model ~= nil, "Voone encounter should be learned")
	local cleave = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Cleave")
	Harness.assertTrue(cleave ~= nil, "Cleave should be learned")
	Harness.assertTrue(cleave.segmentStats.hp_65 ~= nil, "Cleave should be tied to the 65% phase segment")
	Harness.assertTrue(cleave.selectedRule and (cleave.selectedRule.type == "hp_gate" or cleave.selectedRule.type == "phase_start_offset"), "Cleave should classify as HP or phase-start driven")
end

local function scenarioRepeatedTransitionSpell()
	Harness.resetState("Replay Deadmines")
	local boss = "Mr. Smite"
	local guid = Harness.makeGuid(boss, 300)
	Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Smite Slam", hp = 100 })
	Harness.emitSpell({ t = 10, sourceName = boss, sourceGUID = guid, spellName = "Smite Stomp", hp = 64 })
	Harness.emitSpell({ t = 40, sourceName = boss, sourceGUID = guid, spellName = "Smite Stomp", hp = 34 })
	Harness.emitSpell({ t = 50, sourceName = boss, sourceGUID = guid, spellName = "Smite Slam", hp = 32 })
	Harness.emitSpell({ t = 56, sourceName = boss, sourceGUID = guid, spellName = "Smite Slam", hp = 25 })
	Harness.finishPull(70)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local stomp = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Smite Stomp")
	Harness.assertTrue(stomp ~= nil, "Smite Stomp should be learned")
	Harness.assertTrue(stomp.segmentStats.hp_65 ~= nil and stomp.segmentStats.hp_35 ~= nil, "Smite Stomp should be represented as repeated phase transitions")
	Harness.assertTrue(stomp.selectedRule and stomp.selectedRule.type ~= "time_interval", "Repeated HP transition spell must not become a normal cooldown")
end

local function scenarioCouncilGrouping()
	Harness.resetState("Replay Council")
	local left = "Skarvald"
	local right = "Dalronn"
	local leftGuid = Harness.makeGuid(left, 401)
	local rightGuid = Harness.makeGuid(right, 402)
	Harness.emitSpell({ t = 0, sourceName = left, sourceGUID = leftGuid, spellName = "Charge", hp = 100 })
	Harness.emitSpell({ t = 1, sourceName = right, sourceGUID = rightGuid, spellName = "Shadow Bolt", hp = 100 })
	Harness.emitSpell({ t = 8, sourceName = left, sourceGUID = leftGuid, spellName = "Charge", hp = 80 })
	Harness.emitSpell({ t = 16, sourceName = right, sourceGUID = rightGuid, spellName = "Shadow Bolt", hp = 82 })
	Harness.finishPull(30)

	local keys = { addon.Core.Util.bossKey(left, leftGuid), addon.Core.Util.bossKey(right, rightGuid) }
	table.sort(keys)
	local model = Harness.encounter("group:" .. table.concat(keys, "+"))
	Harness.assertTrue(model ~= nil, "Council bosses should be grouped into one encounter")
	Harness.assertTrue(model.actorCount == 2, "Council encounter should contain both actors")
end

local function scenarioEncounterOwnedAdd()
	Harness.resetState("Replay Summons")
	local boss = "Wolf Master"
	local guid = Harness.makeGuid(boss, 500)
	local pull, context = Harness.emitSpell({ t = 0, sourceName = boss, sourceGUID = guid, spellName = "Savage Bite", hp = 100 })
	Harness.emitAssociatedSpell({ t = 12, pull = pull, ownerContext = context, sourceName = "Lupine Horror", sourceId = 501, spellName = "Summon Delusion", hp = 92 })
	Harness.emitAssociatedSpell({ t = 36, pull = pull, ownerContext = context, sourceName = "Lupine Horror", sourceId = 501, spellName = "Summon Delusion", hp = 70 })
	Harness.finishPull(55)

	local model = Harness.encounter(addon.Core.Util.bossKey(boss, guid))
	local summon = Harness.ability(model, addon.Core.Util.bossKey(boss, guid), "Summon Delusion")
	Harness.assertTrue(summon ~= nil, "Encounter-owned add summon should be learned under the boss")
	Harness.assertTrue(summon.encounterAssociated == true, "Add summon should preserve encounter association")
	Harness.assertTrue(summon.associatedSourceName == "Lupine Horror", "Original add source should be retained")
end

local scenarios = {
	scenarioChannelLifecycle,
	scenarioPhaseHpRules,
	scenarioRepeatedTransitionSpell,
	scenarioCouncilGrouping,
	scenarioEncounterOwnedAdd,
}

for index = 1, #scenarios do
	scenarios[index]()
end

print("replay scenarios passed: " .. tostring(#scenarios))
