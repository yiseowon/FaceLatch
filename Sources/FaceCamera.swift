import AVFoundation
import CoreImage
import QuartzCore

final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Mode { case enroll, test, unlock }
    enum Result { case enrolled([[Float]]), matched, retryable(String), failed(String) }

    static let enrollmentSampleCount = 8

    private var enrollmentPreview: ((AVCaptureSession) -> Void)?
    private var scanProgress: ((String, Int) -> Void)?
    private var lastScanStatus = ""
    private var lastReportedCount = -1

    private let queue = DispatchQueue(label: "local.facelatch.camera", qos: .userInitiated)
    private let context = CIContext()
    private var session: AVCaptureSession?
    private var embedder: ArcFaceEmbedder?
    private var generation = UUID()
    private var activeMode: Mode?
    private var samples: [[Float]] = []
    private var reference: [[Float]] = []
    private var gate = FaceMatchGate()
    private var deadline: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var completion: ((Result) -> Void)?

    func start(mode: Mode, reference: [[Float]],
               preview: ((AVCaptureSession) -> Void)? = nil,
               progress: ((String, Int) -> Void)? = nil,
               completion: @escaping (Result) -> Void) {
        queue.async {
            self.stopOnQueue()
            self.activeMode = mode
            self.reference = reference
            self.completion = completion
            self.enrollmentPreview = preview
            self.scanProgress = progress
            self.lastScanStatus = ""
            self.lastReportedCount = -1
            self.samples = []
            self.gate = FaceMatchGate()
            self.lastFrame = 0
            let request = self.generation

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configure()
            case .notDetermined where mode != .unlock:
                AVCaptureDevice.requestAccess(for: .video) { allowed in
                    self.queue.async {
                        guard self.generation == request else { return }
                        if allowed { self.configure() }
                        else { self.finish(.failed("카메라 접근이 거부됐어요.")) }
                    }
                }
            default:
                self.finish(.failed("시스템 설정에서 FaceLatch의 카메라 접근을 허용하세요."))
            }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func configure() {
        do {
            if embedder == nil { embedder = try ArcFaceEmbedder() }
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }
        do {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                           mediaType: .video, position: .unspecified).devices
            guard let camera = devices.first(where: { !$0.isContinuityCamera }) else {
                finish(.retryable("Mac 내장 카메라를 찾지 못했어요."))
                return
            }
            let session = AVCaptureSession()
            session.sessionPreset = .vga640x480
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddInput(input), session.canAddOutput(output) else {
                finish(.retryable("카메라를 시작할 수 없어요."))
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
            self.session = session
            session.startRunning()
            guard session.isRunning else {
                finish(.retryable("카메라가 시작되지 않았어요. 다른 앱에서 카메라를 사용 중인지 확인하세요."))
                return
            }
            if let preview = enrollmentPreview {
                DispatchQueue.main.async { preview(session) }
            }
            let request = generation
            let isEnrollment = activeMode == .enroll
            let duration: TimeInterval = isEnrollment ? 20 : 7
            deadline = CACurrentMediaTime() + duration
            queue.asyncAfter(deadline: .now() + duration) {
                guard self.generation == request else { return }
                let message = self.lastScanStatus.isEmpty
                    ? "카메라 영상이 들어오지 않았어요."
                    : self.lastScanStatus
                self.finish(.retryable(message))
            }
        } catch {
            finish(.retryable(error.localizedDescription))
        }
    }

    private func finish(_ result: Result) {
        let callback = completion
        stopOnQueue()
        DispatchQueue.main.async { callback?(result) }
    }

    private func stopOnQueue() {
        generation = UUID()
        completion = nil
        enrollmentPreview = nil
        scanProgress = nil
        activeMode = nil
        session?.stopRunning()
        session = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput frame: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard let mode = activeMode, now < deadline, now - lastFrame >= (mode == .enroll ? 0.28 : 0.075),
              let buffer = CMSampleBufferGetImageBuffer(frame) else { return }
        lastFrame = now
        let source = CIImage(cvPixelBuffer: buffer)
        do {
            guard let image = context.createCGImage(source, from: source.extent) else {
                reportProgress("카메라 영상을 읽을 수 없어요.")
                gate = FaceMatchGate()
                return
            }
            let faces = try FaceDetector.detectFaces(in: image)
            guard faces.count == 1 else {
                reportProgress(faces.isEmpty ? "얼굴이 보이지 않아요" : "한 사람만 화면에 들어와 주세요")
                gate = FaceMatchGate()
                return
            }
            guard let aligned = FaceAligner.align(faces[0], from: image), let embedder else {
                reportProgress("얼굴이 잘 보이도록 정면을 봐 주세요.")
                gate = FaceMatchGate()
                return
            }
            let vector = try embedder.embedding(for: aligned.image)

            if mode == .enroll {
                samples.append(vector)
                reportProgress("얼굴 확인됨 · \(samples.count)/\(Self.enrollmentSampleCount)", count: samples.count)
                if samples.count == Self.enrollmentSampleCount { finish(.enrolled(samples)) }
                return
            }
            let bestScore = reference.map { FaceEmbedding.cosineSimilarity($0, vector) }.max()
            if gate.observe(score: bestScore) {
                finish(.matched)
            } else {
                reportProgress("등록된 얼굴과 비교 중")
            }
        } catch {
            finish(.failed("얼굴 처리 중 오류가 발생했어요. \(error.localizedDescription)"))
        }
    }

    private func reportProgress(_ message: String, count: Int = 0) {
        guard let progress = scanProgress,
              message != lastScanStatus || count != lastReportedCount else { return }
        lastScanStatus = message
        lastReportedCount = count
        DispatchQueue.main.async { progress(message, count) }
    }

}
