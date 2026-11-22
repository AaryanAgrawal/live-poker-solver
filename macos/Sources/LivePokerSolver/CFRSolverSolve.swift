import Foundation

extension CFRSolver {
    struct HeroAction { let name: String; let put: Double; let aggressive: Bool }

    static func regretMatch(_ regrets: [Double]) -> [Double] {
        let pos = regrets.map { max(0, $0) }
        let sum = pos.reduce(0, +)
        return sum > 0 ? pos.map { $0 / sum } : [Double](repeating: 1.0 / Double(max(1, regrets.count)), count: regrets.count)
    }

    static func solve(hero: [Card], board: [Card], pot: Double, toCall: Double, stack: Double?, villainKind: String) -> Output? {
        guard board.count >= 3, pot > 0 else { return nil }
        // Facing a bet on flop/turn, future streets set the real price:
        // the multi-street engine earned this spot in golden tests
        // (folds blanks, raises made hands, mixes the draw call).
        if toCall > 0 {
            let key = "\(hero.map { $0.code }.joined())|\(board.map { $0.code }.joined())|\(pot)|\(toCall)|\(stack ?? -1)|\(villainKind)"
            if let hit = multiCache[key] { return hit }
            if let multi = MultiStreet.solve(hero: hero, board: board, pot: pot, toCall: toCall, stack: stack, villainKind: villainKind) {
                multiCache[key] = multi
                return multi
            }
        }
        let model = buildModel(hero: hero, board: board, villainKind: villainKind)
        let H = model.heroW.count, V = model.villainW.count
        let effStack = stack ?? pot * 20
        let prior = pot - toCall
        var actions: [HeroAction] = []
        if toCall > 0 {
            actions = [HeroAction(name: "FOLD", put: 0, aggressive: false),
                       HeroAction(name: "CALL", put: min(toCall, effStack), aggressive: false)]
            for f in [0.5, 1.0] {
                let put = min(effStack, toCall + f * (pot + toCall))
                if put > toCall { actions.append(HeroAction(name: "RAISE", put: put, aggressive: true)) }
            }
            if effStack > toCall && !actions.contains(where: { $0.put == effStack }) {
                actions.append(HeroAction(name: "RAISE", put: effStack, aggressive: true))
            }
        } else {
            actions = [HeroAction(name: "CHECK", put: 0, aggressive: false)]
            for f in [1.0 / 3, 0.75, 1.0] {
                let put = min(effStack, f * pot)
                if put > 0 { actions.append(HeroAction(name: "BET", put: put, aggressive: true)) }
            }
            if effStack > 0 && !actions.contains(where: { $0.put == effStack }) {
                actions.append(HeroAction(name: "BET", put: effStack, aggressive: true))
            }
        }
        let A = actions.count
        var heroRegret = [[Double]](repeating: [Double](repeating: 0, count: A), count: H)
        var heroAvg = [[Double]](repeating: [Double](repeating: 0, count: A), count: H)
        var villRegret = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: 0, count: 3), count: A), count: V)
        var villAvg = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: 0, count: 3), count: A), count: V)
        var jamRegretA = [[[Double]]](repeating: [[Double]](repeating: [0, 0], count: A), count: H)
        var jamAvgA = [[[Double]]](repeating: [[Double]](repeating: [0, 0], count: A), count: H)

        let hb0 = model.heroComboBucket
        var prevStrategy: [Double]? = nil
        var blocks = 0
        while blocks < 10 {
            blocks += 1
            for _ in 0..<200 {
            let hS = heroRegret.map { regretMatch($0) }
            let vS = villRegret.map { $0.map { regretMatch($0) } }
            let jS = jamRegretA.map { $0.map { regretMatch($0) } }
            for hb in 0..<H { for a in 0..<A { heroAvg[hb][a] += hS[hb][a] } }
            for vb in 0..<V { for a in 0..<A { for v in 0..<3 { villAvg[vb][a][v] += vS[vb][a][v] } } }
            for hb in 0..<H { for a in 0..<A { for j in 0..<2 { jamAvgA[hb][a][j] += jS[hb][a][j] } } }

            var heroVal = [[Double]](repeating: [Double](repeating: 0, count: A), count: H)
            var villPay = [[[Double]]](repeating: [[Double]](repeating: [0, 0, 0], count: A), count: V)
            var jamVal = [[[Double]]](repeating: [[Double]](repeating: [0, 0], count: A), count: H)
            for hb in 0..<H where model.heroW[hb] > 0 {
                for a in 0..<A {
                    let act = actions[a]
                    for vb in 0..<V where model.villainW[vb] > 0 {
                        let e = model.matrix[hb][vb], w = model.villainW[vb]
                        if !act.aggressive {
                            heroVal[hb][a] += w * (act.name == "FOLD" ? 0 : e * (prior + 2 * act.put) - act.put)
                        } else {
                            let jamPut = min(toCall + effStack, act.put * 3)
                            let foldPay = pot
                            let callPay = e * (prior + 2 * act.put) - act.put
                            let jamFold = -act.put
                            let jamCall = e * (prior + 2 * jamPut) - jamPut
                            jamVal[hb][a][0] += w * jamFold
                            jamVal[hb][a][1] += w * jamCall
                            let jamPay = jS[hb][a][0] * jamFold + jS[hb][a][1] * jamCall
                            heroVal[hb][a] += w * (vS[vb][a][0] * foldPay + vS[vb][a][1] * callPay + vS[vb][a][2] * jamPay)
                            let reach = model.heroW[hb] * hS[hb][a]
                            villPay[vb][a][0] += reach * foldPay
                            villPay[vb][a][1] += reach * callPay
                            villPay[vb][a][2] += reach * jamPay
                        }
                    }
                }
            }
            for hb in 0..<H where model.heroW[hb] > 0 {
                let exp = zip(hS[hb], heroVal[hb]).map(*).reduce(0, +)
                for a in 0..<A {
                    heroRegret[hb][a] += heroVal[hb][a] - exp
                    if actions[a].aggressive {
                        var jamProb = 0.0
                        for vb in 0..<V { jamProb += model.villainW[vb] * vS[vb][a][2] }
                        let jamExp = jS[hb][a][0] * jamVal[hb][a][0] + jS[hb][a][1] * jamVal[hb][a][1]
                        jamRegretA[hb][a][0] += jamProb * (jamVal[hb][a][0] - jamExp)
                        jamRegretA[hb][a][1] += jamProb * (jamVal[hb][a][1] - jamExp)
                    }
                }
            }
            for vb in 0..<V where model.villainW[vb] > 0 {
                for a in 0..<A where actions[a].aggressive {
                    let exp = (0..<3).map { vS[vb][a][$0] * villPay[vb][a][$0] }.reduce(0, +)
                    for v in 0..<3 { villRegret[vb][a][v] += exp - villPay[vb][a][v] }
                }
            }
            let total = heroAvg[hb0].reduce(0, +)
            let current = heroAvg[hb0].map { total > 0 ? $0 / total : 0 }
            if let prev = prevStrategy, zip(current, prev).map({ abs($0 - $1) }).max() ?? 1 < 0.008 { break }
            prevStrategy = current
        }
        }

        let hb = hb0
        let sums = heroAvg[hb].reduce(0, +)
        let villSums = villAvg.map { $0.map { $0.reduce(0, +) } }
        var strategy: [(action: String, freq: Double, ev: Double, put: Double)] = []
        for a in 0..<A {
            let act = actions[a]
            var ev = 0.0
            for vb in 0..<V where model.villainW[vb] > 0 {
                let e = model.matrix[hb][vb], w = model.villainW[vb]
                if !act.aggressive {
                    ev += w * (act.name == "FOLD" ? 0 : e * (prior + 2 * act.put) - act.put)
                } else {
                    let vs = (0..<3).map { villAvg[vb][a][$0] / max(1, villSums[vb][a]) }
                    let jamShare = jamAvgA[hb][a].reduce(0, +)
                    let jf = jamShare > 0 ? jamAvgA[hb][a][0] / jamShare : 0.0
                    let jc = jamShare > 0 ? jamAvgA[hb][a][1] / jamShare : 0.0
                    let jamPut = min(toCall + effStack, act.put * 3)
                    let jamPay = jf * -act.put + jc * (e * (prior + 2 * jamPut) - jamPut)
                    ev += w * (vs[0] * pot + vs[1] * (e * (prior + 2 * act.put) - act.put) + vs[2] * jamPay)
                }
            }
            strategy.append((act.name, sums > 0 ? heroAvg[hb][a] / sums : 0, ev, act.put))
        }
        var foldPct: Double? = nil
        if let top = strategy.filter({ $0.action == "RAISE" || $0.action == "BET" }).max(by: { $0.freq < $1.freq }),
           let a = actions.firstIndex(where: { $0.name == top.action && $0.put == top.put }) {
            foldPct = (0..<V).reduce(0.0) { acc, vb in
                acc + model.villainW[vb] * (villAvg[vb][a][0] / max(1, villSums[vb][a]))
            }
        }
        return Output(strategy: strategy.sorted { $0.freq > $1.freq }, villainFold: foldPct)
    }
}
