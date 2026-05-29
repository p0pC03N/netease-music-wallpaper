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

function send(res, status, body, type = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "Content-Type": type,
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma": "no-cache",
  });
  res.end(body);
}

function safeFileFromUrl(url) {
  const pathname = new URL(url, `http://127.0.0.1:${port}`).pathname;
  const name = path.basename(decodeURIComponent(pathname));
  if (!["now-playing.json", "now-playing.js", "bridge-heartbeat.json", "cover.jpg"].includes(name)) {
    return null;
  }
  return path.join(runtimeDir, name);
}

fs.mkdirSync(runtimeDir, { recursive: true });

http.createServer((req, res) => {
  if (req.method === "OPTIONS") {
    send(res, 204, "");
    return;
  }

  const file = safeFileFromUrl(req.url || "/");
  if (!file) {
    send(res, 404, "Not found");
    return;
  }

  fs.readFile(file, (error, data) => {
    if (error) {
      send(res, 404, "Not found");
      return;
    }
    send(res, 200, data, contentTypes[path.extname(file).toLowerCase()] || "application/octet-stream");
  });
}).listen(port, "127.0.0.1", () => {
  console.log(`NetEase wallpaper runtime server listening on http://127.0.0.1:${port}`);
  console.log(`Runtime dir: ${runtimeDir}`);
});
