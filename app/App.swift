// SPDX-License-Identifier: GPL-2.0-or-later
// Canon MF4780w Print & Scan: app, window and menu-bar status.

import AppKit
import Combine
import ServiceManagement
import SwiftUI


// MARK: - Live state → PanelModel

extension PanelModel {
    static func live(_ b: Bridge, _ s: ScanController, now: Date = Date()) -> PanelModel {
        var m = PanelModel()
        m.toner = b.toner
        m.pages = b.pageCount
        m.address = b.printerAddress
        m.airPrint = b.serverRunning ? .available(added: b.queueAdded) : .starting
        m.scanName = s.listedAs
        m.lastScan = s.lastScan?.lastPathComponent
        if let e = b.events.last(where: { $0.kind != .info }) {
            let notable = e.kind != .ok || e.text.hasPrefix("Saved") || e.text.hasPrefix("Job ")
            let lifetime: TimeInterval = e.kind == .ok ? 30 : 300
            if notable && now.timeIntervalSince(e.time) < lifetime {
                m.notice = .init(text: e.text, isError: e.kind != .ok)
                m.noticeExpiry = e.time.addingTimeInterval(lifetime)
            }
        }

        if let phase = s.phase {
            m.tone = .scanning
            m.title = "Scanning"
            m.activity = true
            m.canCancel = true
            switch phase {
            case .starting:
                m.detail = "Starting the scan…"
            case .scanning(let feeder, let pages):
                m.detail = (feeder ? "From the feeder" : "From the glass") + (pages > 0 ? " · page \(pages) done" : "")
            }
        } else if let job = b.activeJob {
            if let problem = b.problem {
                m.tone = .warning
                m.title = problem
                m.detail = "“\(job)” continues once that is fixed"
            } else {
                m.tone = .printing
                m.title = "Printing"
                m.activity = true
                if let total = b.jobPagesTotal, total > 0 {
                    let printed = min(b.jobPagesPrinted, total)
                    m.detail = "“\(job)” · page \(min(printed + 1, total)) of \(total)"
                    m.progress = Double(printed) / Double(total)
                } else {
                    m.detail = "“\(job)”" + (b.jobPagesSent > 0 ? " · sending page \(b.jobPagesSent)" : "")
                }
            }
        } else if let problem = b.problem {
            let advice = Self.advice[problem]
            m.tone = advice?.blocking == false ? .warning : .error
            m.title = problem
            m.detail = advice?.text ?? "Check the printer's display"
        } else if !b.serverRunning || !b.searched {
            m.tone = .asleep
            m.title = b.serverRunning ? "Looking for the printer…" : "Starting…"
            m.activity = true
        } else if let state = b.printerState {
            switch state {
            case "other":
                m.tone = .asleep
                m.title = "Ready"
                m.detail = "Asleep — wakes up for print jobs and scans"
            case "warmup":
                m.title = "Ready"
                m.detail = "Warming up"
            case "printing":
                m.tone = .printing
                m.title = "Busy"
                m.detail = "Printing or copying"
                m.activity = true
            default:
                m.title = "Ready"
                m.detail = "Print from any app, or scan from the printer"
            }
        } else {
            m.tone = .offline
            m.title = "Not found"
            m.detail = "Is the printer on and connected to this network?"
        }
        return m
    }

    private static let advice: [String: (text: String, blocking: Bool)] = [
        "Paper jam": ("Open the printer and remove the jammed paper", true),
        "Cover open": ("Close the printer's cover", true),
        "Out of paper": ("Load paper into the drawer", true),
        "Out of toner": ("Replace the Canon 728 cartridge", true),
        "Printer needs attention": ("Check the printer's display", true),
        "Paper drawer missing": ("Push the paper drawer back in", true),
        "Printer offline": ("The printer is offline", false),
        "A paper tray is empty": ("One paper tray is empty", false),
        "Paper low": ("Paper is running low", false),
        "Toner low": ("Order a Canon 728 cartridge soon", false),
    ]
}

// MARK: - Window

struct LivePanel: View {
    @ObservedObject var bridge = Bridge.shared
    @ObservedObject var scan = ScanController.shared

