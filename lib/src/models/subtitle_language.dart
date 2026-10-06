/// Subtitle language normalization and naming.
///
/// Normalizes language codes:
/// lowercase, `_`→`-`, Brazilian/European Portuguese and Latin American
/// Spanish detection, then 3-letter code and language-name aliases. Codes are
/// ISO 639-1 (`en`), with `pt-BR`, `es-419`, `zh-CN` and `zh-TW` regions kept.
abstract final class SubtitleLanguage {
  /// Normalized code used for an unknown language.
  static const unknown = 'unknown';

  static const _codeAliases = {
    'pt-pt': 'pt',
    'pt_br': 'pt-BR',
    'pt-br': 'pt-BR',
    'br': 'pt-BR',
    'pob': 'pt-BR',
    'eng': 'en',
    'spa': 'es',
    'es-419': 'es-419',
    'es_419': 'es-419',
    'es-la': 'es-419',
    'es-lat': 'es-419',
    'fra': 'fr',
    'fre': 'fr',
    'deu': 'de',
    'ger': 'de',
    'ita': 'it',
    'por': 'pt',
    'rus': 'ru',
    'jpn': 'ja',
    'kor': 'ko',
    'zho': 'zh',
    'chi': 'zh',
    'zht': 'zh-TW',
    'zhs': 'zh-CN',
    'chi-tw': 'zh-TW',
    'chi-cn': 'zh-CN',
    'zh-tw': 'zh-TW',
    'zh_tw': 'zh-TW',
    'zh-cn': 'zh-CN',
    'zh_cn': 'zh-CN',
    'ara': 'ar',
    'hin': 'hi',
    'nld': 'nl',
    'dut': 'nl',
    'pol': 'pl',
    'swe': 'sv',
    'nor': 'no',
    'dan': 'da',
    'fin': 'fi',
    'tur': 'tr',
    'ell': 'el',
    'gre': 'el',
    'heb': 'he',
    'tha': 'th',
    'vie': 'vi',
    'ind': 'id',
    'msa': 'ms',
    'may': 'ms',
    'ces': 'cs',
    'cze': 'cs',
    'hun': 'hu',
    'ron': 'ro',
    'rum': 'ro',
    'ukr': 'uk',
    'bul': 'bg',
    'hrv': 'hr',
    'srp': 'sr',
    'slk': 'sk',
    'slo': 'sk',
    'slv': 'sl',
    'cat': 'ca',
    'alb': 'sq',
    'sqi': 'sq',
    'bos': 'bs',
    'mac': 'mk',
    'mkd': 'mk',
    'lav': 'lv',
    'lit': 'lt',
    'est': 'et',
    'isl': 'is',
    'ice': 'is',
    'glg': 'gl',
    'baq': 'eu',
    'eus': 'eu',
    'wel': 'cy',
    'cym': 'cy',
    'gle': 'ga',
    'ben': 'bn',
    'tam': 'ta',
    'tel': 'te',
    'mal': 'ml',
    'kan': 'kn',
    'mar': 'mr',
    'pan': 'pa',
    'guj': 'gu',
    'urd': 'ur',
    'fas': 'fa',
    'per': 'fa',
    'amh': 'am',
    'swa': 'sw',
    'zul': 'zu',
    'afr': 'af',
    'mlt': 'mt',
    'bel': 'be',
    'geo': 'ka',
    'kat': 'ka',
    'arm': 'hy',
    'hye': 'hy',
    'aze': 'az',
    'kaz': 'kk',
    'uzb': 'uz',
    'mon': 'mn',
    'khm': 'km',
    'lao': 'lo',
    'mya': 'my',
    'bur': 'my',
    'sin': 'si',
    'nep': 'ne',
    'tgl': 'tl',
    'fil': 'tl',
  };

