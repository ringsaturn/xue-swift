import Foundation

private enum ParseMode { case fullFile, prefix }

private struct Structure {
    let metadata: XueMetadata
    let metadataJSON: String
    let entries: [XuePlaneEntry]
    let entryMap: [XueFrameRequest: Int]
    let dataOffset: UInt64
    let fileSize: UInt64
    let dictionary: Data?

    func entryPosition(for request: XueFrameRequest) throws -> Int {
        guard let position = entryMap[request] else {
            throw XueDecodeError("no plane exists for variable \(request.variableID), frame offset \(request.frameOffset)")
        }
        return position
    }

    func dependency(of entry: XuePlaneEntry) -> UInt16? {
        // ANCHOR and PREVIOUS both carry their dependency explicitly;
        // parseStructure has pinned PREVIOUS to the preceding axis frame.
        switch entry.predictor {
        case .anchor, .previous: return entry.dependencyOffset
        case .raw, .zero: return nil
        }
    }

    func dependencyChain(for request: XueFrameRequest) throws -> [XueFrameRequest] {
        var chain = [request]
        var current = request
        let firstPosition = try entryPosition(for: request)
        let first = entries[firstPosition]
        let groupLimit = entries.reduce(into: 0) { count, entry in
            if entry.variableID == first.variableID && entry.groupID == first.groupID { count += 1 }
        }
        while true {
            let entry = entries[try entryPosition(for: current)]
            guard let hour = dependency(of: entry) else { return chain }
            let next = XueFrameRequest(variableID: current.variableID, frameOffset: hour)
            guard !chain.contains(next), chain.count < groupLimit else {
                throw XueDecodeError("cyclic or too-deep dependency chain")
            }
            chain.append(next)
            current = next
        }
    }
}

