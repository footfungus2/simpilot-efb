import Foundation
import zlib

/// AWC cache files are gzip; zlib validates the header, checksum and trailer while inflating bounded chunks.
enum Gzip {
    enum Failure: Error, Equatable {
        case truncated
        case unsupported
        case corrupt
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func decompressIfNeeded(_ data: Data) throws -> Data {
        isGzip(data) ? try decompress(data) : data
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 20, isGzip(data) else { throw Failure.truncated }
        guard data[data.startIndex + 2] == 8, data[data.startIndex + 3] & 0xE0 == 0 else { throw Failure.unsupported }
        let limit = 64 << 20
        guard data.count <= limit else { throw Failure.unsupported }
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.corrupt }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunk.count - Int(stream.avail_out)
                guard result.count + written <= limit else { throw Failure.unsupported }
                result.append(contentsOf: chunk.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw Failure.corrupt }
                    return result
                }
                guard status == Z_OK else { throw Failure.corrupt }
                guard written > 0 || stream.avail_in > 0 else { throw Failure.truncated }
            }
        }
    }
}
