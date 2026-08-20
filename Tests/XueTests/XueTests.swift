import Foundation
import Testing
@testable import Xue

@Test func goldenFileMatchesPythonDecoder() throws {
    let bundle = try XueBundle(contentsOf: #require(Bundle.module.url(forResource: "tmp2m", withExtension: "xue")))
    let expected = try Data(contentsOf: #require(Bundle.module.url(forResource: "expected.tmp2m.f000", withExtension: "bin")))

    #expect(bundle.metadata.schemaVersion == 1)
    #expect(bundle.metadata.model == "GFS")
    #expect(bundle.metadata.variables.first?.id == "tmp2m")
    #expect(try bundle.decodeFrame(variableID: 1, forecastHour: 0) == expected)
}

@Test func streamingRangeDecodeMatchesCompleteFile() throws {
    let bytes = try Data(contentsOf: #require(Bundle.module.url(forResource: "tmp2m", withExtension: "xue")))
    let full = try XueBundle(data: bytes)
    let dataOffset = Int(readUInt64(bytes, at: 56))
    let streaming = try XueStreamingBundle(prefix: bytes.prefix(dataOffset))
    let request = XueFrameRequest(variableID: 1, forecastHour: 0)
    let missingRange = try streaming.missingGroupRange(for: request)
    let range = try #require(missingRange)

    #expect(throws: XueDecodeError.self) { try streaming.decodeFrame(request) }
    try streaming.insertRange(
        offset: range.lowerBound,
        data: bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    )
    #expect(try streaming.missingGroupRange(for: request) == nil)
    #expect(try streaming.decodeFrame(request) == full.decodeFrame(request))
}

@Test func badHeaderAndCRCAreRejected() throws {
    let original = try Data(contentsOf: #require(Bundle.module.url(forResource: "tmp2m", withExtension: "xue")))
    var badMagic = original
    badMagic[0] = 0
    #expect(throws: XueDecodeError.self) { try XueBundle(data: badMagic) }

    var badCRC = original
    let indexOffset = Int(readUInt64(original, at: 40))
    badCRC[indexOffset + 16 + 28] ^= 0xff
    let bundle = try XueBundle(data: badCRC)
    #expect(throws: XueDecodeError.self) { try bundle.decodeFrame(variableID: 1, forecastHour: 0) }
}

@Test func moduloResidualReconstruction() throws {
    let bytes = makeUncompressedAnchorBundle()
    let bundle = try XueBundle(data: bytes)
    #expect(try bundle.decodeFrame(variableID: 1, forecastHour: 1) == Data([250, 5, 100, 0]))
    #expect(try bundle.decodeFrame(variableID: 1, forecastHour: 0) == Data([2, 250, 100, 255]))
}

private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 { value |= UInt64(data[offset + index]) << UInt64(index * 8) }
    return value
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func align(_ value: Int) -> Int { (value + 7) / 8 * 8 }

private func makeUncompressedAnchorBundle() -> Data {
    let metadata = Data(#"{"schemaVersion":1,"model":"TEST","product":"test","runTime":"2026-01-01T00:00:00Z","time":{"firstForecastHour":0,"stepHours":1,"frameCount":2},"grid":{"width":2,"height":2,"layout":"row-major","rowOrder":"north-to-south","columnOrder":"west-to-east","firstLongitude":-180,"firstLatitude":90,"longitudeStep":1,"latitudeStep":-1,"wrapLongitude":true},"variables":[{"numericId":1,"id":"tmp2m","label":"temperature","unit":"C","quantization":{"type":"linear","offset":-60,"scale":0.5,"minimumCode":0,"maximumCode":254,"nodataCode":255}}]}"#.utf8)
    let indexOffset = align(80 + metadata.count)
    let indexLength = 16 + 2 * 40
    let dataOffset = align(indexOffset + indexLength)
    let anchor = Data([250, 5, 100, 0])
    let target = Data([2, 250, 100, 255])
    let residual = Data(zip(target, anchor).map { $0 &- $1 })
    let fileSize = align(dataOffset + anchor.count + residual.count)
    var file = Data(repeating: 0, count: fileSize)

    var header = Data([0x58, 0x55, 0x45, 0, 0, 0, 0, 0])
    append(UInt16(1), to: &header)
    append(UInt16(80), to: &header)
    append(UInt32(0), to: &header)
    append(UInt64(fileSize), to: &header)
    append(UInt64(80), to: &header)
    append(UInt64(metadata.count), to: &header)
    append(UInt64(indexOffset), to: &header)
    append(UInt64(indexLength), to: &header)
    append(UInt64(dataOffset), to: &header)
    append(UInt64(0), to: &header)
    append(UInt64(0), to: &header)
    file.replaceSubrange(0..<80, with: header)
    file.replaceSubrange(80..<(80 + metadata.count), with: metadata)

    var index = Data("IDX1".utf8)
    append(UInt16(40), to: &index)
    append(UInt16(1), to: &index)
    append(UInt32(2), to: &index)
    append(UInt32(0), to: &index)
    appendEntry(predictor: 1, hour: 0, dependency: 1, group: 0, offset: dataOffset + 4, plane: target, payloadLength: 4, to: &index)
    appendEntry(predictor: 0, hour: 1, dependency: UInt16.max, group: 0, offset: dataOffset, plane: anchor, payloadLength: 4, to: &index)
    file.replaceSubrange(indexOffset..<(indexOffset + index.count), with: index)
    file.replaceSubrange(dataOffset..<(dataOffset + 4), with: anchor)
    file.replaceSubrange((dataOffset + 4)..<(dataOffset + 8), with: residual)
    return file
}

private func appendEntry(
    predictor: UInt8, hour: UInt16, dependency: UInt16, group: UInt16,
    offset: Int, plane: Data, payloadLength: UInt32, to index: inout Data
) {
    index.append(1)
    index.append(predictor)
    index.append(0)
    index.append(0)
    append(hour, to: &index)
    append(dependency, to: &index)
    append(group, to: &index)
    append(UInt16(0), to: &index)
    append(payloadLength, to: &index)
    append(UInt64(offset), to: &index)
    append(UInt32(plane.count), to: &index)
    append(crc32(plane), to: &index)
    index.append(plane.min()!)
    index.append(plane.max()!)
    index.append(contentsOf: repeatElement(0, count: 6))
}
