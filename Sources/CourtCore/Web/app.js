// Zacks Court browser display (docs/web-display.md). A thin client: the camera owns the session,
// recordings and shot rows; this page shows them and sends requests the camera answers.
import { hmacSHA256Hex, uuid } from "./hmac.js";

const $ = (id) => document.getElementById(id);
const PROTOCOL = 2;
const STROKES = {
  groundstroke: "落地击球", forehand: "正手", backhand: "反手", serve: "发球",
  volley: "截击", overhead: "高压", feed: "喂球", unknown: "待确认",
};
const STROKE_ORDER = Object.keys(STROKES);
// Same words as the App (SessionState.courtTitle, CameraStatusPanel.thermalTitle).
const SESSION_STATES = { active: "进行中", paused: "已暂停", completed: "已完成", interrupted: "意外中断" };
const THERMAL = { nominal: "正常", fair: "偏暖", serious: "偏高", critical: "过热" };
const BACKOFF = [0.5, 1, 2, 4, 8];
const TOKEN_KEY = `court.web.token.${location.host}`;
/// Shot lists grow page by page: an hour of play is thousands of rows, and each row may hold a player.
const PAGE = (() => {
  // ?page=N (5–100) only changes the page size, for checking paging on a short session.
  const size = Number(new URLSearchParams(location.search).get("page"));
  return Number.isInteger(size) && size >= 5 && size <= 100 ? size : 30;
})();

const state = {
  socket: null, connected: false, attempt: 0, retry: null, closedByUs: false,
  token: null, access: null, nonce: null,
  camera: null, status: null, session: null, clockOffset: 0,
  sessionRows: new Map(), recentRows: new Map(), recentCalibration: null,
  waiters: new Map(),
  previewOn: false, previewURL: null, lastFrameAt: 0,
  renderQueued: false, lastRender: 0,
  history: [],
  liveLimit: PAGE, liveSession: null,
  detail: { rows: [], sessionID: null, limit: PAGE },
  // Session command waiting for the camera's reply; the session buttons wait with it.
  pending: null,
  // Status reports that disagreed with the session shown, and the throttled repair (see agree()).
  disagreements: 0, repairs: 0, nextRepairAt: 0, repairing: false,
};

// MARK: Storage (wrapped: private windows may refuse it)

function load(key) { try { return sessionStorage.getItem(key) || localStorage.getItem(key); } catch { return null; } }
function save(key, value) {
  for (const store of [sessionStorage, localStorage]) {
    try { if (value) store.setItem(key, value); else store.removeItem(key); } catch { /* storage unavailable */ }
  }
}

// MARK: Formatting

const esc = (text) => String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const validSpeed = (value) => typeof value === "number" && Number.isFinite(value) && value > 0;
const speedText = (value) => (validSpeed(value) ? Math.round(value).toString() : "—");
const strokeColor = (kind) => `var(--${STROKES[kind] ? kind : "unknown"})`;
function duration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const total = Math.floor(seconds), h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}
function dateText(ms) {
  if (!ms) return "—";
  return new Date(ms).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}
const hasPlacement = (shot) => Number.isFinite(shot?.bounce?.xMeters) && Number.isFinite(shot?.bounce?.yMeters);
/// The camera sends the App's plain wording (TennisReason); an older camera sends only its engine
/// wording, which is shown as a last resort rather than nothing.
const speedReason = (shot) => shot?.speedReasonText || (shot?.speedReason?.startsWith("等待") ? "还在分析" : shot?.speedReason) || "暂时无法给出";
const placementReason = (shot) => shot?.placementReasonText || (shot?.bounce?.reason?.startsWith("等待") ? "还在分析" : shot?.bounce?.reason) || "没看到球落地";
const strokeTag = (kind) => `<span class="tag" style="--c:${strokeColor(kind)}">${STROKES[kind] || "待确认"}</span>`;
/// The stroke's mark on the court map, the same shapes as the App (TennisStrokeKind.courtMarkPath):
/// circle, square, triangle, diamond, pentagon, cross, plus and star, so colour is never the only cue.
function markPath(kind, cx, cy, r) {
  const poly = (n, rot, radius, dy = 0) => Array.from({ length: n }, (_, i) => {
    const a = rot + (i * 2 * Math.PI) / n;
    return [cx + radius * Math.cos(a), cy + dy + radius * Math.sin(a)];
  });
  const close = (pts) => `M${pts.map(([x, y]) => `${x.toFixed(3)},${y.toFixed(3)}`).join("L")}Z`;
  const up = -Math.PI / 2;
  switch (kind) {
    case "forehand": return `M${cx - r},${cy}a${r},${r} 0 1,0 ${2 * r},0a${r},${r} 0 1,0 ${-2 * r},0Z`;
    case "backhand": { const h = r * 0.875; return close([[cx - h, cy - h], [cx + h, cy - h], [cx + h, cy + h], [cx - h, cy + h]]); }
    case "serve": return close(poly(3, up, r * 1.2, r * 0.2));
    case "volley": return close(poly(4, up, r * 1.25));
    case "overhead": return close(poly(5, up, r * 1.15));
    case "groundstroke": case "feed": {
      const arm = r * 1.15, half = r * 0.38, turn = kind === "groundstroke" ? Math.PI / 4 : 0;
      const rotate = ([x, y]) => [cx + (x - cx) * Math.cos(turn) - (y - cy) * Math.sin(turn), cy + (x - cx) * Math.sin(turn) + (y - cy) * Math.cos(turn)];
      const arms = [[cx - half, cy - arm], [cx + half, cy - arm], [cx + half, cy - half], [cx + arm, cy - half], [cx + arm, cy + half],
        [cx + half, cy + half], [cx + half, cy + arm], [cx - half, cy + arm], [cx - half, cy + half], [cx - arm, cy + half],
        [cx - arm, cy - half], [cx - half, cy - half]];
      return close(arms.map(rotate));
    }
    default: {
      const outer = poly(5, up, r * 1.3), inner = poly(5, up + Math.PI / 5, r * 0.55);
      return close(outer.flatMap((p, i) => [p, inner[i]]));
    }
  }
}
const markIcon = (kind) => `<svg class="mark" viewBox="-1.5 -1.5 3 3" aria-hidden="true"><path d="${markPath(kind, 0, 0, 1)}" fill="${strokeColor(kind)}"/></svg>`;
/// Half and area of the court from the near baseline (y = 0), as the App says it (courtZone).
function courtZone(x, y) {
  const W = 10.97, L = 23.77, net = L / 2;
  if (!(x >= 0 && x <= W && y >= 0 && y <= L)) return "场外";
  const singles = x >= 1.37 && x <= W - 1.37;
  return (y < net ? "近端半场" : "远端半场") + (!singles ? "双打边线区" : Math.abs(y - net) <= 6.4 ? "发球区" : "后场");
}
/// What a screen reader says for one bounce: shot number, stroke, speed when known, rough placement.
function bounceLabel(shot, number) {
  const x = shot.bounce.xMeters, y = shot.bounce.yMeters;
  return [`第 ${number} 拍`, STROKES[shot.stroke] || "待确认", validSpeed(shot.speedKPH) ? `约 ${speedText(shot.speedKPH)} 千米每小时` : "暂无球速",
    courtZone(x, y), `约横 ${x.toFixed(1)} 米、纵 ${y.toFixed(1)} 米`].join("，");
}
const isOpen = (session) => session && (session.state === "active" || session.state === "paused");
/// Open, or interrupted (the camera restarted mid-session) and waiting to be resumed or finished.
const isControllable = (session) => isOpen(session) || session?.state === "interrupted";

function toast(message, info = false) {
  const element = $("toast");
  // A full-screen element shows only its own subtree: put the toast inside the board while it is full screen.
  const host = document.fullscreenElement || document.body;
  if (element.parentElement !== host) host.appendChild(element);
  element.textContent = message; element.className = info ? "toast info" : "toast"; element.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { element.hidden = true; }, info ? 2500 : 6000);
}

// MARK: Connection

function readToken() {
  const hash = new URLSearchParams(location.hash.slice(1));
  const fromHash = hash.get("t");
  if (fromHash) {
    save(TOKEN_KEY, fromHash);
    // The token must not stay in the address bar, history or a shared screenshot.
    history.replaceState(null, "", location.pathname + location.search);
  }
  state.token = fromHash || load(TOKEN_KEY);
}

function setLink(text, kind) {
  const element = $("link");
  element.textContent = text; element.className = `pill ${kind || ""}`;
}

function connect() {
  clearTimeout(state.retry);
  setLink(state.attempt ? `重连中（第 ${state.attempt} 次）…` : "连接中…", "bad");
  const socket = new WebSocket(`ws://${location.host}/ws`);
  socket.binaryType = "arraybuffer";
  state.socket = socket;
  socket.onmessage = (event) => {
    if (socket !== state.socket) return;
    if (typeof event.data === "string") receive(JSON.parse(event.data));
    else receiveBinary(event.data);
  };
  socket.onclose = () => {
    if (socket !== state.socket) return;
    const was = state.connected;
    // The access key stays: a loading clip may still use it for a minute.
    state.connected = false;
    for (const [, waiter] of state.waiters) waiter.resolve({ ok: false, message: "连接已断开，命令可能没有送达，请看机位状态后再试。" });
    state.waiters.clear();
    if (state.closedByUs) return;
    if (!state.token) { setLink("等待配对", "bad"); return; } // reconnect only with something to log in with
    state.attempt += 1;
    const delay = BACKOFF[Math.min(state.attempt - 1, BACKOFF.length - 1)];
    setLink(was ? "已断开，正在重连" : "无法连接机位，正在重试", "bad");
    state.retry = setTimeout(connect, delay * 1000);
    render();
  };
}

