import '../services/playback_settings_controller.dart';
import '../services/plugin_library_repository.dart';
import '../services/provider_plugin_service.dart';
import '../services/storage_service.dart';
import '../services/tmdb_service.dart';

/// The app's shared services, built in one place and handed to the screens
/// and ViewModels that use them, rather than constructed inside widgets.
///
/// Home owns one for its lifetime (as it owned these services before), so
/// nothing about when they start or stop has changed. A test can pass its
/// own [tmdb] and [storage].
class AppServices {
  AppServices({TmdbService? tmdb, StorageService? storage})
    : tmdb = tmdb ?? TmdbService(),
      storage = storage ?? StorageService();

  final TmdbService tmdb;
  final StorageService storage;

  /// Provider repositories, their plugins and stream lookups.
  final providerPlugins = ProviderPluginService();

  /// The plugin catalog, loaded the first time the Plugin Library opens.
  final pluginLibrary = PluginLibraryRepository();

  final playbackSettings = PlaybackSettingsController();

  void dispose() {
    playbackSettings.dispose();
    providerPlugins.dispose();
    pluginLibrary.dispose();
  }
}
