import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'flutter_go_torrent_streamer_platform_interface.dart';


DynamicLibrary _loadLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libtorrent_streamer.so');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}

// FFI 函数签名
typedef InitFunc = Void Function(Pointer<Utf8> configDir);
typedef Init = void Function(Pointer<Utf8> configDir);

typedef StartStreamFunc =
    Pointer<Utf8> Function(Pointer<Utf8> magnet, Pointer<Utf8> savePath);
typedef StartStream =
    Pointer<Utf8> Function(Pointer<Utf8> magnet, Pointer<Utf8> savePath);

typedef StopClientFunc = Void Function(Pointer<Utf8> sessionId);
typedef StopClient = void Function(Pointer<Utf8> sessionId);

typedef PauseSessionFunc = Void Function(Pointer<Utf8> sessionId);
typedef PauseSession = void Function(Pointer<Utf8> sessionId);

typedef ResumeSessionFunc = Void Function(Pointer<Utf8> sessionId);
typedef ResumeSession = void Function(Pointer<Utf8> sessionId);

typedef GetStreamStatusFunc = Pointer<Utf8> Function(Pointer<Utf8> sessionId);
typedef GetStreamStatus = Pointer<Utf8> Function(Pointer<Utf8> sessionId);

typedef GetFilesFunc = Pointer<Utf8> Function(Pointer<Utf8> sessionId);
typedef GetFiles = Pointer<Utf8> Function(Pointer<Utf8> sessionId);

typedef SelectFileFunc =
    Pointer<Utf8> Function(Pointer<Utf8> sessionId, Int32 fileIndex);
typedef SelectFile =
    Pointer<Utf8> Function(Pointer<Utf8> sessionId, int fileIndex);

typedef DownloadFileFunc =
    Pointer<Utf8> Function(Pointer<Utf8> sessionId, Int32 fileIndex);
typedef DownloadFile =
    Pointer<Utf8> Function(Pointer<Utf8> sessionId, int fileIndex);

typedef GetAllSessionsFunc = Pointer<Utf8> Function();
typedef GetAllSessions = Pointer<Utf8> Function();

typedef FreeStringFunc = Void Function(Pointer<Utf8> str);
typedef FreeString = void Function(Pointer<Utf8> str);

typedef ConfigureFunc = Pointer<Utf8> Function(Pointer<Utf8> configJson);
typedef Configure = Pointer<Utf8> Function(Pointer<Utf8> configJson);

/// 全局配置类
class TorrentStreamerConfig {
  /// 下载限速 (字节/秒)，0 无限制
  final int downloadSpeedLimit;

  /// 上传限速 (字节/秒)，0 无限制
  final int uploadSpeedLimit;

  /// 每个种子最大连接数，0 默认
  final int connectionsLimit;

  /// 监听端口，0 随机
  final int port;

  /// User-Agent
  final String userAgent;

  /// 最大并发下载数，0 默认 (3)
  final int maxActiveDownloads;

  TorrentStreamerConfig({
    this.downloadSpeedLimit = 0,
    this.uploadSpeedLimit = 0,
    this.connectionsLimit = 0,
    this.port = 0,
    this.userAgent = "",
    this.maxActiveDownloads = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'downloadSpeedLimit': downloadSpeedLimit,
      'uploadSpeedLimit': uploadSpeedLimit,
      'connectionsLimit': connectionsLimit,
      'port': port,
      'userAgent': userAgent,
      'maxActiveDownloads': maxActiveDownloads,
    };
  }
}

/// 种子文件信息
class TorrentFile {
  /// 文件索引
  final int index;

  /// 文件名/路径
  final String name;

  /// 文件大小 (字节)
  final int size;

  TorrentFile({required this.index, required this.name, required this.size});

  factory TorrentFile.fromJson(Map<String, dynamic> json) {
    return TorrentFile(
      index: json['index'],
      name: json['name'],
      size: json['size'],
    );
  }
}

/// 会话状态快照
class SessionInfo {
  /// 会话 ID
  final String id;

  /// 任务名称
  final String name;

