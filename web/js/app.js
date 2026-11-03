import { L, isChinese, langParam } from './l10n.js';
import * as KC from './keycode.js';
import { KEYS, ROWS, WIDTH, factoryCode, keySpec } from './layout.js';
import { Keymap } from './keymap.js';
import { keymapFromWindowsProfile } from './windows-import.js';
import * as Dev from './device.js';

// 页面的全部状态与界面，对应 Mac app 的 AppModel + 各个 View。
// 配置存在本浏览器的 localStorage 里；文件格式与 Mac app / 命令行通用，可导入导出。

const STORE_KEYMAP = 'a66-keymap/keymap';
const STORE_LAST = 'a66-keymap/last-written';

function loadStored(k) {
  try {
    const s = localStorage.getItem(k);
    return s ? Keymap.fromJSON(s) : null;
  } catch { return null; }
}

function saveStored(k, keymap) {
  try { localStorage.setItem(k, keymap.toJSONString()); return true; } catch { return false; }
}

const S = {
  /** 正在编辑的配置，每次改动都存起来 */
  keymap: loadStored(STORE_KEYMAP) ?? Keymap.factory(),
  /** 键盘里现在的配置：上次成功写入、或从键盘读出来的；null = 这个浏览器还没写过也没读过 */
  lastWritten: loadStored(STORE_LAST),
  layer: 0,
  /** 正在弹出选择框的键 */
  editing: null,
  picker: { groupId: 'letters', mods: 0 },
  /** 已授权、连着的配置通道，已按 有线 > 蓝牙 > 2.4G 排序；读写只用第一个 */
  channels: [],
  busy: false,
  identifyText: null,
  identifyOK: false,
  /** 写入框：confirm | connecting | running | finished | failed */
  write: { phase: 'confirm', done: 0, total: 0, error: '' },
  rewriteAll: false,
  log: [],
  cancelFlag: null,
};

const supported = Dev.isSupported();
const channel = () => Dev.preferred(S.channels);
const isConnected = () => S.channels.length > 0;
const layerNames = () => [L('普通层', 'base'), L('Fn 层', 'Fn'), L('FN2 层', 'FN2')];

// MARK: - 小工具

/** 建元素：h('div', {class, onclick, ...}, 子元素…) */
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'checked' || k === 'value') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  fill(el, kids, false);
  return el;
}

/** 把子元素放进 el（replace = 先清空）。null / undefined / false / 0 都跳过，条件渲染可以直接写 cond && h(…)。 */
function fill(el, kids, replace = true) {
  const nodes = [kids].flat(Infinity).filter((c) => c != null && c !== false && c !== 0 && c !== '')
    .map((c) => (c instanceof Node ? c : String(c)));
  if (replace) el.replaceChildren(...nodes);
  else el.append(...nodes);
}

const $ = (id) => document.getElementById(id);

function showAlert(msg) {
  const d = $('alert-dialog');
  fill(d, [
    h('h2', null, L('出错了', 'Something went wrong')),
    h('p', { class: 'pre' }, msg),
    h('div', { class: 'actions' }, h('button', { class: 'primary', onclick: () => d.close() }, 'OK')),
  ]);
  d.showModal();
}

/** 确认框：点 okText 才执行 onOk */
function showConfirm(title, msg, okText, onOk) {
  const d = $('alert-dialog');
  fill(d, [
    h('h2', null, title),
    h('p', null, msg),
    h('div', { class: 'actions' },
      h('span', { class: 'push' }),
      h('button', { autofocus: true, onclick: () => d.close() }, L('取消', 'Cancel')),
      h('button', { class: 'primary', onclick: () => { d.close(); onOk(); } }, okText)),
  ]);
  d.showModal();
}

// MARK: - 状态操作

function setKeymap(k) {
  S.keymap = k;
  if (!saveStored(STORE_KEYMAP, k)) showAlert(L('浏览器保存不了配置（可能是无痕模式），关闭页面后改动会丢失，请先导出。',
    'This browser cannot save the keymap (private mode?). Export it before closing the page.'));
  render();
}

function edit(fn) {
  const k = S.keymap.clone();
  fn(k);
  setKeymap(k);
}

/** 在 Fn 层里，普通层是 Fn 的键必须保持 Fn（按住它才进得来） */
const isLocked = (key) => S.layer > 0 && S.keymap.code(0, key) === KC.FN;

/** 相对上次写入（没写过则相对出厂）的改动 */
const baseline = () => S.lastWritten ?? Keymap.factory();
const pendingChanges = () => S.keymap.changes(baseline());
const isPending = (layer, key) => S.keymap.code(layer, key) !== baseline().code(layer, key);

