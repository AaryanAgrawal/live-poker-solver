"""Poker trainer: equity + pot-odds maths for study, drills and hand review. Not for live play.

  python3 trainer.py advise --hero AhKd --board Qs7h2c --pot 100 --to-call 50 --opponents 1
  python3 trainer.py drill
"""

import argparse
import random
from collections import Counter
from itertools import combinations

RANKS = "23456789TJQKA"
DECK = [r + s for r in RANKS for s in "shdc"]


def parse(text):
    cards = [text[i : i + 2] for i in range(0, len(text), 2)]
    cards = [c[0].upper() + c[1].lower() for c in cards]
    if any(c not in DECK for c in cards) or len(set(cards)) != len(cards):
        raise ValueError(f"Bad cards: {text}")
    return cards


def score5(cards):
    """Bigger tuple = better 5-card hand."""
    ranks = sorted((RANKS.index(c[0]) for c in cards), reverse=True)
    groups = sorted(Counter(ranks).items(), key=lambda g: (g[1], g[0]), reverse=True)
    shape = [n for _, n in groups]
    order = [r for r, _ in groups]
    flush = len({c[1] for c in cards}) == 1
    straight = len(set(ranks)) == 5 and ranks[0] - ranks[4] == 4
    if ranks == [12, 3, 2, 1, 0]:  # A-5 straight
        straight, order = True, [3]
    if straight and flush:
        return (8, order)
    if shape == [4, 1]:
        return (7, order)
    if shape == [3, 2]:
        return (6, order)
    if flush:
        return (5, order)
    if straight:
        return (4, order)
    if shape == [3, 1, 1]:
        return (3, order)
    if shape == [2, 2, 1]:
        return (2, order)
    if shape == [2, 1, 1, 1]:
        return (1, order)
    return (0, order)


def best(cards):
    return max(score5(c) for c in combinations(cards, 5))


# --- Best local maths engine: fast evaluator + exact enumeration -----------
# Card int: rank 0-12 (2..A) in the high bits, suit 0-3 in the low bits.
TO_INT = {c: RANKS.index(c[0]) * 4 + "shdc".index(c[1]) for c in DECK}
FROM_INT = {v: k for k, v in TO_INT.items()}


def eval_fast(cards):
    """One comparable int for a 5-7 card hand. Bigger = better."""
    counts = [0] * 13
    suit_counts = [0] * 4
    suit_mask = [0] * 4
    mask = 0
    for c in cards:
        r, s = c >> 2, c & 3
        counts[r] += 1
        suit_counts[s] += 1
        suit_mask[s] |= 1 << r
        mask |= 1 << r

    def straight_top(m):
        for top in range(12, 2, -1):
            if top == 3:  # wheel A-2-3-4-5
                if m & 0x100F == 0x100F:
                    return 3
            elif m >> (top - 4) & 0b11111 == 0b11111:
                return top
        return -1

    def pack(category, tie):
        value = category << 20
        for i, r in enumerate((tie + [0] * 5)[:5]):
            value |= r << (16 - 4 * i)
        return value

    for s in range(4):
        if suit_counts[s] >= 5:
            top = straight_top(suit_mask[s])
            if top >= 0:
                return pack(8, [top])
    groups = sorted(((n, r) for r, n in enumerate(counts) if n), reverse=True)
    shape = [n for n, _ in groups]
    tie = []
    for n, r in groups:
        tie += [r] * n
    if shape[0] == 4:
        return pack(7, tie)
    if shape[:2] == [3, 2]:
        return pack(6, tie)
    for s in range(4):
        if suit_counts[s] >= 5:
            ranks = [r for r in range(12, -1, -1) if suit_mask[s] >> r & 1][:5]
            return pack(5, ranks)
    top = straight_top(mask)
    if top >= 0:
        return pack(4, [top])
    if shape[0] == 3:
        return pack(3, tie)
    if shape[:2] == [2, 2]:
        return pack(2, tie)
    if shape[0] == 2:
        return pack(1, tie)
    return pack(0, tie)


def hand_class(hero):
    ranks = sorted((RANKS.index(c[0]) for c in hero), reverse=True)
    if ranks[0] == ranks[1]:
        return RANKS[ranks[0]] * 2
    suited = hero[0][1] == hero[1][1]
    return RANKS[ranks[0]] + RANKS[ranks[1]] + ("s" if suited else "o")


def chen(hero):
    """Bill Chen's preflop strength score. A rough, well-known ranking, not GTO."""
    ranks = sorted((RANKS.index(c[0]) for c in hero), reverse=True)
    base = {12: 10, 11: 8, 10: 7, 9: 6}.get(ranks[0], (ranks[0] + 2) / 2)
    if ranks[0] == ranks[1]:
        return max(5, base * 2)
    score = base + (2 if hero[0][1] == hero[1][1] else 0)
    gap = ranks[0] - ranks[1] - 1
    score -= {0: 0, 1: 1, 2: 2, 3: 4}.get(gap, 5)
    if gap <= 1 and ranks[0] < 10:  # straight bonus for low connected cards
        score += 1
    return score


