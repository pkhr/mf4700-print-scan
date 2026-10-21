// SPDX-License-Identifier: GPL-2.0-or-later
// Canon MF4780w Print & Scan: the printer side.
//
// While this app is open, the Canon MF4780w (a UFR II LT-only printer) is an
// AirPrint printer for this Mac only: the app runs macOS's built-in
// /usr/bin/ippeveprinter bound to localhost, advertises it with a local-only
// Bonjour registration, and every job is encoded by the bundled rastertoufr2lt
// and sent to the printer. Quitting stops the server and the advertisement.

import AppKit
import SwiftUI
import SystemConfiguration
import dnssd

#if SOAK
// Soak-test build (test/soak): its own name, port and folders, so it runs beside the
// real app, and timers 20x faster to compress days of polling into hours.
let appName = "MF4700 Soak Test"
let oldAppName = "MF4700 Soak Test (old)"
let printerName = "MF4700 Soak"
let queueName = "MF4700_Soak"
let preferredPort = 18631
let timeScale = 0.05
#else
let appName = "Canon MF4780w Print & Scan"
let oldAppName = "Canon MF4780w AirPrint"           // until v2.0; its data is moved over
let printerName = "Canon MF4780w"
let queueName = "Canon_MF4780w"
let preferredPort = 8631
let timeScale = 1.0
#endif
/// The printer's own Bonjour name first, then any MF4700-series printer on the network.
let defaultDevice = "dnssd://CanonMF4700 dnssd://*"

// MARK: - Activity log

struct Event: Identifiable {
    enum Kind { case info, ok, warning, error }
    let id = UUID()
    let time = Date()
    let text: String
    let kind: Kind
}

/// Keeps the Mac from idle-sleeping while a job prints or a scan runs: sleep
/// would cut the connection to the printer.
final class KeepAwake {
    private let reason: String
    private var activity: NSObjectProtocol?

    init(_ reason: String) { self.reason = reason }

    func hold(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}

// MARK: - Bridge: AirPrint server + Bonjour + printer status

final class Bridge: ObservableObject {
    static let shared = Bridge()

    @Published var serverRunning = false
    @Published var port = 0
    @Published var printerAddress: String?
    @Published var printerState: String?        // idle / printing / warmup / other, nil = not found
    @Published var searched = false
    @Published var problem: String?
    @Published var pageCount: Int?              // the printer's lifetime page counter
    @Published var toner: Int?                  // percent, nil = unknown
    @Published var activeJob: String? {
        didSet {
            printing.hold(activeJob != nil)
            if (activeJob == nil) != (oldValue == nil) { schedulePoll() }   // 5 s polls while it prints
        }
    }
    @Published var jobPagesSent = 0             // pages encoded and sent so far
    @Published var jobPagesTotal: Int?          // known once the whole job was sent
    @Published var jobStartCount: Int?          // page counter when the job started
    @Published var queueAdded = false
    @Published var events: [Event] = []

