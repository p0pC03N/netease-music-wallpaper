const http = require("http");
const fs = require("fs");
const path = require("path");

const port = Number(process.env.NETEASE_WALLPAPER_PORT || process.argv[2] || 39487);
const runtimeDir = process.env.NETEASE_WALLPAPER_RUNTIME ||
  path.join(process.env.LOCALAPPDATA || process.env.TEMP || ".", "NeteaseMusicWallpaper", "runtime");

const contentTypes = {
  ".json": "application/json; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
};

function getCorsHeaders(req) {
  const origin = req.headers.origin;
  if (!origin) {
    return {};
  }

  const allowedOrigins = new Set([
    "null",
    `http://127.0.0.1:${port}`,
    `http://localhost:${port}`,
  ]);

  if (!allowedOrigins.has(origin)) {
    return { "Vary": "Origin" };
  }

  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Vary": "Origin",
  };
}

function send(req, res, status, body, type = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "Content-Type": type,
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma": "no-cache",
    ...getCorsHeaders(req),
  });
  res.end(req.method === "HEAD" ? "" : body);
}

function safeFileFromUrl(url) {
  let pathname = "";
  try {
    pathname = new URL(url, `http://127.0.0.1:${port}`).pathname;
  } catch {
    return null;
  }

  let name = "";
  try {
    name = path.basename(decodeURIComponent(pathname));
  } catch {
    return null;
  }

  if (!["now-playing.json", "now-playing.js", "bridge-heartbeat.json", "cover.jpg"].includes(name)) {
    return null;
  }
  return path.join(runtimeDir, name);
}

fs.mkdirSync(runtimeDir, { recursive: true });

http.createServer((req, res) => {
  if (req.method === "OPTIONS") {
    send(req, res, 204, "");
    return;
  }

  if (req.method !== "GET" && req.method !== "HEAD") {
    send(req, res, 405, "Method not allowed");
    return;
  }

  const file = safeFileFromUrl(req.url || "/");
  if (!file) {
    send(req, res, 404, "Not found");
    return;
  }

  fs.readFile(file, (error, data) => {
    if (error) {
      send(req, res, 404, "Not found");
      return;
    }
    send(req, res, 200, data, contentTypes[path.extname(file).toLowerCase()] || "application/octet-stream");
  });
}).listen(port, "127.0.0.1", () => {
  console.log(`NetEase wallpaper runtime server listening on http://127.0.0.1:${port}`);
  console.log(`Runtime dir: ${runtimeDir}`);
});
