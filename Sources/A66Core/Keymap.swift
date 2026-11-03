import Foundation

/// 三层键位：第 0 层 = 普通层，第 1 层 = 按住 Fn 时，第 2 层 = 原驱动的 FN2 层（一般只放 Fn 键）。
/// 第 3 层本工具从不写入。
///
/// 键盘不能读回键位表，所以这里保存的是"要写进去 / 上次写进去"的配置。
public struct Keymap: Equatable, Sendable {
    public static let layerCount = 3
    /// 每层的键位表条目数（每条 4 字节），最后一条固定为校验字 00 00 5A A5
    public static let matrixEntries = 128
    public static let matrixBytes = matrixEntries * 4

    /// layers[层][K 编号] = 设备码；不在表里的键为空（00 00 00 00）
    public var layers: [[Int: KeyCode]]

    /// 空表（所有键无功能）
    public init() {
        layers = Array(repeating: [:], count: Keymap.layerCount)
    }

    /// 出厂键位：普通层 + Fn 层，FN2 层为空
    public static var factory: Keymap {
        var k = Keymap()
        for spec in A66Layout.keys {
            for l in 0..<2 where !spec.factory(layer: l).isNone {
                k.layers[l][spec.id] = spec.factory(layer: l)
            }
        }
        return k
    }

    /// 推荐的初始配置：出厂键位，但把 Fn+CapsLock 的复位挪到 Fn+Delete（见 moveResetToFnDelete）
    public static var recommended: Keymap {
        var k = factory
        k.moveResetToFnDelete()
        return k
    }

    public func code(layer: Int, key: Int) -> KeyCode {
        layers[layer][key] ?? .none
    }

    public func isFactory(layer: Int, key: Int) -> Bool {
        code(layer: layer, key: key) == (A66Layout.key(key)?.factory(layer: layer) ?? .none)
    }

    /// 改一个键。普通层的键改成 Fn 时，Fn 层和 FN2 层的同一个键也设成 Fn（原驱动的做法：
    /// 按住这个键进入 Fn 层后，它在 Fn 层里也得是 Fn）；普通层的 Fn 改成别的时，这两层恢复出厂。
    public mutating func set(_ code: KeyCode, layer: Int, key: Int) {
        precondition((0..<Keymap.layerCount).contains(layer) && A66Layout.key(key) != nil)
        let old = self.code(layer: layer, key: key)
        put(code, layer: layer, key: key)
        guard layer == 0, old != code else { return }
        if code == .fn {
            put(.fn, layer: 1, key: key)
            put(.fn, layer: 2, key: key)
        } else if old == .fn {
            for l in 1...2 { put(A66Layout.key(key)!.factory(layer: l), layer: l, key: key) }
        }
    }

    private mutating func put(_ code: KeyCode, layer: Int, key: Int) {
        layers[layer][key] = code.isNone ? nil : code
    }

    /// 恢复一个键的出厂设置（同样遵守 Fn 联动）
    public mutating func resetToFactory(layer: Int, key: Int) {
        set(A66Layout.key(key)!.factory(layer: layer), layer: layer, key: key)
    }

    // MARK: - 复位键

    /// 出厂 Fn+CapsLock = 复位键盘：按住约 5 秒会把键位清回出厂。CapsLock 改成 Ctrl 后，
    /// 任何"Ctrl + Fn 层的键"都容易先按到 Fn 而误触。这里把复位挪到 Fn+Delete（右侧，单手很难误按），
    /// Fn+CapsLock 改成与普通层的 CapsLock 位置相同的功能。
    public mutating func moveResetToFnDelete() {
        let caps = 33, delete = 31
        if code(layer: 1, key: caps) == .resetKeyboard {
            let base = code(layer: 0, key: caps)
            put(base == .fn ? .fn : base, layer: 1, key: caps)
        }
        put(.resetKeyboard, layer: 1, key: delete)
    }

    /// 复位键在哪些键上（层, K 编号）
    public var resetKeys: [(layer: Int, key: Int)] {
        (0..<Keymap.layerCount).flatMap { l in
            layers[l].filter { $0.value == .resetKeyboard }.map { (layer: l, key: $0.key) }.sorted { $0.key < $1.key }
        }
    }

    /// 普通层有没有 Fn 键。没有的话进不了 Fn 层（切换连接、灯光、复位都用不了）。
    public var hasFnKey: Bool { layers[0].values.contains(.fn) }

    // MARK: - 键位表

