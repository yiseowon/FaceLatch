import AppKit
import AVFoundation

final class EnrollmentWindow: NSWindowController, NSWindowDelegate {
    private let preview = EnrollmentPreview(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
    private let message = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 475),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "FaceLatch · 얼굴 등록"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "원 안에 얼굴을 맞춰 주세요")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        message.textColor = .secondaryLabelColor
        progress.isIndeterminate = false
        progress.maxValue = Double(FaceCamera.enrollmentSampleCount)

        let content = NSStackView(views: [title, preview, message, progress])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        guard let root = window.contentView else { return }
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 480),
            preview.heightAnchor.constraint(equalToConstant: 360),
            progress.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        update("카메라를 준비하는 중…", count: 0)
        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func attach(_ session: AVCaptureSession?) {
        preview.camera.session = session
    }

    func update(_ text: String, count: Int) {
        message.stringValue = text
        progress.doubleValue = Double(count)
        preview.guide.strokeColor = (count > 0 ? NSColor.systemGreen : .white).cgColor
    }

    func dismiss() {
        attach(nil)
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        attach(nil)
        onClose?()
    }
}

private final class EnrollmentPreview: NSView {
    let camera = AVCaptureVideoPreviewLayer()
    let guide = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        camera.videoGravity = .resizeAspectFill
        guide.fillColor = nil
        guide.lineWidth = 3
        guide.strokeColor = NSColor.white.cgColor
        layer?.addSublayer(camera)
        layer?.addSublayer(guide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        camera.frame = bounds
        guide.frame = bounds
        let diameter = min(bounds.width, bounds.height) * 0.73
        let circle = CGRect(x: (bounds.width - diameter) / 2,
                            y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        guide.path = CGPath(ellipseIn: circle, transform: nil)
    }
}
