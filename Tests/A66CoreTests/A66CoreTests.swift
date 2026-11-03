import Foundation
import Testing
@testable import A66Core

@Suite struct LayoutTests {
    @Test func keysAreNumberedAndUnique() {
        #expect(A66Layout.keys.count == 67)
        #expect(A66Layout.keys.map(\.id) == Array(1...67))
        let matrices = A66Layout.keys.map(\.matrix)
        #expect(Set(matrices).count == matrices.count)
        #expect(matrices.allSatisfy { $0 >= 0 && $0 < Keymap.matrixEntries - 1 })
    }

    @Test func rowsDoNotOverlap() {
        for row in 0..<A66Layout.rows {
            let ks = A66Layout.keys.filter { $0.y == row }.sorted { $0.x < $1.x }
            for (a, b) in zip(ks, ks.dropFirst()) { #expect(a.x + a.w <= b.x + 1e-9, "K\(a.id) / K\(b.id)") }
            #expect((ks.last.map { $0.x + $0.w } ?? 0) <= A66Layout.width)
        }
    }

    @Test func factoryHasFnAndReset() {
        #expect(A66Layout.key(64)!.factoryBase == .fn)
        #expect(A66Layout.key(33)!.factoryFn == .resetKeyboard)
    }
}

@Suite struct KeyCodeTests {
    @Test func encodings() {
        #expect(KeyCode.key(0x29).bytes == [0x00, 0x00, 0x00, 0x29])
        #expect(KeyCode.key(0x50, mods: .leftCommand).bytes == [0x00, 0x08, 0x00, 0x50])
        #expect(KeyCode.modifier(.leftControl).bytes == [0x00, 0x01, 0x00, 0x00])
        #expect(KeyCode.consumer(0x00CD).bytes == [0x02, 0x00, 0x00, 0xCD])
        #expect(KeyCode.consumer(0x0183).bytes == [0x02, 0x00, 0x01, 0x83])
        #expect(KeyCode.fn.bytes == [0x0D, 0x00, 0x00, 0x00])
        #expect(KeyCode(hex: "07 00 00 04") == .resetKeyboard)
    }

    @Test func specs() {
        #expect(KeyCatalog.code(forSpec: "LCtrl") == .modifier(.leftControl))
        #expect(KeyCatalog.code(forSpec: "LCmd+Left") == .key(0x50, mods: .leftCommand))
        #expect(KeyCatalog.code(forSpec: "Home") == .key(0x4A))
        #expect(KeyCatalog.code(forSpec: "f5") == .key(0x3E))
        #expect(KeyCatalog.code(forSpec: "Fn") == .fn)
        #expect(KeyCatalog.code(forSpec: "raw:07000004") == .resetKeyboard)
        #expect(KeyCatalog.code(forSpec: "nonsense") == nil)
    }

    @Test func everyCatalogCodeHasAName() {
        for g in KeyCatalog.groups {
            for c in g.codes {
                #expect(!c.label.isEmpty)
                #expect(!c.name.hasPrefix("设备码") && !c.name.hasPrefix("Device code"), "\(c)")
            }
        }
    }
}

@Suite struct KeymapTests {
    @Test func factoryMatrix() {
        let m = Keymap.factory.matrix(layer: 0)
        #expect(m.count == 512)
        #expect(Array(m[4..<8]) == [0x00, 0x00, 0x00, 0x29])        // Esc 在矩阵 1
        #expect(Array(m[59 * 4..<59 * 4 + 4]) == [0x0D, 0x00, 0x00, 0x00]) // Fn 在矩阵 59
        #expect(Array(m.suffix(4)) == [0x00, 0x00, 0x5A, 0xA5])
        #expect(Keymap.factory.matrix(layer: 2).filter { $0 != 0 }.count == 2)
    }

    @Test func wirelessFirstPacket() {
        let p = WirelessPacket.writePackets(.setMatrix, sub: 0, data: Keymap.factory.matrix(layer: 0))
        #expect(p.count == 37)
        #expect(hex(p[0]) == "13 01 25 00 0E 00 00 00 00 00 00 00 29 00 00 00 2B 00 00 9B")
        #expect(p[36][4] == 0x08)
    }

    @Test func wiredPackets() {
        let p = WiredPacket.packets(.setMatrix, sub: 1, data: Keymap.factory.matrix(layer: 1))
        #expect(p.count == 1 && p[0].count == 520)
        #expect(Array(p[0].prefix(8)) == [0x06, 0x03, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02])
    }

    @Test func fnMirrorsIntoFnLayers() {
        var k = Keymap.factory
        k.set(.fn, layer: 0, key: 59)
        #expect(k.code(layer: 1, key: 59) == .fn)
        #expect(k.code(layer: 2, key: 59) == .fn)
        k.set(.modifier(.leftControl), layer: 0, key: 59)
        #expect(k == Keymap.factory)
    }

