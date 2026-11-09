// Confirms that playback goes on after libmpv switches the audio track.

/// One look at the player after an audio switch.
class AudioSwitchSample {
  const AudioSwitchSample({required this.playing, required this.position});

  /// Playback is meant to advance (not paused or being scrubbed).
  final bool playing;
  final Duration position;
}

/// Watches the player after an audio switch until playback has clearly
/// gone on, or clearly stopped.
///
/// libmpv accepts every track it lists, but on Windows and Android an
/// alternative fMP4 rendition of an HLS stream that FFmpeg's demuxer did not
/// start at open freezes playback, and some seconds later libmpv ends it as
/// a lost connection, which fails the source. No error comes first, so [run]
/// reports failure when the position stands still for [stalledLimit] of
/// play, and success once it has moved on by [progress]. A paused player is
/// waited for, up to [maxWait] in all.
///
/// Only the position is used: reading libmpv's own audio state on request
/// blocks the UI thread on libmpv's core and can deadlock with the video
/// output. So a track whose codec libmpv cannot decode, which plays the
/// picture silently, passes.
class AudioSwitchCheck {
  AudioSwitchCheck({
    required this.sample,
    this.interval = const Duration(milliseconds: 500),
    this.stalledLimit = const Duration(seconds: 3),
    this.progress = const Duration(seconds: 2),
    this.maxWait = const Duration(seconds: 60),
  });

  /// Reads the player, or returns null once the check no longer matters
  /// (the player closed or another switch started).
  final AudioSwitchSample? Function() sample;
  final Duration interval;
  final Duration stalledLimit;
  final Duration progress;
  final Duration maxWait;

  /// True when playback went on (or the check was abandoned), false when it
  /// froze.
  Future<bool> run() async {
    var waited = Duration.zero;
    var stalled = Duration.zero;
    var moved = Duration.zero;
    Duration? last;
    while (waited < maxWait) {
      final now = sample();
      if (now == null) return true;
      if (now.playing) {
        if (last != null) {
          if (now.position > last) {
            moved += now.position - last;
            stalled = Duration.zero;
          } else {
            stalled += interval;
          }
        }
        if (moved >= progress) return true;
        if (stalled >= stalledLimit) return false;
        last = now.position;
      } else {
        // Paused: judge only time spent playing.
        last = null;
        stalled = Duration.zero;
      }
      await Future<void>.delayed(interval);
      waited += interval;
    }
    return true;
  }
}
