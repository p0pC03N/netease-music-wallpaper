# NetEase Music Reactive Wallpaper

Wallpaper Engine Web 壁纸，用网易云音乐当前播放状态驱动封面、歌名、播放列表、进度条和音频可视化。

## 功能

- 显示当前歌曲标题、歌手、专辑和封面。
- 使用当前封面作为放大模糊背景，并保留纯色兜底。
- 支持横向频谱、圆形频谱和封面低频脉冲。
- 支持播放/暂停/停止状态和播放进度条。
- 通过本地桥接读取网易云音乐 CDP 状态，比 Windows 媒体会话更稳定。
- 桥接支持后台计划任务，不需要长期打开终端窗口。
- 如果 Wallpaper Engine 音频回调不可用，会在播放中自动切到模拟频谱，避免画面完全不动。

## 安装到 Wallpaper Engine

1. 把项目复制到 Wallpaper Engine 本地项目目录，例如：

   ```text
   D:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine\projects\myprojects\netease-music-wallpaper
   ```

2. 在 Wallpaper Engine 中从该目录的 `project.json` 或 `index.html` 打开壁纸。

3. 确认 `project.json` 中保留：

   ```json
   "supportsaudioprocessing": true
   ```

   `general.supportsaudioprocessing` 也应该为 `true`。

4. 在 Wallpaper Engine 设置里启用媒体集成和音频响应。

## 后台桥接

推荐安装后台任务，不要手动开一个终端长期挂着：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bridge\install-background-tasks.ps1
```

这个脚本会安装并启动两个计划任务：

- `Netease Music Wallpaper Bridge Watchdog`
- `Netease Music CDP Launcher`

watchdog 会保持以下组件在后台运行：

- `netease-runtime-server.js`：本地 HTTP 服务，默认 `http://127.0.0.1:39487`
- `netease-bridge.ps1`：读取网易云音乐当前播放状态
- Wallpaper Engine 配置修复：避免锁屏/系统壁纸覆盖重新开启导致闪屏
- `project.json` 音频配置修复：避免编辑器保存后丢失音频处理开关

如果只是临时启动，可以双击：

```text
bridge\run-bridge.cmd
```

它会隐藏启动 watchdog，不需要保留终端窗口。

## 常用检查

检查桥接是否正常：

```powershell
Invoke-RestMethod http://127.0.0.1:39487/now-playing.json
```

重启桥接后台任务：

```powershell
Stop-ScheduledTask -TaskName "Netease Music Wallpaper Bridge Watchdog"
Start-ScheduledTask -TaskName "Netease Music Wallpaper Bridge Watchdog"
```

查看 watchdog 日志：

```powershell
Get-Content "$env:LOCALAPPDATA\NeteaseMusicWallpaper\runtime\bridge-watchdog.log" -Tail 50
```

## 运行时文件

运行时数据默认写到：

```text
%LOCALAPPDATA%\NeteaseMusicWallpaper\runtime
```

项目目录下的 `runtime/` 只作为旧版兼容和本地预览兜底，不应该提交日志、pid 或实时封面缓存。
