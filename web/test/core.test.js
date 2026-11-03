// 与 Tests/A66CoreTests 相同的用例，保证网页版和 Swift 版行为一致。运行：cd web && npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as KC from '../js/keycode.js';
import { KEYS, WIDTH, ROWS, keySpec } from '../js/layout.js';
import { Keymap, MATRIX_ENTRIES } from '../js/keymap.js';
import { Wired, Wireless } from '../js/packets.js';
import { canRead, channelTitle, classify, isA66 } from '../js/device.js';

const hex = (b) => KC.hexBytes(b);

test('键编号连续、矩阵号不重复', () => {
  assert.equal(KEYS.length, 67);
  assert.deepEqual(KEYS.map((k) => k.id), Array.from({ length: 67 }, (_, i) => i + 1));
  const m = KEYS.map((k) => k.matrix);
  assert.equal(new Set(m).size, m.length);
  assert.ok(m.every((v) => v >= 0 && v < MATRIX_ENTRIES - 1));
});

test('同一行的键不重叠', () => {
  for (let row = 0; row < ROWS; row++) {
    const ks = KEYS.filter((k) => k.y === row).sort((a, b) => a.x - b.x);
    for (let i = 1; i < ks.length; i++) assert.ok(ks[i - 1].x + ks[i - 1].w <= ks[i].x + 1e-9, `K${ks[i - 1].id} / K${ks[i].id}`);
    assert.ok(ks.at(-1).x + ks.at(-1).w <= WIDTH);
  }
});

test('出厂有 Fn 和复位键', () => {
  assert.equal(keySpec(64).factoryBase, KC.FN);
  assert.equal(keySpec(33).factoryFn, KC.RESET_KEYBOARD);
});

test('设备码编码', () => {
  assert.deepEqual(KC.bytes(KC.key(0x29)), [0x00, 0x00, 0x00, 0x29]);
  assert.deepEqual(KC.bytes(KC.key(0x50, KC.Mod.leftCommand)), [0x00, 0x08, 0x00, 0x50]);
  assert.deepEqual(KC.bytes(KC.modifier(KC.Mod.leftControl)), [0x00, 0x01, 0x00, 0x00]);
  assert.deepEqual(KC.bytes(KC.consumer(0x00cd)), [0x02, 0x00, 0x00, 0xcd]);
  assert.deepEqual(KC.bytes(KC.consumer(0x0183)), [0x02, 0x00, 0x01, 0x83]);
  assert.deepEqual(KC.bytes(KC.FN), [0x0d, 0x00, 0x00, 0x00]);
  assert.equal(KC.fromHex('07 00 00 04'), KC.RESET_KEYBOARD);
  assert.equal(KC.fromHex('0700004'), null);
  assert.equal(KC.bytes(KC.key(0x50, 0x80))[1], 0x80);
});

test('键名', () => {
  assert.equal(KC.label(KC.key(0x50, KC.Mod.leftCommand)), '⌘←');
  assert.equal(KC.label(KC.modifier(KC.Mod.leftControl)), '⌃ Ctrl');
  assert.equal(KC.label(KC.modifier(KC.Mod.rightOption)), 'R⌥ Opt');
  // 键帽短名一般不分语言，只有复位跟随界面语言（中文“复位”，英文“Reset”）
  assert.ok(['复位', 'Reset'].includes(KC.label(KC.RESET_KEYBOARD)));
  assert.equal(KC.label(KC.NONE), '');
  for (const g of KC.keyGroups()) {
    for (const c of g.codes) {
      assert.ok(KC.label(c).length > 0);
      assert.ok(!KC.name(c).startsWith('设备码') && !KC.name(c).startsWith('Device code'), KC.spacedHex(c));
    }
  }
});

test('出厂键位表', () => {
  const m = Keymap.factory().matrix(0);
  assert.equal(m.length, 512);
  assert.deepEqual([...m.slice(4, 8)], [0x00, 0x00, 0x00, 0x29]); // Esc 在矩阵 1
  assert.deepEqual([...m.slice(59 * 4, 59 * 4 + 4)], [0x0d, 0x00, 0x00, 0x00]); // Fn 在矩阵 59
  assert.deepEqual([...m.slice(-4)], [0x00, 0x00, 0x5a, 0xa5]);
  assert.equal(Keymap.factory().matrix(2).filter((v) => v !== 0).length, 2);
});