def range_combos(hero, board, kind):
    """Opponent two-card combos (card ints) that fit a range, eval7-style."""
    used = {TO_INT[c] for c in hero + board}
    rest = [c for c in range(52) if c not in used]
    board_i = [TO_INT[c] for c in board]
    out = []
    for a, b in combinations(rest, 2):
        cards = [FROM_INT[a], FROM_INT[b]]
        if not board:
            score = chen(cards)
            keep = score >= 7 if kind in ("open", "bet") else score >= 9.5 if kind == "value" else True
        else:
            cat = eval_fast([a, b] + board_i) >> 20
            mine = cards + list(board)
            flush_draw = any(sum(c[1] == s for c in mine) == 4 for s in "shdc")
            ranks = {RANKS.index(c[0]) for c in mine} | ({-1} if any(c[0] == "A" for c in mine) else set())
            straight_draw = any(all((r + k) in ranks for k in range(4)) for r in range(-1, 10))
            keep = cat >= 1 or flush_draw or straight_draw if kind in ("bet", "open") else cat >= 2 if kind == "value" else True
        if keep:
            out.append((a, b))
    return out


def equity_detail(hero, board=(), opponents=1, trials=20000, rng=random, villain="any"):
    """Exact enumeration on turn/river vs one opponent; else fast Monte Carlo.

    Returns equity plus how it was got, so close calls can be shown as close.
    """
    hero_i = [TO_INT[c] for c in hero]
    board_i = [TO_INT[c] for c in board]
    used = set(hero_i + board_i)
    rest = [c for c in range(52) if c not in used]
    combos = range_combos(hero, board, villain) if villain != "any" and opponents == 1 else None
    if opponents == 1 and len(board_i) >= 3:
        # Exact: hero is scored once per completed board, not once per opponent.
        won = total = 0.0
        need = 5 - len(board_i)
        for extra in combinations(rest, need):
            full = board_i + list(extra)
            mine = eval_fast(hero_i + full)
            left = [c for c in rest if c not in extra]
            left_set = set(left)
            opps = combinations(left, 2) if combos is None else [c for c in combos if c[0] in left_set and c[1] in left_set]
            for opp in opps:
                theirs = eval_fast(list(opp) + full)
                won += 1 if mine > theirs else 0.5 if mine == theirs else 0
                total += 1
        return {"equity": won / total, "method": "exact", "samples": int(total), "se": 0.0}
    # Monte Carlo in batches: stop as soon as the estimate is tight enough.
    won = done = 0.0
    eq = 0.0
    while done < trials:
        batch = min(5000, trials - int(done))
        for _ in range(batch):
            if combos is not None:
                opp = list(rng.choice(combos))
                pool = [c for c in rest if c not in opp]
                full = board_i + rng.sample(pool, 5 - len(board_i))
                mine = eval_fast(hero_i + full)
                theirs = [eval_fast(opp + full)]
                draw = opp
            else:
                draw = rng.sample(rest, 2 * opponents + 5 - len(board_i))
                full = board_i + draw[2 * opponents:]
                mine = eval_fast(hero_i + full)
                theirs = [eval_fast(draw[2 * i:2 * i + 2] + full) for i in range(opponents)]
            top = max(theirs)
            won += 1 if mine > top else 1 / (1 + theirs.count(top)) if mine == top else 0
        done += batch
        eq = won / done
        if done >= 10000 and (eq * (1 - eq) / done) ** 0.5 < 0.002:
            break
    return {"equity": eq, "method": "monte-carlo",
            "samples": int(done), "se": (eq * (1 - eq) / done) ** 0.5}


def equity(hero, board=(), opponents=1, trials=20000, rng=random):
    """Share of the pot hero wins on average against random opponent hands."""
    return equity_detail(hero, board, opponents, trials, rng)["equity"]


FRACTIONS = [1 / 3, 1 / 2, 2 / 3, 3 / 4, 1.0]


def pick_fraction(eq):
    if eq >= 0.80:
        return 1.0
    if eq >= 0.70:
        return 0.75
    if eq >= 0.60:
        return 0.5
    return 1 / 3


def size_for(fraction, pot, to_call):
    """Chips to put in now for a bet, or for a raise on top of the call."""
    if to_call:
        return to_call + fraction * (pot + to_call)
    return fraction * pot


def advise(hero, board, pot, to_call, opponents=1, eq=None, stack=None):
    eq = equity(hero, board, opponents) if eq is None else eq
    need = to_call / (pot + to_call) if to_call else 0.0
    ev = eq * (pot + to_call) - to_call  # average chips won by calling
    can_raise = stack is None or stack > to_call
    if to_call == 0:
        available = ["CHECK", "BET"] if can_raise and pot else ["CHECK"]
        action = "BET" if "BET" in available and eq > 1 / (opponents + 1) + 0.1 else "CHECK"
    else:
        available = ["FOLD", "CALL"] + (["RAISE"] if can_raise else [])
        if eq < need:
            action = "FOLD"
        elif can_raise and eq > 1 / (opponents + 1) + 0.15:
            action = "RAISE"
        else:
            action = "CALL"
    fraction = pick_fraction(eq) if action in ("BET", "RAISE") else None
    amount = size_for(fraction, pot, to_call) if fraction else (to_call if action == "CALL" else 0)
    if stack is not None:
        amount = min(amount, stack)
    return {"action": action, "equity": eq, "needed": need, "ev_call": ev,
            "available": available, "fraction": fraction, "amount": round(amount)}


