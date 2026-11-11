import AppKit
import SwiftUI
import OSLog

private struct FaceGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 48, y: rect.minY + rect.height * y / 48)
        }
        var path = Path()
        for (right, bottom) in [(false, false), (true, false), (false, true), (true, true)] {
            func corner(_ x: Double, _ y: Double) -> CGPoint {
                point(right ? 48 - x : x, bottom ? 48 - y : y)
            }
            path.move(to: corner(14, 5))
            path.addLine(to: corner(10, 5))
            path.addCurve(to: corner(6, 9), control1: corner(7.79, 5), control2: corner(6, 6.79))
            path.addLine(to: corner(6, 12))
        }
        for x in [16.0, 32.0] {
            path.move(to: point(x, 16))
            path.addLine(to: point(x, 20))
        }
        path.move(to: point(25, 17))
        path.addLine(to: point(22.5, 25))
        path.addLine(to: point(25.5, 25))
        path.move(to: point(15, 30))
        path.addCurve(to: point(33, 30), control1: point(19, 36), control2: point(29, 36))
        return path
    }
}

private struct SuccessCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.31, y: rect.height * 0.51))
        path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.63))
        path.addLine(to: CGPoint(x: rect.width * 0.69, y: rect.height * 0.38))
        return path
    }
}

struct RecognitionGlyph: View, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private func phase(from start: Double, to end: Double) -> Double {
        min(1, max(0, (progress - start) / (end - start)))
    }

    var body: some View {
        let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        let green = Color(red: 0.20, green: 0.84, blue: 0.36)
        let spin = phase(from: 0, to: 0.84)
        let arc = phase(from: 0.06, to: 0.27)
        let fill = phase(from: 0.42, to: 0.86)
        let check = phase(from: 0.64, to: 1)

        ZStack {
            FaceGlyph()
                .stroke(.white, style: stroke)
                .rotationEffect(.degrees(360 * spin))
                .opacity(1 - phase(from: 0.04, to: 0.26))
            Circle()
                .trim(from: 0, to: 0.27 + 0.73 * fill)
                .stroke(green, style: stroke)
                .padding(4)
                .rotationEffect(.degrees(-90 + 360 * spin))
                .opacity(arc)
            SuccessCheck()
                .trim(from: 0, to: check)
                .stroke(green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

final class MotionState: ObservableObject {
    @Published var success = false
    @Published var message = ""
    @Published var notchExtended = false
}

struct UnlockMotion: View {
    @ObservedObject var state: MotionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var notchSize: CGSize?

    static let iconSize: CGFloat = 48
    static let previewSize = CGSize(width: 162, height: 92)
    static let notchHeight: CGFloat = 68
    static let notchOverlap: CGFloat = 9
    static let collapseDuration = 0.24
    static let recognitionDuration = 0.70

    private var glyph: some View {
        RecognitionGlyph(progress: state.success ? 1 : 0)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .animation(reduceMotion ? nil : .timingCurve(0.36, 0.12, 0.24, 1, duration: Self.recognitionDuration),
                       value: state.success)
    }

    var body: some View {
        Group {
            if let notchSize {
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                        .fill(.black)
                        .scaleEffect(x: 1, y: state.notchExtended ? 1 : 0, anchor: .top)
                    glyph
                        .offset(y: state.notchExtended ? 13 + Self.notchOverlap : -Self.iconSize)
                        .opacity(state.notchExtended ? 1 : 0)
                }
                .frame(width: notchSize.width, height: notchSize.height)
                .clipped()
                .animation(state.notchExtended ? .easeOut(duration: 0.28) : .easeIn(duration: Self.collapseDuration),
                           value: state.notchExtended)
            } else {
                VStack(spacing: 6) {
                    glyph
                    Text(state.message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                }
                .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                .background(.black, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .accessibilityLabel(state.message)
    }
}

final class MotionPanel {
    let state = MotionState()
    private var delegated = false
    private var notchTransition: DispatchWorkItem?
    private let log = Logger(subsystem: "local.facelatch.mac", category: "motion")
    private let panel = NSPanel(contentRect: CGRect(origin: .zero, size: UnlockMotion.previewSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func show(_ message: String, locked: Bool = false) {
        hide()
        state.success = false
        state.message = message
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let notch = locked ? notchBounds(on: screen) : nil
        let size = notch?.size ?? UnlockMotion.previewSize
        let x = notch?.minX ?? (screen.frame.midX - size.width / 2)
        let y = notch?.minY ?? (screen.frame.maxY - max(12, screen.safeAreaInsets.top) - size.height - 8)
        panel.contentView = NSHostingView(rootView: UnlockMotion(state: state, notchSize: notch?.size))
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: false)
        panel.orderFrontRegardless()
        if locked && LockMonitor.isScreenActuallyLocked() {
            if let skyLight = NotchSkyLight.shared {
                let status = skyLight.delegate(panel)
                delegated = status == 0
                log.notice("Lock overlay attached: SkyLight status \(status)")
            } else {
                log.error("Lock overlay unavailable: SkyLight symbols missing")
            }
        }
        if notch != nil {
            let expand = DispatchWorkItem { [weak self] in self?.state.notchExtended = true }
            notchTransition = expand
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: expand)
        }
    }

    private func notchBounds(on screen: NSScreen) -> CGRect {
        let left = screen.auxiliaryTopLeftArea?.maxX ?? (screen.frame.midX - 64)
        let right = screen.auxiliaryTopRightArea?.minX ?? (screen.frame.midX + 64)
        let hasNotch = screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        let overlap = hasNotch ? UnlockMotion.notchOverlap : 0
        let edgeInset = hasNotch ? 1 / screen.backingScaleFactor : 0
        let top = screen.frame.maxY - screen.safeAreaInsets.top + overlap
        // Add height above the old bottom edge so the date keeps the same clearance.
        let height = UnlockMotion.notchHeight + overlap - 1
        let horizontalOffset = hasNotch ? 1 / screen.backingScaleFactor : 0
        return CGRect(x: left + edgeInset + horizontalOffset, y: top - height,
                      width: right - left - 2 * edgeInset, height: height)
    }

    func keepOnLockScreen(_ message: String, recognized: Bool = false) {
        if !panel.isVisible || !delegated {
            show(message, locked: true)
        }
        state.message = message
        state.success = recognized
    }

    func succeed(_ message: String) {
        state.message = message
        state.success = true
    }

    func detachFromLockScreen() {
        guard delegated else { return }
        NotchSkyLight.shared?.undelegate(panel)
        delegated = false
    }

    func hide(animated: Bool = false) {
        notchTransition?.cancel()
        notchTransition = nil
        let shouldCollapse = animated && panel.isVisible && state.notchExtended
        let wasDelegated = delegated
        detachFromLockScreen()
        if shouldCollapse {
            if wasDelegated {
                // Reorder into the desktop space after removing the lock-screen window association.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            state.notchExtended = false
            let collapse = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            notchTransition = collapse
            DispatchQueue.main.asyncAfter(deadline: .now() + UnlockMotion.collapseDuration + 0.03,
                                          execute: collapse)
            return
        }
        state.notchExtended = false
        panel.orderOut(nil)
    }
}
