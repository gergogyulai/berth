// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BerthKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BerthKit", targets: ["BerthKit"]),
    ],
    dependencies: [
        .package(path: "../BerthSMB"),
    ],
    targets: [
        .target(
            name: "BerthKit",
            dependencies: [
                .product(name: "BerthSMB", package: "BerthSMB"),
            ],
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("FileProvider"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(name: "BerthKitTests", dependencies: ["BerthKit"]),
    ]
)
