// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContainerDesk",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ContainerDeskCore", targets: ["ContainerDeskCore"]),
        .executable(name: "ContainerDesk", targets: ["ContainerDeskApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.5.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.47.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1"),
    ],
    targets: [
        .target(
            name: "ContainerDeskCore",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerRuntimeClient", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerXPC", package: "container"),
            ]
        ),
        .executableTarget(
            name: "ContainerDeskApp",
            dependencies: ["ContainerDeskCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ContainerDeskCoreTests", dependencies: ["ContainerDeskCore"]),
        .testTarget(name: "ContainerDeskAppTests", dependencies: ["ContainerDeskApp", "ContainerDeskCore"]),
    ]
)
