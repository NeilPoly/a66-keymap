import { L } from './l10n.js';
import { hexBytes } from './keycode.js';
import { Wired, Wireless } from './packets.js';
import { Keymap, LAYER_COUNT, MATRIX_BYTES } from './keymap.js';

// 通过 WebHID 与键盘通信：找配置通道、读密码核对型号、读写键位表。
// 只用 packets.js 里登记过的命令。流程与 Sources/A66HID/A66Device.swift 一致。

export const A66 = Object.freeze({
  wiredVID: 0x258a,
  wiredPID: 0x010c,
  wirelessVID: 0x3554,
  /** 2.4G 接收器；蓝牙下是 0xFA07 */
  receiverPID: 0xfa09,
  /**
   * 键盘同时广播两种蓝牙，配置通道相同（FF02:2，报告 0x13），都能写入、都不读键位：
   * "A66 5.0" = 低功耗蓝牙 0xFA07，"A66 3.0" = 经典蓝牙 0xFA08（2026-11-03 实测）
   */
  blePID: 0xfa07,
  classicPID: 0xfa08,
  /** 读到的"密码"必须是这 6 个字节才写入（同 VID/PID 被多家品牌的键盘共用） */
  password: Object.freeze([0x03, 0x00, 0x00, 0x00, 0x00, 0xd9]),
});

/** 浏览器设备选择框里只列出 A66 的配置通道 */
export const FILTERS = [
  { vendorId: A66.wiredVID, productId: A66.wiredPID, usagePage: 0xff00, usage: 0x01 },
  { vendorId: A66.wirelessVID, usagePage: 0xff02, usage: 0x02 },
];

export const CONNECTION_TITLES = {
  wired: () => L('有线', 'USB cable'),
  bluetooth: () => L('蓝牙', 'Bluetooth'),
  receiver: () => L('2.4G 接收器', '2.4 GHz receiver'),
};

/** 界面上显示的通道名：蓝牙再分 5.0 / 3.0（按 PID；认不出的 3554 设备只写"蓝牙"） */
export function channelTitle(ch) {
  if (ch?.connection !== 'bluetooth') return CONNECTION_TITLES[ch?.connection]?.() ?? '';
  const pid = ch.device?.productId;
  if (pid === A66.blePID) return L('蓝牙 5.0', 'Bluetooth 5.0');
  if (pid === A66.classicPID) return L('蓝牙 3.0', 'Bluetooth 3.0');
  return CONNECTION_TITLES.bluetooth();
}

export class A66Error extends Error {}

export const isSupported = () => typeof navigator !== 'undefined' && 'hid' in navigator;
export const isMac = () =>
  typeof navigator !== 'undefined' && (navigator.userAgentData?.platform === 'macOS' || /Mac/.test(navigator.platform || ''));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function hasCollection(cols, page, usage) {
  return (cols || []).some((c) => (c.usagePage === page && c.usage === usage) || hasCollection(c.children, page, usage));
}

/** 'wired' | 'bluetooth' | 'receiver' | null */
export function classify(dev) {
  if (dev.vendorId === A66.wiredVID && dev.productId === A66.wiredPID && hasCollection(dev.collections, 0xff00, 1)) {
    return 'wired';
  }
  if (dev.vendorId === A66.wirelessVID && hasCollection(dev.collections, 0xff02, 2)) {
    return dev.productId === A66.receiverPID ? 'receiver' : 'bluetooth';
  }
  return null;
}

const ORDER = { wired: 0, bluetooth: 1, receiver: 2 };

/**
 * 已授权、当前连着的配置通道：有线在前，然后蓝牙、2.4G。
 * @returns {Promise<{device: HIDDevice, connection: string}[]>}
 */
export async function channels() {
  if (!isSupported()) return [];
  const devs = await navigator.hid.getDevices();
  const seen = new Set();
  return devs
    .map((device) => ({ device, connection: classify(device) }))
    .filter((c) => c.connection && !seen.has(c.device) && seen.add(c.device))
    .sort((a, b) => ORDER[a.connection] - ORDER[b.connection]);
}

