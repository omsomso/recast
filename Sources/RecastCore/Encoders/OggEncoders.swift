import AVFoundation
import AudioToolbox
import COggVorbis
import Foundation

/// Writes Ogg pages for one logical stream.
final class OggWriter {
    private let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
    private let handle: FileHandle
    private var page = ogg_page()
    private var closed = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        ogg_stream_init(stream, Int32.random(in: 1...Int32.max))
    }

    deinit { close() }

    func submit(_ packet: UnsafeMutablePointer<ogg_packet>) {
        ogg_stream_packetin(stream, packet)
    }

    func submit(_ data: Data, granule: Int64, packetNumber: Int64, first: Bool = false, last: Bool = false) {
        var bytes = [UInt8](data)
        bytes.withUnsafeMutableBufferPointer { buffer in
            var packet = ogg_packet(packet: buffer.baseAddress, bytes: buffer.count, b_o_s: first ? 1 : 0, e_o_s: last ? 1 : 0,
                                    granulepos: granule, packetno: packetNumber)
            ogg_stream_packetin(stream, &packet)
        }
    }

    /// Writes the pages that are full.
    func writePages() throws {
        while ogg_stream_pageout(stream, &page) != 0 { try writePage() }
    }

    /// Writes everything submitted so far, ending the current page.
    func flush() throws {
        while ogg_stream_flush(stream, &page) != 0 { try writePage() }
    }

    private func writePage() throws {
        try handle.write(contentsOf: Data(bytes: page.header, count: page.header_len))
        try handle.write(contentsOf: Data(bytes: page.body, count: page.body_len))
    }

    func close() {
        guard !closed else { return }
        closed = true
        ogg_stream_clear(stream)
        stream.deallocate()
        try? handle.close()
    }
}

/// Ogg Vorbis through libvorbis.
final class VorbisEncoder: AudioEncoder {
    let inputFormat: AVAudioFormat
    let notes: [String] = []
    private let info = UnsafeMutablePointer<vorbis_info>.allocate(capacity: 1)
    private let comment = UnsafeMutablePointer<vorbis_comment>.allocate(capacity: 1)
    private let dsp = UnsafeMutablePointer<vorbis_dsp_state>.allocate(capacity: 1)
    private let block = UnsafeMutablePointer<vorbis_block>.allocate(capacity: 1)
    private let ogg: OggWriter
    private let channels: Int
    private var state = 0 // 0 = info only, 1 = analysing, 2 = finished

    init(_ setup: EncoderSetup) throws {
        channels = setup.channels
        inputFormat = floatFormat(rate: setup.sampleRate, channels: setup.channels)
        ogg = try OggWriter(url: setup.url)
        vorbis_info_init(info)
        let settings = setup.settings
        let status: Int32
        if settings.vorbisMode == .quality {
            status = vorbis_encode_init_vbr(info, setup.channels, Int(setup.sampleRate), Float(max(-1, min(10, settings.vorbisQuality)) / 10))
        } else {
            status = vorbis_encode_init(info, setup.channels, Int(setup.sampleRate), -1, settings.vorbisBitrate * 1000, -1)
        }
        guard status == 0 else {
            abort()
            throw ConversionError.encoder("The Vorbis encoder doesn't accept these settings at \(ConversionSettings.rateText(setup.sampleRate)).")
        }
        vorbis_comment_init(comment)
        for (name, value) in setup.tags.vorbisFields() { vorbis_comment_add_tag(comment, name, value) }
        if setup.includeArtwork, let artwork = setup.tags.artwork {
            vorbis_comment_add_tag(comment, "METADATA_BLOCK_PICTURE", VorbisComment.makePicture(artwork).base64EncodedString())
        }
        vorbis_analysis_init(dsp, info)
        vorbis_block_init(dsp, block)
        state = 1
        var header = ogg_packet(), commentPacket = ogg_packet(), codebooks = ogg_packet()
        vorbis_analysis_headerout(dsp, comment, &header, &commentPacket, &codebooks)
        ogg.submit(&header)
        ogg.submit(&commentPacket)
        ogg.submit(&codebooks)
        try ogg.flush()
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard state == 1, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let target = vorbis_analysis_buffer(dsp, Int32(frames)) else { return }
        for channel in 0..<channels {
            target[channel]!.update(from: data[channel], count: frames)
        }
        vorbis_analysis_wrote(dsp, Int32(frames))
        try drain()
    }

