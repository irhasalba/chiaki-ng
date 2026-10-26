import AVFoundation
import GameController
import SwiftUI

/// Annex-B H.264 from chiaki-lib -> AVSampleBufferDisplayLayer.
/// Called on chiaki's video thread.
final class VideoDecoder {
    let layer = AVSampleBufferDisplayLayer()
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func reset() {
        layer.flush()
        sps = nil
        pps = nil
        format = nil
    }

    /// false asks chiaki for a new keyframe
    func decode(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
        var frame = Data()
        for nal in Self.splitAnnexB(buf) {
            switch nal[nal.startIndex] & 0x1f {
            case 7: sps = nal; format = nil
            case 8: pps = nal; format = nil
            default:
                var len = UInt32(nal.count).bigEndian
                frame.append(Data(bytes: &len, count: 4))
                frame.append(nal)
            }
        }
        if format == nil, let sps, let pps {
            format = Self.makeFormat(sps: sps, pps: pps)
        }
        if frame.isEmpty { return true } // parameter sets only
        guard let format else { return false }
        guard let sample = Self.makeSample(frame, format: format) else { return false }
        if layer.status == .failed {
            layer.flush()
            return false
        }
        layer.enqueue(sample)
        return true
    }

    static func splitAnnexB(_ p: UnsafeBufferPointer<UInt8>) -> [Data] {
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        while i + 2 < p.count {
            if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                starts.append((i > 0 && p[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [Data] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : p.count
            if end > s.nal {
                nals.append(Data(UnsafeBufferPointer(rebasing: p[s.nal..<end])))
            }
        }
        return nals
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { q in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, q.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return format
    }

    private static func makeSample(_ frame: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: frame.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: frame.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        frame.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count)
        }
        var sample: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

struct VideoView: UIViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.layer.addSublayer(videoLayer)
        view.videoLayer = videoLayer
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        var videoLayer: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            videoLayer?.frame = bounds
        }
    }
}

/// Forwards any connected MFi / DualShock / DualSense pad.
/// ponytail: physical controller only, add on-screen controls when needed
final class Gamepad {
    var onChange: ((GCExtendedGamepad) -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            self?.attach(note.object as? GCController)
        }
        GCController.controllers().forEach { attach($0) }
    }

    private func attach(_ controller: GCController?) {
        controller?.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            self?.onChange?(pad)
        }
    }

    static func send(_ p: GCExtendedGamepad, to session: OpaquePointer) {
        let touchpad = (p as? GCDualSenseGamepad)?.touchpadButton ?? (p as? GCDualShockGamepad)?.touchpadButton
        let mapping: [(GCControllerButtonInput?, ChiakiControllerButton)] = [
            (p.buttonA, CHIAKI_CONTROLLER_BUTTON_CROSS),
            (p.buttonB, CHIAKI_CONTROLLER_BUTTON_MOON),
            (p.buttonX, CHIAKI_CONTROLLER_BUTTON_BOX),
            (p.buttonY, CHIAKI_CONTROLLER_BUTTON_PYRAMID),
            (p.dpad.left, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT),
            (p.dpad.right, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT),
            (p.dpad.up, CHIAKI_CONTROLLER_BUTTON_DPAD_UP),
            (p.dpad.down, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN),
            (p.leftShoulder, CHIAKI_CONTROLLER_BUTTON_L1),
            (p.rightShoulder, CHIAKI_CONTROLLER_BUTTON_R1),
            (p.leftThumbstickButton, CHIAKI_CONTROLLER_BUTTON_L3),
            (p.rightThumbstickButton, CHIAKI_CONTROLLER_BUTTON_R3),
            (p.buttonMenu, CHIAKI_CONTROLLER_BUTTON_OPTIONS),
            (p.buttonOptions, CHIAKI_CONTROLLER_BUTTON_SHARE),
            (p.buttonHome, CHIAKI_CONTROLLER_BUTTON_PS),
            (touchpad, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD),
        ]
        var buttons: UInt32 = 0
        for (input, flag) in mapping where input?.isPressed == true {
            buttons |= UInt32(flag.rawValue)
        }
        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trigger(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        // GameController y is up-positive, chiaki expects down-positive
        cb_session_set_controller(session, buttons,
                                  trigger(p.leftTrigger.value), trigger(p.rightTrigger.value),
                                  axis(p.leftThumbstick.xAxis.value), axis(-p.leftThumbstick.yAxis.value),
                                  axis(p.rightThumbstick.xAxis.value), axis(-p.rightThumbstick.yAxis.value))
    }
}
