import Foundation

public struct XueFrameRequest: Hashable, Sendable {
    public let variableID: UInt8
    public let forecastHour: UInt16

    public init(variableID: UInt8, forecastHour: UInt16) {
        self.variableID = variableID
        self.forecastHour = forecastHour
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
    public let forecastHour: UInt16
    public let dependencyHour: UInt16
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

    public struct TimeAxis: Codable, Sendable {
        public let firstForecastHour: Int
        public let stepHours: Int
        public let frameCount: Int
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
        public let quantization: Quantization
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