private func parseStructure(_ data: Data, mode: ParseMode) throws -> Structure {
    let reader = ByteReader(data: data)
    guard data.count >= XueFormat.headerSize else { throw XueDecodeError("file is smaller than the fixed header") }
    guard Array(try reader.bytes(at: 0, count: 8)) == XueFormat.magic else {
        throw XueDecodeError("invalid magic, expected a Xue file")
    }
    guard try reader.u16(8) == 1 else { throw XueDecodeError("unsupported Xue version") }
    guard try reader.u16(10) == UInt16(XueFormat.headerSize) else { throw XueDecodeError("headerSize must be 80 for v1") }
    guard try reader.u32(12) == 0 else { throw XueDecodeError("header flags must be zero for v1") }

    let fileSize = try reader.u64(16)
    switch mode {
    case .fullFile:
        guard fileSize == UInt64(data.count) else { throw XueDecodeError("header fileSize does not match actual length") }
    case .prefix:
        guard UInt64(data.count) <= fileSize else { throw XueDecodeError("prefix is longer than the declared fileSize") }
    }
    let metadataOffset = try reader.u64(24)
    let metadataLength = try reader.u64(32)
    let indexOffset = try reader.u64(40)
    let indexLength = try reader.u64(48)
    let dataOffset = try reader.u64(56)
    let dictionaryOffset = try reader.u64(64)
    let dictionaryLength = try reader.u64(72)

    func checkedEnd(_ offset: UInt64, _ length: UInt64, _ label: String) throws -> UInt64 {
        let end = try checkedAdd(offset, length, label: label)
        guard end <= fileSize else { throw XueDecodeError("\(label) range exceeds fileSize") }
        return end
    }
    guard metadataOffset == UInt64(XueFormat.headerSize) else { throw XueDecodeError("metadataOffset must be 80 for v1") }
    let metadataEnd = try checkedEnd(metadataOffset, metadataLength, "metadata")
    guard indexOffset == (try align8(metadataEnd)) else { throw XueDecodeError("indexOffset must immediately follow aligned metadata") }
    let indexEnd = try checkedEnd(indexOffset, indexLength, "index")
    let expectedDataOffset: UInt64
    if dictionaryLength == 0 {
        guard dictionaryOffset == 0 else { throw XueDecodeError("dictionaryOffset must be zero without a dictionary") }
        expectedDataOffset = try align8(indexEnd)
    } else {
        guard dictionaryOffset == (try align8(indexEnd)) else { throw XueDecodeError("dictionaryOffset must immediately follow the aligned index") }
        expectedDataOffset = try align8(try checkedEnd(dictionaryOffset, dictionaryLength, "dictionary"))
    }
    guard dataOffset == expectedDataOffset, dataOffset <= fileSize else {
        throw XueDecodeError("dataOffset must immediately follow the previous aligned section")
    }
    guard UInt64(data.count) >= dataOffset else { throw XueDecodeError("prefix must contain the complete metadata, index, and dictionary") }

    func requireZero(_ start: UInt64, _ end: UInt64, label: String) throws {
        let lower = try checkedInt(start, label: label)
        let upper = try checkedInt(end, label: label)
        guard data[lower..<upper].allSatisfy({ $0 == 0 }) else { throw XueDecodeError("\(label) padding bytes must be zero") }
    }
    try requireZero(metadataEnd, indexOffset, label: "metadata")
    if dictionaryLength == 0 {
        try requireZero(indexEnd, dataOffset, label: "index")
    } else {
        try requireZero(indexEnd, dictionaryOffset, label: "index")
        try requireZero(try checkedAdd(dictionaryOffset, dictionaryLength, label: "dictionary"), dataOffset, label: "dictionary")
    }

    let metadataData = try reader.bytes(
        at: checkedInt(metadataOffset, label: "metadataOffset"),
        count: checkedInt(metadataLength, label: "metadataLength")
    )
    guard let metadataJSON = String(data: metadataData, encoding: .utf8) else { throw XueDecodeError("metadata is not UTF-8") }
    let metadata: XueMetadata
    do { metadata = try JSONDecoder().decode(XueMetadata.self, from: metadataData) }
    catch let error as XueDecodeError { throw error }
    catch { throw XueDecodeError("metadata is invalid: \(error.localizedDescription)") }
    try validateMetadata(metadata)

    guard indexLength >= UInt64(XueFormat.indexHeaderSize) else { throw XueDecodeError("index is smaller than its header") }
    let indexStart = try checkedInt(indexOffset, label: "indexOffset")
    guard Array(try reader.bytes(at: indexStart, count: 4)) == XueFormat.indexMagic else { throw XueDecodeError("invalid index magic") }
    guard try reader.u16(indexStart + 4) == UInt16(XueFormat.entrySize) else { throw XueDecodeError("index entrySize must be 40 for v1") }
    guard try reader.u16(indexStart + 6) == 1 else { throw XueDecodeError("index version must be 1") }
    let entryCount = UInt64(try reader.u32(indexStart + 8))
    guard try reader.u32(indexStart + 12) == 0 else { throw XueDecodeError("index reserved field must be zero") }
    let expectedCount = try checkedMultiply(UInt64(metadata.time.frameCount), UInt64(metadata.variables.count), label: "entry count")
    guard entryCount == expectedCount else { throw XueDecodeError("entryCount does not match metadata") }
    let entriesBytes = try checkedAdd(
        UInt64(XueFormat.indexHeaderSize),
        checkedMultiply(entryCount, UInt64(XueFormat.entrySize), label: "index size"),
        label: "index size"
    )
    guard indexLength == entriesBytes else { throw XueDecodeError("indexLength does not match entryCount") }

    let count = try checkedInt(entryCount, label: "entryCount")
    var entries: [XuePlaneEntry] = []
    entries.reserveCapacity(count)
    for position in 0..<count {
        let start = indexStart + XueFormat.indexHeaderSize + position * XueFormat.entrySize
        guard try reader.u16(start + 10) == 0,
              try reader.bytes(at: start + 34, count: 6).allSatisfy({ $0 == 0 }) else {
            throw XueDecodeError("index entry reserved fields must be zero")
        }
        guard let predictor = XuePredictor(rawValue: try reader.u8(start + 1)) else { throw XueDecodeError("unknown predictor") }
        guard let compression = XueCompression(rawValue: try reader.u8(start + 2)) else { throw XueDecodeError("unknown compression") }
        entries.append(XuePlaneEntry(
            variableID: try reader.u8(start), predictor: predictor, compression: compression,
            flags: try reader.u8(start + 3), frameOffset: try reader.u16(start + 4),
            dependencyOffset: try reader.u16(start + 6), groupID: try reader.u16(start + 8),
            compressedLength: try reader.u32(start + 12), dataOffset: try reader.u64(start + 16),
            decodedLength: try reader.u32(start + 24), crc32: try reader.u32(start + 28),
            minimumCode: try reader.u8(start + 32), maximumCode: try reader.u8(start + 33)
        ))
    }

    let planeLength = UInt32(metadata.grid.width * metadata.grid.height)
    let variableIDs = Set(metadata.variables.map { UInt8($0.numericId) })
    var entryMap: [XueFrameRequest: Int] = [:]
    var previousKey: (UInt8, UInt16)?
    var occupied: [(UInt64, UInt64)] = []
    for (position, entry) in entries.enumerated() {
        let key = (entry.variableID, entry.frameOffset)
        if let previousKey, key.0 < previousKey.0 || (key.0 == previousKey.0 && key.1 <= previousKey.1) {
            throw XueDecodeError("index entries must be sorted and unique by variableId and frameOffset")
        }
        previousKey = key
        guard variableIDs.contains(entry.variableID) else { throw XueDecodeError("entry references an unknown variableId") }
        guard entry.flags & ~XueFormat.checksumFlag == 0 else { throw XueDecodeError("entry has unknown flags") }
        guard entry.compression != .zstdDictionary || dictionaryLength > 0 else { throw XueDecodeError("ZSTD_DICT requires an embedded dictionary") }
        guard entry.decodedLength == planeLength else { throw XueDecodeError("decodedLength does not match the metadata grid") }
        guard entry.minimumCode <= entry.maximumCode else { throw XueDecodeError("minimumCode exceeds maximumCode") }
        if entry.predictor == .zero {
            guard entry.compressedLength == 0 else { throw XueDecodeError("ZERO entries must have no payload") }
        } else {
            guard entry.compressedLength > 0 else { throw XueDecodeError("non-ZERO entries must have a payload") }
            guard entry.dataOffset >= dataOffset else { throw XueDecodeError("payload overlaps a structural section") }
            _ = try checkedEnd(entry.dataOffset, UInt64(entry.compressedLength), "payload")
            occupied.append((entry.dataOffset, UInt64(entry.compressedLength)))
        }
        entryMap[XueFrameRequest(variableID: entry.variableID, frameOffset: entry.frameOffset)] = position
    }

    // Frame coverage per variable, against the materialized axis — never
    // reconstructed arithmetically when the metadata lists its offsets.
    for variableID in variableIDs {
        for offset in metadata.time.frameOffsets {
            guard entryMap[XueFrameRequest(variableID: variableID, frameOffset: offset)] != nil else {
                throw XueDecodeError("a variable does not cover every frame of the axis")
            }
        }
    }

    occupied.sort { $0.0 < $1.0 }
    var cursor = dataOffset
    for (start, length) in occupied {
        guard start == cursor else { throw XueDecodeError("payloads must be adjacent with no gaps or overlaps") }
        cursor = try checkedAdd(cursor, length, label: "payload")
    }
    guard try align8(cursor) == fileSize else { throw XueDecodeError("fileSize must equal the aligned end of the final payload") }
    if mode == .fullFile { try requireZero(cursor, fileSize, label: "trailing") }

    let dictionary: Data?
    if dictionaryLength > 0 {
        dictionary = try reader.bytes(at: checkedInt(dictionaryOffset, label: "dictionaryOffset"), count: checkedInt(dictionaryLength, label: "dictionaryLength"))
    } else { dictionary = nil }
    let structure = Structure(
        metadata: metadata, metadataJSON: metadataJSON, entries: entries, entryMap: entryMap,
        dataOffset: dataOffset, fileSize: fileSize, dictionary: dictionary
    )
    try validateDependencies(structure)
    return structure
}