    @Test func moveReset() {
        var k = Keymap.factory
        k.set(.modifier(.leftControl), layer: 0, key: 33)
        k.moveResetToFnDelete()
        #expect(k.code(layer: 1, key: 33) == .modifier(.leftControl))
        #expect(k.code(layer: 1, key: 31) == .resetKeyboard)
        #expect(k.resetKeys.map(\.key) == [31])
        #expect(Keymap.recommended.code(layer: 1, key: 33) == .key(0x39))
    }

    @Test func jsonRoundTrip() throws {
        var k = Keymap.recommended
        k.set(.key(0x4A), layer: 0, key: 16)
        let back = try Keymap(jsonData: k.jsonData())
        #expect(back == k)
        #expect(back.changes(from: .recommended).count == 1)
        #expect(back.changedLayers(from: .recommended) == [0])
    }

    @Test func onlyChangedLayers() {
        let last = Keymap.recommended
        var k = last
        k.set(.key(0x4A), layer: 0, key: 16)
        #expect(k.changedLayers(from: last) == [0])
        k.set(.fn, layer: 0, key: 59)          // Fn 联动到第 1、2 层
        #expect(k.changedLayers(from: last) == [0, 1, 2])
        let written = last.replacing(layers: [0], from: k)
        #expect(written.code(layer: 0, key: 16) == .key(0x4A))
        #expect(written.code(layer: 1, key: 59) == last.code(layer: 1, key: 59))
    }

    @Test func rejectsForeignJSON() {
        #expect(throws: (any Error).self) { try Keymap(jsonData: Data(#"{"format":"x","version":1,"layers":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try Keymap(jsonData: Data(#"{"format":"a66-keymap","version":1,"layers":[{"K99":"00000004"}]}"#.utf8)) }
    }
}

@Suite struct ReadBackTests {
    @Test func wiredReadRequestAndReply() {
        let req = WiredPacket.readRequest(.readMatrix, sub: 1, length: 512)
        #expect(req.count == 520)
        #expect(hex(req.prefix(8)) == "06 83 01 00 01 00 00 02")
        let m = Keymap.recommended.matrix(layer: 1)
        let rsp = Array(req.prefix(8)) + m
        #expect(WiredPacket.matrixReply(rsp, layer: 1) == m)
        #expect(WiredPacket.matrixReply(rsp, layer: 0) == nil)            // 层号对不上
        var bad = rsp; bad[519] = 0
        #expect(WiredPacket.matrixReply(bad, layer: 1) == nil)            // 没有 5A A5
        var echo = rsp; echo[1] = 0x82
        #expect(WiredPacket.matrixReply(echo, layer: 1) == nil)           // 不是读键位的回包
    }

    @Test func wirelessReadRequestAndPart() {
        #expect(hex(WirelessPacket.readRequest(.readMatrix, sub: 2)) == "13 41 01 00 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 75")
        #expect(hex(WirelessPacket.readRequest(.readPassword)) == "13 05 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 19")
        // 2.4G 实测的第 1 层首包
        let r: [UInt8] = [0x13, 0x41, 0x24, 0x00, 0x1E, 0, 0, 0, 0, 0, 0, 0, 0x35, 0x07, 0, 0, 0x12, 0, 0x01, 0xE5]
        let p = WirelessPacket.parseReadPart(r)!
        #expect(p.cmd == 0x41 && p.total == 36 && p.index == 0 && p.sub == 1 && p.data.count == 14 && !p.crcError)
        var broken = r; broken[19] ^= 1
        #expect(WirelessPacket.parseReadPart(broken) == nil)              // 校验和不对的包丢掉
    }

    @Test func keymapFromReadBack() {
        let k = Keymap.recommended
        let wired = (0..<3).map { k.matrix(layer: $0) }
        #expect(Keymap.fromMatrices(wired).keymap == k)
        #expect(Keymap.fromMatrices(wired).unknown.isEmpty)
        let wireless = wired.map { Array($0.prefix(WirelessPacket.matrixReadBytes)) }
        #expect(Keymap.fromMatrices(wireless).keymap == k)
        #expect(wireless.enumerated().allSatisfy { k.matches($0.element, layer: $0.offset) })
        var other = k
        other.set(.key(0x4A), layer: 0, key: 16)
        #expect(!other.matches(wireless[0], layer: 0))
        #expect(!k.matches(Array(wired[0].prefix(100)), layer: 0))      // 太短不算
        var odd = wired
        odd[2].replaceSubrange(0..<4, with: [0x00, 0x00, 0x00, 0x04]) // 矩阵 0 不是 A66 的键
        let r = Keymap.fromMatrices(odd)
        #expect(r.keymap == k && r.unknown == [Keymap.UnknownEntry(layer: 2, index: 0, code: .key(0x04))])
    }
}