function send(kind, body) {
  if (state.socket?.readyState === WebSocket.OPEN) state.socket.send(JSON.stringify({ kind, body }));
}

function receive(message) {
  const { kind, body, t } = message;
  if (typeof t === "number") state.clockOffset = t - Date.now();
  switch (kind) {
    case "auth": return auth(body);
    case "hello":
      // The camera's open session, or none. A finished one follows as a session message. Without
      // this a page that reconnects to a restarted camera would keep showing a stale "recording".
      state.camera = body;
      applySession(body.session || null);
      state.disagreements = 0; state.repairs = 0; state.nextRepairAt = 0;
      break;
    case "status": state.status = body; agree(body); hawkStatus(body); break;
    case "session": applySession(body); break;
    case "analysis": hawkRows(body); applyAnalysis(body); break;
    case "control":
      if (body.command === "reply") {
        const waiter = state.waiters.get(body.replyTo);
        if (waiter) { state.waiters.delete(body.replyTo); waiter.resolve(body); }
      }
      break;
    default: break;
  }
  scheduleRender();
}

function auth(body) {
  if (body.nonce) {
    if (body.version !== PROTOCOL) {
      showLogin(`机位运行协议 v${body.version}，本页面是 v${PROTOCOL}，请刷新页面。`);
      state.closedByUs = true; state.socket.close(); return;
    }
    state.nonce = body.nonce;
    $("camera-name").textContent = body.camera ? `机位：${body.camera}` : "";
    if (state.token) { state.sentMac = true; send("auth", { mac: hmacSHA256Hex(state.token, body.nonce) }); }
    else if (state.pendingPIN) { send("auth", { pin: state.pendingPIN }); state.pendingPIN = null; }
    else showLogin();
    return;
  }
  if (body.ok) {
    state.sentMac = false;
    if (body.token) { state.token = body.token; save(TOKEN_KEY, body.token); }
    state.access = body.access; state.connected = true; state.attempt = 0;
    $("login").hidden = true; $("app").hidden = false;
    setLink("已连接机位", "ok");
    send("hello", { role: "display", device: deviceName(), hardware: "browser", app: "web", capabilities: ["web"] });
    if (state.previewOn) send("preview", { enabled: true });
    // History is read from disk on the camera: load it once when the page opens, then on 「刷新」.
    if (!state.historyLoaded) { state.historyLoaded = true; refreshHistory(); }
    return;
  }
  if (state.sentMac) {
    // The saved token no longer works (pairing refreshed or expired): ask for the PIN instead.
    state.sentMac = false; state.token = null; save(TOKEN_KEY, null);
    showLogin(body.message);
    return;
  }
  showLogin();
  $("login-error").textContent = body.message || "配对失败。";
}

function showLogin(reason) {
  $("app").hidden = true; $("login").hidden = false;
  setLink("等待配对", "bad");
  if (reason) $("login-reason").textContent = reason;
  $("pin").focus();
}

function deviceName() {
  const agent = navigator.userAgent;
  if (/iPad/.test(agent)) return "iPad 浏览器";
  if (/Android/.test(agent)) return /Mobile/.test(agent) ? "安卓手机浏览器" : "安卓平板浏览器";
  if (/iPhone/.test(agent)) return "iPhone 浏览器";
  return "浏览器";
}

$("pin-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const pin = $("pin").value.trim();
  if (!/^\d{6}$/.test(pin)) { $("login-error").textContent = "配对码是 6 位数字。"; return; }
  $("login-error").textContent = "";
  if (state.socket?.readyState === WebSocket.OPEN && state.nonce) send("auth", { pin });
  else { state.pendingPIN = pin; state.attempt = 0; connect(); }
});

// MARK: Data

function applySession(session) {
  if (!session) {
    if (isControllable(state.session)) { state.session = null; state.sessionRows = new Map(); }
    return;
  }
  if (!state.session || state.session.id !== session.id) state.sessionRows = new Map();
  state.session = session;
}

/// The camera reports its session's id and state once a second. Messages arrive in order on one
/// socket, so a disagreement that lasts three reports means this page missed an update: reload the
/// session over HTTP, backing off 5 s → 15 s → 60 s, at most 5 times until the two agree again.
function agree(status) {
  if (state.pending || status.busy === true || state.repairing) return;
  const id = status.sessionID || null, current = state.session;
  let agrees;
  if (id && status.sessionState) {
    const open = ["active", "paused", "interrupted"].includes(status.sessionState);
    agrees = current?.id === id ? current.state === status.sessionState : !open && !isControllable(current);
  } else if (id) {
    agrees = true; // an older camera does not report the state
  } else {
    agrees = !isControllable(current);
  }
  if (agrees) { state.disagreements = 0; state.repairs = 0; state.nextRepairAt = 0; return; }
  state.disagreements += 1;
  if (state.disagreements < 3 || state.repairs >= 5 || Date.now() < state.nextRepairAt) return;
  state.nextRepairAt = Date.now() + [5, 15, 60][Math.min(state.repairs, 2)] * 1000;
  state.repairs += 1; state.disagreements = 0;
  if (!id) { applySession(null); scheduleRender(); return; }
  repairSession(id);
}
async function repairSession(id) {
  state.repairing = true;
  try {
    const { session } = await api(`/api/session?id=${id}`);
    const rows = session.tennisEvents || [];
    delete session.tennisEvents;
    applySession(session);
    state.sessionRows = new Map(rows.map((row) => [row.id, row]));
  } catch { /* the next disagreement retries after the back-off */ }
  state.repairing = false;
  if (state.repairs >= 5) toast("页面与机位的记录状态仍不一致，请以机位为准，或刷新页面。");
  scheduleRender();
}

function applyAnalysis(message) {
  const target = message.sessionID ? state.sessionRows : state.recentRows;
  if (message.sessionID && state.session && message.sessionID !== state.session.id) return;
  if (message.resync && (message.part ?? 0) === 0) target.clear();
  for (const row of message.events || []) target.set(row.id, row);
  if (!message.sessionID && message.calibration) state.recentCalibration = message.calibration;
  if (!message.sessionID && target.size > 24) {
    const keep = [...target.values()].sort((a, b) => a.sourcePTS - b.sourcePTS).slice(-24);
    target.clear(); for (const row of keep) target.set(row.id, row);
  }
}

function dashboardRows() {
  const rows = isOpen(state.session) ? state.sessionRows : state.recentRows;
  return [...rows.values()].sort((a, b) => a.sourcePTS - b.sourcePTS);
}

function sessionElapsed(session) {
  if (!session) return NaN;
  let seconds = session.accumulatedElapsed || 0;
  if (session.state === "active" && session.activeSince) seconds += Math.max(0, (Date.now() + state.clockOffset - session.activeSince) / 1000);
  return seconds;
}

// MARK: Commands

function command(name, fields = {}, timeout = 15000) {
  return new Promise((resolve) => {
    if (!state.connected) { resolve({ ok: false, message: "未连接机位：等页面重新连上机位后再试。" }); return; }
    const id = uuid();
    state.waiters.set(id, { resolve });
    send("control", { id, command: name, ...fields });
    setTimeout(() => {
      if (state.waiters.delete(id)) resolve({ ok: false, message: "机位没有回应，请看机位状态后再试。" });
    }, timeout);
  });
}
async function run(button, name, fields, timeout) {
  button.disabled = true;
  const reply = await command(name, fields, timeout);
  button.disabled = false;
  if (reply.ok === false) toast(reply.message || "机位没有执行这条命令。");
  render();
  return reply;
}
/// Session commands lock every session button until the camera answers; the camera sends the new
/// session state before its reply, so the page shows the camera's state, never a guess.
async function runSession(name, fields, timeout) {
  if (state.pending) return { ok: false };
  state.pending = name; render();
  const reply = await command(name, fields, timeout);
  state.pending = null;
  if (reply.ok === false) toast(reply.message || "机位没有执行这条命令。");
  render();
  return reply;
}

$("start").addEventListener("click", () => runSession("start", { label: $("title").value.trim() || "球场分析" }));
$("pause").addEventListener("click", () => {
  const session = state.session; if (!session) return;
  runSession(session.state === "active" ? "pause" : "resume", { sessionID: session.id }, 30000);
});
$("finish").addEventListener("click", () => {
  const session = state.session; if (!session) return;
  if (!confirm(`结束记录「${session.title}」？结束后机位停止录像。`)) return;
  runSession("finish", { sessionID: session.id }, 60000);
});
// The same two markers as the App: 精彩 and 待复核.
for (const id of ["marker", "marker-review"]) {
  $(id).addEventListener("click", async () => {
    const session = state.session; if (!session) return;
    const label = $(id).dataset.label;
    const reply = await run($(id), "marker", { sessionID: session.id, label, date: Date.now() + state.clockOffset });
    if (reply.ok !== false) { toast(`已标记「${label}」`, true); navigator.vibrate?.(30); }
  });
}
$("wake").addEventListener("click", async () => {
  const reply = await run($("wake"), "wake");
  if (reply.ok !== false) toast("已请求点亮机位屏幕", true);
});
for (const id of ["near", "far"]) {
  $(id).addEventListener("change", async () => {
    const reply = await run($(id), "handedness", { near: $("near").value, far: $("far").value });
    if (reply.ok !== false) toast("持拍手已保存，影响之后的击球", true);
  });
}

// MARK: Preview

