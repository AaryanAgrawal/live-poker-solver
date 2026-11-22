import AppKit
import ScreenCaptureKit
import SwiftUI

@main
struct LivePokerSolverApp: App {
    @StateObject private var state = AppState()
    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.run() }
        if let i = args.firstIndex(of: "--solve"), args.count >= i + 6 {
            let out = CFRSolver.solve(hero: parseCards(args[i + 1]), board: parseCards(args[i + 2]),
                                      pot: Double(args[i + 3]) ?? 100, toCall: Double(args[i + 4]) ?? 0,
                                      stack: Double(args[i + 5]), villainKind: (Double(args[i + 4]) ?? 0) > 0 ? "bet" : "any")!
            for s in out.strategy {
                print(s.action, s.put, String(format: "%.0f%%", s.freq * 100), "ev", String(format: "%.1f", s.ev))
            }
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("Live Poker Solver") { ContentView().environmentObject(state) }
            .windowResizability(.contentSize)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var windows: [PokerWindow] = []
    @Published var selectedID: CGWindowID = 0
    let testMode = CommandLine.arguments.contains("--live-test")
    @Published var watching = false
    @Published var status = "Pick your poker window, then Watch." {
        didSet { if testMode {
            let line = status + "\n"
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/live-solver.log")) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else { try? line.write(toFile: "/tmp/live-solver.log", atomically: true, encoding: .utf8) }
        } }
    }
    @Published var heroText = ""
    @Published var boardText = ""
    @Published var potText = ""
    @Published var callText = ""
    @Published var stackText = ""
    @Published var unit = "chips"
    @Published var opponents = 1
    @Published var lastRead = ""
    @Published var uiScale: Double = max(0.7, min(1.8, UserDefaults.standard.double(forKey: "uiScale") == 0 ? 1 : UserDefaults.standard.double(forKey: "uiScale")))
    func setScale(_ v: Double) {
        uiScale = max(0.7, min(1.8, v))
        UserDefaults.standard.set(uiScale, forKey: "uiScale")
        panel?.setContentSize(NSSize(width: 780 * uiScale, height: 230 * uiScale))
    }
    @Published var tableInfo: Jev.TableInfo?
    @Published var blindsCrop: NSImage?
    @Published var sbText = ""
    @Published var bbText = ""
    private var lastB64 = ""
    @Published var advice: Advice?
    @Published var preview: NSImage?
    @Published var potCrop: NSImage?
    private var lockedID: CGWindowID?
    private var searchQueue: [PokerWindow]?
    private var emptyReads = 0
    private var lastSchema: GameSchema?
    private var lastFingerprint: [UInt8]?
    private var detectMisses = 0
    private var watchTask: Task<Void, Never>?
    private var panel: NSPanel?
    private weak var mainWindow: NSWindow?

    var selectedWindow: SCWindow? { windows.first { $0.id == selectedID }?.window }

    func refreshWindows() async {
        do { windows = try await Capture.listWindows()
             if selectedID == 0 || !windows.contains(where: { $0.id == selectedID }) {
                 let saved = UserDefaults.standard.string(forKey: "lastWindowLabel")
                 selectedID = windows.first { $0.label == saved }?.id ?? windows.first?.id ?? 0
             } }
        catch { status = "Window list failed: allow Screen Recording for this app in System Settings → Privacy & Security, then Refresh. (\(error.localizedDescription))" }
    }

    func toggleWatch() { watching ? stopWatch() : startWatch() }

    func useWindow(_ id: CGWindowID) {
        selectedID = id
        if watching { lockedID = id }
        if let w = windows.first(where: { $0.id == id }) {
            UserDefaults.standard.set(w.label, forKey: "lastWindowLabel")
        }
    }

    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) }) { w.makeKeyAndOrderFront(nil) }
    }

    func startWatch() {
        guard !windows.isEmpty else { status = "No windows yet — press Refresh, or open your game first."; return }
        let window = selectedWindow
        watching = true
        if selectedID != 0 { lockedID = selectedID }
        showPanel()
        mainWindow = NSApp.windows.first { !($0 is NSPanel) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.mainWindow?.orderOut(nil) }
        watchTask = Task { [weak self] in
            while let self = self, self.watching, !Task.isCancelled {
                await self.autoTick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        _ = window
    }

    func stopWatch() {
        watching = false
        watchTask?.cancel()
        lockedID = nil
        status = "Stopped."
        panel?.title = "Live Poker Solver"
    }

    /// Find the poker window by itself: score every window locally (fast, no
    /// Jev), then let Jev confirm only the best-looking candidates.
    private func autoTick() async {
        if windows.isEmpty { await refreshWindows() }
        guard !windows.isEmpty else { status = "No windows to look in. Open your poker game, then Watch."; return }
        if let lockedID = lockedID, let w = windows.first(where: { $0.id == lockedID }) {
            await tick(w.window)
            return
        }
        if searchQueue == nil {
            let deny = ["Dock", "Notification", "WindowManager", "Control Center", "Spotlight", "loginwindow", "ScreenSaver", "Wallpaper"]
            let cands = windows.filter { w in
                w.window.frame.width > 500 && w.window.frame.height > 350 && !deny.contains { w.appName.contains($0) }
            }.sorted { $0.window.frame.width * $0.window.frame.height > $1.window.frame.width * $1.window.frame.height }
            let keywords = ["poker", "youtube", "ggpoker", "pokerstars", "wsop", "holdem", "hold'em"]
            var scored: [(PokerWindow, Double)] = []
            for cand in cands {
                if let img = try? await Capture.capture(cand.window) {
                    let boost = keywords.contains { cand.label.lowercased().contains($0) } ? 0.5 : 0.0
                    scored.append((cand, Capture.feltScore(img) + boost))
                }
            }
            searchQueue = scored.sorted { $0.1 > $1.1 }.filter { $0.1 > 0.08 }.map { $0.0 }
            status = searchQueue!.isEmpty
                ? "No poker table found. Put your poker game in its OWN Chrome tab and make that the visible tab — I can only see the front tab. I will keep looking."
                : "Found \(searchQueue!.count) possible table(s). Confirming with Jev…"
            return
        }
        guard var queue = searchQueue, !queue.isEmpty else { searchQueue = nil; return }
        heartbeat()
        let cand = queue.removeFirst()
        searchQueue = queue
        do {
            let image = try await Capture.capture(cand.window)
            preview = Capture.nsImage(image)
            guard let data = Capture.jpeg(image) else { return }
            status = "Checking \(cand.label)…"
            let schema = try await scanSmart(image, fullB64: data.base64EncodedString())
            if schema.tables == "multiple" {
                status = "That screen has several tables tiled. Make ONE table fill its window and I will read it."
            } else if schema.hero.count == 2 {
                lockedID = cand.id; selectedID = cand.id; emptyReads = 0; searchQueue = nil
                status = "Found your table: \(cand.label). Reading it live…"
                await tick(cand.window)
            } else {
                status = "Not a poker hand there. Still looking…"
            }
        } catch {
            status = "Still looking for your poker table… (\(error.localizedDescription))"
        }
    }

    private func tick(_ window: SCWindow) async {
        heartbeat()
        guard let current = windows.first(where: { $0.id == selectedID })?.window ?? selectedWindow else { return }
        do {
            let image = try await Capture.capture(current)
            preview = Capture.nsImage(image)
            if let d = Capture.jpeg(image) { lastB64 = d.base64EncodedString() }
            if tableInfo == nil {
                status = "First pass: learning this table (units, blinds, game)…"
                let info = try await Jev.tableInfo(jpegB64: lastB64)
                tableInfo = info; unit = info.unit
                if let box = info.blindsBox {
                    blindsCrop = Capture.crop(image, box: box)
                    if let cg = Capture.cropCG(image, box: box) {
                        let nums = OCR.numbers(cg)
                        if nums.count >= 2 { sbText = num(nums[0]); bbText = num(nums[1]) }
                    }
                }
                status = "Table: \(info.line). Type the blinds from the crop, then play."
            }
            guard let data = Capture.jpeg(image), let b64 = Optional(data.base64EncodedString()) else { return }
            let fp = Capture.fingerprint(image)
            if let last = lastFingerprint, lastSchema != nil {
                let diff = Capture.diffRatio(last, fp)
                if diff < 0.025 {
                    status = "Watching — no board change."
                    return
                }
            }
            let bigChange = lastFingerprint.map { Capture.diffRatio($0, fp) > 0.35 } ?? false
            if let prev = lastSchema, !bigChange {
                let d = try await Jev.detect(jpegB64: b64, prev: prev)
                status = "Change check: board \(Int(d.board * 100))%, new hand \(Int(d.hero * 100))%, pot \(Int(d.pot * 100))%\(d.turn > 0.5 ? " — your turn" : "")."
                if !d.changed {
                    detectMisses += 1
                    if detectMisses < 3 { lastFingerprint = fp; return }
                    status = "Change gate unsure 3 times — re-reading the table."
                }
            }
            detectMisses = 0
            status = "Reading table with Jev…"
            let schema = try await scanSmart(image, fullB64: b64)
            if schema.tables == "multiple" {
                status = "Several tables on screen — make ONE table big and I will read just that one."
                return
            }
            if schema.hero.isEmpty {
                emptyReads += 1
                if emptyReads >= 2 { lockedID = nil; lastSchema = nil; status = "Lost the poker table — looking again…"; return }
            } else { emptyReads = 0 }
            lastSchema = schema
            lastFingerprint = fp
            if !schema.hero.isEmpty { heroText = schema.hero.joined() }
            boardText = schema.board.joined()
            opponents = schema.opponents
            if let box = schema.potBox { potCrop = Capture.crop(image, box: box) }
            let ocr = OCR.amounts(image)
            let stackGuess = Double(stackText) ?? .infinity
            if let pot = ocr.pot, pot > 0, pot < stackGuess * 100 { potText = num(pot) }
            if (schema.facingBet ?? 0) > 0.5, let call = ocr.call, call <= stackGuess { callText = num(call) }
            else if (schema.facingBet ?? 1) <= 0.5 { callText = "0" }
            let unsureHero = schema.lowConfidence.contains("hero1") || schema.lowConfidence.contains("hero2")
            status = "Jev read: \(schema.hero.joined(separator: " ")) · board \(schema.board.joined(separator: " ")) · vs \(schema.opponents) · unit \(schema.unit)"
                + (unsureHero ? " — Jev is UNSURE about your cards: check them, then Solve." : "")
                + (schema.lowConfidence.isEmpty ? "" : " · CHECK: \(schema.lowConfidence.joined(separator: ", "))")
                + (Double(potText) == nil ? " · type the pot, then Solve." : "")
            if Double(potText) != nil && !unsureHero { solve() }
        } catch {
            if lockedID != nil { lockedID = nil; lastSchema = nil; searchQueue = nil; status = "That window closed — looking for your table again…" }
            else { status = "Watch error: \(error.localizedDescription)" }
        }
    }

    /// Scan the table crop (cards big) instead of the whole window (cards tiny).
    func scanSmart(_ image: CGImage, fullB64: String) async throws -> GameSchema {
        if let box = Capture.tableBox(image), let cg = Capture.cropCG(image, box: box), let data = Capture.jpeg(cg, quality: 0.85) {
            var schema = try await Jev.scan(jpegB64: data.base64EncodedString())
            if let pot = schema.potBox, let l = box["left"], let t = box["top"], let w = box["right"].map({ $0 - l }), let h = box["bottom"].map({ $0 - t }) {
                schema.potBox = ["left": l + (pot["left"] ?? 0) * w, "right": l + (pot["right"] ?? 0) * w,
                                 "top": t + (pot["top"] ?? 0) * h, "bottom": t + (pot["bottom"] ?? 0) * h]
            }
            if schema.hero.count == 2 { return schema }
        }
        return try await Jev.scan(jpegB64: fullB64)
    }

    func heartbeat() {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lastRead = f.string(from: Date())
    }

    func solve() {
        let hero = parseCards(heroText), board = parseCards(boardText)
        guard hero.count == 2, [0, 3, 4, 5].contains(board.count), let pot = Double(potText) else {
            status = "Solve needs 2 hero cards, a 0/3/4/5-card board, and a pot."; return
        }
        let toCall = Double(callText) ?? 0, stack = Double(stackText)
        let opponentsValue = toCall > 0 ? 1 : max(1, opponents)
        status = "Solving…"
        Task.detached(priority: .userInitiated) {
            let result = analyse(hero: hero, board: board, pot: pot, toCall: toCall, opponents: opponentsValue, stack: stack)
            await MainActor.run { [weak self] in self?.advice = result; self?.status = "Solved (\(result.method), \(result.samples) hands)." }
        }
    }

    func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 140, y: 560, width: 780 * uiScale, height: 230 * uiScale),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isMovableByWindowBackground = true
            p.sharingType = .none // never visible in call shares or recordings
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .black
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: OverlayView().environmentObject(self))
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

