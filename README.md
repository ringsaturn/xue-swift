# Xue Swift

`Xue` is a Swift Package Manager library for parsing and decoding Xue v1 weather bundles.

It implements metadata schema versions 1 through 3 — the legacy whole-hour axes (`stepHours`, `hours`) and the unit-neutral axis version 3 introduced (`unitSeconds` with `frameStep` or `frameOffsets`), plus the per-variable GRIB2 `parameter` block. A file must declare the lowest schema version able to express its metadata, and both an unimplemented and an overdeclared version are rejected.

Validation covers the complete container before any plane is decoded: section geometry, zero padding, metadata and index consistency, payload adjacency, frame coverage against the materialized axis, dependency chains, decoded sizes, code ranges, and CRC-32. Zstandard frames with or without an embedded dictionary are supported.

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
    frameOffset: 6
)

print(bundle.metadata.grid.width)
print(bundle.metadata.grid.height)
```

The returned `Data` contains one row-major quantized byte per grid point. Use the selected variable's `metadata.variables[].quantization` values to convert codes to scalar values.

A plane is keyed by its **frame offset** on the metadata time axis, not by a forecast hour: the frame at offset `o` is valid at `runTime + o * unitSeconds`. `bundle.frameOffsets` lists the axis and `bundle.unitSeconds` gives the unit — 3600 for every forecast source, which leaves its offsets equal to its forecast hours, and finer for a sub-hourly observation series.

```swift
for offset in bundle.frameOffsets {
    let seconds = Int(offset) * bundle.unitSeconds
    ...
}
```

Variables also carry their GRIB2 identity on a schemaVersion 3 file, so a field can be recognized without matching on `id` strings:

```swift
let isTemperature = bundle.metadata.variables.contains {
    guard let parameter = $0.parameter else { return false }
    return (parameter.discipline, parameter.parameterCategory, parameter.parameterNumber) == (0, 0, 0)
        && parameter.typeOfFirstFixedSurface == 103
        && parameter.firstFixedSurfaceValue == 2
}
```

## HTTP range streaming

Fetch the fixed 80-byte header first and read `dataOffset` at byte offset 56. Fetch `[0, dataOffset)` and open a streaming bundle:

```swift
let stream = try XueStreamingBundle(prefix: structuralPrefix)
let request = XueFrameRequest(variableID: 1, frameOffset: 6)

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

Tests include Python-generated golden fixtures for a uniform and a mixed-cadence axis, range streaming, corruption checks, legacy schema version 1 and 2 axes, per-rule metadata rejection, and modulo-256 temporal residual reconstruction.

Fixtures come from the reference pipeline's `tests/prepare_bin_fixture.py`; `tmp2m.xue` and `mixed.xue` are copied from its `tests/fixtures/generated/` output together with their expected planes.

## License

Dual-licensed under MIT and Apache-2.0
([LICENSE-MIT](LICENSE-MIT) / [LICENSE-APACHE](LICENSE-APACHE)); use
either at your option.