HAND_NAMES = ["high card", "a pair", "two pair", "three of a kind", "a straight",
              "a flush", "a full house", "four of a kind", "a straight flush"]


def analyse(hero, board, pot, to_call, opponents=1, stack=None, villain="auto", position="CO"):
    """Book-flavoured maths on a confirmed schema. Returns one categorised action.

    Sources in spirit: Modern Poker Theory (Acevedo) for sizing by strength and
    board, The Theory of Poker (Sklansky) for pot odds / EV. This is range-free
    equity vs random hands, so treat close spots as close, not solver-exact.
    """
    if villain == "auto":
        villain = "bet" if to_call else "any"
    detail = equity_detail(hero, board, opponents, villain=villain)
    result = advise(hero, board, pot, to_call, opponents, eq=detail["equity"], stack=stack)
    result.update(method=detail["method"], samples=detail["samples"], se=detail["se"], villain=villain)
    result["class"] = hand_class(hero)
    result["chen"] = chen(hero)
    open_min = {"UTG": 9, "MP": 8, "CO": 7, "BTN": 5, "SB": 7, "BB": 0}.get(position, 7)
    result["chart"] = (f"Chen score {result['chen']:.0f}: {'opens' if result['chen'] >= open_min else 'does not open'} "
                       f"from {position} in a simplified chart (not GTO-exact)") if not board else None
    result["hand"] = HAND_NAMES[best(hero + board)[0]] if board else "not yet known (preflop)"
    suited = len(hero) == 2 and hero[0][1] == hero[1][1]
    if board and len(board) < 5:  # draws can still arrive
        mine = [c for c in hero + board]
        flush_draw = any(sum(c[1] == s for c in mine) == 4 for s in "shdc")
        ranks = {RANKS.index(c[0]) for c in mine} | ({-1} if any(c[0] == "A" for c in mine) else set())
        straight_draw = any(all((r + k) in ranks for k in range(4)) for r in range(-1, 10))
        result["draw"] = "flush draw" if flush_draw else "straight draw" if straight_draw else None
    else:
        result["draw"] = None
    result["outs"] = 9 if result["draw"] == "flush draw" else 8 if result["draw"] == "straight draw" else 0
    result["suited"] = suited
    result["spr"] = round(stack / pot, 1) if stack and pot else None
    result["sizes"] = [{"fraction": f, "label": f"{f:.2f}".rstrip("0").rstrip(".") + "x pot",
                        "amount": round(min(size_for(f, pot, to_call), stack)) if stack else round(size_for(f, pot, to_call))}
                       for f in FRACTIONS]  # fmt: skip
    if result["action"] in ("BET", "RAISE"):
        why = f"Your hand wins often enough ({result['equity']:.0%}) to build the pot"
        why += ", and a draw may improve" if result["draw"] else ""
    elif result["action"] == "CALL":
        why = f"You need {result['needed']:.0%} to break even and you have {result['equity']:.0%}"
    elif result["action"] == "FOLD":
        why = f"You need {result['needed']:.0%} to break even but only have {result['equity']:.0%}"
    else:
        why = "Checking is free and your hand is not strong enough to build the pot"
    result["why"] = why + "."
    return result


def show(result):
    print(
        f"{result['action']}: you win about {result['equity']:.0%} of the time, "
        f"you need {result['needed']:.0%} to break even, "
        f"calling earns {result['ev_call']:+.1f} chips on average."
    )


def drill():
    score = total = 0
    while True:
        deck = random.sample(DECK, 7)
        hero, board = deck[:2], deck[2 : 2 + random.choice([0, 3, 4, 5])]
        pot = random.choice([40, 60, 100, 150])
        to_call = random.choice([0, pot // 4, pot // 2, pot])
        print(f"\nYou: {' '.join(hero)}  Board: {' '.join(board) or '(preflop)'}  Pot: {pot}  To call: {to_call}")
        options = "check/bet" if to_call == 0 else "fold/call/raise"
        try:
            answer = input(f"Your move ({options}, q to quit): ").strip().upper()
        except EOFError:
            break
        if answer in {"Q", ""}:
            break
        result = advise(hero, board, pot, to_call)
        total += 1
        score += answer == result["action"]
        print("Correct." if answer == result["action"] else "Not the best play.")
        show(result)
    print(f"\nScore: {score}/{total}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("advise")
    a.add_argument("--hero", required=True)
    a.add_argument("--board", default="")
    a.add_argument("--pot", type=float, required=True)
    a.add_argument("--to-call", type=float, default=0)
    a.add_argument("--opponents", type=int, default=1)
    sub.add_parser("drill")
    args = parser.parse_args()
    if args.cmd == "drill":
        drill()
    else:
        hero, board = parse(args.hero), parse(args.board)
        parse(args.hero + args.board)
        show(advise(hero, board, args.pot, args.to_call, args.opponents))
