---
name: roblox-game-design
description: Design checklist for making this Roblox game fun, readable and successful — combat feel, onboarding, retention, mobile/console support, monetization within Roblox rules, and performance budgets. Use when planning a new feature, mode, weapon, boss, UI screen or economy change, or when the user asks how to make the game better.
---

# Designing for LAST BLADE on Roblox

Read the README's relevant section first; it is the source of truth for the current rules and numbers. Propose changes that fit the existing systems instead of parallel ones.

## Who plays Roblox

- Most sessions are on **phones**, often low-end; many players are young and new to the genre. Design for a thumb, a small screen and 150-250 ms ping first, then add depth for PC/gamepad.
- Players decide in the first **60 seconds** whether to stay. A new player must be fighting (and understanding why they win or lose) within ~10 s of the title card.
- Short sessions: a full loop (queue → fight → reward → back to lobby) should fit in 2-5 minutes.

## Combat feel checklist

- **Readability:** every threat telegraphs (glint, 危 colour, sound) before it lands, with time to react at mobile ping. Silhouettes and colours must read against the sand floor.
- **Responsiveness:** the player's own input animates instantly (client prediction); the server decides the outcome. Keep input buffering generous.
- **Feedback on every exchange:** hit-stop, sparks, sound, camera kick, a number or word. A deflect must *feel* better than a hit.
- **Fairness:** a death should always be explainable ("I pressed late", "I guarded a thrust"). If a test player can't explain it, the telegraph or rule is wrong.
- **Sidegrades, not upgrades:** new weapons spend the same budget (README "Weapons"). Defensive verbs stay universal.
- Tune numbers in `Config.luau`, then check `Telemetry` alarms rather than guessing.

## Onboarding and retention

- Teach by doing (Coach prompts, Deflect Trainer, tutorial boss) — no walls of text.
- Easy early wins against Novice bots, then ramp. Bot tiers follow the least experienced human.
- Daily reasons to return (missions, streak, rotating shop) must never punish missing a day.
- Social hooks: invite button, duels, leaderboards, visible cosmetics on others.

## Monetization (Roblox rules + this game's rule)

- **Robux never buys whether you win.** Only cosmetics and convenience that doesn't affect combat.
- Paid random items: show odds before purchase and respect `PolicyService` `ArePaidRandomItemsRestricted` (hide, not grey out).
- No fake timers, no pressure pop-ups on first join, no paid streak repair. Every cosmetic category should be earnable.
- Purchases are idempotent and granted only after the save commits.
- Avoid real-brand names, FromSoftware/Sekiro trademarks and copied assets; keep everything original.

## Platform support

- Every action must work on keyboard/mouse, gamepad and touch; show the right button names (`InputNames`).
- Touch targets ≥ 45 px, kept clear of the left-thumb move stick.
- Respect Settings toggles (camera shake, reduced effects, reduce motion).

## Performance budget

- Target a steady 60 fps on a mid phone. Keep parts, lights, Highlights (~31 cap) and particles in check; pool VFX.
- Measure with Studio's **MicroProfiler** (Ctrl+F6) and **Stats** panel rather than guessing.

## When proposing a feature

Give: the player-facing goal (why it's fun), how it fits the existing loop, the files/configs it touches, what it costs (perf, complexity), and how to playtest it (see `roblox-playtest`). Prefer the smallest version that proves the idea.
