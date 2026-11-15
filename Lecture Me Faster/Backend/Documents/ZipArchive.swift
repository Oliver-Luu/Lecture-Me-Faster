import Compression
import Foundation

/// Reads files out of a .zip archive: just enough for Word (.docx) and PowerPoint (.pptx) files, which
/// are zip archives of XML. Handles stored and deflate-compressed entries. Not handled: ZIP64 archives
/// (over 4 GB) and encrypted entries.
nonisolated struct ZipArchive {
    enum Failure: LocalizedError {
        case notAZip
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: "The file is damaged or isn't really a Word or PowerPoint file."
            case .unsupported(let detail): "This file uses a format feature the app can't read (\(detail))."
            }
        }
    }

    private struct Entry {
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]

    /// Every file path in the archive.
    var names: [String] { Array(entries.keys) }

    init(data: Data) throws {
        bytes = [UInt8](data)
        // The end-of-central-directory record is at the end, followed by a comment of up to 64 KB.
        let eocdSignature: UInt32 = 0x0605_4B50
        guard bytes.count >= 22,
              let eocd = stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1)
                .first(where: { read32($0) == eocdSignature })
        else { throw Failure.notAZip }

        let count = read16(eocd + 10)
        var offset = read32Int(eocd + 16)
        if count == 0xFFFF || offset == 0xFFFF_FFFF { throw Failure.unsupported("ZIP64") }

        for _ in 0..<count {
            guard offset + 46 <= bytes.count, read32(offset) == 0x0201_4B50 else { throw Failure.notAZip }
            let flags = read16(offset + 8)
            let nameLength = read16(offset + 28)
            let extraLength = read16(offset + 30)
            let commentLength = read16(offset + 32)
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.notAZip }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            if flags & 1 == 0 {  // bit 0 means encrypted; skip those
                entries[name] = Entry(
                    method: read16(offset + 10),
                    compressedSize: read32Int(offset + 20),
                    uncompressedSize: read32Int(offset + 24),
                    localHeaderOffset: read32Int(offset + 42)
                )
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The uncompressed contents of one file, or nil if the archive has no such file.
    func contents(of name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, read32(header) == 0x0403_4B50 else { throw Failure.notAZip }
        let start = header + 30 + read16(header + 26) + read16(header + 28)
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw Failure.notAZip }
        let compressed = bytes[start..<end]

        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            // COMPRESSION_ZLIB is raw DEFLATE (no zlib header), which is what zip entries contain.
            guard entry.uncompressedSize > 0 else { return Data() }
            guard entry.uncompressedSize < 500_000_000 else { throw Failure.unsupported("an entry over 500 MB") }
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
            let written = compressed.withUnsafeBufferPointer { source in
                compression_decode_buffer(
                    &output, entry.uncompressedSize, source.baseAddress!, entry.compressedSize, nil, COMPRESSION_ZLIB
                )
            }
            guard written == entry.uncompressedSize else { throw Failure.notAZip }
            return Data(output)
        default:
            throw Failure.unsupported("compression method \(entry.method)")
        }
    }

    private func read16(_ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private func read32(_ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func read32Int(_ offset: Int) -> Int { Int(read32(offset)) }
}