$("preview-toggle").addEventListener("click", () => {
  state.previewOn = !state.previewOn;
  send("preview", { enabled: state.previewOn });
  if (!state.previewOn) {
    $("preview").hidden = true;
    if (state.previewURL) { URL.revokeObjectURL(state.previewURL); state.previewURL = null; }
  }
  render();
});
document.addEventListener("visibilitychange", () => {
  // A hidden tab does not need frames; the camera stops encoding when nobody watches.
  if (state.previewOn) send("preview", { enabled: !document.hidden });
});

function receiveBinary(buffer) {
  const bytes = new Uint8Array(buffer);
  if (bytes.length < 5) return;
  const length = new DataView(buffer).getUint32(1);
  const info = JSON.parse(new TextDecoder().decode(bytes.subarray(5, 5 + length)));
  const blob = new Blob([bytes.subarray(5 + length)], { type: "image/jpeg" });
  if (bytes[0] === 1) {
    if (!state.previewOn) return;
    const url = URL.createObjectURL(blob);
    const image = $("preview");
    image.onload = () => { if (state.previewURL && state.previewURL !== url) URL.revokeObjectURL(state.previewURL); state.previewURL = url; };
    image.src = url; image.hidden = false;
    state.lastFrameAt = Date.now();
    scheduleRender();
  }
}

// MARK: History

$("history-refresh").addEventListener("click", refreshHistory);
async function api(path) {
  if (!state.access) throw new Error("未连接机位");
  const response = await fetch(`${path}${path.includes("?") ? "&" : "?"}k=${encodeURIComponent(state.access)}`, { cache: "no-store" });
  if (!response.ok) throw new Error((await response.text()) || `机位返回 ${response.status}`);
  return response.json();
}
async function refreshHistory() {
  try { state.history = await api("/api/sessions"); renderHistory(); }
  catch (error) { $("history").innerHTML = `<li class="error small">读取历史记录失败：${esc(error.message)}。确认已连接机位后点「刷新」。</li>`; }
}
function renderHistory() {
  const items = state.history.slice(0, 30).map((row) => {
    const status = SESSION_STATES[row.state] || row.state;
    return `<li><button data-session="${esc(row.id)}">${esc(row.title)}<br><span class="muted small">${dateText(row.startedAt)} · ${duration(row.elapsed)} · ${status} · ${row.shots} 拍（球速 ${row.speeds} · 落点 ${row.landings}）</span></button></li>`;
  });
  $("history").innerHTML = items.join("") || `<li class="muted small">机位上还没有记录。</li>`;
}
$("history").addEventListener("click", async (event) => {
  const id = event.target.closest("button")?.dataset.session;
  if (!id) return;
  try { showDetail(await api(`/api/session?id=${id}`)); } catch (error) { toast(error.message); }
});
$("detail-close").addEventListener("click", () => {
  for (const video of $("detail").querySelectorAll("video")) video.removeAttribute("src");
  $("detail").close();
});
function showDetail({ session, elapsed, available }) {
  const rows = (session.tennisEvents || []).slice().sort((a, b) => a.sourcePTS - b.sourcePTS);
  $("detail-title").textContent = session.title;
  const speeds = rows.map((r) => r.speedKPH).filter(validSpeed);
  $("detail-meta").textContent = `${dateText(session.startedAt)} · ${duration(elapsed)} · ${rows.length} 拍 · 有效平均 ${speeds.length ? Math.round(speeds.reduce((a, b) => a + b, 0) / speeds.length) : "—"} km/h · 模型 ${session.tennisModelVersion || "—"}`;
  const recordings = session.recordings || [];
  // `available` lists recordings still on the camera (older cameras omit it: offer them all).
  const onCamera = (r) => !Array.isArray(available) || available.includes(r.filename);
  $("detail-recordings").innerHTML = recordings.length
    ? recordings.map((r) => onCamera(r)
      ? `<a href="/api/recording?session=${session.id}&file=${encodeURIComponent(r.filename)}&k=${encodeURIComponent(state.access)}" download="${esc(r.filename)}" data-testid="court.history.download">下载录像 ${esc(r.filename)}（${duration(r.duration)}，约 ${Math.max(1, Math.round(r.duration))} MB）</a>`
      : `<p class="muted small" data-testid="court.history.cleared">${esc(r.filename)}：机位上的录像已清理，逐拍数据保留。</p>`).join("")
      + `<p class="muted small">整段录像约每分钟 60 MB；机位记录中不能下载。</p>`
    : `<p class="muted small">这次记录没有录像。</p>`;
  state.detail = { rows, sessionID: session.id, limit: PAGE };
  $("detail-shots").innerHTML = "";
  renderDetailShots();
  $("detail").showModal();
}
function renderDetailShots() {
  const { rows, sessionID, limit } = state.detail;
  const list = $("detail-shots");
  // Append only the new page, so players already open keep playing.
  const shown = list.querySelectorAll(".shot").length;
  const page = rows.slice().reverse().slice(shown, limit);
  list.insertAdjacentHTML("beforeend", page.map((shot) => shotItem(shot, sessionID, rows[0]?.sourcePTS)).join(""));
  if (!rows.length) list.innerHTML = `<li class="muted small">本次记录没有可用的击球候选。</li>`;
  pager($("detail-more"), $("detail-count"), rows.length, Math.min(limit, rows.length));
}
$("detail-more").addEventListener("click", () => { state.detail.limit += PAGE; renderDetailShots(); });
function pager(button, count, total, shown) {
  count.textContent = total > 0 ? (shown < total ? `共 ${total} 拍 · 显示最近 ${shown} 拍` : `共 ${total} 拍`) : "";
  button.hidden = shown >= total;
  button.textContent = `显示更早的 ${Math.min(PAGE, total - shown)} 拍`;
}

// MARK: Clips (shared by the live list and history)

function shotItem(shot, sessionID, firstPTS) {
  const speed = validSpeed(shot.speedKPH)
    ? `<span class="shot-speed">${Math.round(shot.speedKPH)}</span> <span class="muted small">km/h 估计</span>`
    : `<span class="shot-speed">—</span>`;
  const why = [];
  if (!validSpeed(shot.speedKPH)) why.push(`球速：${speedReason(shot)}`);
  if (hasPlacement(shot)) why.push(`落点：约横 ${shot.bounce.xMeters.toFixed(1)} m，纵 ${shot.bounce.yMeters.toFixed(1)} m`);
  else why.push(`落点：${placementReason(shot)}`);
  if (shot.origin === "offline") why.push("离线补算");
  const time = Number.isFinite(firstPTS) ? `+${duration(shot.sourcePTS - firstPTS)}` : "";
  const clip = sessionID ? `<div class="shot-actions"><button data-clip="${esc(shot.id)}" data-session="${esc(sessionID)}">播放这一拍</button></div>` : "";
  return `<li class="shot" data-shot="${esc(shot.id)}"><div class="shot-head"><span>${strokeTag(shot.stroke)} <span class="muted small">${time}</span></span><span>${speed}</span></div><div class="shot-why">${esc(why.join(" · "))}</div>${clip}</li>`;
}

// "ZacksCourt-第12拍-正手-128kmh.mp4", like the App's export name (the browser has no session start time here).
function clipName(shotID) {
  const rows = state.detail?.rows?.some((r) => r.id === shotID) ? state.detail.rows : dashboardRows();
  const index = rows.findIndex((r) => r.id === shotID), shot = rows[index];
  const parts = ["ZacksCourt"];
  if (index >= 0) parts.push(`第${index + 1}拍`);
  if (shot) parts.push(STROKES[shot.stroke] || STROKES.unknown);
  if (shot && validSpeed(shot.speedKPH)) parts.push(`${Math.round(shot.speedKPH)}kmh`);
  return parts.join("-") + ".mp4";
}

async function playClip(button) {
  const item = button.closest(".shot");
  item.querySelector("video")?.remove();
  item.querySelector(".clip-error")?.remove();
  item.querySelector(".clip-download")?.remove();
  const url = `/api/clip?session=${button.dataset.session}&shot=${button.dataset.clip}&k=${encodeURIComponent(state.access || "")}`;
  button.disabled = true; button.textContent = "机位正在剪片段…";
  try {
    // HEAD first: a refused clip comes back with the camera's reason instead of a broken player.
    const check = await fetch(url, { method: "HEAD", cache: "no-store" });
    if (!check.ok) throw new Error((await fetch(url, { cache: "no-store" }).then((r) => r.text())) || `机位返回 ${check.status}`);
    const video = document.createElement("video");
    video.controls = true; video.playsInline = true; video.muted = true; video.preload = "auto";
    video.src = url;
    item.appendChild(video);
    video.play().catch(() => {});
    // The camera keeps the cut clip for a while, so the download asks for the same file again.
    const link = document.createElement("a");
    link.className = "clip-download"; link.href = url; link.download = clipName(button.dataset.clip);
    link.textContent = "下载这一拍"; link.dataset.testid = "court.shot.download";
    item.querySelector(".shot-actions")?.appendChild(link);
  } catch (error) {
    item.insertAdjacentHTML("beforeend", `<p class="clip-error shot-why">${esc(error.message)}</p>`);
  }
  button.disabled = false; button.textContent = "重新播放这一拍";
}
for (const list of ["shots", "detail-shots"]) {
  $(list).addEventListener("click", (event) => {
    const button = event.target.closest("button[data-clip]");
    if (button) playClip(button);
  });
}

$("shots-more").addEventListener("click", () => { state.liveLimit += PAGE; render(); });

// MARK: Hawk-Eye line calls (the camera judges with the settings a display sent; this page shows them)

