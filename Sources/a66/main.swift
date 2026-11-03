import A66Core
import A66HID
import Foundation

// A66 键盘命令行工具。list / identify / read / show / build / init / import-windows 不改变键盘；
// apply 写键位表，默认只演习，加 --yes 才发送，写完读回核对。

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((L("错误：", "Error: ") + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print(L("""
    用法：
      a66 list                         列出相关 HID 设备（只枚举，不打开）
      a66 identify [通道]               读键盘"密码"核对型号（只读）
      a66 read [通道] [--save | -o F]   读出键盘里现在的键位（只读），显示与本机配置的差别；
                                       --save 存为本机配置（也记为"上次写入"），-o 另存到文件
      a66 show [--keymap F] [--all]     显示配置（默认只列与出厂不同的键）
      a66 apply [--keymap F] [--all | --layers 0,1,2] [--set 层:K编号=键 ...] [--factory K编号 ...] [通道] [--yes]
                                       把配置写进键盘；默认只写与上次写入不同的层，--all 全部重写
                                       不加 --yes 只演习、不发送；写完自动读回核对
      a66 init [-o F] [--factory] [--force]
                                       新建配置：出厂键位 + 复位挪到 Fn+Del（--factory 则完全出厂）
      a66 import-windows profile.dct [--overrides F] [-o F] [--force]
                                       导入原厂 Windows 驱动的配置
      a66 build [--keymap F] [--out DIR] 离线生成有线报文文件，不碰键盘

    通道：默认自动（有线 > 蓝牙 > 2.4G 取第一个）；--wired 有线、--bt 蓝牙、--24g 2.4G 接收器 强制指定
    配置默认在 \(KeymapStore.keymapURL.path)
    键的写法：A、F5、Home、Left、LCtrl、RCmd、LCmd+Left、Fn、none、raw:07000004
    """, """
    Usage:
      a66 list                         list related HID devices (enumerate only)
      a66 identify [channel]           read the keyboard ID (read-only)
      a66 read [channel] [--save | -o F]
                                       read the keymap stored in the keyboard (read-only) and compare it with
                                       the local keymap; --save adopts it locally, -o saves it to a file
      a66 show [--keymap F] [--all]    show the keymap (keys that differ from factory, or --all)
      a66 apply [--keymap F] [--all | --layers 0,1,2] [--set L:Kn=KEY ...] [--factory Kn ...] [channel] [--yes]
                                       write layers that changed since the last write (--all: every layer)
                                       without --yes it is a dry run; verified by reading back
      a66 init [-o F] [--factory] [--force]
                                       create a keymap: factory + reset moved to Fn+Del (--factory: pure factory)
      a66 import-windows profile.dct [--overrides F] [-o F] [--force]
                                       import the vendor Windows driver profile
      a66 build [--keymap F] [--out DIR] write wired packet files offline

    channel: automatic (wired > Bluetooth > 2.4 GHz); --wired, --bt, --24g force one
    default keymap: \(KeymapStore.keymapURL.path)
    keys: A, F5, Home, Left, LCtrl, RCmd, LCmd+Left, Fn, none, raw:07000004
    """))
    exit(2)
}

func pad(_ s: String, _ n: Int) -> String {
    let w = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) }
    return w >= n ? s : s + String(repeating: " ", count: n - w)
}

func layerTitle(_ l: Int) -> String {
    [L("普通层", "Base layer"), L("Fn 层", "Fn layer"), L("FN2 层", "FN2 layer")][l]
}

/// 简单的参数读取
struct Args {
    var items: [String]
    mutating func flag(_ names: String...) -> Bool {
        guard let i = items.firstIndex(where: { names.contains($0) }) else { return false }
        items.remove(at: i)
        return true
    }
    mutating func values(_ name: String) -> [String] {
        var out: [String] = []
        while let i = items.firstIndex(of: name) {
            guard i + 1 < items.count else { usage() }
            out.append(items[i + 1])
            items.removeSubrange(i...i + 1)
        }
        return out
    }
    mutating func value(_ names: String...) -> String? {
        for n in names { if let v = values(n).last { return v } }
        return nil
    }
    mutating func positional() -> String? {
        guard let i = items.firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
        return items.remove(at: i)
    }
    func done() { if !items.isEmpty { usage() } }
}

