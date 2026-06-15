const http = require("http");

const port = Number(process.env.NETEASE_CDP_PORT || process.argv[2] || 9222);

function getJson(pathname, timeoutMs = 1200) {
  return new Promise((resolve, reject) => {
    const req = http.get(
      {
        host: "127.0.0.1",
        port,
        path: pathname,
        timeout: timeoutMs,
      },
      (res) => {
        let data = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => {
          try {
            resolve(JSON.parse(data));
          } catch (error) {
            reject(error);
          }
        });
      }
    );
    req.on("timeout", () => {
      req.destroy(new Error("CDP request timed out"));
    });
    req.on("error", reject);
  });
}

async function evaluate(wsUrl, expression) {
  const ws = new WebSocket(wsUrl);
  let nextId = 0;
  const pending = new Map();

  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  };

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("CDP websocket timed out")), 1500);
    ws.onopen = () => {
      clearTimeout(timer);
      resolve();
    };
    ws.onerror = (event) => {
      clearTimeout(timer);
      reject(new Error(String(event.message || "CDP websocket failed")));
    };
  });

  function send(method, params = {}) {
    const id = ++nextId;
    ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve) => pending.set(id, resolve));
  }

  await send("Runtime.enable");
  const result = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
    timeout: 2500,
  });
  ws.close();

  if (result.result && result.result.exceptionDetails) {
    throw new Error(
      result.result.exceptionDetails.exception &&
        result.result.exceptionDetails.exception.description
        ? result.result.exceptionDetails.exception.description
        : result.result.exceptionDetails.text
    );
  }

  return result.result && result.result.result
    ? result.result.result.value
    : null;
}

const expression = `(() => {
  const req = window.__wreq;
  if (!req) {
    if (window.webpackJsonp) {
      const id = "__netease_bridge_" + Date.now();
      window.webpackJsonp.push([[id], {
        [id]: function(module, exports, __webpack_require__) {
          window.__wreq = __webpack_require__;
        }
      }, [[id]]]);
    }
  }

  const req2 = window.__wreq;
  const modules = req2 && req2.c ? Object.keys(req2.c) : [];
  let appContext = null;
  for (const moduleId of modules) {
    try {
      const exports = req2(moduleId);
      if (exports && typeof exports.getAppContext === "function") {
        const context = exports.getAppContext();
        if (context && (context._currentValue || context._currentValue2)) {
          appContext = context;
          break;
        }
      }
    } catch (error) {
      // Some webpack modules have side effects or missing dependencies.
    }
  }
  const app = appContext && (
    (appContext._currentValue && appContext._currentValue.app) ||
    (appContext._currentValue2 && appContext._currentValue2.app)
  );
  const store = app && app._store;
  const state = store && store.getState && store.getState();
  const playing = state && state.playing;
  const playingList = state && state.playingList;
  if (!playing) return null;

  const track = playing.curTrack || (playing.curPlaying && playing.curPlaying.track);
  if (!track || !track.id) return null;
  const album = track.album || track.al || {};
  const artists = track.artists || track.ar || [];
  const duration = Number(track.duration || track.dt || playing.resourceDuration * 1000 || 0);
  const coverUrl = album.picUrl || album.cover || album.blurPicUrl || playing.resourceCoverUrl || "";
  const stateValue = Number(playing.playingState);
  const currentOrder = playing.curPlaying && Number.isFinite(Number(playing.curPlaying.displayOrder))
    ? Number(playing.curPlaying.displayOrder)
    : null;
  const currentId = String(track.id || playing.resourceTrackId || playing.onlineResourceId || "");
  const fullPlaylist = ((playingList && playingList.curPlayingList) || []).filter((item) => item && item.track);
  const currentIndex = fullPlaylist.findIndex((item) => {
    return String(item.track && item.track.id || item.trackId || item.resourceId || item.id || "") === currentId;
  });
  const playlistStart = currentIndex > 40 ? Math.max(0, currentIndex - 36) : 0;
  const playlist = fullPlaylist
    .slice(playlistStart, playlistStart + 80)
    .filter((item) => item && item.track)
    .map((item) => {
      const itemTrack = item.track || {};
      const itemArtists = itemTrack.artists || itemTrack.ar || [];
      return {
        id: String(itemTrack.id || item.trackId || item.resourceId || item.id || ""),
        title: itemTrack.name || "",
        artist: itemArtists.map((artist) => artist && artist.name).filter(Boolean).join(", "),
        displayOrder: Number(item.displayOrder),
        current: String(itemTrack.id || item.trackId || item.resourceId || item.id || "") === currentId,
        played: Boolean(item.isPlayedOnce)
      };
    });

  return {
    id: currentId,
    title: track.name || playing.resourceName || "",
    artist: artists.map((artist) => artist && artist.name).filter(Boolean).join(", ") || playing.resourceArtists || "",
    album: album.name || album.albumName || "",
    coverUrl,
    durationSeconds: duration > 1000 ? Math.round(duration) / 1000 : duration,
    playback: stateValue === 3 ? "paused" : "playing",
    sourceFile: "cdp:app._store.getState().playing.curTrack",
    sourceFileTime: new Date().toISOString().slice(0, 19),
    sourceState: stateValue,
    currentOrder,
    playlist,
  };
})()`;

async function main() {
  const targets = await getJson("/json/list");
  const page = targets.find((target) => target.type === "page" && /orpheus/.test(target.url));
  if (!page || !page.webSocketDebuggerUrl) {
    throw new Error("NetEase CDP page target not found");
  }

  const song = await evaluate(page.webSocketDebuggerUrl, expression);
  if (!song || !song.id) {
    throw new Error("NetEase playing state not found in CDP");
  }

  const json = JSON.stringify(song).replace(/[^\x00-\x7f]/g, (char) => {
    return "\\u" + char.charCodeAt(0).toString(16).padStart(4, "0");
  });
  process.stdout.write(json);
}

Promise.race([
  main(),
  new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error("CDP helper timed out")), 5000);
    timer.unref();
  }),
]).catch((error) => {
  process.stderr.write(error.message || String(error));
  process.exit(1);
});
