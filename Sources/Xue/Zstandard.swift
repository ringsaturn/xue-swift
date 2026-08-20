import Foundation
import libzstd

enum Zstandard {
    static func decompress(_ input: Data, expectedSize: Int, dictionary: Data?) throws -> Data {
        var output = Data(count: expectedSize)
        let result: Int = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                if let dictionary {
                    return dictionary.withUnsafeBytes { dictionaryBytes in
                        guard let context = ZSTD_createDCtx() else { return Int.max }
                        defer { ZSTD_freeDCtx(context) }
                        return ZSTD_decompress_usingDict(
                            context,
                            destination.baseAddress, expectedSize,
                            source.baseAddress, input.count,
                            dictionaryBytes.baseAddress, dictionary.count
                        )
                    }
                }
                return ZSTD_decompress(
                    destination.baseAddress, expectedSize,
                    source.baseAddress, input.count
                )
            }
        }
        guard result != Int.max else { throw XueDecodeError("unable to allocate a Zstandard context") }
        guard ZSTD_isError(result) == 0 else {
            let message = String(cString: ZSTD_getErrorName(result))
            throw XueDecodeError("Zstandard decode failed: \(message)")
        }
        guard result == expectedSize else {
            throw XueDecodeError("decompressed payload length does not match decodedLength")
        }
        return output
    }
}
