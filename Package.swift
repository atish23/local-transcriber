// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalTranscriber",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "LocalTranscriber",
            targets: ["LocalTranscriber"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LocalTranscriber",
            dependencies: [],
            path: "Sources/LocalTranscriber",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/LocalTranscriber/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "LocalTranscriberTests",
            dependencies: ["LocalTranscriber"],
            path: "Tests/LocalTranscriberTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
