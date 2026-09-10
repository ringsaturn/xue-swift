import Foundation

private enum ParseMode { case fullFile, prefix }

/// The plane-major v1 index: one entry per (variable, frame), with
/// dependency chains that never leave a temporal group.
private struct PlaneLayout {
    let entries: [XuePlaneEntry]
    let entryMap: [XueFrameRequest: Int]

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

/// The tiled v2 index: the tiling, the axis partition, and one entry per
/// chunk in the file's fixed physical order — group, then tile (row-major),
/// then variable (ascending id).
///
/// Chunk offsets are the prefix sums of the lengths: the order is the spec's
/// and chunks are strictly adjacent, so they are computed once here rather
/// than read from the file.
private struct TiledLayout {
    struct Variable {
        let id: UInt8
        let predictor: XuePredictor
    }

    struct Group {
        /// Index into the axis, not a frame offset.
        let firstFrame: Int
        let frameCount: Int
    }

    struct Chunk {
        let compressedLength: UInt32
        let crc32: UInt32
    }

    let geometry: XueTileGeometry
    let compression: XueCompression
    let variables: [Variable]
    let groups: [Group]
    let chunks: [Chunk]
    let chunkOffsets: [UInt64]
    /// Axis index to (group, index within the group).
    let frameGroup: [(group: Int, index: Int)]

    func variablePosition(_ variableID: UInt8) throws -> Int {
        guard let position = variables.firstIndex(where: { $0.id == variableID }) else {
            throw XueDecodeError("no chunks exist for variable \(variableID)")
        }
        return position
    }

    func chunkPosition(group: Int, tile: Int, variablePosition: Int) -> Int {
        (group * geometry.count + tile) * variables.count + variablePosition
    }

    /// The byte span `[start, end)` of a chunk's compressed payload.
    func chunkSpan(_ position: Int) -> (UInt64, UInt64) {
        let start = chunkOffsets[position]
        return (start, start + UInt64(chunks[position].compressedLength))
    }

    /// How many bytes a chunk reconstructs to: the group's frames of the
    /// tile's clipped rectangle.
    func decodedLength(group: Int, tile: Int) -> Int {
        let shape = geometry.shape(of: tile)
        return groups[group].frameCount * shape.height * shape.width
    }
}

/// What a payload is in this file: a whole plane, or a tile of a group.
private enum Layout {
    case planes(PlaneLayout)
    case tiles(TiledLayout)
}

private struct Structure {
    let metadata: XueMetadata
    let metadataJSON: String
    let layout: Layout
    let dataOffset: UInt64
    let fileSize: UInt64
    let dictionary: Data?

    /// How many payloads the index describes — planes in v1, chunks in v2.
    /// Residency and range requests are tracked per payload, whatever a
    /// payload happens to be in this file.
    var payloadCount: Int {
        switch layout {
        case .planes(let planes): planes.entries.count
        case .tiles(let tiles): tiles.chunks.count
        }
    }

    /// One payload's byte span `[start, end)`. A v1 ZERO plane has no bytes
    /// at all and reports an empty span.
    func payloadSpan(_ position: Int) -> (UInt64, UInt64) {
        switch layout {
        case .planes(let planes):
            let entry = planes.entries[position]
            if entry.compressedLength == 0 { return (0, 0) }
            return (entry.dataOffset, entry.dataOffset + UInt64(entry.compressedLength))
        case .tiles(let tiles):
            return tiles.chunkSpan(position)
        }
    }

    /// The frame's index on the axis.
    func frameIndex(_ frameOffset: UInt16) throws -> Int {
        guard let index = metadata.time.frameOffsets.firstIndex(of: frameOffset) else {
            throw XueDecodeError("frame offset \(frameOffset) is not on the time axis")
        }
        return index
    }

