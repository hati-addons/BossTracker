-- cpp_module_replay.lua
-- CLI entry point for the AzerothCore-inspired BossTracker encounter
-- simulator. The simulator itself lives in tests/encounter_simulator.lua so
-- tests can reuse the extractor, model, variants, and assertions directly.

local Simulator = dofile("tests/encounter_simulator.lua")

Simulator.main(arg or {})
