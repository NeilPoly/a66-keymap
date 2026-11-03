import { L } from './l10n.js';

// 键位表里一个键的 4 字节设备码，用无符号 32 位整数表示。
//
// 整数按写进键盘的字节顺序做大端表示，所以十六进制写法就是字节顺序，
// 例如复位键 0x07000004 = 07 00 00 04。字节 0 是类型：
//   - 00 普通键：字节 1 = 修饰键位图（HID 标准），字节 2 = 第二个键（一般为 0），字节 3 = 主键 HID usage
//   - 02 多媒体：字节 2–3 = Consumer usage（大端）
//   - 07 键盘自身功能（字节 3 = 功能号）、08 灯光（字节 1 = 项目，字节 2 = 加/减）
//   - 0D Fn（字节 1 = 0）/ Fn2（字节 1 = 1）
//   - 00 00 00 00 = 无功能
// 与 Sources/A66Core/KeyCode.swift、KeyNames.swift 一一对应。

export const NONE = 0;
export const FN = 0x0d000000;
export const FN2 = 0x0d010000;
/** 出厂 Fn+CapsLock：复位键盘（会把键位清回出厂） */
export const RESET_KEYBOARD = 0x07000004;

/** HID 修饰键位图（字节 1） */
export const Mod = Object.freeze({
  leftControl: 0x01, leftShift: 0x02, leftOption: 0x04, leftCommand: 0x08,
  rightControl: 0x10, rightShift: 0x20, rightOption: 0x40, rightCommand: 0x80,
});

/** 普通键（可带修饰键），usage 为 HID 键盘页编号 */
export const key = (usage, mods = 0) => (((mods & 0xff) << 16) | (usage & 0xff)) >>> 0;
/** 单独的修饰键 */
export const modifier = (m) => ((m & 0xff) << 16) >>> 0;
/** 多媒体键（Consumer usage） */
export const consumer = (u) => (0x02000000 | (u & 0xffff)) >>> 0;

export const type = (c) => c >>> 24;
export const modifiers = (c) => (type(c) === 0 ? (c >>> 16) & 0xff : 0);
export const usage = (c) => (type(c) === 0 ? c & 0xff : 0);
export const secondUsage = (c) => (type(c) === 0 ? (c >>> 8) & 0xff : 0);
export const consumerUsage = (c) => (type(c) === 2 ? c & 0xffff : null);

/** 写进键位表的 4 个字节 */
export const bytes = (c) => [c >>> 24, (c >>> 16) & 0xff, (c >>> 8) & 0xff, c & 0xff];
export const hex8 = (c) => (c >>> 0).toString(16).toUpperCase().padStart(8, '0');
export const spacedHex = (c) => hexBytes(bytes(c));

/** 8 位十六进制（可带空格），如 "07000004" 或 "07 00 00 04"；不合法返回 null */
export function fromHex(s) {
  const h = String(s).replace(/ /g, '');
  return /^[0-9a-fA-F]{8}$/.test(h) ? parseInt(h, 16) >>> 0 : null;
}

export function hexBytes(b, sep = ' ') {
  return Array.from(b, (v) => v.toString(16).toUpperCase().padStart(2, '0')).join(sep);
}

// MARK: - 名称
// 键盘功能（类型 07/08）只收录 A66 出厂键位表里出现过的码，名称对照包装说明书；不提供手填任意设备码的入口。

/** HID 键：usage → [键帽短名, 中文全名, 英文全名] */
const hidNames = (() => {
  const m = new Map();
  const put = (u, cap, zh = cap, en = cap) => m.set(u, [cap, zh, en]);
  for (let i = 0; i < 26; i++) put(0x04 + i, String.fromCharCode(65 + i));
  for (let i = 0; i < 9; i++) put(0x1e + i, String(i + 1));
  put(0x27, '0');
  for (let i = 0; i < 12; i++) put(0x3a + i, `F${i + 1}`);
  put(0x28, 'Enter', '回车', 'Return');
  put(0x29, 'Esc');
  put(0x2a, '⌫', '退格', 'Backspace');
  put(0x2b, 'Tab');
  put(0x2c, 'Space', '空格', 'Space');
  put(0x2d, '-'); put(0x2e, '='); put(0x2f, '['); put(0x30, ']'); put(0x31, '\\');
  put(0x33, ';'); put(0x34, "'"); put(0x35, '`'); put(0x36, ','); put(0x37, '.'); put(0x38, '/');
  put(0x39, 'Caps', '大写锁定', 'Caps Lock');
  put(0x46, 'PrtSc', '截屏', 'Print Screen');
  put(0x47, 'ScrLk', '滚动锁定', 'Scroll Lock');
  put(0x48, 'Pause', '暂停', 'Pause');
  put(0x49, 'Ins', '插入', 'Insert');
  put(0x4a, 'Home');
  put(0x4b, 'PgUp', '上翻页', 'Page Up');
  put(0x4c, 'Del', '删除', 'Delete');
  put(0x4d, 'End');
  put(0x4e, 'PgDn', '下翻页', 'Page Down');
  put(0x4f, '→', '右', 'Right');
  put(0x50, '←', '左', 'Left');
  put(0x51, '↓', '下', 'Down');
  put(0x52, '↑', '上', 'Up');
  put(0x53, 'Num', '数字锁定', 'Num Lock');
  put(0x54, 'P/', '小键盘 /', 'Keypad /');
  put(0x55, 'P*', '小键盘 *', 'Keypad *');
  put(0x56, 'P-', '小键盘 -', 'Keypad -');
  put(0x57, 'P+', '小键盘 +', 'Keypad +');
  put(0x58, 'PEnt', '小键盘回车', 'Keypad Enter');
  for (let i = 0; i < 9; i++) put(0x59 + i, `P${i + 1}`, `小键盘 ${i + 1}`, `Keypad ${i + 1}`);
  put(0x62, 'P0', '小键盘 0', 'Keypad 0');
  put(0x63, 'P.', '小键盘 .', 'Keypad .');
  put(0x65, 'Menu', '菜单', 'Menu');
  return m;
})();

