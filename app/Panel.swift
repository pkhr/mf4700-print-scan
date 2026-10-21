// SPDX-License-Identifier: GPL-2.0-or-later
// Canon MF4780w Print & Scan: the window, a dark device panel in the spirit of
// Logi Options+ (the device large on a spotlit stage, status in white type).
// Views take a PanelModel, so they render without a printer (app/Snapshot).

import AppKit
import SwiftUI

struct PanelModel: Equatable {
    enum Tone: Equatable { case ready, asleep, printing, scanning, warning, error, offline }
    enum AirPrint: Equatable { case starting, available(added: Bool) }
    struct Notice: Equatable { var text: String; var isError: Bool }

    var tone = Tone.ready
    var title = "Ready"
    var detail = ""
    var progress: Double?                       // 0…1, nil = no determinate progress
    var activity = false                        // something is happening (animated bar)
    var canCancel = false
    var toner: Int?                             // percent
    var pages: Int?                             // lifetime page counter
    var address: String?
    var airPrint = AirPrint.starting
    var scanName: String?                       // listed under SCAN → Computer as …
    var lastScan: String?                       // file name of the last scan
    var notice: Notice?
    var noticeExpiry: Date?                     // when the notice should go
}

struct PanelActions {
    var cancelScan: () -> Void = {}
    var openLastScan: () -> Void = {}
    var addToMac: () -> Void = {}
    var openPrinterSettings: () -> Void = {}
}

enum Palette {
    static let top = Color(red: 0.110, green: 0.114, blue: 0.129)
    static let bottom = Color(red: 0.047, green: 0.051, blue: 0.059)
    static let primary = Color(white: 0.97)
    static let secondary = Color(red: 0.63, green: 0.65, blue: 0.69)
    static let label = Color(red: 0.47, green: 0.49, blue: 0.53)
    static let card = Color.white.opacity(0.045)
    static let cardLine = Color.white.opacity(0.075)
    static let green = Color(red: 0.25, green: 0.86, blue: 0.56)
    static let blue = Color(red: 0.32, green: 0.62, blue: 1.0)
    static let teal = Color(red: 0.20, green: 0.84, blue: 0.78)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.24)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let gray = Color(red: 0.55, green: 0.57, blue: 0.61)
}

extension PanelModel.Tone {
    var color: Color {
        switch self {
        case .ready: return Palette.green
        case .asleep: return Palette.green.opacity(0.7)
        case .printing: return Palette.blue
        case .scanning: return Palette.teal
        case .warning: return Palette.amber
        case .error: return Palette.red
        case .offline: return Palette.gray
        }
    }

    /// Light on the stage behind the printer.
    var stageLight: Color {
        switch self {
        case .ready, .asleep, .offline: return Color(red: 0.62, green: 0.66, blue: 0.74)
        default: return color
        }
    }

    /// Menu-bar symbol.
    var symbol: String {
        switch self {
        case .ready, .asleep: return "printer"
        case .printing: return "printer.fill"
        case .scanning: return "scanner.fill"
        case .warning, .error: return "exclamationmark.triangle.fill"
        case .offline: return "printer.dotmatrix"
        }
    }
}

/// Canon's render of the MF4700 series (from its Mac driver, transparent).
enum PrinterArt {
    static let image: NSImage = {
        if let path = ProcessInfo.processInfo.environment["PANEL_ART"], let image = NSImage(contentsOfFile: path) {
            return image
        }
        return Bundle.main.image(forResource: "printer-large") ?? NSImage()
    }()
}

// MARK: - Panel

struct PanelView: View {
    var model: PanelModel
    var actions = PanelActions()
    var animate = true

    /// The printer's height plus small margins; the text is centred on the printer.
    static let size = CGSize(width: 800, height: 320)
    private static let stageWidth: CGFloat = 344