  /// English language names to codes (also used for display names).
  static const _names = {
    'afrikaans': 'af', 'albanian': 'sq', 'amharic': 'am', 'arabic': 'ar',
    'armenian': 'hy', 'azerbaijani': 'az', 'basque': 'eu',
    'belarusian': 'be', 'bengali': 'bn', 'bosnian': 'bs', 'bulgarian': 'bg',
    'burmese': 'my', 'catalan': 'ca', 'chinese': 'zh', 'mandarin': 'zh',
    'croatian': 'hr', 'czech': 'cs', 'danish': 'da', 'dutch': 'nl',
    'english': 'en', 'estonian': 'et', 'filipino': 'tl', 'finnish': 'fi',
    'french': 'fr', 'galician': 'gl', 'georgian': 'ka', 'german': 'de',
    'greek': 'el', 'gujarati': 'gu', 'hebrew': 'he', 'hindi': 'hi',
    'hungarian': 'hu', 'icelandic': 'is', 'indonesian': 'id', 'irish': 'ga',
    'italian': 'it', 'japanese': 'ja', 'kannada': 'kn', 'kazakh': 'kk',
    'khmer': 'km', 'korean': 'ko', 'lao': 'lo', 'latvian': 'lv',
    'lithuanian': 'lt', 'macedonian': 'mk', 'malay': 'ms',
    'malayalam': 'ml', 'maltese': 'mt', 'marathi': 'mr', 'mongolian': 'mn',
    'nepali': 'ne', 'norwegian': 'no', 'persian': 'fa', 'polish': 'pl',
    'punjabi': 'pa', 'romanian': 'ro', 'russian': 'ru', 'serbian': 'sr',
    'sinhala': 'si', 'slovak': 'sk', 'slovenian': 'sl', 'swahili': 'sw',
    'swedish': 'sv', 'tamil': 'ta', 'telugu': 'te', 'thai': 'th',
    'turkish': 'tr', 'ukrainian': 'uk', 'urdu': 'ur', 'uzbek': 'uz',
    'vietnamese': 'vi', 'welsh': 'cy', 'zulu': 'zu',
    // Common spellings the table above does not cover.
    'portuguese': 'pt', 'spanish': 'es', 'tagalog': 'tl',
  };

  static const _regionNames = {
    'pt-BR': 'Portuguese (Brazil)',
    'es-419': 'Spanish (Latin America)',
    'zh-CN': 'Chinese (Simplified)',
    'zh-TW': 'Chinese (Traditional)',
  };

  static final Map<String, String> _nameForCode = {
    for (final entry in _names.entries)
      // First (canonical) name wins, e.g. `zh` → Chinese, not Mandarin.
      if (entry.key != 'mandarin' && entry.key != 'tagalog')
        entry.value: _titleCase(entry.key),
  };

  static bool _containsAny(String value, List<String> needles) =>
      needles.any(value.contains);

  /// Normalizes a provider/addon language value (`eng`, `pob`, `English`,
  /// `pt_BR`, `Spanish (Latin America)`) to a code, or [unknown].
  static String normalize(String? raw) {
    final value = (raw ?? '')
        .trim()
        .replaceAll('_', '-')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (value.isEmpty) return unknown;

    if (_containsAny(value, const ['portuguese', 'portugues'])) {
      if (_containsAny(value, const [
        'brazil',
        'brasil',
        'brazilian',
        'brasileiro',
        'pt br',
        'ptbr',
        'pob',
        '(br)',
      ])) {
        return 'pt-BR';
      }
      return 'pt';
    }
    if (value == 'pt-br') return 'pt-BR';
    if (_containsAny(value, const [
          'portugal',
          'european',
          'europeu',
          'iberian',
          'pt pt',
          'ptpt',
        ]) &&
        value.startsWith('pt')) {
      return 'pt';
    }
    if (_containsAny(value, const ['spanish', 'espanol', 'castellano'])) {
      if (_containsAny(value, const [
        'latin',
        'latino',
        'latinoamerica',
        'latinoamericano',
        'lat am',
        'latam',
        'es 419',
        'es419',
        '(419)',
      ])) {
        return 'es-419';
      }
      return 'es';
    }

    final alias = _codeAliases[value];
    if (alias != null) return alias;
    final byName = _names[value];
    if (byName != null) return byName;
    // A name inside a longer label, such as "English (Forced)".
    final names = _names.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final name in names) {
      if (value.startsWith('$name ') ||
          value.endsWith(' $name') ||
          value.contains(' $name ')) {
        return _names[name]!;
      }
    }
    final base = value.split('-').first;
    final baseAlias = _codeAliases[base];
    if (baseAlias != null) return baseAlias;
    if (RegExp(r'^[a-z]{2}$').hasMatch(base)) {
      final region = value.contains('-') ? value.split('-').last : '';
      return region.isEmpty ? base : '$base-${region.toUpperCase()}';
    }
    return unknown;
  }

  /// A readable name for a normalized [code], such as `English` or
  /// `Portuguese (Brazil)`. Unknown codes are returned uppercased.
  static String name(String code) {
    if (code == unknown) return 'Unknown';
    final region = _regionNames[code];
    if (region != null) return region;
    final base = code.split('-').first;
    return _nameForCode[base] ?? code.toUpperCase();
  }

  /// Whether a subtitle in [language] satisfies a preferred language. A
  /// regional preference (`pt-BR`) needs that region; a plain preference
  /// (`pt`) accepts any region.
  static bool matches(String language, String preferred) {
    final track = normalize(language);
    final target = normalize(preferred);
    if (track == unknown || target == unknown) return false;
    if (track == target) return true;
    return !target.contains('-') &&
        track.split('-').first == target.split('-').first;
  }

  static String _titleCase(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}
