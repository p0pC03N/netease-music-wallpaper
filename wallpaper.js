const els = {
  body: document.body,
  visualizer: document.getElementById("visualizer"),
  ring: document.getElementById("ring"),
  cover: document.getElementById("cover"),
  backdropCovers: [
    document.getElementById("backdropCoverA"),
    document.getElementById("backdropCoverB")
  ],
  status: document.getElementById("status"),
  title: document.getElementById("title"),
  artist: document.getElementById("artist"),
  album: document.getElementById("album"),
  mediaProbe: document.getElementById("mediaProbe"),
  audioProbe: document.getElementById("audioProbe"),
  timeline: document.getElementById("timeline"),
  progress: document.getElementById("progress"),
  position: document.getElementById("position"),
  duration: document.getElementById("duration"),
  clockTime: document.getElementById("clockTime"),
  clockDate: document.getElementById("clockDate"),
  playlistPanel: document.getElementById("playlistPanel"),
  playlistToggle: document.getElementById("playlistToggle"),
  playlistItems: document.getElementById("playlistItems")
};

const state = {
  mediaEnabled: true,
  playback: "waiting",
  bridgeUpdatedAt: 0,
  bridgeSequence: 0,
  bridgeConfidence: 0,
  bridgeSongId: "",
  bridgeLastSeenAt: 0,
  title: "",
  artist: "",
  albumTitle: "",
  position: 0,
  duration: 0,
  hasTimeline: false,
  timelineRatioText: "",
  timelinePositionSecond: -1,
  timelineDurationSecond: -1,
  playlist: [],
  sidebarOpen: false,
  hasCover: false,
  primaryColor: "rgb(30, 72, 74)",
  secondaryColor: "rgb(214, 78, 72)",
  tertiaryColor: "rgb(238, 193, 77)",
  textColor: "rgb(249, 250, 246)",
  highContrastColor: "rgb(255, 255, 255)",
  visualStyle: "ringbars",
  visualIntensity: 1,
  showClock: true,
  showTimeline: true,
  coverRoundness: 28,
  brightness: 1.24,
  audio: new Array(128).fill(0),
  smooth: new Array(128).fill(0),
  barPeaks: new Array(48).fill(0),
  beat: 0,
  bassPulse: 0,
  audioListenerRegistered: false,
  audioRegisteredAt: 0,
  audioUnavailable: false,
  lastAudioAt: 0,
  audioProbeLastUpdate: 0,
  syntheticAudio: false,
  mockMode: false,
  coverSrc: "",
  pendingCoverSrc: "",
  displayedCoverSrc: "",
  activeBackdropIndex: 0,
  coverPaletteToken: 0,
  coverPaletteSrc: "",
  animationFrameId: 0,
  animationTimerId: 0,
  lastRenderedAt: 0,
  lastBridgePollAt: 0,
  lastClockUpdateAt: 0,
  lastMediaUpdateAt: 0,
  lastAudioHealthAt: 0,
  bridgePollTimerId: 0,
  clockTimerId: 0,
  mediaTimerId: 0,
  audioHealthTimerId: 0,
  mockTimerId: 0
};

const ctx = els.visualizer.getContext("2d");
const ringCtx = els.ring.getContext("2d");
const bridgeBaseUrl = "http://127.0.0.1:39487";
let dpr = 1;
let lastFrame = 0;
let mockPhase = 0;
const rootStyle = document.documentElement.style;
const rootVarCache = new Map();
const ACTIVE_FRAME_INTERVAL = 1000 / 45;
const ACTIVE_BRIDGE_POLL_INTERVAL = 2000;
const ACTIVE_STATUS_INTERVAL = 1000;

function currentBridgePollInterval() {
  return ACTIVE_BRIDGE_POLL_INTERVAL;
}

function currentStatusInterval() {
  return ACTIVE_STATUS_INTERVAL;
}

function scheduleTimer(name, callback, delay) {
  const key = `${name}TimerId`;
  if (state[key]) {
    clearTimeout(state[key]);
  }
  state[key] = window.setTimeout(() => {
    state[key] = 0;
    callback();
  }, delay);
}

function stopAnimation() {
  if (state.animationFrameId) {
    cancelAnimationFrame(state.animationFrameId);
    state.animationFrameId = 0;
  }
  if (state.animationTimerId) {
    clearTimeout(state.animationTimerId);
    state.animationTimerId = 0;
  }
}

function scheduleAnimation(delay = 0) {
  stopAnimation();
  if (delay > 0) {
    state.animationTimerId = window.setTimeout(() => {
      state.animationTimerId = 0;
      state.animationFrameId = requestAnimationFrame(animate);
    }, delay);
  } else {
    state.animationFrameId = requestAnimationFrame(animate);
  }
}

function resizeCanvas(canvas) {
  const rect = canvas.getBoundingClientRect();
  canvas.width = Math.max(1, Math.floor(rect.width * dpr));
  canvas.height = Math.max(1, Math.floor(rect.height * dpr));
}

function resizeAll() {
  dpr = Math.min(window.devicePixelRatio || 1, 1.5);
  resizeCanvas(els.visualizer);
  resizeCanvas(els.ring);
}

function setText(node, value, fallback) {
  node.textContent = value && String(value).trim() ? value : fallback;
}