// MARK: - 通道

/// 要用的通道：默认按 有线 > 蓝牙 > 2.4G 取第一个（见 A66Device.preferred）；--wired / --bt / --24g 强制指定。
func pickChannel(_ a: inout Args) -> ConfigChannel {
    var want: Connection?
    if a.flag("--wired") { want = .wired }
    if a.flag("--bt", "--bluetooth") { want = .bluetooth }
    if a.flag("--24g", "--receiver") { want = .receiver }
    let all = A66Device.channels()
    let cands = want.map { w in all.filter { $0.connection == w } } ?? all
    guard let c = A66Device.preferred(cands) else {
        if all.isEmpty {
            fail(L("没找到键盘。插线（拨到有线，经转换器）、连上蓝牙或插好 2.4G 接收器后再试；a66 list 可以看看系统里有什么。",
                   "No keyboard found. Connect by cable (wired mode), Bluetooth or the 2.4 GHz receiver; try a66 list."))
        }
        fail(L("没找到\(want!.title)通道，现在连着的是：", "No \(want!.title) channel; connected: ")
             + all.map { $0.connection.title }.joined(separator: "、"))
    }
    print(L("通道：", "Channel: ") + c.connection.title
          + (all.count > 1 && want == nil ? L("（检测到 ", " (detected ") + all.map { $0.connection.title }.joined(separator: "、") + L("，按 有线 > 蓝牙 > 2.4G 选）", "; priority wired > Bluetooth > 2.4 GHz)") : ""))
    return c
}

// MARK: - list

func cmdList(_ a: Args) {
    a.done()
    let devs = HID.enumerate(vendorIDs: [A66.wiredVID, A66.wirelessVID])
    if devs.isEmpty { print(L("没找到 VID 0x258A / 0x3554 的设备。", "No devices with VID 0x258A / 0x3554.")); return }
    let chans = A66Device.channels()
    for d in devs {
        let pairs = d.usagePairs.map { String(format: "%04X:%X", $0.page, $0.usage) }.joined(separator: " ")
        print(String(format: "%04X:%04X  %@ %@ loc=0x%08X  in/out/feature=%d/%d/%d",
                     d.vendorID, d.productID, pad(d.transport, 22) as NSString, pad("\"\(d.product)\"", 24) as NSString,
                     d.locationID, d.maxInput, d.maxOutput, d.maxFeature))
        print(L("           用途：", "           usages: ") + pairs)
        if let c = chans.first(where: { $0.info.device === d.device }) {
            print(L("           ↑ 配置通道（\(c.connection.title)）", "           ↑ config channel (\(c.connection.title))"))
        }
    }
}

// MARK: - identify

func cmdIdentify(_ a: Args) {
    var a = a
    let ch = pickChannel(&a)
    a.done()
    let psd: [UInt8]
    do {
        let (link, p) = try A66Device.connect(ch) { print($0) }
        link.close()
        psd = p
    } catch { fail("\(error)") }
    print(L("密码：", "ID: ") + hex(psd))
    if psd == A66.password {
        print(L("✓ 是 A66（型号字节 0xD9）。", "✓ This is an A66 (model byte 0xD9)."))
    } else {
        print(L("✗ 与 A66 的 \(hex(A66.password)) 不一致，不要往这把键盘写任何东西。",
                "✗ Does not match the A66's \(hex(A66.password)); do not write anything to this keyboard."))
        exit(3)
    }
}

// MARK: - read