    var body: some View {
        // redrawn when the state changes, and once more when a notice should go
        let expiry = PanelModel.live(bridge, scan).noticeExpiry
        TimelineView(.explicit(expiry.map { [$0] } ?? [])) { context in
            PanelView(model: .live(bridge, scan, now: context.date), actions: PanelActions(
                cancelScan: { scan.cancelScan() },
                openLastScan: { if let url = scan.lastScan { NSWorkspace.shared.open(url) } },
                addToMac: { bridge.addQueue() },
                openPrinterSettings: { openPrinterSettings() }
            ))
        }
        .ignoresSafeArea()
    }
}

/// The panel window: exactly the panel's size, content under a transparent title
/// bar, draggable by its background. While it is open (or minimized) the app is in
/// the Dock; closing it leaves only the menu-bar icon.
final class PanelWindow: NSObject, NSWindowDelegate {
    static let shared = PanelWindow()
    private var window: NSWindow?

    func show() {
        Bridge.shared.refreshQueue()                      // "Add to Mac" or the check mark
        Bridge.shared.refreshPrinter()                    // fresh status, then every 30 s while open
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: PanelView.size),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = printerName
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenNone]
            w.delegate = self
            w.contentView = Self.content()
            // the content fills the whole frame (title bar included): size the frame,
            // keeping a remembered position
            let restored = w.setFrameUsingName("Panel")
            var frame = w.frame
            frame.origin.y += frame.height - PanelView.size.height
            frame.size = PanelView.size
            w.setFrame(frame, display: false)
            if !restored { w.center() }
            w.setFrameAutosaveName("Panel")
            window = w
        }
        if window?.contentView == nil { window?.contentView = Self.content() }
        #if SOAK
        window?.alphaValue = 0                            // rendered, but invisible and never in the way
        window?.ignoresMouseEvents = true
        window?.orderFrontRegardless()
        #else
        NSApp.setActivationPolicy(.regular)               // back in the Dock
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)        // again, once the Dock knows the app
            self?.window?.makeKeyAndOrderFront(nil)
            self?.fitFrame()
        }
        #endif
    }

    private static func content() -> NSView {
        let host = NSHostingView(rootView: LivePanel())
        host.sizingOptions = []
        return host
    }

    /// Closed (not minimized): leave the Dock, keep the menu-bar icon. The views go
    /// too, so nothing is redrawn while the panel isn't shown.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window?.contentView = nil
        DispatchQueue.main.async { Bridge.shared.schedulePoll() }   // back to the slower polls
    }

    /// Size the frame (title bar included) to the panel; the hosting view may have
    /// grown the window by the title bar's height when it appeared.
    private func fitFrame() {
        guard let w = window, w.frame.size != PanelView.size else { return }
        var frame = w.frame
        frame.origin.y += frame.height - PanelView.size.height
        frame.size = PanelView.size
        w.setFrame(frame, display: true)
    }

    var isVisible: Bool { window?.isVisible == true }

    #if SOAK
    func close() { window?.close() }
    #endif
}

func openPrinterSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Menu bar

/// One status item, made once: its symbol follows the printer's state and its
/// menu is built when it opens. While a job prints, macOS 27's Print Center shows
/// its own printer icon in the menu bar (a Live Activity), so this one steps aside
/// to keep a single icon.
final class StatusItem: NSObject, NSMenuDelegate {
    static let shared = StatusItem()
    private var item: NSStatusItem?
    private var updates: AnyCancellable?
    private var symbol = ""

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "CanonMF4780wStatus"        // keeps its place while hidden
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        refresh()
        updates = Bridge.shared.objectWillChange.map { _ in () }
            .merge(with: ScanController.shared.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let m = PanelModel.live(Bridge.shared, ScanController.shared)
        #if SOAK
        let visible = false
        #else
        let visible = Bridge.shared.activeJob == nil
        #endif
        if item?.isVisible != visible { item?.isVisible = visible }
        let tip = "\(printerName) — \(m.title)"
        if item?.button?.toolTip != tip { item?.button?.toolTip = tip }
        guard m.tone.symbol != symbol else { return }
        symbol = m.tone.symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: m.title)
        image?.isTemplate = true
        item?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = PanelModel.live(Bridge.shared, ScanController.shared)
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ key: String = "", _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = handler
            menu.addItem(item)
        }
        info("\(printerName) — \(m.title)")
        if !m.detail.isEmpty { info(m.detail) }
        if let toner = m.toner { info("Toner \(toner)%") }
        menu.addItem(.separator())
        if m.canCancel { action("Cancel Scan") { ScanController.shared.cancelScan() } }
        if let url = ScanController.shared.lastScan { action("Open Last Scan") { NSWorkspace.shared.open(url) } }
        action("Show \(printerName)") { PanelWindow.shared.show() }
        action("Printers & Scanners…") { openPrinterSettings() }
        menu.addItem(.separator())
        action("Open at Login") { LoginItem.toggle() }
        menu.items.last?.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(.separator())
        action("Quit", "q") { NSApp.terminate(nil) }
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}