const CALLS = {
  out: { shout: "OUT", text: "出界", color: "var(--recording)" },
  in: { shout: "IN", text: "界内", color: "var(--green)" },
  close: { shout: "CLOSE", text: "压线附近", color: "var(--warning)" },
};
const LINES = { sideline: "边线", baseline: "底线", serviceLine: "发球线", centreLine: "中线" };
const FORMATS = { singles: "单打", doubles: "双打" };
const VOICE_KEY = "court.web.hawkeye.voice";
/// Calls this old (row time against the newest row of the message) are not announced: a page that
/// reconnects must not shout past calls. Same as the app (HawkEyeAlerts).
const STALE_CALL_SECONDS = 8;
state.hawkEye = { announced: new Set(), alert: null, timer: null, voice: load(VOICE_KEY) !== "off", unlocked: false, pending: null };
const hawkSupported = () => (state.camera?.capabilities || []).includes("hawkEye");
const hawkOff = { enabled: false, format: "singles", farHalf: false };
const hawkSettings = () => state.hawkEye.pending || state.status?.hawkEye || hawkOff;
const sameHawk = (a, b) => Boolean(a && b) && a.enabled === b.enabled && a.format === b.format && Boolean(a.farHalf) === Boolean(b.farHalf);

function hawkDetail(j) {
  const cm = Math.round(Math.abs(j.distanceM) * 100), line = LINES[j.line] || "线";
  if (j.call === "out") return `出界约 ${cm} 厘米 · ${line}`;
  if (j.call === "in") return `界内 · 距${line}约 ${cm} 厘米`;
  return `离${line}不到 ${Math.round(j.marginM * 100)} 厘米，无法判定`;
}

function hawkStatus(status) {
  if (state.hawkEye.pending && sameHawk(status.hawkEye, state.hawkEye.pending)) state.hawkEye.pending = null;
}

/// Announces the newest call not shown before; rows from a catch-up are remembered, never announced.
function hawkRows(message) {
  const rows = message.events || [];
  const announced = state.hawkEye.announced;
  if (message.resync) { for (const row of rows) if (row.bounce?.hawkEye) announced.add(row.id); return; }
  const newest = rows.reduce((m, r) => Math.max(m, r.sourcePTS || 0), 0);
  let next = state.hawkEye.alert, fresh = false;
  for (const row of [...rows].sort((a, b) => a.sourcePTS - b.sourcePTS)) {
    const call = row.bounce?.hawkEye;
    if (!call) continue;
    if (next && next.id === row.id) { next = { ...next, call }; announced.add(row.id); continue; }
    if (announced.has(row.id)) continue;
    announced.add(row.id);
    if (newest - row.sourcePTS > STALE_CALL_SECONDS) continue;
    next = { id: row.id, call }; fresh = true;
    if (call.call === "out") sayOut();
  }
  if (next !== state.hawkEye.alert) showCall(next, fresh);
}

function showCall(alert, fresh) {
  state.hawkEye.alert = alert;
  const element = $("hawkeye-call");
  // The replay is open: the voice still calls, the banner would cover its buttons.
  if (!alert || !$("challenge").hidden) { element.hidden = true; return; }
  const j = alert.call, look = CALLS[j.call] || CALLS.close;
  // A full-screen element shows only its own subtree, like the toast.
  const host = document.fullscreenElement || document.body;
  if (element.parentElement !== host) host.appendChild(element);
  element.style.setProperty("--call", look.color);
  element.className = `hawkeye-call ${j.call}`;
  $("hawkeye-shout").textContent = look.shout;
  $("hawkeye-title").textContent = `界内外 · ${look.text}${j.serve ? " · 发球" : ""}`;
  $("hawkeye-detail").textContent = hawkDetail(j);
  element.setAttribute("aria-label", `界内外：${look.text}，${hawkDetail(j)}。轻点关闭`);
  element.hidden = false;
  if (fresh) {
    clearTimeout(state.hawkEye.timer);
    state.hawkEye.timer = setTimeout(() => showCall(null), 4000);
  }
}
$("hawkeye-call").addEventListener("click", () => { clearTimeout(state.hawkEye.timer); showCall(null); });

/// Browsers speak only after a tap on the page: the Hawk-Eye buttons and the 「开启语音」 chip unlock it.
function unlockVoice() {
  if (state.hawkEye.unlocked || !("speechSynthesis" in window)) return;
  const silent = new SpeechSynthesisUtterance(" ");
  silent.volume = 0;
  speechSynthesis.speak(silent);
  state.hawkEye.unlocked = true;
}
function sayOut() {
  if (!state.hawkEye.voice || !("speechSynthesis" in window)) return;
  const utterance = new SpeechSynthesisUtterance("Out!");
  utterance.lang = "en-GB"; utterance.rate = 1; utterance.pitch = 1.1; utterance.volume = 1;
  speechSynthesis.cancel();
  speechSynthesis.speak(utterance);
}
$("hawkeye-sound").addEventListener("click", () => { unlockVoice(); renderHawkEye(); });

async function setHawk(settings) {
  state.hawkEye.pending = settings;
  renderHawkEye();
  const reply = await command("hawkEye", { hawkEye: settings });
  if (reply.ok === false) { state.hawkEye.pending = null; toast(reply.message || "机位没有保存界内外设置。"); }
  if (!settings.enabled) showCall(null);
  render();
}
function openHawkEye() {
  unlockVoice();
  if (!hawkSupported()) { toast(state.connected ? "机位的 App 版本不支持界内外判定，请更新机位。" : "连接机位后才能开启界内外。"); return; }
  if (hawkSettings().enabled) { renderHawkEye(); $("hawkeye-settings").showModal(); } else $("hawkeye-ask").showModal();
}
for (const id of ["hawkeye-open", "board-hawkeye"]) $(id).addEventListener("click", openHawkEye);
for (const button of document.querySelectorAll("#hawkeye-ask [data-format]")) {
  button.addEventListener("click", () => {
    $("hawkeye-ask").close();
    setHawk({ enabled: true, format: button.dataset.format, farHalf: false });
  });
}
$("hawkeye-ask-cancel").addEventListener("click", () => $("hawkeye-ask").close());
$("hawkeye-settings-close").addEventListener("click", () => $("hawkeye-settings").close());
for (const button of document.querySelectorAll("#hawkeye-settings [data-set-format]")) {
  button.addEventListener("click", () => setHawk({ ...hawkSettings(), format: button.dataset.setFormat }));
}
$("hawkeye-far").addEventListener("change", (event) => setHawk({ ...hawkSettings(), farHalf: event.target.checked }));
$("hawkeye-voice").addEventListener("change", (event) => {
  state.hawkEye.voice = event.target.checked; save(VOICE_KEY, state.hawkEye.voice ? "on" : "off"); renderHawkEye();
});
$("hawkeye-off").addEventListener("click", () => { $("hawkeye-settings").close(); setHawk({ ...hawkSettings(), enabled: false }); });

function renderHawkEye() {
  const settings = hawkSettings(), supported = hawkSupported() && state.connected;
  for (const id of ["hawkeye-open", "board-hawkeye"]) {
    const button = $(id);
    button.hidden = !supported;
    button.classList.toggle("on", settings.enabled);
    button.textContent = settings.enabled ? `◉ 界内外 · ${FORMATS[settings.format] || "单打"}` : "◎ 界内外";
    button.setAttribute("aria-label", settings.enabled ? `界内外已开启，${FORMATS[settings.format]}，${settings.farHalf ? "全场" : "仅近端半场"}` : "开启界内外");
  }
  for (const button of document.querySelectorAll("#hawkeye-settings [data-set-format]")) {
    button.setAttribute("aria-checked", String(button.dataset.setFormat === settings.format));
  }
  $("hawkeye-far").checked = Boolean(settings.farHalf);
  $("hawkeye-far-note").textContent = settings.farHalf ? "远端落点看得斜，误差是近端的几倍，远端的判定更常显示「压线附近」。" : "只判近端半场：远端的落点误差大，默认不判。";
  $("hawkeye-voice").checked = state.hawkEye.voice;
  $("hawkeye-pending").hidden = !state.hawkEye.pending;
  $("board-challenge").hidden = !(settings.enabled || dashboardRows().some((row) => row.bounce?.hawkEye));
  const chip = $("hawkeye-sound");
  chip.hidden = !(supported && settings.enabled && state.hawkEye.voice && !state.hawkEye.unlocked && "speechSynthesis" in window);
  const host = document.fullscreenElement || document.body;
  if (!chip.hidden && chip.parentElement !== host) host.appendChild(chip);
}

// MARK: Hawk-Eye challenge replay (mirrors CourtCore/HawkEyeReplay.swift and HawkEyeChallengeView)

const HE = {
  netY: 11.885, length: 23.77, width: 10.97, centreX: 5.485, singles: 4.115, service: 6.40, centreHalf: 0.025,
  ball: 0.033, g: 9.80665, sigmas: 2, minMargin: 0.03, defaultMargin: 0.15,
};
const v3 = {
  add: (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]], sub: (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]],
  mul: (a, k) => [a[0] * k, a[1] * k, a[2] * k], dot: (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
  cross: (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]],
  norm: (a) => { const l = Math.hypot(a[0], a[1], a[2]) || 1; return [a[0] / l, a[1] / l, a[2] / l]; },
};