/** 这次要写的层：和原厂驱动一样只写有改动的层（协议最小单位是一整层）；没写过、或选了"全部重写"时三层都写 */
function layersToWrite() {
  if (!S.lastWritten || S.rewriteAll) return [0, 1, 2];
  return S.keymap.changedLayers(S.lastWritten);
}

async function refreshChannels() {
  const now = await Dev.channels();
  const same = now.length === S.channels.length && now.every((c, i) => c.device === S.channels[i].device);
  if (!same) {
    S.channels = now;
    if (!S.busy) S.identifyText = null;
    render();
  }
}

async function requestAccess() {
  try { await Dev.requestAccess(); } catch (e) {
    if (e?.name !== 'NotFoundError') showAlert(String(e?.message || e)); // NotFoundError = 用户在选择框里点了取消
  }
  await refreshChannels();
}

async function identify() {
  const ch = channel();
  if (!ch || S.busy) return;
  S.busy = true;
  S.identifyText = L('正在读取…', 'Reading…');
  render();
  let text, ok = false;
  try {
    const { link, password } = await Dev.connect(ch);
    await link.close();
    ok = Dev.isA66(password);
    text = ok ? L('✓ 已确认是 A66', '✓ A66 confirmed')
      : L(`✗ 不是 A66（${KC.hexBytes(password)}），不要写入`, `✗ Not an A66 (${KC.hexBytes(password)}); do not write`);
  } catch (e) {
    text = L('读取失败', 'Failed');
    showAlert(String(e?.message || e));
  }
  S.identifyText = text;
  S.identifyOK = ok;
  S.busy = false;
  render();
}

/** 读取会不会冲掉正在编辑的内容：当前配置既不是键盘里的、也不是默认的出厂键位 */
const readWouldDiscardEdits = () => !S.keymap.equals(S.lastWritten ?? Keymap.factory());

function readFromKeyboard() {
  if (!channel() || S.busy) return;
  if (!Dev.canRead(channel().connection)) { showAlert(Dev.bluetoothReadMessage()); return; }
  if (!readWouldDiscardEdits()) { performRead(); return; }
  showConfirm(L('从键盘读取？', 'Read from the keyboard?'),
    L('读取会覆盖还没写入的改动，需要的话先导出。',
      'Reading replaces your unwritten changes. Export first if needed.'),
    L('读取并替换', 'Read and replace'), performRead);
}

/** 读出 0–2 层，作为当前配置，同时记为"键盘里现在的配置" */
async function performRead() {
  const ch = channel();
  if (!ch || S.busy) return;
  S.busy = true;
  S.identifyText = L('正在读取键位…', 'Reading the keymap…');
  render();
  try {
    const { keymap, unknown } = await Dev.readKeymap(ch);
    S.lastWritten = keymap;
    saveStored(STORE_LAST, keymap);
    S.identifyText = L('✓ 已从键盘读取', '✓ Read from the keyboard');
    S.identifyOK = true;
    S.busy = false;
    setKeymap(keymap.clone());
    if (unknown.length) {
      showAlert(L(`键盘里有 ${unknown.length} 个位置不在 A66 的键位排列上（${unknown.map((u) => `第 ${u.layer} 层矩阵 ${u.index}`).join('、')}），已忽略。`,
        `${unknown.length} entries are not A66 key positions (${unknown.map((u) => `layer ${u.layer} matrix ${u.index}`).join(', ')}); ignored.`));
    }
  } catch (e) {
    S.identifyText = L('读取失败', 'Failed');
    S.identifyOK = false;
    S.busy = false;
    render();
    showAlert(String(e?.message || e));
  }
}

function beginWrite() {
  S.write = { phase: 'confirm', done: 0, total: 0, error: '' };
  S.log = [];
  S.rewriteAll = false;
  renderWrite();
  $('write-dialog').showModal();
}

async function performWrite() {
  const layers = layersToWrite();
  const ch = channel();
  if (!ch || S.busy || !layers.length) return;
  S.busy = true;
  const k = S.keymap.clone();
  const written = (S.lastWritten ?? k).replacing(layers, k);
  const flag = new Dev.CancelFlag();
  S.cancelFlag = flag;
  S.write = { phase: 'connecting', done: 0, total: 0, error: '' };
  S.log = [L('通道：', 'Channel: ') + Dev.channelTitle(ch)];
  render();
  try {
    const result = await Dev.write(k, layers, ch, {
      cancel: flag,
      log: (line) => { S.log.push(line); renderWrite(); },
      progress: (done, total) => { S.write = { phase: 'running', done, total, error: '' }; renderWrite(); },
    });
    S.lastWritten = written;
    saveStored(STORE_LAST, written);
    // note 为空 = 已读回核对一致；否则是没能核对的原因
    S.write = { phase: 'finished', done: 0, total: 0, error: '', note: result.verified ? '' : result.note };
    S.identifyText = L('✓ 已确认是 A66', '✓ A66 confirmed');
    S.identifyOK = true;
  } catch (e) {
    S.write = { phase: 'failed', done: 0, total: 0, error: String(e?.message || e) };
  }
  S.busy = false;
  S.cancelFlag = null;
  render();
}