/** 修饰键：[位, 符号, 中文全名, 英文全名] */
const modifierNames = [
  [Mod.leftControl, '⌃', '左 Control', 'Left Control'],
  [Mod.leftShift, '⇧', '左 Shift', 'Left Shift'],
  [Mod.leftOption, '⌥', '左 Option（Alt）', 'Left Option (Alt)'],
  [Mod.leftCommand, '⌘', '左 Command（Win）', 'Left Command (Win)'],
  [Mod.rightControl, '⌃', '右 Control', 'Right Control'],
  [Mod.rightShift, '⇧', '右 Shift', 'Right Shift'],
  [Mod.rightOption, '⌥', '右 Option（Alt）', 'Right Option (Alt)'],
  [Mod.rightCommand, '⌘', '右 Command（Win）', 'Right Command (Win)'],
];

const modifierShort = { '⌃': 'Ctrl', '⇧': 'Shift', '⌥': 'Opt', '⌘': 'Cmd' };

/** 多媒体键：Consumer usage → [键帽, 中文, 英文] */
const consumerNames = new Map([
  [0x00cd, ['⏯', '播放/暂停', 'Play/Pause']],
  [0x00b5, ['⏭', '下一曲', 'Next Track']],
  [0x00b6, ['⏮', '上一曲', 'Previous Track']],
  [0x00b7, ['⏹', '停止', 'Stop']],
  [0x00e2, ['Mute', '静音', 'Mute']],
  [0x00e9, ['Vol+', '音量 +', 'Volume Up']],
  [0x00ea, ['Vol−', '音量 −', 'Volume Down']],
  [0x006f, ['☀+', '屏幕亮度 +', 'Brightness Up']],
  [0x0070, ['☀−', '屏幕亮度 −', 'Brightness Down']],
  [0x0183, ['Player', '媒体播放器', 'Media Player']],
  [0x018a, ['Mail', '邮件', 'Mail']],
  [0x0192, ['Calc', '计算器', 'Calculator']],
  [0x0194, ['PC', '我的电脑', 'My Computer']],
  [0x0221, ['Search', '搜索', 'Search']],
  [0x0223, ['WWW', '浏览器主页', 'Browser Home']],
  [0x0224, ['Back', '浏览器后退', 'Browser Back']],
  [0x0225, ['Fwd', '浏览器前进', 'Browser Forward']],
  [0x0226, ['Stop', '浏览器停止', 'Browser Stop']],
  [0x0227, ['Refresh', '浏览器刷新', 'Browser Refresh']],
  [0x022a, ['Fav', '收藏夹', 'Bookmarks']],
]);

/** A66 出厂键位表里出现过的键盘功能（类型 07 / 08）：[设备码, 键帽, 中文, 英文] */
const boardFunctions = [
  [0x07000005, 'BT1', '蓝牙 1（长按配对）', 'Bluetooth 1 (hold to pair)'],
  [0x07000006, 'BT2', '蓝牙 2（长按配对）', 'Bluetooth 2 (hold to pair)'],
  [0x07000007, 'BT3', '蓝牙 3（长按配对）', 'Bluetooth 3 (hold to pair)'],
  [0x07000008, '2.4G', '2.4G 模式', '2.4 GHz mode'],
  [0x07000001, 'Win🔒', '锁 Win 键', 'Win key lock'],
  [0x07000011, 'Batt', '电量查询', 'Battery check'],
  [0x0700000b, 'LED', '背光开关', 'Backlight on/off'],
  [0x07000012, 'White', '一键白光', 'White backlight'],
  [0x08000000, 'Mode', '灯效模式切换', 'Lighting mode'],
  [0x08020000, 'Color', '灯光颜色切换', 'Lighting color'],
  [0x08030100, 'Bri+', '背光亮度 +', 'Backlight brighter'],
  [0x08030200, 'Bri−', '背光亮度 −', 'Backlight dimmer'],
  [0x08040100, 'Spd+', '灯效速度 +', 'Lighting faster'],
  [0x08040200, 'Spd−', '灯效速度 −', 'Lighting slower'],
  [0x08000001, 'LED?', '灯光功能（出厂 Fn+Space，含义未知）', 'Lighting (factory Fn+Space, unknown)'],
  [0x0700000a, 'Fn+G', '键盘功能（出厂 Fn+G，含义未知）', 'Keyboard function (factory Fn+G, unknown)'],
  [0x07000014, 'Knob', '旋钮按下（出厂）', 'Knob press (factory)'],
  [RESET_KEYBOARD, L('复位', 'Reset'), '复位键盘（长按约 5 秒，清回出厂键位）', 'Reset keyboard (hold ~5 s, restores factory keymap)'],
];