    private func drain() throws {
        var packet = ogg_packet()
        while vorbis_analysis_blockout(dsp, block) == 1 {
            vorbis_analysis(block, nil)
            vorbis_bitrate_addblock(block)
            while vorbis_bitrate_flushpacket(dsp, &packet) == 1 {
                ogg.submit(&packet)
                try ogg.writePages()
            }
        }
    }

    func finish() throws {
        guard state == 1 else { return }
        vorbis_analysis_wrote(dsp, 0)
        try drain()
        try ogg.flush()
        release()
        ogg.close()
    }

    func abort() {
        release()
        ogg.close()
    }

    private func release() {
        guard state != 2 else { return }
        if state == 1 {
            vorbis_block_clear(block)
            vorbis_dsp_clear(dsp)
            vorbis_comment_clear(comment)
        }
        vorbis_info_clear(info)
        info.deallocate(); comment.deallocate(); dsp.deallocate(); block.deallocate()
        state = 2
    }

    deinit { if state != 2 { abort() } }
}

/// Opus in Ogg: Core Audio's Opus encoder makes the packets, libogg pages them (RFC 7845 headers).
final class OpusEncoder: AudioEncoder {
    let inputFormat: AVAudioFormat
    let notes: [String] = []
    private var converter: AudioConverterRef?
    private let ogg: OggWriter
    private let channels: Int
    private var fifo: [Float] = []
    private var fifoStart = 0
    private var scratch: UnsafeMutablePointer<Float>
    private var scratchCapacity = 0
    private var finishing = false
    private var preSkip = 0
    private var inputFrames: Int64 = 0
    private var packetCount: Int64 = 0
    private var held: Data?
    private var heldEnd: Int64 = 0
    private var lastGranule: Int64 = 0
    private var outputBuffer: UnsafeMutableRawPointer
    private var maxPacketSize = 4000
    private static let packetsPerCall = 16
    private static let needMoreInput = OSStatus(bitPattern: 0x6E6D_6F72) // 'nmor'

