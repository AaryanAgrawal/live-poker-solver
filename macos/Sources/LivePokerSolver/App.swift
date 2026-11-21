import AppKit
import ScreenCaptureKit
import SwiftUI

@main
struct LivePokerSolverApp: App {
    @StateObject private var state = AppState()
    init() { if CommandLine.arguments.contains("--selftest") { SelfTest.run() } }
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
    @Published var tableInfo: Jev.TableInfo?
    @Published var blindsCrop: NSImage?
    @Published var sbText = ""
    @Published var bbText = ""
    private var lastB64 = ""
    @Published var advice: Advice?
    @Published var preview: NSImage?
    @Published var potCrop: NSImage?
    private var lastSchema: GameSchema?
    private var lastFingerprint: [UInt8]?
    private var watchTask: Task<Void, Never>?
    private var panel: NSPanel?

    var selectedWindow: SCWindow? { windows.first { $0.id == selectedID }?.window }

    func refreshWindows() async {
        do { windows = try await Capture.listWindows()
             if selectedID == 0 { selectedID = windows.first?.id ?? 0 } }
        catch { status = "Window list failed: allow Screen Recording for this app in System Settings → Privacy & Security, then Refresh. (\(error.localizedDescription))" }
    }

    func toggleWatch() { watching ? stopWatch() : startWatch() }

    func startWatch() {
        guard let window = selectedWindow else { status = "Pick a window first (Refresh if the list is empty)."; return }
        watching = true
        showPanel()
        watchTask = Task { [weak self] in
            while let self = self, self.watching, !Task.isCancelled {
                await self.tick(window)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        _ = window
    }

    func stopWatch() {
        watching = false
        watchTask?.cancel()
        status = "Stopped."
        panel?.title = "Live Poker Solver"
    }

    private func tick(_ window: SCWindow) async {
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
                if diff < 0.01 {
                    status = "Watching — no board change."
                    return
                }
            }
            if let prev = lastSchema {
                let d = try await Jev.detect(jpegB64: b64, prev: prev)
                status = "Change check: board \(Int(d.board * 100))%, new hand \(Int(d.hero * 100))%, pot \(Int(d.pot * 100))%\(d.turn > 0.5 ? " — your turn" : "")."
                if !d.changed { lastFingerprint = fp; return }
            }
            status = "Reading table with Jev…"
            let schema = try await Jev.scan(jpegB64: b64)
            lastSchema = schema
            lastFingerprint = fp
            if !schema.hero.isEmpty { heroText = schema.hero.joined() }
            boardText = schema.board.joined()
            opponents = schema.opponents
            if let box = schema.potBox { potCrop = Capture.crop(image, box: box) }
            let ocr = OCR.amounts(image)
            if let pot = ocr.pot { potText = num(pot) }
            if (schema.facingBet ?? 0) > 0.5, let call = ocr.call { callText = num(call) }
            else if (schema.facingBet ?? 1) <= 0.5 { callText = "0" }
            status = "Jev read: \(schema.hero.joined(separator: " ")) · board \(schema.board.joined(separator: " ")) · vs \(schema.opponents) · unit \(schema.unit)"
                + (schema.lowConfidence.isEmpty ? "" : " · CHECK: \(schema.lowConfidence.joined(separator: ", "))")
                + (Double(potText) == nil ? " · type the pot, then Solve." : "")
            if Double(potText) != nil { solve() }
        } catch {
            status = "Watch error: \(error.localizedDescription)"
        }
    }

    func solve() {
        let hero = parseCards(heroText), board = parseCards(boardText)
        guard hero.count == 2, [0, 3, 4, 5].contains(board.count), let pot = Double(potText) else {
            status = "Solve needs 2 hero cards, a 0/3/4/5-card board, and a pot."; return
        }
        let toCall = Double(callText) ?? 0, stack = Double(stackText)
        let opponentsValue = opponents
        status = "Solving…"
        Task.detached(priority: .userInitiated) {
            let result = analyse(hero: hero, board: board, pot: pot, toCall: toCall, opponents: opponentsValue, stack: stack)
            await MainActor.run { [weak self] in self?.advice = result; self?.status = "Solved (\(result.method), \(result.samples) hands)." }
        }
    }

