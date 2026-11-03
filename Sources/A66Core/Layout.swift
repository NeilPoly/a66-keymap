/// 键盘上的一个键。编号 K1…K67 与原厂驱动一致（也是导入 Windows 配置时的记录顺序）。
public struct KeySpec: Identifiable, Hashable, Sendable {
    /// K 编号，从 1 起
    public let id: Int
    /// 键帽上的字
    public let legend: String
    /// 在键位表里的位置（0…126；127 是校验位）
    public let matrix: Int
    /// 排列位置与宽度，单位 = 一个标准键宽；行高都是 1
    public let x: Double
    public let y: Int
    public let w: Double
    public let factoryBase: KeyCode
    public let factoryFn: KeyCode

    /// 右上角的旋钮（按下算一个键）
    public var isKnob: Bool { id == 67 }

    public func factory(layer: Int) -> KeyCode {
        switch layer {
        case 0: return factoryBase
        case 1: return factoryFn
        default: return .none
        }
    }
}

extension A66Layout {
    public static func key(_ id: Int) -> KeySpec? {
        guard id >= 1, id <= keys.count else { return nil }
        return keys[id - 1]
    }

    /// 键盘总宽（单位）
    public static let width: Double = 16
    public static let rows = 5
}

// A66 的 67 个键：矩阵位置、键盘排列（单位 = 一个标准键宽）、出厂普通层与 Fn 层设备码。
// 由实机键位与原厂出厂配置整理而来；设备码写法见 KeyCode。改动前先跑测试。

