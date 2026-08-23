// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MKVSubtitleTranslator",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MKVSubtitleCore", targets: ["MKVSubtitleCore"]),
        .executable(name: "MKVSubtitleTranslator", targets: ["MKVSubtitleTranslatorApp"])
    ],
    targets: [
        .binaryTarget(
            name: "SparkleFramework",
            path: "Vendor/Frameworks/Sparkle/Sparkle.xcframework"
        ),
        .binaryTarget(
            name: "WhisperFramework",
            path: "Vendor/Frameworks/Whisper/build-apple/whisper.xcframework"
        ),
        .target(
            name: "WhisperBridge",
            dependencies: ["WhisperFramework"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "MKVSubtitleCore",
            dependencies: ["WhisperBridge"]
        ),
        .executableTarget(
            name: "MKVSubtitleTranslatorApp",
            dependencies: [
                "MKVSubtitleCore",
                "SparkleFramework"
            ]
        ),
        .testTarget(
            name: "MKVSubtitleCoreTests",
            dependencies: ["MKVSubtitleCore"]
        )
    ]
)