func cmdRead(_ a: Args) {
    var a = a
    let save = a.flag("--save")
    let out = a.value("-o", "--out")
    let ch = pickChannel(&a)
    a.done()
    if save && out != nil { usage() }
    let read: (keymap: Keymap, unknown: [Keymap.UnknownEntry])
    do { read = try A66Device.readKeymap(from: ch, log: { print($0) }) } catch { fail("\(error)") }
    let k = read.keymap
    printKeymap(k, layers: [0, 1, 2], all: false)
    for u in read.unknown {
        print(L("注意：\(layerTitle(u.layer)) 矩阵 \(u.index) 有内容 \(u.code.spacedHex)，不在 A66 的键位排列上，已忽略。",
                "Note: \(layerTitle(u.layer)) matrix \(u.index) holds \(u.code.spacedHex), which is not an A66 key position; ignored."))
    }
    if let local = KeymapStore.load(KeymapStore.keymapURL) {
        let diff = local.changes(from: k)
        if diff.isEmpty {
            print(L("\n与本机配置一致。", "\nMatches the local keymap."))
        } else {
            print(L("\n本机配置与键盘里不同的键（键盘 → 本机）：", "\nLocal keymap differs from the keyboard (keyboard → local):"))
            for c in diff {
                print("  \(layerTitle(c.layer)) K\(c.key) \(A66Layout.key(c.key)!.legend)：\(c.from.name) → \(c.to.name)")
            }
        }
    }
    if save {
        do {
            try KeymapStore.save(k, to: KeymapStore.keymapURL)
            try KeymapStore.save(k, to: KeymapStore.lastWrittenURL)
        } catch { fail("\(error)") }
        print(L("已存为本机配置：", "Saved as the local keymap: ") + KeymapStore.keymapURL.path)
    } else if let out {
        do { try KeymapStore.save(k, to: URL(fileURLWithPath: out)) } catch { fail("\(error)") }
        print(L("已保存：", "Saved: ") + out)
    } else {
        print(L("（只读出来看，没有保存；加 --save 存为本机配置）", "(not saved; add --save to adopt it locally)"))
    }
}

// MARK: - 配置读取与显示

func loadKeymap(_ path: String?) -> Keymap {
    let url = path.map { URL(fileURLWithPath: $0) } ?? KeymapStore.keymapURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail(L("配置文件不存在：\(url.path)\n先跑 a66 read --save（从键盘读出）、a66 init 或 a66 import-windows 生成。",
               "Keymap not found: \(url.path)\nCreate one with a66 read --save (from the keyboard), a66 init or a66 import-windows."))
    }
    do { return try Keymap(jsonData: Data(contentsOf: url)) } catch { fail("\(url.path)：\(error)") }
}

/// "L:Kn=写法"，例如 "1:K33=LCtrl"
func applySet(_ line: String, source: String, to k: inout Keymap) {
    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    let lk = parts.first?.split(separator: ":").map(String.init) ?? []
    guard parts.count == 2, lk.count == 2, let l = Int(lk[0]), (0..<Keymap.layerCount).contains(l),
          let n = Int(lk[1].hasPrefix("K") ? String(lk[1].dropFirst()) : lk[1]), let spec = A66Layout.key(n) else {
        fail(L("\(source)：看不懂「\(line)」，格式是 层:K编号=键，如 1:K33=LCtrl",
               "\(source): cannot parse “\(line)”; expected L:Kn=KEY, e.g. 1:K33=LCtrl"))
    }
    guard let code = KeyCatalog.code(forSpec: parts[1]) else {
        fail(L("\(source)：不认识的键「\(parts[1])」", "\(source): unknown key “\(parts[1])”"))
    }
    let old = k.code(layer: l, key: n)
    k.set(code, layer: l, key: n)
    print(L("改写（\(source)）：", "Set (\(source)): ") + "\(layerTitle(l)) K\(n) \(spec.legend)：\(old.name) → \(code.name)")
}

