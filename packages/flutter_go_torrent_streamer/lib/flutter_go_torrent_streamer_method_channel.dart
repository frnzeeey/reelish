import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_go_torrent_streamer_platform_interface.dart';

/// An implementation of [FlutterTorrentStreamerPlatform] that uses method channels.
/// 基于 MethodChannel 的 [FlutterTorrentStreamerPlatform] 实现。
class MethodChannelFlutterTorrentStreamer
    extends FlutterTorrentStreamerPlatform {
  /// The method channel used to interact with the native platform.
  /// 用于与原生平台通信的 MethodChannel。
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_torrent_streamer');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
