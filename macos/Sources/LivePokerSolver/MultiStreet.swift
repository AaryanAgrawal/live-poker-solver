import Foundation

/// Monte Carlo CFR across the remaining streets (experimental, gated by tests).
/// Each training pass samples one villain hand and deals turn/river as the
/// hand actually reaches them, with a betting round on every street.
enum MultiStreet {
    struct Act {
        let name: String; let add: Double
        var aggressive: Bool { name == "RAISE" || name == "BET" }
    }

    struct State {
        var board: [Int], pot: Double
        var heroStack: Double, villainStack: Double
        var heroRound: Double = 0, villainRound: Double = 0
        var heroTotal: Double = 0
        var heroTurn = true
        var acted = 0
        var history = ""
        var needsCard = false
        var showdown = false
        var terminal: Double? = nil
    }

    static func bucket(_ combo: [Int], _ board: [Int], cache: inout [String: Int]) -> Int {
        let key = "\(combo.sorted())|\(board.sorted())"
        if let hit = cache[key] { return hit }
        let cards = (combo + board).map { Card(value: $0) }
        let cat = board.count >= 3 ? evalFast(combo + board) >> 20 : Int(chen(cards) / 2)
        var counts: [Int: Int] = [:]
        for c in cards { counts[c.rank, default: 0] += 1 }
        let pairRank = counts.filter { $0.value == 2 }.map { $0.key }.max()
        let boardTop = board.map { $0 / 4 }.max() ?? 0
        let d = hasDraw(cards)
        let value: Int
        if cat >= 2 { value = 20 + cat }
        else if cat == 1 {
            if let pr = pairRank, pr > boardTop { value = 18 }
            else if pairRank == boardTop { value = 16 }
            else { value = d.flush || d.straight ? 12 : 10 }
        } else if d.flush { value = 11 }
        else if d.straight { value = 9 }
        else { value = (cards.map { $0.rank }.max() ?? 0) >= 11 ? 7 : 3 }
        cache[key] = value
        return value
    }

    final class Trainer {
        let hero: [Int], startBoard: [Int], villainCombos: [[Int]]
        let startPot: Double, startCall: Double, effStack: Double
        let heroActsFirstEachStreet: Bool
        var regrets: [String: [Double]] = [:]
        var averages: [String: [Double]] = [:]
        var bucketCache: [String: Int] = [:]
        var rng = SplitMix()
        var iteration = 0

        init(hero: [Card], board: [Card], pot: Double, toCall: Double, stack: Double?, villainKind: String) {
            self.hero = hero.map { $0.value }
            startBoard = board.map { $0.value }
            startPot = pot; startCall = toCall
            effStack = stack ?? pot * 20
            heroActsFirstEachStreet = toCall == 0
            if let range = rangeCombos(hero: hero, board: board, kind: villainKind) {
                villainCombos = range.map { [$0.0, $0.1] }
            } else {
                let used = Set(hero.map { $0.value } + board.map { $0.value })
                let rest = (0..<52).filter { !used.contains($0) }
                var combos: [[Int]] = []
                for a in rest { for b in rest where b > a { combos.append([a, b]) } }
                villainCombos = combos
            }
        }

        func rootState() -> State {
            State(board: startBoard, pot: startPot, heroStack: effStack, villainStack: effStack,
                  villainRound: startCall, heroTurn: true, acted: startCall > 0 ? 1 : 0,
                  history: startCall > 0 ? "B" : "")
        }

        func key(_ s: State, combo: [Int]) -> String {
            let toCall = abs(s.heroRound - s.villainRound)
            let callBucket = toCall == 0 ? 0 : toCall / max(1, s.pot) < 0.34 ? 1 : toCall / max(1, s.pot) < 0.8 ? 2 : 3
            let spr = (s.heroStack + s.villainStack) / 2 / max(1, s.pot)
            let sprBucket = spr < 1.5 ? 0 : spr < 4 ? 1 : spr < 8 ? 2 : 3
            return "\(s.board.count)|\(bucket(combo, s.board, cache: &bucketCache))|\(String(s.history.suffix(2)))|\(callBucket)|\(sprBucket)"
        }

