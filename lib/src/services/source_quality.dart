// Resolution for choosing between provider sources: what each source claims,
// and how sources rank against a quality target (docs/playback/
// quality-prioritization.md). Claims come from plugins and are never verified
// before playback; nothing here guesses a resolution a source does not state.
import '../models/stream_source.dart';

abstract final class SourceQuality {
  static final _height = RegExp(
    r'(?<!\d)(4320|2160|1440|1080|720|576|480|360)\s*[pi]?(?!\d)',
    caseSensitive: false,
  );
  static final _uhd = RegExp(r'\b(4k|uhd)\b', caseSensitive: false);
  static final _eightK = RegExp(r'\b8k\b', caseSensitive: false);
  static final _fullHd = RegExp(r'\b(fhd|full\s*hd)\b', caseSensitive: false);
  static final _sd = RegExp(r'\bsd\b', caseSensitive: false);

  /// The height [source] claims, from its quality field, then its name, then
  /// its description; null when none says. A bare "HD" (720p or 1080p) is
  /// not a claim.
  static int? claimedHeight(StreamSource source) {
    for (final text in [source.quality, source.name, source.description]) {
      final height = heightOf(text);
      if (height != null) return height;
    }
    return null;
  }

  /// The height one label states, or null.
  static int? heightOf(String text) {
    if (text.trim().isEmpty) return null;
    final explicit = _height.firstMatch(text);
    if (explicit != null) return int.parse(explicit.group(1)!);
    if (_eightK.hasMatch(text)) return 4320;
    if (_uhd.hasMatch(text)) return 2160;
    if (_fullHd.hasMatch(text)) return 1080;
    if (_sd.hasMatch(text)) return 480;
    return null;
  }
}

/// The highest resolution worth playing first, and how sources rank by it.
class QualityTarget {
  const QualityTarget(this.height);

  /// No limit known: 4K first.
  static const best = QualityTarget(2160);

  final int height;

  /// Below this, a claimed height ranks after unknown ones.
  int get floor => height < 720 ? height : 720;

  /// Lower is better. Claimed heights from [floor] up to [height] first,
  /// highest first; then unknown heights (often adaptive "auto" streams);
  /// then claimed heights below [floor], highest first; then heights above
  /// [height], lowest first.
  int rank(StreamSource source) => rankOf(SourceQuality.claimedHeight(source));

  int rankOf(int? claimed) {
    if (claimed == null) return 10000;
    if (claimed > height) return 30000 + claimed;
    if (claimed >= floor) return 10000 - claimed;
    return 20000 + (10000 - claimed);
  }

  /// Whether [source] claims exactly what this target asks for.
  bool isIdeal(StreamSource source) =>
      SourceQuality.claimedHeight(source) == height;

  /// The target below [failed]: after a device could not decode or show a
  /// source of that height, the next tier down.
  QualityTarget below(int failed) {
    const tiers = [4320, 2160, 1440, 1080, 720, 480, 360];
    final next = tiers.where((tier) => tier < failed).firstOrNull ?? 360;
    return QualityTarget(next < height ? next : height);
  }

  @override
  bool operator ==(Object other) =>
      other is QualityTarget && other.height == height;

  @override
  int get hashCode => height.hashCode;

  @override
  String toString() => 'QualityTarget(${height}p)';
}