func printKeymap(_ k: Keymap, layers: [Int], all: Bool) {
    for l in layers {
        let ids = A66Layout.keys.map(\.id).filter { all ? !k.code(layer: l, key: $0).isNone : !k.isFactory(layer: l, key: $0) }
        let count = k.layers[l].count
        print("\n== \(layerTitle(l))" + L("：\(count) 个非空键", ": \(count) keys set")
              + (all ? "" : L("，与出厂不同 \(ids.count) 个", ", \(ids.count) differ from factory")))
        for id in ids {
            let spec = A66Layout.key(id)!
            let c = k.code(layer: l, key: id)
            let f = spec.factory(layer: l)
            let mark = c != f ? L("   ← 出厂是 ", "   ← factory: ") + f.name : ""
            print("  " + pad("K\(id)", 5) + pad(spec.legend, 10) + L("矩阵", "matrix") + String(format: "%3d  ", spec.matrix)
                  + c.spacedHex + "  " + c.name + mark)
        }
    }
    for r in k.resetKeys {
        print(L("\n注意：\(layerTitle(r.layer)) K\(r.key)（\(A66Layout.key(r.key)!.legend)）是复位键，长按约 5 秒会清回出厂键位。",
                "\nNote: \(layerTitle(r.layer)) K\(r.key) (\(A66Layout.key(r.key)!.legend)) is the reset key; holding it ~5 s restores the factory keymap."))
    }
    if !k.hasFnKey {
        print(L("\n注意：普通层没有 Fn 键，写入后将进不了 Fn 层。", "\nNote: no Fn key on the base layer; the Fn layer will be unreachable."))
    }
}

func cmdShow(_ a: Args) {
    var a = a
    let path = a.value("--keymap")
    let all = a.flag("--all")
    a.done()
    printKeymap(loadKeymap(path), layers: [0, 1, 2], all: all)
}

// MARK: - init / import-windows

func writeNew(_ k: Keymap, to path: String?, force: Bool) {
    let url = path.map { URL(fileURLWithPath: $0) } ?? KeymapStore.keymapURL
    if FileManager.default.fileExists(atPath: url.path) && !force {
        fail(L("\(url.path) 已存在，覆盖请加 --force", "\(url.path) exists; add --force to overwrite"))
    }
    do { try KeymapStore.save(k, to: url) } catch { fail("\(error)") }
    print(L("已保存：", "Saved: ") + url.path)
}

func cmdInit(_ a: Args) {
    var a = a
    let out = a.value("-o", "--out")
    let factory = a.flag("--factory")
    let force = a.flag("--force")
    a.done()
    writeNew(factory ? .factory : .recommended, to: out, force: force)
}

func cmdImportWindows(_ a: Args) {
    var a = a
    let overrides = a.value("--overrides")
    let out = a.value("-o", "--out")
    let force = a.flag("--force")
    guard let src = a.positional() else { usage() }
    a.done()
    var k: Keymap
    do { k = try Keymap(windowsProfile: Data(contentsOf: URL(fileURLWithPath: src))) } catch { fail("\(src)：\(error)") }
    if let overrides {
        let text: String
        do { text = try String(contentsOfFile: overrides, encoding: .utf8) } catch { fail("\(overrides)：\(error)") }
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { applySet(line, source: "\(overrides):\(i + 1)", to: &k) }
        }
    }
    printKeymap(k, layers: [0, 1, 2], all: false)
    writeNew(k, to: out, force: force)
}

// MARK: - build