        func actions(_ s: State) -> [Act] {
            let stack = s.heroTurn ? s.heroStack : s.villainStack
            let mine = s.heroTurn ? s.heroRound : s.villainRound
            let theirs = s.heroTurn ? s.villainRound : s.heroRound
            let toCall = max(0, theirs - mine)
            var out: [Act] = []
            if toCall > 0 {
                out.append(Act(name: "FOLD", add: 0))
                out.append(Act(name: "CALL", add: min(toCall, stack)))
                for f in [0.5, 1.0] {
                    let add = min(stack, toCall + f * (s.pot + toCall))
                    if add > toCall { out.append(Act(name: "RAISE", add: add)) }
                }
            } else {
                out.append(Act(name: "CHECK", add: 0))
                for f in [1.0 / 3, 0.75, 1.0] {
                    let add = min(stack, f * s.pot)
                    if add > 0 { out.append(Act(name: "BET", add: add)) }
                }
            }
            if stack > (out.last?.add ?? 0) { out.append(Act(name: toCall > 0 ? "RAISE" : "BET", add: stack)) }
            var seen = Set<Double>()
            return out.filter { seen.insert(($0.add * 100).rounded()).inserted }
        }

        func apply(_ s: State, _ act: Act) -> State {
            var n = s
            if act.name == "FOLD" {
                n.terminal = n.heroTurn ? -n.heroTotal : n.pot - n.heroTotal
                return n
            }
            let add = min(act.add, n.heroTurn ? n.heroStack : n.villainStack)
            n.pot += add
            if n.heroTurn { n.heroStack -= add; n.heroRound += add; n.heroTotal += add }
            else { n.villainStack -= add; n.villainRound += add }
            n.history += act.name.prefix(1) + (act.add > 0 ? "1" : "0")
            let closes = act.name == "CALL" || (act.add == 0 && n.acted >= 1)
            if closes {
                if n.board.count == 5 || n.heroStack <= 0.01 || n.villainStack <= 0.01 { n.showdown = true }
                else { n.needsCard = true }
                n.heroRound = 0; n.villainRound = 0; n.acted = 0; n.history = ""
            } else {
                n.acted = act.add > 0 ? 1 : n.acted + 1
            }
            n.heroTurn.toggle()
            return n
        }

        func remaining(_ s: State, villain: [Int]) -> [Int] {
            let used = Set(hero + villain + s.board)
            return (0..<52).filter { !used.contains($0) }
        }

        func showdownValue(_ s: State, villain: [Int], deck: [Int]) -> Double {
            var full = s.board
            var pool = deck
            while full.count < 5 {
                let i = Int(rng.next() % UInt64(pool.count))
                full.append(pool.remove(at: i))
            }
            let mine = evalFast(hero + full), theirs = evalFast(villain + full)
            let share = mine > theirs ? 1.0 : mine == theirs ? 0.5 : 0.0
            return share * s.pot - s.heroTotal
        }

        func traverse(_ s0: State, villain: [Int], traverserHero: Bool, reach: Double) -> Double {
            var s = s0
            if let t = s.terminal { return t }
            if s.showdown { return showdownValue(s, villain: villain, deck: remaining(s, villain: villain)) }
            if s.needsCard {
                var deck = remaining(s, villain: villain)
                let i = Int(rng.next() % UInt64(deck.count))
                s.board.append(deck.remove(at: i))
                s.needsCard = false; s.heroTurn = heroActsFirstEachStreet
                return traverse(s, villain: villain, traverserHero: traverserHero, reach: reach)
            }
            let combo = s.heroTurn ? hero : villain
            let k = key(s, combo: combo)
            let acts = actions(s)
            var strat = CFRSolver.regretMatch(regrets[k] ?? [Double](repeating: 0, count: acts.count))
            if strat.count != acts.count { strat = [Double](repeating: 1.0 / Double(acts.count), count: acts.count) }
            if s.heroTurn == traverserHero {
                var values: [Double] = []
                for (i, act) in acts.enumerated() {
                    values.append(traverse(apply(s, act), villain: villain, traverserHero: traverserHero, reach: reach * strat[i]))
                }
                let node = zip(strat, values).map(*).reduce(0, +)
                let sign = traverserHero ? 1.0 : -1.0
                // Never wipe learning: same key can recur with fewer actions when stacks shrink.
                if regrets[k] == nil { regrets[k] = [Double](repeating: 0, count: acts.count) }
                if averages[k] == nil { averages[k] = [Double](repeating: 0, count: acts.count) }
                while regrets[k]!.count < acts.count { regrets[k]!.append(0) }
                while averages[k]!.count < acts.count { averages[k]!.append(0) }
                for i in acts.indices {
                    regrets[k]![i] = max(0, regrets[k]![i] + sign * (values[i] - node))
                    averages[k]![i] += reach * strat[i] * Double(iteration + 1)
                }
                return node
            }
            var pick = Double(rng.next() % 10000) / 10000.0, chosen = 0
            for i in strat.indices { pick -= strat[i]; if pick <= 0 { chosen = i; break } }
            return traverse(apply(s, acts[chosen]), villain: villain, traverserHero: traverserHero, reach: reach)
        }