test('无线首包', () => {
  const p = Wireless.writePackets(Wireless.Command.setMatrix, 0, Keymap.factory().matrix(0));
  assert.equal(p.length, 37);
  assert.equal(hex(p[0]), '13 01 25 00 0E 00 00 00 00 00 00 00 29 00 00 00 2B 00 00 9B');
  assert.equal(p[36][4], 0x08);
  assert.equal(hex(Wireless.readRequest(Wireless.Command.readPassword)), '13 05 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 19');
});

test('有线报文', () => {
  const p = Wired.packets(Wired.Command.setMatrix, 1, Keymap.factory().matrix(1));
  assert.equal(p.length, 1);
  assert.equal(p[0].length, 520);
  assert.deepEqual([...p[0].slice(0, 8)], [0x06, 0x03, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02]);
  assert.equal(hex(Wired.readRequest(Wired.Command.readPassword, 1, 6).slice(0, 8)), '06 82 01 00 01 00 06 00');
});

test('只发登记过的命令', () => {
  assert.throws(() => Wired.packets(0x7f, 0, [1]));
  assert.throws(() => Wired.readRequest(0x01, 0, 6));
  assert.throws(() => Wireless.writePackets(0x03, 0, [1]));
  assert.throws(() => Wireless.readRequest(0x82));
});