private func validateMetadata(_ metadata: XueMetadata) throws {
    guard XueFormat.schemaVersions.contains(metadata.schemaVersion) else {
        throw XueDecodeError("unsupported metadata schemaVersion")
    }
    guard metadata.grid.width > 0, metadata.grid.height > 0 else { throw XueDecodeError("grid dimensions must be positive") }
    let points = try checkedMultiply(UInt64(metadata.grid.width), UInt64(metadata.grid.height), label: "grid")
    guard points <= XueFormat.maxPlaneLength, points <= UInt64(UInt32.max) else { throw XueDecodeError("grid exceeds the plane safety limit") }
    // The axis decoded into whichever shape the block declared; a version 3
    // file must carry a unit-neutral axis and a version 1 or 2 file the
    // hour-named one. The two shapes never mix.
    let axisVersion = metadata.time.axisVersion
    guard (metadata.schemaVersion >= 3) == (axisVersion == 3) else {
        throw XueDecodeError("the time axis shape does not match the declared schemaVersion")
    }
    guard !metadata.variables.isEmpty else { throw XueDecodeError("metadata must declare at least one variable") }
    let ids = metadata.variables.map(\.numericId)
    // The registry (docs/format.md) assigns 1 through 6 so far; like the Rust
    // reference decoder this accepts any single-byte id and leaves the real
    // check to the index, whose entries must name a declared variable.
    guard ids.allSatisfy({ (1...255).contains($0) }), Set(ids).count == ids.count else {
        throw XueDecodeError("variable numericId is invalid or duplicated")
    }
    // Every axis and every variable set has exactly one valid encoding: the
    // declared version must be the lowest able to express both.
    let parameters = metadata.variables.filter { $0.parameter != nil }.count
    if metadata.schemaVersion >= 3 {
        guard parameters == metadata.variables.count else {
            throw XueDecodeError("schemaVersion 3 requires a parameter block on every variable")
        }
    } else {
        guard parameters == 0 else { throw XueDecodeError("a GRIB2 parameter block requires schemaVersion 3") }
    }
    guard metadata.schemaVersion == max(axisVersion, parameters > 0 ? 3 : 1) else {
        throw XueDecodeError("metadata declares a schemaVersion other than the lowest it needs")
    }
    for variable in metadata.variables {
        guard variable.quantization.type == "linear" || variable.quantization.type == "log1p" else { throw XueDecodeError("unknown quantization type") }
        guard variable.quantization.scale > 0,
              (0...255).contains(variable.quantization.minimumCode),
              (0...255).contains(variable.quantization.maximumCode),
              (0...255).contains(variable.quantization.nodataCode) else { throw XueDecodeError("invalid quantization parameters") }
    }
}