// MARK: - Open at Login

/// The app as a login item (System Settings → General → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        set(!isEnabled)
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Bridge.shared.note(.error, "Open at Login: \(error.localizedDescription)")
        }
        // the user switched it off in System Settings before: they have to allow it there
        if on && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isEnabled == on
    }

    /// Launched by macOS at login (then the app starts in the menu bar, without its window).
    static var launchedAtLogin = false

    static func noteLaunchEvent() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

// MARK: - App

enum MainMenu {
    static func build() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? printerName
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = app

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return main
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?
    private var quitBySignal = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        LoginItem.noteLaunchEvent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quit cleanly on SIGTERM too (logout, kill): stop the server and withdraw the advert.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.quitBySignal = true
            NSApp.terminate(nil)
        }
        source.resume()
        sigterm = source
        Bridge.shared.start()
        ScanController.shared.start()
        StatusItem.shared.start()
        #if SOAK
        // -SoakPanelToggle N: open and close the (invisible) panel every N seconds
        let toggle = UserDefaults.standard.double(forKey: "SoakPanelToggle")
        if toggle > 0 {
            PanelWindow.shared.show()
            Timer.scheduledTimer(withTimeInterval: toggle, repeats: true) { _ in
                if PanelWindow.shared.isVisible { PanelWindow.shared.close() } else { PanelWindow.shared.show() }
            }
        }
        #else
        // opened at login, or with --menu-bar-only: no panel, just the menu-bar icon
        if !LoginItem.launchedAtLogin && !CommandLine.arguments.contains("--menu-bar-only") { PanelWindow.shared.show() }
        #endif
    }

    /// Closing the window keeps the app (and the printer) running in the Dock and menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon clicked (or the app opened again): bring the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !PanelWindow.shared.isVisible { PanelWindow.shared.show() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if SOAK
        return .terminateNow
        #else
        // logout, restart, shutdown or SIGTERM: never hold them up with a question
        let byUser = !(quitBySignal || Self.systemIsQuitting)
        if byUser, let busy = Bridge.shared.activeJob.map({ "“\($0)” is still being sent to the printer." })
            ?? (ScanController.shared.scanning ? "A scan is in progress." : nil) {
            NSApp.activate(ignoringOtherApps: true)        // also when only in the menu bar
            let alert = NSAlert()
            alert.messageText = busy
            alert.informativeText = "If you quit now, it may be lost."
            alert.addButton(withTitle: "Keep Going")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        // a scan's PDF is being written: a few seconds, then quit (15 s at most)
        guard ScanController.shared.saving > 0 else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        ScanController.shared.whenSaved(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: reply)
        return .terminateLater
        #endif
    }

    /// macOS's quit event at logout, restart and shutdown carries the reason.
    private static var systemIsQuitting: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEQuitApplication,
              let why = event.attributeDescriptor(forKeyword: kAEQuitReason) ?? event.paramDescriptor(forKeyword: kAEQuitReason)
        else { return false }
        return [kAEQuitAll, kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
            .contains(why.typeCodeValue)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScanController.shared.stop()
        Bridge.shared.stop()
    }
}

@main
enum Main {
    private static let delegate = AppDelegate()

    static func main() {
        // `--login-item on|off|status`: manage Open at Login from a script, then exit
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            if args[i + 1] != "status" { LoginItem.set(args[i + 1] == "on") }
            print(SMAppService.mainApp.status == .enabled ? "on" : SMAppService.mainApp.status == .requiresApproval ? "needs approval" : "off")
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)                // the panel brings the Dock icon
        app.mainMenu = MainMenu.build()
        app.run()
    }
}
