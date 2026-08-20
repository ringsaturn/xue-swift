# Xue Swift

`Xue` is a Swift Package Manager library for parsing and decoding Xue v1 weather bundles.

It validates the complete container structure before decoding any plane. Validation covers section geometry, zero padding, metadata and index consistency, payload adjacency, forecast coverage, dependency chains, decoded sizes, code ranges, and CRC-32. Zstandard frames with or without an embedded dictionary are supported.

## Requirements

- Swift 6.0 or newer
- Apple platform versions declared in `Package.swift`, or Linux

The package builds the upstream Zstandard 1.5.7 package as a dependency.

## Complete files

```swift
import Xue

let bundle = try XueBundle(contentsOf: fileURL)
let plane: Data = try bundle.decodeFrame(
    variableID: 1,
    forecastHour: 6
)

print(bundle.metadata.grid.width)
print(bundle.metadata.grid.height)
```

The returned `Data` contains one row-major quantized byte per grid point. Use the selected variable's `metadata.variables[].quantization` values to convert codes to scalar values.

## HTTP range streaming

Fetch the fixed 80-byte header first and read `dataOffset` at byte offset 56. Fetch `[0, dataOffset)` and open a streaming bundle:

```swift
let stream = try XueStreamingBundle(prefix: structuralPrefix)
let request = XueFrameRequest(variableID: 1, forecastHour: 6)

if let range = try stream.missingGroupRange(for: request) {
    // Fetch the half-open HTTP byte range [lowerBound, upperBound).
    let payload = try await fetch(range)
    try stream.insertRange(offset: range.lowerBound, data: payload)
}

let plane = try stream.decodeFrame(request)
```

`missingGroupRange(for:)` returns the contiguous span needed for the requested variable's temporal group. Range endpoints are half-open, so an HTTP `Range` header uses `bytes=lowerBound-(upperBound - 1)`.

## Development

```sh
swift test
```

Tests include a Python-generated golden fixture, range streaming, corruption checks, and modulo-256 temporal residual reconstruction.