    /// 某一层的键位表（512 字节）：每个键的设备码按字节顺序放在 矩阵号×4 处，最后 4 字节为 00 00 5A A5。
    public func matrix(layer: Int) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: Keymap.matrixBytes)
        for (id, code) in layers[layer] {
            guard let spec = A66Layout.key(id) else { continue }
            precondition(spec.matrix >= 0 && spec.matrix < Keymap.matrixEntries - 1)
            m.replaceSubrange(spec.matrix * 4..<spec.matrix * 4 + 4, with: code.bytes)
        }
        m.replaceSubrange(Keymap.matrixBytes - 4..<Keymap.matrixBytes, with: [0x00, 0x00, 0x5A, 0xA5])
        return m
    }

    // MARK: - 从键盘读回

    /// 读回的键位表里，不在 A66 键位排列上却有内容的位置（本工具不认识，读入时忽略）
    public struct UnknownEntry: Hashable, Sendable {
        public let layer: Int
        public let index: Int
        public let code: KeyCode
    }

    /// 用读回的各层键位表组成配置。每层至少要覆盖到 A66 用到的最大矩阵号（无线读回 504 字节、有线 512 字节）；
    /// 最后一项（校验位 00 00 5A A5）不算键。
    public static func fromMatrices(_ ms: [[UInt8]]) -> (keymap: Keymap, unknown: [UnknownEntry]) {
        precondition(ms.count == layerCount)
        let known = Dictionary(uniqueKeysWithValues: A66Layout.keys.map { ($0.matrix, $0.id) })
        var k = Keymap()
        var unknown: [UnknownEntry] = []
        for (l, m) in ms.enumerated() {
            precondition(m.count >= minimumReadBytes)
            for i in 0..<min(m.count / 4, matrixEntries - 1) {
                let code = KeyCode(bytes: Array(m[i * 4..<i * 4 + 4]))
                if code.isNone { continue }
                if let id = known[i] { k.layers[l][id] = code } else { unknown.append(UnknownEntry(layer: l, index: i, code: code)) }
            }
        }
        return (k, unknown)
    }

    /// 读回的数据至少要这么长才覆盖 A66 的所有键
    public static var minimumReadBytes: Int { (A66Layout.keys.map(\.matrix).max()! + 1) * 4 }

    /// 读回的一层（可能比 512 字节短）和这份配置的这一层是否一致
    public func matches(_ readBack: [UInt8], layer: Int) -> Bool {
        let m = matrix(layer: layer)
        return readBack.count >= Keymap.minimumReadBytes && readBack.count <= m.count && Array(m.prefix(readBack.count)) == readBack
    }

    // MARK: - 比较

    public struct Change: Hashable, Sendable {
        public let layer: Int
        public let key: Int
        public let from: KeyCode
        public let to: KeyCode
    }

    /// 相对 other 改了哪些键（按层、K 编号排序）
    public func changes(from other: Keymap) -> [Change] {
        var out: [Change] = []
        for l in 0..<Keymap.layerCount {
            for id in Set(layers[l].keys).union(other.layers[l].keys).sorted() {
                let a = other.code(layer: l, key: id), b = code(layer: l, key: id)
                if a != b { out.append(Change(layer: l, key: id, from: a, to: b)) }
            }
        }
        return out
    }

    /// 哪些层和 other 不同
    public func changedLayers(from other: Keymap) -> [Int] {
        (0..<Keymap.layerCount).filter { matrix(layer: $0) != other.matrix(layer: $0) }
    }

    /// 把指定层换成 other 的（用来记录"写入后键盘里是什么"）
    public func replacing(layers ls: [Int], from other: Keymap) -> Keymap {
        var k = self
        for l in ls { k.layers[l] = other.layers[l] }
        return k
    }
}

// MARK: - 文件格式

/// ```json
/// { "format": "a66-keymap", "version": 1,
///   "layers": [ { "K1": "00000029", ... }, { ... }, { ... } ] }
/// ```
/// 设备码是 8 位十六进制、按字节顺序书写；没列出的键为空。
extension Keymap: Codable {
    enum CodingKeys: String, CodingKey { case format, version, layers }

    public enum FormatError: Error, CustomStringConvertible {
        case notKeymap, badVersion(Int), badEntry(String)
        public var description: String {
            switch self {
            case .notKeymap: return L("不是 A66 键位文件", "not an A66 keymap file")
            case let .badVersion(v): return L("不支持的版本 \(v)", "unsupported version \(v)")
            case let .badEntry(s): return L("看不懂的条目：\(s)", "invalid entry: \(s)")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == "a66-keymap" else { throw FormatError.notKeymap }
        let v = try c.decode(Int.self, forKey: .version)
        guard v == 1 else { throw FormatError.badVersion(v) }
        let raw = try c.decode([[String: String]].self, forKey: .layers)
        self.init()
        for (l, dict) in raw.prefix(Keymap.layerCount).enumerated() {
            for (k, h) in dict {
                guard k.hasPrefix("K"), let id = Int(k.dropFirst()), A66Layout.key(id) != nil,
                      let code = KeyCode(hex: h) else { throw FormatError.badEntry("\(k)=\(h)") }
                if !code.isNone { layers[l][id] = code }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("a66-keymap", forKey: .format)
        try c.encode(1, forKey: .version)
        try c.encode(layers.map { l in Dictionary(uniqueKeysWithValues: l.map { ("K\($0.key)", $0.value.hex) }) }, forKey: .layers)
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Keymap.self, from: jsonData)
    }
}

/// 命令行的保存位置：~/Library/Application Support/A66 Keymap/（目录名沿用以前的 app，已有配置不用搬）
public enum KeymapStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("A66 Keymap", isDirectory: true)
    }
    /// 正在编辑的配置
    public static var keymapURL: URL { directory.appendingPathComponent("keymap.json") }
    /// 上次成功写进键盘的配置
    public static var lastWrittenURL: URL { directory.appendingPathComponent("last-written.json") }

    public static func load(_ url: URL) -> Keymap? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? Keymap(jsonData: d)
    }

    public static func save(_ k: Keymap, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try k.jsonData().write(to: url, options: .atomic)
    }
}