function replayScene(event) {
  const b = event.bounce, j = b?.hawkEye;
  if (!j || !Number.isFinite(b.xMeters) || !Number.isFinite(b.yMeters)) return null;
  const x = b.xMeters, y = b.yMeters, c = HE.centreX, far = y > HE.netY;
  const bounce = [x, y, HE.ball];
  const half = j.serve || j.format === "singles" ? HE.singles : c;
  let anchor, outward;
  if (j.line === "sideline") { const r = x >= c; anchor = [r ? c + half : c - half, y, 0]; outward = [r ? 1 : -1, 0, 0]; }
  else if (j.line === "centreLine") { const r = x >= c; anchor = [r ? c + HE.centreHalf : c - HE.centreHalf, y, 0]; outward = [r ? 1 : -1, 0, 0]; }
  else if (j.line === "baseline") { anchor = [x, far ? HE.length : 0, 0]; outward = [0, far ? 1 : -1, 0]; }
  else { anchor = [x, far ? HE.netY + HE.service : HE.netY - HE.service, 0]; outward = [0, far ? 1 : -1, 0]; }
  const hit = event.hit;
  const fromNear = hit ? hit.y < HE.netY : y > HE.netY;
  let flight = null, bounceIndex = 0;
  const T = b.sourcePTS - event.sourcePTS;
  if (hit && T > 0.15 && T < 3) {
    const H = [hit.x, hit.y, Math.max(hit.z, HE.ball)];
    const v = v3.mul(v3.sub(bounce, H), 1 / T); v[2] += 0.5 * HE.g * T;
    flight = [];
    for (let i = 0; i <= 36; i += 1) { const t = T * i / 36; flight.push(v3.sub(v3.add(H, v3.mul(v, t)), [0, 0, 0.5 * HE.g * t * t])); }
    const vb = [v[0] * 0.7, v[1] * 0.7, -(v[2] - HE.g * T) * 0.72];
    for (let i = 1; i <= 10; i += 1) {
      const t = 0.35 * i / 10, p = v3.sub(v3.add(bounce, v3.mul(vb, t)), [0, 0, 0.5 * HE.g * t * t]);
      p[2] = Math.max(p[2], HE.ball); flight.push(p);
    }
    bounceIndex = 36;
  }
  const sx = Number.isFinite(b.sigmaXMeters) ? Math.max(HE.minMargin, HE.sigmas * b.sigmaXMeters) : HE.defaultMargin;
  const sy = Number.isFinite(b.sigmaYMeters) ? Math.max(HE.minMargin, HE.sigmas * b.sigmaYMeters) : HE.defaultMargin;
  const wideY = fromNear ? -10.5 : HE.length + 10.5;
  const wide = { pos: [c, wideY, 7.5], target: [c, HE.netY, 0], fov: 46 };
  const gap = Math.abs(j.distanceM), back = 1.1 + Math.min(2.5, gap * 1.5), height = 0.55 + Math.min(1.4, gap * 0.8);
  const along = [-outward[1], outward[0], 0];
  const focus = v3.mul(v3.add(anchor, [x, y, 0]), 0.5);
  const close = { pos: v3.add(v3.add(v3.sub(focus, v3.mul(outward, back)), v3.mul(along, back * 0.35)), [0, 0, height]), target: focus, fov: 34 };
  return { j, bounce, flight, bounceIndex, anchor, outward, unc: [sx, sy], wide, close };
}

function camBlend(a, b, t) {
  const s = Math.max(0, Math.min(1, t)), e = s * s * (3 - 2 * s);
  const mix = (p, q) => v3.add(p, v3.mul(v3.sub(q, p), e));
  return { pos: mix(a.pos, b.pos), target: mix(a.target, b.target), fov: a.fov + (b.fov - a.fov) * e };
}
function camera(cam, w, h) {
  const fwd = v3.norm(v3.sub(cam.target, cam.pos)), right = v3.norm(v3.cross(fwd, [0, 0, 1])), up = v3.cross(right, fwd);
  const f = h / (2 * Math.tan(cam.fov * Math.PI / 360));
  const view = (p) => { const d = v3.sub(p, cam.pos); return [v3.dot(d, right), v3.dot(d, up), v3.dot(d, fwd)]; };
  const screen = (q) => [w / 2 + f * q[0] / q[2], h / 2 - f * q[1] / q[2]];
  const NEAR = 0.05;
  return {
    f, view, screen,
    project: (p) => { const q = view(p); return q[2] > NEAR ? screen(q) : null; },
    polygon: (points) => {
      const cs = points.map(view), out = [];
      for (let i = 0; i < cs.length; i += 1) {
        const a = cs[i], b = cs[(i + 1) % cs.length], ina = a[2] > NEAR, inb = b[2] > NEAR;
        if (ina) out.push(a);
        if (ina !== inb) { const t = (NEAR - a[2]) / (b[2] - a[2]); out.push(v3.add(a, v3.mul(v3.sub(b, a), t))); }
      }
      return out.map(screen);
    },
  };
}
function courtLines() {
  const W = HE.width, L = HE.length, net = HE.netY, c = HE.centreX, s0 = c - HE.singles, s1 = c + HE.singles, svc = HE.service, w = 0.05, base = 0.10;
  const rect = (x0, y0, x1, y1) => [[x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]];
  return [rect(0, 0, W, base), rect(0, L - base, W, L), rect(0, 0, w, L), rect(W - w, 0, W, L), rect(s0, 0, s0 + w, L), rect(s1 - w, 0, s1, L),
    rect(s0, net - svc, s1, net - svc + w), rect(s0, net + svc - w, s1, net + svc), rect(c - w / 2, net - svc, c + w / 2, net + svc),
    rect(c - w / 2, base, c + w / 2, base + 0.10), rect(c - w / 2, L - base - 0.10, c + w / 2, L - base)];
}
function replayTiming(hasFlight) {
  const title = 1.0, flightEnd = hasFlight ? title + 2.2 : title, zoomEnd = flightEnd + 1.4, markEnd = zoomEnd + 0.5;
  return { title, flightEnd, zoomEnd, markEnd, total: markEnd + 0.3 };
}

const challenge = { shots: [], index: 0, started: 0, frame: null, scene: null, running: false };
function judgedShots() {
  return dashboardRows().map((row, i) => ({ number: i + 1, shot: row })).filter((e) => e.shot.bounce?.hawkEye);
}
function cssColor(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || "#fff"; }
function callColor(call) { return cssColor(call === "out" ? "--recording" : call === "in" ? "--green" : "--warning"); }

function paintReplay(scene, t) {
  const canvas = $("challenge-canvas"), ratio = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * ratio) || canvas.height !== Math.round(h * ratio)) { canvas.width = Math.round(w * ratio); canvas.height = Math.round(h * ratio); }
  const g = canvas.getContext("2d");
  g.setTransform(ratio, 0, 0, ratio, 0, 0);
  const timing = replayTiming(Boolean(scene.flight));
  const cam = camera(camBlend(scene.wide, scene.close, (t - timing.flightEnd) / (timing.zoomEnd - timing.flightEnd)), w, h);
  const mark = Math.max(0, Math.min(1, (t - timing.zoomEnd) / (timing.markEnd - timing.zoomEnd)));
  const fill = (points, color) => {
    const s = cam.polygon(points); if (s.length < 3) return null;
    g.beginPath(); g.moveTo(s[0][0], s[0][1]); for (const p of s.slice(1)) g.lineTo(p[0], p[1]); g.closePath();
    if (color) { g.fillStyle = color; g.fill(); }
    return true;
  };
  g.fillStyle = cssColor("--bg"); g.fillRect(0, 0, w, h);
  const W = HE.width, L = HE.length, color = callColor(scene.j.call);
  g.globalAlpha = 0.65; fill([[-6, -8, 0], [W + 6, -8, 0], [W + 6, L + 8, 0], [-6, L + 8, 0]], "#0e2921"); g.globalAlpha = 1;
  fill([[0, 0, 0], [W, 0, 0], [W, L, 0], [0, L, 0]], "#0e2921");
  if (mark > 0) {
    const ring = []; for (let i = 0; i < 48; i += 1) { const a = i / 48 * 2 * Math.PI; ring.push([scene.bounce[0] + scene.unc[0] * Math.cos(a), scene.bounce[1] + scene.unc[1] * Math.sin(a), 0]); }
    if (fill(ring)) { g.globalAlpha = 0.16 * mark; g.fillStyle = color; g.fill(); g.globalAlpha = 0.55 * mark; g.setLineDash([4, 3]); g.strokeStyle = color; g.lineWidth = 1; g.stroke(); g.setLineDash([]); g.globalAlpha = 1; }
  }
  g.globalAlpha = 0.92; for (const r of courtLines()) fill(r, "#ffffff"); g.globalAlpha = 1;
  const net = HE.netY;
  if (fill([[-0.9, net, 0], [W + 0.9, net, 0], [W + 0.9, net, 1.07], [W / 2, net, 0.914], [-0.9, net, 1.07]])) {
    g.fillStyle = "rgba(255,255,255,0.10)"; g.fill(); g.strokeStyle = "rgba(255,255,255,0.55)"; g.lineWidth = 1; g.stroke();
  }
  if (scene.flight && t > timing.title) {
    const f = Math.max(0, Math.min(1, (t - timing.title) / (timing.flightEnd - timing.title)));
    const last = scene.flight.length - 1, bi = scene.bounceIndex;
    const n = Math.min(last, f < 0.85 ? bi * (f / 0.85) : bi + (last - bi) * ((f - 0.85) / 0.15));
    const whole = Math.floor(n), pts = scene.flight.slice(0, whole + 1);
    if (whole < last) pts.push(v3.add(scene.flight[whole], v3.mul(v3.sub(scene.flight[whole + 1], scene.flight[whole]), n - whole)));
    g.beginPath(); let started = false;
    for (const p of pts) { const s = cam.project(p); if (!s) { started = false; continue; } if (started) g.lineTo(s[0], s[1]); else { g.moveTo(s[0], s[1]); started = true; } }
    g.strokeStyle = cssColor("--green"); g.globalAlpha = 0.85; g.lineWidth = 3; g.lineCap = "round"; g.lineJoin = "round"; g.stroke(); g.globalAlpha = 1;
    const ball = pts[pts.length - 1], q = cam.view(ball);
    if (mark < 1 && q[2] > 0.05) {
      const s = cam.screen(q), r = Math.max(3, HE.ball * cam.f / q[2]);
      g.beginPath(); g.arc(s[0], s[1], r, 0, 2 * Math.PI); g.fillStyle = "#dbf240"; g.fill();
    }
  }
  if (mark > 0) {
    const ring = []; for (let i = 0; i < 32; i += 1) { const a = i / 32 * 2 * Math.PI; ring.push([scene.bounce[0] + HE.ball * Math.cos(a), scene.bounce[1] + HE.ball * Math.sin(a), 0]); }
    if (fill(ring)) { g.globalAlpha = 0.9 * mark; g.fillStyle = color; g.fill(); g.globalAlpha = mark; g.strokeStyle = "#fff"; g.lineWidth = 1; g.stroke(); g.globalAlpha = 1; }
  }
  $("challenge-title").hidden = t >= timing.title + 0.3;
  $("challenge-title").style.opacity = String(t < timing.title ? 1 : Math.max(0, 1 - (t - timing.title) / 0.3));
  $("challenge-verdict").hidden = t < timing.markEnd;
  return t < timing.total;
}