function normalizeThumbnail(src) {
  if (!src) {
    return "";
  }
  const value = String(src).trim();
  if (value.startsWith("data:image/") || value.startsWith("blob:") || value.startsWith("runtime/")) {
    return value;
  }
  if (/^https?:\/\//i.test(value)) {
    try {
      const url = new URL(value);
      return url.href;
    } catch {
      return "";
    }
  }
  return `data:image/png;base64,${value}`;
}

function isBridgeFresh() {
  return Boolean(state.bridgeSongId && state.bridgeUpdatedAt && Date.now() - state.bridgeUpdatedAt < 12000);
}

function clearCover() {
  state.coverSrc = "";
  state.pendingCoverSrc = "";
  state.displayedCoverSrc = "";
  state.coverPaletteToken += 1;
  state.coverPaletteSrc = "";
  state.hasCover = false;
  els.body.classList.remove("has-cover");
  els.cover.removeAttribute("src");
  els.backdropCovers.forEach((node) => {
    node.classList.remove("is-active");
    node.removeAttribute("src");
  });
}

function setCover(src, options = {}) {
  const imageSrc = normalizeThumbnail(src);
  if (imageSrc) {
    if (state.coverSrc === imageSrc || state.pendingCoverSrc === imageSrc) {
      return;
    }
    state.pendingCoverSrc = imageSrc;
    const token = state.coverPaletteToken + 1;
    state.coverPaletteToken = token;

    const preload = new Image();
    preload.onload = () => {
      if (state.pendingCoverSrc !== imageSrc || token !== state.coverPaletteToken) {
        return;
      }
      state.coverSrc = imageSrc;
      state.displayedCoverSrc = imageSrc;
      state.pendingCoverSrc = "";
      state.hasCover = true;
      els.cover.src = imageSrc;
      swapBackdropCover(imageSrc);
      els.body.classList.add("has-cover");
      applyPaletteFromCover(preload, imageSrc, token);
    };
    preload.onerror = () => {
      if (state.pendingCoverSrc === imageSrc) {
        state.pendingCoverSrc = "";
      }
      if (!state.displayedCoverSrc) {
        state.hasCover = false;
        els.body.classList.remove("has-cover");
      }
    };

    preload.src = imageSrc;
    if (preload.complete && preload.naturalWidth) {
      preload.onload();
    }
  } else {
    if (state.displayedCoverSrc && !options.forceClear) {
      return;
    }
    clearCover();
  }
}

function swapBackdropCover(imageSrc) {
  const current = els.backdropCovers[state.activeBackdropIndex];
  const nextIndex = state.activeBackdropIndex === 0 ? 1 : 0;
  const next = els.backdropCovers[nextIndex];

  if (!current || !next) {
    return;
  }

  if (current.getAttribute("src") === imageSrc) {
    current.classList.add("is-active");
    next.classList.remove("is-active");
    return;
  }

  next.src = imageSrc;
  next.classList.add("is-active");
  current.classList.remove("is-active");
  state.activeBackdropIndex = nextIndex;
}

function applyBridgePayload(payload) {
  if (!payload) {
    return;
  }
  const updatedAt = Number(payload.updatedAt) || Date.now();
  const sequence = Number(payload.sequence) || 0;
  const nextSongId = payload.id ? String(payload.id) : "";
  const confidenceLevels = { none: 0, low: 1, medium: 2, high: 3 };
  const declaredConfidence = confidenceLevels[payload.confidence] || 0;
  const nextConfidence = nextSongId === state.bridgeSongId
    ? Math.max(declaredConfidence, state.bridgeConfidence)
    : declaredConfidence;
  if (sequence > 0 && state.bridgeSequence > 0 && sequence <= state.bridgeSequence) {
    return;
  }
  if (updatedAt <= state.bridgeUpdatedAt) {
    return;
  }
  if (nextSongId && nextSongId !== state.bridgeSongId && nextConfidence < state.bridgeConfidence) {
    return;
  }

  if (!nextSongId) {
    state.bridgeUpdatedAt = updatedAt;
    state.bridgeSequence = sequence;
    state.bridgeConfidence = nextConfidence;
    state.bridgeLastSeenAt = Date.now();
    state.bridgeSongId = "";
    state.playback = payload.playback || "waiting";
    state.title = "";
    state.artist = "";
    state.albumTitle = "";
    state.position = 0;
    state.duration = 0;
    state.hasTimeline = false;
    state.playlist = [];
    clearCover();
    updateMediaText();
    updatePlaybackClass();
    updateTimeline();
    renderPlaylist();
    return;
  }

  const previousSongId = state.bridgeSongId;
  state.bridgeUpdatedAt = updatedAt;
  state.bridgeSequence = sequence;
  state.bridgeConfidence = nextConfidence;
  state.bridgeLastSeenAt = Date.now();
  state.bridgeSongId = nextSongId;
  state.title = payload.title || payload.name || state.title;
  state.artist = payload.artist || state.artist;
  state.albumTitle = payload.album || state.albumTitle;
  state.duration = Number(payload.durationSeconds) || state.duration;
  state.hasTimeline = state.duration > 0;
  state.playback = payload.playback || "playing";
  if (previousSongId !== nextSongId) {
    state.position = Number(payload.positionSeconds) || 0;
  } else if (Number.isFinite(Number(payload.positionSeconds))) {
    state.position = Number(payload.positionSeconds);
  }
  state.playlist = Array.isArray(payload.playlist) ? payload.playlist : state.playlist;

  if (payload.cover) {
    setCover(payload.cover);
  }

  updateMediaText();
  updatePlaybackClass();
  updateTimeline();
  renderPlaylist();
}