        func averageStrategy(_ k: String, count: Int) -> [Double] {
            var a = averages[k] ?? []
            if a.count != count { a = [Double](repeating: 0, count: count) }
            let sum = a.reduce(0, +)
            if sum > 0 { return a.map { $0 / sum } }
            var r = regrets[k] ?? []
            if r.count != count { r = [Double](repeating: 0, count: count) }
            return CFRSolver.regretMatch(r)
        }

        func evaluate(rootAction: Act, trials: Int) -> Double {
            var total = 0.0
            for _ in 0..<trials {
                let villain = villainCombos[Int(rng.next() % UInt64(villainCombos.count))]
                var s = apply(rootState(), rootAction)
                var steps = 0
                while s.terminal == nil && steps < 80 {
                    steps += 1
                    if s.showdown { total += showdownValue(s, villain: villain, deck: remaining(s, villain: villain)); s.terminal = 0; break }
                    if s.needsCard {
                        var deck = remaining(s, villain: villain)
                        let i = Int(rng.next() % UInt64(deck.count))
                        s.board.append(deck.remove(at: i)); s.needsCard = false; s.heroTurn = heroActsFirstEachStreet
                        continue
                    }
                    let acts = actions(s)
                    let strat = averageStrategy(key(s, combo: s.heroTurn ? hero : villain), count: acts.count)
                    var pick = Double(rng.next() % 10000) / 10000.0, chosen = 0
                    for i in strat.indices { pick -= strat[i]; if pick <= 0 { chosen = i; break } }
                    s = apply(s, acts[chosen])
                }
                if let t = s.terminal { total += t }
            }
            return total / Double(trials)
        }

        func train(iterations: Int) {
            for i in 0..<iterations {
                iteration = i
                let v1 = villainCombos[Int(rng.next() % UInt64(villainCombos.count))]
                _ = traverse(rootState(), villain: v1, traverserHero: true, reach: 1)
                let v2 = villainCombos[Int(rng.next() % UInt64(villainCombos.count))]
                _ = traverse(rootState(), villain: v2, traverserHero: false, reach: 1)
            }
        }

        func rootOutput() -> CFRSolver.Output {
            let root = rootState()
            let rootActions = actions(root)
            let freq = averageStrategy(key(root, combo: hero), count: rootActions.count)
            var strategy: [(action: String, freq: Double, ev: Double, put: Double)] = []
            for (i, act) in rootActions.enumerated() {
                strategy.append((act.name, freq[i], evaluate(rootAction: act, trials: 900), act.add))
            }
            strategy.sort { $0.freq > $1.freq }
            return CFRSolver.Output(strategy: strategy, villainFold: nil)
        }

        /// What the trainer believes at one constructed state (for debugging/tests).
        func strategyAt(_ s: State, combo: [Int]) -> [Double] {
            averageStrategy(key(s, combo: combo), count: actions(s).count)
        }
    }

    static func solve(hero: [Card], board: [Card], pot: Double, toCall: Double, stack: Double?, villainKind: String) -> CFRSolver.Output? {
        guard board.count == 3 || board.count == 4 else { return nil }
        let trainer = Trainer(hero: hero, board: board, pot: pot, toCall: toCall, stack: stack, villainKind: villainKind)
        trainer.train(iterations: 20000)
        return trainer.rootOutput()
    }
}
