// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_meta_wearables_dat",
    platforms: [.iOS("17.2")],
    products: [
        .library(name: "flutter-meta-wearables-dat", targets: ["flutter_meta_wearables_dat"]),
        .library(name: "MWDATCore", targets: ["MWDATCore"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "MWDATCore",
            path: "Frameworks/MWDATCore.xcframework"
        ),
        .binaryTarget(
            name: "MWDATCamera",
            path: "Frameworks/MWDATCamera.xcframework"
        ),
        // CONCETTO FORK (capture session): Meta's 1.0.1 Display and Inputs.
        .binaryTarget(
            name: "MWDATDisplay",
            path: "Frameworks/MWDATDisplay.xcframework"
        ),
        .binaryTarget(
            name: "MWDATInputs",
            path: "Frameworks/MWDATInputs.xcframework"
        ),
        .target(
            name: "flutter_meta_wearables_dat",
            dependencies: [
                "MWDATCore",
                "MWDATCamera",
                "MWDATDisplay",
                "MWDATInputs",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Network"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