function applyColors(event) {
  state.primaryColor = event.primaryColor || state.primaryColor;
  state.secondaryColor = event.secondaryColor || state.secondaryColor;
  state.tertiaryColor = event.tertiaryColor || state.tertiaryColor;
  state.textColor = event.textColor || state.textColor;
  state.highContrastColor = event.highContrastColor || state.highContrastColor;

  setRootVar("--primary", state.primaryColor);
  setRootVar("--secondary", state.secondaryColor);
  setRootVar("--tertiary", state.tertiaryColor);
  setRootVar("--text", state.textColor);
  setRootVar("--muted", colorWithAlpha(state.textColor, 0.78));
  setRootVar("--visual-low", colorWithAlpha(state.secondaryColor, 0.2));
  setRootVar("--visual-mid", state.secondaryColor);
  setRootVar("--visual-high", state.tertiaryColor);
  setRootVar("--progress-rest", colorWithAlpha(state.textColor, 0.18));
  setRootVar("--cover-line", colorWithAlpha(state.tertiaryColor, 0.5));
}

function colorWithAlpha(color, alpha) {
  const rgb = color.match(/\d+(\.\d+)?/g);
  if (!rgb || rgb.length < 3) {
    return `rgba(249, 250, 246, ${alpha})`;
  }
  return `rgba(${Math.round(rgb[0])}, ${Math.round(rgb[1])}, ${Math.round(rgb[2])}, ${alpha})`;
}

function setRootVar(name, value) {
  if (rootVarCache.get(name) === value) {
    return;
  }
  rootVarCache.set(name, value);
  rootStyle.setProperty(name, value);
}

function rgbString(rgb) {
  return `rgb(${Math.round(rgb.r)}, ${Math.round(rgb.g)}, ${Math.round(rgb.b)})`;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function rgbToHsl({ r, g, b }) {
  r /= 255;
  g /= 255;
  b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  let h = 0;
  let s = 0;
  const l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r:
        h = (g - b) / d + (g < b ? 6 : 0);
        break;
      case g:
        h = (b - r) / d + 2;
        break;
      default:
        h = (r - g) / d + 4;
        break;
    }
    h /= 6;
  }
  return { h, s, l };
}

function hueToRgb(p, q, t) {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < 1 / 2) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
}

function hslToRgb({ h, s, l }) {
  let r;
  let g;
  let b;
  if (s === 0) {
    r = l;
    g = l;
    b = l;
  } else {
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    r = hueToRgb(p, q, h + 1 / 3);
    g = hueToRgb(p, q, h);
    b = hueToRgb(p, q, h - 1 / 3);
  }
  return { r: r * 255, g: g * 255, b: b * 255 };
}

function tuneColor(rgb, options = {}) {
  const hsl = rgbToHsl(rgb);
  return hslToRgb({
    h: hsl.h,
    s: clamp(options.s ?? hsl.s, 0, 0.86),
    l: clamp(options.l ?? hsl.l, 0.22, 0.74)
  });
}

function perceivedLightness(rgb) {
  return (rgb.r * 0.2126 + rgb.g * 0.7152 + rgb.b * 0.0722) / 255;
}

function applyPaletteFromCover(img, src, token) {
  if (!img.naturalWidth || !img.naturalHeight || token !== state.coverPaletteToken) {
    return;
  }

  try {
    const canvas = document.createElement("canvas");
    const size = 64;
    canvas.width = size;
    canvas.height = size;
    const paletteCtx = canvas.getContext("2d", { willReadFrequently: true });
    paletteCtx.drawImage(img, 0, 0, size, size);
    const data = paletteCtx.getImageData(0, 0, size, size).data;
    const buckets = new Map();

    for (let i = 0; i < data.length; i += 4) {
      const alpha = data[i + 3];
      if (alpha < 210) {
        continue;
      }
      const rgb = { r: data[i], g: data[i + 1], b: data[i + 2] };
      const hsl = rgbToHsl(rgb);
      if (hsl.l < 0.08 || hsl.l > 0.94) {
        continue;
      }
      const key = `${Math.round(rgb.r / 18)}:${Math.round(rgb.g / 18)}:${Math.round(rgb.b / 18)}`;
      const bucket = buckets.get(key) || { r: 0, g: 0, b: 0, count: 0, s: 0, l: 0 };
      bucket.r += rgb.r;
      bucket.g += rgb.g;
      bucket.b += rgb.b;
      bucket.s += hsl.s;
      bucket.l += hsl.l;
      bucket.count += 1;
      buckets.set(key, bucket);
    }

    const colors = Array.from(buckets.values()).map((bucket) => {
      const rgb = {
        r: bucket.r / bucket.count,
        g: bucket.g / bucket.count,
        b: bucket.b / bucket.count
      };
      const hsl = rgbToHsl(rgb);
      return { rgb, hsl, count: bucket.count };
    });
    if (colors.length < 3) {
      return;
    }

    const dominant = colors
      .filter((color) => color.hsl.l > 0.14 && color.hsl.l < 0.78)
      .sort((a, b) => (b.count * (0.55 + b.hsl.s)) - (a.count * (0.55 + a.hsl.s)))[0] || colors[0];
    const accent = colors
      .filter((color) => color.hsl.l > 0.2 && color.hsl.l < 0.82)
      .sort((a, b) => ((b.hsl.s * 2.1 + b.hsl.l * 0.42) * Math.log(b.count + 2)) - ((a.hsl.s * 2.1 + a.hsl.l * 0.42) * Math.log(a.count + 2)))[0] || dominant;
    const primary = tuneColor(dominant.rgb, {
      s: clamp(dominant.hsl.s * 0.82, 0.18, 0.56),
      l: clamp(dominant.hsl.l * 0.86, 0.24, 0.48)
    });
    const secondary = tuneColor(accent.rgb, {
      s: clamp(accent.hsl.s * 1.08, 0.38, 0.78),
      l: clamp(accent.hsl.l * 1.02, 0.42, 0.62)
    });
    const tertiary = tuneColor(accent.rgb, {
      s: clamp(accent.hsl.s * 0.92, 0.32, 0.74),
      l: clamp(accent.hsl.l * 1.32, 0.56, 0.76)
    });
    const text = perceivedLightness(primary) > 0.54 ? "rgb(18, 22, 24)" : "rgb(249, 250, 246)";

    state.coverPaletteSrc = src;
    applyColors({
      primaryColor: rgbString(primary),
      secondaryColor: rgbString(secondary),
      tertiaryColor: rgbString(tertiary),
      textColor: text,
      highContrastColor: text
    });
  } catch {
    // Some external thumbnails can taint canvas; keep the existing palette in that case.
  }
}