function showChallenge(keepIndex) {
  $("hawkeye-call").hidden = true;   // a banner raised before opening would cover the replay's buttons
  challenge.shots = judgedShots();
  if (!keepIndex) challenge.index = challenge.shots.length - 1;
  const current = challenge.shots[challenge.index];
  const scene = current && replayScene(current.shot);
  $("challenge-empty").hidden = Boolean(scene);
  $("challenge-canvas").hidden = !scene;
  $("challenge-prev").disabled = challenge.index <= 0;
  $("challenge-next").disabled = challenge.index >= challenge.shots.length - 1;
  $("challenge-number").textContent = current ? `#${current.number}` : "";
  const foot = $("challenge-foot");
  foot.innerHTML = "";
  challenge.scene = scene;
  if (!scene) { $("challenge-title").hidden = true; $("challenge-verdict").hidden = true; return; }
  const j = scene.j, look = CALLS[j.call] || CALLS.close;
  $("challenge-sub").textContent = `界内外回放 · 第 ${current.number} 拍`;
  const verdict = $("challenge-verdict");
  verdict.className = `challenge-verdict ${j.call}`; verdict.style.setProperty("--call", look.color);
  $("challenge-shout").textContent = look.shout;
  $("challenge-call").textContent = look.text + (j.serve ? " · 发球" : "");
  $("challenge-detail").textContent = hawkDetail(j);
  $("challenge-margin").textContent = `模型估计，不是判罚 · 误差范围 ±${Math.round(j.marginM * 100)} 厘米`;
  $("challenge-canvas").setAttribute("aria-label", `第 ${current.number} 拍界内外回放：${look.text}，${hawkDetail(j)}`);
  const session = isOpen(state.session) ? state.session.id : null;
  foot.innerHTML = (session ? `<button data-clip="${esc(current.shot.id)}" data-session="${esc(session)}">看这一拍的视频</button>` : "")
    + `<span class="muted small">${current.shot.hit ? "轨迹按击球点和落点估算" : "这条链没有击球点，只回放落点"}</span>`;
  challenge.started = performance.now();
  const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  cancelAnimationFrame(challenge.frame);
  const step = () => {
    const t = reduce ? 99 : (performance.now() - challenge.started) / 1000;
    challenge.running = !$("challenge").hidden && paintReplay(scene, t);
    if (challenge.running) challenge.frame = requestAnimationFrame(step);
  };
  step();
}
$("board-challenge").addEventListener("click", () => { showCall(null); $("challenge").hidden = false; showChallenge(false); });
$("challenge-close").addEventListener("click", () => { $("challenge").hidden = true; cancelAnimationFrame(challenge.frame); $("challenge-foot").innerHTML = ""; });
$("challenge-again").addEventListener("click", () => showChallenge(true));
$("challenge-prev").addEventListener("click", () => { challenge.index = Math.max(0, challenge.index - 1); showChallenge(true); });
$("challenge-next").addEventListener("click", () => { challenge.index = Math.min(challenge.shots.length - 1, challenge.index + 1); showChallenge(true); });
$("challenge-foot").addEventListener("click", (event) => { const button = event.target.closest("button[data-clip]"); if (button) playClip(button); });
// A resize (rotation, split screen) redraws the finished replay at the new size; a running one picks it up itself.
if (typeof ResizeObserver === "function") new ResizeObserver(() => { if (!$("challenge").hidden && challenge.scene && !challenge.running) paintReplay(challenge.scene, 99); }).observe($("challenge"));

// MARK: Full-screen speed board

$("board-open").addEventListener("click", () => {
  const board = $("board");
  board.hidden = false;
  renderBoard();
  // Real full screen where the browser allows it (Android Chrome, iPad); otherwise the board
  // still covers the page (iPhone Safari has no element full screen).
  board.requestFullscreen?.({ navigationUI: "hide" }).catch(() => {});
  keepAwake();
});
function closeBoard() {
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  $("board").hidden = true;
  $("challenge").hidden = true; cancelAnimationFrame(challenge.frame);
  for (const id of ["toast", "hawkeye-call", "hawkeye-sound"]) if ($(id).parentElement !== document.body) document.body.appendChild($(id));
  state.wakeLock?.release().catch(() => {}); state.wakeLock = null;
  showLockHint();
}
/// Screen Wake Lock exists only in a secure context, which this plain-HTTP page usually is not.
/// Ask for it where the browser offers it; otherwise the board keeps its 「关闭自动锁屏」 hint.
async function keepAwake() {
  if (!("wakeLock" in navigator) || !window.isSecureContext || $("board").hidden || state.wakeLock) { showLockHint(); return; }
  try {
    state.wakeLock = await navigator.wakeLock.request("screen");
    state.wakeLock.addEventListener("release", () => { state.wakeLock = null; showLockHint(); });
  } catch { state.wakeLock = null; }
  showLockHint();
}
function showLockHint() {
  for (const hint of document.querySelectorAll(".board-lock")) hint.hidden = Boolean(state.wakeLock);
}
// The browser drops the lock when the page is hidden; ask again when it comes back.
document.addEventListener("visibilitychange", () => { if (!document.hidden && !$("board").hidden) keepAwake(); });
$("board-close").addEventListener("click", closeBoard);
document.addEventListener("keydown", (event) => { if (event.key === "Escape" && !$("board").hidden) closeBoard(); });
document.addEventListener("fullscreenchange", () => { if (!document.fullscreenElement && !$("board").hidden) $("board").hidden = true; });

// 「全部球速」 is the default and shows only the last usable speed; 「发球」 adds serve statistics
// and a trend. The choice is remembered in this browser, like the app remembers it per device.
const BOARD_MODE_KEY = "court.web.speedboard.mode";
state.boardMode = load(BOARD_MODE_KEY) === "serve" ? "serve" : "all";
for (const button of document.querySelectorAll("#board-modes [data-mode]")) {
  button.addEventListener("click", () => {
    state.boardMode = button.dataset.mode === "serve" ? "serve" : "all";
    save(BOARD_MODE_KEY, state.boardMode);
    renderBoard();
  });
}
// Window resizes, rotation and split screen re-pick the layout and redraw the trend at its real size.
if (typeof ResizeObserver === "function") new ResizeObserver(() => renderBoard()).observe($("board"));

/// Mirrors CourtCore.TennisServeSummary: only serves with a usable speed count, never as 0.
function serveSummary(rows) {
  const serves = rows.filter((row) => row.stroke === "serve");
  const points = [];
  serves.forEach((row, index) => { if (validSpeed(row.speedKPH)) points.push({ id: row.id, number: index + 1, speed: row.speedKPH }); });
  const speeds = points.map((p) => p.speed);
  return {
    count: serves.length, points,
    max: speeds.length ? Math.max(...speeds) : null,
    min: speeds.length ? Math.min(...speeds) : null,
    average: speeds.length ? speeds.reduce((a, b) => a + b, 0) / speeds.length : null,
    latest: points[points.length - 1] || null,
    holding: serves.length > 0 && !validSpeed(serves[serves.length - 1].speedKPH),
  };
}

/// A new reading lights the number up once, keyed on the shot so the same speed twice still reads
/// as new. Resizes and status updates re-render the board without a new shot and do not flash.
/// prefers-reduced-motion keeps only a short color change (style.css).
state.boardShown = { all: undefined, serve: undefined };
function flashBoard(element, mode, shotID) {
  const previous = state.boardShown[mode];
  state.boardShown[mode] = shotID ?? null;
  if (previous === undefined || !shotID || previous === shotID) return;
  element.classList.remove("fresh");
  void element.offsetWidth; // restart the animation
  element.classList.add("fresh");
}
for (const id of ["board-value", "serve-value"]) {
  $(id).addEventListener("animationend", () => $(id).classList.remove("fresh"));
}

