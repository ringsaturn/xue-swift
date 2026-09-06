import Foundation
import Testing
@testable import Xue

@Test func goldenFileMatchesPythonDecoder() throws {
    let bundle = try XueBundle(contentsOf: #require(Bundle.module.url(forResource: "tmp2m", withExtension: "xue")))
    let expected = try Data(contentsOf: #require(Bundle.module.url(forResource: "expected.tmp2m.f000", withExtension: "bin")))

    #expect(bundle.metadata.schemaVersion == 3)
    #expect(bundle.metadata.model == "GFS")
    #expect(bundle.unitSeconds == 3600)
    #expect(bundle.frameOffsets == [0])
    let variable = try #require(bundle.metadata.variables.first)
    #expect(variable.id == "tmp2m")
    let parameter = try #require(variable.parameter)
    #expect(parameter.discipline == 0)
    #expect(parameter.parameterCategory == 0)
    #expect(parameter.parameterNumber == 0)
    #expect(parameter.typeOfFirstFixedSurface == 103)
    #expect(parameter.firstFixedSurfaceValue == 2)
    #expect(parameter.typeOfStatisticalProcessing == nil)
    #expect(try bundle.decodeFrame(variableID: 1, frameOffset: 0) == expected)

    // Metadata re-encodes into the shape it was read from.
    let reencoded = try JSONDecoder().decode(XueMetadata.self, from: JSONEncoder().encode(bundle.metadata))
    #expect(reencoded.schemaVersion == 3)
    #expect(reencoded.time.frameOffsets == bundle.frameOffsets)
    #expect(reencoded.time.frameStep == 1)
    #expect(reencoded.variables.first?.parameter?.typeOfFirstFixedSurface == 103)
}

/// A mixed-cadence axis, hourly then three-hourly: the offsets are listed
/// outright and temporal groups are formed inside each segment.
@Test func listedAxisGoldenPlanesMatchPythonDecoder() throws {
    let bundle = try XueBundle(contentsOf: #require(Bundle.module.url(forResource: "mixed", withExtension: "xue")))

    #expect(bundle.metadata.schemaVersion == 3)
    #expect(bundle.metadata.time.frameStep == nil)
    #expect(bundle.frameOffsets == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 18, 21, 24, 27, 30, 33, 36])
    #expect(bundle.metadata.time.secondsFromRunTime(frameIndex: 20) == 36 * 3600)

    for offset: UInt16 in [0, 4, 18, 36] {
        let name = String(format: "expected.mixed.f%03d", Int(offset))
        let expected = try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "bin")))
        #expect(try bundle.decodeFrame(variableID: 1, frameOffset: offset) == expected)
    }
}