/** 弹出浏览器的设备选择框（必须由点击触发）。用户取消时不报错。 */
export async function requestAccess() {
  await navigator.hid.requestDevice({ filters: FILTERS });
}

/**
 * 该用哪个通道：有线 > 蓝牙 > 2.4G 的第一个。有线、蓝牙的通道只在键盘处于该模式时才出现，
 * 接收器插着却不代表键盘在 2.4G 模式，所以只要有更高优先级的通道就不用接收器；
 * 也不在失败后退到下一个（比如蓝牙被 Karabiner 独占时退到接收器只会白等），直接报真实原因。
 */
export const preferred = (chs) => chs[0] ?? null;

/**
 * 能不能读键位。蓝牙（5.0、3.0 都算）不行：键盘约每 4 ms 发一包回包，蓝牙送不过来的被键盘丢掉
 * （抓包证实没上空中）。5.0 每次丢的位置几乎相同，多读也凑不齐；3.0 丢的位置随机，合并十几到二十几次
 * 请求能凑齐，但三层要半分钟以上，按用户决定不做（2026-11-03 实测，见 docs/protocol.md）
 */
export const canRead = (connection) => connection !== 'bluetooth';

export const bluetoothReadMessage = () => L(
  '蓝牙下读不了键位（键盘固件的限制），要读取请用有线或 2.4G。',
  'The keymap cannot be read over Bluetooth (a keyboard firmware limitation). To read, use the cable or 2.4 GHz.');

export class CancelFlag {
  cancelled = false;
  cancel() { this.cancelled = true; }
}

/**
 * 打开失败时的提示。浏览器只报 "Failed to open the device"，分不出是被别的程序独占还是没权限，
 * 所以按常见程度列出来。Mac 上最常见的是 Karabiner-Elements 接管了键盘：蓝牙下改键通道就是键盘本身，
 * 2.4G 下改键通道和键盘输入在接收器的同一个接口里，开着 Modify events 都会独占（2026-11-03 实测
 * 2.4G 也会，命令行打开返回 0xE00002C5）；有线没实测，所以不分连接方式一律提示。
 */
function openHint(connection) {
  if (!isMac()) {
    return L('键盘可能被别的程序（如原厂驱动）占用了，关掉后刷新页面再试。',
      'The keyboard may be in use by another program (such as the vendor driver). Close it, reload the page and try again.');
  }
  const receiver = connection === 'receiver';
  return [
    L('键盘可能被别的程序占用了，或者浏览器没有权限：',
      'The keyboard may be in use by another program, or the browser lacks permission:'),
    L(`1. 用了 Karabiner-Elements 的话，在它的 Devices 里临时关掉${receiver ? '“2.4G Wireless Receiver”' : '这把键盘'}的 Modify events，刷新页面再试，写完再打开。`,
      `1. If you use Karabiner-Elements, temporarily turn off Modify events for ${receiver ? '“2.4G Wireless Receiver”' : 'this keyboard'} in its Devices tab, reload the page and try again; turn it back on afterwards.`),
    L('2. 关掉其他改键程序。',
      '2. Close any other remapping program.'),
    L('3. 检查“输入监控”权限：系统设置 → 隐私与安全性 → 输入监控，打开浏览器，然后完全退出浏览器（⌘Q）再打开。',
      '3. Check Input Monitoring: System Settings → Privacy & Security → Input Monitoring, enable the browser, then quit it completely (⌘Q) and reopen.'),
  ].join('\n');
}

/** 打开通道（同一设备已打开时直接用） */
export async function open(ch, log = () => {}) {
  const dev = ch.device;
  if (!dev.opened) {
    try { await dev.open(); } catch (e) {
      throw new A66Error(L('打开键盘失败：', 'Could not open the keyboard: ') + (e?.message || e) + '\n' + openHint(ch.connection));
    }
  }
  return ch.connection === 'wired' ? new WiredLink(dev, log) : new WirelessLink(dev, ch.connection, log);
}

/** 打开通道并读密码（只读）。cancel 可在等待键盘应答时中止。 */
export async function connect(ch, { cancel, log = () => {} } = {}) {
  const link = await open(ch, log);
  try {
    return { link, password: await link.readPassword(cancel) };
  } catch (e) {
    await link.close();
    throw e;
  }
}

