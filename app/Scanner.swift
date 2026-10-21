// SPDX-License-Identifier: GPL-2.0-or-later
// Canon MF4780w Print & Scan: SCAN → Computer on the printer → PDF on the Desktop.

import AppKit
import SwiftUI
import SystemConfiguration

/// While the app is open, the bundled `mfnpscan --wait` keeps this Mac in the
/// printer's SCAN → Computer list (Canon's MFNP Notify registration). When Start
/// is pressed for this Mac, the same process scans (the feeder if loaded, else the
/// glass, 300 dpi, Color or B&W as chosen on the panel) and exits. The app then
/// saves the pages as a PDF on the Desktop, opens it, and starts a new listener.
final class ScanController: ObservableObject {
    static let shared = ScanController()

    enum Phase: Equatable {
        case starting                            // Start pressed, waiting for the session
        case scanning(feeder: Bool, pages: Int)  // pages finished so far
    }

    @Published var phase: Phase? { didSet { awake.hold(phase != nil) } }
    @Published var listedAs: String?             // this Mac's entry under SCAN → Computer
    @Published var lastScan: URL? = UserDefaults.standard.url(forKey: "LastScan")
        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } {
        didSet { UserDefaults.standard.set(lastScan, forKey: "LastScan") }
    }
    var scanning: Bool { phase != nil }

    /// The name the printer shows under SCAN → Computer. The panel shows plain
    /// ASCII, so the Mac's name is used only if it is ASCII, else its local host name.
    /// Override: defaults write local.mf4700-airprint ScanComputerName "Name"
    static let computerName: String = {
        if let custom = UserDefaults.standard.string(forKey: "ScanComputerName"), !custom.isEmpty { return custom }
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?,
           !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isNewline }) { return name }
        return (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }()

    private let scanner = Bundle.main.url(forAuxiliaryExecutable: "mfnpscan")?.path ?? ""
    private var timer: Timer?
    private var listener: Process?               // mfnpscan --wait
    private var listenerAddress: String?
    private var listenAgain: TimeInterval = 0     // monotonic (systemUptime): immune to clock changes
    private var stoppingListener = false
    private var unreachable = 0                  // listener runs that found no printer
    private var lastReply = ""                   // the printer's last Notify reply, as logged
    private let awake = KeepAwake("Scanning")
    private static let saveQueue = DispatchQueue(label: "scan-save", qos: .userInitiated)
    private(set) var saving = 0                  // PDFs being written: Quit waits for them
    private var afterSaving: [() -> Void] = []

    /// Run `done` once no PDF is being written (now, if none is).
    func whenSaved(_ done: @escaping () -> Void) {
        if saving == 0 { done() } else { afterSaving.append(done) }
    }

    func start() {
        // settings of the Remote Scanner mode that earlier versions used
        UserDefaults.standard.removeObject(forKey: "ScanQuietUntil")
        UserDefaults.standard.removeObject(forKey: "WatchForScans")
        timer = Timer.scheduledTimer(withTimeInterval: 3 * timeScale, repeats: true) { [weak self] _ in self?.listen() }
        timer?.tolerance = 1
    }

    func stop() {
        timer?.invalidate()
        stopListener()
    }

    private func stopListener() {
        guard let listener else { return }
        stoppingListener = true
        listener.terminate()                     // mfnpscan unregisters this Mac, then exits
        DispatchQueue.main.asyncAfter(deadline: .now() + 20 * timeScale) {
            if listener.isRunning { kill(listener.processIdentifier, SIGKILL) }
        }
    }

    /// Stop the scan in progress. mfnpscan ends the session and keeps the pages it finished.
    func cancelScan() {
        guard scanning, let p = listener else { return }
        p.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8 * timeScale) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// Keep one `mfnpscan --wait` running for the printer's current address.
    private func listen() {
        guard let ip = Bridge.shared.printerAddress else { return }
        if listener != nil {
            if listenerAddress != ip && !scanning { stopListener() }   // the printer moved
            return
        }
        guard ProcessInfo.processInfo.systemUptime >= listenAgain else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scanner)
        p.arguments = ["--wait", "-v", "-n", Self.computerName, "-r", "300", "-m", "color", "-s", "auto", "-o", dir.path, ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // The listener is over once it exited AND all its output was read: the last
        // PAGE lines may still be in the pipe when the exit is reported.
        var output = "", partial = "", exited = false, drained = false     // main thread only
        func finish() {
            guard exited && drained else { return }
            p.terminationHandler = nil           // it holds this function: let the process go
            listenerEnded(p, output: output + partial, dir: dir)
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { drained = true; finish() }   // after the output blocks
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                partial += text
                while let nl = partial.firstIndex(of: "\n") {
                    let line = String(partial[..<nl])
                    partial.removeSubrange(...nl)
                    // the scan's trace starts at Start; before it (days, maybe) keep only recent replies
                    if line.hasPrefix("EVENT") { output = "" }
                    else if self?.phase == nil && output.utf8.count > 64_000 { output = String(output.suffix(16_000)) }
                    output += line + "\n"
                    self?.listenerSaid(line)
                }
            }
        }
        p.terminationHandler = { _ in DispatchQueue.main.async { exited = true; finish() } }
        do {
            try p.run()
            listener = p
            listenerAddress = ip
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            p.terminationHandler = nil
            listenAgain = ProcessInfo.processInfo.systemUptime + 60 * timeScale
            Bridge.shared.logLine("cannot start the scan listener: \(error.localizedDescription)")
        }
    }

    private func listenerSaid(_ line: String) {
        let bridge = Bridge.shared
        if line.hasPrefix("INFO: listed on the printer as ") {
            let name = line.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
            unreachable = 0
            if listedAs != name {
                listedAs = name
                bridge.logLine("listed under SCAN → Computer as \(name)")
            }
        } else if line.hasPrefix("notify ") || line.hasPrefix("INFO: the printer refused") {
            if line != lastReply { bridge.logLine("scan listener: \(line)") }   // the printer's replies, when they change
            lastReply = line
        } else if line.hasPrefix("EVENT") {
            phase = .starting
            bridge.logLine("Start pressed for this Mac: \(line)")
        } else if line.hasPrefix("INFO: scanning from") {
            phase = .scanning(feeder: line.contains("feeder"), pages: 0)
            bridge.note(.info, line.contains("feeder") ? "Scanning from the feeder" : "Scanning from the glass")
        } else if line.hasPrefix("PAGE "), case .scanning(let feeder, _) = phase {
            phase = .scanning(feeder: feeder, pages: Int(line.split(separator: " ")[1]) ?? 0)
        }
    }

    private func listenerEnded(_ proc: Process, output: String, dir: URL) {
        let pressed = phase != nil
        listener = nil
        phase = nil
        let bridge = Bridge.shared
        let stopped = stoppingListener
        stoppingListener = false
        let crashed = proc.terminationReason != .exit
        let status = crashed ? -1 : proc.terminationStatus
        if crashed && !stopped {
            bridge.logLine("scan listener crashed (signal \(proc.terminationStatus))")
            listenAgain = ProcessInfo.processInfo.systemUptime + 10 * timeScale
        }
        if pressed && status != 0 {                     // the scan's trace, minus the per-block exchanges
            bridge.logLine("SCAN → Computer exit \(status), trace:\n"
                           + output.split(separator: "\n").filter { !Self.isChatter($0) }.joined(separator: "\n"))
        }
        if status == 4 {                                                // the printer stopped answering
            listedAs = nil
            listenAgain = ProcessInfo.processInfo.systemUptime + 30 * timeScale
            unreachable += 1
            // SNMP (Apple's snmpget) reaches the printer but our helper can't:
            // macOS Local Network privacy is blocking the app.
            if unreachable == 2 && bridge.printerAddress != nil {
                bridge.note(.warning, "Can't reach the scanner. Allow this app in System Settings → Privacy & Security → Local Network.")
            }
        } else if status > 0 {
            listenAgain = ProcessInfo.processInfo.systemUptime + 5 * timeScale
        }
        guard pressed, status != 2 else {
            if pressed { bridge.note(.warning, "The printer did not start the scan") }
            try? FileManager.default.removeItem(at: dir)
            return
        }
        conclude(status, output: output, dir: dir)
    }

    /// mfnpscan -v's per-block protocol exchanges: too many to log.
    static func isChatter(_ line: Substring) -> Bool {
        line.hasPrefix("tcp ") || line.hasPrefix("udp ") || line.hasPrefix("block hdr") || line.hasPrefix("reply (")
    }

    /// Save the pages mfnpscan finished (also those before a failed page), open the
    /// PDF, and say how it went. The PDF is written off the main thread: the first
    /// save may wait for the user to answer macOS's question about the Desktop.
    private func conclude(_ status: Int32, output: String, dir: URL) {
        let pages = Self.pageList(output)
        let error = output.split(separator: "\n").last { $0.hasPrefix("ERROR: ") }.map { String($0.dropFirst(7)) }
        saving += 1
        Self.saveQueue.async {
            let saved = Self.savePDF(pages, draft: dir.appendingPathComponent("scan.pdf"))
            DispatchQueue.main.async { self.concluded(status, saved: saved, error: error, dir: dir) }
        }
    }

    private func concluded(_ status: Int32, saved: Result<SavedScan?, Error>, error: String?, dir: URL) {
        let bridge = Bridge.shared
        let fm = FileManager.default
        var url: URL?, unsaved: String?
        defer {
            saving -= 1
            if saving == 0 {
                let waiting = afterSaving
                afterSaving = []
                waiting.forEach { $0() }
            }
        }
        switch saved {
        case .success(let scan?):
            url = scan.url
            lastScan = scan.url
            bridge.note(.ok, "Saved “\(scan.url.lastPathComponent)” (\(scan.pages) page\(scan.pages == 1 ? "" : "s"))"
                             + (scan.inAppFolder ? " in the app's folder: the Desktop was not available" : ""))
            #if !SOAK
            NSSound(named: "Glass")?.play()
            #endif
            try? fm.removeItem(at: dir)
        case .success(nil):
            if status == 0 { bridge.note(.error, "The scanner sent no pages") }
            try? fm.removeItem(at: dir)
        case .failure(let e):
            // no PDF could be written anywhere: keep the pages rather than lose the scan
            var kept = bridge.support.appendingPathComponent("Unsaved Scans/\(dir.lastPathComponent)")
            try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: dir, to: kept)) == nil { kept = dir }      // then they stay where they are
            unsaved = "could not save the PDF (\(e.localizedDescription)); the pages are in \(kept.path)"
        }
        let kept = url != nil ? "; the pages scanned before it are saved" : unsaved.map { "; \($0)" } ?? ""
        switch status {
        case 0:
            if let unsaved { bridge.note(.error, unsaved.prefix(1).uppercased() + unsaved.dropFirst()) }
        case 5:
            bridge.note(.error, "The printer stopped the scan (paper jam or Stop key)\(kept)")
        case 6:
            bridge.note(.warning, "Scan cancelled\(kept)")
        default:
            bridge.note(.error, "Scan failed: \(error ?? "see log")\(kept)")
        }
        #if !SOAK
        if let url { NSWorkspace.shared.open(url) }
        #endif
    }

    struct SavedScan { let url: URL; let pages: Int; let inAppFolder: Bool }

    /// The PDF is written as `draft` next to the pages, then moved to the Desktop,
    /// else (no permission, ...) to the app's folder: an interrupted save never
    /// leaves half a PDF on the Desktop.
    static func savePDF(_ pages: [(String, Int)], draft: URL) -> Result<SavedScan?, Error> {
        Result {
            guard let count = try writePDF(pages, to: draft) else { return nil }
            let fm = FileManager.default
            do {
                let url = newScanURL(in: scanFolder())
                try fm.moveItem(at: draft, to: url)
                return SavedScan(url: url, pages: count, inAppFolder: false)
            } catch {
                let folder = Bridge.shared.support.appendingPathComponent("Scans", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = newScanURL(in: folder)
                try fm.moveItem(at: draft, to: url)
                return SavedScan(url: url, pages: count, inAppFolder: true)
            }
        }
    }

    /// mfnpscan's "PAGE <n> <path> <width> <height> <dpi>" lines.
    static func pageList(_ output: String) -> [(String, Int)] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.first == "PAGE", f.count >= 6, let dpi = Int(f[f.count - 1]) else { return nil }
            return (f[2..<(f.count - 3)].joined(separator: " "), dpi)
        }
    }

    enum ScanError: LocalizedError {
        case cannotCreate
        var errorDescription: String? { "cannot create the PDF file" }
    }

    static func scanFolder() -> URL {
        #if SOAK
        let folder = Bridge.shared.support.appendingPathComponent("scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
        #else
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        #endif
    }

    static func newScanURL(in desktop: URL) -> URL {
        let fm = FileManager.default
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Scan \(format.string(from: Date()))"
        var url = desktop.appendingPathComponent("\(stem).pdf")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(stem) \(n).pdf")
            n += 1
        }
        return url
    }

    /// Write the pages to a PDF, one at a time: a full colour page is 26 MB of
    /// pixels, and a feeder holds 35 sheets. Returns the page count, nil without pages.
    static func writePDF(_ list: [(String, Int)], to url: URL) throws -> Int? {
        var ctx: CGContext?, pages = 0
        for (path, dpi) in list {
            try autoreleasepool {
                guard let raw = loadPNM(path), let image = jpeg(raw) else { return }
                if ctx == nil {
                    guard let c = CGContext(url as CFURL, mediaBox: nil, nil) else { throw ScanError.cannotCreate }
                    ctx = c
                }
                var box = CGRect(x: 0, y: 0, width: CGFloat(raw.width) * 72 / CGFloat(dpi),
                                 height: CGFloat(raw.height) * 72 / CGFloat(dpi))
                ctx?.beginPage(mediaBox: &box)
                ctx?.draw(image, in: box)
                ctx?.endPage()
                pages += 1
            }
        }
        ctx?.closePDF()
        return pages > 0 ? pages : nil
    }

    /// P5 (gray) / P6 (RGB) 8-bit, as written by mfnpscan.
    static func loadPNM(_ path: String) -> CGImage? {
        // mapped, not read: only the pixels are copied, once
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        var fields: [String] = [], i = 0
        let header = data.prefix(64)
        func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09 }
        while fields.count < 4, i < header.count {
            while i < header.count, space(header[i]) { i += 1 }
            var token = ""
            while i < header.count, !space(header[i]) {
                token.append(Character(UnicodeScalar(header[i])))
                i += 1
            }
            fields.append(token)
        }
        i += 1                                     // single whitespace before the pixels
        guard fields.count == 4, let w = Int(fields[1]), let h = Int(fields[2]), fields[3] == "255" else { return nil }
        let channels = fields[0] == "P6" ? 3 : 1
        guard w > 0, h > 0, data.count >= i + w * h * channels,
              let provider = CGDataProvider(data: data.subdata(in: i..<(i + w * h * channels)) as CFData),
              let space = channels == 3 ? CGColorSpace(name: CGColorSpace.sRGB) : CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * channels, bytesPerRow: w * channels,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Re-encode as JPEG. An image made from a JPEG data provider is embedded in
    /// the PDF as-is (DCTDecode) instead of as Flate-compressed pixels.
    static func jpeg(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