@Test func streamingRangeDecodeMatchesCompleteFile() throws {
    let bytes = try Data(contentsOf: #require(Bundle.module.url(forResource: "mixed", withExtension: "xue")))
    let full = try XueBundle(data: bytes)
    let dataOffset = Int(readUInt64(bytes, at: 56))
    let streaming = try XueStreamingBundle(prefix: bytes.prefix(dataOffset))
    let request = XueFrameRequest(variableID: 1, frameOffset: 18)
    let range = try #require(try streaming.missingGroupRange(for: request))

    #expect(streaming.frameOffsets == full.frameOffsets)
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
    #expect(throws: XueDecodeError.self) { try bundle.decodeFrame(variableID: 1, frameOffset: 0) }
}

@Test func moduloResidualReconstruction() throws {
    let bundle = try XueBundle(data: makeAnchorBundle(metadata: offsetAxisMetadata(), offsets: [0, 1]))
    #expect(try bundle.decodeFrame(variableID: 1, frameOffset: 0) == syntheticPlanes[0])
    #expect(try bundle.decodeFrame(variableID: 1, frameOffset: 1) == syntheticPlanes[1])
}

/// Bundles published under the legacy whole-hour axes stay readable.
@Test func legacyHourAxesRemainReadable() throws {
    let uniform = try XueBundle(data: makeAnchorBundle(
        metadata: hourAxisMetadata(#""stepHours":1"#, schemaVersion: 1), offsets: [0, 1]
    ))
    #expect(uniform.metadata.schemaVersion == 1)
    #expect(uniform.unitSeconds == 3600)
    #expect(uniform.frameOffsets == [0, 1])
    #expect(uniform.metadata.variables.allSatisfy { $0.parameter == nil })
    #expect(try uniform.decodeFrame(variableID: 1, frameOffset: 1) == syntheticPlanes[1])

    let listed = try XueBundle(data: makeAnchorBundle(
        metadata: hourAxisMetadata(#""hours":[0,1,3]"#, schemaVersion: 2, frameCount: 3), offsets: [0, 1, 3]
    ))
    #expect(listed.metadata.schemaVersion == 2)
    #expect(listed.frameOffsets == [0, 1, 3])
    #expect(try listed.decodeFrame(variableID: 1, frameOffset: 3) == syntheticPlanes[2])
}

/// Each case is a whole valid bundle apart from the one metadata rule it
/// breaks, so the rejection can only come from that rule.
@Test(arguments: [
    // The parameter block and the unit-neutral axis are what schemaVersion 3
    // introduces: neither is valid below it, and version 3 carries both.
    InvalidMetadata(offsetAxisMetadata(schemaVersion: 1)),
    InvalidMetadata(hourAxisMetadata(#""stepHours":1"#, schemaVersion: 1, parameter: true)),
    InvalidMetadata(hourAxisMetadata(#""stepHours":1"#, schemaVersion: 3, parameter: true)),
    // The declared version must be the lowest able to express the metadata.
    InvalidMetadata(hourAxisMetadata(#""stepHours":1"#, schemaVersion: 2)),
    InvalidMetadata(offsetAxisMetadata(schemaVersion: 4)),
    // Exactly one of a uniform step and a listed axis, and never a uniform list.
    InvalidMetadata(offsetAxisMetadata(axis: #""firstFrameOffset":0,"frameStep":1,"frameOffsets":[0,1]"#)),
    InvalidMetadata(offsetAxisMetadata(axis: #""firstFrameOffset":0"#)),
    InvalidMetadata(offsetAxisMetadata(axis: #""firstFrameOffset":0,"frameOffsets":[0,1]"#)),
    InvalidMetadata(
        offsetAxisMetadata(axis: #""firstFrameOffset":0,"frameOffsets":[1,2,4]"#, frameCount: 3),
        offsets: [1, 2, 4]
    ),
    InvalidMetadata(
        offsetAxisMetadata(axis: #""firstFrameOffset":2,"frameOffsets":[2,1,4]"#, frameCount: 3),
        offsets: [1, 2, 4]
    ),
    // No field the time block does not define, in either shape.
    InvalidMetadata(offsetAxisMetadata(axis: #""firstFrameOffset":0,"frameStep":1,"stepHours":1"#)),
    // unitSeconds must be a whole divisor of 3600, and the coarsest that fits.
    InvalidMetadata(offsetAxisMetadata(unitSeconds: 7)),
    InvalidMetadata(
        offsetAxisMetadata(unitSeconds: 1800, axis: #""firstFrameOffset":0,"frameStep":2"#),
        offsets: [0, 2]
    ),
    // A fixed surface is wholly present or wholly null, and both keys are
    // always there.
    InvalidMetadata(offsetAxisMetadata(parameter: #""discipline":0,"parameterCategory":0,"parameterNumber":0,"typeOfFirstFixedSurface":103,"scaleFactorOfFirstFixedSurface":0,"scaledValueOfFirstFixedSurface":null"#)),
    InvalidMetadata(offsetAxisMetadata(parameter: #""discipline":0,"parameterCategory":0,"parameterNumber":0,"typeOfFirstFixedSurface":103"#)),
    // No key the parameter block does not define, and no code outside 0-255.
    InvalidMetadata(offsetAxisMetadata(parameter: defaultParameter + #","level":2"#)),
    InvalidMetadata(offsetAxisMetadata(parameter: #""discipline":256,"parameterCategory":0,"parameterNumber":0,"typeOfFirstFixedSurface":103,"scaleFactorOfFirstFixedSurface":0,"scaledValueOfFirstFixedSurface":2"#)),
])
func invalidMetadataIsRejected(_ testCase: InvalidMetadata) throws {
    #expect(throws: XueDecodeError.self) {
        try XueBundle(data: makeAnchorBundle(metadata: testCase.metadata, offsets: testCase.offsets))
    }
}

struct InvalidMetadata: Sendable {
    let metadata: String
    let offsets: [UInt16]

    init(_ metadata: String, offsets: [UInt16] = [0, 1]) {
        self.metadata = metadata
        self.offsets = offsets
    }
}

private let defaultParameter = #""discipline":0,"parameterCategory":0,"parameterNumber":0,"typeOfFirstFixedSurface":103,"scaleFactorOfFirstFixedSurface":0,"scaledValueOfFirstFixedSurface":2"#

/// Metadata for the synthetic bundle below, on a schemaVersion 3 unit-neutral
/// axis.
private func offsetAxisMetadata(
    schemaVersion: Int = 3,
    unitSeconds: Int = 3600,
    axis: String = #""firstFrameOffset":0,"frameStep":1"#,
    parameter: String = defaultParameter,
    frameCount: Int = 2
) -> String {
    makeMetadata(
        schemaVersion: schemaVersion,
        time: #""unitSeconds":\#(unitSeconds),\#(axis),"frameCount":\#(frameCount)"#,
        parameter: #""parameter":{\#(parameter)},"#
    )
}

/// Metadata on a legacy whole-hour axis, which carries no parameter block
/// unless a case asks for that invalid combination.
private func hourAxisMetadata(
    _ axis: String, schemaVersion: Int, frameCount: Int = 2, parameter: Bool = false
) -> String {
    makeMetadata(
        schemaVersion: schemaVersion,
        time: #""firstForecastHour":0,\#(axis),"frameCount":\#(frameCount)"#,
        parameter: parameter ? #""parameter":{\#(defaultParameter)},"# : ""
    )
}

private func makeMetadata(schemaVersion: Int, time: String, parameter: String) -> String {
    #"""
    {"schemaVersion":\#(schemaVersion),"model":"TEST","product":"test","runTime":"2026-01-01T00:00:00Z",\#
    "time":{\#(time)},\#
    "grid":{"width":2,"height":2,"layout":"row-major","rowOrder":"north-to-south","columnOrder":"west-to-east",\#
    "firstLongitude":-180,"firstLatitude":90,"longitudeStep":1,"latitudeStep":-1,"wrapLongitude":true},\#
    "variables":[{"numericId":1,"id":"tmp2m","label":"temperature","unit":"C",\#(parameter)\#
    "quantization":{"type":"linear","offset":-60,"scale":0.5,"minimumCode":0,"maximumCode":254,"nodataCode":255}}]}
    """#
}

/// Planes whose differences wrap in both directions, so the residuals below
/// exercise modulo-256 reconstruction.
private let syntheticPlanes: [Data] = [
    Data([2, 250, 100, 255]),
    Data([250, 5, 100, 0]),
    Data([7, 7, 7, 7]),
]

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

/// A single-variable bundle with uncompressed payloads: a RAW anchor on the
/// first frame offset, and one ANCHOR residual against it per later frame.
private func makeAnchorBundle(metadata json: String, offsets: [UInt16]) -> Data {
    let metadata = Data(json.utf8)
    let indexOffset = align(80 + metadata.count)
    let indexLength = 16 + offsets.count * 40
    let dataOffset = align(indexOffset + indexLength)
    let planes = Array(syntheticPlanes.prefix(offsets.count))
    let payloads = planes.enumerated().map { index, plane in
        index == 0 ? plane : Data(zip(plane, planes[0]).map { $0 &- $1 })
    }
    let payloadBytes = payloads.reduce(0) { $0 + $1.count }
    let fileSize = align(dataOffset + payloadBytes)
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
    append(UInt32(offsets.count), to: &index)
    append(UInt32(0), to: &index)
    var payloadOffset = dataOffset
    for (position, offset) in offsets.enumerated() {
        appendEntry(
            predictor: position == 0 ? 0 : 1,
            offset: offset,
            dependency: position == 0 ? UInt16.max : offsets[0],
            payloadOffset: payloadOffset,
            plane: planes[position],
            payloadLength: UInt32(payloads[position].count),
            to: &index
        )
        file.replaceSubrange(payloadOffset..<(payloadOffset + payloads[position].count), with: payloads[position])
        payloadOffset += payloads[position].count
    }
    file.replaceSubrange(indexOffset..<(indexOffset + index.count), with: index)
    return file
}

private func appendEntry(
    predictor: UInt8, offset: UInt16, dependency: UInt16,
    payloadOffset: Int, plane: Data, payloadLength: UInt32, to index: inout Data
) {
    index.append(1)
    index.append(predictor)
    index.append(0)
    index.append(0)
    append(offset, to: &index)
    append(dependency, to: &index)
    append(UInt16(0), to: &index)
    append(UInt16(0), to: &index)
    append(payloadLength, to: &index)
    append(UInt64(payloadOffset), to: &index)
    append(UInt32(plane.count), to: &index)
    append(crc32(plane), to: &index)
    index.append(plane.min()!)
    index.append(plane.max()!)
    index.append(contentsOf: repeatElement(0, count: 6))
}