test('应答判定', () => {
  const ack = new Uint8Array(20); ack[0] = 0x13; ack[1] = 0x01;
  assert.equal(Wireless.classifyAck(ack, 0x01), 'ok');
  ack[2] = 0x80;
  assert.equal(Wireless.classifyAck(ack, 0x01), 'crcError');
  const part = Wireless.seal(Uint8Array.from([0x13, 0x05, 0x01, 0x00, 0x06, 3, 0, 0, 0, 0, 0xd9, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
  const r = Wireless.parseReadPart(part);
  const broken = part.slice(); broken[19] ^= 1;
  assert.equal(Wireless.parseReadPart(broken), null); // 校验和不对的包丢掉
  assert.deepEqual(r.data, [3, 0, 0, 0, 0, 0xd9]);
  assert.ok(isA66(r.data));
  assert.ok(!isA66([3, 0, 0, 0, 0, 0xd8]));
});

test('Fn 联动到 Fn 层', () => {
  const k = Keymap.factory();
  k.set(KC.FN, 0, 59);
  assert.equal(k.code(1, 59), KC.FN);
  assert.equal(k.code(2, 59), KC.FN);
  k.set(KC.modifier(KC.Mod.leftControl), 0, 59);
  assert.ok(k.equals(Keymap.factory()));
});

test('复位键挪到 Fn+Del', () => {
  const k = Keymap.factory();
  k.set(KC.modifier(KC.Mod.leftControl), 0, 33);
  k.moveResetToFnDelete();
  assert.equal(k.code(1, 33), KC.modifier(KC.Mod.leftControl));
  assert.equal(k.code(1, 31), KC.RESET_KEYBOARD);
  assert.deepEqual(k.resetKeys.map((r) => r.key), [31]);
  assert.equal(Keymap.recommended().code(1, 33), KC.key(0x39));
});

test('JSON 往返', () => {
  const k = Keymap.recommended();
  k.set(KC.key(0x4a), 0, 16);
  const back = Keymap.fromJSON(k.toJSONString());
  assert.ok(back.equals(k));
  assert.equal(back.changes(Keymap.recommended()).length, 1);
  assert.deepEqual(back.changedLayers(Keymap.recommended()), [0]);
});

test('只写有改动的层', () => {
  const last = Keymap.recommended();
  const k = last.clone();
  k.set(KC.key(0x4a), 0, 16);
  assert.deepEqual(k.changedLayers(last), [0]);
  k.set(KC.FN, 0, 59); // Fn 联动到第 1、2 层
  assert.deepEqual(k.changedLayers(last), [0, 1, 2]);
  const written = last.replacing([0], k);
  assert.equal(written.code(0, 16), KC.key(0x4a));
  assert.equal(written.code(1, 59), last.code(1, 59));
});

test('拒绝不认识的 JSON', () => {
  assert.throws(() => Keymap.fromJSON('{"format":"x","version":1,"layers":[]}'));
  assert.throws(() => Keymap.fromJSON('{"format":"a66-keymap","version":1,"layers":[{"K99":"00000004"}]}'));
  assert.throws(() => Keymap.fromJSON('{"format":"a66-keymap","version":2,"layers":[]}'));
  assert.throws(() => Keymap.fromJSON('not json'));
});

test('识别连接方式', () => {
  const col = (usagePage, usage) => ({ usagePage, usage, children: [] });
  assert.equal(classify({ vendorId: 0x258a, productId: 0x010c, collections: [col(1, 6), col(0xff00, 1)] }), 'wired');
  assert.equal(classify({ vendorId: 0x3554, productId: 0xfa09, collections: [col(0xff02, 2)] }), 'receiver');
  assert.equal(classify({ vendorId: 0x3554, productId: 0xfa07, collections: [col(1, 6), col(0xff02, 2)] }), 'bluetooth');
  // 经典蓝牙 "A66 3.0"：同样的配置通道，当作蓝牙（能写、不读）
  assert.equal(classify({ vendorId: 0x3554, productId: 0xfa08, collections: [col(1, 6), col(0xff02, 2)] }), 'bluetooth');
  assert.equal(classify({ vendorId: 0x3554, productId: 0xfa09, collections: [col(1, 6)] }), null);
  assert.equal(classify({ vendorId: 0x258a, productId: 0x0001, collections: [col(0xff00, 1)] }), null);
});

test('读键位：有线请求与回包', () => {
  const req = Wired.readRequest(Wired.Command.readMatrix, 1, 512);
  assert.equal(req.length, 520);
  assert.equal(hex(req.slice(0, 8)), '06 83 01 00 01 00 00 02');
  const m = Keymap.recommended().matrix(1);
  const rsp = new Uint8Array(520); rsp.set(req.slice(0, 8)); rsp.set(m, 8);
  assert.deepEqual([...Wired.matrixReply(rsp, 1)], [...m]);
  assert.equal(Wired.matrixReply(rsp, 0), null); // 层号对不上
  const bad = rsp.slice(); bad[519] = 0;
  assert.equal(Wired.matrixReply(bad, 1), null); // 没有 5A A5
  const echo = rsp.slice(); echo[1] = 0x82;
  assert.equal(Wired.matrixReply(echo, 1), null); // 不是读键位的回包
});

test('读键位：无线请求与回包', () => {
  assert.equal(hex(Wireless.readRequest(Wireless.Command.readMatrix, 2)), '13 41 01 00 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 75');
  // 2.4G 实测的第 1 层首包
  const r = Uint8Array.from([0x13, 0x41, 0x24, 0x00, 0x1e, 0, 0, 0, 0, 0, 0, 0, 0x35, 0x07, 0, 0, 0x12, 0, 0x01, 0xe5]);
  const p = Wireless.parseReadPart(r);
  assert.equal(p.cmd, 0x41); assert.equal(p.total, 36); assert.equal(p.index, 0); assert.equal(p.sub, 1);
  assert.equal(p.data.length, 14); assert.equal(p.crcError, false);
});

test('读回的键位表转成配置', () => {
  const k = Keymap.recommended();
  const wired = [0, 1, 2].map((l) => k.matrix(l));
  assert.ok(Keymap.fromMatrices(wired).keymap.equals(k));
  assert.equal(Keymap.fromMatrices(wired).unknown.length, 0);
  const wireless = wired.map((m) => m.slice(0, Wireless.matrixReadBytes));
  assert.ok(Keymap.fromMatrices(wireless).keymap.equals(k));
  assert.ok(wireless.every((m, l) => k.matches(m, l)));
  const other = k.clone(); other.set(KC.key(0x4a), 0, 16);
  assert.ok(!other.matches(wireless[0], 0));
  assert.ok(!k.matches(wired[0].slice(0, 100), 0)); // 太短不算
  const odd = wired.map((m) => m.slice()); odd[2].set([0, 0, 0, 4], 0); // 矩阵 0 不是 A66 的键
  const r = Keymap.fromMatrices(odd);
  assert.ok(r.keymap.equals(k));
  assert.deepEqual(r.unknown, [{ layer: 2, index: 0, code: KC.key(0x04) }]);
});

test('蓝牙不读键位', () => {
  assert.equal(canRead('wired'), true);
  assert.equal(canRead('receiver'), true);
  assert.equal(canRead('bluetooth'), false);
});

test('通道名区分蓝牙 5.0 / 3.0', () => {
  const ch = (connection, productId) => ({ connection, device: { productId } });
  assert.match(channelTitle(ch('bluetooth', 0xfa07)), /5\.0/);
  assert.match(channelTitle(ch('bluetooth', 0xfa08)), /3\.0/);
  assert.doesNotMatch(channelTitle(ch('bluetooth', 0xfa0b)), /\d\.0/);
  assert.ok(channelTitle(ch('receiver', 0xfa09)).length > 0);
  assert.ok(channelTitle(ch('wired', 0x010c)).length > 0);
});
