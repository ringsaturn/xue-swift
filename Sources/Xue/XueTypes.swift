import Foundation

/// One plane of one variable, keyed the way the index keys it: a frame offset
/// on the metadata time axis, not a forecast hour. The frame is valid at
/// `runTime + frameOffset * unitSeconds`.
public struct XueFrameRequest: Hashable, Sendable {
    public let variableID: UInt8
    public let frameOffset: UInt16

    public init(variableID: UInt8, frameOffset: UInt16) {
        self.variableID = variableID
        self.frameOffset = frameOffset
    }
}

public enum XuePredictor: UInt8, Sendable {
    case raw = 0
    case anchor = 1
    case previous = 2
    case zero = 3
}

public enum XueCompression: UInt8, Sendable {
    case none = 0
    case zstd = 1
    case zstdDictionary = 2
}

public struct XuePlaneEntry: Sendable {
    public let variableID: UInt8
    public let predictor: XuePredictor
    public let compression: XueCompression
    public let flags: UInt8
    public let frameOffset: UInt16
    public let dependencyOffset: UInt16
    public let groupID: UInt16
    public let compressedLength: UInt32
    public let dataOffset: UInt64
    public let decodedLength: UInt32
    public let crc32: UInt32
    public let minimumCode: UInt8
    public let maximumCode: UInt8
}

public struct XueMetadata: Codable, Sendable {
    public let schemaVersion: Int
    public let model: String
    public let product: String
    public let runTime: String
    public let time: TimeAxis
    public let grid: Grid
    public let variables: [Variable]

    /// The time axis, materialized as frame offsets whatever shape the file
    /// declares.
    ///
    /// Schema versions 1 and 2 describe a whole-hour axis with
    /// `firstForecastHour` plus one of `stepHours` (uniform) and `hours`
    /// (listed outright). Version 3 replaces the block with a unit-neutral one
    /// — `unitSeconds` plus offsets in that unit — so a series finer than an
    /// hour has an exact axis. Both shapes decode into the fields below; the
    /// two never mix, and `axisVersion` records the lowest schema version able
    /// to express what was read.
    public struct TimeAxis: Codable, Sendable {
        /// Seconds one offset unit is worth. Always 3600 on a version 1 or 2
        /// axis; a whole divisor of 3600 on a version 3 axis.
        public let unitSeconds: Int
        public let firstFrameOffset: Int
        public let frameCount: Int
        /// The uniform step, or `nil` when the axis lists its offsets outright.
        public let frameStep: Int?
        /// The full axis, ascending, with `frameCount` elements.
        public let frameOffsets: [UInt16]

        let axisVersion: Int

        /// The seconds from `runTime` to the frame at `frameOffsets[index]`.
        public func secondsFromRunTime(frameIndex index: Int) -> Int {
            Int(frameOffsets[index]) * unitSeconds
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: XueAnyKey.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            let frameCount = try Self.integer(container, "frameCount")
            guard let frameCount, frameCount > 0, frameCount <= Int(UInt16.max) else {
                throw XueDecodeError("metadata frameCount is invalid")
            }
            self.frameCount = frameCount

            if keys.contains(where: Self.offsetAxisFields.contains) {
                // A unit-neutral axis. Every field it may carry is known, so an
                // unrecognized one is a later schema version this reader does
                // not implement — including any of the hour-named fields.
                guard keys.allSatisfy({ $0 == "frameCount" || Self.offsetAxisFields.contains($0) }) else {
                    throw XueDecodeError("metadata time block has an unknown field")
                }
                guard let unitSeconds = try Self.integer(container, "unitSeconds"),
                      unitSeconds >= 1, unitSeconds <= XueFormat.hourSeconds,
                      XueFormat.hourSeconds % unitSeconds == 0 else {
                    throw XueDecodeError("metadata unitSeconds must be a whole divisor of 3600")
                }
                guard let first = try Self.integer(container, "firstFrameOffset"),
                      first >= 0, first <= Int(UInt16.max) else {
                    throw XueDecodeError("metadata firstFrameOffset is invalid")
                }
                self.unitSeconds = unitSeconds
                firstFrameOffset = first
                (frameStep, frameOffsets) = try Self.axis(
                    container, step: "frameStep", listed: "frameOffsets",
                    first: first, frameCount: frameCount
                )
                // The unit is the coarsest one that expresses every offset
                // exactly, so an axis has one encoding rather than one per
                // divisor of its step.
                var divisor = XueFormat.hourSeconds / unitSeconds
                for offset in frameOffsets { divisor = Self.greatestCommonDivisor(divisor, Int(offset)) }
                guard divisor == 1 else { throw XueDecodeError("metadata unitSeconds is finer than the axis needs") }
                axisVersion = 3
            } else {
                guard let first = try Self.integer(container, "firstForecastHour"),
                      first >= 0, first <= Int(UInt16.max) else {
                    throw XueDecodeError("metadata firstForecastHour is invalid")
                }
                unitSeconds = XueFormat.hourSeconds
                firstFrameOffset = first
                (frameStep, frameOffsets) = try Self.axis(
                    container, step: "stepHours", listed: "hours",
                    first: first, frameCount: frameCount
                )
                axisVersion = frameStep == nil ? 2 : 1
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: XueAnyKey.self)
            if axisVersion == 3 {
                try container.encode(unitSeconds, forKey: XueAnyKey("unitSeconds"))
                try container.encode(firstFrameOffset, forKey: XueAnyKey("firstFrameOffset"))
                try container.encode(frameCount, forKey: XueAnyKey("frameCount"))
                if let frameStep {
                    try container.encode(frameStep, forKey: XueAnyKey("frameStep"))
                } else {
                    try container.encode(frameOffsets, forKey: XueAnyKey("frameOffsets"))
                }
            } else {
                try container.encode(firstFrameOffset, forKey: XueAnyKey("firstForecastHour"))
                try container.encode(frameCount, forKey: XueAnyKey("frameCount"))
                if let frameStep {
                    try container.encode(frameStep, forKey: XueAnyKey("stepHours"))
                } else {
                    try container.encode(frameOffsets, forKey: XueAnyKey("hours"))
                }
            }
        }