    let support: URL
    let uuid: String
    let device: String
    private let encoder: String
    private let resources: URL
    private let logURL: URL
    private var server: Process?
    private var dnsRef: DNSServiceRef?
    private var registrations = 0               // numbers each registration, for its watchdog
    private var registrationAnswered = false
    private var registeredName = printerName
    private var poll: Timer?                    // the next look at the printer (see pollInterval)
    private var misses = 0                      // looks in a row that didn't find it
    private var lastSearch: TimeInterval = -60  // uptime of the last full search
    private var browseRef: DNSServiceRef?       // Bonjour: the printer showing up on the network
    private var stopping = false
    private var restarts = 0
    private var pending = ""
    private var log: FileHandle?
    private var logOpened = false
    private var logSize: UInt64 = 0
    private var refreshingPrinter = false, refreshingQueue = false
    private var idleJobTicks = 0                // timer ticks with a job shown but no encoder running
    private let printing = KeepAwake("Printing")

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        support = appSupport.appendingPathComponent(appName, isDirectory: true)
        // keep the pinned printer UUID (the Mac's print queue refers to it) across the rename
        let old = appSupport.appendingPathComponent(oldAppName, isDirectory: true)
        if !fm.fileExists(atPath: support.path) && fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: support)
        }
        for dir in ["spool", "keys"] {
            try? fm.createDirectory(at: support.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        // A stable printer UUID keeps the Mac's queue (dnssd://...?uuid=) valid across launches.
        let uuidURL = support.appendingPathComponent("uuid")
        if let saved = try? String(contentsOf: uuidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            uuid = saved
        } else {
            uuid = UUID().uuidString.lowercased()
            try? uuid.write(to: uuidURL, atomically: true, encoding: .utf8)
        }
        device = UserDefaults.standard.string(forKey: "PrinterURI") ?? defaultDevice
        encoder = Bundle.main.url(forAuxiliaryExecutable: "rastertoufr2lt")?.path ?? ""
        resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        logURL = logs.appendingPathComponent("\(appName).log")
        let oldLog = logs.appendingPathComponent("\(oldAppName).log")
        if !fm.fileExists(atPath: logURL.path) && fm.fileExists(atPath: oldLog.path) {
            try? fm.moveItem(at: oldLog, to: logURL)
        }
    }

    private var pidURL: URL { support.appendingPathComponent("server.pid") }

    // MARK: Lifecycle

    func start() {
        openLog()
        killOrphan()
        port = Self.freePort(from: preferredPort)
        var conf = (try? String(contentsOf: resources.appendingPathComponent("mf4700.conf"), encoding: .utf8)) ?? ""
        conf += "ATTR uri printer-uuid urn:uuid:\(uuid)\n"
        let confURL = support.appendingPathComponent("mf4700.conf")
        try? conf.write(to: confURL, atomically: true, encoding: .utf8)
        launchServer(conf: confURL)
        refreshPrinter()
        watchForPrinter()
        #if SOAK
        // a main-thread heartbeat with the sizes of what could grow, for the soak driver
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.write(String(format: "soak: heartbeat %.3f events=%d pending=%d\n",
                              Date().timeIntervalSince1970, self.events.count, self.pending.utf8.count))
        }
        #endif
    }

    /// A job is shown while the server's print command (the encoder) runs. Should
    /// the line that ends it never arrive, clear it once no command has run for two
    /// ticks: a stuck job would hide the menu-bar icon and make Quit ask forever.
    private func checkJobRunning() {
        guard activeJob != nil, let p = server, p.isRunning else { idleJobTicks = 0; return }
        var kids = [pid_t](repeating: 0, count: 16)
        let n = proc_listchildpids(p.processIdentifier, &kids, Int32(MemoryLayout<pid_t>.size * kids.count))
        idleJobTicks = n > 0 ? 0 : idleJobTicks + 1
        if idleJobTicks >= 2 {
            note(.warning, "Job “\(activeJob ?? "")” ended without a status line")
            activeJob = nil
            idleJobTicks = 0
        }
    }

    func stop() {
        stopping = true
        poll?.invalidate()
        if let ref = browseRef { DNSServiceRefDeallocate(ref) }
        browseRef = nil
        unregister()
        if let p = server, p.isRunning {
            // its process group: the server and a job it runs (encoder, nc), no orphans
            kill(-p.processIdentifier, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while p.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(50_000) }
            if p.isRunning { kill(-p.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: pidURL)
        write("app quit; AirPrint server stopped\n")
    }

    private func launchServer(conf: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ippeveprinter")
        p.arguments = [
            "-v",
            "-n", "localhost",                 // listen on 127.0.0.1 / ::1 only
            "-p", String(port),
            "-r", "off",                       // no network-wide Bonjour; we register local-only below
            "-K", support.appendingPathComponent("keys").path,
            "-d", support.appendingPathComponent("spool").path,
            "-a", conf.path,
            "-c", encoder,
            "-D", "file:///dev/null",          // the encoder talks to the printer itself
            "-i", resources.appendingPathComponent("printer.png").path,
            printerName,
        ]
        var env = ProcessInfo.processInfo.environment
        env["UFR2LT_DEVICE"] = device
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil       // EOF: an empty read would repeat forever
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            // a job still running in its group would print again once macOS resends it
            kill(-proc.processIdentifier, SIGTERM)
            DispatchQueue.main.async { self?.serverExited(proc.terminationStatus) }
        }
        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            note(.error, "Could not start the AirPrint server: \(error.localizedDescription)")
            scheduleServerStart(after: 60)
            return
        }
        server = p
        try? String(p.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        let port = self.port
        DispatchQueue.global().async {
            let up = Self.waitForPort(port, seconds: 8)
            DispatchQueue.main.async {
                guard up, self.server === p, p.isRunning else {
                    if !self.stopping && self.server === p {
                        self.note(.error, "The AirPrint server did not start")
                        if p.isRunning { p.terminate() }  // serverExited starts another
                    }
                    return
                }
                self.serverRunning = true
                self.restarts = 0
                self.register()
            }
        }
    }

    private func serverExited(_ status: Int32) {
        serverRunning = false
        unregister()
        activeJob = nil
        guard !stopping else { return }
        restarts += 1
        if restarts > 5 {
            // keep trying, but slowly: printing must come back on its own
            if restarts == 6 { note(.error, "The AirPrint server keeps stopping (exit \(status)); retrying every minute") }
            scheduleServerStart(after: 60)
            return
        }
        note(.warning, "The AirPrint server stopped (exit \(status)); restarting")
        scheduleServerStart(after: 3)
    }

    private func scheduleServerStart(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * timeScale) { [weak self] in
            guard let self, !self.stopping, self.server?.isRunning != true else { return }
            self.port = Self.freePort(from: preferredPort)
            self.launchServer(conf: self.support.appendingPathComponent("mf4700.conf"))
        }
    }

    /// A previous run that was force-quit may have left its server behind.
    private func killOrphan() {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        let ps = Self.run("/bin/ps", ["-p", String(pid), "-o", "comm="])
        if ps.output.hasSuffix("ippeveprinter\n") || ps.output.hasSuffix("ippeveprinter") {
            kill(pid, SIGTERM)
            usleep(300_000)
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    // MARK: Bonjour (local-only)

    private func register() {
        var txt = [UInt8]()
        func add(_ key: String, _ value: String) {
            let b = Array("\(key)=\(value)".utf8)
            txt.append(UInt8(b.count))
            txt += b
        }
        add("txtvers", "1")
        add("qtotal", "1")
        add("rp", "ipp/print")
        add("ty", printerName)
        add("product", "(\(printerName))")
        add("note", "This Mac")
        add("adminurl", "http://localhost:\(port)/")
        add("pdl", "application/octet-stream,image/pwg-raster,image/urf")
        add("URF", "V1.4,W8,RS600,CP1,IS1,MT1,PQ4,OB10")
        add("Color", "F")
        add("Duplex", "F")
        add("kind", "document")
        add("PaperMax", "legal-A4")
        add("priority", "0")
        add("UUID", uuid)

        write("app: registering “\(printerName)” (Bonjour, this Mac only) for port \(port)\n")
        var ref: DNSServiceRef?
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = txt.withUnsafeBufferPointer { buf in
            DNSServiceRegister(&ref, 0, UInt32.max /* kDNSServiceInterfaceIndexLocalOnly */,
                               printerName, "_ipp._tcp,_print,_universal", nil, "localhost.",
                               UInt16(port).bigEndian, UInt16(buf.count), buf.baseAddress,
                               registerReply, ctx)
        }
        guard err == kDNSServiceErr_NoError, let ref else {
            note(.error, "Bonjour registration failed (\(err)); retrying")
            scheduleRegister()
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        dnsRef = ref
        registrations += 1
        registrationAnswered = false
        // mDNSResponder answers within a second; no answer means the registration is lost
        let number = registrations
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.registrations == number, self.dnsRef != nil, !self.registrationAnswered else { return }
            self.write("app: no Bonjour reply; registering again\n")
            self.unregister()
            self.register()
        }
    }

    /// Register again a little later, e.g. after mDNSResponder restarted.
    private func scheduleRegister() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10 * timeScale) { [weak self] in
            guard let self, !self.stopping, self.serverRunning, self.dnsRef == nil else { return }
            self.register()
        }
    }

    /// Called on the main queue while `ref` is live; answers for a registration that
    /// was replaced since are ignored.
    fileprivate func registered(ref: DNSServiceRef?, name: String, error: DNSServiceErrorType) {
        guard ref == dnsRef else { return }
        write("app: Bonjour reply for “\(name)”: \(error)\n")
        registrationAnswered = true
        if error != kDNSServiceErr_NoError {
            note(.error, "Bonjour registration failed (\(error)); retrying")
            let number = registrations
            DispatchQueue.main.async { [weak self] in    // not from inside the reply itself
                guard let self, self.registrations == number else { return }
                self.unregister()
                self.scheduleRegister()
            }
            return
        }
        registeredName = name
        note(.ok, "AirPrint printer “\(name)” is available on this Mac")
    }

    private func unregister() {
        if let ref = dnsRef { DNSServiceRefDeallocate(ref) }
        dnsRef = nil
    }

    // MARK: Printer status (Bonjour + SNMP, via the encoder)

    /// Look at the printer: its status straight over SNMP at the address it had
    /// (one UDP exchange), else a full search with the encoder (`--find`: Bonjour,
    /// then SNMP). Then the next look is scheduled.
    func refreshPrinter() {
        guard !refreshingPrinter else { return }        // a slow poll must not pile up
        refreshingPrinter = true
        poll?.invalidate()
        let known = printerAddress, encoder = self.encoder, device = self.device
        DispatchQueue.global().async {
            var line = known.flatMap { ip in SNMP.status(ip).map { "\(ip) \($0)" } }
            var searched = false
            if line == nil {
                let r = Self.run(encoder, ["--find", device], timeout: 60)
                line = r.status == 0 ? r.output : nil
                searched = true
            }
            let parts = (line ?? "").split(whereSeparator: \.isWhitespace).map(String.init)   // "… 85\n"
            DispatchQueue.main.async {
                self.refreshingPrinter = false
                if searched { self.lastSearch = ProcessInfo.processInfo.systemUptime }
                self.update(parts.count >= 4 ? parts : nil)
                self.checkJobRunning()
                if PanelWindow.shared.isVisible { self.refreshQueue() }
                self.schedulePoll()
            }
        }
    }

    /// "IP state pages error-bits toner%"; nil = not found. Published values are
    /// set only when they change: an unchanged poll redraws nothing.
    private func update(_ parts: [String]?) {
        if let parts, printerAddress != parts[0] {
            note(.ok, "Printer found at \(parts[0])")
        } else if parts == nil, printerAddress != nil || !searched {
            note(.warning, "Printer not found on this network")
        }
        misses = parts == nil ? misses + 1 : 0
        set(\.searched, true)
        set(\.printerAddress, parts?[0])
        set(\.printerState, parts?[1])
        if let parts, let count = Int(parts[2]), count > 0 {
            set(\.pageCount, count)
            if activeJob != nil && jobStartCount == nil { jobStartCount = count }
        }
        set(\.toner, parts.flatMap { $0.count >= 5 ? Int($0[4]) : nil }.flatMap { $0 >= 0 ? $0 : nil })
        let problem = parts.flatMap { Self.describe(errorBits: UInt32($0[3], radix: 16) ?? 0) }
        if problem != self.problem {
            if let problem { note(.warning, "Printer: \(problem)") }
            else if self.problem != nil { note(.ok, "Printer: problem cleared") }
            self.problem = problem
        }
    }

    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<Bridge, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Seconds to the next look: 5 while a job prints, 30 while the panel is open,
    /// else 2 minutes. While the printer isn't found (switched off, maybe for the
    /// night) only every 5 minutes: Bonjour says when it is back (watchForPrinter).
    private var pollInterval: Double {
        if activeJob != nil { return 5 }
        if printerAddress == nil && searched { return misses < 3 ? 30 : 300 }
        return PanelWindow.shared.isVisible ? 30 : 120
    }

    func schedulePoll() {
        guard !refreshingPrinter, !stopping else { return }    // the poll in flight schedules the next
        poll?.invalidate()
        let interval = pollInterval * timeScale
        poll = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in self?.refreshPrinter() }
        poll?.tolerance = interval / 10                         // let macOS batch the wakeup
    }

    /// Bonjour browsing for raw-port printers costs nothing while nothing changes,
    /// and tells at once when a printer comes on: look then, not minutes later.
    private func watchForPrinter() {
        var ref: DNSServiceRef?
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard DNSServiceBrowse(&ref, 0, 0, "_pdl-datastream._tcp", "local.", browseReply, ctx) == kDNSServiceErr_NoError,
              let ref else { return }
        DNSServiceSetDispatchQueue(ref, .main)
        browseRef = ref
    }

    fileprivate func printerAnnounced(error: DNSServiceErrorType, added: Bool) {
        if error != kDNSServiceErr_NoError {                    // mDNSResponder restarted: browse again
            if let ref = browseRef { DNSServiceRefDeallocate(ref) }
            browseRef = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, !self.stopping, self.browseRef == nil else { return }
                self.watchForPrinter()
            }
            return
        }
        // a printer appeared while ours is missing: search now (at most every 10 s)
        if added && printerAddress == nil && ProcessInfo.processInfo.systemUptime - lastSearch > 10 { refreshPrinter() }
    }

    // MARK: Print queue on this Mac

    var queueURI: String {
        let name = registeredName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? registeredName
        return "dnssd://\(name)._ipp._tcp.local./?uuid=\(uuid)"
    }

    func refreshQueue() {
        guard !refreshingQueue else { return }
        refreshingQueue = true
        let uuid = self.uuid
        DispatchQueue.global().async {
            let r = Self.run("/usr/bin/lpstat", ["-v"])
            DispatchQueue.main.async {
                self.refreshingQueue = false
                if r.status == 0 { self.queueAdded = r.output.contains("uuid=\(uuid)") }
            }
        }
    }

    /// Same as adding the printer in System Settings: macOS builds the queue
    /// from the printer's AirPrint capabilities.
    func addQueue() {
        let args = ["-p", queueName, "-E", "-v", queueURI, "-m", "everywhere", "-D", printerName]
        note(.info, "Adding “\(printerName)” to this Mac…")
        DispatchQueue.global().async {
            let r = Self.run("/usr/sbin/lpadmin", args, timeout: 60)
            DispatchQueue.main.async {
                if r.status == 0 {
                    self.note(.ok, "Added. Choose “\(printerName)” in any Print dialog.")
                } else {
                    self.note(.error, "Could not add the printer: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                self.refreshQueue()
            }
        }
    }

    // MARK: Server output → activity

    private func consume(_ data: Data) {
        write(data)
        pending += String(decoding: data, as: UTF8.self)
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            parse(line)
        }
    }

    private func parse(_ line: String) {
        guard line.hasPrefix("[Job ") else { return }
        let job = line.dropFirst(5).prefix { $0.isNumber }
        if let r = line.range(of: "Command - INFO: Printing \"") {
            let name = line[r.upperBound...].dropLast()
            activeJob = String(name)
            jobPagesSent = 0
            jobPagesTotal = nil
            jobStartCount = pageCount
            note(.info, "Job \(job): printing “\(name)”")
        } else if let r = line.range(of: "Command - INFO: ") {
            let msg = String(line[r.upperBound...])
            // "page 2 encoded (A4, …)", "Sent 3 page(s); waiting for the printer to finish"
            if msg.hasPrefix("page "), let n = Int(msg.dropFirst(5).prefix { $0.isNumber }) { jobPagesSent = n }
            if msg.hasPrefix("Sent "), let n = Int(msg.dropFirst(5).prefix { $0.isNumber }) { jobPagesTotal = n }
            if msg.hasPrefix("Connected to printer") || msg.hasPrefix("Sent ") || msg.hasPrefix("Printer not reachable") {
                note(msg.hasPrefix("Printer not") ? .warning : .info, "Job \(job): \(msg)")
            }
        } else if let r = line.range(of: "Command - ERROR: ") {
            note(.error, "Job \(job): \(line[r.upperBound...])")
        } else if line.contains("completed successfully") {
            activeJob = nil
            note(.ok, "Job \(job): done")
        } else if line.contains("exited with status") || line.contains("terminated with signal") {
            activeJob = nil
            note(.error, "Job \(job): failed (see log)")
        }
    }

    /// Pages of the current job that came out of the printer (page counter delta).
    var jobPagesPrinted: Int {
        guard let start = jobStartCount, let now = pageCount else { return 0 }
        return max(0, now - start)
    }

    /// hrPrinterDetectedErrorState bits (first octet = high byte), most severe first.
    static func describe(errorBits bits: UInt32) -> String? {
        let table: [(UInt32, String)] = [
            (0x0400, "Paper jam"), (0x0800, "Cover open"), (0x4000, "Out of paper"),
            (0x1000, "Out of toner"), (0x0100, "Printer needs attention"), (0x0080, "Paper drawer missing"),
            (0x0200, "Printer offline"), (0x0004, "A paper tray is empty"), (0x8000, "Paper low"),
            (0x2000, "Toner low"),
        ]
        return table.first { bits & $0.0 != 0 }?.1
    }

    func note(_ kind: Event.Kind, _ text: String) {
        events.append(Event(text: text, kind: kind))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        write("app: \(text)\n")
    }

    #if SOAK
    private let logLimit: UInt64 = 256_000
    #else
    private let logLimit: UInt64 = 2_000_000
    #endif

    private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        reopenLog()
        logOpened = true
        write("---- \(Date()) app started (printer UUID \(uuid), device \(device))\n")
    }

    private func reopenLog() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        log = try? FileHandle(forWritingTo: logURL)
        logSize = (try? log?.seekToEnd()) ?? 0
    }

    /// The log is kept below its limit while the app runs for weeks: the older half
    /// goes to "<name>.log.1" (replacing the previous one).
    private func rotateLog() {
        try? log?.close()
        let fm = FileManager.default
        let old = logURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logURL, to: old)
        fm.createFile(atPath: logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: logURL)
        logSize = 0
        write("---- \(Date()) log continued (older lines in \(old.lastPathComponent))\n")
    }

    private func write(_ s: String) { write(Data(s.utf8)) }

    private func write(_ data: Data) {
        if log == nil && logOpened { reopenLog() }      // e.g. a rotation failed on a full disk
        guard let log else { return }
        // write(contentsOf:) throws instead of raising an exception, e.g. on a full disk
        guard (try? log.write(contentsOf: data)) != nil else { return }
        logSize += UInt64(data.count)
        if logSize > logLimit { rotateLog() }
    }

    func logLine(_ s: String) { write("app: \(s)\n") }

    // MARK: Helpers

    static func freePort(from start: Int) -> Int {
        for p in start..<(start + 50) where portIsFree(p) { return p }
        return start
    }

    static func portIsFree(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func waitForPort(_ port: Int, seconds: Double) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(s)
            if ok { return true }
            usleep(200_000)
        }
        return false
    }

    struct RunResult { let status: Int32; let output: String }

    /// Run a helper and collect its output, stopping it after `timeout` seconds: it
    /// is read as it comes, so a child that hangs (or leaves a process holding its
    /// output open) can't block the caller.
    static func run(_ path: String, _ args: [String], timeout: Double = 15) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let lock = NSLock()
        var data = Data()
        let closed = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                closed.signal()
                return
            }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return RunResult(status: -1, output: error.localizedDescription)
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        if closed.wait(timeout: .now() + 2) == .timedOut { out.fileHandleForReading.readabilityHandler = nil }
        lock.lock()
        defer { lock.unlock() }
        return RunResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Delivered on the main queue (DNSServiceSetDispatchQueue).
private let browseReply: DNSServiceBrowseReply = { _, flags, _, error, _, _, _, context in
    guard let context else { return }
    Unmanaged<Bridge>.fromOpaque(context).takeUnretainedValue()
        .printerAnnounced(error: error, added: flags & kDNSServiceFlagsAdd != 0)
}

/// Delivered on the main queue (DNSServiceSetDispatchQueue).
private let registerReply: DNSServiceRegisterReply = { ref, _, error, name, _, _, context in
    guard let context else { return }
    Unmanaged<Bridge>.fromOpaque(context).takeUnretainedValue()
        .registered(ref: ref, name: name.map { String(cString: $0) } ?? printerName, error: error)
}
