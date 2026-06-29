import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox H.264 encoder for the Tripper Dash stream: 526×300, Baseline 4.1,
/// 1-second IDR interval, ~200 kbps. The iOS analogue of the Kotlin `DashEncoder`
/// (MediaCodec). Emits Annex-B `(bytes, isKeyframe)` for the `NalProcessor`.
///
/// The dash deliberately stays LOW (2–4 fps / 100–200 kbps): a map needs no video
/// frame rate, and a few fps never overruns the dash decoder.
final class DashEncoder {
    static let width: Int32 = 526
    static let height: Int32 = 300
    static let fps: Int32 = 4
    static let bitrate: Int32 = 200_000
    static let bitrateIdle: Int32 = 100_000

    private var session: VTCompressionSession?
    private let onEncodedData: (Data, Bool) -> Void
    private let startCode = Data([0, 0, 0, 1])

    init(onEncodedData: @escaping (Data, Bool) -> Void) {
        self.onEncodedData = onEncodedData
    }

    func prepare() {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Self.width, height: Self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            DiagnosticsLog.shared.log("encoder", "VTCompressionSessionCreate failed: \(status)")
            return
        }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_4_1)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: Self.fps))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Self.bitrate))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(pixelBuffer: CVPixelBuffer, ptsMs: Int64) {
        guard let session else { return }
        let pts = CMTime(value: ptsMs, timescale: 1000)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            self.handle(sample)
        }
    }

    /// Live bitrate switch (200 k moving / 100 k static) — no reconfigure, mirrors `requestBitrate`.
    func requestBitrate(_ bps: Int32) {
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bps))
    }

    func release() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    // ── internals ──────────────────────────────────────────────────────────
    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        VTSessionSetProperty(session, key: key, value: value)
    }

    private func handle(_ sample: CMSampleBuffer) {
        let isKey = isKeyframe(sample)
        var out = Data()

        // Keyframe: prepend SPS/PPS from the format description as Annex-B.
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr {
                    out.append(startCode)
                    out.append(UnsafeBufferPointer(start: ptr, count: size))
                }
            }
        }

        // Convert the AVCC (length-prefixed) block buffer to Annex-B.
        if let block = CMSampleBufferGetDataBuffer(sample) {
            var lengthAtOffset = 0, totalLength = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                           totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == noErr,
               let dataPtr {
                let p = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
                var offset = 0
                while offset + 4 <= totalLength {
                    var nalLen: UInt32 = 0
                    memcpy(&nalLen, p + offset, 4)
                    nalLen = CFSwapInt32BigToHost(nalLen)
                    offset += 4
                    if offset + Int(nalLen) > totalLength { break }
                    out.append(startCode)
                    out.append(UnsafeBufferPointer(start: p + offset, count: Int(nalLen)))
                    offset += Int(nalLen)
                }
            }
        }

        if !out.isEmpty { onEncodedData(out, isKey) }
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }
}