  /// 当前状态
  final String state;

  /// 进度 (0-100)
  final double progress;

  /// 模式："stream" (边下边播) 或 "download" (下载)
  final String mode;

  /// 本地流媒体地址
  final String url;

  /// 下载速度 (字节/秒)
  final int downloadSpeed;

  /// 连接人数 (Peers)
  final int peers;

  /// 做种人数 (Seeds)
  final int seeds;

  /// 剩余时间 (秒)，-1 未知
  final int eta;

  SessionInfo({
    required this.id,
    required this.name,
    required this.state,
    required this.progress,
    required this.mode,
    required this.url,
    this.downloadSpeed = 0,
    this.peers = 0,
    this.seeds = 0,
    this.eta = -1,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      id: json['id'],
      name: json['name'],
      state: json['state'],
      progress: (json['progress'] as num).toDouble(),
      mode: json['mode'],
      url: json['url'] ?? '',
      downloadSpeed: json['downloadSpeed'] ?? 0,
      peers: json['peers'] ?? 0,
      seeds: json['seeds'] ?? 0,
      eta: json['eta'] ?? -1,
    );
  }
}

/// 会话控制类
class TorrentStreamSession {
  final String sessionId;
  final String streamUrl;
  final FlutterTorrentStreamer _plugin;
  bool _stopped = false;

  TorrentStreamSession(this.sessionId, this.streamUrl, this._plugin);

  /// 停止任务并移除 (同时删除记录)
  Future<void> stop() async {
    if (_stopped) return;
    await _plugin._stopSession(sessionId);
    _stopped = true;
  }

  /// 暂停任务
  Future<void> pause() async {
    if (_stopped) return;
    await _plugin._pauseSession(sessionId);
  }

  /// 恢复任务
  Future<void> resume() async {
    if (_stopped) return;
    await _plugin._resumeSession(sessionId);
  }

  /// 获取任务状态
  Future<Map<String, dynamic>> getStatus() async {
    if (_stopped) {
      return {'state': 'Stopped'};
    }
    final jsonStr = await _plugin._getSessionStatus(sessionId);
    return json.decode(jsonStr);
  }

  /// 获取文件列表
  Future<List<TorrentFile>> getFiles() async {
    if (_stopped) return [];
    final jsonStr = await _plugin._getFiles(sessionId);
    final List<dynamic> list = json.decode(jsonStr);
    return list.map((e) => TorrentFile.fromJson(e)).toList();
  }

  /// 选择文件播放 (流媒体模式)
  Future<void> selectFile(int index) async {
    if (_stopped) return;
    await _plugin._selectFile(sessionId, index);
  }

  /// 后台下载文件 (下载模式)
  Future<void> downloadFile(int index) async {
    if (_stopped) return;
    await _plugin._downloadFile(sessionId, index);
  }
}

/// 插件主类 (单例)
class FlutterTorrentStreamer {
  static DynamicLibrary? _lib;
  static final FlutterTorrentStreamer _instance =
      FlutterTorrentStreamer._internal();
  static bool _hasInitializedBackend = false;

  factory FlutterTorrentStreamer() {
    return _instance;
  }

  FlutterTorrentStreamer._internal();

  static const MethodChannel _channel = MethodChannel(
    'flutter_torrent_streamer',
  );

  Future<String?> getPlatformVersion() {
    return FlutterTorrentStreamerPlatform.instance.getPlatformVersion();
  }

  /// 配置全局参数 (支持动态更新)
  Future<void> configure(TorrentStreamerConfig config) async {
    await _autoInit();

    // Use Isolate.run to offload FFI call and JSON encoding
    final configJson = config.toJson();

    await Isolate.run(() {
      final lib = _loadLib();
      final configureFunc =
          lib
              .lookup<NativeFunction<ConfigureFunc>>('Configure')
              .asFunction<Configure>();

      final freeString =
          lib
              .lookup<NativeFunction<FreeStringFunc>>('FreeString')
              .asFunction<FreeString>();

      final jsonStr = json.encode(configJson);
      final jsonPtr = jsonStr.toNativeUtf8();

      try {
        final resultPtr = configureFunc(jsonPtr);
        final resultStr = resultPtr.toDartString();
        freeString(resultPtr);

        if (resultStr != "Success") {
          throw Exception("配置失败: $resultStr");
        }
      } finally {
        calloc.free(jsonPtr);
      }
    });
  }