    var body: some View {
        if animate && (model.tone == .printing || model.tone == .scanning) {
            TimelineView(.animation) { context in
                panel(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            panel(time: 0)
        }
    }

    private func panel(time: Double) -> some View {
        let breath = model.tone == .printing ? 0.5 + 0.5 * sin(time * 2.2) : 0.5
        let light = model.tone.stageLight
        return HStack(spacing: 0) {
            DeviceArt(tone: model.tone, time: time, breath: breath)
                .frame(width: Self.stageWidth)
            InfoColumn(model: model, actions: actions, animate: animate)
                .padding(.leading, 8)
                .padding(.trailing, 36)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: Self.size.width, maxWidth: .infinity, minHeight: Self.size.height, maxHeight: .infinity)
        .background {
            ZStack {
                LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                // the stage light spills softly into the text column: no edge
                RadialGradient(colors: [light.opacity(0.24 + 0.08 * breath), light.opacity(0.07), .clear],
                               center: UnitPoint(x: Self.stageWidth / 2 / Self.size.width, y: 0.5),
                               startRadius: 0, endRadius: 250)
                    .animation(.easeInOut(duration: 0.6), value: model.tone)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The printer standing on the lit floor of the stage: a contact shadow along its
/// base, no gap underneath. Scanning sweeps a light across it.
struct DeviceArt: View {
    var tone: PanelModel.Tone
    var time: Double
    var breath: Double

    private static let side: CGFloat = 316              // the 512 px render, in points
    private static let k = side / 512                    // render px → points

    var body: some View {
        let light = tone.stageLight
        let art = Image(nsImage: PrinterArt.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        // the floor's pool of light is centred on the printer's base (render px ≈ 275, 432)
        let pool = CGPoint(x: 275 * Self.k - Self.side / 2, y: 432 * Self.k - Self.side / 2)
        ZStack {
            Ellipse()
                .fill(light.opacity(0.13 + 0.06 * breath))
                .frame(width: 380, height: 64)
                .blur(radius: 20)
                .offset(x: pool.x, y: pool.y)
            ContactShadow()
                .frame(width: Self.side, height: Self.side)
            art
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    if tone == .scanning { ScanLight(time: time).mask(art) }
                }
                .saturation(tone == .offline ? 0 : 1)
                .opacity(tone == .offline ? 0.55 : 1)
                .shadow(color: light.opacity(0.16 + 0.10 * breath), radius: 18, y: -10)
        }
        .animation(.easeInOut(duration: 0.6), value: tone)
    }
}

/// A soft shadow along the render's base outline (in render pixels): the front
/// edge runs from (60, 430) to (378, 470), the right side back to (486, 386).
struct ContactShadow: View {
    var body: some View {
        GeometryReader { g in
            let k = g.size.width / 512
            let base = Path { p in
                p.move(to: CGPoint(x: 58 * k, y: 428 * k))
                p.addLine(to: CGPoint(x: 378 * k, y: 472 * k))
                p.addLine(to: CGPoint(x: 488 * k, y: 388 * k))
                p.addLine(to: CGPoint(x: 200 * k, y: 352 * k))
                p.closeSubpath()
            }
            ZStack {
                base.fill(Color.black.opacity(0.55)).blur(radius: 14)
                base.fill(Color.black.opacity(0.85)).blur(radius: 4)
            }
        }
    }
}

/// A bar of light moving across the scanner part of the printer.
struct ScanLight: View {
    var time: Double

    var body: some View {
        GeometryReader { g in
            let t = 0.5 + 0.5 * sin(time * 1.9)
            LinearGradient(colors: [.clear, Palette.teal.opacity(0.55), .white.opacity(0.95), Palette.teal.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: g.size.height * 0.07)
                .offset(y: g.size.height * (0.10 + 0.24 * t))
                .blendMode(.plusLighter)
        }
    }
}

// MARK: - Information

struct InfoColumn: View {
    var model: PanelModel
    var actions: PanelActions
    var animate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("CANON  i-SENSYS").foregroundStyle(Palette.label)
                Text("MF4780w").foregroundStyle(Palette.primary)
            }
            .font(.system(size: 11, weight: .semibold))
            .tracking(2.6)

            StatusBlock(model: model, actions: actions, animate: animate)
                .padding(.top, 16)

            VStack(spacing: 10) {
                FeatureRow(icon: "printer", title: "AirPrint", detail: airPrintDetail) {
                    switch model.airPrint {
                    case .starting: EmptyView()
                    case .available(added: true): Check()
                    case .available(added: false): PillButton(title: "Add to Mac", action: actions.addToMac)
                    }
                }
                FeatureRow(icon: "scanner", title: "Scan to Mac", detail: scanDetail) {
                    if model.lastScan != nil {
                        PillButton(title: "Last Scan", action: actions.openLastScan)
                    } else if model.scanName != nil {
                        Check()
                    }
                }
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var airPrintDetail: String {
        switch model.airPrint {
        case .starting: return "Starting…"
        case .available(added: true): return "Print from any app on this Mac"
        case .available(added: false): return "Available to this Mac only"
        }
    }

    private var scanDetail: String {
        guard let name = model.scanName else { return "Waiting for the printer…" }
        return "SCAN → Computer → \(name)"
    }
}

struct StatusBlock: View {
    var model: PanelModel
    var actions: PanelActions
    var animate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                StatusDot(color: model.tone.color, glow: model.activity)
                Text(model.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if model.canCancel { PillButton(title: "Cancel", action: actions.cancelScan) }
            }
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            if model.activity || model.progress != nil {
                ActivityBar(progress: model.progress, color: model.tone.color, animate: animate)
                    .frame(height: 4)
                    .padding(.leading, 18)
                    .padding(.top, 5)
            }
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    Text(notice.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(notice.isError ? Palette.amber : Palette.green)
                .padding(.leading, 18)
                .padding(.top, 3)
            }
        }
    }
}

// MARK: - Components

struct StatusDot: View {
    var color: Color
    var glow: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(glow ? 0.9 : 0.5), radius: glow ? 6 : 3)
    }
}

struct ActivityBar: View {
    var progress: Double?
    var color: Color
    var animate: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if let progress {
                    Capsule().fill(color).frame(width: max(4, g.size.width * min(1, progress)))
                        .animation(.easeOut(duration: 0.4), value: progress)
                } else if animate {
                    TimelineView(.animation) { context in
                        sweep(width: g.size.width, t: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    sweep(width: g.size.width, t: 0.6)
                }
            }
        }
        .clipShape(Capsule())
    }

    private func sweep(width: Double, t: Double) -> some View {
        let segment = width * 0.32
        let x = (t.truncatingRemainder(dividingBy: 1.5) / 1.5) * (width + segment) - segment
        return Capsule()
            .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .frame(width: segment)
            .offset(x: x)
    }
}

struct FeatureRow<Trailing: View>: View {
    var icon: String
    var title: String
    var detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.primary.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct Check: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(Palette.green)
    }
}

struct PillButton: View {
    var title: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.18 : 0.11)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
