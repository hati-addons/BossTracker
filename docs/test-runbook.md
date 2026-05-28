# Alpha Test Runbook

BossTracker stores alpha diagnostics in `BossTrackerDB` because the addon cannot write files directly. After a dungeon or raid test, use `/reload` or log out normally so the WoW client writes SavedVariables to disk.

## Before a Test

1. Enable the addon on the character selection screen.
2. Log in and run `/bt status`.
3. If the timer frame is in the way, drag the visible frame to move it.
4. Resize the visible timer frame from its lower-right corner. Slash commands are fallback controls only.
5. Run `/bt preview` to show sample timer bars when no boss is active.
6. If BossTracker warns that a full client restart is required, restart the WoW client before testing. `/reload` is not enough after newly added addon files.

## During a Test

- The timer UI may be wrong while the addon is still learning.
- Long trash combat is acceptable. The addon records separate boss contexts inside one combat window, so a boss added later should still learn from its own first activity.
- Multiple bosses in combat at the same time should appear as separate active contexts in `/bt status`.
- If the client shows boss health frames, BossTracker should use them automatically for boss identity and HP samples, including frames that appear later in the encounter.
- Boss tracking should not require targeting the boss. `target` and `focus` are only fallbacks when boss frames are missing.
- Trash and adds are still recorded for diagnostics, but boss-frame actors are preferred for durable timer models and nearby non-boss actors should be filtered out automatically.
- If the group wipes or leaves combat while a qualified boss is still above low HP, observed ability timings may still update learned timer models. HP is logged as evidence, not used as a display gate.
- After a wipe, the next pull may already show low-confidence timers for abilities that had at least one usable time estimate.
- During a long first pull, a repeated boss ability may appear as a provisional timer as soon as the addon has measured a usable interval in that same fight.
- Targeting a learned boss during unrelated trash combat should not open timers until that boss is actually engaged through combat-log activity, boss frames, or a matching unit that is affecting combat.
- Cast-time abilities should use the observed recast interval, not the cast duration. If a spell visibly appears once but has separate cast, damage, or aura ids, the timer list should show one ability bar.
- Channeled abilities should use activation-to-activation timing, not channel duration or tick spacing. A Whirlwind-style ability with a self aura and repeated damage ticks should count as one occurrence per activation.
- Repeated add-summon casts may be learned under the active boss when there is exactly one boss-frame owner. The debug log records `encounter_spell_associated`, and the timer may show the add source, for example `Lupine Horror: Summon Lupine Delusions`.
- Council and companion bosses may be learned only after the whole pull ends, because the addon needs the complete pull context to distinguish them from adds.
- If the timer UI blocks play or behaves badly, run `/bt panic`. Capture and debug recording continue.
- If you want to restore the timer UI, run `/bt resume`.
- Do not use `/bt clearlogs` until the saved test data has been inspected.

## After a Test

Run `/reload` or log out normally. This is required because WoW writes SavedVariables only during reload/logout/clean exit.

Useful commands:

- `/bt status`: show current addon state and active pull summary.
- `/bt help`: show slash command help.
- `/bt unlock`: show the timer frame for fallback positioning when no timer is active.
- `/bt preview`: toggle sample timer bars.
- `/bt scale 1.0`: fallback timer frame scale command.
- `/bt bigger` and `/bt smaller`: fallback timer frame scale commands.
- `/bt debug on`: enable SavedVariables diagnostics.
- `/bt debug off`: disable SavedVariables diagnostics.
- `/bt timers off`: hide timer predictions while keeping capture active.
- `/bt panic`: hide the timer UI while keeping capture active.
- `/bt resume`: restore timer UI after panic.
- `/bt resetui`: reset timer frame position.
- `/bt clearlearned`: clear learned boss models after captured data has been inspected.
