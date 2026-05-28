# BossTracker Design Notes

These notes capture the product direction, constraints, and active architecture decisions.

## Product Goal

BossTracker should help raid and dungeon players see which relevant boss ability is expected next. The main display should be a compact chronological list of timer bars with remaining time. It should stay visually calm, readable in combat, and avoid configuration clutter during play.

## Core Constraints

- The addon is for Project Ascension Bronzebeard and must assume encounter behavior can differ from public AzerothCore scripts.
- AzerothCore can be used only as background material for understanding common boss scripting patterns.
- The addon must learn from observed gameplay and keep validating old learned data after patches.
- The user should not have to classify spells, tune algorithms, or understand technical state.
- Routine noise such as auto attacks must be filtered out automatically.
- Learned predictions should prefer conservative early warnings. For time-window mechanics, the shortest observed reliable interval is the display baseline.

## Future Architecture Topics

1. Evidence capture: which combat-log events and unit state changes are reliable enough on this client.
2. Encounter identity: how to identify instance, boss, pull, phase, and reset boundaries without server support.
3. Relevance scoring: how to distinguish meaningful mechanics from incidental casts, melee swings, auras, procs, and trash.
4. Timer models: time-based intervals, health-threshold triggers, one-time casts, phase transitions, cooldown resets, and random windows.
5. Drift correction: how much mismatch is needed before the addon downgrades confidence or replaces old learned data.
6. Persistence: how to version learned data so corrupt or stale models can be repaired without user action.
7. Timer UI: compact bars, visual priority, sorting, locking, scaling, and in-combat readability.
8. Configuration UI: searchable hierarchy by instance, boss, and ability with hide and highlight controls.
9. Audio: countdown support once suitable sound assets or built-in alternatives are chosen.

## Current Learning Boundary

The addon records hostile NPC spell evidence broadly because manual dungeon tests are expensive and failures need enough SavedVariables data for diagnosis. Durable timer learning is narrower:

- Player combat is only a coarse capture window.
- Every hostile source gets its own context inside that window.
- Boss unit frames (`boss1..MAX_BOSS_FRAMES`) are the strongest available client-side signal for boss identity and HP, including bosses that spawn after the pull starts.
- Combat-log, target, and focus evidence remain required fallbacks because custom Ascension encounters may expose incomplete boss-frame state. Target and focus are never required for boss tracking; healers and support players often target friendly units during encounters.
- Contexts are scored for durable learning at pull end, after the addon can see the full boss group and repeated trash models.
- Only qualified boss-like contexts are promoted into persistent timer models.
- Repeated model names inside one run are strong evidence for trash or adds unless boss-frame or worldboss classification proves a boss.
- If a pull has boss-frame evidence, nearby non-boss actors are treated conservatively so adds and long trash chains do not become timer models.
- Summon spells from non-boss actors may be associated with a single active boss-frame owner as encounter mechanics. The boss owns the encounter timer, but the original source is retained so add-driven mechanics are not treated as direct boss casts. Ambiguous multi-boss ownership is skipped until the model can resolve it safely.
- Fallback learning without boss frames remains possible, but it uses a higher confidence requirement than direct boss-frame learning.
- Boss HP is evidence, not a hard learning gate. A qualified boss context can update timer models even when the group wipes or resets early; low HP only improves completion evidence when the client misses `UNIT_DIED`.
- A timer may be shown from the first usable estimate. Single-sample predictions are intentionally low-confidence and should be refined, hidden, or suppressed automatically as more pulls are observed.
- Repeated casts inside the current pull can produce live provisional `time` timers before the boss model is persisted at pull end. These timers are display-only estimates and should remain gated by boss-context qualification.
- Timer ability identity is based on the visible spell name when available, while still storing spell ids for diagnostics and icons. Ascension can emit separate technical ids for one displayed mechanic's cast, damage, and aura events.
- Cast lifecycle events are deduplicated. A cast-start or cast-success followed shortly by success, damage, aura, heal, summon, or miss evidence counts as one occurrence, so cast time is not learned as the boss cooldown.
- Self-applied aura windows are treated as ability lifecycles. Channeled mechanics such as Whirlwind can emit an activation, a self aura, repeated damage events, and an aura removal; the timer model must learn activation-to-activation intervals rather than channel duration or tick spacing.
- Startup repair may replay bounded debug pull events to correct old learned intervals that were polluted by cast lifecycle or channel tick events.
- Persistent learned timers require current boss combat evidence before display. A boss merely being targeted during unrelated trash combat must not open timer bars until that boss context has combat-log activity or a matching unit is affecting combat.
- Known routine abilities such as `Fierce Blow` and `Auto Shot` are hidden immediately. Other common short-interval abilities shared across many bosses are treated as routine noise once enough evidence exists.
- Timer UI updates must not depend on the visible timer frame's `OnUpdate`; hidden WoW frames can stop polling, so the display uses a separate always-active ticker.
- Timer UI positioning and resizing should be direct mouse interactions on the visible frame. Slash commands are acceptable only as fallback diagnostics or recovery controls.

This keeps diagnostics useful without letting normal trash packs teach the addon permanent boss timers.

## AzerothCore Pattern Notes

AzerothCore scripts under `/home/two/projects/azerothcore-wotlk` are useful as a catalogue of common encounter shapes, not as truth for Ascension. Relevant patterns seen there include:

- Timed scheduler abilities with fixed or random repeat windows, for example `context.Repeat(22s, 26s)`.
- Channel or aura abilities where one server event creates multiple client combat-log records.
- HP-gated checks such as `HealthBelowPct` and phase-dependent `HealthAbovePct` guards.
- Scheduler pauses such as `DelayAll`, where one mechanic delays unrelated timers.
- Summon and add ownership patterns where the boss triggers adds or add sources perform encounter mechanics.

The addon can only infer these patterns from client-visible evidence, so learned models must prefer stable activation evidence and keep enough diagnostics to correct bad assumptions.