public enum A66Layout {
    public static let keys: [KeySpec] = [
        KeySpec(id: 1, legend: "Esc", matrix: 1, x: 0.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0029), factoryFn: KeyCode(0x0000_0035)),
        KeySpec(id: 2, legend: "1", matrix: 7, x: 1.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_001E), factoryFn: KeyCode(0x0000_003A)),
        KeySpec(id: 3, legend: "2", matrix: 13, x: 2.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_001F), factoryFn: KeyCode(0x0000_003B)),
        KeySpec(id: 4, legend: "3", matrix: 19, x: 3.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0020), factoryFn: KeyCode(0x0000_003C)),
        KeySpec(id: 5, legend: "4", matrix: 25, x: 4.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0021), factoryFn: KeyCode(0x0000_003D)),
        KeySpec(id: 6, legend: "5", matrix: 31, x: 5.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0022), factoryFn: KeyCode(0x0000_003E)),
        KeySpec(id: 7, legend: "6", matrix: 37, x: 6.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0023), factoryFn: KeyCode(0x0000_003F)),
        KeySpec(id: 8, legend: "7", matrix: 43, x: 7.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0024), factoryFn: KeyCode(0x0000_0040)),
        KeySpec(id: 9, legend: "8", matrix: 49, x: 8.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0025), factoryFn: KeyCode(0x0000_0041)),
        KeySpec(id: 10, legend: "9", matrix: 55, x: 9.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0026), factoryFn: KeyCode(0x0000_0042)),
        KeySpec(id: 11, legend: "0", matrix: 61, x: 10.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_0027), factoryFn: KeyCode(0x0000_0043)),
        KeySpec(id: 12, legend: "-", matrix: 67, x: 11.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_002D), factoryFn: KeyCode(0x0000_0044)),
        KeySpec(id: 13, legend: "=", matrix: 73, x: 12.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0000_002E), factoryFn: KeyCode(0x0000_0045)),
        KeySpec(id: 14, legend: "Backspace", matrix: 79, x: 13.0, y: 0, w: 2.0, factoryBase: KeyCode(0x0000_002A), factoryFn: KeyCode(0x0700_000B)),
        KeySpec(id: 15, legend: "→", matrix: 95, x: 15.0, y: 4, w: 1.0, factoryBase: KeyCode(0x0000_004F), factoryFn: KeyCode(0x0804_0100)),
        KeySpec(id: 16, legend: "PgUp", matrix: 93, x: 15.0, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_004B), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 17, legend: "Tab", matrix: 2, x: 0.0, y: 1, w: 1.5, factoryBase: KeyCode(0x0000_002B), factoryFn: KeyCode(0x0700_0012)),
        KeySpec(id: 18, legend: "Q", matrix: 8, x: 1.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0014), factoryFn: KeyCode(0x0700_0005)),
        KeySpec(id: 19, legend: "W", matrix: 14, x: 2.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_001A), factoryFn: KeyCode(0x0700_0006)),
        KeySpec(id: 20, legend: "E", matrix: 20, x: 3.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0008), factoryFn: KeyCode(0x0700_0007)),
        KeySpec(id: 21, legend: "R", matrix: 26, x: 4.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0015), factoryFn: KeyCode(0x0700_0008)),
        KeySpec(id: 22, legend: "T", matrix: 32, x: 5.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0017), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 23, legend: "Y", matrix: 38, x: 6.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_001C), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 24, legend: "U", matrix: 44, x: 7.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0018), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 25, legend: "I", matrix: 50, x: 8.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_000C), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 26, legend: "O", matrix: 56, x: 9.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0012), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 27, legend: "P", matrix: 62, x: 10.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0013), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 28, legend: "[", matrix: 68, x: 11.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_002F), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 29, legend: "]", matrix: 74, x: 12.5, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_0030), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 30, legend: "\\", matrix: 80, x: 13.5, y: 1, w: 1.5, factoryBase: KeyCode(0x0000_0031), factoryFn: KeyCode(0x0800_0000)),
        KeySpec(id: 31, legend: "Del", matrix: 92, x: 15.0, y: 1, w: 1.0, factoryBase: KeyCode(0x0000_004C), factoryFn: KeyCode(0x0802_0000)),
        KeySpec(id: 32, legend: "PgDn", matrix: 94, x: 15.0, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_004E), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 33, legend: "Caps", matrix: 3, x: 0.0, y: 2, w: 1.75, factoryBase: KeyCode(0x0000_0039), factoryFn: KeyCode(0x0700_0004)),
        KeySpec(id: 34, legend: "A", matrix: 9, x: 1.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_0004), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 35, legend: "S", matrix: 15, x: 2.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_0016), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 36, legend: "D", matrix: 21, x: 3.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_0007), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 37, legend: "F", matrix: 27, x: 4.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_0009), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 38, legend: "G", matrix: 33, x: 5.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_000A), factoryFn: KeyCode(0x0700_000A)),
        KeySpec(id: 39, legend: "H", matrix: 39, x: 6.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_000B), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 40, legend: "J", matrix: 45, x: 7.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_000D), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 41, legend: "K", matrix: 51, x: 8.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_000E), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 42, legend: "L", matrix: 57, x: 9.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_000F), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 43, legend: ";", matrix: 63, x: 10.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_0033), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 44, legend: "'", matrix: 69, x: 11.75, y: 2, w: 1.0, factoryBase: KeyCode(0x0000_0034), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 45, legend: "Enter", matrix: 81, x: 12.75, y: 2, w: 2.25, factoryBase: KeyCode(0x0000_0028), factoryFn: KeyCode(0x0802_0000)),
        KeySpec(id: 46, legend: "Shift", matrix: 4, x: 0.0, y: 3, w: 2.25, factoryBase: KeyCode(0x0002_0000), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 47, legend: "Z", matrix: 10, x: 2.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_001D), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 48, legend: "X", matrix: 16, x: 3.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_001B), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 49, legend: "C", matrix: 22, x: 4.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0006), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 50, legend: "V", matrix: 28, x: 5.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0019), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 51, legend: "B", matrix: 34, x: 6.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0005), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 52, legend: "N", matrix: 40, x: 7.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0011), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 53, legend: "M", matrix: 46, x: 8.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0010), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 54, legend: ",", matrix: 52, x: 9.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0036), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 55, legend: ".", matrix: 58, x: 10.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0037), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 56, legend: "/", matrix: 64, x: 11.25, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0038), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 57, legend: "Shift", matrix: 82, x: 12.25, y: 3, w: 1.75, factoryBase: KeyCode(0x0020_0000), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 58, legend: "↑", matrix: 88, x: 14.0, y: 3, w: 1.0, factoryBase: KeyCode(0x0000_0052), factoryFn: KeyCode(0x0803_0100)),
        KeySpec(id: 59, legend: "Ctrl", matrix: 5, x: 0.0, y: 4, w: 1.25, factoryBase: KeyCode(0x0001_0000), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 60, legend: "Win", matrix: 11, x: 1.25, y: 4, w: 1.25, factoryBase: KeyCode(0x0008_0000), factoryFn: KeyCode(0x0700_0001)),
        KeySpec(id: 61, legend: "Alt", matrix: 17, x: 2.5, y: 4, w: 1.25, factoryBase: KeyCode(0x0004_0000), factoryFn: KeyCode(0x0000_0000)),
        KeySpec(id: 62, legend: "Space", matrix: 35, x: 3.75, y: 4, w: 6.25, factoryBase: KeyCode(0x0000_002C), factoryFn: KeyCode(0x0800_0001)),
        KeySpec(id: 63, legend: "Alt", matrix: 53, x: 10.0, y: 4, w: 1.25, factoryBase: KeyCode(0x0040_0000), factoryFn: KeyCode(0x0700_0011)),
        KeySpec(id: 64, legend: "Fn", matrix: 59, x: 11.25, y: 4, w: 1.25, factoryBase: KeyCode(0x0D00_0000), factoryFn: KeyCode(0x0D00_0000)),
        KeySpec(id: 65, legend: "←", matrix: 83, x: 13.0, y: 4, w: 1.0, factoryBase: KeyCode(0x0000_0050), factoryFn: KeyCode(0x0804_0200)),
        KeySpec(id: 66, legend: "↓", matrix: 89, x: 14.0, y: 4, w: 1.0, factoryBase: KeyCode(0x0000_0051), factoryFn: KeyCode(0x0803_0200)),
        KeySpec(id: 67, legend: "Knob", matrix: 91, x: 15.0, y: 0, w: 1.0, factoryBase: KeyCode(0x0700_0014), factoryFn: KeyCode(0x0000_0000)),
    ]
}
