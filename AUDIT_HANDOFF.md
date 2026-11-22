# Audit handoff — Live Poker Solver

Purpose: give an independent checker everything needed to verify, reproduce, and break this app. Product owner reports the live advice feels wrong in real play; do not assume any claim below is true without rerunning it.

## What this is
Native macOS Texas Hold'em live coach. It captures one picked window, reads cards from pixels, and gives one categorised action. Play-money study use; many real-money sites ban real-time assistance.

## Run it first
```bash
cd macos && ./build-app.sh        # builds, signs, installs ~/Applications/Live Poker Solver.app
open ~/Applications/"Live Poker Solver.app"
# or from source: swift build -c release && .build/release/LivePokerSolver --selftest
# spot check:  "Live Poker Solver" --solve AhQh 9dTc4dJhKd 36.7 20 57.4
```
First run prompts for Screen Recording (System Settings → Privacy & Security). The app is local-signed with a stable self-signed identity (macos/make-signing-identity.sh) so rebuilds keep the grant; it is not notarized.

Jev key lives only outside the repo:
```
~/Library/Application Support/Poker Trainer/jev_key.txt   ( chmod 600; or set JEV_API_KEY )
```
There must be no key in the repo, app bundle, or DMG. Grep before every release: `grep -rl "apikey_" .`

## Components (macos/Sources/LivePokerSolver/)
| File | Owns |
|---|---|
| App.swift | `AppState` state machine, main window, always-on-top `NSPanel` (`sharingType = .none`, so call shares/recordings never see it), screening of `status` text, solving via `analyse(...)` |
| Capture.swift | `listWindows()` (`SCShareableContent`), `capture()` (`SCScreenshotManager`), `feltScore`/`tableBox` (local felt-colour table crop), `fingerprint`/`diffRatio` change gate, OCR crop helper |
| Jev.swift | TypeSafe client for `POST https://api.typesafe.ai/v1/systemone` (`model: jev-1.14.0`, `TypeSafe-Danger-Zone-Images: true`, `TypeSafe-Danger-Zone-Long-Context: true`), typed questions: one rank choice and one suit choice per card slot, street choice, `hero_turn`/`facing_bet`/`opponents`/`tables` questions, pot box; `tableInfo()` first pass (unit/game/format/seats); `detect()` change classifier. `parseSchema` dedupes cards and tracks per-card confidence. |
| OCR.swift | Apple Vision OCR on device: finds pot, Call amount, and blinds from the located pot/blinds crops. It is the only source of digits (Jev cannot emit numbers). |
| Engine.swift | Exact fast 7-card evaluator (`evalFast`), `equity`/`equity_detail` (exact enumeration flop/turn/river for one opponent, adaptive Monte Carlo otherwise), villain ranges in `rangeCombos` (`any|open|bet|value`), `chen`/`handClass`, GTO-ish preflop ranges in `RFI_RANGES`/`THREEBET_RANGE`/`CALL_RANGE` (position default CO), pot-fraction sizing, base `analyse` decision, `Advice`, `describeHand`, `boardDanger`, `SelfTest` |
| CFRSolver.swift / CFRSolverSolve.swift | One-street counterfactual-regret solver: 20 equity buckets (60 on river), bucket-vs-bucket win table counted by sampling, bet tree (fold/call/check, ⅓/¾/pot bets, 3× re-raise cap), CFR in 200-iteration blocks until hero strategy changes less than 0.008 (cap 2000), mixed strategies, villain fold fraction. Hero assumed to act after the bettor on future streets only inside `MultiStreet` below. |
| MultiStreet.swift | Monte Carlo CFR for facing bets on flop/turn (`MultiStreet.Trainer`): samples villain hands, deals turn/river, plays future betting rounds, CFR+ with linear-weighted averaging. Dispatches from `CFRSolver.solve` when `toCall > 0` and board count is 3 or 4; otherwise the one-street CFR is used. |
| KuhnTest.swift | Theory gate. Kuhn poker has known value -1/18 for the first player; `SelfTest` fails if recovered CFR value drifts > 0.01. |
| prototype/ | Earlier Python web version. Reference only; not the product. The Python engine's numbers matched Swift's after porting. |

