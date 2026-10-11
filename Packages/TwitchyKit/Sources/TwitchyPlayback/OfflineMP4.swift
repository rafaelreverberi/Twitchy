import Foundation
import AVFoundation
import TwitchyCore

/// Turns a completed fragmented transfer into an indexed local movie without decoding
/// or copying media samples into memory. The original stays intact until validation succeeds.
public enum OfflineMP4 {
    public static func prepare(_ url: URL, expectedDuration: Double? = nil) async throws {
        try await Task.detached(priority: .utility) {
            try await normalize(url, expectedDuration: expectedDuration)
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, try await asset.load(.isPlayable) else { throw invalid() }
            if let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 {
                guard duration >= expectedDuration - max(2, expectedDuration * 0.05) else { throw invalid() }
            }
        }.value
    }
    private struct Box {
        let type: String
        let payload: Data
        var data: Data { atom(type, payload) }
    }
    private struct Sample { let offset: UInt64; let size: UInt32; let duration: UInt32; let cts: Int32; let sync: Bool }
    private struct Defaults { var duration: UInt32 = 0; var size: UInt32 = 0; var flags: UInt32 = 0 }
    private static func invalid() -> ClientError { .message("This download is incomplete or has an unsupported MP4 index. Retry the download.") }
    private static func u32(_ d: Data, _ p: Int) throws -> UInt32 {
        guard p >= 0, p <= d.count - 4 else { throw invalid() }
        return d[p..<p+4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func u64(_ d: Data, _ p: Int) throws -> UInt64 { (UInt64(try u32(d, p)) << 32) | UInt64(try u32(d, p+4)) }
    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data { var v = value.bigEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    private static func atom(_ type: String, _ payload: Data) -> Data { integer(UInt32(payload.count + 8)) + Data(type.utf8) + payload }
    private static func boxes(_ data: Data) throws -> [Box] {
        var p = 0; var result: [Box] = []
        while p < data.count {
            let n = Int(try u32(data, p))
            guard n >= 8, n <= data.count - p, let type = String(data: data[p+4..<p+8], encoding: .ascii) else { throw invalid() }
            result.append(Box(type: type, payload: Data(data[p+8..<p+n]))); p += n
        }
        return result
    }
    private static func table(_ type: String, _ entries: [Data], version: UInt32 = 0) -> Data { atom(type, integer(version) + integer(UInt32(entries.count)) + entries.reduce(into: Data()) { $0.append($1) }) }
    private static func duration(_ payload: Data, kind: String, value: UInt64) throws -> Data {
        var d = payload
        let v = d.first == 1
        let offset = kind == "tkhd" ? (v ? 28 : 20) : (v ? 24 : 16)
        let length = v ? 8 : 4
        guard offset + length <= d.count, v || value <= UInt32.max else { throw invalid() }
        d.replaceSubrange(offset..<offset+length, with: v ? integer(value) : integer(UInt32(value)))
        return d
    }
    private static func runTable(_ values: [UInt32]) -> [Data] {
        var result: [Data] = []; var last: UInt32?; var count: UInt32 = 0
        for value in values {
            if value == last { count += 1 }
            else { if let last { result.append(integer(count) + integer(last)) }; last = value; count = 1 }
        }
        if let last { result.append(integer(count) + integer(last)) }; return result
    }
    private static func containsSample(_ at: UInt64, length: UInt32, media: [Range<UInt64>]) -> Bool {
        var low = 0, high = media.count
        while low < high {
            let mid = low + (high - low) / 2
            if media[mid].upperBound <= at { low = mid + 1 } else { high = mid }
        }
        return low < media.count && media[low].lowerBound <= at && at + UInt64(length) <= media[low].upperBound
    }
    private static func normalize(_ url: URL, expectedDuration: Double?) async throws {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        var p: UInt64 = 0; var moov: Data?; var freed: [UInt64] = []; var fragments: [(UInt64, Data)] = []
        var media: [Range<UInt64>] = []; var zeroSized: [(UInt64, UInt32)] = []; var metadataBytes = 0
        while p < size {
            try Task.checkCancellation()
            try file.seek(toOffset: p)
            guard let header = try file.read(upToCount: 16), header.count >= 8 else { throw invalid() }
            let small = try u32(header, 0); let headerSize: UInt64 = small == 1 ? 16 : 8
            let n = small == 0 ? size - p : (small == 1 ? try u64(header, 8) : UInt64(small))
            guard n >= headerSize, n <= size - p, let type = String(data: header[4..<8], encoding: .ascii) else { throw invalid() }
            if type == "mdat" { media.append((p + headerSize)..<(p+n)) }
            if small == 0 { guard n <= UInt32.max else { throw invalid() }; zeroSized.append((p, UInt32(n))) }
            if ["moov", "moof"].contains(type) {
                guard n <= 32_000_000 else { throw invalid() }
                metadataBytes += Int(n); guard metadataBytes <= 128_000_000 else { throw invalid() }
                try file.seek(toOffset: p + headerSize)
                guard let data = try file.read(upToCount: Int(n-headerSize)), data.count == Int(n-headerSize) else { throw invalid() }
                if type == "moov" { moov = data } else { fragments.append((p, data)) }
                freed.append(p)
            }
            if type == "mfra" || type == "sidx" { freed.append(p) }
            p += n
        }
        guard !fragments.isEmpty else { return }
        guard let moov else { throw invalid() }
        let movie = try boxes(moov)
        guard let mvhd = movie.first(where: { $0.type == "mvhd" }) else { throw invalid() }
        let movieScale = try u32(mvhd.payload, mvhd.payload.first == 1 ? 20 : 12)
        guard movieScale > 0 else { throw invalid() }
        var defaults: [UInt32: Defaults] = [:]
        if let mvex = movie.first(where: { $0.type == "mvex" }) {
            for box in try boxes(mvex.payload) where box.type == "trex" {
                guard try u32(box.payload, 8) == 1 else { throw invalid() }
                defaults[try u32(box.payload, 4)] = Defaults(duration: try u32(box.payload, 12), size: try u32(box.payload, 16), flags: try u32(box.payload, 20))
            }
        }
        var tracks: [UInt32: [Sample]] = [:]; var sampleCount = 0
        for (position, data) in fragments {
            try Task.checkCancellation()
            for traf in try boxes(data) where traf.type == "traf" {
                let children = try boxes(traf.payload)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }) else { throw invalid() }
                let flags = try u32(tfhd.payload, 0) & 0xFFFFFF, id = try u32(tfhd.payload, 4)
                var def = defaults[id] ?? Defaults(), cursor = 8
                var base = position
                if flags & 1 != 0 { base = try u64(tfhd.payload, cursor); cursor += 8 }
                if flags & 2 != 0 { guard try u32(tfhd.payload, cursor) == 1 else { throw invalid() }; cursor += 4 }
                if flags & 8 != 0 { def.duration = try u32(tfhd.payload, cursor); cursor += 4 }
                if flags & 16 != 0 { def.size = try u32(tfhd.payload, cursor); cursor += 4 }
                if flags & 32 != 0 { def.flags = try u32(tfhd.payload, cursor) }
                var offset: UInt64?
                for trun in children where trun.type == "trun" {
                    let d = trun.payload, flags = try u32(d, 0) & 0xFFFFFF
                    let count = Int(try u32(d, 4)); sampleCount += count
                    guard sampleCount <= 5_000_000 else { throw invalid() }
                    var c = 8
                    if flags & 1 != 0 {
                        let delta = Int64(Int32(bitPattern: try u32(d,c))); c += 4
                        guard base <= UInt64(Int64.max), delta <= Int64.max - Int64(base), delta >= -Int64(base) else { throw invalid() }
                        offset = UInt64(Int64(base) + delta)
                    }
                    var firstFlags: UInt32?
                    if flags & 4 != 0 { firstFlags = try u32(d,c); c += 4 }
                    guard var at = offset else { throw invalid() }
                    for i in 0..<count {
                        var duration = def.duration, length = def.size, sf = i == 0 ? (firstFlags ?? def.flags) : def.flags
                        var cts: Int32 = 0
                        if flags & 0x100 != 0 { duration = try u32(d,c); c += 4 }
                        if flags & 0x200 != 0 { length = try u32(d,c); c += 4 }
                        if flags & 0x400 != 0 { sf = try u32(d,c); c += 4 }
                        if flags & 0x800 != 0 { cts = Int32(bitPattern: try u32(d,c)); c += 4 }
                        guard duration > 0, length > 0, at <= size, UInt64(length) <= size-at,
                              containsSample(at, length: length, media: media) else { throw invalid() }
                        tracks[id, default: []].append(Sample(offset: at, size: length, duration: duration, cts: cts, sync: sf & 0x10000 == 0))
                        at += UInt64(length)
                    }
                    offset = at
                }
            }
        }
        var longest: UInt64 = 0
        var rewritten = Data()
        for box in movie where box.type != "mvex" && box.type != "mvhd" {
            guard box.type == "trak" else { rewritten.append(box.data); continue }
            let children = try boxes(box.payload)
            guard let tkhd = children.first(where: { $0.type == "tkhd" }) else { throw invalid() }
            let id = try u32(tkhd.payload, tkhd.payload.first == 1 ? 20 : 12)
            guard let samples = tracks[id], !samples.isEmpty, let mdia = children.first(where: { $0.type == "mdia" }) else { throw invalid() }
            let mdiaBoxes = try boxes(mdia.payload)
            guard let mdhd = mdiaBoxes.first(where: { $0.type == "mdhd" }) else { throw invalid() }
            let scale = try u32(mdhd.payload, mdhd.payload.first == 1 ? 20 : 12); guard scale > 0 else { throw invalid() }
            let ticks = samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
            let movieTicks = UInt64((Double(ticks) / Double(scale) * Double(movieScale)).rounded(.up)); longest = max(longest, movieTicks)
            var track = Data()
            for child in children {
                if child.type == "tkhd" { track.append(atom("tkhd", try duration(child.payload, kind: "tkhd", value: movieTicks))) }
                else if child.type == "mdia" {
                    var media = Data()
                    for m in mdiaBoxes {
                        if m.type == "mdhd" { media.append(atom("mdhd", try duration(m.payload, kind: "mdhd", value: ticks))) }
                        else if m.type == "minf" {
                            var minf = Data()
                            for b in try boxes(m.payload) {
                                guard b.type == "stbl" else { minf.append(b.data); continue }
                                let originalTables = try boxes(b.payload)
                                guard let stsd = originalTables.first(where: { $0.type == "stsd" }),
                                      let sizes = originalTables.first(where: { $0.type == "stsz" }), try u32(sizes.payload, 8) == 0 else { throw invalid() }
                                var stbl = stsd.data
                                stbl.append(table("stts", runTable(samples.map(\.duration))))
                                if samples.contains(where: { $0.cts != 0 }) { stbl.append(table("ctts", runTable(samples.map { UInt32(bitPattern: $0.cts) }), version: 0x01000000)) }
                                stbl.append(table("stsc", [integer(UInt32(1)) + integer(UInt32(1)) + integer(UInt32(1))]))
                                stbl.append(atom("stsz", integer(UInt32(0)) + integer(UInt32(0)) + integer(UInt32(samples.count)) + samples.reduce(into: Data()) { $0.append(integer($1.size)) }))
                                stbl.append(table("co64", samples.map { integer($0.offset) }))
                                stbl.append(table("stss", samples.enumerated().filter { $0.element.sync }.map { integer(UInt32($0.offset+1)) }))
                                minf.append(atom("stbl", stbl))
                            }
                            media.append(atom("minf", minf))
                        } else { media.append(m.data) }
                    }
                    track.append(atom("mdia", media))
                } else { track.append(child.data) }
            }
            rewritten.append(atom("trak", track))
        }
        rewritten = atom("mvhd", try duration(mvhd.payload, kind: "mvhd", value: longest)) + rewritten
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".indexed.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: url, to: temporary)
        let out = try FileHandle(forWritingTo: temporary)
        do {
            for p in freed { try out.seek(toOffset: p+4); try out.write(contentsOf: Data("free".utf8)) }
            for (p, n) in zeroSized { try out.seek(toOffset: p); try out.write(contentsOf: integer(n)) }
            try out.seekToEnd(); try out.write(contentsOf: atom("moov", rewritten)); try out.close()
        } catch { try? out.close(); throw error }
        let asset = AVURLAsset(url: temporary, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let actual = try await asset.load(.duration).seconds
        let expected = Double(longest) / Double(movieScale)
        guard actual.isFinite, actual >= expected - max(0.25, expected * 0.01) else { throw invalid() }
        if let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 {
            guard actual >= expectedDuration - max(2, expectedDuration * 0.05) else { throw invalid() }
        }
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
