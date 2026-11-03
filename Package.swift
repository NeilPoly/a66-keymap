// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "a66-keymap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "a66", targets: ["a66"]),
    ],
    targets: [
        // 纯逻辑：键位数据、设备码、配置文件、报文组包。不碰设备。
        .target(name: "A66Core"),
        // IOKit HID 访问与键盘通信（找通道、核对型号、写键位）。
        .target(name: "A66HID", dependencies: ["A66Core"], linkerSettings: [.linkedFramework("IOKit")]),
        // 命令行（主要给开发排障用；面向用户的是 web/ 里的网页版）
        .executableTarget(name: "a66", dependencies: ["A66Core", "A66HID"]),
        .testTarget(name: "A66CoreTests", dependencies: ["A66Core"]),
    ]
)
