# Flutter Go Torrent Streamer

[English](#english) | [中文 (Chinese)](#chinese)

<a name="english"></a>
## Flutter Go Torrent Streamer (English)

A Flutter plugin for real-time BitTorrent streaming (sequential download) and background downloading on Android, powered by a Go backend via FFI.

**New in v0.0.8:** Supports multiple concurrent download tasks，The plugin now uses a single global torrent client instance to manage multiple sessions, ensuring efficient resource usage and preventing port binding conflicts.



---

### Installation

Add `flutter_go_torrent_streamer` to your `pubspec.yaml` dependencies.

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_go_torrent_streamer: ^0.0.8
```

Then run:

```bash
flutter pub get
```

---

### Android Configuration

To ensure the plugin works correctly, especially for background downloading, configure your `android/app/src/main/AndroidManifest.xml`.

#### 1. Permissions

Add the following permissions inside the `<manifest>` tag:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.your_app">

    <!-- Network Access -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <!-- Prevent CPU Sleep (for background download) -->
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <!-- Foreground Service (Android 9+) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

    <application ...>
       ...
    </application>
</manifest>
```

---

### Usage

#### 1. Initialization

The plugin initializes automatically when first used. However, you can import it in your main entry point.

```dart
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';

void main() {
  runApp(MyApp());
}
```

#### 2. Global Configuration (Optional)

You can set global speed limits and other parameters.

```dart
await FlutterTorrentStreamer().configure(TorrentStreamerConfig(
  downloadSpeedLimit: 5 * 1024 * 1024, // 5 MB/s
  uploadSpeedLimit: 1 * 1024 * 1024,   // 1 MB/s
  connectionsLimit: 500,               // Max 500 connections
  port: 6881,                          // Listen port
));
```

#### 3. Start a Session (Magnet Link)

Use `startStream` to create a session from a magnet link.

> **Note**: On Android, ensure `savePath` is a valid writable path (e.g., using `path_provider`).

```dart
import 'package:path_provider/path_provider.dart';

// ...

String magnetLink = "magnet:?xt=urn:btih:EXAMPLE...";
final dir = await getApplicationDocumentsDirectory();
String savePath = "${dir.path}/downloads"; 

// Create a session
TorrentStreamSession session = await FlutterTorrentStreamer().startStream(magnetLink, savePath);

print("Session ID: ${session.sessionId}");
print("Stream URL: ${session.streamUrl}"); // Can be passed directly to a video player
```

#### 4. Control Session (Pause / Resume / Stop)

You can pause, resume, or stop a session.

```dart
// Pause the session (stops network activity, keeps state)
await session.pause();

// Resume the session
await session.resume();

// Stop the session (removes it completely)
await session.stop();
// Or use the plugin instance:
// await FlutterTorrentStreamer().stopStream(sessionId);
```

#### 5. Get Files & Select File

Once metadata is fetched (state becomes `Ready`), you can list files and select one to download/stream.

```dart
// Get file list
List<TorrentFile> files = await session.getFiles();

for (var file in files) {
  print("Index: ${file.index}, Name: ${file.name}, Size: ${file.size}");
}

// Scenario A: User wants to stream file at index 0 (Sequential Mode)
await session.selectFile(0); 

// Scenario B: User wants to download file at index 1 (Background Mode)
await session.downloadFile(1);
```

#### 6. Background Mode (Android)

Enable background mode to prevent the OS from killing the download process.

```dart
// Enable background service with a notification
await FlutterTorrentStreamer().enableBackgroundMode(
  title: "Downloading...",
  content: "Your torrent is downloading in the background.",
);

// ... After task is done ...
await FlutterTorrentStreamer().disableBackgroundMode();
```

#### 7. Monitor Status

Poll for status updates to refresh your UI.

```dart
List<SessionInfo> sessions = await FlutterTorrentStreamer().getAllSessions();

for (var info in sessions) {
  print("Task: ${info.name}");
  print("Progress: ${info.progress.toStringAsFixed(1)}%");
  print("Speed: ${info.downloadSpeed / 1024} KB/s");
  print("State: ${info.state}"); // Downloading, Seeding, Ready, etc.
}
```

### API

| Method | Description |
| --- | --- |
| `FlutterTorrentStreamer().configure(config)` | Set global limits, port, connections, etc. |
| `FlutterTorrentStreamer().startStream(magnet, savePath)` | Create a new session from a magnet link. Returns `Session`. |
| `FlutterTorrentStreamer().stopStream(sessionId)` | Stop and remove a specific session. |
| `FlutterTorrentStreamer().getAllSessions()` | Get real-time status of all sessions. |
| `FlutterTorrentStreamer().enableBackgroundMode()` | **(Android)** Start foreground service to prevent killing. |
| `FlutterTorrentStreamer().disableBackgroundMode()` | **(Android)** Stop foreground service. |
| `session.pause()` | Pause the session (stops network, keeps state). |
| `session.resume()` | Resume the session. |
| `session.stop()` | Stop and remove the session. |
| `session.getFiles()` | Get the list of files in the torrent. |
| `session.selectFile(index)` | Select a file for streaming (sequential download). |
| `session.downloadFile(index)` | Select a file for background download (rarest-first). |

<br>
<br>

---

<a name="chinese"></a>
## Flutter Go Torrent Streamer (中文文档)

这是一个 Flutter 插件，支持 BT 磁力链接的流媒体播放（边下边播）以及后台下载功能。底层使用 Go 语言编写，通过 FFI 与 Flutter 通信。

**v0.0.78新特性：** 支持多任务并发下载，现在使用全局唯一的 Torrent 客户端实例来管理多个会话，确保资源高效利用并解决了多任务时的端口冲突问题。



### 引入与安装

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_go_torrent_streamer: ^0.0.8
```

然后运行：

```bash
flutter pub get
```

---

### Android 配置

为了确保插件正常工作，特别是后台下载功能，需要对 Android 项目进行配置。

#### 1. 权限声明 (AndroidManifest.xml)

打开 `android/app/src/main/AndroidManifest.xml`，添加以下权限：

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.your_app">

    <!-- 网络访问权限 -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <!-- 防止 CPU 休眠 (用于后台下载) -->
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <!-- 前台服务权限 (Android 9+) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>

    <application ...>
       ...
    </application>
</manifest>
```

---

### 使用指南

#### 1. 初始化插件

在应用启动时（例如 `main()` 函数中），首先初始化插件。这一步会加载 Go 核心库并准备本地数据库。

```dart
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';

void main() {
  runApp(MyApp());
}
```

#### 2. 全局配置 (可选)

可以配置全局的下载限速、最大连接数等参数。

```dart
await FlutterTorrentStreamer().configure(TorrentStreamerConfig(
  downloadSpeedLimit: 5 * 1024 * 1024, // 5 MB/s
  uploadSpeedLimit: 1 * 1024 * 1024,   // 1 MB/s
  connectionsLimit: 500,               // 最大 500 个连接
  port: 6881,                          // 指定监听端口
));
```

#### 3. 开始任务 (磁力链接)

使用 `startStream` 方法通过磁力链接创建一个新的会话。

> **注意**: 在 Android 上，请确保 `savePath` 是一个合法的可写路径（使用 `path_provider` 获取）。

```dart
import 'package:path_provider/path_provider.dart';

// ...

String magnetLink = "magnet:?xt=urn:btih:EXAMPLE...";
final dir = await getApplicationDocumentsDirectory();
String savePath = "${dir.path}/downloads"; 

// 创建任务
TorrentStreamSession session = await FlutterTorrentStreamer().startStream(magnetLink, savePath);

print("任务ID: ${session.sessionId}");
print("流媒体地址: ${session.streamUrl}"); // 可直接丢给播放器
```

#### 4. 控制任务 (暂停 / 恢复 / 停止)

你可以暂停、恢复或完全停止（删除）一个任务。

```dart
// 暂停任务 (停止网络活动，保留状态)
await session.pause();

// 恢复任务
await session.resume();

// 停止任务 (完全移除)
await session.stop();
// 或者使用插件实例:
// await FlutterTorrentStreamer().stopStream(sessionId);
```

#### 5. 获取文件列表与选择文件

创建任务后，通常需要等待元数据解析完成（状态变为 `Ready`），然后获取文件列表。

```dart
// 获取文件列表
List<TorrentFile> files = await session.getFiles();

for (var file in files) {
  print("文件索引: ${file.index}, 文件名: ${file.name}, 大小: ${file.size}");
}

// 场景 A: 用户想播放第 0 个文件 (边下边播模式)
// 这会优先下载文件的开头和当前播放位置
await session.selectFile(0); 

// 场景 B: 用户想纯下载第 1 个文件 (后台下载模式)
// 这会使用 Rarest-First 策略全速下载
await session.downloadFile(1);
```

#### 6. 开启/关闭后台保活模式

为了防止在后台下载时被系统杀掉，建议在开始下载时开启后台保活。

```dart
// 开启后台保活 (显示通知栏)
await FlutterTorrentStreamer().enableBackgroundMode(
  title: "下载中...",
  content: "正在后台下载文件",
);

// ... 任务完成后关闭 ...
await FlutterTorrentStreamer().disableBackgroundMode();
```

#### 7. 获取所有任务状态

你可以轮询获取所有任务的最新状态，用于更新 UI 进度条。

```dart
List<SessionInfo> sessions = await FlutterTorrentStreamer().getAllSessions();

for (var info in sessions) {
  print("任务: ${info.name}");
  print("进度: ${(info.progress * 100).toStringAsFixed(1)}%");
  print("速度: ${info.downloadSpeed / 1024} KB/s");
  print("状态: ${info.state}"); // Downloading, Seeding, Ready 等
}
```

---

### API

| 方法 | 描述 |
| --- | --- |
| `FlutterTorrentStreamer().configure(config)` | 设置全局限速、端口、连接数等。 |
| `FlutterTorrentStreamer().startStream(magnet, savePath)` | 通过磁力链接创建新任务，返回 `Session` 对象。 |
| `FlutterTorrentStreamer().stopStream(sessionId)` | 停止并删除指定任务。 |
| `FlutterTorrentStreamer().getAllSessions()` | 获取当前所有任务的实时状态列表。 |
| `FlutterTorrentStreamer().enableBackgroundMode()` | **(Android)** 启动前台服务，防止后台被杀。 |
| `FlutterTorrentStreamer().disableBackgroundMode()` | **(Android)** 停止前台服务。 |
| `session.pause()` | 暂停任务（停止网络活动，保留状态）。 |
| `session.resume()` | 恢复任务。 |
| `session.stop()` | 停止并删除任务。 |
| `session.getFiles()` | 获取种子包含的文件列表。 |
| `session.selectFile(index)` | 选择文件进行流媒体播放 (顺序下载优先)。 |
| `session.downloadFile(index)` | 选择文件进行纯下载 (乱序下载优先)。 |

---

### 注意事项

1.  **Android 编译**: 本插件依赖 Go 编译的 `libtorrent_streamer.so`。如果你修改了 `go/` 目录下的代码，请务必运行 `go/build_android.ps1` 重新编译动态库。
2.  **网络权限**: 确保设备连接了网络，并且未被防火墙拦截 P2P 流量。
3.  **存储**: 默认情况下，下载的文件存储在应用的私有目录下。如果需要导出文件，需要自行处理文件复制逻辑。