export const isA66 = (psd) => psd.length === 6 && psd.every((v, i) => v === A66.password[i]);

function checkPassword(password, ch, log) {
  if (!isA66(password)) {
    throw new A66Error(L(`键盘密码 ${hexBytes(password)} 不是 A66 的 ${hexBytes(A66.password)}，已中止，没有读写任何东西。`,
      `Keyboard ID ${hexBytes(password)} is not the A66's ${hexBytes(A66.password)}; aborted, nothing was read or written.`));
  }
  log(L(`✓ 型号核对通过（${CONNECTION_TITLES[ch.connection]()}，${hexBytes(password)}）`,
    `✓ Keyboard ID verified (${CONNECTION_TITLES[ch.connection]()}, ${hexBytes(password)})`));
}

/**
 * 核对密码后写入指定层，写完把这些层读回来逐字节核对。只有连接、读密码阶段能取消；开始写以后不响应取消，免得写一半。
 * progress(已完成包数, 总包数)，开始写时先报 (0, 总数)。读回与写入不一致时抛错。
 * 返回 { verified: true } 或 { verified: false, note: 没能核对的原因 }。
 * @param {import('./keymap.js').Keymap} keymap
 */
export async function write(keymap, layers, ch, { cancel, log = () => {}, progress = () => {} } = {}) {
  if (!layers.length || !layers.every((l) => l >= 0 && l <= 2)) throw new Error('bad layers');
  const { link, password } = await connect(ch, { cancel, log });
  try {
    checkPassword(password, ch, log);
    await link.writeLayers(layers.map((l) => [l, keymap.matrix(l)]), progress);

    if (!canRead(ch.connection)) {
      const note = L('蓝牙下不能读回核对。',
        'Bluetooth cannot read back, so the write was not verified.');
      log('  ' + note);
      return { verified: false, note };
    }

    // 读回核对。刚写完时先稍等；不一致再等一会儿重读一次，免得键盘还没存完就误报
    log(L('  读回核对…', '  verifying by reading back…'));
    let mismatched = layers;
    for (const wait of [100, 400]) {
      if (!mismatched.length) break;
      await sleep(wait);
      let back;
      try { back = await link.readLayers(mismatched); } catch (e) {
        log(L(`  ⚠ 读回失败，没能核对：${e.message}`, `  ⚠ could not read back to verify: ${e.message}`));
        return { verified: false, note: e.message };
      }
      mismatched = mismatched.filter((l, i) => !keymap.matches(back[i], l));
    }
    if (mismatched.length) {
      throw new A66Error(L(`写入后读回核对不一致（${mismatched.map((l) => `第 ${l} 层`).join('、')}）。键盘里可能是新旧混合的状态，请重新写一次。`,
        `Read-back after writing does not match (layer ${mismatched.join(', ')}). The keyboard may be half-updated; write again.`));
    }
    log(L('  ✓ 读回核对一致', '  ✓ read-back matches'));
    return { verified: true };
  } finally {
    await link.close();
  }
}

/**
 * 核对密码后读回 0–2 层，组成配置（只读）。返回 { keymap, unknown }，unknown = 不在 A66 键位排列上却有内容的位置。
 * progress(已读层数, 总层数)。只有连接、读密码阶段能取消。
 */
export async function readKeymap(ch, { cancel, log = () => {}, progress = () => {} } = {}) {
  if (!canRead(ch.connection)) throw new A66Error(bluetoothReadMessage());
  const { link, password } = await connect(ch, { cancel, log });
  try {
    checkPassword(password, ch, log);
    const ms = await link.readLayers([...Array(LAYER_COUNT).keys()], progress);
    log(L('  ✓ 已读回 3 层', '  ✓ read 3 layers'));
    return Keymap.fromMatrices(ms);
  } finally {
    await link.close();
  }
}

const cancelledError = () => new A66Error(L('已取消，没有写入任何东西。', 'Cancelled; nothing was written.'));

// MARK: - 有线：Feature 报告 6，520 字节

class WiredLink {
  constructor(dev, log) { this.dev = dev; this.log = log; this.connection = 'wired'; }