        private static let offsetAxisFields: Set<String> = [
            "unitSeconds", "firstFrameOffset", "frameStep", "frameOffsets",
        ]

        private static func integer(
            _ container: KeyedDecodingContainer<XueAnyKey>, _ name: String
        ) throws -> Int? {
            try container.decodeIfPresent(Int.self, forKey: XueAnyKey(name))
        }

        /// Exactly one of a uniform step and a listed axis, materialized.
        private static func axis(
            _ container: KeyedDecodingContainer<XueAnyKey>,
            step stepName: String, listed listedName: String,
            first: Int, frameCount: Int
        ) throws -> (Int?, [UInt16]) {
            let step = try integer(container, stepName)
            let listed = try container.decodeIfPresent([Int].self, forKey: XueAnyKey(listedName))
            switch (step, listed) {
            case (.some, .some), (.none, .none):
                throw XueDecodeError("metadata time must declare exactly one of \(stepName) and \(listedName)")
            case (.some(let step), .none):
                guard step > 0, step <= Int(UInt16.max) else { throw XueDecodeError("metadata \(stepName) is invalid") }
                let last = try checkedAdd(
                    UInt64(first),
                    checkedMultiply(UInt64(frameCount - 1), UInt64(step), label: "frame offset"),
                    label: "frame offset"
                )
                guard last <= UInt64(XueFormat.maximumFrameOffset) else {
                    throw XueDecodeError("frame offsets exceed the u16 range")
                }
                return (step, (0..<frameCount).map { UInt16(first + $0 * step) })
            case (.none, .some(let listed)):
                guard listed.count == frameCount else { throw XueDecodeError("metadata \(listedName) does not match frameCount") }
                var offsets: [UInt16] = []
                offsets.reserveCapacity(listed.count)
                for value in listed {
                    guard value >= 0, value <= Int(XueFormat.maximumFrameOffset) else {
                        throw XueDecodeError("metadata \(listedName) contains an offset outside the u16 range")
                    }
                    if let previous = offsets.last, UInt16(value) <= previous {
                        throw XueDecodeError("metadata \(listedName) must be strictly increasing")
                    }
                    offsets.append(UInt16(value))
                }
                guard offsets[0] == UInt16(first) else {
                    throw XueDecodeError("metadata \(listedName) must begin with the declared first offset")
                }
                // A uniform axis has exactly one encoding, the step — which
                // also rules out lists of fewer than three offsets, since any
                // shorter axis is trivially uniform.
                let steps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
                guard steps.count >= 2, !steps.allSatisfy({ $0 == steps[0] }) else {
                    throw XueDecodeError("a uniform axis must be encoded as a step")
                }
                return (nil, offsets)
            }
        }

        private static func greatestCommonDivisor(_ left: Int, _ right: Int) -> Int {
            right == 0 ? left : greatestCommonDivisor(right, left % right)
        }
    }

