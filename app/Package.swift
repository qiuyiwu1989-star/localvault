// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalVault",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalVault", targets: ["LocalVault"])
    ],
    targets: [
        .executableTarget(
            name: "LocalVault",
            path: "Sources/LocalVault",
            linkerSettings: [
                // macOS 自带 libsqlite3 —— 不引入任何第三方依赖
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
