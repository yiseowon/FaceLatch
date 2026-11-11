import AppKit
import ApplicationServices
import CoreGraphics
import OSLog
import AVFoundation
import AudioToolbox

final class FaceLatch: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let camera = FaceCamera()
    private lazy var motion = MotionPanel()
    private var enrollmentWindow: EnrollmentWindow?
    private var samples: [[Float]] = []
    private var password = Data()
    private var attempt = UUID()
    private var scanMode: FaceCamera.Mode?
    private var unlockSubmitted = false
    private var lockScanStarted = false
    private var lockMessage: String?
    private var displaySleeping = false
    private let waitingMessage = "얼굴 대기 중"
    private let manualUnlockMessage = "암호를 직접 입력하세요"
    private let paymentSuccessSound: SystemSoundID? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/payment_success.aif"
        var sound: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &sound)
        return status == noErr ? sound : nil
    }()
    private var lockMotionTestUntil: Date?
    private var lockMotionTestPlaying = false
    private let log = Logger(subsystem: "local.facelatch.mac", category: "lock")
    private var observers: [NSObjectProtocol] = []
    private let info = NSMenuItem(title: "얼굴을 등록하세요", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "Mac 잠금 해제 켜기…", action: #selector(toggleUnlock), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "FaceLatch")
        status.menu = menu
        menu.addItem(info)
        add("얼굴 등록…", #selector(enroll))
        add("얼굴 인식 테스트", #selector(test))
        add("잠금 해제 모션 미리보기", #selector(preview))
        add("실제 잠금 화면 모션 테스트…", #selector(armLockMotionTest))
        menu.addItem(.separator())
        toggle.target = self
        menu.addItem(toggle)
        add("FaceLatch 종료", #selector(quit), key: "q")

        let system = DistributedNotificationCenter.default()
        observers.append(system.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.scheduleUnlock()
        })
        observers.append(system.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenUnlocked()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.displaySleeping = false
                self.scheduleUnlock()
            })
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.displaySleeping = true
                self.cancel()
                self.lockScanStarted = false
                self.lockMessage = self.unlockSubmitted ? self.manualUnlockMessage : nil
            })
        }
        scheduleUnlock()
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.async { self.preview() }
        }
    }

    private func add(_ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func alert(_ text: String, detail: String) {
        let dialog = NSAlert()
        dialog.messageText = text
        dialog.informativeText = detail
        NSApp.activate()
        dialog.runModal()
    }

    @objc private func enroll() {
        start(.enroll)
    }

    @objc private func test() {
        guard !samples.isEmpty else {
            alert("얼굴을 먼저 등록하세요", detail: "메뉴 막대의 얼굴 등록을 선택하세요.")
            return
        }
        start(.test)
    }

    @objc private func toggleUnlock() {
        if !password.isEmpty {
            clearPassword()
            cancel()
            return
        }
        guard !samples.isEmpty else {
            alert("얼굴을 먼저 등록하세요", detail: "메뉴 막대의 얼굴 등록을 선택하세요.")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            alert("카메라 권한이 필요해요", detail: "시스템 설정 → 개인정보 보호 및 보안 → 카메라에서 FaceLatch를 허용하세요.")
            return
        }
        guard KeystrokeInjector.isAccessibilityTrusted() || KeystrokeInjector.promptForAccessibility() else {
            alert("손쉬운 사용 권한이 필요해요", detail: "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에 FaceLatch.app을 추가하고, 이 메뉴를 다시 선택하세요.")
            return
        }
        let dialog = NSAlert()
        dialog.messageText = "Mac 잠금 해제 켜기"
        dialog.informativeText = "등록된 얼굴이 확인되면 이 암호로 Mac 잠금을 자동으로 해제합니다. 암호는 앱을 끄거나 기능을 끌 때까지 메모리에 남습니다."
        dialog.addButton(withTitle: "켜기")
        dialog.addButton(withTitle: "취소")
        let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Mac 로그인 암호"
        dialog.accessoryView = field
        dialog.window.initialFirstResponder = field
        NSApp.activate()
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        password = Data(field.stringValue.utf8)
        field.stringValue = ""
        guard !password.isEmpty else { return }
        toggle.title = "Mac 잠금 해제 끄기"
        info.title = "Mac 잠금 해제 켜짐"
    }

    private func clearPassword() {
        password.resetBytes(in: 0..<password.count)
        password.removeAll()
        toggle.title = "Mac 잠금 해제 켜기…"
        info.title = samples.isEmpty ? "얼굴을 등록하세요" : "얼굴 등록됨"
    }

    @objc private func armLockMotionTest() {
        alert("실제 잠금 화면 모션 테스트", detail: "확인을 누른 뒤 30초 안에 전원 버튼을 짧게 누르거나 Control–Command–Q를 누르세요. 잠금 화면에서 얼굴 아이콘이 회전한 뒤 초록색 체크로 바뀝니다. 테스트가 끝나면 Touch ID나 암호로 직접 잠금을 해제하세요.")
        lockMotionTestUntil = Date().addingTimeInterval(30)
        log.notice("Lock motion test armed")
    }

    private func scheduleUnlock() {
        let current = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.attempt == current, !self.displaySleeping,
                  LockMonitor.isScreenActuallyLocked() else { return }
            self.showLockedScreen()
        }
    }

    private func showLockedScreen() {
        guard !lockMotionTestPlaying else { return }
        if let expiry = lockMotionTestUntil, expiry > Date() {
            lockMotionTestUntil = nil
            cancel()
            lockMotionTestPlaying = true
            motion.show("모션 테스트", locked: true)
            let current = attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.attempt == current, LockMonitor.isScreenActuallyLocked() else { return }
                self.motion.succeed("모션 테스트")
            }
            return
        }
        if scanMode == .unlock || lockScanStarted || unlockSubmitted {
            motion.keepOnLockScreen(lockMessage ?? motion.state.message,
                                    recognized: lockMessage != manualUnlockMessage && motion.state.success)
        } else if password.isEmpty {
            cancel(hideMotion: false)
            motion.keepOnLockScreen(samples.isEmpty ? "얼굴 등록 필요" : "얼굴 잠금 해제 꺼짐")
        } else if !KeystrokeInjector.isAccessibilityTrusted() {
            cancel(hideMotion: false)
            motion.keepOnLockScreen("손쉬운 사용 권한 필요")
        } else {
            lockScanStarted = true
            log.notice("Starting lock screen face scan")
            start(.unlock)
        }
    }

    private func screenUnlocked() {
        guard !LockMonitor.isScreenActuallyLocked() else { return }
        let wasSubmitted = unlockSubmitted
        unlockSubmitted = false
        lockScanStarted = false
        lockMessage = nil
        cancel(hideMotion: false)
        if wasSubmitted {
            log.notice("Screen unlocked after password submission")
        }
        motion.hide(animated: true)
    }

    private func start(_ mode: FaceCamera.Mode) {
        cancel(hideMotion: mode != .unlock)
        scanMode = mode
        let current = attempt
        if mode == .enroll {
            let window = EnrollmentWindow()
            window.onClose = { [weak self] in
                guard let self, self.attempt == current else { return }
                self.cancel()
            }
            enrollmentWindow = window
            window.present()
        } else if mode == .unlock {
            motion.keepOnLockScreen(waitingMessage)
        } else {
            motion.show("카메라를 바라보세요")
        }
        camera.start(mode: mode, reference: samples, preview: { [weak self] session in
            guard let self, self.attempt == current else { return }
            self.enrollmentWindow?.attach(session)
        }, progress: { [weak self] message, count in
            guard let self, self.attempt == current else { return }
            if let window = self.enrollmentWindow {
                window.update(message, count: count)
            } else if mode != .unlock {
                self.motion.state.message = message
            }
        }) { [weak self] result in
            guard let self, self.attempt == current else { return }
            switch result {
            case let .enrolled(samples):
                self.scanMode = nil
                self.samples = samples
                self.enrollmentWindow?.dismiss()
                self.enrollmentWindow = nil
                self.clearPassword()
                self.motion.show("얼굴 등록 완료")
                self.finishMotion("얼굴 등록 완료")
            case .matched:
                if mode == .unlock {
                    self.log.notice("Lock screen face matched")
                    self.scanMode = nil
                    self.scheduleAutomaticUnlock()
                } else {
                    self.scanMode = nil
                    self.finishMotion("얼굴 인식 성공")
                }
            case let .retryable(message):
                if mode == .unlock {
                    self.waitForAnotherScan(current)
                } else {
                    self.cancel()
                    self.alert("얼굴 확인 실패", detail: message)
                }
            case let .failed(message):
                if mode == .unlock {
                    self.log.notice("Lock screen scan unavailable")
                    self.cancel(hideMotion: false)
                    let status = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                        ? "얼굴 인식을 시작할 수 없어요" : "카메라 권한 필요"
                    self.lockMessage = status
                    if LockMonitor.isScreenActuallyLocked() { self.motion.keepOnLockScreen(status) }
                } else {
                    self.cancel()
                    self.alert("얼굴 확인 실패", detail: message)
                }
            }
        }
    }

    private func waitForAnotherScan(_ current: UUID) {
        scanMode = nil
        guard !displaySleeping, LockMonitor.isScreenActuallyLocked() else { return }
        lockMessage = waitingMessage
        motion.keepOnLockScreen(waitingMessage)
        log.notice("No match yet; waiting for another lock screen face scan")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.attempt == current, !self.displaySleeping,
                  !self.unlockSubmitted, LockMonitor.isScreenActuallyLocked() else { return }
            // Recheck configuration through the normal lock-screen path before starting again.
            self.lockScanStarted = false
            self.lockMessage = nil
            self.showLockedScreen()
        }
    }

    private func scheduleAutomaticUnlock() {
        guard !unlockSubmitted, !password.isEmpty, !displaySleeping,
              LockMonitor.isScreenActuallyLocked() else { return }
        lockMessage = "잠금 해제 중"
        motion.succeed("잠금 해제 중")
        playRecognitionSound()
        let current = attempt
        // Let the check finish drawing before triggering the lock-screen transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + UnlockMotion.recognitionDuration + 0.08) { [weak self] in
            guard let self, self.attempt == current, !self.displaySleeping, !self.unlockSubmitted,
                  !self.password.isEmpty, LockMonitor.isScreenActuallyLocked() else { return }
            self.submitUnlock(current)
        }
    }

    private func submitUnlock(_ current: UUID) {
        do {
            try KeystrokeInjector.submitPassword(password)
            unlockSubmitted = true
            log.notice("Submitted one automatic unlock attempt")
        } catch {
            guard LockMonitor.isScreenActuallyLocked() else { return }
            showManualUnlock()
            log.notice("Could not submit the lock screen password")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.attempt == current else { return }
            if LockMonitor.isScreenActuallyLocked() {
                self.showManualUnlock()
                self.log.notice("Screen still locked after password submission")
            } else {
                self.screenUnlocked()
            }
        }
    }

    private func showManualUnlock() {
        lockMessage = manualUnlockMessage
        motion.keepOnLockScreen(manualUnlockMessage)
    }

    private func playRecognitionSound() {
        if let paymentSuccessSound {
            AudioServicesPlayAlertSound(paymentSuccessSound)
        }
    }

    @objc private func preview() {
        guard scanMode == nil else { return }
        cancel()
        motion.show("잠겨 있음")
        finishMotion("잠금 해제", delay: 0.45, playSound: true)
    }

    private func finishMotion(_ message: String, delay: TimeInterval = 0, playSound: Bool = false) {
        let current = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.attempt == current else { return }
            self.motion.succeed(message)
            if playSound { self.playRecognitionSound() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.35) { [weak self] in
            guard let self, self.attempt == current else { return }
            self.motion.hide()
        }
    }

    private func cancel(hideMotion: Bool = true) {
        attempt = UUID()
        scanMode = nil
        lockMotionTestPlaying = false
        camera.stop()
        enrollmentWindow?.dismiss()
        enrollmentWindow = nil
        if hideMotion { motion.hide() }
    }

    @objc private func quit() {
        clearPassword()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = FaceLatch()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
