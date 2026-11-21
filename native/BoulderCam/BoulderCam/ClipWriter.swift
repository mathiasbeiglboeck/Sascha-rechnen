import AVFoundation
import Photos

/// Writes already-compressed H.264 frames (passthrough, no re-encoding) plus
/// audio into a .mov file. Used both for live recordings and for saving a replay.
final class ClipWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let transform: CGAffineTransform
    private let audioSettings: [String: Any]?
    /// Live recording: drop a sample when the writer is busy. Saving a replay: wait for it.
    private let waitWhenBusy: Bool
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private(set) var started = false
    private var startTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid

    init?(transform: CGAffineTransform, audioSettings: [String: Any]?, waitWhenBusy: Bool) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoulderCam-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        writer = w
        self.transform = transform
        self.audioSettings = audioSettings
        self.waitWhenBusy = waitWhenBusy
    }

    /// The first frame given must be a keyframe; earlier frames are skipped.
    func appendVideo(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started {
            guard sb.isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            v.expectsMediaDataInRealTime = true
            v.transform = transform
            guard writer.canAdd(v) else { return }
            writer.add(v)
            videoInput = v
            if let audioSettings {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                a.expectsMediaDataInRealTime = true
                if writer.canAdd(a) { writer.add(a); audioInput = a }
            }
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            startTime = pts
            started = true
        }
        guard writer.status == .writing, let v = videoInput, ready(v) else { return }
        if v.append(sb) { lastVideoTime = pts }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard started, writer.status == .writing, let a = audioInput else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sb) >= startTime, ready(a) else { return }
        a.append(sb)
    }

    private func ready(_ input: AVAssetWriterInput) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        guard waitWhenBusy else { return false }
        for _ in 0..<2500 {          // at most about 5 s
            usleep(2000)
            if input.isReadyForMoreMediaData { return true }
        }
        return false
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard started, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            done(nil)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if lastVideoTime.isValid {
            writer.endSession(atSourceTime: lastVideoTime + CMTime(value: 1, timescale: 30))
        }
        writer.finishWriting { [writer, url] in
            done(writer.status == .completed ? url : nil)
        }
    }

    /// Moves the file into the Photos library, next to the videos of the normal camera.
    static func saveToPhotos(_ url: URL, done: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                done(false, "Kein Zugriff auf Fotos. Bitte in Einstellungen › BoulderCam › Fotos erlauben.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }) { ok, _ in
                if !ok { try? FileManager.default.removeItem(at: url) }
                done(ok, ok ? nil : "Speichern in Fotos fehlgeschlagen.")
            }
        }
    }
}
