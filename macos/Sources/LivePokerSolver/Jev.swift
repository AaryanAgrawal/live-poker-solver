import Foundation

struct GameSchema {
    var hero: [String] = [], board: [String] = [], streetCards = 0
    var heroTurn: Double?, facingBet: Double?
    var unit = "chips"
    var opponents = 1
    var potBox: [String: Double]?
    var lowConfidence: [String] = []
}
struct DetectResult { let changed: Bool, board: Double, hero: Double, pot: Double, turn: Double }

enum JevError: Error { case message(String) }
extension JevError: LocalizedError { var errorDescription: String? { if case .message(let m) = self { return m }; return nil } }

enum Jev {
    static let model = "jev-1.14.0"
    static let ranks: [String: String] = ["A": "Ace", "K": "King", "Q": "Queen", "J": "Jack", "T": "Ten",
        "9": "Nine", "8": "Eight", "7": "Seven", "6": "Six", "5": "Five", "4": "Four", "3": "Three", "2": "Two", "?": "Unreadable or no card"]
    static let suits: [String: String] = ["s": "Spades black", "h": "Hearts red", "d": "Diamonds red", "c": "Clubs black", "?": "Unreadable or no card"]
    static let slots = ["hero1", "hero2", "board1", "board2", "board3", "board4", "board5"]