func spacedCards(_ text: String) -> String {
    let c = text.replacingOccurrences(of: " ", with: "")
    guard !c.isEmpty else { return "—" }
    return stride(from: 0, to: c.count, by: 2).map { i in
        String(c[c.index(c.startIndex, offsetBy: i)..<c.index(c.startIndex, offsetBy: min(i + 2, c.count))])
    }.joined(separator: " ")
}

struct ContentView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Poker Solver").font(.largeTitle).bold()
            HStack {
                Picker("Window", selection: $s.selectedID) {
                    ForEach(s.windows) { w in Text(w.label).tag(w.id) }
                }.frame(maxWidth: 430)
                .onChange(of: s.selectedID) { id in s.useWindow(id) }
                Button("Refresh") { Task { await s.refreshWindows() } }
            }
            HStack {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Button("A−") { s.setScale(s.uiScale - 0.1) }
                Text("\(Int((s.uiScale * 100).rounded()))%").font(.caption).monospacedDigit()
                Button("A+") { s.setScale(s.uiScale + 0.1) }
            }
            Text("Pick your Chrome poker window above, or just press Watch and I will look for it.")
                .font(.caption).foregroundStyle(.secondary)
            Button(s.watching ? "■ Stop" : "▶ Watch my table") { s.toggleWatch() }
                .font(.title3).bold()
            Text(s.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("You: \(spacedCards(s.heroText)) · Board: \(spacedCards(s.boardText))\(s.potText.isEmpty ? "" : " · Pot \(s.potText) \(s.unit)")\(s.callText.isEmpty || s.callText == "0" ? "" : " · To call \(s.callText) \(s.unit)")\(s.lastRead.isEmpty ? "" : " · read \(s.lastRead)")")
                .font(.caption).foregroundStyle(.secondary)
            if let a = s.advice { AdviceView(a: a) }
            Text("Keep your poker game in its own visible tab. The bar floats on top and stays out of call shares.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 780)
        .task {
            await s.refreshWindows()
            if s.testMode {
                if let chrome = s.windows.filter({ $0.appName.contains("Chrome") }).max(by: { $0.window.frame.width * $0.window.frame.height < $1.window.frame.width * $1.window.frame.height }) {
                    s.selectedID = chrome.id
                    s.status = "Test: picked \(chrome.label)"
                } else {
                    s.status = "Test: no Chrome window in list (\(s.windows.count) windows)"
                }
                s.toggleWatch()
                Task { try? await Task.sleep(nanoseconds: 60_000_000_000); exit(0) }
            }
        }
    }
}

