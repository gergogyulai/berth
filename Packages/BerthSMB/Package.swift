// swift-tools-version: 6.2
import PackageDescription

// BerthSMB is a self-contained SMB 2/3 client. On Apple platforms it only needs CryptoKit and
// CommonCrypto from the SDK. On Linux (handy for running the integration tests against a local
// Samba) it pulls in swift-crypto for the CryptoKit API.
var packageDependencies: [Package.Dependency] = []
var cryptoDependencies: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
cryptoDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "BerthSMB",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BerthSMB", targets: ["BerthSMB"]),
        .executable(name: "berth-smb", targets: ["berth-smb"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "BerthSMB", dependencies: cryptoDependencies),
        .executableTarget(name: "berth-smb", dependencies: ["BerthSMB"]),
        .testTarget(name: "BerthSMBTests", dependencies: ["BerthSMB"]),
    ]
)