## Data flow
Window pick (or auto-find by felt score) → every 1.2 s local pixel fingerprint; big changes skip the Jev gate and re-scan → Jev reads typed questions against the screenshot (table-felt crop first, full frame fallback; re-read once if two hero cards are not found) → user-visible schema (hero/board/pot/to-call/stack/opponents/unit) → OCR fills numbers → solver (preflop ranges preflop; multi-street CFR when facing a flop/turn bet; one-street CFR heads-up postflop; exact/range equity otherwise) → advice shown only after a fresh solve (advice is cleared on every new scan — stale advice caused a user's complaint; verify this invariant).

## Recorded test evidence (verify, don't trust)
- Evaluator: Swift evaluator matched brute-force Python evaluator on 3,000 random hand pairs with zero mismatches (benchmark and tests in session history, not committed as tests).
- Exact equity: AA river 0.8934 vs a random opponent; AK vs flop betting range 0.2097.
- Solver sanity: nut flush draw faces a flop bet → CALL; Aces on a dry flop → BET; weak river → FOLD 92%; Kuhn CFR → -0.0556 exactly.
- Timings: fresh spot ~0.2–2.5 s one-street; multi-street facing-bet spots ~2–5 s; repeat spots cached.
- Jev suits: 24 of 24 cards across two single-table online videos (GGPoker broadcast and PokerStars/Lex), including four-colour decks. Whole-card-choice variant once read K♥ Q♥ as "8♥" on live Bovada and has been reverted to rank+suit questions. Bovada light-blue layout once read 9♠ J♦ and a four-card board exactly. Multi-table screens defeat Jev (guard tells the user to enlarge a single table).

## Known weaknesses / likely defects to probe
1. Jev can still misread, especially black suits (one A♠→A♣) or when hero cards overlap. Low-confidence reads are flagged; duplicates are rejected; never auto-solves if hero confidence is low, but a confident wrong read still solves.
2. Hero position defaults to CO in preflop ranges (there is no position UI). Multi-street assumes the hero is in position when facing a bet and out of position when first to act; hero's actual seat (Bovada dealer marker) is ignored.
3. Opponent counts come from Jev and can count seated/folded players; when facing a bet the engine deliberately solves heads-up versus that bettor.
4. `tableBox` is a green/brown felt heuristic; unusual (for example light-blue) tables rely on the full-frame fallback.
5. One-street CFR treats the end of the street as showdown and under-prices draws; multi-street only partly compensates and only when facing a bet. No ICM, no multi-way CFR, no opponent stats or exploitation.
6. Full GTO solver claim would be wrong: this is bucketed CFR plus ranges, not an unabstracted solve. It is closer to a good trainer than a replacement for study tools.
7. Owner's latest live report (Bovada, 2026-11-22): "everything it's saying is wrong", then "everything you did is wrong". Treat the live pipeline as **not trusted for decisions** until an independent audit reproduces the failures and finds the causes. The app has crashed in real play before (preflop scan range trap, fixed in commit history).

## Full-check procedure for the auditor
1. `cd poker-trainer/macos && swift build -c release && .build/release/LivePokerSolver --selftest` — Kuhn gate and solver checks must all PASS. Note the binary in ~/Applications can be stale: run `macos/build-app.sh` (it now fails loudly) and compare build times/hashes before trusting any running copy.
2. Read every file in `macos/Sources/LivePokerSolver/` fully (about 2,500 lines total), plus `macos/Package.swift`, `macos/build-app.sh`, `macos/make-signing-identity.sh`. Check git log: several features were added in single passes under time pressure and some were reverted; search for leftover dead code (`scanSmartUnused`, unused warnings), force unwraps, and stale state after failed scans.
3. Reproduce live reading failures yourself: capture single-table screenshots from at least two sites, run the same typed Jev questions, and score rank and suit accuracy against the pixels card by card. Include Bovada's light-blue layout and hero cards that overlap. Whole-card (52-choice) questioning was tried and reverted after it once read K♥Q♥ as a lone 8♥; rank+suit questions are the current default — verify which is actually better with data, not anecdote.
4. For any advice the app gives wrong, trace which layer failed: capture/window choice, Jev schema, OCR numbers, range assumption, CFR abstraction, or UI showing a stale `Advice`. A wrong answer with a right read is a different bug than a right answer to a wrong read.
5. Check secrets hygiene: grep repo and app bundle for the Jev key prefix, confirm the key only exists at the documented path, and confirm screenshots sent to TypeSafe are only of the user-picked window.
6. Deliverable expected from the audit: a defect list ranked by (a) anything that can show an action for a different hand than the one on screen, (b) wrong-card or wrong-board reads that still solve, (c) crashes/hangs, (d) solver spots where a reference solver (PioSOLVER/GTO Wizard) disagrees materially, each with a reproduction.