// MARK: - 导入导出

function importFile(file) {
  file.arrayBuffer().then((buf) => {
    const k = file.name.toLowerCase().endsWith('.dct')
      ? keymapFromWindowsProfile(new Uint8Array(buf))
      : Keymap.fromJSON(new TextDecoder().decode(buf));
    setKeymap(k);
  }).catch((e) => showAlert(L('导入失败：', 'Import failed: ') + (e?.message || e)));
}

function exportFile() {
  const url = URL.createObjectURL(new Blob([S.keymap.toJSONString()], { type: 'application/json' }));
  const a = h('a', { href: url, download: 'a66-keymap.json' });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// MARK: - 界面

function render() {
  renderTop();
  renderMain();
  renderBottom();
  if ($('picker-dialog').open) renderPicker();
  if ($('write-dialog').open) renderWrite();
}

function renderTop() {
  const ch = channel();
  const status = [];
  if (!supported) {
    status.push(h('span', { class: 'dot off' }), h('span', { class: 'muted' }, L('这个浏览器不能连接键盘', 'This browser cannot reach the keyboard')));
  } else if (ch) {
    status.push(
      h('span', { class: 'dot on' }),
      h('span', null, L('已连接：', 'Connected: ') + Dev.channelTitle(ch)),
      // 换一种连接方式（第一次用某种方式时要在浏览器里选一次；之后键盘切换模式会自动识别）
      h('button', { class: 'link', onclick: requestAccess, disabled: S.busy }, L('换连接方式…', 'Change connection…')),
      h('button', { onclick: identify, disabled: S.busy }, L('核对型号', 'Check keyboard')),
      h('button', {
        onclick: readFromKeyboard, disabled: S.busy || !Dev.canRead(ch.connection),
        title: Dev.canRead(ch.connection) ? null : Dev.bluetoothReadMessage(),
      }, L('从键盘读取', 'Read from keyboard')),
      S.identifyText && h('span', { class: S.identifyOK ? 'ok-text small' : 'muted small' }, S.identifyText),
    );
  } else {
    status.push(
      h('span', { class: 'dot off' }),
      h('span', { class: 'muted' }, L('未连接键盘', 'Keyboard not connected')),
      h('button', { class: 'primary', onclick: requestAccess }, L('连接键盘…', 'Connect…')),
    );
  }

  const menu = h('details', { class: 'menu' },
    h('summary', null, L('配置', 'Keymap')),
    h('div', { class: 'menu-list' },
      h('button', { onclick: (e) => { closeMenu(e); $('import-input').click(); } }, L('导入…（.json 或 profile.dct）', 'Import… (.json or profile.dct)')),
      h('button', { onclick: (e) => { closeMenu(e); exportFile(); } }, L('导出…', 'Export…')),
      h('hr'),
      h('button', { onclick: (e) => { closeMenu(e); setKeymap(Keymap.factory()); } }, L('恢复出厂键位', 'Factory keymap')),
    ));

  fill($('top'), [
    h('div', { class: 'brand' }, h('img', { src: 'favicon.svg', alt: '', width: 22, height: 22 }), h('h1', null, L('A66 改键', 'A66 Keymap'))),
    h('div', { class: 'status' }, status),
    menu,
  ]);
}

function closeMenu(e) {
  e.target.closest('details')?.removeAttribute('open');
}

function renderMain() {
  const tabs = h('div', { class: 'segmented', role: 'tablist' },
    [[0, L('普通层', 'Base layer')], [1, L('按住 Fn', 'Fn layer')]].map(([l, t]) =>
      h('button', { role: 'tab', 'aria-selected': S.layer === l ? 'true' : 'false', onclick: () => { S.layer = l; render(); } }, t)));
  const legend = h('div', { class: 'legend' },
    h('span', null, h('i', { class: 'swatch' }), L('已改', 'Changed')),
    h('span', null, h('i', { class: 'pdot' }), L('未写入', 'Not written')));

  const banners = [];
  if (!supported) {
    banners.push(banner('warn', L('这个浏览器连不了键盘，请用电脑上的 Chrome 或 Edge 打开。',
      'This browser cannot connect to the keyboard. Use desktop Chrome or Edge.')));
  } else if (!channel()) {
    banners.push(banner('info', L('连上键盘（有线、蓝牙或 2.4G）后，点“连接键盘…”，在列表里选择它。每种连接方式只需选一次。',
      'Connect the keyboard (cable, Bluetooth or 2.4 GHz), click “Connect…” and pick it. Each connection type only needs this once.')
      + (Dev.isMac() ? L('Mac 上还要给浏览器开“输入监控”权限。', ' On a Mac, the browser also needs Input Monitoring permission.') : '')));
  }
  if (supported && !S.lastWritten) {
    banners.push(channel() && !Dev.canRead(channel().connection)
      ? banner('warn', L('下面是出厂键位，不是键盘里现在的键位。蓝牙下读不了，要读取请用有线或 2.4G。',
        'Shown below is the factory keymap, not the keyboard’s current one. It cannot be read over Bluetooth; use the cable or 2.4 GHz.'))
      : channel()
      ? banner('warn', L('下面是出厂键位，不是键盘里现在的键位，建议先从键盘读取。',
        'Shown below is the factory keymap, not the keyboard’s current one. Read from the keyboard first.'),
      [L('从键盘读取', 'Read from keyboard'), readFromKeyboard])
      : banner('info', L('下面是出厂键位。连上键盘后可以读出它现在的键位。',
        'Shown below is the factory keymap. Connect the keyboard to read its current one.')));
  }
  if (!S.keymap.hasFnKey) {
    banners.push(banner('danger', L('普通层没有 Fn 键，写入后将用不了 Fn 层的功能。',
      'No Fn key on the base layer; Fn-layer functions will be unreachable after writing.')));
  }
  if (S.keymap.code(1, 33) === KC.RESET_KEYBOARD) {
    banners.push(banner('warn', L('Fn+Caps 是“复位键盘”，按住约 5 秒会清掉所有改键，容易误触。',
      'Fn+Caps is “reset keyboard” (hold ~5 s to wipe all remapping) and is easy to hit by accident.'),
    [L('挪到 Fn+Del', 'Move to Fn+Del'), () => edit((k) => k.moveResetToFnDelete())]));
  }

  const keys = h('div', { class: 'keys' }, KEYS.map(keyCap));
  const hint = h('p', { class: 'muted small' }, S.layer === 0
    ? L('点一个键修改它的功能。',
      'Click a key to change it.')
    : L('按住 Fn 时各键的功能，空白表示没有功能。',
      'Functions while Fn is held; blank keys do nothing.'));

  fill($('main'), [
    h('div', { class: 'row' }, tabs, legend),
    banners.length && h('div', { class: 'banners' }, banners),
    h('div', { class: 'board' }, keys),
    hint,
  ]);
}

function banner(kind, text, action) {
  return h('div', { class: `banner ${kind}` },
    h('span', { class: 'banner-icon', 'aria-hidden': 'true' }, kind === 'info' ? 'i' : '!'),
    h('span', { class: 'banner-text' }, text),
    action && h('button', { onclick: action[1] }, action[0]));
}

function keyCap(spec) {
  const layer = S.layer;
  const code = S.keymap.code(layer, spec.id);
  const changed = !S.keymap.isFactory(layer, spec.id);
  const pending = isPending(layer, spec.id);
  const locked = isLocked(spec.id);
  // 普通层上没改过的键只写一行；其余情况左上角小字标出键帽
  const showLegend = (layer > 0 || changed) && !spec.isKnob;
  const text = code === KC.NONE ? (layer === 0 ? '—' : '') : KC.label(code);
  const size = [...text].length <= 2 ? 'big' : [...text].length <= 5 ? 'mid' : 'small';
  let tip = `K${spec.id} ${spec.legend}${isChinese ? '：' : ': '}${KC.name(code)}`;
  if (locked) tip += L('（Fn 键，在 Fn 层必须保持 Fn）', ' (Fn key; must stay Fn on the Fn layer)');
  const cls = ['key', size, changed && 'changed', locked && 'locked', spec.isKnob && 'knob',
    S.editing === spec.id && 'selected', showLegend && 'with-legend'].filter(Boolean).join(' ');
  return h('button', {
    class: cls,
    style: `left:${(spec.x / WIDTH) * 100}%;top:${(spec.y / ROWS) * 100}%;width:${(spec.w / WIDTH) * 100}%;height:${100 / ROWS}%`,
    title: tip,
    'aria-label': tip,
    'aria-disabled': locked ? 'true' : null,
    onclick: () => openPicker(spec.id),
  }, h('span', { class: 'cap' },
    showLegend && h('span', { class: 'legend-text' }, spec.legend),
    h('span', { class: 'label' }, text),
    pending && h('span', { class: 'pending' })));
}

function renderBottom() {
  const pending = pendingChanges().length;
  let left;
  if (!S.lastWritten) {
    left = h('span', { class: 'muted small' }, L('还没读取或写入过，写入会覆盖键盘里的全部键位。',
      'Not read or written yet; writing replaces the whole keymap.'));
  } else if (pending === 0) {
    left = h('span', { class: 'muted' }, '✓ ' + L('与上次写入键盘的一致', 'Matches what was last written'));
  } else {
    left = h('span', { class: 'pending-text' },
      h('span', null, L(`${pending} 处改动还没写进键盘`, `${pending} change(s) not yet written`)),
      h('button', { onclick: () => setKeymap(S.lastWritten.clone()) }, L('撤销这些改动', 'Discard')));
  }
  fill($('bottom'), [
    h('div', { class: 'bottom-left' }, left),
    h('button', {
      class: 'primary large', onclick: beginWrite, disabled: !isConnected() || S.busy,
      title: isConnected() ? null : L('先连接键盘', 'Connect the keyboard first'),
    }, L('写入键盘', 'Write to keyboard')),
  ]);
}

// MARK: - 选键框

function openPicker(id) {
  if (isLocked(id)) return;
  const cur = S.keymap.code(S.layer, id);
  S.editing = id;
  S.picker = { groupId: initialGroup(cur), mods: KC.usage(cur) ? KC.modifiers(cur) : 0 };
  renderPicker();
  $('picker-dialog').showModal();
  renderMain();
}

/** 打开时定位到当前值所在的组 */
function initialGroup(code) {
  const plain = KC.usage(code) ? KC.key(KC.usage(code)) : code;
  return KC.keyGroups().find((g) => g.codes.includes(plain))?.id ?? 'letters';
}

function choose(code) {
  const id = S.editing;
  $('picker-dialog').close();
  edit((k) => k.set(code, S.layer, id));
}

function renderPicker() {
  const id = S.editing;
  const spec = keySpec(id);
  if (!spec) return;
  const groups = KC.keyGroups();
  const group = groups.find((g) => g.id === S.picker.groupId) ?? groups[0];
  const current = S.keymap.code(S.layer, id);
  const factory = factoryCode(spec, S.layer);
  const mods = S.picker.mods;
  const wide = !group.allowsModifiers;

  const modRow = group.allowsModifiers && h('div', { class: 'mods' },
    h('span', { class: 'muted small' }, L('同时按住：', 'With:')),
    [[KC.Mod.leftControl, '⌃ Ctrl'], [KC.Mod.leftShift, '⇧ Shift'], [KC.Mod.leftOption, '⌥ Opt'], [KC.Mod.leftCommand, '⌘ Cmd']].map(([m, t]) =>
      h('button', {
        class: 'toggle', 'aria-pressed': mods & m ? 'true' : 'false',
        onclick: () => { S.picker.mods ^= m; renderPicker(); },
      }, t)),
    mods ? h('span', { class: 'accent-text small' }, L('将设为组合键', 'will set a combo')) : null);

  const grid = h('div', { class: `choices${wide ? ' wide' : ''}` }, group.codes.map((code) => {
    const target = group.allowsModifiers && mods ? KC.key(KC.usage(code), mods) : code;
    return h('button', {
      class: 'choice', 'aria-pressed': target === current ? 'true' : 'false', title: KC.name(code),
      // 打开选择框时焦点落在当前值上（没有则落在“关闭”）
      autofocus: target === current,
      onclick: () => choose(target),
    }, wide ? KC.name(code) : KC.label(code));
  }));

  fill($('picker-dialog'), [
    h('div', { class: 'picker-head' },
      h('h2', null, spec.legend),
      h('span', { class: 'muted' }, S.layer === 0 ? L('普通层', 'base layer') : L('按住 Fn', 'Fn layer')),
      h('span', { class: 'faint small push' }, `K${spec.id}`)),
    h('div', { class: 'picker-now small' },
      h('span', null, L('当前：', 'Now: ') + KC.name(current)),
      h('span', { class: 'muted' }, L('出厂：', 'Factory: ') + KC.name(factory))),
    h('div', { class: 'tabs' }, groups.map((g) => h('button', {
      'aria-pressed': g.id === group.id ? 'true' : 'false',
      onclick: () => { S.picker.groupId = g.id; renderPicker(); },
    }, g.title))),
    modRow,
    grid,
    group.id === 'board' && h('p', { class: 'muted small' }, L('“复位键盘”按住约 5 秒会清掉所有改键，建议放在不易误按的位置。',
      '“Reset keyboard” held ~5 s wipes all remapping; put it somewhere hard to hit by accident.')),
    h('div', { class: 'actions' },
      h('button', {
        disabled: current === factory,
        onclick: () => { $('picker-dialog').close(); edit((k) => k.resetToFactory(S.layer, id)); },
      }, L(`恢复出厂（${factory ? KC.label(factory) : '无'}）`, `Factory (${factory ? KC.label(factory) : 'none'})`)),
      h('button', { disabled: current === KC.NONE, onclick: () => choose(KC.NONE) }, L('设为无功能', 'No function')),
      h('span', { class: 'push' }),
      h('button', { autofocus: true, onclick: () => $('picker-dialog').close() }, L('关闭', 'Close'))),
  ]);
}

// MARK: - 写入框

function renderWrite() {
  const d = $('write-dialog');
  const ch = channel();
  const w = S.write;
  const body = [];
  const logView = () => S.log.length > 0 && h('pre', { class: 'log' }, S.log.join('\n'));

  if (w.phase === 'confirm') {
    const changes = S.keymap.changes(baseline());
    const ls = layersToWrite();
    if (ch) body.push(h('p', null, layersText(ch, ls)));
    else body.push(h('p', { class: 'danger-text' }, L('键盘已断开，先重新连接。', 'The keyboard is disconnected; reconnect it first.')));
    // 蓝牙、2.4G 下 Karabiner 开着 Modify events 会独占改键通道（2.4G 是 11-03 实测发现的；有线没实测，不提示）
    if ((ch?.connection === 'bluetooth' || ch?.connection === 'receiver') && Dev.isMac()) {
      const target = ch.connection === 'receiver' ? L('“2.4G Wireless Receiver”', '“2.4G Wireless Receiver”') : L('这把键盘', 'this keyboard');
      body.push(h('p', { class: 'muted small' }, L(`用了 Karabiner-Elements 的话，先在它的 Devices 里关掉${target}的 Modify events，写完再打开。`,
        `Using Karabiner-Elements? Turn off Modify events for ${target} in its Devices tab first, and back on afterwards.`)));
    }
    body.push(h('p', { class: 'muted small' }, S.lastWritten
      ? L('与上次写入相比的改动：', 'Changes since the last write:')
      : L('与出厂键位相比的改动：', 'Changes compared with the factory keymap:')));
    body.push(changes.length === 0
      ? h('p', { class: 'small' }, L('没有改动。', 'No changes.'))
      : h('div', { class: 'changes' }, changes.map((c) => h('div', { class: 'change' },
        h('span', { class: 'faint' }, c.layer === 0 ? L('普通', 'Base') : c.layer === 1 ? 'Fn' : 'FN2'),
        h('span', null, keySpec(c.key).legend),
        h('span', { class: 'muted' }, KC.name(c.from)),
        h('span', { class: 'faint' }, '→'),
        h('span', { class: 'accent-text' }, KC.name(c.to))))));
    if (!S.keymap.hasFnKey) {
      body.push(banner('danger', L('普通层没有 Fn 键，写入后进不了 Fn 层。', 'No Fn key on the base layer; the Fn layer will be unreachable.')));
    }
    for (const r of S.keymap.resetKeys) {
      body.push(h('p', { class: 'muted small' }, L('复位键在：', 'Reset key: ') + (r.layer === 1 ? 'Fn + ' : '') + keySpec(r.key).legend
        + L('（按住约 5 秒清回出厂）', ' (hold ~5 s to restore factory)')));
    }
    if (S.lastWritten) {
      body.push(h('label', { class: 'check small' },
        h('input', { type: 'checkbox', checked: S.rewriteAll, onchange: (e) => { S.rewriteAll = e.target.checked; renderWrite(); } }),
        L('全部重写 3 层（键盘被复位过或在别处改过键时勾上）', 'Rewrite all 3 layers (after a keyboard reset or remapping elsewhere)')));
    }
    body.push(h('div', { class: 'actions' },
      h('span', { class: 'push' }),
      h('button', { onclick: () => d.close() }, L('取消', 'Cancel')),
      h('button', { class: 'primary', disabled: !ch || ls.length === 0 || S.busy, onclick: performWrite }, L('写入', 'Write'))));
  } else if (w.phase === 'connecting') {
    body.push(h('p', { class: 'busy-line' }, h('span', { class: 'spinner' }),
      L('正在连接键盘…（空闲后要先唤醒，最多等 20 秒）', 'Connecting… (an idle keyboard needs waking, up to 20 s)')));
    body.push(logView());
    body.push(h('div', { class: 'actions' }, h('span', { class: 'push' }),
      h('button', { onclick: () => S.cancelFlag?.cancel() }, L('取消', 'Cancel'))));
  } else if (w.phase === 'running') {
    body.push(h('progress', { max: Math.max(w.total, 1), value: w.done }));
    body.push(h('p', { class: 'small' }, w.total > 0 && w.done === w.total
      ? L('已写完，正在读回核对…', 'Written; verifying by reading back…')
      : L(`正在写入… ${w.done}/${w.total} 包。别拔线、别关键盘，也别切走这个页面。`,
        `Writing… ${w.done}/${w.total} packets. Don’t disconnect, and keep this tab in front.`)));
    body.push(logView());
  } else if (w.phase === 'finished') {
    if (w.note) {
      body.push(h('p', { class: 'accent-text' }, '! ' + L('写入完成，但没能读回核对。按几个改过的键确认一下。', 'Written, but could not verify by reading back. Try a few changed keys.')));
      body.push(h('p', { class: 'pre small muted' }, w.note));
    } else {
      body.push(h('p', { class: 'ok-text' }, '✓ ' + L('写入完成，已读回核对一致。', 'Done and verified by reading back.')));
    }
    body.push(logView());
    body.push(h('div', { class: 'actions' }, h('span', { class: 'push' }),
      h('button', { class: 'primary', onclick: () => d.close() }, L('好', 'OK'))));
  } else {
    body.push(h('p', { class: 'danger-text' }, '✕ ' + L('写入失败', 'Write failed')));
    body.push(h('p', { class: 'pre small' }, w.error));
    body.push(logView());
    body.push(h('div', { class: 'actions' }, h('span', { class: 'push' }),
      h('button', { onclick: () => d.close() }, L('关闭', 'Close')),
      h('button', { class: 'primary', disabled: !ch || S.busy, onclick: performWrite }, L('重试', 'Retry'))));
  }
  fill(d, [h('h2', null, L('写入键盘', 'Write to keyboard')), body]);
}

function layersText(ch, ls) {
  const title = Dev.channelTitle(ch);
  const check = Dev.canRead(ch.connection)
    ? L('写入前核对型号，写完读回核对。', 'The keyboard ID is checked first and the result is verified by reading back.')
    : L('写入前核对型号。蓝牙下写完不能读回核对。',
      'The keyboard ID is checked first. Over Bluetooth the result cannot be read back to verify.');
  if (ls.length === 0) return L('与上次写入一致，没有要写的层。', 'Nothing changed since the last write.');
  if (ls.length === 3) return L(`通过${title}写入全部 3 层。`, `Writes all 3 layers over ${title}. `) + check;
  const names = ls.map((l) => layerNames()[l]);
  return L(`通过${title}只写有改动的层：${names.join('、')}（和原厂驱动一样，协议最小单位是一整层）。`,
    `Writes only the changed layer(s) over ${title}: ${names.join(', ')} (like the vendor driver; a layer is the smallest unit). `) + check;
}

// MARK: - 说明

function renderHelp() {
  const item = (q, ...a) => h('details', null, h('summary', null, q), ...a.map((p) => h('p', null, p)));
  fill($('help'), [
    h('h2', null, L('说明', 'Notes')),
    item(L('能用哪些浏览器？', 'Which browsers work?'),
      L('电脑上的 Chrome 或 Edge（Windows、macOS、Linux 均可）。Safari、Firefox 和手机浏览器不支持。',
        'Desktop Chrome or Edge (Windows, macOS or Linux). Safari, Firefox and mobile browsers are not supported.')),
    item(L('macOS 上连接失败？', 'Connection fails on macOS?'),
      L('用了 Karabiner-Elements 的话，它会占住键盘，浏览器就打不开。在它的 Devices 里临时关掉这把键盘（2.4G 下是“2.4G Wireless Receiver”）的 Modify events，刷新页面再试，写完再打开。',
        'Karabiner-Elements can hold the keyboard so the browser cannot open it. Temporarily turn off Modify events for the keyboard (over 2.4 GHz: “2.4G Wireless Receiver”) in its Devices tab, reload the page, and turn it back on after writing.'),
      L('还要给浏览器开“输入监控”权限：系统设置 → 隐私与安全性 → 输入监控，打开浏览器，然后完全退出浏览器（⌘Q）再打开。',
        'The browser also needs Input Monitoring permission: System Settings → Privacy & Security → Input Monitoring, enable the browser, then quit it completely (⌘Q) and reopen.')),
    item(L('蓝牙模式能做什么？', 'What works over Bluetooth?'),
      L('蓝牙下可以改键写入，但读不了键盘里的键位，这是键盘固件的限制。要读取请用有线或 2.4G。',
        'Over Bluetooth you can write remaps, but the keymap cannot be read back; this is a keyboard firmware limitation. To read, use the cable or 2.4 GHz.'),
      L('蓝牙列表里的 A66 5.0 和 A66 3.0 是同一把键盘，推荐连 A66 5.0，不推荐 A66 3.0。',
        'A66 5.0 and A66 3.0 in the Bluetooth list are the same keyboard. Use A66 5.0; A66 3.0 is not recommended.')),
    item(L('显示的键位和键盘里的不一样？', 'The page does not match my keyboard?'),
      L('页面显示的是这个浏览器保存的配置。在别处改过键后，点“从键盘读取”（有线或 2.4G）。',
        'The page shows the keymap saved in this browser. After remapping elsewhere, click “Read from keyboard” (cable or 2.4 GHz).')),
    item(L('改键为什么会莫名丢失？', 'Why do my remaps disappear?'),
      L('出厂的 Fn + Caps Lock 是“复位键盘”：按住约 5 秒，所有改键被清回出厂。',
        'Factory Fn + Caps Lock is “reset keyboard”: holding it ~5 s restores the factory keymap.')),
    item(L('安全吗？', 'Is it safe?'),
      L('只读写键位、读型号，不碰固件。每次读写前都会核对型号，不是 A66 就不操作。所有操作都在本机浏览器里完成，不上传任何数据。',
        'Only reads/writes the keymap and reads the keyboard ID; nothing firmware-related. The ID is checked before every read or write. Everything runs in your browser; nothing is uploaded.'),
      L('本工具与键盘厂商无关，非官方，使用风险自负。不支持宏和灯效设置。',
        'Unofficial and not affiliated with the keyboard maker; use at your own risk. Macros and lighting are not supported.')),
  ]);
}

// MARK: - 启动

function init() {
  document.documentElement.lang = isChinese ? 'zh-CN' : 'en';
  // 标题、描述、规范网址给搜索引擎看（页面里写的是中文版的，英文界面换成英文）
  document.title = L('新盟 A66 键盘改键工具：Mac 也能用的网页版驱动 · A66 Keymap', 'A66 Keymap · Mac & web key remapper for the A66 tri-mode keyboard');
  document.querySelector('meta[name="description"]')?.setAttribute('content', L(
    '新盟 A66 三模机械键盘的网页版改键工具，可以代替只有 Windows 版的官方驱动。Mac、Windows、Linux 上用 Chrome 或 Edge 打开就能改键，有线、蓝牙、2.4G 都能写入，不用安装。',
    'A web-based alternative to the Windows-only driver of the A66 tri-mode mechanical keyboard: remap keys on macOS, Windows or Linux in Chrome or Edge, over USB, Bluetooth or 2.4 GHz. Nothing to install.'));
  const canonical = document.createElement('link');
  canonical.rel = 'canonical';
  canonical.href = 'https://www.neilpoly.top/a66/' + (langParam ? `?lang=${langParam}` : '');
  document.head.append(canonical);
  // 页脚的语言切换：链到另一种语言的固定网址
  const sw = $('lang-switch');
  sw.href = isChinese ? '?lang=en' : '?lang=zh';
  sw.hreflang = isChinese ? 'en' : 'zh-Hans';
  sw.textContent = isChinese ? 'English' : '中文';
  if (!loadStored(STORE_KEYMAP)) saveStored(STORE_KEYMAP, S.keymap);

  $('import-input').addEventListener('change', (e) => {
    const f = e.target.files?.[0];
    e.target.value = '';
    if (f) importFile(f);
  });
  $('picker-dialog').addEventListener('close', () => { S.editing = null; renderMain(); });
  $('write-dialog').addEventListener('cancel', (e) => {
    // 连接中按 Esc = 取消；写入中不让关
    if (S.write.phase === 'connecting') { e.preventDefault(); S.cancelFlag?.cancel(); }
    else if (S.write.phase === 'running') e.preventDefault();
  });
  window.addEventListener('beforeunload', (e) => { if (S.busy) e.preventDefault(); });
  // 其他标签页改了配置时同步过来
  window.addEventListener('storage', (e) => {
    if (e.key === STORE_KEYMAP) S.keymap = loadStored(STORE_KEYMAP) ?? S.keymap;
    else if (e.key === STORE_LAST) S.lastWritten = loadStored(STORE_LAST);
    else return;
    render();
  });
  $('footer-note').textContent = L('非官方工具，与键盘厂商无关，仅供个人非商业使用，风险自负。',
    'Unofficial; not affiliated with the keyboard maker. Personal, non-commercial use only, at your own risk.');

  renderHelp();
  render();
  if (supported) {
    navigator.hid.addEventListener('connect', refreshChannels);
    navigator.hid.addEventListener('disconnect', refreshChannels);
    refreshChannels();
  }
}

init();