func cmdBuild(_ a: Args) {
    var a = a
    let path = a.value("--keymap")
    let outDir = a.value("--out") ?? "build/matrix"
    a.done()
    let k = loadKeymap(path)
    let out = URL(fileURLWithPath: outDir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for l in 0..<Keymap.layerCount {
        let pkts = WiredPacket.packets(.setMatrix, sub: UInt8(l), data: k.matrix(layer: l))
        let f = out.appendingPathComponent("layer\(l).bin")
        do { try Data(pkts.reduce([], +)).write(to: f) } catch { fail("\(f.path)：\(error)") }
        print("\(layerTitle(l))：\(hex(pkts[0].prefix(8))) … → \(f.path)")
    }
    print(L("只生成了文件，没有访问键盘。", "Files only; the keyboard was not touched."))
}

// MARK: - apply

func cmdApply(_ a: Args) {
    var a = a
    let path = a.value("--keymap")
    let sets = a.values("--set")
    let factoryKeys = a.values("--factory")
    let layersArg = a.value("--layers")
    let all = a.flag("--all")
    let yes = a.flag("--yes")
    var k = loadKeymap(path)
    for f in factoryKeys {
        guard let n = Int(f.hasPrefix("K") ? String(f.dropFirst()) : f), let spec = A66Layout.key(n) else { usage() }
        k.resetToFactory(layer: 0, key: n)
        print(L("注意：普通层 K\(n)（\(spec.legend)）按出厂键位写入。", "Note: base layer K\(n) (\(spec.legend)) uses its factory key."))
    }
    for s in sets { applySet(s, source: "--set", to: &k) }
    // 和原厂驱动一样只写有改动的层（相对上次写入）；没写过或加 --all 时三层都写
    let last = KeymapStore.load(KeymapStore.lastWrittenURL)
    var layers = [0, 1, 2]
    if let layersArg {
        layers = layersArg.split(separator: ",").compactMap { Int($0) }
        guard !layers.isEmpty, layers.allSatisfy({ (0..<Keymap.layerCount).contains($0) }) else { usage() }
        layers = Array(Set(layers)).sorted()
    } else if let last, !all {
        layers = k.changedLayers(from: last)
        if layers.isEmpty {
            print(L("与上次写入一致，没有要写的层。键盘被复位过或在别处改过键的话，加 --all 全部重写。",
                    "Nothing changed since the last write. After a keyboard reset or remapping elsewhere, add --all."))
            return
        }
        print(L("只写有改动的层：", "Writing only changed layer(s): ") + layers.map { layerTitle($0) }.joined(separator: "、")
              + L("（全部重写加 --all）", " (add --all to rewrite everything)"))
    }
    printKeymap(k, layers: layers, all: false)
    if !k.hasFnKey && !yes {
        print(L("（写入前请确认这是你想要的）", "(make sure this is intended before writing)"))
    }
    let ch = pickChannel(&a)
    a.done()
    print(L("\n将要写入（\(ch.connection.title)）：", "\nWill write (\(ch.connection.title)):"))
    for l in layers {
        let m = k.matrix(layer: l)
        if ch.connection == .wired {
            let p = WiredPacket.packets(.setMatrix, sub: UInt8(l), data: m)
            print("  \(layerTitle(l))：\(p.count) × \(WiredPacket.size) B，\(hex(p[0].prefix(8)))")
        } else {
            let p = WirelessPacket.writePackets(.setMatrix, sub: UInt8(l), data: m)
            print("  \(layerTitle(l))：\(p.count) × \(WirelessPacket.size) B，" + L("首包 ", "first ") + hex(p[0]))
        }
    }
    guard yes else {
        print(L("\n演习模式：什么都没发。确认无误后加 --yes 才会真的写入键盘。", "\nDry run: nothing sent. Add --yes to write."))
        return
    }
    let verification: A66Device.Verification
    do {
        verification = try A66Device.write(k, layers: layers, to: ch, log: { print($0) })
    } catch { fail("\(error)") }
    // 记下键盘里现在是什么：写了的层换成这次的内容。从没写过又只写了部分层时，其余层不确定，不记。
    if let base = last ?? (layers.count == Keymap.layerCount ? k : nil) {
        try? KeymapStore.save(base.replacing(layers: layers, from: k), to: KeymapStore.lastWrittenURL)
    }
    switch verification {
    case .verified:
        print(L("完成，已读回核对。", "Done and verified by reading back."))
    case let .unverified(why):
        print(L("写入完成，但没能读回核对（\(why)）。按几个改过的键确认一下。", "Written, but could not verify by reading back (\(why)). Press a few changed keys to check."))
    }
}

// MARK: - main

var argv = Array(CommandLine.arguments.dropFirst())
guard !argv.isEmpty else { usage() }
let cmd = argv.removeFirst()
let args = Args(items: argv)
switch cmd {
case "list": cmdList(args)
case "identify": cmdIdentify(args)
case "read": cmdRead(args)
case "show": cmdShow(args)
case "init": cmdInit(args)
case "import-windows": cmdImportWindows(args)
case "build": cmdBuild(args)
case "apply": cmdApply(args)
default: usage()
}
