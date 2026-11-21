import AVFoundation
import VideoToolbox

/// Encodes camera frames to H.264 in real time. The compressed frames are small
/// enough to keep several minutes in memory for the delayed replay.
final class VideoEncoder {
    let width: Int32
    let height: Int32
    private let session: VTCompressionSession
    private let output: (CMSampleBuffer) -> Void
    /// Set to true to make the next frame a keyframe (start of a recording).
    var forceKeyframe = false

    init?(width: Int32, height: Int32, output: @escaping (CMSampleBuffer) -> Void) {
        self.width = width
        self.height = height
        self.output = output
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { return nil }
        session = s
        let bitrate = Int(Double(width) * Double(height) * 30 * 0.1)   // about 8 Mbit/s at 1440x1920
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }
        let output = self.output
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            output(sampleBuffer)
        }
    }

    deinit {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }
}

extension CMSampleBuffer {
    /// True for keyframes (frames a decoder can start with).
    var isKeyframe: Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = arr.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    var ptsSeconds: Double { CMSampleBufferGetPresentationTimeStamp(self).seconds }

    /// A new sample buffer sharing the compressed data, marked "decode but do not show".
    /// Built fresh so the original (also used for saving) keeps its own attachments.
    func hiddenCopy() -> CMSampleBuffer? {
        guard let data = CMSampleBufferGetDataBuffer(self),
              let fmt = CMSampleBufferGetFormatDescription(self) else { return nil }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(self, at: 0, timingInfoOut: &timing)
        var size = CMSampleBufferGetSampleSize(self, at: 0)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &out)
        guard status == noErr, let out,
              let arr = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true),
              CFArrayGetCount(arr) > 0 else { return nil }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if !isKeyframe {
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return out
    }

    /// Deep copy of an audio buffer, so the capture pipeline gets its memory back.
    func audioDeepCopy() -> CMSampleBuffer? {
        guard let data = CMSampleBufferGetDataBuffer(self),
              let fmt = CMSampleBufferGetFormatDescription(self) else { return nil }
        var contiguous: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault, sourceBuffer: data, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 0,
            flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &contiguous) == noErr,
              let contiguous else { return nil }
        var out: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: contiguous, formatDescription: fmt,
            sampleCount: CMSampleBufferGetNumSamples(self),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(self),
            packetDescriptions: nil, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}
