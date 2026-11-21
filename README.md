# Live Poker Solver

A live Texas Hold'em coach that works with **any** poker site, because it only ever sees pixels.

1. Press **Watch my table** and pick the Chrome window/tab with your game.
2. [Jev](https://docs.typesafe.ai) (multimodal, `jev-1.14.0`) reads the screenshot into a game schema — hero cards, board, street, facing a bet — and classifies board changes so it only re-reads when something changed.
3. The local maths engine gives **one exact play** (`FOLD / CHECK / CALL / BET / RAISE` at a pot fraction) in a pinned, draggable, always-on-top bar (Chrome Document Picture-in-Picture), with the figures players think about: win chance, break-even need, call EV, outs, SPR.

## Maths

- Fast 7-card evaluator (~380k hands/sec, pure Python, verified against a brute-force evaluator on 3,000 random hands with 0 mismatches).
- **Exact enumeration** on flop, turn and river vs one opponent (hero scored once per completed board); adaptive Monte Carlo (stops when the standard error is under 0.2%) preflop and multi-way.
- Equity vs **ranges**, not just random hands: any / opening / betting (pair+ or draw) / value-only (two pair+), in the spirit of eval7's hand-vs-range and *Modern Poker Theory* (Acevedo); pot odds and EV from *The Theory of Poker* (Sklansky).
- This is a GTO-style equity solver, **not** a full CFR solver like TexasSolver or PioSOLVER. Close spots are shown with their sample size and error.

## Run it

One-click Mac app (Apple Silicon): open `PokerTrainer.dmg`, drag to Applications, launch. Or from source on any platform:

```bash
python3 server.py   # then open http://localhost:8765
```

## Jev key

Bring your own key from TypeSafe — no key is in this repo or the app bundle. Either:

- save it in `~/Library/Application Support/Poker Trainer/jev_key.txt` (chmod 600), or
- run with `JEV_API_KEY=... python3 server.py`

Costs and limits are Jev's; a full table read is a fraction of a cent. Pot and stack numbers are typed by you from the zoomed pot crop Jev locates — Jev returns typed answers, not free text, so digits are confirmed by eye on purpose.

## Honesty notes

- Jev can misread a suit (we caught A♣ read as A♦ in testing). Duplicate cards are rejected automatically and low-confidence reads are flagged; always confirm the cards before trusting a play.
- A screenshot is sent to TypeSafe's API when you scan. Nothing is stored by this app; the practice money is yours to lose responsibly.
- Study/practice tool. Check the rules of any site you play on — many ban real-time assistance in real-money games.

## Licence

MIT