    public struct Grid: Codable, Sendable {
        public let width: Int
        public let height: Int
        public let layout: String
        public let rowOrder: String
        public let columnOrder: String
        public let firstLongitude: Double
        public let firstLatitude: Double
        public let longitudeStep: Double
        public let latitudeStep: Double
        public let wrapLongitude: Bool
    }

    public struct Variable: Codable, Sendable {
        public let numericId: Int
        public let id: String
        public let label: String
        public let unit: String
        /// The GRIB2 identity, present exactly on schemaVersion 3 files.
        public let parameter: Parameter?
        public let quantization: Quantization
    }

    /// What a variable *is*, in GRIB2's own terms, so a reader can recognize a
    /// field without matching on `id` strings. Introduced by schemaVersion 3.
    public struct Parameter: Codable, Sendable {
        /// Section 0, octet 7.
        public let discipline: Int
        /// Section 4, code table 4.1.
        public let parameterCategory: Int
        /// Section 4, code table 4.2.
        public let parameterNumber: Int
        /// Section 4, code table 4.5.
        public let typeOfFirstFixedSurface: Int
        /// `nil` together with `scaledValueOfFirstFixedSurface` on a surface
        /// that carries no value, which is how GRIB2 encodes one.
        public let scaleFactorOfFirstFixedSurface: Int?
        public let scaledValueOfFirstFixedSurface: UInt32?
        /// Section 4, code table 4.10. Absent for an instantaneous field,
        /// present when the values are a statistic over the step.
        public let typeOfStatisticalProcessing: Int?

        /// The fixed surface's value in its own unit, or `nil` when the surface
        /// carries none.
        public var firstFixedSurfaceValue: Double? {
            guard let scaleFactorOfFirstFixedSurface, let scaledValueOfFirstFixedSurface else { return nil }
            return Double(scaledValueOfFirstFixedSurface) * pow(10, Double(-scaleFactorOfFirstFixedSurface))
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: XueAnyKey.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            guard keys.allSatisfy(Self.knownFields.contains) else {
                throw XueDecodeError("metadata parameter block has an unknown field")
            }
            func code(_ name: String) throws -> Int {
                guard let value = try container.decodeIfPresent(Int.self, forKey: XueAnyKey(name)),
                      (0...255).contains(value) else {
                    throw XueDecodeError("metadata parameter code is invalid")
                }
                return value
            }
            discipline = try code("discipline")
            parameterCategory = try code("parameterCategory")
            parameterNumber = try code("parameterNumber")
            typeOfFirstFixedSurface = try code("typeOfFirstFixedSurface")

            // GRIB2 encodes a surface with no value by writing both halves as
            // missing; one of the two alone describes nothing. Both keys are
            // always present.
            guard keys.contains("scaleFactorOfFirstFixedSurface"),
                  keys.contains("scaledValueOfFirstFixedSurface") else {
                throw XueDecodeError("metadata parameter fixed surface value is incomplete")
            }
            let factor = try container.decodeIfPresent(Int.self, forKey: XueAnyKey("scaleFactorOfFirstFixedSurface"))
            let value = try container.decodeIfPresent(UInt32.self, forKey: XueAnyKey("scaledValueOfFirstFixedSurface"))
            guard (factor == nil) == (value == nil) else {
                throw XueDecodeError("metadata parameter fixed surface must be wholly present or wholly null")
            }
            if let factor {
                guard (-127...127).contains(factor) else {
                    throw XueDecodeError("metadata parameter scaleFactorOfFirstFixedSurface is invalid")
                }
                guard let value, value <= 0xFFFF_FFFE else {
                    throw XueDecodeError("metadata parameter scaledValueOfFirstFixedSurface is invalid")
                }
            }
            scaleFactorOfFirstFixedSurface = factor
            scaledValueOfFirstFixedSurface = value

            let statistical = try container.decodeIfPresent(Int.self, forKey: XueAnyKey("typeOfStatisticalProcessing"))
            if let statistical, !(0...255).contains(statistical) {
                throw XueDecodeError("metadata parameter typeOfStatisticalProcessing is invalid")
            }
            typeOfStatisticalProcessing = statistical
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: XueAnyKey.self)
            try container.encode(discipline, forKey: XueAnyKey("discipline"))
            try container.encode(parameterCategory, forKey: XueAnyKey("parameterCategory"))
            try container.encode(parameterNumber, forKey: XueAnyKey("parameterNumber"))
            try container.encode(typeOfFirstFixedSurface, forKey: XueAnyKey("typeOfFirstFixedSurface"))
            try container.encode(scaleFactorOfFirstFixedSurface, forKey: XueAnyKey("scaleFactorOfFirstFixedSurface"))
            try container.encode(scaledValueOfFirstFixedSurface, forKey: XueAnyKey("scaledValueOfFirstFixedSurface"))
            if let typeOfStatisticalProcessing {
                try container.encode(typeOfStatisticalProcessing, forKey: XueAnyKey("typeOfStatisticalProcessing"))
            }
        }

