import AVFoundation
import SwiftUI

/// Runs the camera, keeps the last minutes as compressed frames in memory,
/// shows them delayed (not mirrored, like a played-back video) and saves
/// replays to Photos. A small live preview helps to set the phone up.
///
/// Threads: `sessionQueue` configures the capture session; everything about
/// frames (encoder, buffer, replay) lives on the serial `dataQueue`;
/// @Published properties change on the main thread only.
final class CameraEngine: NSObject, ObservableObject,
                          AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate,
                          @unchecked Sendable {

    /// Volume up/down walk through these steps.
    static let delayChoices = [20, 25, 30, 35, 40, 45, 50, 55, 60, 70, 80, 90, 100, 110, 120]
    static let defaultDelay = 30
    /// The buffer always holds the longest delay (plus a little), so a longer
    /// delay can be shown at once.
    private static let keepSec = Double(delayChoices.last!) + 10

    // MARK: Main thread state
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart = Date()
    @Published private(set) var toast: String?
    @Published private(set) var permissionDenied = false
    /// Delay in seconds.
    @Published private(set) var delay = CameraEngine.defaultDelay
    /// Width / height of the upright picture (3/4 for a 4:3 sensor format).
    @Published private(set) var aspect: CGFloat = 3.0 / 4.0
    /// Bumped on every delay change, so the view can flash the new value.
    @Published private(set) var delayChangeCount = 0

    let session = AVCaptureSession()
    /// The live picture: the same upright frames as the replay, shown at once.
    let liveLayer = AVSampleBufferDisplayLayer()
    let displayLayer: AVSampleBufferDisplayLayer
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var coordinatorObservation: NSKeyValueObservation?
    /// Last clear portrait/landscape orientation (flat on a table does not count).
    private var lastOrientation = UIDeviceOrientation.portrait
    private var toastToken = 0
    private var wantBack = false

    // MARK: Session queue state
    private let sessionQueue = DispatchQueue(label: "bouldercam.session")
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private var configuredBack: Bool?
    private var micAllowed = false

    // MARK: Data queue state
    private struct Frame { let sb: CMSampleBuffer; let t: Double; let key: Bool }
    private let dataQueue = DispatchQueue(label: "bouldercam.data", qos: .userInteractive)
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private var encoder: VideoEncoder?
    private var generation = 0
    private var frames: [Frame] = []
    private var firstSeq = 0                 // sequence number of frames[0]
    private struct Sound { let sb: CMSampleBuffer; let t: Double }
    private var audio: [Sound] = []
    private var hasAudio = false
    private var delaySec = Double(CameraEngine.defaultDelay)
    private var feedSeq: Int?                // next frame to hand to the replay
    private var hideBefore = 0.0             // frames before this are decoded but not shown
    private var recorder: ClipWriter?
    private var recSeq: Int?                 // next frame for the recording
    private var recAudioT = -Double.infinity // audio up to this time is in the recording
    private var feedTimer: DispatchSourceTimer?
    private var lastPublish = 0.0

    override init() {
        let layer = AVSampleBufferDisplayLayer()
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        timebase = tb!
        super.init()
        liveLayer.videoGravity = .resizeAspect
        displayLayer.videoGravity = .resizeAspect
        displayLayer.controlTimebase = timebase

        // Center Stage would follow and crop the picture: keep the full, fixed view.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let timer = DispatchSource.makeTimerSource(queue: dataQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.feed() }
        timer.resume()
        feedTimer = timer

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            let o = UIDevice.current.orientation
            if o.isPortrait || o.isLandscape { self?.lastOrientation = o }
            self?.learnPortraitAngle()
        }
    }

    // MARK: - Which way is up

    /// The rotation that makes the frames upright while the phone stands in
    /// portrait. Usually 90°, but not on every camera (on the iPhone Air's front
    /// camera it is 0°). Apple's rotation coordinator knows it; we read it while
    /// the phone actually stands upright and remember it per camera.
    private static func portraitAngleKey(back: Bool) -> String { back ? "portraitAngleBack" : "portraitAngleFront" }

    static func storedPortraitAngle(back: Bool) -> CGFloat {
        let v = UserDefaults.standard.object(forKey: portraitAngleKey(back: back)) as? Double
        return CGFloat(v ?? 90)
    }

    /// Main thread: when the phone stands upright, take the coordinator's angle.
    private func learnPortraitAngle() {
        guard UIDevice.current.orientation == .portrait, let coord = rotationCoordinator else { return }
        let angle = coord.videoRotationAngleForHorizonLevelCapture
        let back = wantBack
        guard angle != Self.storedPortraitAngle(back: back) else { return }
        Self.diag("learned portrait angle \(angle) for back=\(back)")
        UserDefaults.standard.set(Double(angle), forKey: Self.portraitAngleKey(back: back))
        dataQueue.async { self.resetBuffer() }
        sessionQueue.async {
            guard self.configuredBack == back, let c = self.videoOut.connection(with: .video),
                  c.isVideoRotationAngleSupported(angle) else { return }
            c.videoRotationAngle = angle
        }
    }

    /// Diagnose output (shows in `devicectl device process launch --console`).
    static func diag(_ text: String) { NSLog("BoulderCam-DIAG %@", text) }

    // MARK: - Controls (main thread)

    func start(back: Bool) {
        wantBack = back
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                self.sessionQueue.async {
                    self.micAllowed = mic
                    if self.configuredBack != back { self.configure(back: back) }
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        }
    }

    /// App goes to the background: save a running recording, stop the camera, forget the buffer.
    func stop() {
        if isRecording { stopRecording() }
        sessionQueue.async { self.session.stopRunning() }
        dataQueue.async { self.resetBuffer() }
    }

    func switchCamera(back: Bool) {
        guard back != wantBack else { return }
        if isRecording { stopRecording() }
        wantBack = back
        dataQueue.async { self.resetBuffer() }
        sessionQueue.async {
            self.configure(back: back)
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func setDelay(_ seconds: Int) {
        guard seconds != delay else { return }
        delay = seconds
        delayChangeCount += 1
        dataQueue.async {
            self.delaySec = Double(seconds)
            self.resync()
        }
    }

    /// Volume up (+1) and down (-1): one step longer or shorter.
    func stepDelay(_ direction: Int) {
        let steps = Self.delayChoices
        let i = steps.firstIndex(where: { $0 >= delay }) ?? steps.count - 1
        let j: Int
        if direction > 0 {
            j = steps[i] > delay ? i : min(i + 1, steps.count - 1)
        } else {
            j = max(i - 1, 0)
        }
        if steps[j] == delay {
            delayChangeCount += 1          // still flash the value at the end of the range
        } else {
            setDelay(steps[j])
        }
    }

    /// The record button: records the delayed video, from the moment shown
    /// when pressed until the moment shown at the second press.
    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let transform = Self.transform(for: lastOrientation, back: wantBack)
        Self.diag("record start: orientation=\(lastOrientation.rawValue) back=\(wantBack) coordinatorCapture=\(rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? -1)")
        isRecording = true
        recordingStart = Date()
        dataQueue.async {
            guard let writer = ClipWriter(transform: transform, audioSettings: self.audioSettings(),
                                          waitWhenBusy: false) else {
                self.show("Aufnahme fehlgeschlagen.")
                DispatchQueue.main.async { self.isRecording = false }
                return
            }
            self.recorder = writer
            let shown = CMTimebaseGetTime(self.timebase).seconds
            // Start at the keyframe just before the moment on screen (at most 1 s earlier).
            if let i = self.frames.lastIndex(where: { $0.key && $0.t <= shown })
                ?? self.frames.firstIndex(where: { $0.key }) {
                self.recSeq = self.firstSeq + i
                self.recAudioT = self.frames[i].t - 0.001
            } else {
                self.recSeq = self.firstSeq + self.frames.count
                self.recAudioT = -.infinity
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        dataQueue.async {
            self.feedRecorder(upTo: CMTimebaseGetTime(self.timebase).seconds)
            guard let r = self.recorder else { return }
            self.recorder = nil
            self.recSeq = nil
            r.finish { url in
                guard let url else { self.show("Nichts aufgenommen."); return }
                ClipWriter.saveToPhotos(url) { ok, msg in
                    self.show(ok ? "Aufnahme in Fotos gespeichert" : (msg ?? ""))
                }
            }
        }
    }

    func show(_ text: String, seconds: Double = 3) {
        DispatchQueue.main.async {
            self.toastToken += 1
            let token = self.toastToken
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if self.toastToken == token { self.toast = nil }
            }
        }
    }

    /// Frames are stored upright for a phone standing in portrait. When it
    /// stands sideways, the file gets a rotation so Photos shows it the right
    /// way up. The front camera's frames are not mirrored, which turns the
    /// direction of the needed rotation around.
    private static func transform(for orientation: UIDeviceOrientation, back: Bool) -> CGAffineTransform {
        let degrees: CGFloat
        switch orientation {
        case .landscapeLeft: degrees = back ? -90 : 90     // top of the phone points left
        case .landscapeRight: degrees = back ? 90 : -90
        case .portraitUpsideDown: degrees = 180
        default: degrees = 0
        }
        return CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }

    // MARK: - Session setup (session queue)

    private static func camera(back: Bool) -> AVCaptureDevice? {
        if back {
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    /// The format that shows the most of the scene (widest field of view in
    /// both directions, so nothing is cut off), up to 1920 pixels on the long
    /// side and 30 fps; among equals the sharper one.
    private static func bestFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        func coverage(_ f: AVCaptureDevice.Format) -> Double {
            let d = dims(f)
            let h = Double(f.videoFieldOfView) * .pi / 180
            let v = 2 * atan(tan(h / 2) * Double(d.height) / Double(d.width))
            return (h * v * 100).rounded()        // tiny differences count as equal
        }
        let candidates = device.formats.filter { f in
            let d = dims(f)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
            guard max(d.width, d.height) <= 1920, d.width > 0, d.height > 0 else { return false }
            return f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        return candidates.max { a, b in
            let ca = coverage(a), cb = coverage(b)
            if ca != cb { return ca < cb }
            let da = dims(a), db = dims(b)
            let pa = Int(da.width) * Int(da.height), pb = Int(db.width) * Int(db.height)
            if pa != pb { return pa < pb }
            return CMFormatDescriptionGetMediaSubType(a.formatDescription) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }

    private func configure(back: Bool) {
        session.beginConfiguration()
        if let old = videoInput {
            session.removeInput(old)
            videoInput = nil
        }
        guard let device = Self.camera(back: back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            show("Kamera nicht verfügbar.")
            return
        }
        session.addInput(input)
        videoInput = input
        configuredBack = back

        if !outputsAdded {
            videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.setSampleBufferDelegate(self, queue: dataQueue)
            if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
            if micAllowed, let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput), session.canAddOutput(audioOut) {
                session.addInput(micInput)
                audioOut.setSampleBufferDelegate(self, queue: dataQueue)
                session.addOutput(audioOut)
                dataQueue.async { self.hasAudio = true }
            }
            outputsAdded = true
        }

        if let format = Self.bestFormat(device), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            let frame = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = false   // correction trims the edges
            }
            device.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let upright = CGFloat(min(d.width, d.height)) / CGFloat(max(d.width, d.height))
            DispatchQueue.main.async { self.aspect = upright }
        } else {
            session.sessionPreset = .high
        }

        Self.diag("device=\(device.deviceType.rawValue) pos=\(device.position.rawValue) formats:")
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            Self.diag("  \(d.width)x\(d.height) sub=\(String(format: "%08x", sub)) fov=\(f.videoFieldOfView) maxfps=\(f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)")
        }
        let ad = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        Self.diag("active=\(ad.width)x\(ad.height) fov=\(device.activeFormat.videoFieldOfView)")
        if let c = videoOut.connection(with: .video) {
            Self.diag("conn before: angle=\(c.videoRotationAngle) sup90=\(c.isVideoRotationAngleSupported(90)) sup0=\(c.isVideoRotationAngleSupported(0)) mirrored=\(c.isVideoMirrored)")
            let angle = Self.storedPortraitAngle(back: back)
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false        // mirroring happens on screen only
            }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        }
        session.commitConfiguration()
        if let c = videoOut.connection(with: .video) {
            Self.diag("conn after commit: angle=\(c.videoRotationAngle) mirrored=\(c.isVideoMirrored)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let coord = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            self.rotationCoordinator = coord
            self.coordinatorObservation = coord.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                        options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.learnPortraitAngle() }
            }
            Self.diag("orientation=\(UIDevice.current.orientation.rawValue) coordinatorCapture=\(coord.videoRotationAngleForHorizonLevelCapture) coordinatorPreview=\(coord.videoRotationAngleForHorizonLevelPreview)")
        }
    }

    // MARK: - Frames (data queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOut {
            handleAudio(sampleBuffer)
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        showLive(sampleBuffer)
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            Self.diag("first frame: buffer=\(w)x\(h) connAngle=\(connection.videoRotationAngle) mirrored=\(connection.isVideoMirrored)")
            generation += 1
            let gen = generation
            encoder = VideoEncoder(width: w, height: h) { [weak self] encoded in
                self?.dataQueue.async { self?.handleEncoded(encoded, generation: gen) }
            }
        }
        encoder?.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func showLive(_ sb: CMSampleBuffer) {
        let live = liveLayer.sampleBufferRenderer
        if live.status == .failed || live.requiresFlushToResumeDecoding {
            live.flush(removingDisplayedImage: false, completionHandler: nil)
        }
        guard live.isReadyForMoreMediaData,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(arr) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        live.enqueue(sb)
    }

    private func handleEncoded(_ sb: CMSampleBuffer, generation gen: Int) {
        guard gen == generation, CMSampleBufferDataIsReady(sb) else { return }
        let t = sb.ptsSeconds
        if let last = frames.last, t <= last.t { return }
        frames.append(Frame(sb: sb, t: t, key: sb.isKeyframe))

        let limit = t - Self.keepSec
        var drop = 0
        while drop < frames.count - 1, frames[drop].t < limit { drop += 1 }
        if drop > 0 {
            frames.removeFirst(drop)
            firstSeq += drop
        }
        var dropAudio = 0
        while dropAudio < audio.count, audio[dropAudio].t < limit { dropAudio += 1 }
        if dropAudio > 0 { audio.removeFirst(dropAudio) }

        if t - lastPublish > 0.25 {
            lastPublish = t
            let buffered = t - frames[0].t
            DispatchQueue.main.async { self.bufferedSeconds = buffered }
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let copy = sb.audioDeepCopy() else { return }
        audio.append(Sound(sb: copy, t: copy.ptsSeconds))
    }

    private func audioSettings() -> [String: Any]? {
        guard hasAudio else { return nil }
        return audioOut.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
    }

    private func resetBuffer() {
        firstSeq += frames.count
        frames.removeAll()
        audio.removeAll()
        encoder = nil
        generation += 1
        feedSeq = nil
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        DispatchQueue.main.async { self.bufferedSeconds = 0 }
    }

    /// Start the replay over: the timebase runs `delaySec` behind the newest frame,
    /// decoding begins at the keyframe just before that moment.
    private func resync() {
        feedSeq = nil
        guard delaySec > 0, let newest = frames.last?.t else { return }
        let target = newest - delaySec
        renderer.flush(removingDisplayedImage: target < frames[0].t, completionHandler: nil)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 90_000))
        CMTimebaseSetRate(timebase, rate: 1)
        guard let start = frames.lastIndex(where: { $0.key && $0.t <= target })
                ?? frames.firstIndex(where: { $0.key }) else { return }
        feedSeq = firstSeq + start
        hideBefore = target
    }

    /// The recording follows the replay: every frame (and its sound) that has
    /// reached the screen goes into the file. A shorter delay makes the replay
    /// jump ahead, the recording then still gets the frames in between; a longer
    /// delay makes it wait, nothing is recorded twice.
    private func feedRecorder(upTo shown: Double) {
        guard let r = recorder, var seq = recSeq else { return }
        seq = max(seq, firstSeq)
        while seq - firstSeq < frames.count {
            let f = frames[seq - firstSeq]
            if f.t > shown { break }
            for a in audio {
                if a.t <= recAudioT { continue }
                if a.t > f.t { break }
                r.appendAudio(a.sb)
                recAudioT = a.t
            }
            r.appendVideo(f.sb)
            seq += 1
        }
        recSeq = seq
    }

    /// Called every 10 ms: hands the replay the frames due in the next half second.
    private func feed() {
        guard delaySec > 0, !frames.isEmpty else { return }
        if recorder != nil { feedRecorder(upTo: CMTimebaseGetTime(timebase).seconds) }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { resync(); return }
        guard var seq = feedSeq, seq >= firstSeq else { resync(); return }
        let now = CMTimebaseGetTime(timebase).seconds
        if let newest = frames.last?.t, abs((newest - delaySec) - now) > 1.0 { resync(); return }
        while renderer.isReadyForMoreMediaData {
            let i = seq - firstSeq
            guard i < frames.count else { break }
            let f = frames[i]
            if f.t > now + 0.5 { break }
            if f.t < hideBefore, let hidden = f.sb.hiddenCopy() {
                renderer.enqueue(hidden)
            } else {
                renderer.enqueue(f.sb)
            }
            seq += 1
        }
        feedSeq = seq
    }
}