    var planeLength: Int { metadata.grid.width * metadata.grid.height }
}

private func parseStructure(_ data: Data, mode: ParseMode) throws -> Structure {
    let reader = ByteReader(data: data)
    guard data.count >= XueFormat.headerSize else { throw XueDecodeError("file is smaller than the fixed header") }
    guard Array(try reader.bytes(at: 0, count: 8)) == XueFormat.magic else {
        throw XueDecodeError("invalid magic, expected a Xue file")
    }
    let version = try reader.u16(8)
    guard version == XueFormat.version || version == XueFormat.versionV2 else {
        throw XueDecodeError("unsupported Xue version")
    }
    guard try reader.u16(10) == UInt16(XueFormat.headerSize) else { throw XueDecodeError("headerSize must be 80") }
    guard try reader.u32(12) == 0 else { throw XueDecodeError("header flags must be zero") }

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
    guard metadataOffset == UInt64(XueFormat.headerSize) else { throw XueDecodeError("metadataOffset must be 80") }
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

    let dictionary: Data?
    if dictionaryLength > 0 {
        dictionary = try reader.bytes(at: checkedInt(dictionaryOffset, label: "dictionaryOffset"), count: checkedInt(dictionaryLength, label: "dictionaryLength"))
    } else { dictionary = nil }

    let geometry = IndexGeometry(
        reader: reader, data: data, metadata: metadata, indexOffset: indexOffset, indexLength: indexLength,
        dataOffset: dataOffset, fileSize: fileSize, dictionaryLength: dictionaryLength, mode: mode,
        checkedEnd: checkedEnd, requireZero: requireZero
    )
    let layout: Layout
    if version == XueFormat.versionV2 {
        layout = .tiles(try parseTiledIndex(geometry))
    } else {
        layout = .planes(try parsePlaneIndex(geometry))
    }
    let structure = Structure(
        metadata: metadata, metadataJSON: metadataJSON, layout: layout,
        dataOffset: dataOffset, fileSize: fileSize, dictionary: dictionary
    )
    if case .planes(let planes) = layout {
        try validateDependencies(planes, metadata: metadata)
    }
    return structure
}

/// Everything the two index parsers share: the section geometry the fixed
/// header established, and the two checks that depend on it.
private struct IndexGeometry {
    let reader: ByteReader
    let data: Data
    let metadata: XueMetadata
    let indexOffset: UInt64
    let indexLength: UInt64
    let dataOffset: UInt64
    let fileSize: UInt64
    let dictionaryLength: UInt64
    let mode: ParseMode
    let checkedEnd: (UInt64, UInt64, String) throws -> UInt64
    let requireZero: (UInt64, UInt64, String) throws -> Void
}

private func parsePlaneIndex(_ geometry: IndexGeometry) throws -> PlaneLayout {
    let reader = geometry.reader
    let metadata = geometry.metadata
    guard geometry.indexLength >= UInt64(XueFormat.indexHeaderSize) else { throw XueDecodeError("index is smaller than its header") }
    let indexStart = try checkedInt(geometry.indexOffset, label: "indexOffset")
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
    guard geometry.indexLength == entriesBytes else { throw XueDecodeError("indexLength does not match entryCount") }

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
        guard entry.compression != .zstdDictionary || geometry.dictionaryLength > 0 else { throw XueDecodeError("ZSTD_DICT requires an embedded dictionary") }
        guard entry.decodedLength == planeLength else { throw XueDecodeError("decodedLength does not match the metadata grid") }
        guard entry.minimumCode <= entry.maximumCode else { throw XueDecodeError("minimumCode exceeds maximumCode") }
        if entry.predictor == .zero {
            guard entry.compressedLength == 0 else { throw XueDecodeError("ZERO entries must have no payload") }
        } else {
            guard entry.compressedLength > 0 else { throw XueDecodeError("non-ZERO entries must have a payload") }
            guard entry.dataOffset >= geometry.dataOffset else { throw XueDecodeError("payload overlaps a structural section") }
            _ = try geometry.checkedEnd(entry.dataOffset, UInt64(entry.compressedLength), "payload")
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
    var cursor = geometry.dataOffset
    for (start, length) in occupied {
        guard start == cursor else { throw XueDecodeError("payloads must be adjacent with no gaps or overlaps") }
        cursor = try checkedAdd(cursor, length, label: "payload")
    }
    guard try align8(cursor) == geometry.fileSize else { throw XueDecodeError("fileSize must equal the aligned end of the final payload") }
    if geometry.mode == .fullFile { try geometry.requireZero(cursor, geometry.fileSize, "trailing") }

    return PlaneLayout(entries: entries, entryMap: entryMap)
}

/// The tiled v2 index: three tables over a physical order the spec fixes.
///
/// Nothing here says where a chunk is — the order is `group, tile, variable`
/// and chunks are strictly adjacent, so an offset is the prefix sum of the
/// lengths before it. What is validated is that the geometry, the axis
/// partition and those prefix sums all agree with the metadata and the
/// declared file length.
private func parseTiledIndex(_ geometry: IndexGeometry) throws -> TiledLayout {
    let reader = geometry.reader
    let metadata = geometry.metadata
    guard geometry.indexLength >= UInt64(XueFormat.indexHeaderSizeV2) else { throw XueDecodeError("index is smaller than its header") }
    let indexStart = try checkedInt(geometry.indexOffset, label: "indexOffset")
    guard Array(try reader.bytes(at: indexStart, count: 4)) == XueFormat.indexMagicV2 else { throw XueDecodeError("invalid index magic") }
    guard try reader.u16(indexStart + 4) == 2 else { throw XueDecodeError("index version must be 2") }
    guard try reader.u16(indexStart + 6) == UInt16(XueFormat.indexHeaderSizeV2) else { throw XueDecodeError("index headerSize must be 32 for v2") }
    let tileWidth = Int(try reader.u16(indexStart + 8))
    let tileHeight = Int(try reader.u16(indexStart + 10))
    let groupCount = Int(try reader.u16(indexStart + 12))
    let variableCount = Int(try reader.u8(indexStart + 14))
    guard let compression = XueCompression(rawValue: try reader.u8(indexStart + 15)) else { throw XueDecodeError("unknown compression") }
    let chunkCount = UInt64(try reader.u32(indexStart + 16))
    guard try reader.u32(indexStart + 20) == 0, try reader.u64(indexStart + 24) == 0 else {
        throw XueDecodeError("index reserved words must be zero")
    }
    guard compression != .none else { throw XueDecodeError("v2 chunks must be Zstandard frames") }
    guard compression != .zstdDictionary || geometry.dictionaryLength > 0 else { throw XueDecodeError("ZSTD_DICT requires an embedded dictionary") }
    guard groupCount >= 1, variableCount >= 1 else { throw XueDecodeError("a v2 file must declare at least one group and one variable") }
    guard variableCount == metadata.variables.count else { throw XueDecodeError("index variableCount does not match the metadata variables") }
    let tiles = try XueTileGeometry(
        width: metadata.grid.width, height: metadata.grid.height, tileWidth: tileWidth, tileHeight: tileHeight
    )
    let expectedChunks = try checkedMultiply(
        checkedMultiply(UInt64(groupCount), UInt64(tiles.count), label: "chunk count"),
        UInt64(variableCount), label: "chunk count"
    )
    guard chunkCount == expectedChunks else { throw XueDecodeError("chunkCount does not match groupCount x tileCount x variableCount") }
    let tablesBytes = UInt64(XueFormat.indexHeaderSizeV2)
        + UInt64(variableCount * XueFormat.variableEntrySize)
        + UInt64(groupCount * XueFormat.groupEntrySize)
        + chunkCount * UInt64(XueFormat.chunkEntrySize)
    guard geometry.indexLength == tablesBytes else { throw XueDecodeError("indexLength does not match the index tables") }

    var cursor = indexStart + XueFormat.indexHeaderSizeV2
    let variableIDs = Set(metadata.variables.map { UInt8($0.numericId) })
    var variables: [TiledLayout.Variable] = []
    variables.reserveCapacity(variableCount)
    for _ in 0..<variableCount {
        let id = try reader.u8(cursor)
        guard let predictor = XuePredictor(rawValue: try reader.u8(cursor + 1)) else { throw XueDecodeError("unknown predictor") }
        // A v2 chunk is decompressed whole, so an anchor buys no random
        // access: one chunk has exactly one valid encoding.
        guard predictor == .raw || predictor == .previous else { throw XueDecodeError("v2 predictors must be RAW or PREVIOUS") }
        guard try reader.u16(cursor + 2) == 0 else { throw XueDecodeError("variable entry reserved field must be zero") }
        if let previous = variables.last, previous.id >= id {
            throw XueDecodeError("variable entries must be sorted and unique by variableId")
        }
        guard variableIDs.contains(id) else { throw XueDecodeError("variable entries do not match the metadata variables") }
        variables.append(TiledLayout.Variable(id: id, predictor: predictor))
        cursor += XueFormat.variableEntrySize
    }

    var groups: [TiledLayout.Group] = []
    groups.reserveCapacity(groupCount)
    var frameGroup: [(group: Int, index: Int)] = []
    frameGroup.reserveCapacity(metadata.time.frameCount)
    var frameCursor = 0
    for group in 0..<groupCount {
        let firstFrame = Int(try reader.u16(cursor))
        let frameCount = Int(try reader.u8(cursor + 2))
        guard try reader.u8(cursor + 3) == 0 else { throw XueDecodeError("group entry reserved field must be zero") }
        cursor += XueFormat.groupEntrySize
        guard frameCount > 0 else { throw XueDecodeError("a temporal group must hold at least one frame") }
        guard firstFrame == frameCursor else { throw XueDecodeError("temporal groups must partition the axis in order") }
        frameCursor += frameCount
        guard frameCursor <= metadata.time.frameCount else { throw XueDecodeError("temporal groups overrun the axis") }
        for index in 0..<frameCount { frameGroup.append((group, index)) }
        groups.append(TiledLayout.Group(firstFrame: firstFrame, frameCount: frameCount))
    }
    guard frameCursor == metadata.time.frameCount else { throw XueDecodeError("temporal groups must end exactly at the axis frameCount") }

    let count = try checkedInt(chunkCount, label: "chunkCount")
    var chunks: [TiledLayout.Chunk] = []
    chunks.reserveCapacity(count)
    var chunkOffsets: [UInt64] = []
    chunkOffsets.reserveCapacity(count)
    var position = geometry.dataOffset
    for _ in 0..<count {
        let compressedLength = try reader.u32(cursor)
        let crc = try reader.u32(cursor + 4)
        cursor += XueFormat.chunkEntrySize
        guard compressedLength > 0 else { throw XueDecodeError("a chunk must have a payload") }
        chunkOffsets.append(position)
        position = try geometry.checkedEnd(position, UInt64(compressedLength), "chunk")
        chunks.append(TiledLayout.Chunk(compressedLength: compressedLength, crc32: crc))
    }
    guard try align8(position) == geometry.fileSize else { throw XueDecodeError("fileSize must equal the aligned end of the final chunk") }
    if geometry.mode == .fullFile { try geometry.requireZero(position, geometry.fileSize, "trailing") }

    return TiledLayout(
        geometry: tiles, compression: compression, variables: variables, groups: groups,
        chunks: chunks, chunkOffsets: chunkOffsets, frameGroup: frameGroup
    )
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

private func validateDependencies(_ layout: PlaneLayout, metadata: XueMetadata) throws {
    let offsets = metadata.time.frameOffsets
    let axisPosition = Dictionary(uniqueKeysWithValues: offsets.enumerated().map { ($1, $0) })
    for entry in layout.entries {
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
            guard let position = layout.entryMap[request] else { throw XueDecodeError("entry depends on a plane that does not exist") }
            guard layout.entries[position].groupID == entry.groupID else { throw XueDecodeError("dependencies must stay in one temporal group") }
        }
    }
    for entry in layout.entries {
        _ = try layout.dependencyChain(for: XueFrameRequest(variableID: entry.variableID, frameOffset: entry.frameOffset))
    }
}

/// Where payload bytes live: the whole file, or per-payload sparse buffers
/// filled in by `XueStreamingBundle.insertRange`.
private enum PayloadStore {
    case full(Data)
    case sparse([Data?], UInt64)
}

/// The decode engine shared by both readers and both container versions.
/// What differs between a whole file and a streamed one is only where a
/// payload's bytes come from; what differs between v1 and v2 is what a
/// payload *is*. The integrity checks above both are the same code.
private final class DecodeCore {
    let structure: Structure
    var store: PayloadStore
    /// v1: RAW base planes along a dependency chain.
    var baseCache: [XueFrameRequest: Data] = [:]
    /// v2: reconstructed chunks, keyed by group then chunk position. A few
    /// groups are kept rather than one, so a prefetch running a group ahead
    /// of playback does not evict the chunks the play head is still reading.
    var chunkCache: [Int: [Int: Data]] = [:]
    /// Least recently used first.
    var cachedGroups: [Int] = []
    static let cachedGroupLimit = 3

    init(structure: Structure, store: PayloadStore) {
        self.structure = structure
        self.store = store
    }

    func clearCache() {
        baseCache.removeAll(keepingCapacity: true)
        chunkCache.removeAll()
        cachedGroups.removeAll()
    }

    // MARK: Payload access

    func payload(position: Int, span: (UInt64, UInt64)) throws -> Data {
        switch store {
        case .full(let data):
            let start = try checkedInt(span.0, label: "payload offset")
            let end = try checkedInt(span.1, label: "payload end")
            return data.subdata(in: start..<end)
        case .sparse(let payloads, _):
            guard let payload = payloads[position] else { throw XueDecodeError("payload is not resident") }
            return payload
        }
    }

    func isResident(position: Int) -> Bool {
        switch store {
        case .full: return true
        case .sparse(let payloads, _):
            let span = structure.payloadSpan(position)
            return span.0 == span.1 || payloads[position] != nil
        }
    }

    func decompress(position: Int, span: (UInt64, UInt64), compression: XueCompression, expected: Int) throws -> Data {
        let payload = try payload(position: position, span: span)
        switch compression {
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

    // MARK: v1, plane-major

    private func planes() throws -> PlaneLayout {
        guard case .planes(let planes) = structure.layout else { throw XueDecodeError("not a plane-major file") }
        return planes
    }

    private func decompressPlane(position: Int, entry: XuePlaneEntry) throws -> Data {
        try decompress(
            position: position,
            span: (entry.dataOffset, entry.dataOffset + UInt64(entry.compressedLength)),
            compression: entry.compression,
            expected: Int(entry.decodedLength)
        )
    }

    private func check(_ plane: Data, entry: XuePlaneEntry) throws -> Data {
        guard crc32(plane) == entry.crc32 else { throw XueDecodeError("plane CRC32 mismatch for variable \(entry.variableID), frame offset \(entry.frameOffset)") }
        guard let minimum = plane.min(), let maximum = plane.max(),
              minimum == entry.minimumCode, maximum == entry.maximumCode else { throw XueDecodeError("plane code range mismatch") }
        return plane
    }

    private func decodeBase(_ request: XueFrameRequest, layout: PlaneLayout) throws -> Data {
        let position = try layout.entryPosition(for: request)
        let entry = layout.entries[position]
        let plane: Data
        switch entry.predictor {
        case .zero: plane = Data(repeating: 0, count: Int(entry.decodedLength))
        case .raw: plane = try decompressPlane(position: position, entry: entry)
        case .anchor, .previous: throw XueDecodeError("dependency chain base must be RAW or ZERO")
        }
        return try check(plane, entry: entry)
    }

    private func decodeFrameV1(_ request: XueFrameRequest) throws -> Data {
        let layout = try planes()
        let chain = try layout.dependencyChain(for: request)
        let baseRequest = chain.last!
        if chain.count == 1 { return try decodeBase(baseRequest, layout: layout) }
        if baseCache[baseRequest] == nil { baseCache[baseRequest] = try decodeBase(baseRequest, layout: layout) }
        var plane = baseCache[baseRequest]!
        for link in chain.reversed().dropFirst() {
            let position = try layout.entryPosition(for: link)
            let entry = layout.entries[position]
            let residual = try decompressPlane(position: position, entry: entry)
            guard residual.count == plane.count else { throw XueDecodeError("residual length mismatch") }
            Self.add(residual, into: &plane, at: 0, count: plane.count, from: 0)
            plane = try check(plane, entry: entry)
        }
        return plane
    }

    // MARK: v2, tiled

    var tileGeometry: XueTileGeometry? {
        if case .tiles(let tiles) = structure.layout { return tiles.geometry }
        return nil
    }

    func tiles() throws -> TiledLayout {
        guard case .tiles(let tiles) = structure.layout else { throw XueDecodeError("not a tiled file") }
        return tiles
    }

    /// One chunk, decompressed and its residual chain replayed.
    func buildChunk(position: Int, layout: TiledLayout) throws -> Data {
        let variableCount = layout.variables.count
        let tileCount = layout.geometry.count
        let group = position / (tileCount * variableCount)
        let tile = position / variableCount % tileCount
        let variable = layout.variables[position % variableCount]
        let shape = layout.geometry.shape(of: tile)
        let frames = layout.groups[group].frameCount
        let expected = layout.decodedLength(group: group, tile: tile)
        var chunk = try decompress(
            position: position, span: layout.chunkSpan(position),
            compression: layout.compression, expected: expected
        )
        if variable.predictor == .previous {
            // A group's frames are contiguous on the axis, so the chain never
            // leaves the chunk: each frame is a modulo-256 residual against
            // the frame reconstructed just before it.
            let stride = shape.height * shape.width
            chunk.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for frame in 1..<max(1, frames) {
                    let current = frame * stride
                    let previous = current - stride
                    for index in 0..<stride { bytes[current + index] &+= bytes[previous + index] }
                }
            }
        }
        guard crc32(chunk) == layout.chunks[position].crc32 else {
            throw XueDecodeError("chunk CRC32 mismatch at position \(position)")
        }
        return chunk
    }

    /// The reconstructed chunk, from the group-scoped cache or built now.
    private func reconstructedChunk(group: Int, position: Int, layout: TiledLayout) throws -> Data {
        if let cached = chunkCache[group]?[position] {
            touch(group: group)
            return cached
        }
        let built = try buildChunk(position: position, layout: layout)
        if chunkCache[group] == nil {
            while cachedGroups.count >= Self.cachedGroupLimit, let victim = cachedGroups.first {
                cachedGroups.removeFirst()
                chunkCache[victim] = nil
            }
            chunkCache[group] = [:]
        }
        chunkCache[group]![position] = built
        touch(group: group)
        return built
    }

    private func touch(group: Int) {
        if let index = cachedGroups.firstIndex(of: group) { cachedGroups.remove(at: index) }
        cachedGroups.append(group)
    }

    /// Assemble a frame from the chunks of its group.
    ///
    /// `tiles` restricts the work to the tiles a viewport covers; cells no
    /// tile covered are left zero, so a caller drawing a partial plane must
    /// know which rectangle it asked for.
    private func decodeFrameV2(_ request: XueFrameRequest, tiles rect: XueTileRect?) throws -> Data {
        let layout = try tiles()
        let axisIndex = try structure.frameIndex(request.frameOffset)
        let (group, frameInGroup) = layout.frameGroup[axisIndex]
        let variablePosition = try layout.variablePosition(request.variableID)
        let geometry = layout.geometry
        var output = Data(count: structure.planeLength)
        for tile in 0..<geometry.count {
            if let rect, !rect.contains(tile, in: geometry) { continue }
            let position = layout.chunkPosition(group: group, tile: tile, variablePosition: variablePosition)
            let chunk = try reconstructedChunk(group: group, position: position, layout: layout)
            let shape = geometry.shape(of: tile)
            let origin = geometry.origin(of: tile)
            let stride = shape.height * shape.width
            let block = frameInGroup * stride
            output.withUnsafeMutableBytes { raw in
                chunk.withUnsafeBytes { source in
                    let target = raw.bindMemory(to: UInt8.self)
                    let bytes = source.bindMemory(to: UInt8.self)
                    for row in 0..<shape.height {
                        let destination = (origin.row + row) * geometry.width + origin.column
                        let from = block + row * shape.width
                        for column in 0..<shape.width { target[destination + column] = bytes[from + column] }
                    }
                }
            }
        }
        return output
    }

    /// One cell's code on every frame of the axis: one chunk per group of the
    /// single tile holding the cell, independent of how many frames the axis
    /// has. Chunks are read straight through rather than cached; each is
    /// touched once.
    func decodeSeries(variableID: UInt8, column: Int, row: Int) throws -> Data {
        let layout = try tiles()
        let variablePosition = try layout.variablePosition(variableID)
        let tile = try layout.geometry.tile(row: row, column: column)
        let origin = layout.geometry.origin(of: tile)
        let shape = layout.geometry.shape(of: tile)
        let cell = (row - origin.row) * shape.width + (column - origin.column)
        var series = Data()
        series.reserveCapacity(structure.metadata.time.frameCount)
        for group in layout.groups.indices {
            let frames = layout.groups[group].frameCount
            let stride = layout.decodedLength(group: group, tile: tile) / frames
            let position = layout.chunkPosition(group: group, tile: tile, variablePosition: variablePosition)
            let chunk = try chunkCache[group]?[position] ?? buildChunk(position: position, layout: layout)
            for frame in 0..<frames { series.append(chunk[chunk.startIndex + frame * stride + cell]) }
        }
        return series
    }

    // MARK: Dispatch

    func decodeFrame(_ request: XueFrameRequest, tiles: XueTileRect?) throws -> Data {
        switch structure.layout {
        case .planes:
            guard tiles == nil else { throw XueDecodeError("a plane-major file has no tiles") }
            return try decodeFrameV1(request)
        case .tiles:
            return try decodeFrameV2(request, tiles: tiles)
        }
    }

    /// `target[at..<at+count] &+= source[from..<from+count]`.
    private static func add(_ source: Data, into target: inout Data, at: Int, count: Int, from: Int) {
        target.withUnsafeMutableBytes { raw in
            source.withUnsafeBytes { delta in
                let targetBytes = raw.bindMemory(to: UInt8.self)
                let deltaBytes = delta.bindMemory(to: UInt8.self)
                for index in 0..<count { targetBytes[at + index] &+= deltaBytes[from + index] }
            }
        }
    }
}

/// A complete `.xue` file held in memory. Reads either container version.
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
    /// The v1 index entries; empty on a tiled v2 file, whose index is chunks
    /// rather than planes.
    public var entries: [XuePlaneEntry] {
        if case .planes(let planes) = core.structure.layout { return planes.entries }
        return []
    }
    public var planeLength: Int { metadata.grid.width * metadata.grid.height }
    /// The time axis as frame offsets, ascending.
    public var frameOffsets: [UInt16] { metadata.time.frameOffsets }
    /// Seconds one frame offset is worth: the frame at offset `o` is valid at
    /// `runTime + o * unitSeconds`.
    public var unitSeconds: Int { metadata.time.unitSeconds }
    /// The file's tiling, or `nil` for a plane-major v1 file.
    public var tileGeometry: XueTileGeometry? { core.tileGeometry }

    public func clearCache() { core.clearCache() }

    public func decodeFrame(variableID: UInt8, frameOffset: UInt16) throws -> Data {
        try core.decodeFrame(XueFrameRequest(variableID: variableID, frameOffset: frameOffset), tiles: nil)
    }

    public func decodeFrame(_ request: XueFrameRequest) throws -> Data { try core.decodeFrame(request, tiles: nil) }

    /// Decode only the tiles a viewport covers, into a whole-plane buffer.
    /// Cells outside the rectangle are zero, so a renderer must draw only the
    /// rectangle it asked for. Fails on a v1 file, which has no tiles.
    public func decodeFrame(_ request: XueFrameRequest, tiles: XueTileRect) throws -> Data {
        try core.decodeFrame(request, tiles: tiles)
    }

    /// One cell's code on every frame of the axis, in axis order. Fails on a
    /// v1 file.
    public func decodeSeries(variableID: UInt8, column: Int, row: Int) throws -> Data {
        try core.decodeSeries(variableID: variableID, column: column, row: row)
    }
}

/// A bundle opened from just its structural prefix `[0, dataOffset)`, with
/// payload bytes arriving incrementally as HTTP range responses. Reads either
/// container version.
public final class XueStreamingBundle {
    private let core: DecodeCore

    public init(prefix: Data) throws {
        let structure = try parseStructure(prefix, mode: .prefix)
        core = DecodeCore(structure: structure, store: .sparse(Array(repeating: nil, count: structure.payloadCount), 0))
    }

    public var metadata: XueMetadata { core.structure.metadata }
    public var metadataJSON: String { core.structure.metadataJSON }
    /// The v1 index entries; empty on a tiled v2 file.
    public var entries: [XuePlaneEntry] {
        if case .planes(let planes) = core.structure.layout { return planes.entries }
        return []
    }
    public var dataOffset: UInt64 { core.structure.dataOffset }
    public var fileSize: UInt64 { core.structure.fileSize }
    /// The time axis as frame offsets, ascending.
    public var frameOffsets: [UInt16] { metadata.time.frameOffsets }
    /// Seconds one frame offset is worth: the frame at offset `o` is valid at
    /// `runTime + o * unitSeconds`.
    public var unitSeconds: Int { metadata.time.unitSeconds }
    /// The file's tiling, or `nil` for a plane-major v1 file.
    public var tileGeometry: XueTileGeometry? { core.tileGeometry }
    /// Sum of every payload's compressed length.
    public var totalPayloadBytes: UInt64 {
        (0..<core.structure.payloadCount).reduce(0) { total, position in
            let span = core.structure.payloadSpan(position)
            return total + (span.1 - span.0)
        }
    }
    /// Compressed bytes inserted so far.
    public var residentPayloadBytes: UInt64 {
        if case .sparse(_, let bytes) = core.store { return bytes }
        return 0
    }

    public func clearCache() { core.clearCache() }

    /// The one contiguous byte span still needed to decode any frame of the
    /// temporal group containing `request`, or `nil` when it is all resident.
    ///
    /// This is the global-view request in both versions, and it stays one
    /// range in both: v1 keeps a variable's group adjacent, v2 keeps a whole
    /// group — every tile, every variable — adjacent. On a v2 file the span
    /// therefore covers the group's other variables too, which is what a
    /// two-component wind bundle needs anyway and saves it a second round
    /// trip for the last tile.
    public func missingGroupRange(for request: XueFrameRequest) throws -> XueByteRange? {
        let positions: [Int]
        switch core.structure.layout {
        case .planes(let planes):
            let target = planes.entries[try planes.entryPosition(for: request)]
            positions = planes.entries.indices.filter { position in
                let member = planes.entries[position]
                return member.variableID == target.variableID && member.groupID == target.groupID
            }
        case .tiles(let layout):
            _ = try layout.variablePosition(request.variableID)
            let group = layout.frameGroup[try core.structure.frameIndex(request.frameOffset)].group
            let first = layout.chunkPosition(group: group, tile: 0, variablePosition: 0)
            positions = Array(first..<(first + layout.geometry.count * layout.variables.count))
        }
        var lower: UInt64?
        var upper: UInt64?
        for position in positions where !core.isResident(position: position) {
            let span = core.structure.payloadSpan(position)
            lower = min(lower ?? span.0, span.0)
            upper = max(upper ?? span.1, span.1)
        }
        guard let lower, let upper else { return nil }
        return XueByteRange(lowerBound: lower, upperBound: upper)
    }

    /// The byte spans a frame still needs, restricted to a tile rectangle and
    /// merged where the chunks are adjacent in the file — one span per tile
    /// row per group, since a row of tiles is contiguous. Fails on a v1 file
    /// when a rectangle is given.
    public func missingSpans(for request: XueFrameRequest, tiles: XueTileRect?) throws -> [XueByteRange] {
        let positions: [Int]
        switch core.structure.layout {
        case .planes(let planes):
            guard tiles == nil else { throw XueDecodeError("a plane-major file has no tiles") }
            let target = planes.entries[try planes.entryPosition(for: request)]
            positions = planes.entries.indices.filter { position in
                let member = planes.entries[position]
                return member.variableID == target.variableID && member.groupID == target.groupID
            }
        case .tiles(let layout):
            let variablePosition = try layout.variablePosition(request.variableID)
            let group = layout.frameGroup[try core.structure.frameIndex(request.frameOffset)].group
            positions = (0..<layout.geometry.count)
                .filter { tile in tiles.map { $0.contains(tile, in: layout.geometry) } ?? true }
                .map { layout.chunkPosition(group: group, tile: $0, variablePosition: variablePosition) }
        }
        return Self.mergeAdjacent(positions.filter { !core.isResident(position: $0) }.map(core.structure.payloadSpan))
    }

    /// The spans one cell's series still needs: one chunk per group, so at
    /// most one span per group and nothing proportional to the frame count.
    public func missingSeriesSpans(variableID: UInt8, column: Int, row: Int) throws -> [XueByteRange] {
        let layout = try core.tiles()
        let variablePosition = try layout.variablePosition(variableID)
        let tile = try layout.geometry.tile(row: row, column: column)
        let positions = layout.groups.indices
            .map { layout.chunkPosition(group: $0, tile: tile, variablePosition: variablePosition) }
            .filter { !core.isResident(position: $0) }
        return Self.mergeAdjacent(positions.map(core.structure.payloadSpan))
    }

    /// Store payload bytes covering `[offset, offset + data.count)` of the
    /// file. Every payload lying fully inside the range becomes resident;
    /// partial overlaps are ignored.
    public func insertRange(offset: UInt64, data: Data) throws {
        let end = try checkedAdd(offset, UInt64(data.count), label: "inserted range")
        guard end <= fileSize else { throw XueDecodeError("inserted range exceeds fileSize") }
        guard case .sparse(var payloads, var residentBytes) = core.store else { return }
        for position in 0..<core.structure.payloadCount where payloads[position] == nil {
            let (start, stop) = core.structure.payloadSpan(position)
            guard start < stop, start >= offset, stop <= end else { continue }
            let from = try checkedInt(start - offset, label: "range offset")
            let length = try checkedInt(stop - start, label: "payload length")
            payloads[position] = data.subdata(in: (data.startIndex + from)..<(data.startIndex + from + length))
            residentBytes += stop - start
        }
        core.store = .sparse(payloads, residentBytes)
    }

    public func decodeFrame(variableID: UInt8, frameOffset: UInt16) throws -> Data {
        try core.decodeFrame(XueFrameRequest(variableID: variableID, frameOffset: frameOffset), tiles: nil)
    }

    public func decodeFrame(_ request: XueFrameRequest) throws -> Data { try core.decodeFrame(request, tiles: nil) }

    /// Decode only the tiles a viewport covers; see `XueBundle.decodeFrame(_:tiles:)`.
    public func decodeFrame(_ request: XueFrameRequest, tiles: XueTileRect) throws -> Data {
        try core.decodeFrame(request, tiles: tiles)
    }

    /// One cell's code on every frame of the axis, in axis order.
    public func decodeSeries(variableID: UInt8, column: Int, row: Int) throws -> Data {
        try core.decodeSeries(variableID: variableID, column: column, row: row)
    }

    /// The given spans in ascending order, with touching ones joined. Chunks
    /// are strictly adjacent in the file, so a run of neighbouring tiles
    /// collapses to a single range request.
    private static func mergeAdjacent(_ spans: [(UInt64, UInt64)]) -> [XueByteRange] {
        var merged: [XueByteRange] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, span.0 <= last.upperBound {
                merged[merged.count - 1] = XueByteRange(lowerBound: last.lowerBound, upperBound: max(last.upperBound, span.1))
            } else {
                merged.append(XueByteRange(lowerBound: span.0, upperBound: span.1))
            }
        }
        return merged
    }
}
