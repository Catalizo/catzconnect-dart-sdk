// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "catzconnect",
    platforms: [
        // The package builds for iOS 13 so apps that only use server keys keep
        // their deployment target; App Attest itself needs iOS 14 and is
        // checked at run time.
        .iOS("13.0")
    ],
    products: [
        .library(name: "catzconnect", targets: ["catzconnect"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "catzconnect",
            dependencies: [],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("DeviceCheck")
            ]
        )
    ]
)
