import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_go_torrent_streamer_method_channel.dart';

/// The interface that implementations of flutter_torrent_streamer must implement.
/// flutter_torrent_streamer 插件必须实现的接口定义。
///
/// Platform implementations should extend this class rather than implementing it as an interface.
/// 平台实现类应继承此类，而不是将其作为接口实现。
abstract class FlutterTorrentStreamerPlatform extends PlatformInterface {
  /// Constructs a FlutterTorrentStreamerPlatform.
  /// 构造函数。
  FlutterTorrentStreamerPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterTorrentStreamerPlatform _instance =
      MethodChannelFlutterTorrentStreamer();

  /// The default instance of [FlutterTorrentStreamerPlatform] to use.
  /// 获取默认的平台实现实例。
  ///
  /// Defaults to [MethodChannelFlutterTorrentStreamer].
  /// 默认为 [MethodChannelFlutterTorrentStreamer]。
  static FlutterTorrentStreamerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterTorrentStreamerPlatform] when
  /// they register themselves.
  /// 平台特定实现应在注册时将其实例设置到此处。
  static set instance(FlutterTorrentStreamerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the platform version.
  /// 获取平台版本号。
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