function updateMediaText() {
  setText(els.title, state.title, state.mediaEnabled ? "等待网易云音乐" : "媒体集成未启用");
  setText(els.artist, state.artist, state.mediaEnabled ? "播放歌曲后读取 Windows 媒体会话" : "请在 Wallpaper Engine 设置中启用媒体集成");
  setText(els.album, state.albumTitle, state.hasTimeline ? "" : "如果网易云没有传出封面，这里仍会保留音频响应");

  const label = {
    playing: "正在播放",
    paused: "已暂停",
    stopped: "播放已停止",
    waiting: "等待媒体信息"
  }[state.playback] || "等待媒体信息";
  els.status.textContent = state.mockMode ? `${label} · 浏览器预览` : label;
  els.body.classList.toggle("has-media", Boolean(state.title || state.artist || state.albumTitle || state.hasCover));
  els.body.classList.remove("is-wallpaper-suspended", "is-low-power");
  els.body.dataset.powerState = "active";
  els.body.dataset.animationState = state.animationFrameId || state.animationTimerId ? "scheduled" : "idle";
  const source = state.bridgeSongId ? "桥接" : "媒体";
  const seen = state.bridgeUpdatedAt ? ` ${formatClockTime(new Date(state.bridgeUpdatedAt))}` : "";
  if (state.bridgeSongId && !isBridgeFresh()) {
    els.mediaProbe.textContent = `${source}: 数据过期${seen}`;
  } else {
    els.mediaProbe.textContent = state.hasCover || state.title ? `${source}: 已连接${seen}` : "桥接: 等待";
  }
}

function updatePlaybackClass() {
  els.body.classList.toggle("is-paused", state.playback === "paused");
  els.body.classList.toggle("is-stopped", state.playback === "stopped" || state.playback === "waiting");
}

function updateTimeline() {
  const show = state.showTimeline && state.hasTimeline && state.duration > 0;
  els.body.classList.toggle("hide-timeline", !show);
  if (!show) {
    return;
  }
  const ratio = Math.min(Math.max(state.position / state.duration, 0), 1);
  const ratioText = ratio.toFixed(4);
  if (ratioText !== state.timelineRatioText) {
    state.timelineRatioText = ratioText;
    els.progress.style.transform = `scaleX(${ratioText})`;
  }

  const positionSecond = Math.floor(state.position);
  const durationSecond = Math.floor(state.duration);
  if (positionSecond !== state.timelinePositionSecond) {
    state.timelinePositionSecond = positionSecond;
    els.position.textContent = formatTime(positionSecond);
  }
  if (durationSecond !== state.timelineDurationSecond) {
    state.timelineDurationSecond = durationSecond;
    els.duration.textContent = formatTime(durationSecond);
  }
}

function renderPlaylist() {
  if (!els.playlistItems) {
    return;
  }

  els.playlistItems.innerHTML = "";
  if (!state.playlist.length) {
    const empty = document.createElement("div");
    empty.className = "playlist-empty";
    empty.textContent = "等待歌单";
    els.playlistItems.appendChild(empty);
    return;
  }

  const items = state.playlist.slice(0, 80);
  for (const item of items) {
    const row = document.createElement("div");
    row.className = `playlist-item${String(item.id) === state.bridgeSongId || item.current ? " is-current" : ""}`;

    const order = document.createElement("span");
    order.className = "playlist-order";
    order.textContent = Number.isFinite(Number(item.displayOrder)) ? String(Number(item.displayOrder) + 1).padStart(2, "0") : "--";

    const text = document.createElement("span");
    text.className = "playlist-text";

    const title = document.createElement("span");
    title.className = "playlist-song";
    title.textContent = item.title || "未知歌曲";

    const artist = document.createElement("span");
    artist.className = "playlist-artist";
    artist.textContent = item.artist || "";

    text.appendChild(title);
    text.appendChild(artist);
    row.appendChild(order);
    row.appendChild(text);
    els.playlistItems.appendChild(row);
  }
}

