// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MyBar",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MyBar", targets: ["MyBar"])
  ],
  targets: [
    .target(name: "MyBarCore"),
    .executableTarget(
      name: "MyBar",
      dependencies: ["MyBarCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(name: "MyBarCoreTests", dependencies: ["MyBarCore"]),
  ]
)
