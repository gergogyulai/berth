// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BerthKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BerthKit", targets: ["BerthKit"]),
    ],
    targets: [
        .target(
            name: "BerthKit",
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "BerthKitTests", dependencies: ["BerthKit"]),
    ]
)