private func validateDependencies(_ structure: Structure) throws {
    let offsets = structure.metadata.time.frameOffsets
    let axisPosition = Dictionary(uniqueKeysWithValues: offsets.enumerated().map { ($1, $0) })
    for entry in structure.entries {
        switch entry.predictor {
        case .raw, .zero:
            guard entry.dependencyOffset == XueFormat.noDependency else {
                throw XueDecodeError("RAW and ZERO entries must have dependencyOffset 65535")
            }
        case .anchor, .previous:
            let dependencyOffset: UInt16
            if entry.predictor == .anchor {
                dependencyOffset = entry.dependencyOffset
            } else {
                // PREVIOUS references the preceding frame on the time axis,
                // carried explicitly in dependencyOffset (never the sentinel,
                // never frameOffset - 1 by arithmetic).
                guard let position = axisPosition[entry.frameOffset] else {
                    throw XueDecodeError("PREVIOUS entry is not on the time axis")
                }
                guard position > 0 else { throw XueDecodeError("PREVIOUS entry has no preceding frame on the time axis") }
                dependencyOffset = offsets[position - 1]
                guard entry.dependencyOffset == dependencyOffset else {
                    throw XueDecodeError("PREVIOUS dependencyOffset must reference the preceding frame on the time axis")
                }
            }
            let request = XueFrameRequest(variableID: entry.variableID, frameOffset: dependencyOffset)
            guard let position = structure.entryMap[request] else { throw XueDecodeError("entry depends on a plane that does not exist") }
            guard structure.entries[position].groupID == entry.groupID else { throw XueDecodeError("dependencies must stay in one temporal group") }
        }
    }
    for entry in structure.entries {
        _ = try structure.dependencyChain(for: XueFrameRequest(variableID: entry.variableID, frameOffset: entry.frameOffset))
    }
}

