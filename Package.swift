// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Syncophant",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CoreKit", targets: ["CoreKit"]),
        .library(name: "HetznerKit", targets: ["HetznerKit"]),
        .executable(name: "Syncophant", targets: ["SyncophantApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2.git", exact: "4.0.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .systemLibrary(name: "CLibSSH2", pkgConfig: "libssh2", providers: [.brew(["libssh2"])]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CoreKit", dependencies: ["CLibSSH2", "CSQLite", .product(name: "AMSMB2", package: "AMSMB2")], exclude: ["README.md", "LICENSE"]),
        .target(name: "HetznerKit", exclude: ["LICENSE"]),
        .executableTarget(name: "SyncophantApp", dependencies: ["CoreKit", "HetznerKit", .product(name: "Sparkle", package: "Sparkle")], path: "Sources", exclude: ["CoreKit", "HetznerKit", "CLibSSH2", "CSQLite", "FileProviderExtension", "AgentRendezvous"], sources: ["SyncophantApp", "PlatformShared"]),
        .testTarget(name: "CoreKitTests", dependencies: ["CoreKit"]),
        .testTarget(name: "HetznerKitTests", dependencies: ["HetznerKit"]),
    ]
)
