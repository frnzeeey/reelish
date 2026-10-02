/// Chooses the best available video height for a preferred resolution.
///
/// A value of 0 means automatic selection. When the exact preference is not
/// available, prefer the highest rendition below it; if every rendition is
/// higher, use the lowest one so a preference never makes playback impossible.
int? selectPreferredVideoHeight(Iterable<int?> available, int preferredHeight) {
  if (preferredHeight <= 0) return null;
  final heights =
      available.whereType<int>().where((height) => height > 0).toSet().toList()
        ..sort();
  if (heights.isEmpty) return null;
  return heights.where((height) => height <= preferredHeight).lastOrNull ??
      heights.first;
}