function formatTime(seconds) {
  const safe = Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
  const mins = Math.floor(safe / 60);
  const secs = Math.floor(safe % 60);
  return `${mins}:${String(secs).padStart(2, "0")}`;
}

function tickClock() {
  const now = new Date();
  els.clockTime.textContent = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
  els.clockDate.textContent = `${now.getFullYear()}.${String(now.getMonth() + 1).padStart(2, "0")}.${String(now.getDate()).padStart(2, "0")}`;
}

function formatClockTime(date) {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
}

function drawBars(width, height) {
  const bars = 48;
  const baseY = height * 0.88;
  const gap = Math.max(2 * dpr, width * 0.002);
  const barWidth = Math.max(3 * dpr, (width * 0.76) / bars - gap);
  const startX = (width - (barWidth + gap) * bars) / 2;
  const capHeight = Math.max(3 * dpr, barWidth * 0.16);

  if (state.barPeaks.length !== bars) {
    state.barPeaks = new Array(bars).fill(0);
  }

  ctx.save();
  ctx.globalCompositeOperation = "source-over";
  ctx.globalAlpha = 0.82;
  ctx.translate(0, Math.sin(performance.now() * 0.0004) * 8 * dpr);
  for (let i = 0; i < bars; i += 1) {
    const band = Math.floor((i / (bars - 1)) * 63);
    const left = state.smooth[band];
    const right = state.smooth[127 - band];
    const v = Math.min((left + right) * 0.5 * state.visualIntensity, 1.25);
    const h = Math.max(2 * dpr, Math.pow(v, 0.8) * height * 0.32);
    const x = startX + i * (barWidth + gap);
    const grad = ctx.createLinearGradient(0, baseY - h, 0, baseY);
    grad.addColorStop(0, state.tertiaryColor);
    grad.addColorStop(0.55, state.secondaryColor);
    grad.addColorStop(1, colorWithAlpha(state.secondaryColor, 0.12));
    ctx.fillStyle = grad;
    roundRect(ctx, x, baseY - h, barWidth, h, barWidth * 0.5);
    ctx.fill();

    state.barPeaks[i] = Math.max(h, state.barPeaks[i] - height * 0.0045);
    const peakY = baseY - state.barPeaks[i] - capHeight * 1.6;
    ctx.globalAlpha = 0.46 + Math.min(v, 1) * 0.28;
    ctx.fillStyle = i % 3 === 0 ? colorWithAlpha(state.tertiaryColor, 0.9) : colorWithAlpha(state.textColor, 0.58);
    roundRect(ctx, x, peakY, barWidth, capHeight, capHeight * 0.5);
    ctx.fill();
    ctx.globalAlpha = 0.82;
  }
  ctx.restore();
}

