# Live Poker Solver

A native macOS live Texas Hold'em coach that works with **any** poker site, on calls too, because it reads only the one window you pick.

1. Open your game anywhere (browser, client, even a video), then in the app pick that window and press **Watch my table**.
2. [Jev](https://docs.typesafe.ai) (multimodal, `jev-1.14.0`) does a one-time first pass per table (game, cash/tournament, seats, **unit — BB/$/chips**, where the blinds print), classifies board changes, and reads cards into a game schema only when something changed. On-device Vision OCR reads the numbers (pot, call, blinds) — Jev never has to spell digits.
3. The Swift maths engine gives **one exact play** (`FOLD / CHECK / CALL / BET / RAISE` at a pot fraction **in your table's units**) in a draggable, always-on-top bar that is hidden from call shares and recordings (`sharingType = .none`), with win chance, break-even need, call EV, outs, SPR, and how the number was got.

## Maths

- Fast 7-card evaluator in Swift (same values as a verified Python reference; self-test in 0.7s, run `--selftest`).
- **Exact enumeration** on flop, turn and river vs one opponent; adaptive Monte Carlo (stops under 0.2% error) preflop and multi-way, now against 1–8 opponents.
- Equity vs **ranges**, not random hands: any / betting (pair+ or draw) / value, in the spirit of eval7 and *Modern Poker Theory*; pot odds from *The Theory of Poker*.
- GTO-style equity solver, **not** a full CFR solver (TexasSolver/Pio class). Close spots show sample size and error.

## Run it

One-click Mac app (Apple Silicon, macOS 14+): `LivePokerSolver.dmg` → drag to Applications → allow Screen Recording once (the build uses a stable local signing identity, so updates keep the permission) → pick window → Watch.

From source:

```bash
cd macos && ./build-app.sh   # builds, signs, installs to ~/Applications
```

## Jev key

Bring your own TypeSafe key — none in this repo or bundle. Save it in `~/Library/Application Support/Poker Trainer/jev_key.txt` (chmod 600) or set `JEV_API_KEY`.

## Honesty notes

- Jev can misread a suit (caught A♣ as A♦ in testing): duplicates are rejected, low-confidence reads flagged, cards confirmed before solving.
- Screenshots of the picked window go to TypeSafe when scanning. Numbers are OCR'd on-device. Nothing is stored.
- Study tool. Many sites ban real-time assistance in real-money games — check the rules where you play.

`prototype/` holds the earlier Python/Chrome version for reference. MIT licence.