struct AdviceView: View {
    let a: Advice
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(a.fraction != nil ? "\(a.action) \(String(format: "%g", a.fraction!))x pot — \(num(a.amount)) \(s.unit)"
                 : a.action == "CALL" ? "CALL \(num(a.amount)) \(s.unit)" : a.action)
                .font(.system(size: 30, weight: .heavy)).foregroundStyle(.yellow)
            Text(a.handDetail + (a.draw != nil ? ", with a \(a.draw!)" : "")).font(.headline)
            if a.mix != a.action && !a.mix.isEmpty { Text("Solver mix: \(a.mix)").font(.caption).foregroundStyle(.secondary) }
            if let f = a.foldPct { Text("Opponents fold about \(Int((f * 100).rounded()))% to a play this size.").font(.caption).foregroundStyle(.secondary) }
            EquityBar(a: a)
            Text("Equity \(Int((a.equity * 100).rounded())) of 100" + (a.needed > 0 ? " — you need \(Int((a.needed * 100).rounded())) to make calling pay" : " — checking is free")
                 + ". Call earns \(a.evCall >= 0 ? "+" : "")\(num(a.evCall)) \(s.unit) in the long run.")
                .fixedSize(horizontal: false, vertical: true)
            if a.outs > 0 { Text("About \(a.outs) cards left that can improve you (outs).").foregroundStyle(.secondary) }
            if let d = a.danger { Text(d).foregroundStyle(.orange) }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One bar: green fill = your win share, white tick = what you need.
struct EquityBar: View {
    let a: Advice
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 6)
                    .fill(a.needed == 0 || a.equity >= a.needed ? Color.green : Color.red)
                    .frame(width: g.size.width * min(1, max(0, a.equity)))
                if a.needed > 0 {
                    Rectangle().fill(.white).frame(width: 2)
                        .offset(x: g.size.width * min(1, max(0, a.needed)))
                }
            }
        }.frame(height: 16)
    }
}