function drawWave(width, height) {
  const centerY = height * 0.78;
  const amp = height * 0.12 * state.visualIntensity;
  ctx.save();
  ctx.lineWidth = Math.max(2, 3 * dpr);
  ctx.strokeStyle = colorWithAlpha(state.tertiaryColor, 0.42);
  ctx.shadowColor = colorWithAlpha(state.secondaryColor, 0.26);
  ctx.shadowBlur = 5 * dpr;
  ctx.beginPath();
  for (let x = 0; x <= width; x += width / 120) {
    const idx = Math.min(63, Math.floor((x / width) * 63));
    const v = (state.smooth[idx] + state.smooth[idx + 64]) * 0.5;
    const y = centerY + Math.sin(x * 0.014 + performance.now() * 0.003) * amp * (0.18 + v);
    if (x === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  ctx.stroke();
  ctx.restore();
}

function drawRing() {
  const width = els.ring.width;
  const height = els.ring.height;
  const cx = width / 2;
  const cy = height / 2;
  const pulse = Math.min(state.bassPulse * state.visualIntensity, 1);
  const radius = Math.min(width, height) * (0.31 + pulse * 0.035);
  const count = 72;
  ringCtx.clearRect(0, 0, width, height);
  ringCtx.save();
  ringCtx.translate(cx, cy);
  ringCtx.globalCompositeOperation = "source-over";
  ringCtx.shadowColor = colorWithAlpha(state.secondaryColor, 0.22);
  ringCtx.shadowBlur = 2.5 * dpr;

  if (pulse > 0.08) {
    ringCtx.save();
    ringCtx.globalAlpha = pulse * 0.22;
    ringCtx.lineWidth = (1.4 + pulse * 3.2) * dpr;
    ringCtx.strokeStyle = colorWithAlpha(state.tertiaryColor, 0.7);
    ringCtx.beginPath();
    ringCtx.arc(0, 0, radius + (92 + pulse * 54) * dpr, 0, Math.PI * 2);
    ringCtx.stroke();
    ringCtx.restore();
  }

  for (let i = 0; i < count; i += 1) {
    const t = i / count;
    const source = (i % 2 === 0) ? Math.floor(t * 63) : 64 + Math.floor((1 - t) * 63);
    const v = Math.min(state.smooth[source] * state.visualIntensity, 1.2);
    const length = (28 + pulse * 16 + Math.pow(v, 0.78) * 112) * dpr;
    const angle = t * Math.PI * 2 - Math.PI / 2;
    ringCtx.save();
    ringCtx.rotate(angle);
    ringCtx.fillStyle = i % 3 === 0 ? state.tertiaryColor : colorWithAlpha(state.secondaryColor, 0.78);
    ringCtx.globalAlpha = 0.16 + pulse * 0.12 + Math.min(v, 1) * 0.48;
    roundRect(ringCtx, radius, -2.2 * dpr, length, 4.4 * dpr, 4 * dpr);
    ringCtx.fill();
    ringCtx.restore();
  }
  ringCtx.restore();
}

function roundRect(context, x, y, width, height, radius) {
  const r = Math.min(radius, width / 2, height / 2);
  context.beginPath();
  context.moveTo(x + r, y);
  context.arcTo(x + width, y, x + width, y + height, r);
  context.arcTo(x + width, y + height, x, y + height, r);
  context.arcTo(x, y + height, x, y, r);
  context.arcTo(x, y, x + width, y, r);
  context.closePath();
}

function animate(ts) {
  state.animationFrameId = 0;
  const frameInterval = ACTIVE_FRAME_INTERVAL;
  if (state.lastRenderedAt && ts - state.lastRenderedAt < frameInterval) {
    scheduleAnimation(frameInterval - (ts - state.lastRenderedAt));
    return;
  }
  state.lastRenderedAt = ts;

  const width = els.visualizer.width;
  const height = els.visualizer.height;
  const dt = Math.min(48, ts - lastFrame || 16);
  lastFrame = ts;

  if (state.mockMode || state.syntheticAudio) {
    generateMockAudio(dt);
  }

  for (let i = 0; i < state.audio.length; i += 1) {
    const target = Math.min(Number(state.audio[i]) || 0, 1.4);
    const ease = target > state.smooth[i] ? 0.34 : 0.11;
    state.smooth[i] += (target - state.smooth[i]) * ease;
  }

  let lowSum = 0;
  let beatSum = 0;
  for (let i = 0; i < 10; i += 1) {
    const value = state.smooth[i] || 0;
    lowSum += value;
    if (i < 6) {
      beatSum += value;
    }
  }
  const lowEnergy = lowSum / 10;
  state.beat = beatSum / 6;
  const bassTarget = Math.min(Math.max((lowEnergy - 0.05) * 1.45 * state.visualIntensity, 0), 1);
  const bassEase = bassTarget > state.bassPulse ? 0.26 : 0.075;
  state.bassPulse += (bassTarget - state.bassPulse) * bassEase;
  const visualBeat = Math.min(state.beat * state.visualIntensity, 1);
  setRootVar("--beat", visualBeat.toFixed(3));
  setRootVar("--bass-pulse", state.bassPulse.toFixed(3));

  ctx.clearRect(0, 0, width, height);
  if (state.visualStyle !== "ring") {
    drawBars(width, height);
    drawWave(width, height);
  }
  if (state.visualStyle !== "bars") {
    drawRing();
  } else {
    ringCtx.clearRect(0, 0, els.ring.width, els.ring.height);
  }

  if (state.playback === "playing" && state.hasTimeline && state.duration > 0) {
    state.position = Math.min(state.duration, state.position + dt / 1000);
    updateTimeline();
  }

  scheduleAnimation(0);
}

function generateMockAudio(dt) {
  mockPhase += dt * 0.004;
  for (let i = 0; i < 128; i += 1) {
    const band = i % 64;
    const lowBias = Math.max(0, 1 - band / 64);
    const pulse = Math.max(0, Math.sin(mockPhase * 1.7)) * lowBias;
    const ripple = (Math.sin(mockPhase + band * 0.34) + 1) * 0.11;
    state.audio[i] = Math.min(1, 0.03 + ripple + pulse * 0.58 + Math.random() * 0.045);
  }
}

function mockCover() {
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="900" height="900" viewBox="0 0 900 900">
      <defs>
        <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#1e484a"/>
          <stop offset="0.48" stop-color="#d64e48"/>
          <stop offset="1" stop-color="#eec14d"/>
        </linearGradient>
      </defs>
      <rect width="900" height="900" fill="url(#g)"/>
      <circle cx="686" cy="206" r="122" fill="rgba(255,255,255,.22)"/>
      <path d="M205 602c94 78 244 86 354 14 72-47 112-118 121-205" fill="none" stroke="rgba(255,255,255,.72)" stroke-width="34" stroke-linecap="round"/>
      <circle cx="330" cy="392" r="72" fill="rgba(255,255,255,.82)"/>
      <rect x="384" y="226" width="28" height="246" rx="14" fill="rgba(255,255,255,.82)"/>
    </svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function startMockMode() {
  if (window.wallpaperRegisterAudioListener || state.mockMode) {
    return;
  }
  if (state.bridgeSongId) {
    state.mockMode = true;
    updateMediaText();
    return;
  }
  state.mockMode = true;
  state.playback = "playing";
  state.title = "网易云音乐响应壁纸";
  state.artist = "浏览器预览模式";
  state.albumTitle = "Wallpaper Engine 中会显示真实歌曲信息";
  state.duration = 245;
  state.position = 48;
  state.hasTimeline = true;
  setCover(mockCover());
  applyColors({
    primaryColor: "rgb(30, 72, 74)",
    secondaryColor: "rgb(214, 78, 72)",
    tertiaryColor: "rgb(238, 193, 77)",
    textColor: "rgb(249, 250, 246)",
    highContrastColor: "rgb(255,255,255)"
  });
  updateMediaText();
  updatePlaybackClass();
  updateTimeline();
}

function wallpaperAudioListener(audioArray) {
  const now = Date.now();
  state.lastAudioAt = now;
  state.syntheticAudio = false;
  let peak = 0;
  for (let i = 0; i < state.audio.length; i += 1) {
    const value = Math.min(Number(audioArray[i]) || 0, 1.4);
    state.audio[i] = value;
    if (value > peak) {
      peak = value;
    }
  }
  if (now - state.audioProbeLastUpdate > 250) {
    state.audioProbeLastUpdate = now;
    els.audioProbe.textContent = peak > 0.01 ? `音频: ${peak.toFixed(2)}` : "音频: 静音/未授权";
  }
}

function registerWallpaperEngine() {
  if (window.wallpaperRegisterAudioListener) {
    state.audioListenerRegistered = true;
    state.audioUnavailable = false;
    state.audioRegisteredAt = Date.now();
    els.audioProbe.textContent = "音频: 监听中";
    window.wallpaperRegisterAudioListener(wallpaperAudioListener);
  } else {
    state.audioUnavailable = true;
    els.audioProbe.textContent = "音频: WE接口缺失";
  }

  if (window.wallpaperRegisterMediaStatusListener) {
    window.wallpaperRegisterMediaStatusListener((event) => {
      state.mediaEnabled = Boolean(event.enabled);
      updateMediaText();
    });
  }

  if (window.wallpaperRegisterMediaPropertiesListener) {
    window.wallpaperRegisterMediaPropertiesListener((event) => {
      if (isBridgeFresh()) {
        return;
      }
      state.title = event.title || "";
      state.artist = event.artist || event.albumArtist || "";
      state.albumTitle = event.albumTitle || event.subTitle || "";
      updateMediaText();
    });
  }

  if (window.wallpaperRegisterMediaThumbnailListener) {
    window.wallpaperRegisterMediaThumbnailListener((event) => {
      if (event.thumbnail || !isBridgeFresh()) {
        setCover(event.thumbnail);
      }
      applyColors(event);
    });
  }

  if (window.wallpaperRegisterMediaPlaybackListener) {
    window.wallpaperRegisterMediaPlaybackListener((event) => {
      const api = window.wallpaperMediaIntegration || {};
      if (event.state === api.PLAYBACK_PLAYING) {
        state.playback = "playing";
      } else if (event.state === api.PLAYBACK_PAUSED) {
        state.playback = "paused";
      } else if (event.state === api.PLAYBACK_STOPPED) {
        state.playback = "stopped";
      } else {
        state.playback = "waiting";
      }
      updateMediaText();
      updatePlaybackClass();
    });
  }

  if (window.wallpaperRegisterMediaTimelineListener) {
    window.wallpaperRegisterMediaTimelineListener((event) => {
      state.position = Number(event.position) || 0;
      state.duration = Number(event.duration) || 0;
      state.hasTimeline = state.duration > 0;
      updateTimeline();
    });
  }
}

function updateAudioHealth() {
  if (state.mockMode) {
    return;
  }

  const now = Date.now();
  const hasRealAudio = state.lastAudioAt > 0 && now - state.lastAudioAt < 5000;
  if (hasRealAudio) {
    return;
  }

  const hasLiveSong = state.playback === "playing" && Boolean(
    state.bridgeSongId ||
    state.title ||
    state.artist ||
    state.albumTitle ||
    state.hasTimeline ||
    state.hasCover
  );
  if (!hasLiveSong) {
    state.syntheticAudio = false;
    if (!state.audioListenerRegistered) {
      els.audioProbe.textContent = state.audioUnavailable ? "音频: WE接口缺失" : "音频: 等待WE接口";
    }
    return;
  }

  if (!state.audioListenerRegistered) {
    state.syntheticAudio = true;
    els.audioProbe.textContent = state.audioUnavailable ? "音频: WE接口缺失·模拟" : "音频: 等待WE接口·模拟";
    return;
  }

  const waitedForCallback = state.audioRegisteredAt > 0 && now - state.audioRegisteredAt > 8000;
  if (state.lastAudioAt === 0) {
    els.audioProbe.textContent = hasLiveSong && waitedForCallback ? "音频: WE录音未启用" : "音频: 等待WE回调";
  } else {
    els.audioProbe.textContent = hasLiveSong ? "音频: 回调中断" : "音频: 静音/未授权";
  }

  state.syntheticAudio = hasLiveSong;
  if (state.syntheticAudio) {
    if (state.lastAudioAt === 0) {
      els.audioProbe.textContent = waitedForCallback ? "音频: WE录音未启用·模拟" : "音频: 等待WE回调·模拟";
    } else {
      els.audioProbe.textContent = "音频: 回调中断·模拟";
    }
  }
}

function scheduleBridgePoll(delay = currentBridgePollInterval()) {
  scheduleTimer("bridgePoll", () => {
    state.lastBridgePollAt = Date.now();
    loadBridgePayload();
    scheduleBridgePoll();
  }, delay);
}

function scheduleClockTick(delay = currentStatusInterval()) {
  scheduleTimer("clock", () => {
    state.lastClockUpdateAt = Date.now();
    tickClock();
    scheduleClockTick();
  }, delay);
}

function scheduleMediaTextUpdate(delay = currentStatusInterval()) {
  scheduleTimer("media", () => {
    state.lastMediaUpdateAt = Date.now();
    updateMediaText();
    scheduleMediaTextUpdate();
  }, delay);
}

function scheduleAudioHealthUpdate(delay = currentStatusInterval()) {
  scheduleTimer("audioHealth", () => {
    state.lastAudioHealthAt = Date.now();
    updateAudioHealth();
    scheduleAudioHealthUpdate();
  }, delay);
}

window.wallpaperPropertyListener = {
  applyUserProperties(properties) {
    if (properties.schemecolor) {
      const values = properties.schemecolor.value.split(" ").map((v) => Math.ceil(Number(v) * 255));
      const color = `rgb(${values[0]}, ${values[1]}, ${values[2]})`;
      state.secondaryColor = color;
      document.documentElement.style.setProperty("--secondary", color);
    }
    if (properties.visualstyle) {
      state.visualStyle = properties.visualstyle.value;
    }
    if (properties.visualintensity) {
      state.visualIntensity = Number(properties.visualintensity.value) || 1;
    }
    if (properties.showclock) {
      state.showClock = Boolean(properties.showclock.value);
      els.body.classList.toggle("hide-clock", !state.showClock);
    }
    if (properties.showtimeline) {
      state.showTimeline = Boolean(properties.showtimeline.value);
      updateTimeline();
    }
  if (properties.coverroundness) {
      state.coverRoundness = Number(properties.coverroundness.value) || 28;
      document.documentElement.style.setProperty("--cover-radius", `${state.coverRoundness}px`);
    }
    if (properties.brightness) {
      state.brightness = Number(properties.brightness.value) || 1.24;
      document.documentElement.style.setProperty("--brightness", String(state.brightness));
    }
    if (properties.layoutmode) {
      els.body.classList.toggle("layout-compact", properties.layoutmode.value === "compact");
    }
  }
};

window.addEventListener("netease-now-playing", (event) => {
  applyBridgePayload(event.detail);
});

function setSidebarOpen(open) {
  if (!els.playlistPanel || !els.playlistToggle) {
    return;
  }
  state.sidebarOpen = Boolean(open);
  els.playlistPanel.classList.toggle("is-open", state.sidebarOpen);
  els.playlistToggle.setAttribute("aria-expanded", String(state.sidebarOpen));
  els.playlistToggle.setAttribute("aria-label", state.sidebarOpen ? "收起播放列表" : "展开播放列表");
}

if (els.playlistToggle) {
  els.playlistToggle.setAttribute("aria-expanded", "false");
  els.playlistToggle.addEventListener("click", (event) => {
    event.stopImmediatePropagation();
    event.stopPropagation();
    setSidebarOpen(!state.sidebarOpen);
  }, true);
}

window.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    setSidebarOpen(false);
  }
});

