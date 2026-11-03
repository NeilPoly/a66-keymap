import A66Core
import Foundation
import IOKit.hid

/// 只读枚举得到的 HID 设备信息（不打开设备）
public struct HIDDeviceInfo {
    public let device: IOHIDDevice
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let transport: String
    public let locationID: Int
    public let usagePairs: [(page: Int, usage: Int)]
    public let maxInput: Int
    public let maxOutput: Int
    public let maxFeature: Int

    init(_ d: IOHIDDevice) {
        func prop(_ k: String) -> AnyObject? { IOHIDDeviceGetProperty(d, k as CFString) }
        device = d
        vendorID = prop(kIOHIDVendorIDKey) as? Int ?? 0
        productID = prop(kIOHIDProductIDKey) as? Int ?? 0
        product = prop(kIOHIDProductKey) as? String ?? ""
        transport = prop(kIOHIDTransportKey) as? String ?? ""
        locationID = prop(kIOHIDLocationIDKey) as? Int ?? 0
        maxInput = prop(kIOHIDMaxInputReportSizeKey) as? Int ?? 0
        maxOutput = prop(kIOHIDMaxOutputReportSizeKey) as? Int ?? 0
        maxFeature = prop(kIOHIDMaxFeatureReportSizeKey) as? Int ?? 0
        let pairs = prop(kIOHIDDeviceUsagePairsKey) as? [[String: Int]] ?? []
        usagePairs = pairs.map { ($0[kIOHIDDeviceUsagePageKey] ?? 0, $0[kIOHIDDeviceUsageKey] ?? 0) }
    }

    public func has(page: Int, usage: Int) -> Bool {
        usagePairs.contains { $0.page == page && $0.usage == usage }
    }
}

public enum HID {
    /// 按 VID（可选 PID）枚举。用 IOHIDManagerCopyDevices，不调用 IOHIDManagerOpen，
    /// 所以不会打开任何设备，也不触发"输入监控"权限。
    public static func enumerate(vendorIDs: [Int]) -> [HIDDeviceInfo] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = vendorIDs.map { [kIOHIDVendorIDKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        guard let set = IOHIDManagerCopyDevices(mgr) else { return [] }
        return (set as NSSet).allObjects
            .map { HIDDeviceInfo($0 as! IOHIDDevice) }
            .sorted { ($0.vendorID, $0.productID, $0.locationID) < ($1.vendorID, $1.productID, $1.locationID) }
    }
}

public struct HIDError: Error, CustomStringConvertible {
    // code 公开给上层判断"没有权限"等情况
    public let what: String
    public let code: IOReturn

    public var description: String {
        let c = UInt32(bitPattern: code)
        var hint = ""
        switch c {
        case 0xE00002C5: hint = L("（设备被别的程序独占，多半是 Karabiner）", " (device is held exclusively by another program, usually Karabiner)")
        case 0xE00002E2: hint = L("（没有权限：系统设置 → 隐私与安全性 → 输入监控）", " (not permitted: System Settings → Privacy & Security → Input Monitoring)")
        case 0xE00002D6: hint = L("（超时）", " (timeout)")
        case 0xE00002C0: hint = L("（设备已断开）", " (device disconnected)")
        default: break
        }
        return String(format: L("%@ 失败 0x%08X%@", "%@ failed 0x%08X%@"), what, c, hint)
    }
}

/// 有线配置接口的 Feature 报告通道
public final class FeatureChannel {
    public let info: HIDDeviceInfo
    private var opened = false

    public init(_ info: HIDDeviceInfo) { self.info = info }

    public func open() throws {
        let r = IOHIDDeviceOpen(info.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDError(what: L("打开设备", "Opening device"), code: r) }
        opened = true
    }

    public func close() {
        if opened { IOHIDDeviceClose(info.device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        opened = false
    }

    deinit { close() }

    /// buf[0] 必须是报告 ID，整包（含 ID）原样发出，与 Windows HidD_SetFeature 一致
    public func setFeature(_ buf: [UInt8]) throws {
        let r = buf.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(info.device, kIOHIDReportTypeFeature, CFIndex(buf[0]), $0.baseAddress!, buf.count)
        }
        guard r == kIOReturnSuccess else { throw HIDError(what: "SetFeature", code: r) }
    }

    public func getFeature(reportID: UInt8, length: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: length)
        buf[0] = reportID
        var len = CFIndex(length)
        let r = buf.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(info.device, kIOHIDReportTypeFeature, CFIndex(reportID), $0.baseAddress!, &len)
        }
        guard r == kIOReturnSuccess else { throw HIDError(what: "GetFeature", code: r) }
        return Array(buf[0..<min(len, length)])
    }
}

/// 无线配置通道：输出报告发送 + 输入报告接收（蓝牙下与键盘本体是同一个 HID 设备）。
/// 只缓存指定报告 ID 的输入报告，其他报告（按键等）直接丢弃、不保存不打印。
public final class ReportChannel {
    public let info: HIDDeviceInfo
    public let reportID: UInt8
    private var opened = false
    private let bufSize: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private var queue: [[UInt8]] = []

    public init(_ info: HIDDeviceInfo, reportID: UInt8) {
        self.info = info
        self.reportID = reportID
        bufSize = max(info.maxInput, 64)
        buffer = .allocate(capacity: bufSize)
        buffer.initialize(repeating: 0, count: bufSize)
    }

    deinit {
        close()
        buffer.deallocate()
    }

    public func open() throws {
        let r = IOHIDDeviceOpen(info.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDError(what: L("打开设备", "Opening device"), code: r) }
        opened = true
        IOHIDDeviceScheduleWithRunLoop(info.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(info.device, buffer, bufSize, { ctx, _, _, _, rid, report, length in
            guard let ctx else { return }
            Unmanaged<ReportChannel>.fromOpaque(ctx).takeUnretainedValue().received(rid, report, length)
        }, ctx)
    }

    public func close() {
        guard opened else { return }
        IOHIDDeviceRegisterInputReportCallback(info.device, buffer, bufSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(info.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(info.device, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = false
    }

    private func received(_ rid: UInt32, _ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard rid == UInt32(reportID), length > 0 else { return }
        var r = Array(UnsafeBufferPointer(start: report, count: length))
        // 统一成"首字节 = 报告 ID"的格式（与 Windows ReadFile 一致）
        if r[0] != reportID || length < 20 { r.insert(reportID, at: 0) }
        queue.append(r)
    }

    /// 丢掉已经收到但还没处理的报告
    public func drain() {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
        queue.removeAll()
    }

    /// buf[0] 必须是报告 ID，整包原样作为输出报告发送（同 Windows WriteFile）
    public func send(_ buf: [UInt8]) throws {
        let r = buf.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(info.device, kIOHIDReportTypeOutput, CFIndex(buf[0]), $0.baseAddress!, buf.count)
        }
        guard r == kIOReturnSuccess else { throw HIDError(what: L("发送输出报告", "Sending output report"), code: r) }
    }

    /// 等下一个指定 ID 的输入报告，超时返回 nil
    public func next(timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while queue.isEmpty {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, min(left, 0.05), true)
        }
        return queue.removeFirst()
    }
}
