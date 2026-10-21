// SPDX-License-Identifier: GPL-2.0-or-later
// Renders the panel in typical states to PNG files, to review the design
// without a printer:  ./app/Snapshot/run.sh [out-dir]

import AppKit
import SwiftUI

/// The app icon: the printer on the panel's dark stage, in macOS's icon shape
/// (an 824 pt squircle on a 1024 pt canvas).
struct AppIconArt: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.165, blue: 0.185), Color(red: 0.05, green: 0.055, blue: 0.065)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RadialGradient(colors: [Color(red: 0.62, green: 0.66, blue: 0.74).opacity(0.34), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.47), startRadius: 0, endRadius: 400)
                        .clipShape(shape)
                }
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 2))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
            ZStack {
                ContactShadow().frame(width: 660, height: 660)
                Image(nsImage: PrinterArt.image).resizable().interpolation(.high)
                    .frame(width: 660, height: 660)
            }
            .offset(x: -6, y: 4)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The disk image window's background (640×400): the app goes on the left icon
/// spot, Applications on the right (dmg-settings.py places them at these points).
struct DMGBackground: View {
    static let size = CGSize(width: 640, height: 400)
    static let appSpot = CGPoint(x: 165, y: 200)
    static let applicationsSpot = CGPoint(x: 475, y: 200)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.976, green: 0.978, blue: 0.984), Color(red: 0.902, green: 0.910, blue: 0.925)],
                           startPoint: .top, endPoint: .bottom)
            ForEach([Self.appSpot, Self.applicationsSpot], id: \.x) { spot in
                RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 120)
                    .frame(width: 260, height: 260)
                    .position(spot)
            }
            VStack(spacing: 7) {
                Text("Canon MF4780w Print & Scan")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color(white: 0.11))
                Text("Drag the app onto Applications to install it")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.40))
            }
            .position(x: Self.size.width / 2, y: 58)
            InstallArrow()
                .stroke(Color(white: 0.24).opacity(0.72), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .frame(width: 120, height: 36)
                .position(x: (Self.appSpot.x + Self.applicationsSpot.x) / 2, y: Self.appSpot.y - 4)
            Text("AirPrint and scanning for Canon i-SENSYS MF4700-series printers")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.52))
                .position(x: Self.size.width / 2, y: 340)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

struct InstallArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.move(to: CGPoint(x: r.maxX - r.height * 0.5, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - r.height * 0.5, y: r.maxY))
        return p
    }
}

@main
struct Snapshot {
    @MainActor
    static func main() {
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--dmg-background" {
            let dir = CommandLine.arguments[2]
            for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
                let renderer = ImageRenderer(content: DMGBackground())
                renderer.scale = scale
                if let image = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
                    print("\(dir)/\(name)")
                }
            }
            return
        }
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--icon" {
            let renderer = ImageRenderer(content: AppIconArt())
            renderer.scale = 1
            if let image = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                print(CommandLine.arguments[2])
            }
            return
        }
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        var base = PanelModel()
        base.toner = 100
        base.pages = 18030
        base.address = "192.168.1.20"
        base.airPrint = .available(added: true)
        base.scanName = "MacBook-Pro"

        var asleep = base
        asleep.tone = .asleep
        asleep.title = "Ready"
        asleep.detail = "Asleep — wakes up for print jobs and scans"
        asleep.lastScan = "Scan 2026-10-20 at 19.48.14.pdf"

        var printing = base
        printing.tone = .printing
        printing.title = "Printing"
        printing.detail = "“Quarterly report.pdf” · page 2 of 5"
        printing.progress = 0.4
        printing.activity = true

        var scanning = base
        scanning.tone = .scanning
        scanning.title = "Scanning"
        scanning.detail = "From the feeder · page 2 done"
        scanning.activity = true
        scanning.canCancel = true

        var jam = base
        jam.tone = .error
        jam.title = "Paper jam"
        jam.detail = "Open the printer and remove the jammed paper"
        jam.notice = .init(text: "The printer stopped the scan (paper jam or Stop key); the pages scanned before it are saved", isError: true)

        var offline = PanelModel()
        offline.tone = .offline
        offline.title = "Not found"
        offline.detail = "Is the printer on and connected to this network?"
        offline.airPrint = .available(added: false)

        for (name, model) in [("asleep", asleep), ("printing", printing), ("scanning", scanning), ("jam", jam), ("offline", offline)] {
            let renderer = ImageRenderer(content: PanelView(model: model, animate: false)
                .frame(width: PanelView.size.width, height: PanelView.size.height))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("cannot render \(name)")
                continue
            }
            try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
            print("\(out)/\(name).png")
        }
        for symbol in ["printer", "printer.fill", "scanner.fill", "exclamationmark.triangle.fill", "printer.dotmatrix"] {
            if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil { print("missing SF Symbol \(symbol)") }
        }
    }
}