window.addEventListener("pointerdown", (event) => {
  if (state.sidebarOpen && els.playlistPanel && !els.playlistPanel.contains(event.target)) {
    setSidebarOpen(false);
  }
});

if (els.playlistPanel) {
  els.playlistPanel.addEventListener("pointerdown", (event) => {
    event.stopPropagation();
  });
}

function loadBridgePayload() {
  if (window.fetch) {
    fetch(`${bridgeBaseUrl}/now-playing.json?ts=${Date.now()}`, { cache: "no-store" })
      .then((response) => response.ok ? response.json() : null)
      .then((payload) => {
        if (payload) {
          applyBridgePayload(payload);
        } else {
          loadBridgePayloadFromProject();
        }
      })
      .catch(() => loadBridgePayloadFromProject());
    return;
  }

  loadBridgePayloadScript();
}

function loadBridgePayloadFromProject() {
  fetch(`runtime/now-playing.json?ts=${Date.now()}`, { cache: "no-store" })
    .then((response) => response.ok ? response.json() : null)
    .then((payload) => {
      if (payload) {
        applyBridgePayload(payload);
      } else {
        loadBridgePayloadScript();
      }
    })
    .catch(() => loadBridgePayloadScript());
}

function loadBridgePayloadScript() {
  const old = document.getElementById("netease-bridge-payload");
  if (old) {
    old.remove();
  }
  const script = document.createElement("script");
  script.id = "netease-bridge-payload";
  script.src = `runtime/now-playing.js?ts=${Date.now()}`;
  script.onerror = () => {
    if (!state.bridgeSongId && !(state.hasCover || state.title)) {
      els.mediaProbe.textContent = "桥接: 未运行";
    }
  };
  document.head.appendChild(script);
}

resizeAll();
tickClock();
updateMediaText();
updatePlaybackClass();
updateTimeline();
registerWallpaperEngine();

window.addEventListener("resize", resizeAll);
state.mockTimerId = window.setTimeout(() => {
  state.mockTimerId = 0;
  startMockMode();
}, 900);
loadBridgePayload();
scheduleBridgePoll(ACTIVE_BRIDGE_POLL_INTERVAL);
scheduleClockTick(ACTIVE_STATUS_INTERVAL);
scheduleMediaTextUpdate(ACTIVE_STATUS_INTERVAL);
scheduleAudioHealthUpdate(ACTIVE_STATUS_INTERVAL);
scheduleAnimation(0);