    func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 200, y: 600, width: 620, height: 150),
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

struct ContentView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Poker Solver").font(.title2).bold()
            HStack {
                Picker("Window", selection: $s.selectedID) {
                    ForEach(s.windows) { w in Text(w.label).tag(w.id) }
                }.frame(maxWidth: 420)
                Button("Refresh") { Task { await s.refreshWindows() } }
                Button(s.watching ? "Stop" : "▶ Watch my table") { s.toggleWatch() }
                Button("Pin bar") { s.showPanel() }
            }
            Text(s.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let img = s.preview { Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 170) }
            if let info = s.tableInfo {
                HStack { Text("Table: \(info.line)").foregroundStyle(.secondary)
                         TextField("SB", text: $s.sbText).frame(width: 60)
                         TextField("BB", text: $s.bbText).frame(width: 60)
                         if let bc = s.blindsCrop { Image(nsImage: bc).resizable().scaledToFit().frame(maxHeight: 36) } }
            }
            if let crop = s.potCrop {
                HStack { Text("Pot (type it):").foregroundStyle(.secondary); Image(nsImage: crop).resizable().scaledToFit().frame(maxHeight: 44) }
            }
            HStack {
                TextField("Hero AhKd", text: $s.heroText).frame(width: 100)
                TextField("Board Qs7h2c", text: $s.boardText).frame(width: 120)
                TextField("Pot", text: $s.potText).frame(width: 70)
                TextField("To call", text: $s.callText).frame(width: 70)
                TextField("Stack", text: $s.stackText).frame(width: 70)
                Text(s.unit).foregroundStyle(.secondary)
                Button("Solve") { s.solve() }
            }.textFieldStyle(.roundedBorder)
            if let a = s.advice { AdviceView(a: a) }
            Text("Call-safe: this app reads only the window you pick; the bar is hidden from shares and recordings. GTO-style equity, not a full solver. Check your site's rules.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 680)
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

func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

struct AdviceView: View {
    let a: Advice
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a.fraction != nil ? "\(a.action) \(String(format: "%g", a.fraction!))x pot — put in \(num(a.amount)) \(s.unit)"
                 : a.action == "CALL" ? "CALL \(num(a.amount)) \(s.unit)" : a.action)
                .font(.title).bold().foregroundStyle(.yellow)
            Text("Win \(Int((a.equity * 100).rounded()))% · Need \(Int((a.needed * 100).rounded()))% · Call EV \(a.evCall >= 0 ? "+" : "")\(Int(a.evCall.rounded())) · \(a.hand)\(a.draw != nil ? " + \(a.draw!)" : "")\(a.outs > 0 ? " · ~\(a.outs) outs" : "")\(a.spr != nil ? " · SPR \(a.spr!)" : "") · vs \(a.villain) range")
            Text(a.why).foregroundStyle(.secondary)
            Text("Sizes: " + a.sizes.map { "\(String(format: "%g", $0.0))x=\(num($0.1))" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OverlayView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("⠿ LIVE PLAY").font(.caption).foregroundStyle(.gray); Spacer(); Text(s.watching ? "watching" : "").font(.caption).foregroundStyle(.gray) }
            if let a = s.advice {
                Text(a.fraction != nil ? "\(a.action) \(String(format: "%g", a.fraction!))x pot — put in \(num(a.amount)) \(s.unit)"
                     : a.action == "CALL" ? "CALL \(num(a.amount)) \(s.unit)" : a.action)
                    .font(.system(size: 26, weight: .heavy)).foregroundStyle(.yellow)
                Text("Win \(Int((a.equity * 100).rounded()))% · Need \(Int((a.needed * 100).rounded()))% · EV \(a.evCall >= 0 ? "+" : "")\(Int(a.evCall.rounded())) · \(a.hand)\(a.draw != nil ? " + \(a.draw!)" : "")")
                    .foregroundStyle(.white)
                Text(a.why).font(.caption).foregroundStyle(.gray).lineLimit(2)
            } else {
                Text(s.status).foregroundStyle(.white).lineLimit(3)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.92))
    }
}