private enum PayloadStore {
    case full(Data)
    case sparse([Data?], UInt64)
}

private final class DecodeCore {
    let structure: Structure
    var store: PayloadStore
    var baseCache: [XueFrameRequest: Data] = [:]

    init(structure: Structure, store: PayloadStore) {
        self.structure = structure
        self.store = store
    }

    func payload(position: Int, entry: XuePlaneEntry) throws -> Data {
        switch store {
        case .full(let data):
            let start = try checkedInt(entry.dataOffset, label: "payload offset")
            return data.subdata(in: start..<(start + Int(entry.compressedLength)))
        case .sparse(let payloads, _):
            guard let payload = payloads[position] else { throw XueDecodeError("payload is not resident") }
            return payload
        }
    }

    func isResident(position: Int, entry: XuePlaneEntry) -> Bool {
        if entry.compressedLength == 0 { return true }
        switch store {
        case .full: return true
        case .sparse(let payloads, _): return payloads[position] != nil
        }
    }

    func decompress(position: Int, entry: XuePlaneEntry) throws -> Data {
        let payload = try payload(position: position, entry: entry)
        let expected = Int(entry.decodedLength)
        switch entry.compression {
        case .none:
            guard payload.count == expected else { throw XueDecodeError("uncompressed payload length mismatch") }
            return payload
        case .zstd:
            return try Zstandard.decompress(payload, expectedSize: expected, dictionary: nil)
        case .zstdDictionary:
            guard let dictionary = structure.dictionary else { throw XueDecodeError("embedded dictionary is missing") }
            return try Zstandard.decompress(payload, expectedSize: expected, dictionary: dictionary)
        }
    }

    func check(_ plane: Data, entry: XuePlaneEntry) throws -> Data {
        guard crc32(plane) == entry.crc32 else { throw XueDecodeError("plane CRC32 mismatch for variable \(entry.variableID), frame offset \(entry.frameOffset)") }
        guard let minimum = plane.min(), let maximum = plane.max(),
              minimum == entry.minimumCode, maximum == entry.maximumCode else { throw XueDecodeError("plane code range mismatch") }
        return plane
    }

    func decodeBase(_ request: XueFrameRequest) throws -> Data {
        let position = try structure.entryPosition(for: request)
        let entry = structure.entries[position]
        let plane: Data
        switch entry.predictor {
        case .zero: plane = Data(repeating: 0, count: Int(entry.decodedLength))
        case .raw: plane = try decompress(position: position, entry: entry)
        case .anchor, .previous: throw XueDecodeError("dependency chain base must be RAW or ZERO")
        }
        return try check(plane, entry: entry)
    }

    func decode(_ request: XueFrameRequest) throws -> Data {
        let chain = try structure.dependencyChain(for: request)
        let baseRequest = chain.last!
        if chain.count == 1 { return try decodeBase(baseRequest) }
        if baseCache[baseRequest] == nil { baseCache[baseRequest] = try decodeBase(baseRequest) }
        var plane = baseCache[baseRequest]!
        for link in chain.reversed().dropFirst() {
            let position = try structure.entryPosition(for: link)
            let entry = structure.entries[position]
            let residual = try decompress(position: position, entry: entry)
            guard residual.count == plane.count else { throw XueDecodeError("residual length mismatch") }
            plane.withUnsafeMutableBytes { target in
                residual.withUnsafeBytes { delta in
                    let targetBytes = target.bindMemory(to: UInt8.self)
                    let deltaBytes = delta.bindMemory(to: UInt8.self)
                    for index in 0..<targetBytes.count { targetBytes[index] &+= deltaBytes[index] }
                }
            }
            plane = try check(plane, entry: entry)
        }
        return plane
    }
}

