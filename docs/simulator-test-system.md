# Encounter Simulator Test System

BossTracker's simulator is a quality gate, not a training source. It uses AzerothCore scripts as a broad pattern catalogue and generates client-visible encounter evidence against a fresh in-memory addon database on every run.

## Goals

- Exercise the real BossTracker capture, learning, relevance, model, and prediction modules.
- Cover many encounter shapes without specializing the addon to a handful of manual test logs.
- Keep failures deterministic through explicit scenario names and seeds.
- Verify invariants that should hold on Ascension even when exact spells and timings differ from AzerothCore.

## Architecture

1. C++ extractor:
   - Reads `boss_*.cpp` files.
   - Strips comments and extracts enum symbols, event case blocks, scheduler calls, HP checks, direct casts, summons, channels, and repeat intervals where possible.
   - Emits a neutral intermediate model instead of directly writing replay events.

2. Intermediate encounter model:
   - `bossName`: primary boss actor identity; summon actions can generate simulated add evidence associated with that owner during replay.
   - `actions`: visible spell/summon actions with spell name, event type, initial delay, repeat seconds, HP gate, source, and relevance hints.
   - `coverage`: parser evidence used by reports and assertions, including event, initial schedule, HP schedule, direct schedule, action, and fallback counters.

3. Client-visible simulator:
   - Generates combat-log shaped evidence through the production replay harness.
   - Simulates kill speed, partial attempts, missing or late boss-frame evidence, target-only fallback, add ownership, interrupt pressure, channel lifecycle events, and repeated casts.
   - Starts every scenario from a clean SavedVariables state.

4. Assertions:
   - A simulated script must emit at least one spell and promote at least one encounter.
   - No learned ability may use combat-log subevent names such as `SPELL_HEAL` as its spell name.
   - Sub-10-second simulated repeats should become routine noise, not displayed timers.
   - Repeated timed mechanics at or above the display floor should remain timer candidates.
   - HP-gated direct casts must not be promoted as normal time intervals from sparse evidence.
   - Interrupt pressure must not turn a spammable cast into a long false cooldown.
   - Known representative scripts keep focused expectations for important mechanics.

## Workflow

Fast focused run:

- `lua tests/cpp_module_replay.lua`

Run selected scripts:

- `lua tests/cpp_module_replay.lua /home/two/projects/azerothcore-wotlk/src/server/scripts/EasternKingdoms/Deadmines/boss_mr_smite.cpp`

Run all AzerothCore boss scripts:

- `lua tests/cpp_module_replay.lua --all --quiet`

Useful options:

- `--seed <number>`: deterministic timing variation seed.
- `--quiet`: suppress per-scenario success lines and print only the summary.
- `--limit <number>`: cap the number of input scripts for quick parser smoke tests.
- `--variant <name>`: run one simulator variant, repeat the option to select multiple variants.
- `--help`: print available options and variant names.

## Non-Goals

- The simulator does not execute C++.
- The simulator does not prove Ascension uses AzerothCore's exact mechanics.
- The simulator does not write learned data for production use.
- Manual dungeon and raid tests remain necessary for Ascension-specific behavior.
