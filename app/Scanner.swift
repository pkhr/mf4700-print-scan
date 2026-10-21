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

    struct Page { let image: CGImage; let width: Int; let height: Int; let dpi: Int }

    enum Phase: Equatable {
        case starting                            // Start pressed, waiting for the session
        case scanning(feeder: Bool, pages: Int)  // pages finished so far
    }

    @Published var phase: Phase?
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
    private var listenAgain = Date.distantPast
    private var stoppingListener = false
    private var unreachable = 0                  // listener runs that found no printer

    func start() {
        // settings of the Remote Scanner mode that earlier versions used
        UserDefaults.standard.removeObject(forKey: "ScanQuietUntil")
        UserDefaults.standard.removeObject(forKey: "WatchForScans")
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.listen() }
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
    }

    /// Stop the scan in progress. mfnpscan ends the session and keeps the pages it finished.
    func cancelScan() {
        guard scanning, let p = listener else { return }
        p.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
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
        guard Date() >= listenAgain else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scanner)
        p.arguments = ["--wait", "-v", "-n", Self.computerName, "-r", "300", "-m", "color", "-s", "auto", "-o", dir.path, ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var output = "", partial = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                output += text
                partial += text
                while let nl = partial.firstIndex(of: "\n") {
                    self?.listenerSaid(String(partial[..<nl]))
                    partial.removeSubrange(...nl)
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                output += rest
                self?.listenerEnded(proc, output: output, dir: dir)
            }
        }
        do {
            try p.run()
            listener = p
            listenerAddress = ip
        } catch {
            listenAgain = Date().addingTimeInterval(60)
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
            bridge.logLine("scan listener: \(line)")     // the printer's replies, when they change
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
        defer { try? FileManager.default.removeItem(at: dir) }
        let bridge = Bridge.shared
        let stopped = stoppingListener
        stoppingListener = false
        guard proc.terminationReason == .exit else {
            if !stopped {
                bridge.logLine("scan listener crashed (signal \(proc.terminationStatus))")
                listenAgain = Date().addingTimeInterval(10)
            }
            return
        }
        let status = proc.terminationStatus
        if pressed {
            bridge.logLine("SCAN → Computer exit \(status), trace:\n"
                           + output.split(separator: "\n").filter { !$0.hasPrefix("tcp < hdr") }.joined(separator: "\n"))
        }
        if status == 4 {                                                // the printer stopped answering
            listedAs = nil
            listenAgain = Date().addingTimeInterval(30)
            unreachable += 1
            // SNMP (Apple's snmpget) reaches the printer but our helper can't:
            // macOS Local Network privacy is blocking the app.
            if unreachable == 2 && bridge.printerAddress != nil {
                bridge.note(.warning, "Can't reach the scanner. Allow this app in System Settings → Privacy & Security → Local Network.")
            }
            return
        }
        if status != 0 { listenAgain = Date().addingTimeInterval(5) }
        guard pressed else { return }
        if status == 2 {
            bridge.note(.warning, "The printer did not start the scan")
        } else {
            conclude(status, output: output)
        }
    }

    /// Save the pages mfnpscan finished (also those before a failed page), open the
    /// PDF, and say how it went.
    private func conclude(_ status: Int32, output: String) {
        let bridge = Bridge.shared
        let url = save(output, required: status == 0)
        let kept = url != nil ? "; the pages scanned before it are saved" : ""
        switch status {
        case 0:
            break
        case 5:
            bridge.note(.error, "The printer stopped the scan (paper jam or Stop key)\(kept)")
        case 6:
            bridge.note(.warning, "Scan cancelled\(kept)")
        default:
            let errors = output.split(separator: "\n").filter { $0.hasPrefix("ERROR: ") }
            bridge.note(.error, "Scan failed: \(errors.last.map { String($0.dropFirst(7)) } ?? "see log")\(kept)")
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Turn mfnpscan's PAGE lines into a PDF on the Desktop.
    private func save(_ output: String, required: Bool) -> URL? {
        let bridge = Bridge.shared
        // "PAGE <n> <path> <width> <height> <dpi>"
        let list: [(String, Int)] = output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.first == "PAGE", f.count >= 6, let dpi = Int(f[f.count - 1]) else { return nil }
            return (f[2..<(f.count - 3)].joined(separator: " "), dpi)
        }
        let pages = Self.loadPages(list)
        guard !pages.isEmpty else {
            if required { bridge.note(.error, "The scanner sent no pages") }
            return nil
        }
        do {
            let url = Self.newScanURL()
            try Self.writePDF(pages, to: url)
            lastScan = url
            bridge.note(.ok, "Saved “\(url.lastPathComponent)” (\(pages.count) page\(pages.count == 1 ? "" : "s"))")
            NSSound(named: "Glass")?.play()
            return url
        } catch {
            bridge.note(.error, "Could not save the PDF: \(error.localizedDescription)")
            return nil
        }
    }

    enum ScanError: LocalizedError {
        case cannotCreate
        var errorDescription: String? { "cannot create the PDF file" }
    }

    static func newScanURL() -> URL {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
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

    static func loadPages(_ list: [(String, Int)]) -> [Page] {
        list.compactMap { path, dpi in
            guard let raw = loadPNM(path), let image = jpeg(raw) else { return nil }
            return Page(image: image, width: raw.width, height: raw.height, dpi: dpi)
        }
    }

    static func writePDF(_ pages: [Page], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw ScanError.cannotCreate }
        for page in pages {
            var box = CGRect(x: 0, y: 0, width: CGFloat(page.width) * 72 / CGFloat(page.dpi),
                             height: CGFloat(page.height) * 72 / CGFloat(page.dpi))
            ctx.beginPage(mediaBox: &box)
            ctx.draw(page.image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// P5 (gray) / P6 (RGB) 8-bit, as written by mfnpscan.
    static func loadPNM(_ path: String) -> CGImage? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let bytes = [UInt8](data)
        var fields: [String] = [], i = 0
        while fields.count < 4, i < bytes.count {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0a || bytes[i] == 0x0d || bytes[i] == 0x09 { i += 1 }
            var token = ""
            while i < bytes.count, !(bytes[i] == 0x20 || bytes[i] == 0x0a || bytes[i] == 0x0d || bytes[i] == 0x09) {
                token.append(Character(UnicodeScalar(bytes[i])))
                i += 1
            }
            fields.append(token)
        }
        i += 1                                     // single whitespace before the pixels
        guard fields.count == 4, let w = Int(fields[1]), let h = Int(fields[2]), fields[3] == "255" else { return nil }
        let channels = fields[0] == "P6" ? 3 : 1
        guard bytes.count >= i + w * h * channels,
              let provider = CGDataProvider(data: Data(bytes[i..<(i + w * h * channels)]) as CFData),
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

