import Foundation

/// A zip archive built in memory, stored (not deflated).
///
/// NSFileCoordinator's `.forUploading` is the system zipper and is what the
/// rest of the export uses, but it zips a *folder*, so every entry comes out
/// under that folder's name. A .drt needs its three files at the root of the
/// archive with exact paths, so this writes the container directly. Stored
/// entries keep it to a few dozen lines; the payload is XML inside a zip that
/// itself lands inside the export's zip, which does the compressing.
struct ZipWriter {

    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: Int
    }

    private var entries: [Entry] = []
    private var body = Data()

    mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let crc = ZipWriter.crc32(data)
        let offset = body.count
        var header = Data()
        header.append(little(UInt32(0x0403_4B50)))  // local file header
        header.append(little(UInt16(10)))           // version needed
        header.append(little(UInt16(0)))            // flags
        header.append(little(UInt16(0)))            // stored
        header.append(little(UInt16(0)))            // time
        header.append(little(UInt16(0)))            // date
        header.append(little(crc))
        header.append(little(UInt32(data.count)))   // compressed size
        header.append(little(UInt32(data.count)))   // uncompressed size
        header.append(little(UInt16(name.count)))
        header.append(little(UInt16(0)))            // extra length
        body.append(header)
        body.append(name)
        body.append(data)
        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    func archive() -> Data {
        var out = body
        let directoryStart = out.count
        for entry in entries {
            let name = Data(entry.path.utf8)
            var header = Data()
            header.append(little(UInt32(0x0201_4B50)))  // central directory
            header.append(little(UInt16(20)))           // version made by
            header.append(little(UInt16(10)))           // version needed
            header.append(little(UInt16(0)))            // flags
            header.append(little(UInt16(0)))            // stored
            header.append(little(UInt16(0)))            // time
            header.append(little(UInt16(0)))            // date
            header.append(little(entry.crc))
            header.append(little(UInt32(entry.data.count)))
            header.append(little(UInt32(entry.data.count)))
            header.append(little(UInt16(name.count)))
            header.append(little(UInt16(0)))            // extra
            header.append(little(UInt16(0)))            // comment
            header.append(little(UInt16(0)))            // disk number
            header.append(little(UInt16(0)))            // internal attributes
            header.append(little(UInt32(0)))            // external attributes
            header.append(little(UInt32(entry.offset)))
            out.append(header)
            out.append(name)
        }
        let directorySize = out.count - directoryStart
        var end = Data()
        end.append(little(UInt32(0x0605_4B50)))         // end of central directory
        end.append(little(UInt16(0)))                   // this disk
        end.append(little(UInt16(0)))                   // disk with directory
        end.append(little(UInt16(entries.count)))
        end.append(little(UInt16(entries.count)))
        end.append(little(UInt32(directorySize)))
        end.append(little(UInt32(directoryStart)))
        end.append(little(UInt16(0)))                   // comment length
        out.append(end)
        return out
    }

    // MARK: - Bits

    private func little(_ value: UInt16) -> Data {
        var out = Data()
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private func little(_ value: UInt32) -> Data {
        var out = Data()
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// Built once rather than shifting bit by bit per byte — an export can run
    /// to a few hundred kilobytes of XML.
    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
