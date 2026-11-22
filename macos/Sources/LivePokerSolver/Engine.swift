import Foundation

let RANKS = Array("23456789TJQKA")
let SUITS = Array("shdc")

struct Card: Hashable {
    let rank: Int // 0=2 ... 12=A
    let suit: Int // s h d c
    var value: Int { rank * 4 + suit }
    var code: String { "\(RANKS[rank])\(SUITS[suit])" }
    init(rank: Int, suit: Int) { self.rank = rank; self.suit = suit }
    init?(_ code: String) {
        let c = Array(code)
        guard c.count == 2, let r = RANKS.firstIndex(of: c[0]), let s = SUITS.firstIndex(of: c[1]) else { return nil }
        rank = r; suit = s
    }
    init(value: Int) { rank = value / 4; suit = value % 4 }
}

func parseCards(_ text: String) -> [Card] {
    let clean = text.replacingOccurrences(of: " ", with: "")
    var out: [Card] = []
    var i = clean.startIndex
    while let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) {
        if let card = Card(String(clean[i..<j])) { out.append(card) }
        i = j
    }
    return out
}

func evalFast(_ cards: [Int]) -> Int {
    var counts = [Int](repeating: 0, count: 13)
    var suitCounts = [Int](repeating: 0, count: 4)
    var suitMask = [Int](repeating: 0, count: 4)
    var mask = 0
    for c in cards {
        let r = c / 4, s = c % 4
        counts[r] += 1; suitCounts[s] += 1; suitMask[s] |= 1 << r; mask |= 1 << r
    }
    func straightTop(_ m: Int) -> Int {
        for top in stride(from: 12, through: 3, by: -1) {
            if top == 3 { if m & 0x100F == 0x100F { return 3 } }
            else if (m >> (top - 4)) & 0b11111 == 0b11111 { return top }
        }
        return -1
    }
    func pack(_ cat: Int, _ tie: [Int]) -> Int {
        var v = cat << 20
        for i in 0..<5 { v |= ((i < tie.count ? tie[i] : 0) << (16 - 4 * i)) }
        return v
    }
    for s in 0..<4 where suitCounts[s] >= 5 {
        let t = straightTop(suitMask[s]); if t >= 0 { return pack(8, [t]) }
    }
    let groups = counts.enumerated().filter { $0.element > 0 }.map { (n: $0.element, r: $0.offset) }
        .sorted { $0.n != $1.n ? $0.n > $1.n : $0.r > $1.r }
    let shape = groups.map { $0.n }
    var tie: [Int] = []; for g in groups { tie += [Int](repeating: g.r, count: g.n) }
    if shape[0] == 4 { return pack(7, tie) }
    if shape.count >= 2 && shape[0] == 3 && shape[1] == 2 { return pack(6, tie) }
    for s in 0..<4 where suitCounts[s] >= 5 {
        return pack(5, (0..<13).reversed().filter { suitMask[s] >> $0 & 1 == 1 }.prefix(5).map { $0 })
    }
    let st = straightTop(mask); if st >= 0 { return pack(4, [st]) }
    if shape[0] == 3 { return pack(3, tie) }
    if shape.count >= 2 && shape[0] == 2 && shape[1] == 2 { return pack(2, tie) }
    if shape[0] == 2 { return pack(1, tie) }
    return pack(0, tie)
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func combinations(_ items: [Int], _ k: Int) -> [[Int]] {
    if k == 0 { return [[]] }
    var out: [[Int]] = []
    func rec(_ start: Int, _ cur: [Int]) {
        if cur.count == k { out.append(cur); return }
        for i in start..<items.count { rec(i + 1, cur + [items[i]]) }
    }
    rec(0, [])
    return out
}

func handClass(_ hero: [Card]) -> String {
    let r = hero.map { $0.rank }.sorted(by: >)
    if r[0] == r[1] { return "\(RANKS[r[0]])\(RANKS[r[0]])" }
    return "\(RANKS[r[0]])\(RANKS[r[1]])\(hero[0].suit == hero[1].suit ? "s" : "o")"
}

func chen(_ hero: [Card]) -> Double {
    let r = hero.map { $0.rank }.sorted(by: >)
    let base: Double = r[0] == 12 ? 10 : r[0] == 11 ? 8 : r[0] == 10 ? 7 : r[0] == 9 ? 6 : Double(r[0] + 2) / 2
    if r[0] == r[1] { return max(5, base * 2) }
    var score = base + (hero[0].suit == hero[1].suit ? 2 : 0)
    let gap = r[0] - r[1] - 1
    score -= gap == 0 ? 0 : gap == 1 ? 1 : gap == 2 ? 2 : gap == 3 ? 4 : 5
    if gap <= 1 && r[0] < 10 { score += 1 }
    return score
}

func hasDraw(_ cards: [Card]) -> (flush: Bool, straight: Bool) {
    let flush = (0..<4).contains { s in cards.filter { $0.suit == s }.count == 4 }
    var ranks = Set(cards.map { $0.rank }); if ranks.contains(12) { ranks.insert(-1) }
    let straight = (-1...9).contains { r in (0..<4).allSatisfy { ranks.contains(r + $0) } }
    return (flush, straight)
}

func rangeCombos(hero: [Card], board: [Card], kind: String) -> [(Int, Int)]? {
    if kind == "any" { return nil }
    let used = Set(hero.map { $0.value } + board.map { $0.value })
    let rest = (0..<52).filter { !used.contains($0) }
    var out: [(Int, Int)] = []
    for a in rest { for b in rest where b > a {
        let cards = [Card(value: a), Card(value: b)]
        let keep: Bool
        if board.isEmpty {
            let s = chen(cards)
            keep = kind == "value" ? s >= 9.5 : s >= 7
        } else {
            let cat = evalFast([a, b] + board.map { $0.value }) >> 20
            let d = hasDraw(cards + board)
            keep = kind == "value" ? cat >= 2 : (cat >= 1 || d.flush || d.straight)
        }
        if keep { out.append((a, b)) }
    } }
    return out
}

struct Equity { let value: Double; let method: String; let samples: Int; let se: Double }

func equity(hero: [Card], board: [Card], opponents: Int, villain: String) -> Equity {
    let heroI = hero.map { $0.value }, boardI = board.map { $0.value }
    let used = Set(heroI + boardI)
    let rest = (0..<52).filter { !used.contains($0) }
    let combos = opponents == 1 ? rangeCombos(hero: hero, board: board, kind: villain) : nil
    if opponents == 1 && boardI.count >= 3 {
        var won = 0.0, total = 0.0
        for extra in combinations(rest, 5 - boardI.count) {
            let full = boardI + extra
            let mine = evalFast(heroI + full)
            let left = rest.filter { !extra.contains($0) }
            let leftSet = Set(left)
            let opps: [[Int]] = combos == nil ? combinations(left, 2)
                : combos!.filter { leftSet.contains($0.0) && leftSet.contains($0.1) }.map { [$0.0, $0.1] }
            for opp in opps {
                let t = evalFast(opp + full)
                won += mine > t ? 1 : mine == t ? 0.5 : 0; total += 1
            }
        }
        return Equity(value: won / total, method: "exact", samples: Int(total), se: 0)
    }
    var rng = SplitMix(); var won = 0.0, done = 0, eq = 0.0
    while done < 20000 {
        let batch = min(5000, 20000 - done)
        for _ in 0..<batch {
            if let combos = combos {
                let c = combos[Int(rng.next() % UInt64(combos.count))]
                var p = rest.filter { $0 != c.0 && $0 != c.1 }
                var fb = boardI
                for i in 0..<(5 - boardI.count) { let j = i + Int(rng.next() % UInt64(p.count - i)); p.swapAt(i, j); fb.append(p[i]) }
                let mine = evalFast(heroI + fb), t = evalFast([c.0, c.1] + fb)
                won += mine > t ? 1 : mine == t ? 0.5 : 0
            } else {
                let need = 2 * opponents + 5 - boardI.count
                var idx = rest, draw: [Int] = []
                for i in 0..<need { let j = i + Int(rng.next() % UInt64(idx.count - i)); idx.swapAt(i, j); draw.append(idx[i]) }
                let full = boardI + Array(draw.dropFirst(2 * opponents))
                let mine = evalFast(heroI + full)
                let theirs = (0..<opponents).map { evalFast(Array(draw[(2 * $0)..<(2 * $0 + 2)]) + full) }
                let top = theirs.max()!
                won += mine > top ? 1 : mine == top ? 1.0 / Double(1 + theirs.filter { $0 == top }.count) : 0
            }
        }
        done += batch; eq = won / Double(done)
        if done >= 10000 && (eq * (1 - eq) / Double(done)).squareRoot() < 0.002 { break }
    }
    return Equity(value: eq, method: "monte-carlo", samples: done, se: (eq * (1 - eq) / Double(done)).squareRoot())
}

let FRACTIONS = [1.0 / 3, 0.5, 2.0 / 3, 0.75, 1.0]
let HAND_NAMES = ["high card", "a pair", "two pair", "three of a kind", "a straight", "a flush", "a full house", "four of a kind", "a straight flush"]

struct Advice {
    let action: String, equity: Double, needed: Double, evCall: Double
    let fraction: Double?, amount: Double, available: [String]
    let hand: String, draw: String?, outs: Int, spr: Double?
    let handDetail: String, danger: String?
    let foldPct: Double?, sizeEV: Double?
    let villain: String, method: String, samples: Int, se: Double
    let mix: String
    let sizes: [(Double, Double)], why: String
}

func pickFraction(_ eq: Double) -> Double { eq >= 0.8 ? 1 : eq >= 0.7 ? 0.75 : eq >= 0.6 ? 0.5 : 1.0 / 3 }

/// Price every size against the villain range: bigger bets fold out more of
/// their range, but the hands that stay are stronger. Best EV size wins.
/// This is a model of GTO sizing logic, not a full game-tree solve.
func bestSize(pot: Double, toCall: Double, eq: Double, wet: Bool = false) -> (fraction: Double, ev: Double, fold: Double) {
    var best = (fraction: FRACTIONS[0], ev: -Double.infinity, fold: 0.0)
    for f in FRACTIONS {
        let extra = f * (pot + toCall)
        let totalPut = toCall + extra
        let foldPct = min(0.9, extra / (pot + toCall + extra))
        let contEq = max(0, min(1, eq * (1 - (wet ? 0.5 : 0.35) * foldPct)))
        let ev = foldPct * (pot + toCall)
            + (1 - foldPct) * (contEq * (pot + toCall + 2 * extra) - totalPut)
        if ev > best.ev { best = (f, ev, foldPct) }
    }
    return best
}
func sizeFor(_ f: Double, _ pot: Double, _ toCall: Double) -> Double { toCall > 0 ? toCall + f * (pot + toCall) : f * pot }

let RANK_SINGULAR = ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King", "Ace"]
let RANK_PLURAL = ["Twos", "Threes", "Fours", "Fives", "Sixes", "Sevens", "Eights", "Nines", "Tens", "Jacks", "Queens", "Kings", "Aces"]

func describeHand(_ hero: [Card], _ board: [Card]) -> String {
    if board.isEmpty { return "No cards out yet — just your two cards" }
    let all = hero + board
    let cat = evalFast(all.map { $0.value }) >> 20
    var counts: [Int: Int] = [:]; for c in all { counts[c.rank, default: 0] += 1 }
    let groups = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
    let high = all.map { $0.rank }.max()!
    switch cat {
    case 8, 4: return "\(cat == 8 ? "Straight flush" : "Straight"), \(RANK_SINGULAR[high]) high"
    case 7: return "Four of a kind — \(RANK_PLURAL[groups[0].key])"
    case 6: return "Full house — \(RANK_PLURAL[groups[0].key]) over \(RANK_PLURAL[groups[1].key])"
    case 5: return "Flush, \(RANK_SINGULAR[high]) high"
    case 3: return "Three of a kind — \(RANK_PLURAL[groups[0].key])"
    case 2: return "Two pair — \(RANK_PLURAL[groups[0].key]) and \(RANK_PLURAL[groups[1].key])"
    case 1: return "One pair — \(RANK_PLURAL[groups[0].key])"
    default: return "\(RANK_SINGULAR[high]) high — no pair yet"
    }
}

func boardDanger(_ board: [Card]) -> String? {
    if board.count < 3 { return nil }
    if (0..<4).contains(where: { s in board.filter { $0.suit == s }.count >= 3 }) {
        return "Careful: the board has three of one suit, so a flush is possible."
    }
    let ranks = Set(board.map { $0.rank })
    for top in stride(from: 12, through: 3, by: -1) {
        let window: Set<Int> = top == 3 ? [12, 3, 2, 1, 0] : Set((top - 4)...top)
        if ranks.intersection(window).count >= 4 { return "Careful: four cards to a straight are on the board." }
    }
    var counts: [Int: Int] = [:]; for c in board { counts[c.rank, default: 0] += 1 }
    if counts.values.contains(where: { $0 >= 2 }) { return "Careful: the board is paired, so a full house is possible." }
    return nil
}

func analyse(hero: [Card], board: [Card], pot: Double, toCall: Double, opponents: Int, stack: Double?) -> Advice {
    let villain = toCall > 0 ? "bet" : "any"
    let eq = equity(hero: hero, board: board, opponents: opponents, villain: villain)
    let e = eq.value
    let need = toCall > 0 ? toCall / (pot + toCall) : 0
    let ev = e * (pot + toCall) - toCall
    let d0 = board.isEmpty ? (flush: false, straight: false) : hasDraw(hero + board)
    let draw0 = board.count == 3 || board.count == 4 ? (d0.flush ? "flush draw" : d0.straight ? "straight draw" : nil) : nil
    let canRaise = stack == nil || stack! > toCall
    let wetBoard = !board.isEmpty && (hasDraw(hero + board).flush || hasDraw(hero + board).straight || (0..<4).contains { su in board.filter { $0.suit == su }.count >= 2 })
    let sized = canRaise && pot > 0 ? bestSize(pot: pot, toCall: toCall, eq: e, wet: wetBoard) : nil
    var action: String
    let available: [String]
    if toCall == 0 {
        available = canRaise && pot > 0 ? ["CHECK", "BET"] : ["CHECK"]
        action = available.contains("BET") && sized != nil && sized!.ev > 0 ? "BET" : "CHECK"
    } else {
        available = ["FOLD", "CALL"] + (canRaise ? ["RAISE"] : [])
        if e < need {
            action = sized != nil && sized!.ev > ev && draw0 != nil ? "RAISE" : "FOLD"
        } else {
            action = canRaise && sized != nil && sized!.ev > ev ? "RAISE" : "CALL"
        }
    }
    var fraction = (action == "BET" || action == "RAISE") ? sized?.fraction : nil
    var amount = fraction != nil ? sizeFor(fraction!, pot, toCall) : (action == "CALL" ? toCall : 0)
    if let stack = stack { amount = min(amount, stack) }
    let d = board.isEmpty ? (flush: false, straight: false) : hasDraw(hero + board)
    let draw = board.count == 3 || board.count == 4 ? (d.flush ? "flush draw" : d.straight ? "straight draw" : nil) : nil
    let hand = board.isEmpty ? "preflop" : HAND_NAMES[evalFast(hero.map { $0.value } + board.map { $0.value }) >> 20]
    let sizes = FRACTIONS.map { f -> (Double, Double) in
        var a = sizeFor(f, pot, toCall); if let stack = stack { a = min(a, stack) }; return (f, (a * 100).rounded() / 100) }
    var mix = action
    if toCall == 0, let sized = sized {
        let alt = max(0.0, sized.ev)
        if sized.ev > 0 && sized.ev < pot * 0.08 { mix = "BET \(Int(50 + sized.ev / (pot * 0.08) * 40))% · CHECK rest" }
    } else if let sized = sized, action == "RAISE" || action == "CALL" {
        let callEV = max(ev, 0.001), raiseEV = max(sized.ev, 0.0)
        if ev > 0 && abs(raiseEV - callEV) < pot * 0.08 {
            let r = Int((raiseEV / (raiseEV + callEV) * 100).rounded())
            mix = "RAISE \(r)% · CALL \(100 - r)%"
        }
    }
    var why = action == "BET" || action == "RAISE" ? "You win \(Int((e * 100).rounded()))% — enough to build the pot."
        : action == "CALL" ? "You need \(Int((need * 100).rounded()))% and have \(Int((e * 100).rounded()))%."
        : action == "FOLD" ? "You need \(Int((need * 100).rounded()))% but have \(Int((e * 100).rounded()))%."
        : "Free to check; not strong enough to build the pot."
    var chosenFold = fraction != nil ? sized?.fold : nil
    var chosenSizeEV = fraction != nil ? sized?.ev : nil
    var evFinal = ev
    if opponents == 1, board.count >= 3,
       let cfr = CFRSolver.solve(hero: hero, board: board, pot: pot, toCall: toCall, stack: stack, villainKind: villain),
       let top = cfr.strategy.first {
        action = top.action
        amount = top.put
        fraction = (top.action == "BET" || top.action == "RAISE") && pot + toCall > 0 ? (top.put - toCall) / (pot + toCall) : nil
        evFinal = cfr.strategy.first(where: { $0.action == "CALL" || $0.action == "CHECK" })?.ev ?? ev
        chosenFold = cfr.villainFold
        chosenSizeEV = top.ev
        mix = cfr.strategy.filter { $0.freq > 0.04 }.map { "\($0.action) \(Int(($0.freq * 100).rounded()))%" }.joined(separator: " · ")
        why = "Full solver (CFR) picks this most often against their range."
    }
    return Advice(action: action, equity: e, needed: need, evCall: evFinal, fraction: fraction,
                  amount: (amount * 100).rounded() / 100, available: available, hand: hand, draw: draw,
                  outs: draw == "flush draw" ? 9 : draw == "straight draw" ? 8 : 0,
                  spr: stack != nil && pot > 0 ? (stack! / pot * 10).rounded() / 10 : nil,
                  handDetail: describeHand(hero, board), danger: boardDanger(board),
                  foldPct: chosenFold, sizeEV: chosenSizeEV,
                  villain: villain, method: eq.method, samples: eq.samples, se: eq.se, mix: mix, sizes: sizes, why: why)
}

enum SelfTest {
    static func run() -> Never {
        func ev(_ s: String) -> Int { evalFast(parseCards(s).map { $0.value }) }
        func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { exit(1) } }
        check(ev("AsKsQsJsTs2c3d") > ev("AhAdAcAsKh2c3d"), "straight flush beats quads")
        check(ev("AhAdAcAsKh2c3d") > ev("KhKdKcQhQd2c3s"), "quads beat full house")
        let t0 = Date()
        let aaRiver = equity(hero: parseCards("AhAd"), board: parseCards("Qs7h2c9d3s"), opponents: 1, villain: "any")
        check(aaRiver.method == "exact" && aaRiver.value > 0.85, "AA river exact \(aaRiver.value)")
        let weak = equity(hero: parseCards("7c2d"), board: parseCards("Qs9h4cKd3s"), opponents: 1, villain: "any")
        check(weak.value < 0.1, "72o river exact \(weak.value)")
        let akFlop = equity(hero: parseCards("AhKd"), board: parseCards("Qs7h2c"), opponents: 1, villain: "bet")
        check(akFlop.method == "exact" && akFlop.value < 0.3, "AK vs betting range \(akFlop.value)")
        let aaPre = equity(hero: parseCards("AhAd"), board: [], opponents: 1, villain: "bet")
        check(aaPre.value > 0.6, "AA preflop vs opening range \(aaPre.value)")
        let adv = analyse(hero: parseCards("AhKh"), board: parseCards("Qh7h2c"), pot: 100, toCall: 50, opponents: 1, stack: 1000)
        check(adv.draw == "flush draw" && adv.outs == 9 && adv.action == "CALL", "flush draw advice \(adv.action)")
        let strong = analyse(hero: parseCards("AhAd"), board: parseCards("Qs7h2c"), pot: 100, toCall: 0, opponents: 1, stack: 1000)
        check(strong.action == "BET", "CFR aces flop bets (\(strong.mix))")
        let weakRiver = analyse(hero: parseCards("7c2d"), board: parseCards("Qs9h4cKd3s"), pot: 100, toCall: 50, opponents: 1, stack: 1000)
        check(weakRiver.action == "FOLD", "CFR weak river folds (\(weakRiver.mix))")
        print(String(format: "ALL PASS in %.2fs", Date().timeIntervalSince(t0)))
        exit(0)
    }
}