    static func loadKey() -> String {
        if let k = ProcessInfo.processInfo.environment["JEV_API_KEY"], !k.isEmpty { return k }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Poker Trainer/jev_key.txt")
        return (try? String(contentsOf: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func post(_ body: [String: Any]) async throws -> [String: Any] {
        let key = loadKey()
        guard !key.isEmpty else { throw JevError.message("No Jev key on this Mac (~/Library/Application Support/Poker Trainer/jev_key.txt).") }
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, res) = try await URLSession.shared.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw JevError.message("Jev said \(code): \(String(decoding: data.prefix(300), as: UTF8.self))") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func asset(_ jpegB64: String) -> [String: Any] {
        ["model": model, "state": ["screenshot": "shot"],
         "assets": ["shot": ["type": "image", "format": "jpeg", "data_base64": jpegB64]]]
    }

    static func scan(jpegB64: String) async throws -> GameSchema {
        var q: [String: Any] = [:]
        for slot in slots {
            let place = slot == "hero1" ? "the hero's left hole card at the bottom of the table"
                : slot == "hero2" ? "the hero's right hole card at the bottom of the table"
                : "board card \(slot.last!) from the left in the middle of the table"
            q["\(slot)_rank"] = ["type": "choice", "instructions": "In image `shot`, rank of \(place)? Choose ? if none/unreadable.", "criteria": ranks]
            q["\(slot)_suit"] = ["type": "choice", "instructions": "In image `shot`, suit of \(place)? Choose ? if none/unreadable.", "criteria": suits]
        }
        q["street"] = ["type": "choice", "instructions": "In image `shot`, how many board cards are face up?",
                       "criteria": ["0": "None preflop", "3": "Three flop", "4": "Four turn", "5": "Five river"]]
        q["hero_turn"] = ["type": "noul", "instructions": "In image `shot`, is it the hero's turn (Fold/Call/Raise active for hero)?"]
        q["facing_bet"] = ["type": "noul", "instructions": "In image `shot`, must the hero pay to continue rather than check free?"]
        q["pot_box"] = ["type": "box", "instructions": "the pot amount display in `shot`"]
        q["opponents"] = ["type": "choice", "instructions": "In image `shot`, how many opponents are still in this hand (not folded, not counting the hero)?",
                          "criteria": Dictionary(uniqueKeysWithValues: (1...8).map { ("\($0)", "\($0) opponent(s) still in the hand") })]
        var body = asset(jpegB64); body["questions"] = q
        let raw = try await post(body)
        let a = raw["answers"] as? [String: Any] ?? [:]
        func choice(_ n: String) -> (String?, Double?) {
            let d = a[n] as? [String: Any]; return (d?["choice"] as? String, d?["confidence"] as? Double)
        }
        var schema = GameSchema()
        var cards: [String: String] = [:], conf: [String: Double] = [:]
        for slot in slots {
            let (r, rc) = choice("\(slot)_rank")
            let (su, sc) = choice("\(slot)_suit")
            cards[slot] = (r == nil || r == "?" || su == nil || su == "?") ? nil : r! + su!
            conf[slot] = min(rc ?? 1, sc ?? 1)
        }
        var seen = Set<String>()
        for slot in slots {
            if let c = cards[slot] { if seen.contains(c) { cards[slot] = nil; conf[slot] = 0 } else { seen.insert(c) } }
        }
        let (street, _) = choice("street")
        schema.streetCards = Int(street ?? "0") ?? 0
        schema.hero = [cards["hero1"], cards["hero2"]].compactMap { $0 }
        schema.board = (1...max(0, schema.streetCards)).compactMap { cards["board\($0)"] }
        schema.heroTurn = (a["hero_turn"] as? [String: Any])?["noul"] as? Double
        schema.facingBet = (a["facing_bet"] as? [String: Any])?["noul"] as? Double
        schema.potBox = (a["pot_box"] as? [String: Any])?["box"] as? [String: Double]
        let (oppChoice, _) = choice("opponents"); schema.opponents = Int(oppChoice ?? "1") ?? 1
        schema.lowConfidence = conf.filter { $0.value < 0.7 }.map { $0.key }.sorted()
        return schema
    }

    struct TableInfo {
        var unit = "chips", game = "holdem", format = "cash", seats = "6"
        var blindsBox: [String: Double]?
        var line: String { "\(game == "holdem" ? "Texas Hold'em" : game) · \(format) · \(seats)-max · amounts in \(unit)" }
    }

    /// One first pass per table: units, game, format, seats, where blinds are printed.
    static func tableInfo(jpegB64: String) async throws -> TableInfo {
        let q: [String: Any] = [
            "unit": ["type": "choice", "instructions": "In image `shot`, what unit are amounts like the pot, stacks and Call shown in?",
                     "criteria": ["BB": "Big blinds, amounts end in BB", "$": "Dollars or currency amounts", "chips": "Plain chip counts with no unit"]],
            "game": ["type": "choice", "instructions": "In image `shot`, which poker game is this table playing?",
                     "criteria": ["holdem": "Texas Hold'em, two hole cards", "omaha": "Omaha, four hole cards", "other": "Another poker variant"]],
            "format": ["type": "choice", "instructions": "In image `shot`, is this a cash game or a tournament?",
                       "criteria": ["cash": "Cash game, blinds stay the same", "tournament": "Tournament, blinds rise, places paid"]],
            "seats": ["type": "choice", "instructions": "In image `shot`, how many seats does the table have in total?",
                      "criteria": ["2": "Heads-up, 2 seats", "6": "6 seats", "9": "9 or 10 seats"]],
            "blinds_box": ["type": "box", "instructions": "the blinds or stakes display (like 250/500 or $1/$2) in `shot`"],
        ]
        var body = asset(jpegB64); body["questions"] = q
        let raw = try await post(body)
        let a = raw["answers"] as? [String: Any] ?? [:]
        func choice(_ n: String) -> String? { (a[n] as? [String: Any])?["choice"] as? String }
        var info = TableInfo()
        info.unit = choice("unit") ?? info.unit
        info.game = choice("game") ?? info.game
        info.format = choice("format") ?? info.format
        info.seats = choice("seats") ?? info.seats
        info.blindsBox = (a["blinds_box"] as? [String: Any])?["box"] as? [String: Double]
        return info
    }

    static func detect(jpegB64: String, prev: GameSchema) async throws -> DetectResult {
        let known = "Previous: hero \(prev.hero.joined(separator: " ")), board \(prev.board.joined(separator: " "))."
        let q: [String: Any] = [
            "board_changed": ["type": "noul", "instructions": "In image `shot`, are the face-up board cards different from before? \(known)"],
            "hero_changed": ["type": "noul", "instructions": "In image `shot`, are the hero hole cards different or a new hand? \(known)"],
            "pot_changed": ["type": "noul", "instructions": "In image `shot`, has the pot or a bet facing the hero changed? \(known)"],
            "hero_turn": ["type": "noul", "instructions": "In image `shot`, is it now the hero's turn?"],
        ]
        var body = asset(jpegB64); body["questions"] = q
        let raw = try await post(body)
        let a = raw["answers"] as? [String: Any] ?? [:]
        func noul(_ n: String) -> Double { (a[n] as? [String: Any])?["noul"] as? Double ?? 0 }
        let b = noul("board_changed"), h = noul("hero_changed"), p = noul("pot_changed"), t = noul("hero_turn")
        return DetectResult(changed: b > 0.6 || p > 0.75 || h > 0.9, board: b, hero: h, pot: p, turn: t)
    }
}