    init(_ setup: EncoderSetup) throws {
        channels = setup.channels
        inputFormat = floatFormat(rate: 48000, channels: setup.channels)
        var source = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: UInt32(4 * channels),
                                                 mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var target = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                 mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                                 mBitsPerChannel: 0, mReserved: 0)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 16)
        var created: AudioConverterRef?
        try check(AudioConverterNew(&source, &target, &created), "start", "the Opus encoder")
        converter = created
        guard let converter else { throw ConversionError.encoder("Couldn't start the Opus encoder.") }
        var bitRate = UInt32(max(6, min(510, setup.settings.opusBitrate)) * 1000)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, 4, &bitRate)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var maxSize: UInt32 = 0
        if AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxSize) == noErr, maxSize > 0 {
            maxPacketSize = Int(maxSize)
        }
        var prime = AudioConverterPrimeInfo()
        size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &size, &prime) == noErr { preSkip = Int(prime.leadingFrames) }
        if preSkip == 0 { preSkip = 312 } // libopus's look-ahead at 48 kHz
        outputBuffer.deallocate()
        outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: maxPacketSize * OpusEncoder.packetsPerCall, alignment: 16)

        do {
            ogg = try OggWriter(url: setup.url)
        } catch {
            AudioConverterDispose(converter)
            throw error
        }
        var head = ByteWriter()
        head.ascii("OpusHead")
        head.u8(1)
        head.u8(UInt8(channels))
        head.u16le(UInt16(preSkip))
        head.u32le(UInt32(setup.sourceRate))
        head.u16le(0)
        head.u8(0)
        ogg.submit(head.data, granule: 0, packetNumber: 0, first: true)
        try ogg.flush()
        var tags = ByteWriter()
        tags.ascii("OpusTags")
        tags.append(VorbisComment.make(setup.tags, vendor: "Recast (Core Audio Opus encoder)", artworkField: setup.includeArtwork))
        ogg.submit(tags.data, granule: 0, packetNumber: 1)
        try ogg.flush()
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        inputFrames += Int64(frames)
        fifo.reserveCapacity(fifo.count + frames * channels)
        for index in 0..<frames { for channel in 0..<channels { fifo.append(data[channel][index]) } }
        if (fifo.count - fifoStart) / channels >= 960 * 8 { try pump() }
    }

    fileprivate func provide(_ packets: UnsafeMutablePointer<UInt32>, _ list: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let available = (fifo.count - fifoStart) / channels
        guard available > 0 else {
            packets.pointee = 0
            list.pointee.mBuffers.mDataByteSize = 0
            return finishing ? noErr : OpusEncoder.needMoreInput
        }
        let frames = min(Int(packets.pointee), available)
        let samples = frames * channels
        if scratchCapacity < samples {
            scratch.deallocate()
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: samples)
            scratchCapacity = samples
        }
        fifo.withUnsafeBufferPointer { source in scratch.update(from: source.baseAddress! + fifoStart, count: samples) }
        fifoStart += samples
        list.pointee.mNumberBuffers = 1
        list.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(samples * 4), mData: scratch)
        packets.pointee = UInt32(frames)
        return noErr
    }

    private func pump() throws {
        guard let converter else { return }
        let count = OpusEncoder.packetsPerCall
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: count)
        while true {
            var packets = UInt32(count)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                                                                 mDataByteSize: UInt32(maxPacketSize * count), mData: outputBuffer))
            let status = descriptions.withUnsafeMutableBufferPointer { descriptionPointer in
                AudioConverterFillComplexBuffer(converter, { _, packets, list, _, context in
                    Unmanaged<OpusEncoder>.fromOpaque(context!).takeUnretainedValue().provide(packets, list)
                }, Unmanaged.passUnretained(self).toOpaque(), &packets, &list, descriptionPointer.baseAddress)
            }
            for index in 0..<Int(packets) {
                let description = descriptions[index]
                try emit(Data(bytes: outputBuffer + Int(description.mStartOffset), count: Int(description.mDataByteSize)))
            }
            if status == OpusEncoder.needMoreInput { break }
            try check(status, "encode", "Opus audio")
            if packets == 0 { break }
        }
        fifo.removeFirst(fifoStart)
        fifoStart = 0
    }

    /// Holds one packet back so the last one can carry the exact end position.
    private func emit(_ packet: Data) throws {
        packetCount += 1
        let end = packetCount * 960
        if let held {
            ogg.submit(held, granule: heldEnd, packetNumber: packetCount)
            lastGranule = heldEnd
            try ogg.writePages()
        }
        held = packet
        heldEnd = end
    }

    func finish() throws {
        finishing = true
        try pump()
        if let held {
            let exact = Int64(preSkip) + inputFrames
            ogg.submit(held, granule: max(lastGranule, min(heldEnd, exact)), packetNumber: packetCount + 1, last: true)
            self.held = nil
        }
        try ogg.flush()
        ogg.close()
        release()
    }

    func abort() {
        ogg.close()
        release()
    }

    private func release() {
        if let converter { AudioConverterDispose(converter) }
        if converter != nil {
            scratch.deallocate()
            outputBuffer.deallocate()
        }
        converter = nil
    }

    deinit { if converter != nil { abort() } }
}