  async close() { try { await this.dev.close(); } catch { /* 已断开 */ } }

  /** SetFeature（报告 ID 单独传，数据不含 ID），失败隔 70ms 重试，共 3 次 */
  async send(pkt) {
    let last;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try { await this.dev.sendFeatureReport(pkt[0], pkt.subarray(1)); return; } catch (e) {
        last = e;
        this.log(L(`  第 ${attempt} 次发送失败：${e?.message || e}`, `  send attempt ${attempt} failed: ${e?.message || e}`));
        await sleep(70);
      }
    }
    throw new A66Error(String(last?.message || last));
  }

  /** 等 20ms → 发读请求（只有包头）→ 等 20ms → 取回，数据从偏移 8 起 */
  async readPassword(cancel) {
    if (cancel?.cancelled) throw cancelledError();
    await sleep(20);
    await this.send(Wired.readRequest(Wired.Command.readPassword, 1, 6));
    await sleep(20);
    // 回包 = 包头原样回显（06 82 01 00 01 00 06 00）+ 6 字节密码
    const b = await this.receive(Wired.Command.readPassword);
    if (b.length < 14) throw new A66Error(L('回包太短：', 'Reply too short: ') + hexBytes(b));
    return Array.from(b.slice(8, 14));
  }

  /** GetFeature(6)。回包首字节是回显的命令时说明浏览器去掉了报告 ID，补回去，统一成"首字节 = 报告 ID" */
  async receive(cmd) {
    let dv;
    try { dv = await this.dev.receiveFeatureReport(Wired.reportId); } catch (e) { throw new A66Error(String(e?.message || e)); }
    const b = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
    if (!(b[0] === Wired.reportId && b[1] === cmd) && b[0] === cmd) return Uint8Array.of(Wired.reportId, ...b);
    return Uint8Array.from(b);
  }

  /** 每层：等 20ms → 发读请求 0x83（只有包头）→ 等 20ms → 取回。包头回显和末尾 5A A5 对不上就重读，最多 3 次 */
  async readLayers(layers, progress = () => {}) {
    const out = [];
    progress(0, layers.length);
    for (const [n, l] of layers.entries()) {
      let got = null;
      for (let attempt = 1; attempt <= 3 && !got; attempt++) {
        await sleep(20);
        await this.send(Wired.readRequest(Wired.Command.readMatrix, l, Wired.chunk));
        await sleep(20);
        const rsp = await this.receive(Wired.Command.readMatrix);
        got = Wired.matrixReply(rsp, l);
        if (!got) {
          this.log(L(`  读第 ${l} 层第 ${attempt} 次：回包不是键位表（${hexBytes(rsp.slice(0, 8))}），重读`,
            `  reading layer ${l}, attempt ${attempt}: reply is not a key table (${hexBytes(rsp.slice(0, 8))}), retrying`));
        }
      }
      if (!got) throw new A66Error(L(`读第 ${l} 层失败：键盘的回包不是键位表。`, `Reading layer ${l} failed: the reply is not a key table.`));
      out.push(got);
      progress(n + 1, layers.length);
    }
    return out;
  }

  /** 每包前等 20ms，每层之后等 30ms */
  async writeLayers(layers, progress) {
    const all = layers.map(([l, m]) => [l, Wired.packets(Wired.Command.setMatrix, l, m)]);
    const total = all.reduce((s, [, p]) => s + p.length, 0);
    let done = 0;
    progress(0, total);
    for (const [l, pkts] of all) {
      for (const [i, p] of pkts.entries()) {
        await sleep(20);
        try { await this.send(p); } catch (e) {
          throw new A66Error(L(`第 ${l} 层第 ${i} 包写入失败：${e.message}。键盘可能处于新旧混合状态，重新写一次即可。`,
            `Writing layer ${l} packet ${i} failed: ${e.message}. The keyboard may be half-updated; just write again.`));
        }
        progress(++done, total);
      }
      this.log(L(`  第 ${l} 层已写入`, `  layer ${l} written`));
      await sleep(30);
    }
  }
}

// MARK: - 蓝牙 / 2.4G：输出/输入报告 0x13，20 字节