const hex2 = (v) => v.toString(16).toUpperCase().padStart(2, '0');

/** 键帽上显示的短名 */
export const label = (c) => describe(c >>> 0, true);
/** 列表和说明里用的全名 */
export const name = (c) => describe(c >>> 0, false);

function describe(c, short) {
  if (c === NONE) return short ? '' : L('无', 'None');
  if (c === FN) return 'Fn';
  if (c === FN2) return 'Fn2';
  const f = boardFunctions.find((b) => b[0] === c);
  if (f) return short ? f[1] : L(f[2], f[3]);
  switch (type(c)) {
    case 0x00: {
      const mods = modifiers(c);
      const keyNames = [];
      for (const u of [usage(c), secondUsage(c)]) {
        if (u === 0) continue;
        const n = hidNames.get(u);
        keyNames.push(n ? (short ? n[0] : L(n[1], n[2])) : `HID ${hex2(u)}`);
      }
      const ms = modifierNames.filter((m) => mods & m[0]);
      if (keyNames.length === 0) {
        // 只有修饰键
        if (short) {
          // 单个修饰键写成"⌘ Cmd"，右侧的加 R；多个只写符号
          if (ms.length === 1) {
            const m = ms[0];
            return (m[0] >= 0x10 ? 'R' : '') + m[1] + ' ' + modifierShort[m[1]];
          }
          return ms.map((m) => (m[0] >= 0x10 ? 'R' : '') + m[1]).join('');
        }
        return ms.map((m) => L(m[2], m[3])).join(' + ');
      }
      const prefix = ms.map((m) => m[1]).join('');
      return short ? prefix + keyNames.join('+') : (prefix ? prefix + ' ' : '') + keyNames.join(' + ');
    }
    case 0x02: {
      const u = consumerUsage(c) ?? 0;
      const n = consumerNames.get(u);
      if (n) return short ? n[0] : L(n[1], n[2]);
      const h = u.toString(16).toUpperCase().padStart(4, '0');
      return short ? 'Media' : L(`多媒体 0x${h}`, `Consumer 0x${h}`);
    }
    default:
      return short ? spacedHex(c) : L('设备码 ', 'Device code ') + spacedHex(c);
  }
}

// MARK: - 可选键

/**
 * 界面里的可选键，按组。allowsModifiers = 这一组的键能不能加修饰键做成组合键。
 * @returns {{id:string, title:string, codes:number[], allowsModifiers:boolean}[]}
 */
export function keyGroups() {
  const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i);
  const letters = [...range(0x04, 0x1d), ...range(0x1e, 0x27)].map((u) => key(u));
  const symbols = [0x35, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x36, 0x37, 0x38, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x39];
  const nav = [0x50, 0x52, 0x51, 0x4f, 0x4a, 0x4d, 0x4b, 0x4e, 0x4c, 0x49];
  const fkeys = [...range(0x3a, 0x45), 0x46, 0x47, 0x48, 0x65];
  const keypad = [0x53, 0x54, 0x55, 0x56, 0x57, 0x58, ...range(0x59, 0x63)];
  const mods = [...modifierNames.map((m) => modifier(m[0])), FN];
  const media = [0x00cd, 0x00b6, 0x00b5, 0x00b7, 0x00e2, 0x00ea, 0x00e9, 0x0070, 0x006f,
    0x0183, 0x018a, 0x0192, 0x0194, 0x0221, 0x0223, 0x0224, 0x0225, 0x0226, 0x0227, 0x022a];
  return [
    { id: 'letters', title: L('字母数字', 'Letters'), codes: letters, allowsModifiers: true },
    { id: 'symbols', title: L('符号编辑', 'Symbols'), codes: symbols.map((u) => key(u)), allowsModifiers: true },
    { id: 'nav', title: L('方向导航', 'Navigation'), codes: nav.map((u) => key(u)), allowsModifiers: true },
    { id: 'fkeys', title: L('F 键', 'F-keys'), codes: fkeys.map((u) => key(u)), allowsModifiers: true },
    { id: 'mods', title: L('修饰键', 'Modifiers'), codes: mods, allowsModifiers: false },
    { id: 'media', title: L('多媒体', 'Media'), codes: media.map(consumer), allowsModifiers: false },
    { id: 'board', title: L('键盘功能', 'Keyboard'), codes: boardFunctions.map((b) => b[0]), allowsModifiers: false },
    { id: 'keypad', title: L('小键盘', 'Keypad'), codes: keypad.map((u) => key(u)), allowsModifiers: true },
  ];
}
