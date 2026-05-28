# BossTracker

BossTracker is a planned boss ability timer addon for Project Ascension Bronzebeard on the WotLK 3.3.5a client (`Interface: 30300`).

The addon should eventually learn relevant boss abilities from real raid and dungeon play, predict the next likely casts, and display them in a clean chronological timer list. The target audience is raid players who want better timing information without being asked to understand the underlying technical model.

## Current Status

This repository contains an alpha implementation intended for real dungeon and raid test runs.

Implemented now:

- Bounded SavedVariables diagnostics in `BossTrackerDB`.
- Error isolation so repeated module failures disable only the failing module.
- A restart warning when the running client has not loaded newly added addon files.
- Combat-log capture for hostile NPC spell evidence.
- Boss-frame sampling through `boss1..MAX_BOSS_FRAMES` for stronger encounter identity and HP evidence, with combat-log, target, and focus fallbacks.
- Boss tracking does not require the player to target the boss; boss-frame evidence stays attached to the encounter context even if target changes.
- Coarse combat-window tracking with separate boss contexts inside a long fight.
- A conservative ability learner scoped per boss source, including late boss pulls and simultaneous bosses.
- Pull-wide boss-context qualification before durable learning, with boss-frame actors preferred and nearby trash kept as diagnostics rather than timer data.
- Add-spawn summon spells from non-boss actors can be associated with one active boss-frame owner as encounter mechanics, while keeping the original add source for display and diagnostics.
- Boss HP is evidence, not a hard learning gate. A qualified boss attempt can update timer estimates even after an early wipe or reset.
- Timer display starts from the first usable estimate; low-confidence provisional timers are allowed and refined by later pulls.
- During a long first pull, repeated casts from a qualified active boss can create provisional same-pull timer bars before the encounter ends.
- Cast lifecycle and channel events are deduplicated so cast duration, aura duration, and tick spacing are not learned as recast timing.
- Displayed boss mechanics are merged by visible spell name when Ascension emits separate technical spell ids for cast, effect, and aura events.
- Learned timers stay hidden for target-only boss contexts until that boss has current combat evidence.
- Automatic suppression for common routine abilities that behave like basic attacks across many bosses.
- A compact timer frame for learned time-based, one-time, and HP-linked candidates.
- Timer UI polling runs from an always-active ticker, so a hidden timer frame can open itself when predictions appear.
- The visible timer frame can be moved by dragging it and resized from the lower-right corner; slash commands are only fallback controls.
- A timer preview mode for positioning and checking the layout without an active boss.
- Slash commands for alpha testing and emergency UI hiding.

Not implemented yet:

- Full configuration UI.
- User-facing instance, boss, and ability hierarchy.
- Audio countdowns.
- Mature drift correction and player-facing relevance controls.

## Alpha Testing

The addon cannot write files directly. After a test run, use `/reload` or log out normally so the client writes `BossTrackerDB` and `BossTrackerCharDB` to disk.

Useful commands:

- `/bt` or `/bt help`: show available commands.
- `/bt status`: show current addon state.
- `/bt unlock`: show the timer frame for fallback positioning when no timer is active.
- `/bt preview`: toggle sample timer bars.
- `/bt scale 1.0`: fallback scale command. The visible frame can be resized directly from its lower-right corner.
- `/bt panic`: hide the timer UI while capture continues.
- `/bt resume`: restore the timer UI.
- `/bt timers off`: disable timer display while capture continues.
- `/bt debug on`: enable SavedVariables diagnostics.
- `/bt clearlogs`: clear stored debug runs after they are no longer needed.
- `/bt clearlearned`: clear learned boss models if alpha data becomes contaminated.

See `docs/test-runbook.md` for the test workflow.