class WirelessLink {
  constructor(dev, connection, log) {
    this.dev = dev; this.connection = connection; this.log = log;
    /** 收到的输入报告，统一成"首字节 = 报告 ID"的 20 字节 */
    this.queue = [];
    this.waiter = null;
    this.onReport = (e) => {
      if (e.reportId !== Wireless.reportId) return;
      const r = new Uint8Array(Wireless.size);
      r[0] = Wireless.reportId;
      r.set(new Uint8Array(e.data.buffer, e.data.byteOffset, Math.min(e.data.byteLength, Wireless.size - 1)), 1);
      this.queue.push(r);
      if (this.waiter) { const w = this.waiter; this.waiter = null; w(); }
    };
    dev.addEventListener('inputreport', this.onReport);
  }

  async close() {
    this.dev.removeEventListener('inputreport', this.onReport);
    try { await this.dev.close(); } catch { /* 已断开 */ }
  }

  /** 丢掉已经收到但还没处理的报告 */
  drain() { this.queue.length = 0; }

  /** 等下一个输入报告，超时返回 null */
  async next(timeoutMs) {
    if (this.queue.length) return this.queue.shift();
    await new Promise((resolve) => {
      const t = setTimeout(() => { if (this.waiter === done) this.waiter = null; resolve(); }, timeoutMs);
      const done = () => { clearTimeout(t); resolve(); };
      this.waiter = done;
    });
    return this.queue.shift() ?? null;
  }

  /** 整包第 0 字节是报告 ID，单独传给浏览器 */
  async send(pkt) {
    await this.dev.sendReport(pkt[0], pkt.subarray(1));
  }

  /**
   * 发读请求、收齐回包。键盘空闲后头几个请求常收不到应答（要先唤醒），所以每 0.5 秒重发一次，最多约 30 秒。
   * 原驱动是每秒重发；缩短间隔只是更早发现键盘醒了，重发的是只读命令。
   * 唤醒用时实测：5.0 蓝牙 0–8 秒，3.0 蓝牙 7–15 秒（原先 20 秒上限余量太小）。
   */
  async readPassword(cancel) {
    const cmd = Wireless.Command.readPassword;
    const req = Wireless.readRequest(cmd);
    const start = performance.now();
    let attempt = 0;
    while (performance.now() - start < 30000) {
      if (cancel?.cancelled) throw cancelledError();
      attempt++;
      this.drain();
      try { await this.send(req); } catch (e) { throw new A66Error(String(e?.message || e)); }
      const data = await this.collect(cmd, 500);
      if (data) {
        if (data.length < 6) throw new A66Error(L('回包太短：', 'Reply too short: ') + hexBytes(data));
        if (attempt > 1) {
          const s = ((performance.now() - start) / 1000).toFixed(1);
          this.log(L(`  键盘已应答（唤醒用了 ${s} 秒）`, `  keyboard answered (woke up in ${s} s)`));
        }
        return data.slice(0, 6);
      }
      if (attempt === 1) {
        this.log(L('  正在唤醒键盘…（空闲后头几个请求常收不到应答）', '  waking the keyboard… (the first requests after idle often go unanswered)'));
      }
    }
    throw new A66Error(L('键盘没有应答。请确认键盘已开机、处于当前连接模式；蓝牙下检查 Karabiner 是否接管了键盘。',
      'The keyboard did not answer. Make sure it is on and in this connection mode; over Bluetooth, check whether Karabiner has grabbed it.'));
  }

  /**
   * 收一次读命令的回包；第一包等 firstTimeout，后续包各等 1 秒。超时、校验错、序号不连续、
   * 或回显的子命令（层号）不是 sub 时返回 null，由调用方重发。
   */
  async collect(cmd, firstTimeoutMs, sub = null) {
    let data = [], others = 0, timeout = firstTimeoutMs, expected = 0;
    for (;;) {
      const r = await this.next(timeout);
      if (!r) return null;
      const part = Wireless.parseReadPart(r);
      if (!part || part.cmd !== cmd) {
        if (++others > 20) return null;
        continue;
      }
      if (part.crcError || part.index !== expected) return null;
      if (sub !== null && part.sub !== sub) return null;
      data = data.concat(part.data);
      expected++;
      if (part.index + 1 >= part.total) return data;
      timeout = 1000;
    }
  }

