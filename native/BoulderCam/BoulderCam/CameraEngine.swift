import AVFoundation
import SwiftUI

/// Runs the camera, keeps the last minutes as compressed frames in memory,
/// shows them live or delayed, records, and saves replays to Photos.
///
/// Threads: `sessionQueue` configures the capture session; everything about
/// frames (encoder, buffer, replay, recorder) lives on the serial `dataQueue`;
/// @Published properties change on the main thread only.
final class CameraEngine: NSObject, ObservableObject,
                          AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate,
                          @unchecked Sendable {

    static let delayChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120]
    /// Saving a replay starts this many seconds before the moment being shown.
    static let saveLeadIn = 30.0

    // MARK: Main thread state
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart = Date()
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var toast: String?
    @Published private(set) var permissionDenied = false
    /// Delay in seconds, 0 = live.
    @Published private(set) var delay = 0

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    let displayLayer: AVSampleBufferDisplayLayer
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
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
    private var audio: [CMSampleBuffer] = []
    private var hasAudio = false
    private var delaySec = 0.0
    private var keepSec = 100.0              // how much the buffer holds
    private var feedSeq: Int?                // next frame to hand to the replay
    private var hideBefore = 0.0             // frames before this are decoded but not shown
    private var recorder: ClipWriter?
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
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        displayLayer.videoGravity = .resizeAspect
        displayLayer.controlTimebase = timebase
        displayLayer.isHidden = true

        // Center Stage would follow and crop the picture: keep the full, fixed view.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let timer = DispatchSource.makeTimerSource(queue: dataQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.feed() }
        timer.resume()
        feedTimer = timer
    }

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

    /// `remembered` is the last delay other than live: the buffer keeps that much
    /// even in live mode, so switching back shows the replay right away.
    func setDelay(_ seconds: Int, remembered: Int) {
        delay = seconds
        displayLayer.isHidden = seconds == 0
        previewLayer.isHidden = seconds != 0
        dataQueue.async {
            let changed = self.delaySec != Double(seconds)
            self.delaySec = Double(seconds)
            self.keepSec = Double(max(seconds, remembered)) + Self.saveLeadIn + 10
            if seconds == 0 {
                self.feedSeq = nil
                self.renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            } else if changed {
                self.resync()
            }
        }
    }

    /// Volume button or the big button: stop a recording, otherwise save the
    /// replay (delayed mode) or start a recording (live mode).
    func primaryAction() {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        if isRecording {
            stopRecording()
        } else if delay > 0 {
            saveReplay(angle: angle)
        } else {
            startRecording(angle: angle)
        }
    }

    private func startRecording(angle: CGFloat) {
        isRecording = true
        recordingStart = Date()
        let transform = Self.transform(forAngle: angle)
        dataQueue.async {
            self.recorder = ClipWriter(transform: transform, audioSettings: self.audioSettings(),
                                       waitWhenBusy: false)
            self.encoder?.forceKeyframe = true
        }
    }

    private func stopRecording() {
        isRecording = false
        dataQueue.async {
            guard let r = self.recorder else { return }
            self.recorder = nil
            r.finish { url in
                guard let url else { self.show("Aufnahme fehlgeschlagen."); return }
                ClipWriter.saveToPhotos(url) { ok, msg in
                    self.show(ok ? "Aufnahme in Fotos gespeichert" : (msg ?? ""))
                }
            }
        }
    }

    /// Saves from `saveLeadIn` seconds before the moment being replayed up to now.
    private func saveReplay(angle: CGFloat) {
        show("Speichere …", seconds: 10)
        let transform = Self.transform(forAngle: angle)
        dataQueue.async {
            guard let newest = self.frames.last?.t else { self.show("Noch nichts aufgenommen."); return }
            let from = newest - self.delaySec - Self.saveLeadIn
            guard let start = self.frames.lastIndex(where: { $0.key && $0.t <= from })
                    ?? self.frames.firstIndex(where: { $0.key }) else {
                self.show("Noch nichts aufgenommen.")
                return
            }
            let startTime = self.frames[start].t
            let video = self.frames[start...].map(\.sb)
            let sound = self.audio.filter { $0.ptsSeconds >= startTime }
            let settings = self.audioSettings()
            DispatchQueue.global(qos: .userInitiated).async {
                guard let w = ClipWriter(transform: transform, audioSettings: settings, waitWhenBusy: true) else {
                    self.show("Speichern fehlgeschlagen.")
                    return
                }
                var i = 0, j = 0
                while i < video.count || j < sound.count {
                    if j >= sound.count || (i < video.count && video[i].ptsSeconds <= sound[j].ptsSeconds) {
                        w.appendVideo(video[i]); i += 1
                    } else {
                        w.appendAudio(sound[j]); j += 1
                    }
                }
                w.finish { url in
                    guard let url else { self.show("Speichern fehlgeschlagen."); return }
                    ClipWriter.saveToPhotos(url) { ok, msg in
                        self.show(ok ? "Wiederholung in Fotos gespeichert" : (msg ?? ""))
                    }
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

    /// Frames are always stored upright for portrait. When the phone stands
    /// sideways, the file gets a rotation so Photos shows it the right way up.
    private static func transform(forAngle angle: CGFloat) -> CGAffineTransform {
        var extra = (angle - 90).truncatingRemainder(dividingBy: 360)
        if extra < 0 { extra += 360 }
        return CGAffineTransform(rotationAngle: extra * .pi / 180)
    }

    // MARK: - Session setup (session queue)

    private static func camera(back: Bool) -> AVCaptureDevice? {
        if back {
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    /// The largest 4:3 format up to 1920 wide that does 30 fps; then the widest field of view.
    private static func bestFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        let candidates = device.formats.filter { f in
            let d = dims(f)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
            guard Int(d.width) * 3 == Int(d.height) * 4, d.width <= 1920 else { return false }
            return f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        return candidates.max { a, b in
            let da = dims(a), db = dims(b)
            if da.width != db.width { return da.width < db.width }
            if a.videoFieldOfView != b.videoFieldOfView { return a.videoFieldOfView < b.videoFieldOfView }
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
            device.unlockForConfiguration()
        } else {
            session.sessionPreset = .high
        }

        if let c = videoOut.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false        // mirroring happens on screen only
            }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
        }
        session.commitConfiguration()

        DispatchQueue.main.async {
            if let c = self.previewLayer.connection {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                if c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = false
                }
            }
            self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                                           previewLayer: self.previewLayer)
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
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            generation += 1
            let gen = generation
            encoder = VideoEncoder(width: w, height: h) { [weak self] encoded in
                self?.dataQueue.async { self?.handleEncoded(encoded, generation: gen) }
            }
            if recorder != nil { encoder?.forceKeyframe = true }
        }
        encoder?.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func handleEncoded(_ sb: CMSampleBuffer, generation gen: Int) {
        guard gen == generation, CMSampleBufferDataIsReady(sb) else { return }
        let t = sb.ptsSeconds
        if let last = frames.last, t <= last.t { return }
        frames.append(Frame(sb: sb, t: t, key: sb.isKeyframe))
        recorder?.appendVideo(sb)

        let limit = t - keepSec
        var drop = 0
        while drop < frames.count - 1, frames[drop].t < limit { drop += 1 }
        if drop > 0 {
            frames.removeFirst(drop)
            firstSeq += drop
        }
        var dropAudio = 0
        while dropAudio < audio.count, audio[dropAudio].ptsSeconds < limit { dropAudio += 1 }
        if dropAudio > 0 { audio.removeFirst(dropAudio) }

        if t - lastPublish > 0.25 {
            lastPublish = t
            let buffered = t - frames[0].t
            DispatchQueue.main.async { self.bufferedSeconds = buffered }
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let copy = sb.audioDeepCopy() else { return }
        audio.append(copy)
        recorder?.appendAudio(copy)
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
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        let target = newest - delaySec
        CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 90_000))
        CMTimebaseSetRate(timebase, rate: 1)
        guard let start = frames.lastIndex(where: { $0.key && $0.t <= target })
                ?? frames.firstIndex(where: { $0.key }) else { return }
        feedSeq = firstSeq + start
        hideBefore = target
    }

    /// Called every 10 ms: hands the replay the frames due in the next half second.
    private func feed() {
        guard delaySec > 0, !frames.isEmpty else { return }
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
