// swift-tools-version: 6.2
import PackageDescription

// Recast: drag-and-drop batch audio converter (WAV, AIFF, CAF, FLAC, Apple Lossless, MP3, AAC, Ogg Vorbis, Opus).
let package = Package(
    name: "Recast",
    platforms: [.macOS(.v26)],
    targets: [
        // LAME 3.100 MP3 encoder (LGPL), vendored unmodified.
        .target(
            name: "CLame",
            path: "Sources/CLame",
            exclude: ["COPYING", "LICENSE", "README", "OMSO_PROVENANCE.md", "config"],
            sources: ["libmp3lame"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("config"),
                .headerSearchPath("libmp3lame"),
                .unsafeFlags(["-w"]),
            ]
        ),
        // libogg + libvorbis 1.3.7 (BSD), as bundled with JUCE.
        .target(
            name: "COggVorbis",
            path: "Sources/COggVorbis",
            sources: ["oggvorbis_unity.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("JUCE_CDECL", to: ""),
                // Upstream headers rely on <sys/types.h> providing uint64_t, which Clang modules hide.
                .unsafeFlags(["-w", "-include", "stdint.h"]),
            ]
        ),
        .target(
            name: "RecastCore",
            dependencies: ["CLame", "COggVorbis"],
            path: "Sources/RecastCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Recast",
            dependencies: ["RecastCore"],
            path: "Sources/Recast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RecastCoreTests",
            dependencies: ["RecastCore"],
            path: "Tests/RecastCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