struct CardChip: View {
    let code: String
    var body: some View {
        let rank = code.first.map { $0 == "T" ? "10" : String($0) } ?? "?"
        let suit = code.last.map { ["s": "♠", "h": "♥", "d": "♦", "c": "♣"][$0] ?? "" } ?? ""
        let red = code.last == "h" || code.last == "d"
        Text("\(rank)\(suit)")
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(red ? Color.red : Color.black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct CardRow: View {
    let label: String, text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.gray).frame(width: 46, alignment: .leading)
            if text.isEmpty || text == "—" { Text("—").foregroundStyle(.gray) }
            else { ForEach(spacedCards(text).split(separator: " ").map(String.init), id: \.self) { CardChip(code: $0) } }
        }
    }
}

struct OverlayView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(spacedCards(s.heroText).split(separator: " ").map(String.init), id: \.self) { CardChip(code: $0) }
                Text("·").foregroundStyle(.gray)
                if s.boardText.isEmpty { Text("no board yet").font(.caption).foregroundStyle(.gray) }
                else { ForEach(spacedCards(s.boardText).split(separator: " ").map(String.init), id: \.self) { CardChip(code: $0) } }
                Spacer()
                Text(s.watching ? "●" : "").foregroundStyle(.green).font(.caption)
            }
            if let a = s.advice {
                Text(a.fraction != nil ? "\(a.action) \(String(format: "%g", a.fraction!))x pot — \(num(a.amount)) \(s.unit)"
                     : a.action == "CALL" ? "CALL \(num(a.amount)) \(s.unit)" : a.action)
                    .font(.system(size: 36, weight: .heavy)).foregroundStyle(.yellow)
                EquityBar(a: a)
                Text("Win \(Int((a.equity * 100).rounded()))" + (a.needed > 0 ? " · Need \(Int((a.needed * 100).rounded()))" : ""))
                    .font(.caption).foregroundStyle(.white)
            } else {
                Text(s.status).foregroundStyle(.white).lineLimit(2).font(.caption)
            }
            HStack {
                Spacer()
                Button("A−") { s.setScale(s.uiScale - 0.1) }.buttonStyle(.plain).font(.caption).foregroundStyle(.gray)
                Button("A+") { s.setScale(s.uiScale + 0.1) }.buttonStyle(.plain).font(.caption).foregroundStyle(.gray)
                Button("Main") { s.showMain() }.buttonStyle(.plain).font(.caption2).foregroundStyle(.gray)
                Button("Stop") { s.stopWatch() }.buttonStyle(.plain).font(.caption2).foregroundStyle(.gray)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.92))
        .scaleEffect(s.uiScale, anchor: .topLeading)
    }
}
