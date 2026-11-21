"""Jev multimodal: poker screenshot -> typed answers -> editable game schema.

Jev never writes sentences. It answers typed questions in one pass, so the
screenshot is asked as many small choices: rank/suit per card, street, and
yes/no checks. Numbers (pot, stacks) it cannot spell out, so it locates the
pot area with a box question and the player types the digits from the crop.

Docs: https://docs.typesafe.ai/api.md  (model jev-1.14.0, header
TypeSafe-Danger-Zone-Images: true, assets map, choice/noul/box questions)
"""

import json
import urllib.request

API = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-1.14.0"
RANKS = {"A": "Ace", "K": "King", "Q": "Queen", "J": "Jack", "T": "Ten",
         "9": "Nine", "8": "Eight", "7": "Seven", "6": "Six", "5": "Five",
         "4": "Four", "3": "Three", "2": "Two", "?": "Unreadable or no card here"}
SUITS = {"s": "Spades (black)", "h": "Hearts (red)", "d": "Diamonds (red)",
         "c": "Clubs (black)", "?": "Unreadable or no card here"}
SLOTS = ["hero1", "hero2", "board1", "board2", "board3", "board4", "board5"]


def build_request(image_b64, fmt="jpeg"):
    questions = {}
    for slot in SLOTS:
        where = "the hero's first/second hole card" if slot.startswith("hero") else f"board card {slot[-1]} (left to right)"
        if slot == "hero1":
            where = "the hero's left hole card at the bottom of the table"
        if slot == "hero2":
            where = "the hero's right hole card at the bottom of the table"
        questions[f"{slot}_rank"] = {"type": "choice",
            "instructions": f"In image `shot`, what is the rank of {where}? Choose ? if there is no such card or it cannot be read.",
            "criteria": RANKS}  # fmt: skip
        questions[f"{slot}_suit"] = {"type": "choice",
            "instructions": f"In image `shot`, what is the suit of {where}? Choose ? if there is no such card or it cannot be read.",
            "criteria": SUITS}  # fmt: skip
    questions.update({
        "street": {"type": "choice",
            "instructions": "In image `shot`, how many community/board cards are face up in the middle of the poker table?",
            "criteria": {"0": "No board cards (preflop)", "3": "Three board cards (flop)",
                         "4": "Four board cards (turn)", "5": "Five board cards (river)"}},
        "hero_turn": {"type": "noul",
            "instructions": "In image `shot`, is it the hero's turn to act (action buttons such as Fold/Call/Raise are active for the hero)?"},
        "facing_bet": {"type": "noul",
            "instructions": "In image `shot`, must the hero put in chips to continue (a bet to call), rather than being able to check for free?"},
        "pot_box": {"type": "box", "instructions": "the pot amount display in `shot`"},
    })  # fmt: skip
    return {"model": MODEL, "state": {"screenshot": "shot"},
            "assets": {"shot": {"type": "image", "format": fmt, "data_base64": image_b64}},
            "questions": questions}


def _post(body, api_key, opener):
    req = urllib.request.Request(API, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
        "TypeSafe-Danger-Zone-Images": "true", "TypeSafe-Danger-Zone-Long-Context": "true"})
    with opener(req, timeout=60) as res:
        return json.loads(res.read())


def call_jev(image_b64, api_key, fmt="jpeg", model=MODEL, opener=urllib.request.urlopen):
    body = build_request(image_b64, fmt)
    body["model"] = model or MODEL
    return _post(body, api_key, opener)


def build_detect_request(image_b64, prev, fmt="jpeg"):
    """Cheap gate: has anything that matters changed since the last schema?"""
    prev = prev or {}
    known = (f"Previous known state: hero {' '.join(prev.get('hero') or []) or 'unknown'}, "
             f"board {' '.join(prev.get('board') or []) or 'none'}, pot {prev.get('pot') or 'unknown'}.")
    questions = {
        "board_changed": {"type": "noul",
            "instructions": f"In image `shot`, are the face-up board/community cards different from this previous state? {known}"},
        "hero_changed": {"type": "noul",
            "instructions": f"In image `shot`, are the hero's two hole cards different from this previous state, or is this a new hand? {known}"},
        "pot_changed": {"type": "noul",
            "instructions": f"In image `shot`, has the pot size or a bet in front of the hero changed from this previous state? {known}"},
        "hero_turn": {"type": "noul",
            "instructions": "In image `shot`, is it now the hero's turn to act (Fold/Call/Raise buttons active for the hero)?"},
    }  # fmt: skip
    return {"model": MODEL, "state": {"screenshot": "shot"},
            "assets": {"shot": {"type": "image", "format": fmt, "data_base64": image_b64}},
            "questions": questions}


def call_detect(image_b64, api_key, prev, fmt="jpeg", model=MODEL, opener=urllib.request.urlopen):
    body = build_detect_request(image_b64, prev, fmt)
    body["model"] = model or MODEL
    raw = _post(body, api_key, opener)
    a = raw.get("answers") or {}
    prob = {k: (a.get(k) or {}).get("noul") for k in ("board_changed", "hero_changed", "pot_changed", "hero_turn")}
    changed = (prob["board_changed"] or 0) > 0.6 or (prob["pot_changed"] or 0) > 0.75 or (prob["hero_changed"] or 0) > 0.9
    return {"changed": changed, **prob, "model": raw.get("model")}


def _choice(answers, name):
    a = answers.get(name) or {}
    return a.get("choice"), a.get("confidence")


def parse_schema(raw):
    """Raw Jev response -> {hero, board, to_call_unknown, confidences...}."""
    answers = raw.get("answers") or {}
    cards, conf = {}, {}
    for slot in SLOTS:
        rank, rc = _choice(answers, f"{slot}_rank")
        suit, sc = _choice(answers, f"{slot}_suit")
        cards[slot] = None if not rank or rank == "?" or not suit or suit == "?" else rank + suit
        conf[slot] = round(min(x for x in (rc, sc) if x is not None), 2) if rc is not None and sc is not None else None
    seen = set()
    for slot in SLOTS:  # Jev can repeat a card; a real deck cannot
        if cards[slot] in seen:
            cards[slot], conf[slot] = None, 0.0
        elif cards[slot]:
            seen.add(cards[slot])
    street, street_conf = _choice(answers, "street")
    n_board = int(street) if street and street.isdigit() else 0
    board = [cards[f"board{i}"] for i in range(1, n_board + 1)]
    return {
        "hero": [c for c in (cards["hero1"], cards["hero2"]) if c],
        "board": [c for c in board if c],
        "street_cards": n_board,
        "hero_turn": (answers.get("hero_turn") or {}).get("noul"),
        "facing_bet": (answers.get("facing_bet") or {}).get("noul"),
        "pot_box": (answers.get("pot_box") or {}).get("box"),
        "confidence": {**conf, "street": street_conf},
        "model": raw.get("model"),
    }
