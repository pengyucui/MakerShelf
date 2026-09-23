// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "libwebp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "libwebp", targets: ["libwebp"])
    ],
    targets: [
        .target(
            name: "libwebp",
            path: ".",
            exclude: ["COPYING"],
            sources: ["src", "sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("_THREAD_SAFE")
            ]
        )
    ]
)
