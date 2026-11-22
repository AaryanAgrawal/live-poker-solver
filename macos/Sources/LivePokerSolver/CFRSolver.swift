import Foundation

/// Abstracted CFR solver for one heads-up street.
/// Ranges are bucketed by equity vs the opposing range (20 buckets), the
/// betting tree allows fold/call/check, three raise sizes and a jam, and
/// villain responses are solved by regret matching, not assumed.
/// This is real CFR on an abstracted game — the same family as big solvers,
/// with card and bet abstraction so it finishes live.
enum CFRSolver {
    struct Output {
        let strategy: [(action: String, freq: Double, ev: Double, put: Double)]
        let villainFold: Double?
    }

    static var cache: [String: BucketModel] = [:]
    static var multiCache: [String: Output] = [:]

    struct BucketModel {
        let heroBucketOf: [Int: Int]      // combo index (a*64+b) -> bucket
        let villainBucketOf: [Int: Int]
        let heroW: [Double], villainW: [Double]  // bucket weights
        let matrix: [[Double]]            // P(hero bucket wins) incl. half ties
        let heroComboBucket: Int
    }

    static func comboKey(_ a: Int, _ b: Int) -> Int { min(a, b) * 64 + max(a, b) }

    static func buildModel(hero: [Card], board: [Card], villainKind: String) -> BucketModel {
        let cacheKey = "\(board.map { $0.code }.joined())|\(villainKind)"
        if let hit = cache[cacheKey] { return hit }
        let boardI = board.map { $0.value }
        let boardSet = Set(boardI)
        func combos(excluding extra: Set<Int>) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            for a in 0..<52 where !boardSet.contains(a) && !extra.contains(a) {
                for b in (a + 1)..<52 where !boardSet.contains(b) && !extra.contains(b) { out.append((a, b)) }
            }
            return out
        }
        let heroCombos = combos(excluding: [])
        let villainCombos = rangeCombos(hero: hero, board: board, kind: villainKind) ?? combos(excluding: Set(hero.map { $0.value }))
        func equities(of mine: [(Int, Int)], vs theirs: [(Int, Int)]) -> [Double] {
            var results = [Double](repeating: 0.5, count: mine.count)
            results.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: mine.count) { idx in
                    var rng = SplitMix(); rng.state &+= UInt64(idx &+ 1) &* 0x9E3779B97F4A7C15
                    let me = mine[idx]
                var won = 0.0, n = 0.0
                if boardI.count == 5 {
                    for opp in theirs where opp.0 != me.0 && opp.0 != me.1 && opp.1 != me.0 && opp.1 != me.1 {
                        let m = evalFast([me.0, me.1] + boardI), t = evalFast([opp.0, opp.1] + boardI)
                        won += m > t ? 1 : m == t ? 0.5 : 0; n += 1
                    }
                } else {
                    for _ in 0..<140 {
                        let opp = theirs[Int(rng.next() % UInt64(theirs.count))]
                        if opp.0 == me.0 || opp.0 == me.1 || opp.1 == me.0 || opp.1 == me.1 { continue }
                        var pool = (0..<52).filter { !boardSet.contains($0) && $0 != me.0 && $0 != me.1 && $0 != opp.0 && $0 != opp.1 }
                        var full = boardI
                        for i in 0..<(5 - boardI.count) { let j = i + Int(rng.next() % UInt64(pool.count - i)); pool.swapAt(i, j); full.append(pool[i]) }
                        let m = evalFast([me.0, me.1] + full), t = evalFast([opp.0, opp.1] + full)
                        won += m > t ? 1 : m == t ? 0.5 : 0; n += 1
                    }
                }
                    buf[idx] = n > 0 ? won / n : 0.5
                }
            }
            return results
        }
        func bucketize(_ list: [(Int, Int)], _ eqs: [Double], _ k: Int) -> (of: [Int: Int], w: [Double], mean: [Double]) {
            let order = list.indices.sorted { eqs[$0] < eqs[$1] }
            var of: [Int: Int] = [:], w = [Double](repeating: 0, count: k), sum = [Double](repeating: 0, count: k)
            for (pos, idx) in order.enumerated() {
                let b = min(k - 1, pos * k / max(1, list.count))
                of[comboKey(list[idx].0, list[idx].1)] = b
                w[b] += 1; sum[b] += eqs[idx]
            }
            let total = w.reduce(0, +)
            return (of, w.map { $0 / total }, zip(sum, w).map { $1 > 0 ? $0 / $1 : 0.5 })
        }
        let heroEq = equities(of: heroCombos, vs: villainCombos)
        let villEq = equities(of: villainCombos, vs: heroCombos)
        // River hand values are fixed, so finer groups cost nothing in accuracy.
        let k = boardI.count == 5 ? 60 : 20
        let hb = bucketize(heroCombos, heroEq, k)
        let vb = bucketize(villainCombos, villEq, k)
        // Bucket-vs-bucket win rates counted directly, never derived from means.
        var winSum = [[Double]](repeating: [Double](repeating: 0, count: vb.w.count), count: hb.w.count)
        var counts = [[Double]](repeating: [Double](repeating: 0, count: vb.w.count), count: hb.w.count)
        func tally(_ me: (Int, Int), _ opp: (Int, Int), _ full: [Int]) {
            guard let hb2 = hb.of[comboKey(me.0, me.1)], let vb2 = vb.of[comboKey(opp.0, opp.1)] else { return }
            let m = evalFast([me.0, me.1] + full), t = evalFast([opp.0, opp.1] + full)
            winSum[hb2][vb2] += m > t ? 1 : m == t ? 0.5 : 0
            counts[hb2][vb2] += 1
        }
        if boardI.count == 5 {
            for me in heroCombos { for opp in villainCombos
                where opp.0 != me.0 && opp.0 != me.1 && opp.1 != me.0 && opp.1 != me.1 {
                tally(me, opp, boardI)
            } }
        } else {
            var rng = SplitMix()
            for _ in 0..<40000 {
                let me = heroCombos[Int(rng.next() % UInt64(heroCombos.count))]
                let opp = villainCombos[Int(rng.next() % UInt64(villainCombos.count))]
                if opp.0 == me.0 || opp.0 == me.1 || opp.1 == me.0 || opp.1 == me.1 { continue }
                var pool = (0..<52).filter { !boardSet.contains($0) && $0 != me.0 && $0 != me.1 && $0 != opp.0 && $0 != opp.1 }
                var full = boardI
                for i in 0..<(5 - boardI.count) { let j = i + Int(rng.next() % UInt64(pool.count - i)); pool.swapAt(i, j); full.append(pool[i]) }
                tally(me, opp, full)
            }
        }
        var matrix = [[Double]](repeating: [Double](repeating: 0.5, count: vb.w.count), count: hb.w.count)
        for i in 0..<hb.w.count { for j in 0..<vb.w.count where counts[i][j] > 0 {
            matrix[i][j] = winSum[i][j] / counts[i][j]
        } }
        let heroKey = comboKey(hero[0].value, hero[1].value)
        let model = BucketModel(heroBucketOf: hb.of, villainBucketOf: vb.of,
                                heroW: hb.w, villainW: vb.w, matrix: matrix,
                                heroComboBucket: hb.of[heroKey] ?? 10)
        cache[cacheKey] = model
        return model
    }
}