function renderBoard() {
  if ($("board").hidden) { state.boardShown = { all: undefined, serve: undefined }; return; }
  const rows = dashboardRows();
  const serve = state.boardMode === "serve";
  let latestIndex = rows.length - 1; // findLastIndex is missing on older Android browsers
  while (latestIndex >= 0 && !validSpeed(rows[latestIndex].speedKPH)) latestIndex -= 1;
  const latest = latestIndex >= 0 ? rows[latestIndex] : undefined;
  const summary = serveSummary(rows);
  const hasData = serve ? Boolean(summary.latest) : Boolean(latest);
  const live = state.connected && state.status?.capturing === true;
  $("board-dot").className = live ? "board-dot live" : "board-dot";
  $("board-live").textContent = !state.connected ? "未连接" : live ? "实时" : hasData ? "已停止" : "等待";
  for (const button of document.querySelectorAll("#board-modes [data-mode]")) {
    button.setAttribute("aria-checked", String(button.dataset.mode === state.boardMode));
  }
  $("board-all").hidden = serve;
  $("board-serve").hidden = !serve;
  if (serve) { renderServeBoard(summary); return; }
  $("board-value").textContent = latest ? Math.round(latest.speedKPH).toString() : "--";
  $("board-value").classList.toggle("waiting", !latest);
  flashBoard($("board-value"), "all", latest?.id);
  $("board-unit").className = latest ? "board-unit" : "board-unit waiting";
  // The shot's position in the rows shown, like the serve number in 「发球」.
  const number = latestIndex + 1;
  $("board-status").textContent = !latest ? "等待有效击球"
    : !validSpeed(rows[rows.length - 1]?.speedKPH) ? `#${number} · 本拍暂无球速 · 保留上一有效值`
      : `#${number} · 最近有效球速 · ${STROKES[latest.stroke] || "待确认"}`;
}

function renderServeBoard(summary) {
  // Same rules as the app's ServeBandLayout, measured on the serve area itself.
  const box = $("board-serve"), width = box.clientWidth, height = box.clientHeight;
  const wide = width >= 560 && width >= height;
  const showsChart = height >= 280 && width >= 280;
  box.classList.toggle("wide", wide);
  box.classList.toggle("no-chart", !showsChart);
  box.style.setProperty("--trend-height", `${Math.round(Math.min(84, Math.max(36, height * 0.09)))}px`);
  box.style.setProperty("--stat-size", `${Math.round(Math.min(30, Math.max(15, Math.min(width, height) * 0.04)))}px`);

  const value = summary.latest ? Math.round(summary.latest.speed).toString() : "--";
  $("serve-value").textContent = value;
  $("serve-value").classList.toggle("waiting", !summary.latest);
  flashBoard($("serve-value"), "serve", summary.latest?.id);
  $("serve-unit").className = summary.latest ? "board-unit" : "board-unit waiting";
  // Short on the board (serve number), full sentence for screen readers.
  const n = summary.latest?.number;
  $("serve-status").textContent = !summary.latest ? (summary.count === 0 ? "等待发球" : "无有效球速")
    : summary.holding ? `#${n} · 本发无速` : `#${n}`;
  const counts = `本场 ${summary.count} 个发球，${summary.points.length} 个有球速`;
  $("serve-status").setAttribute("aria-label", !summary.latest
    ? (summary.count === 0 ? "等待有效发球" : `已识别 ${summary.count} 个发球，暂无有效球速`)
    : `${Math.round(summary.latest.speed)} 千米每小时，${summary.holding ? `最新一发暂无球速，保留第 ${n} 个发球的有效值` : `第 ${n} 个发球`}，${counts}`);
  // MAX / AVG / MIN on one line; unknown stays 「—」, never 0.
  const stats = [["MAX", "最高", summary.max], ["AVG", "平均", summary.average], ["MIN", "最低", summary.min]];
  $("serve-stats-line").innerHTML = stats.map(([title, , number]) =>
    `<span>${title}</span><b class="${validSpeed(number) ? "" : "none"}">${esc(speedText(number))}</b>`).join("");
  $("serve-stats-line").setAttribute("aria-label", stats.map(([, spoken, number]) =>
    `发球${spoken} ${validSpeed(number) ? `${speedText(number)} 千米每小时` : "暂无"}`).join("，"));
  if (showsChart) renderServeChart(summary);
}

/// A thin strip of serve speeds in serve order (last 30), without axes: earlier serves faint, the
/// current one in the accent (the same value as the large number), the average dashed.
const SERVE_TREND_LIMIT = 30;
function renderServeChart(summary) {
  const plot = $("serve-plot");
  const shown = summary.points.slice(-SERVE_TREND_LIMIT);
  $("serve-key-average").hidden = summary.average === null || !shown.length;
  $("serve-key-now").hidden = !shown.length;
  $("serve-key-last").hidden = summary.points.length <= shown.length;
  $("serve-key-last").textContent = `LAST ${shown.length}`;
  const width = plot.clientWidth, height = plot.clientHeight;
  if (!shown.length) {
    plot.innerHTML = '<div class="empty"></div>';
    plot.setAttribute("aria-label", "暂无有效发球球速");
    return;
  }
  if (width < 40 || height < 20) { plot.innerHTML = ""; return; }
  const speeds = shown.map((p) => p.speed);
  const low = Math.max(0, Math.min(...speeds) - 5), high = Math.max(...speeds) + 5;
  const first = shown[0].number, last = shown[shown.length - 1].number;
  const [x0, x1] = [first - 0.5, last + 0.5]; // room for the current point
  const pad = 5;
  const x = (n) => ((n - x0) / (x1 - x0)) * width;
  const y = (v) => pad + (1 - (v - low) / (high - low)) * (height - 2 * pad);
  const parts = [`<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="发球球速趋势，最近 ${shown.length} 个有效发球：${shown.slice(-5).map((p) => Math.round(p.speed)).join("、")} 千米每小时">`];
  if (summary.average !== null) {
    parts.push(`<line x1="0" x2="${width}" y1="${y(summary.average)}" y2="${y(summary.average)}" stroke="var(--muted)" stroke-width="1.5" stroke-dasharray="4 4"/>`);
  }
  if (shown.length > 1) {
    parts.push(`<polyline fill="none" stroke="rgba(255,255,255,0.5)" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round" points="${shown.map((p) => `${x(p.number)},${y(p.speed)}`).join(" ")}"/>`);
  }
  shown.forEach((p, index) => {
    const current = index === shown.length - 1;
    parts.push(current
      ? `<circle cx="${x(p.number)}" cy="${y(p.speed)}" r="5" fill="var(--green)"/>`
      : `<circle cx="${x(p.number)}" cy="${y(p.speed)}" r="2" fill="rgba(255,255,255,0.6)"/>`);
  });
  parts.push("</svg>");
  plot.innerHTML = parts.join("");
}

// MARK: Rendering (at most 4 times a second, like the app)

function scheduleRender() {
  if (state.renderQueued) return;
  state.renderQueued = true;
  const wait = Math.max(0, 250 - (Date.now() - state.lastRender));
  setTimeout(() => requestAnimationFrame(() => { state.renderQueued = false; state.lastRender = Date.now(); render(); }), wait);
}

/// "0.5×", "2.3×", "12×": the native app's CameraZoomRange.title.
function zoomTitle(factor) {
  if (factor >= 9.95) return Math.round(factor) + "×";
  return String(Math.round(factor * 10) / 10) + "×";
}