        private static let knownFields: Set<String> = [
            "discipline", "parameterCategory", "parameterNumber", "typeOfFirstFixedSurface",
            "scaleFactorOfFirstFixedSurface", "scaledValueOfFirstFixedSurface",
            "typeOfStatisticalProcessing",
        ]
    }

    public struct Quantization: Codable, Sendable {
        public let type: String
        public let offset: Double?
        public let scale: Double
        public let minimumCode: Int
        public let maximumCode: Int
        public let nodataCode: Int
        public let trace: Double?
        public let maximum: Double?
        public let zeroCode: Int?
        public let overflowCode: Int?
    }
}

/// A coding key that accepts whatever the JSON carries, so a container can be
/// asked which fields are actually present.
struct XueAnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct XueByteRange: Equatable, Sendable {
    public let lowerBound: UInt64
    public let upperBound: UInt64

    public init(lowerBound: UInt64, upperBound: UInt64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var length: UInt64 { upperBound - lowerBound }
}

public struct XueDecodeError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// How a container v2 grid is cut into tiles: arithmetic over the metadata
/// grid and the index header, stored nowhere in the file.
///
/// Tiles start at the grid's first cell and are laid out row-major; the last
/// column and the last row are clipped to the grid, so a tile size need not
/// divide the grid. A tile is cells, never degrees — the horizontal wrap of a
/// global grid is a property of the grid, not of any tile.
public struct XueTileGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let tileWidth: Int
    public let tileHeight: Int

    public init(width: Int, height: Int, tileWidth: Int, tileHeight: Int) throws {
        guard width > 0, height > 0, tileWidth >= 1, tileHeight >= 1,
              tileWidth <= width, tileHeight <= height else {
            throw XueDecodeError("tile size must be between 1 and the grid dimensions")
        }
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
    }

    public var columns: Int { (width + tileWidth - 1) / tileWidth }
    public var rows: Int { (height + tileHeight - 1) / tileHeight }
    public var count: Int { columns * rows }

    /// The (row, column) of a tile's north-west cell in the grid.
    public func origin(of tile: Int) -> (row: Int, column: Int) {
        ((tile / columns) * tileHeight, (tile % columns) * tileWidth)
    }

    /// The clipped (height, width) of a tile in cells.
    public func shape(of tile: Int) -> (height: Int, width: Int) {
        let origin = origin(of: tile)
        return (min(tileHeight, height - origin.row), min(tileWidth, width - origin.column))
    }

    /// The tile containing a grid cell.
    public func tile(row: Int, column: Int) throws -> Int {
        guard row >= 0, column >= 0, row < height, column < width else {
            throw XueDecodeError("cell is outside the grid")
        }
        return (row / tileHeight) * columns + column / tileWidth
    }
}

/// A rectangle of tiles, the unit a viewport asks for. Inclusive of both ends.
public struct XueTileRect: Equatable, Sendable {
    public let firstColumn: Int
    public let firstRow: Int
    public let lastColumn: Int
    public let lastRow: Int

    public init(firstColumn: Int, firstRow: Int, lastColumn: Int, lastRow: Int) {
        self.firstColumn = firstColumn
        self.firstRow = firstRow
        self.lastColumn = lastColumn
        self.lastRow = lastRow
    }

    /// The tiles a grid rectangle of cells touches, clamped to the geometry.
    public static func covering(
        _ geometry: XueTileGeometry, row: Int, column: Int, height: Int, width: Int
    ) -> XueTileRect {
        let lastRow = min(row + max(0, height - 1), geometry.height - 1)
        let lastColumn = min(column + max(0, width - 1), geometry.width - 1)
        return XueTileRect(
            firstColumn: max(0, min(column, geometry.width - 1)) / geometry.tileWidth,
            firstRow: max(0, min(row, geometry.height - 1)) / geometry.tileHeight,
            lastColumn: max(0, lastColumn) / geometry.tileWidth,
            lastRow: max(0, lastRow) / geometry.tileHeight
        )
    }

    public func contains(_ tile: Int, in geometry: XueTileGeometry) -> Bool {
        let row = tile / geometry.columns
        let column = tile % geometry.columns
        return (firstRow...max(firstRow, lastRow)).contains(row)
            && (firstColumn...max(firstColumn, lastColumn)).contains(column)
    }
}