  /** 每层发读请求 0x41，收齐回包（36 包 504 字节）。超时或不完整就同层重发，最多 3 次（2.4G 实测同一层偶尔第一次请求没有应答） */
  async readLayers(layers, progress = () => {}) {
    const cmd = Wireless.Command.readMatrix;
    const out = [];
    progress(0, layers.length);
    for (const [n, l] of layers.entries()) {
      let got = null;
      for (let attempt = 1; attempt <= 3 && !got; attempt++) {
        this.drain();
        try { await this.send(Wireless.readRequest(cmd, l)); } catch (e) { throw new A66Error(String(e?.message || e)); }
        const d = await this.collect(cmd, 1500, l);
        if (d && d.length >= Keymap.minimumReadBytes) got = Uint8Array.from(d.slice(0, MATRIX_BYTES));
        else this.log(L(`  读第 ${l} 层第 ${attempt} 次没收齐，重发`, `  reading layer ${l}, attempt ${attempt} incomplete, resending`));
      }
      if (!got) {
        throw new A66Error(L(`读第 ${l} 层失败：重发 3 次都没收齐键盘的回包。确认键盘醒着、处于这个连接模式。`,
          `Reading layer ${l} failed: no complete reply after 3 tries. Make sure the keyboard is awake and in this mode.`));
      }
      out.push(got);
      progress(n + 1, layers.length);
    }
    return out;
  }

  /** 先等 200ms；逐包发送，每包前等 15ms 并等应答，超时/校验错同包重发最多 5 次；层间 30ms，结束后 50ms */
  async writeLayers(layers, progress) {
    const cmd = Wireless.Command.setMatrix;
    const all = layers.map(([l, m]) => [l, Wireless.writePackets(cmd, l, m)]);
    const total = all.reduce((s, [, p]) => s + p.length, 0);
    let done = 0;
    progress(0, total);
    await sleep(200);
    for (const [l, pkts] of all) {
      for (const [i, p] of pkts.entries()) {
        let ok = false;
        for (let attempt = 1; attempt <= 5 && !ok; attempt++) {
          await sleep(15);
          this.drain();
          try { await this.send(p); } catch (e) {
            throw new A66Error(L(`第 ${l} 层第 ${i} 包发送失败：${e?.message || e}。这一层可能只写了一半，重新写一次即可。`,
              `Sending layer ${l} packet ${i} failed: ${e?.message || e}. The layer may be half-written; just write again.`));
          }
          let outcome = L('超时', 'timeout');
          for (let seen = 0; seen < 20; seen++) {
            const r = await this.next(1000);
            if (!r) break;
            const ack = Wireless.classifyAck(r, cmd);
            if (ack === 'other') continue;
            if (ack === 'ok') ok = true;
            else if (ack === 'crcError') outcome = L('校验错', 'checksum error');
            else {
              throw new A66Error(L(`第 ${l} 层第 ${i} 包：键盘回报错误 ${hexBytes(r)}，已中止。`,
                `Layer ${l} packet ${i}: keyboard reported an error ${hexBytes(r)}; aborted.`));
            }
            break;
          }
          if (!ok) {
            this.log(L(`  第 ${l} 层第 ${i} 包第 ${attempt} 次：${outcome}，重发`,
              `  layer ${l} packet ${i} attempt ${attempt}: ${outcome}, resending`));
          }
        }
        if (!ok) {
          throw new A66Error(L(`第 ${l} 层第 ${i} 包重发 5 次仍失败，已中止。这一层可能只写了一半，重新写一次即可。`,
            `Layer ${l} packet ${i} failed 5 times; aborted. The layer may be half-written; just write again.`));
        }
        progress(++done, total);
      }
      this.log(L(`  第 ${l} 层已写入（${pkts.length} 包，均已应答）`, `  layer ${l} written (${pkts.length} packets, all acknowledged)`));
      await sleep(30);
    }
    await sleep(50);
  }
}
