import Foundation

/// Theory gate: Kuhn poker has a known game-theoretic solution.
/// Both players ante 1, one betting round, cards J < Q < K.
/// The first player's value under perfect play is exactly -1/18.
/// If our regret matching cannot recover that, the Hold'em CFR above it
/// is not trustworthy either. (Zinkevich et al., CFR, 2007.)
enum KuhnTest {
    static func run() -> Double {
        var regret: [String: [Double]] = [:]
        var avg: [String: [Double]] = [:]

        func strategy(_ key: String, _ n: Int) -> [Double] {
            CFRSolver.regretMatch(regret[key] ?? [Double](repeating: 0, count: n))
        }
        func showdown(_ c0: Int, _ c1: Int, _ potWin: Double) -> Double { c0 > c1 ? potWin : -potWin }

        func cfr(_ c0: Int, _ c1: Int, _ hist: String, _ r0: Double, _ r1: Double) -> Double {
            switch hist {
            case "xx": return showdown(c0, c1, 1)
            case "bf", "xbf": return hist == "bf" ? 1 : -1          // folder loses their ante
            case "bc", "xbc": return showdown(c0, c1, 2)
            default: break
            }
            if hist == "" || hist == "xb" { // first player to act
                let key = "\(c0)|\(hist)"
                let acts = hist == "" ? ["x", "b"] : ["f", "c"]
                let strat = strategy(key, 2)
                var node = 0.0
                var utils = [0.0, 0.0]
                for a in 0..<2 {
                    utils[a] = hist == ""
                        ? cfr(c0, c1, acts[a], r0 * strat[a], r1)
                        : cfr(c0, c1, hist + acts[a], r0 * strat[a], r1)
                    node += strat[a] * utils[a]
                }
                for a in 0..<2 {
                    regret[key, default: [0, 0]][a] += r1 * (utils[a] - node)
                    avg[key, default: [0, 0]][a] += r0 * strat[a]
                }
                return node
            } else { // "x" or "b": second player to act
                let key = "\(c1)|\(hist)"
                let acts = hist == "x" ? ["x", "b"] : ["f", "c"]
                let strat = strategy(key, 2)
                var node = 0.0
                var utils = [0.0, 0.0]
                for a in 0..<2 {
                    utils[a] = cfr(c0, c1, hist + acts[a], r0, r1 * strat[a])
                    node += strat[a] * utils[a]
                }
                for a in 0..<2 {
                    // P2's utility is the negative of P0's.
                    regret[key, default: [0, 0]][a] += r0 * (node - utils[a])
                    avg[key, default: [0, 0]][a] += r1 * strat[a]
                }
                return node
            }
        }

        let deals = [(0, 1), (0, 2), (1, 0), (1, 2), (2, 0), (2, 1)]
        for _ in 0..<20000 {
            for (c0, c1) in deals { _ = cfr(c0, c1, "", 1, 1) }
        }
        func avgStrategy(_ key: String, _ n: Int) -> [Double] {
            let a = avg[key] ?? [Double](repeating: 0, count: n)
            let sum = a.reduce(0, +)
            return sum > 0 ? a.map { $0 / sum } : [Double](repeating: 1.0 / Double(n), count: n)
        }
        func value(_ c0: Int, _ c1: Int, _ hist: String) -> Double {
            switch hist {
            case "xx": return showdown(c0, c1, 1)
            case "bf": return 1
            case "xbf": return -1
            case "bc", "xbc": return showdown(c0, c1, 2)
            default: break
            }
            if hist == "" || hist == "xb" {
                let acts = hist == "" ? ["x", "b"] : ["f", "c"]
                let strat = avgStrategy("\(c0)|\(hist)", 2)
                return (0..<2).map { strat[$0] * value(c0, c1, hist + acts[$0]) }.reduce(0, +)
            }
            let acts = hist == "x" ? ["x", "b"] : ["f", "c"]
            let strat = avgStrategy("\(c1)|\(hist)", 2)
            return (0..<2).map { strat[$0] * value(c0, c1, hist + acts[$0]) }.reduce(0, +)
        }
        return deals.map { value($0.0, $0.1, "") }.reduce(0, +) / Double(deals.count)
    }
}