public final class XueBundle {
    private let core: DecodeCore

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        let structure = try parseStructure(data, mode: .fullFile)
        core = DecodeCore(structure: structure, store: .full(data))
    }

    public var metadata: XueMetadata { core.structure.metadata }
    public var metadataJSON: String { core.structure.metadataJSON }
    public var entries: [XuePlaneEntry] { core.structure.entries }
    public var planeLength: Int { metadata.grid.width * metadata.grid.height }
    /// The time axis as frame offsets, ascending.
    public var frameOffsets: [UInt16] { metadata.time.frameOffsets }
    /// Seconds one frame offset is worth: the frame at offset `o` is valid at
    /// `runTime + o * unitSeconds`.
    public var unitSeconds: Int { metadata.time.unitSeconds }

    public func clearCache() { core.baseCache.removeAll(keepingCapacity: true) }

    public func decodeFrame(variableID: UInt8, frameOffset: UInt16) throws -> Data {
        try core.decode(XueFrameRequest(variableID: variableID, frameOffset: frameOffset))
    }

    public func decodeFrame(_ request: XueFrameRequest) throws -> Data { try core.decode(request) }
}

public final class XueStreamingBundle {
    private let core: DecodeCore

    public init(prefix: Data) throws {
        let structure = try parseStructure(prefix, mode: .prefix)
        core = DecodeCore(structure: structure, store: .sparse(Array(repeating: nil, count: structure.entries.count), 0))
    }

    public var metadata: XueMetadata { core.structure.metadata }
    public var metadataJSON: String { core.structure.metadataJSON }
    public var entries: [XuePlaneEntry] { core.structure.entries }
    public var dataOffset: UInt64 { core.structure.dataOffset }
    public var fileSize: UInt64 { core.structure.fileSize }
    /// The time axis as frame offsets, ascending.
    public var frameOffsets: [UInt16] { metadata.time.frameOffsets }
    /// Seconds one frame offset is worth: the frame at offset `o` is valid at
    /// `runTime + o * unitSeconds`.
    public var unitSeconds: Int { metadata.time.unitSeconds }
    public var totalPayloadBytes: UInt64 { entries.reduce(0) { $0 + UInt64($1.compressedLength) } }
    public var residentPayloadBytes: UInt64 {
        if case .sparse(_, let bytes) = core.store { return bytes }
        return 0
    }

    public func clearCache() { core.baseCache.removeAll(keepingCapacity: true) }

    public func missingGroupRange(for request: XueFrameRequest) throws -> XueByteRange? {
        let position = try core.structure.entryPosition(for: request)
        let target = entries[position]
        var lower: UInt64?
        var upper: UInt64?
        for (memberPosition, member) in entries.enumerated() where member.variableID == target.variableID && member.groupID == target.groupID {
            guard !core.isResident(position: memberPosition, entry: member) else { continue }
            let end = try checkedAdd(member.dataOffset, UInt64(member.compressedLength), label: "payload")
            lower = min(lower ?? member.dataOffset, member.dataOffset)
            upper = max(upper ?? end, end)
        }
        guard let lower, let upper else { return nil }
        return XueByteRange(lowerBound: lower, upperBound: upper)
    }

    public func insertRange(offset: UInt64, data: Data) throws {
        let end = try checkedAdd(offset, UInt64(data.count), label: "inserted range")
        guard end <= fileSize else { throw XueDecodeError("inserted range exceeds fileSize") }
        guard case .sparse(var payloads, var residentBytes) = core.store else { return }
        for (position, entry) in entries.enumerated() where entry.compressedLength > 0 && payloads[position] == nil {
            let stop = try checkedAdd(entry.dataOffset, UInt64(entry.compressedLength), label: "payload")
            guard entry.dataOffset >= offset, stop <= end else { continue }
            let start = try checkedInt(entry.dataOffset - offset, label: "range offset")
            payloads[position] = data.subdata(in: start..<(start + Int(entry.compressedLength)))
            residentBytes += UInt64(entry.compressedLength)
        }
        core.store = .sparse(payloads, residentBytes)
    }

    public func decodeFrame(_ request: XueFrameRequest) throws -> Data { try core.decode(request) }

    public func decodeFrame(variableID: UInt8, frameOffset: UInt16) throws -> Data {
        try core.decode(XueFrameRequest(variableID: variableID, frameOffset: frameOffset))
    }
}
