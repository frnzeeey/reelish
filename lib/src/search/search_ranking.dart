// How closely a title or a name matches what was typed. TMDB already orders
// each list by its own relevance; this only lifts exact and leading matches
// above loose ones, and picks a top result when one clearly stands out.

/// Lower case, accents and punctuation gone, spaces collapsed, a leading
/// "the" dropped: "The Lord of the Rings: The Two Towers" and "lord of the
/// rings the two towers" compare equal.
String normalizeForMatch(String text) {
  var out = text.toLowerCase();
  const accents = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
    'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i',
    'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o',
    'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ù': 'u', 'ú': 'u',
    'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'æ': 'ae', 'œ': 'oe',
    'ß': 'ss',
  };
  out = out.split('').map((c) => accents[c] ?? c).join();
  out = out.replaceAll('&', ' and ');
  out = out.replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ' ').trim();
  if (out.startsWith('the ')) out = out.substring(4);
  return out;
}

/// How well [candidate] (and its original-language title) matches [query]:
/// 3 exact, 2 starts with it, 1 has every word, 0 otherwise.
int matchScore(String query, String candidate, {String original = ''}) {
  final q = normalizeForMatch(query);
  if (q.isEmpty) return 0;
  var best = 0;
  for (final text in [candidate, original]) {
    final c = normalizeForMatch(text);
    if (c.isEmpty) continue;
    final score = c == q
        ? 3
        : c.startsWith('$q ') || c.startsWith(q)
        ? 2
        : q.split(' ').every((word) => c.split(' ').contains(word))
        ? 1
        : 0;
    if (score > best) best = score;
  }
  return best;
}

/// [items] with closer matches first; TMDB's order breaks ties, so its
/// relevance (popularity, release) still decides among equals.
List<T> rankByMatch<T>(
  String query,
  List<T> items,
  String Function(T) title, {
  String Function(T)? original,
}) {
  final scored = [
    for (final (index, item) in items.indexed)
      (
        item,
        matchScore(query, title(item), original: original?.call(item) ?? ''),
        index,
      ),
  ];
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
  });
  return [for (final entry in scored) entry.$1];
}

/// A trailing year in a query ("dune 2021"), when there are words before it
/// and it could be a release year; used only to retry a search that found
/// nothing, since many titles end in a year ("Blade Runner 2049").
({String words, int year})? trailingYear(String query, {required int now}) {
  final match = RegExp(r'^(.*\S)\s+(\d{4})$').firstMatch(query.trim());
  if (match == null) return null;
  final year = int.parse(match.group(2)!);
  if (year < 1888 || year > now + 2) return null;
  return (words: match.group(1)!, year: year);
}