function render() {
  renderHawkEye();
  const status = state.status, session = state.session, open = isOpen(session);
  const connected = state.connected;
  // Status chips
  const chips = [];
  if (!connected) chips.push(`<span class="chip warn">数据可能不是最新</span>`);
  if (status) {
    chips.push(status.recording ? `<span class="chip rec">● 录像 ${duration(status.recordingSeconds ?? 0)}</span>` : `<span class="chip">${status.capturing ? "采集中 · 未录像" : "未采集"}</span>`);
    const analysis = status.analysis || {};
    chips.push(analysis.available ? `<span class="chip good">分析正常</span>` : `<span class="chip warn">分析：${esc(analysis.reason || "不可用")}</span>`);
    const lag = Number.isFinite(analysis.latestPTS) && Number.isFinite(analysis.analyzedPTS) ? analysis.latestPTS - analysis.analyzedPTS : null;
    if (lag !== null && lag > 1) chips.push(`<span class="chip warn">分析落后 ${lag.toFixed(1)} 秒</span>`);
    const device = status.device || {};
    if (typeof device.battery === "number") chips.push(`<span class="chip ${device.battery < 0.15 && !device.charging ? "warn" : ""}">电量 ${Math.round(device.battery * 100)}%${device.charging ? " · 充电" : ""}</span>`);
    else chips.push(`<span class="chip">电量 —</span>`);
    const thermal = THERMAL[device.thermal] || "—";
    chips.push(`<span class="chip ${device.thermal === "nominal" ? "" : "warn"}">温度 ${esc(thermal)}</span>`);
    // Camera zoom (0.5× ultra-wide … 3×); only shown when it is not 1×.
    if (Number.isFinite(status.zoom) && Math.abs(status.zoom - 1) > 0.001) chips.push(`<span class="chip">倍率 ${zoomTitle(status.zoom)}</span>`);
    if (status.shed > 0) chips.push(`<span class="chip warn" title="${esc(status.shedReason || "")}">机位负载保护 L${status.shed}</span>`);
    if (device.screen === "standby") chips.push(`<span class="chip">机位屏幕值守中</span>`);
  } else chips.push(`<span class="chip">等待机位状态</span>`);
  $("chips").innerHTML = chips.join("");
  $("warnings").textContent = [status?.shed > 0 ? status.shedReason : null, ...(status?.warnings || [])].filter(Boolean).join(" ");

  // Session controls
  $("session-title").textContent = session ? session.title : "未开始记录";
  const stateText = SESSION_STATES[session?.state] || "";
  $("session-meta").textContent = session ? `${stateText} · 开始于 ${dateText(session.startedAt)}${session.capturedOn ? ` · ${session.capturedOn}` : ""}` : "开始后机位录像并把逐拍结果归入本次记录。";
  $("elapsed").textContent = session ? duration(sessionElapsed(session)) : "—";
  const controllable = isControllable(session);
  $("start-row").hidden = controllable; $("run-row").hidden = !controllable;
  // Session buttons wait while a command is in flight or the camera is pausing or finishing.
  const waiting = state.pending ? "已发送到机位，等待机位确认…" : connected && status?.busy ? "机位正在保存录像与分析…" : "";
  for (const id of ["wake", "near", "far", "preview-toggle"]) $(id).disabled = !connected;
  for (const id of ["start", "pause", "finish"]) $(id).disabled = !connected || !!waiting;
  $("pause").textContent = session?.state === "active" ? "暂停" : "继续";
  for (const id of ["marker", "marker-review"]) $(id).disabled = !connected || session?.state !== "active" || !!waiting;
  $("session-wait").textContent = session?.state === "interrupted" && !waiting
    ? "机位上的这次记录意外中断（机位曾重启）。点「继续」恢复录像，或点「结束」保存。"
      : session?.state === "paused" && !waiting ? "暂停中不能标记；点「继续」后可以标记精彩或待复核。" : waiting;
  $("session-wait").hidden = !$("session-wait").textContent;
  if (status && document.activeElement !== $("near")) $("near").value = status.near || "right";
  if (status && document.activeElement !== $("far")) $("far").value = status.far || "right";

  const calibrationState = status?.analysis?.calibration || (open ? session?.tennisCalibration : state.recentCalibration);
  $("calibration-state").textContent = calibrationState?.isAvailable
      ? `球场映射：自动，${calibrationState.landmarkCount} 个场地参考点${Number.isFinite(calibrationState.validationErrorMeters) ? `，残差 ${calibrationState.validationErrorMeters.toFixed(2)} m` : ""}。`
      : `还没识别出球场（${calibrationState?.reason || "等待场地地标"}）。识别出来前不画落点、不判界内外。`;

  // Preview
  $("preview-toggle").textContent = state.previewOn ? "关闭实时画面" : "打开实时画面";
  if (state.previewOn) {
    const stale = Date.now() - state.lastFrameAt > 3000;
    $("preview-note").textContent = status?.shed >= 2 ? "画面暂停：机位负载高（数据照常）" : stale ? "等待画面…（机位未采集时没有画面）" : "低清 · 有延迟";
  } else $("preview-note").textContent = "打开后显示机位的低清画面（640×360，最多每秒 5 张，有延迟）。只用于确认机位朝向与取景。";

  renderAnalysis(open, calibrationState);
  renderBoard();
}

function renderAnalysis(open, calibrationState) {
  const rows = dashboardRows();
  const speeds = rows.map((r) => r.speedKPH).filter(validSpeed);
  const latest = rows[rows.length - 1];
  $("speed-latest").textContent = speedText(latest?.speedKPH);
  $("speed-average").textContent = speeds.length ? speedText(speeds.reduce((a, b) => a + b, 0) / speeds.length) : "—";
  $("speed-max").textContent = speeds.length ? speedText(Math.max(...speeds)) : "—";
  $("speed-note").textContent = rows.length === 0
    ? (state.status?.analysis?.available ? "出现击球后显示球速。" : `机位分析还没准备好：${state.status?.analysis?.reason || "请看机位状态"}`)
    : `${open ? "本次记录" : "未开始记录 · 最近几拍"} · ${speeds.length} 拍有球速 · ${rows.length - speeds.length} 拍暂无球速${latest && !validSpeed(latest.speedKPH) ? ` · 最近一拍：${speedReason(latest)}` : ""}`;

  // Court map: x 0…10.97 m left→right, y 0 at the near baseline; far end at the top.
  const W = 10.97, L = 23.77, flip = (y) => L - y;
  const lines = [
    [0, 0, W, 0], [0, L, W, L], [0, 0, 0, L], [W, 0, W, L], [1.37, 0, 1.37, L], [9.6, 0, 9.6, L],
    [1.37, 5.485, 9.6, 5.485], [1.37, 18.285, 9.6, 18.285], [5.485, 5.485, 5.485, 18.285],
  ].map(([x1, y1, x2, y2]) => `<line x1="${x1}" y1="${flip(y1)}" x2="${x2}" y2="${flip(y2)}" stroke="rgba(255,255,255,0.55)" stroke-width="0.06"/>`).join("");
  // Court colours are the App's tokens (courtSurface / courtLine / courtNet, docs/design-system.md).
  const net = `<line x1="-0.9" y1="${L / 2}" x2="${W + 0.9}" y2="${L / 2}" stroke="rgba(255,255,255,0.8)" stroke-width="0.09" stroke-dasharray="0.3 0.2"/>`;
  // Numbered by place in the list (the 「拍次」 of the speed chart); the newest is drawn last, larger, ringed.
  const placed = rows.map((shot, i) => ({ shot, number: i + 1 })).filter(({ shot }) => hasPlacement(shot));
  const dots = placed.map(({ shot, number }, i) => {
    const last = i === placed.length - 1, label = esc(bounceLabel(shot, number));
    return `<path d="${markPath(shot.stroke, shot.bounce.xMeters, flip(shot.bounce.yMeters), last ? 0.5 : 0.36)}" fill="${strokeColor(shot.stroke)}" stroke="${last ? "#fff" : "rgba(0,0,0,0.45)"}" stroke-width="${last ? 0.1 : 0.04}" role="img" aria-label="${label}"><title>${label}</title></path>`;
  }).join("");
  const court = $("court");
  court.setAttribute("aria-label", `球场落点图，${placed.length} 拍有落点`);
  court.innerHTML = `<rect x="-1.5" y="-1.5" width="13.97" height="26.77" fill="#0e2921" rx="0.5"/>${lines}${net}${dots}<text x="${W / 2}" y="-0.4" font-size="0.6" fill="rgba(255,255,255,0.6)" text-anchor="middle" aria-hidden="true">远端</text><text x="${W / 2}" y="${L + 1}" font-size="0.6" fill="rgba(255,255,255,0.6)" text-anchor="middle" aria-hidden="true">近端（机位侧）</text>`;
  const kinds = STROKE_ORDER.filter((k) => placed.some(({ shot }) => shot.stroke === k));
  $("placement-legend").innerHTML = kinds.map((k) => `<span>${markIcon(k)}${STROKES[k]}</span>`).join("");
  $("placement-note").textContent = rows.length === 0 ? "出现击球后，落点会画在球场图上。"
    : placed.length === 0 ? (calibrationState && !calibrationState.isAvailable ? "还没识别出球场，暂不画落点。" : `最近一拍：${placementReason(latest)}`)
      : `${placed.length} 拍有落点 · ${rows.length - placed.length} 拍暂无落点`;

  // Strokes
  $("strokes").innerHTML = rows.length === 0 ? `<p class="muted small">出现击球候选后，按动作类别统计拍数。</p>`
    : `<div class="bars">${STROKE_ORDER.map((kind) => {
      const count = rows.filter((r) => r.stroke === kind).length;
      if (!count) return "";
      return `<div class="item"><div class="row between">${strokeTag(kind)}<span class="muted">${count} 拍</span></div><div class="track"><div class="fill" style="width:${(100 * count) / rows.length}%;background:${strokeColor(kind)}"></div></div></div>`;
    }).join("")}</div>`;

  // Shot list: newest first; keep an open clip player in place.
  const list = $("shots");
  const sessionID = open ? state.session.id : null;
  const firstPTS = rows[0]?.sourcePTS;
  // A new session starts from the first page again.
  const listKey = sessionID || "recent";
  if (state.liveSession !== listKey) { state.liveSession = listKey; state.liveLimit = PAGE; }
  const wanted = rows.slice(-state.liveLimit).reverse();
  const existing = new Map([...list.children].map((li) => [li.dataset.shot, li]));
  const fragment = document.createDocumentFragment();
  for (const shot of wanted) {
    const html = shotItem(shot, sessionID, firstPTS);
    const current = existing.get(shot.id);
    if (current && current.dataset.html === html) { fragment.appendChild(current); continue; }
    const template = document.createElement("template");
    template.innerHTML = html;
    const item = template.content.firstElementChild;
    item.dataset.html = html;
    const video = current?.querySelector("video");
    if (video) item.appendChild(video);
    fragment.appendChild(item);
  }
  list.replaceChildren(fragment);
  $("shots-empty").hidden = rows.length > 0;
  pager($("shots-more"), $("shots-count"), rows.length, wanted.length);
}

setInterval(() => { if (state.session?.state === "active") $("elapsed").textContent = duration(sessionElapsed(state.session)); }, 1000);

// MARK: Start

readToken();
if (state.token) connect(); else showLogin();
// Opening a new QR link in a tab that already shows this page changes only the fragment.
window.addEventListener("hashchange", () => {
  if (!new URLSearchParams(location.hash.slice(1)).get("t")) return;
  readToken();
  state.closedByUs = false; state.attempt = 0; state.sentMac = false;
  const old = state.socket; state.socket = null; old?.close();
  connect();
});
