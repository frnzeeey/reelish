// Whether an installed provider can work on this device, judged only from
// what its manifest declares and what Reelish's runtime does. Pure Dart, so
// the service, the three interfaces and the tests share one rule.
import '../models/plugin_catalog.dart';
import '../models/provider_plugin.dart';
import '../platform/device_capabilities.dart';

/// The interface Reelish runs as. Matches the three shipped targets.
enum ReelishDevice {
  phone('phones and tablets'),
  tv('TV devices'),
  windows('Windows');

  const ReelishDevice(this.label);

  /// Plural noun phrase for sentences ("not for TV devices").
  final String label;

  static ReelishDevice get current => DeviceCapabilities.isTv
      ? ReelishDevice.tv
      : DeviceCapabilities.isDesktop
      ? ReelishDevice.windows
      : ReelishDevice.phone;

  /// Manifest platform names that mean this device. Names Reelish cannot
  /// map with confidence (`ios`, `web`, `macos`) never match.
  Set<String> get manifestNames => switch (this) {
    ReelishDevice.phone => const {'android', 'mobile', 'phone'},
    ReelishDevice.tv => const {
      'tv',
      'androidtv',
      'android-tv',
      'android_tv',
      'googletv',
      'google-tv',
    },
    ReelishDevice.windows => const {'windows', 'desktop', 'pc'},
  };
}

enum PluginCompatibilityLevel {
  /// Nothing the manifest declares rules this device out. Not a promise
  /// that the provider finds streams.
  compatible('No known issues'),

  /// Runs here, with a declared limitation.
  partial('Works with limits'),

  /// Declared not to work here, or never searched by Reelish.
  unsupported('Not for this device'),

  /// The catalog does not carry the data to judge (checked after install).
  unknown('Checked after install');

  const PluginCompatibilityLevel(this.label);
  final String label;
}

class PluginCompatibility {
  const PluginCompatibility({
    required this.level,
    this.reasons = const [],
    this.blockedOnDevice = false,
    this.searchable = true,
  });

  final PluginCompatibilityLevel level;

  /// Plain-language explanations, most important first.
  final List<String> reasons;

  /// The author lists this device among its disabled platforms. Such a
  /// provider starts switched off here; the viewer may still switch it on.
  final bool blockedOnDevice;

  /// Declares a content type Reelish looks up (movies or series).
  final bool searchable;

  static PluginCompatibility of(ProviderPlugin plugin, ReelishDevice device) {
    final unsupported = <String>[];
    final limits = <String>[];
    final types = {
      for (final type in plugin.supportedTypes) normalizeType(type),
    };
    final searchable = types.contains('movie') || types.contains('tv');
    if (!searchable) {
      final declared = types.isEmpty ? 'no content types' : types.join(', ');
      unsupported.add(
        'It declares $declared. Reelish only searches for movies and series, '
        'so it is never asked for streams.',
      );
    }
    final blocked = plugin.disabledPlatforms.any(
      (name) => device.manifestNames.contains(name.trim().toLowerCase()),
    );
    if (blocked) {
      unsupported.add(
        'Its author marks it as not working on ${device.label}. It starts '
        'switched off here.',
      );
    }
    if (plugin.hasSettings) {
      limits.add(
        'It has settings in other apps. Reelish has no provider settings, so '
        'it runs with its defaults and some sources may be missing.',
      );
    }
    final level = unsupported.isNotEmpty
        ? PluginCompatibilityLevel.unsupported
        : limits.isNotEmpty
        ? PluginCompatibilityLevel.partial
        : PluginCompatibilityLevel.compatible;
    return PluginCompatibility(
      level: level,
      reasons: [...unsupported, ...limits],
      blockedOnDevice: blocked,
      searchable: searchable,
    );
  }

  /// A catalog repository judged from its scrapers before install: how many
  /// of its sources this device can use. Unknown when the catalog does not
  /// list platform data for any of them.
  static PluginCompatibility ofCatalog(
    ReelishPlugin plugin,
    ReelishDevice device,
  ) {
    final scrapers = plugin.scrapers;
    if (scrapers.isEmpty ||
        scrapers.every((scraper) => scraper.disabledPlatforms == null)) {
      return const PluginCompatibility(
        level: PluginCompatibilityLevel.unknown,
        reasons: [
          'The catalog does not say which devices its sources support. '
              'Reelish checks each source after you install it.',
        ],
      );
    }
    var unusable = 0;
    for (final scraper in scrapers) {
      final types = scraper.contentTypes;
      final blocked = (scraper.disabledPlatforms ?? const []).any(
        (name) => device.manifestNames.contains(name.trim().toLowerCase()),
      );
      if (blocked || !(types.contains('movie') || types.contains('tv'))) {
        unusable++;
      }
    }
    final total = scrapers.length;
    if (unusable == 0) {
      return const PluginCompatibility(
        level: PluginCompatibilityLevel.compatible,
      );
    }
    final reason = unusable == total
        ? 'None of its sources can be used on ${device.label}: their authors '
              'disable this device, or they only find content Reelish does not '
              'search for.'
        : '$unusable of its $total sources cannot be used on ${device.label}. '
              'They start switched off; the rest work as usual.';
    return PluginCompatibility(
      level: unusable == total
          ? PluginCompatibilityLevel.unsupported
          : PluginCompatibilityLevel.partial,
      reasons: [reason],
      searchable: unusable < total,
    );
  }

  /// `movie`, `tv` or the lower-cased original, as provider lookups match.
  static String normalizeType(String type) => switch (type.toLowerCase()) {
    'tv' || 'series' || 'show' || 'shows' => 'tv',
    'movie' || 'movies' || 'film' || 'films' => 'movie',
    final other => other,
  };
}