  /// 开启后台保活 (Android 前台服务)
  Future<void> enableBackgroundMode({
    String title = "Torrent Downloader",
    String content = "Downloading in background...",
  }) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('startBackgroundService', {
          'title': title,
          'content': content,
        });
      } on PlatformException catch (e) {
        debugPrint("Failed to enable background mode: ${e.message}");
      }
    }
  }

  /// 关闭后台保活
  Future<void> disableBackgroundMode() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopBackgroundService');
      } on PlatformException catch (e) {
        debugPrint("Failed to disable background mode: ${e.message}");
      }
    }
  }

  /// 确保动态库已加载
  void _ensureInitialized() {
    if (_lib != null) return;

    try {
      if (Platform.isAndroid) {
        _lib = DynamicLibrary.open('libtorrent_streamer.so');
      } else {
        throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
      }
    } catch (e) {
      debugPrint('Failed to load dynamic library: $e');
      rethrow;
    }
  }

  /// 自动初始化后端引擎
  Future<void> _autoInit() async {
    _ensureInitialized();
    if (_hasInitializedBackend) return;

    final dir = await getApplicationDocumentsDirectory();
    final initFunc =
        _lib!.lookup<NativeFunction<InitFunc>>('Init').asFunction<Init>();

    final pathPtr = dir.path.toNativeUtf8();
    try {
      initFunc(pathPtr);
      _hasInitializedBackend = true;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// 启动下载/流媒体 (自动持久化)
  Future<TorrentStreamSession> startStream(
    String magnetLink,
    String savePath,
  ) async {
    await _autoInit();

    // Use Isolate.run to offload FFI call
    final Map<String, dynamic> result = await Isolate.run(() {
      final lib = _loadLib();
      final startStream =
          lib
              .lookup<NativeFunction<StartStreamFunc>>('StartStream')
              .asFunction<StartStream>();

      final freeString =
          lib
              .lookup<NativeFunction<FreeStringFunc>>('FreeString')
              .asFunction<FreeString>();

      final magnetPtr = magnetLink.toNativeUtf8();
      final savePathPtr = savePath.toNativeUtf8();
      try {
        final resultPtr = startStream(magnetPtr, savePathPtr);
        final resultStr = resultPtr.toDartString();
        freeString(resultPtr);

        if (!resultStr.trim().startsWith('{')) {
          throw Exception(resultStr);
        }

        final Map<String, dynamic> decoded = json.decode(resultStr);
        if (decoded.containsKey('error')) {
          throw Exception(decoded['error']);
        }
        return decoded;
      } finally {
        calloc.free(magnetPtr);
        calloc.free(savePathPtr);
      }
    });

    return TorrentStreamSession(result['sessionId'], result['url'], this);
  }

  /// 获取所有会话列表 (用于恢复状态)
  Future<List<SessionInfo>> getAllSessions() async {
    await _autoInit();
    final getAll =
        _lib!
            .lookup<NativeFunction<GetAllSessionsFunc>>('GetAllSessions')
            .asFunction<GetAllSessions>();

    final freeString =
        _lib!
            .lookup<NativeFunction<FreeStringFunc>>('FreeString')
            .asFunction<FreeString>();

    final resultPtr = getAll();
    final resultStr = resultPtr.toDartString();
    freeString(resultPtr);

    // debugPrint("Raw sessions JSON: $resultStr"); // Debug log

    final dynamic decoded = json.decode(resultStr);
    if (decoded == null) {
      // debugPrint("警告: 获取到的会话列表为空 (null)");
      return [];
    }

    final List<dynamic> list = decoded;
    // debugPrint("成功获取会话列表: 共 ${list.length} 个任务");
    return list.map((e) => SessionInfo.fromJson(e)).toList();
  }

  /// 根据 ID 创建会话对象
  TorrentStreamSession getSession(String sessionId) {
    return TorrentStreamSession(sessionId, "", this);
  }

  /// 停止任务 (通过 ID)
  Future<void> stopStream(String sessionId) async {
    await _autoInit();
    return _stopSession(sessionId);
  }

  /// 内部实现：调用 C 接口 StopClient
  Future<void> _stopSession(String sessionId) async {
    await _autoInit();
    final stopClient =
        _lib!
            .lookup<NativeFunction<StopClientFunc>>('StopClient')
            .asFunction<StopClient>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      stopClient(sessionPtr);
    } finally {
      calloc.free(sessionPtr);
    }
  }

  /// 内部实现：调用 C 接口 PauseSession
  Future<void> _pauseSession(String sessionId) async {
    await _autoInit();
    final pauseSession =
        _lib!
            .lookup<NativeFunction<PauseSessionFunc>>('PauseSession')
            .asFunction<PauseSession>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      pauseSession(sessionPtr);
    } finally {
      calloc.free(sessionPtr);
    }
  }

  /// 内部实现：调用 C 接口 ResumeSession
  Future<void> _resumeSession(String sessionId) async {
    await _autoInit();
    final resumeSession =
        _lib!
            .lookup<NativeFunction<ResumeSessionFunc>>('ResumeSession')
            .asFunction<ResumeSession>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      resumeSession(sessionPtr);
    } finally {
      calloc.free(sessionPtr);
    }
  }

  /// 内部实现：调用 C 接口 GetStreamStatus
  Future<String> _getSessionStatus(String sessionId) async {
    await _autoInit();
    final getStatus =
        _lib!
            .lookup<NativeFunction<GetStreamStatusFunc>>('GetStreamStatus')
            .asFunction<GetStreamStatus>();

    final freeString =
        _lib!
            .lookup<NativeFunction<FreeStringFunc>>('FreeString')
            .asFunction<FreeString>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final resultPtr = getStatus(sessionPtr);
      final result = resultPtr.toDartString();
      freeString(resultPtr);
      return result;
    } finally {
      calloc.free(sessionPtr);
    }
  }

  /// 内部实现：调用 C 接口 GetFiles
  Future<String> _getFiles(String sessionId) async {
    await _autoInit();
    final getFiles =
        _lib!
            .lookup<NativeFunction<GetFilesFunc>>('GetFiles')
            .asFunction<GetFiles>();

    final freeString =
        _lib!
            .lookup<NativeFunction<FreeStringFunc>>('FreeString')
            .asFunction<FreeString>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final resultPtr = getFiles(sessionPtr);
      final result = resultPtr.toDartString();
      freeString(resultPtr);
      return result;
    } finally {
      calloc.free(sessionPtr);
    }
  }

  /// 内部实现：调用 C 接口 SelectFile
  Future<void> _selectFile(String sessionId, int index) async {
    await _autoInit();
    final selectFile =
        _lib!
            .lookup<NativeFunction<SelectFileFunc>>('SelectFile')
            .asFunction<SelectFile>();

    final freeString =
        _lib!
            .lookup<NativeFunction<FreeStringFunc>>('FreeString')
            .asFunction<FreeString>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final resultPtr = selectFile(sessionPtr, index);
      freeString(resultPtr);
    } finally {
      calloc.free(sessionPtr);
    }
  }

  /// 内部实现：调用 C 接口 DownloadFile
  Future<void> _downloadFile(String sessionId, int index) async {
    await _autoInit();
    final downloadFile =
        _lib!
            .lookup<NativeFunction<DownloadFileFunc>>('DownloadFile')
            .asFunction<DownloadFile>();

    final freeString =
        _lib!
            .lookup<NativeFunction<FreeStringFunc>>('FreeString')
            .asFunction<FreeString>();

    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final resultPtr = downloadFile(sessionPtr, index);
      freeString(resultPtr);
    } finally {
      calloc.free(sessionPtr);
    }
  }
}
