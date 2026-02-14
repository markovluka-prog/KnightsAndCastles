// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KnightsAndCastlesLoader",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .iOSApplication(
            name: "KnightsAndCastlesLoader",
            targets: ["AppModule"],
            bundleIdentifier: "com.markovluka.knightsandcastlesloader",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .gameController),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.phone, .pad, .mac],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeLeft,
                .landscapeRight
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources",
            resources: [
                .copy("Web")
            ]
        )
    ]
)
