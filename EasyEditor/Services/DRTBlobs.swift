import Foundation

/// The binary shapes a DaVinci Resolve .drt is built from.
///
/// A .drt is a zip of three XML files. Most of it is plain XML; the parts that
/// are not are hex-encoded blobs in one of two serialisations, both worked out
/// by reading files Resolve wrote and checking what came back:
///
/// KEY/VALUE — Time, Geometry, Proxy, VideoMetadata, TracksBA, FieldsBlob
///
///     [u32 version][u32 count]
///     then count x:
///         [u32 keyByteLength][key UTF-16BE][u32 type][u8 flag]
///         then, for the length-prefixed types: [u32 length][value]
///              for the rest:                   [value, type's own width]
///
/// PROTOBUF — Clip, EffectFiltersBA
///
///     [u32 version=2][u32 byteLength][u8 flag][payload]
///
///     flag 0x80 = the payload as it is, 0x81 = zstd-compressed. iOS has no
///     zstd, so everything here is written raw — which Resolve reads back
///     perfectly well, having been tested against files it had never seen.
enum DRTBlobs {

    // MARK: - Key/value

    /// The value types, and how wide a fixed-width one is.
    enum FieldType: UInt32 {
        case bool = 1
        case int = 2
        case uint = 3
        case int64 = 4
        case long = 6
        case string = 10
        case blob = 12

        var width: Int {
            switch self {
            case .bool: return 1
            case .int64, .long: return 8
            default: return 4
            }
        }

        var isLengthPrefixed: Bool { self == .string || self == .blob }
    }

    enum Field {
        case int(String, FieldType, Int)
        case text(String, String)
        case data(String, Data)

        var key: String {
            switch self {
            case .int(let key, _, _), .text(let key, _), .data(let key, _): return key
            }
        }
    }

    static func keyValue(_ fields: [Field], version: UInt32 = 1) -> String {
        var out = Data()
        out.append(bigEndian(version))
        out.append(bigEndian(UInt32(fields.count)))
        for field in fields {
            // Keys are UTF-16BE, and the length is in bytes, not characters.
            var key = Data()
            for unit in field.key.utf16 { key.append(bigEndian(unit)) }
            out.append(bigEndian(UInt32(key.count)))
            out.append(key)

            switch field {
            case .int(_, let type, let value):
                out.append(bigEndian(type.rawValue))
                out.append(0)
                out.append(bigEndian(UInt64(bitPattern: Int64(value)), width: type.width))
            case .text(_, let value):
                out.append(bigEndian(FieldType.string.rawValue))
                out.append(0)
                var encoded = Data()
                for unit in value.utf16 { encoded.append(bigEndian(unit)) }
                out.append(bigEndian(UInt32(encoded.count)))
                out.append(encoded)
            case .data(_, let value):
                out.append(bigEndian(FieldType.blob.rawValue))
                out.append(0)
                out.append(bigEndian(UInt32(value.count)))
                out.append(value)
            }
        }
        return out.hexadecimal
    }

    // MARK: - Protobuf

    static func varint(_ value: UInt64) -> Data {
        var out = Data()
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0
        return out
    }

    static func string(_ number: Int, _ text: String) -> Data {
        let payload = Data(text.utf8)
        var out = varint(UInt64(number) << 3 | 2)
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    static func number(_ number: Int, _ value: UInt64) -> Data {
        var out = varint(UInt64(number) << 3)
        out.append(varint(value))
        return out
    }

    /// Wrap a payload the way the DRT does, uncompressed.
    static func wrap(_ payload: Data) -> String {
        var out = Data()
        out.append(bigEndian(UInt32(2)))
        out.append(bigEndian(UInt32(payload.count + 1)))
        out.append(0x80)
        out.append(payload)
        return out.hexadecimal
    }

    // MARK: - The fixed 16-byte pairs

    /// Geometry.Resolution: two big-endian u64.
    static func resolution(width: Int, height: Int) -> Data {
        var out = bigEndian(UInt64(width), width: 8)
        out.append(bigEndian(UInt64(height), width: 8))
        return out
    }

    /// FrameRate: two little-endian doubles, the second unused.
    static func frameRate(_ rate: Double) -> Data {
        var out = Data()
        withUnsafeBytes(of: rate.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        out.append(Data(count: 8))
        return out
    }

    /// MediaFrameRate, which is the same pair written into the clip.
    static func mediaFrameRate(_ rate: Double) -> String { frameRate(rate).hexadecimal }

    /// MediaTimemapBA: a marker byte, then the media's last frame in seconds
    /// as a big-endian double.
    static func timemap(frames: Int, rate: Double) -> String {
        let seconds = Double(max(0, frames - 1)) / max(0.001, rate)
        var out = Data([2])
        withUnsafeBytes(of: seconds.bitPattern.bigEndian) { out.append(contentsOf: $0) }
        return out.hexadecimal
    }

    /// PreConformMediaExtents. Resolve writes the same four words whatever the
    /// clip is; it is the timeline's own extents it conforms against.
    static let preConformExtents = "00000100000030c200000100" + "00003042"

    // MARK: - The one field we came for

    /// A timeline clip's EffectFiltersBA, carrying its Composite Mode.
    ///
    /// The mode is a protobuf varint in field 9; field 160 is the length of
    /// what follows, so it grows by the block's 8 bytes. Verified
    /// byte-identical against Resolve's own exports for Normal, Lum and
    /// Foreground.
    static func effectFilters(composite: Int) -> String {
        let tail = "4a00" + "0a14082c4a004a004a08085c1a040a0220024a004a00"
        let block: String
        let inner: Int
        if composite != 0 {
            block = String(format: "4a0808001a040a0220%02x", composite)
            inner = 14
        } else {
            block = "4a00"
            inner = 6
        }
        let body = String(format: "800a%02x0802", inner) + block + tail
        let length = body.count / 2
        return (bigEndian(UInt32(2)) + bigEndian(UInt32(length))).hexadecimal + body
    }

    /// Resolve's Composite Mode enumeration. There is no published list of
    /// these; they were read back off clips set by hand in the Inspector.
    enum Composite {
        static let normal = 0
        static let foreground = 27
        static let lum = 30
    }

    /// Resolve's BitDepth enumeration for an audio track, which is not a count
    /// of bits. Read back the same way.
    static func bitDepth(forCodec codec: String) -> Int {
        codec == "Linear PCM" ? 1 : 3
    }

    // MARK: - Numbers

    private static func bigEndian(_ value: UInt32) -> Data {
        var out = Data()
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func bigEndian(_ value: UInt16) -> Data {
        var out = Data()
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func bigEndian(_ value: UInt64, width: Int) -> Data {
        var out = Data()
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        return out.suffix(width)
    }
}

extension Data {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
