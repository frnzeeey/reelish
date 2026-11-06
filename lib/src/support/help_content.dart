// The questions and troubleshooting articles in Help & Support. Every answer
// describes what Reelish actually does today; when a feature changes, change
// its answer here (help_content_test checks names against the app's own
// labels where it can).

enum FaqCategory {
  gettingStarted('Getting started'),
  playback('Playback'),
  subtitles('Subtitles'),
  sources('Providers & plugins'),
  library('Library & history'),
  trakt('Trakt'),
  watchParty('Watch party'),
  updates('Updates'),
  downloads('Downloads'),
  privacy('Account & privacy');

  const FaqCategory(this.label);
  final String label;
}

class FaqEntry {
  const FaqEntry(this.category, this.question, this.answer);
  final FaqCategory category;
  final String question;
  final String answer;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return q
        .split(RegExp(r'\s+'))
        .every(
          (word) =>
              question.toLowerCase().contains(word) ||
              answer.toLowerCase().contains(word) ||
              category.label.toLowerCase().contains(word),
        );
  }
}

/// A problem, why it happens, and what to try, ending in a report.
class TroubleshootingArticle {
  const TroubleshootingArticle({
    required this.id,
    required this.title,
    required this.summary,
    required this.causes,
    required this.solutions,
    this.moreSteps = const [],
    required this.reportCategory,
  });

  final String id;
  final String title;
  final String summary;
  final List<String> causes;
  final List<String> solutions;
  final List<String> moreSteps;

  /// The bug category its "Report this problem" button starts with.
  final String reportCategory;
}

const faqEntries = <FaqEntry>[
  FaqEntry(
    FaqCategory.gettingStarted,
    'Why do I need to sign in with Trakt?',
    'Reelish signs you in with your Trakt account. Once you are signed in, '
        'the movie and series catalog loads through the Reelish service. Your '
        'display name and avatar stay on this device.',
  ),
  FaqEntry(
    FaqCategory.gettingStarted,
    'Why is there nothing to play right after installing?',
    'Reelish does not include video sources. Open Plugins and add a provider '
        'collection from the Plugin Library or by link. Its '
        'providers search for streams when you press Play.',
  ),
  FaqEntry(
    FaqCategory.gettingStarted,
    'Which devices does Reelish run on?',
    'Android phones and tablets, Android TV and Google TV, and Windows. Each '
        'has its own layout: touch on phones, the remote on TVs, and mouse, '
        'keyboard or a game controller on Windows.',
  ),
  FaqEntry(
    FaqCategory.playback,
    'How do I pick a different stream?',
    'While a title plays, open the player\'s source list and choose another '
        'stream. Playback settings has Stream selection and Stream auto-play '
        'for how Reelish picks one on its own.',
  ),
  FaqEntry(
    FaqCategory.playback,
    'Can I choose the video player?',
    'No. The decoder is managed by Reelish for each device. On Android, '
        'HTTPS streams open in Android\'s own player first and other streams '
        'in libmpv; Windows uses libmpv.',
  ),
  FaqEntry(
    FaqCategory.playback,
    'What is P2P streaming?',
    'Some providers return torrent sources. With P2P streaming turned on in '
        'Playback settings, Reelish plays them on 64-bit Android phones and '
        'TVs; Windows cannot. Torrent data is deleted automatically once it '
        'passes 5 GB, or right away with Clear torrent cache.',
  ),
  FaqEntry(
    FaqCategory.playback,
    'Does the next episode start by itself?',
    'Yes, if Auto-play next episode is on in Playback settings.',
  ),
  FaqEntry(
    FaqCategory.subtitles,
    'Where do subtitles come from?',
    'From subtitle addons: Stremio subtitle sources, with OpenSubtitles v3 '
        'added by default. Manage them in Settings › Subtitle addons, and '
        'pick a subtitle from the player\'s subtitle menu while you watch.',
  ),
  FaqEntry(
    FaqCategory.sources,
    'What does "Needs attention" or "Allow update" mean in Plugins?',
    'When a provider\'s code changes, Reelish pauses that provider until you '
        'review it and choose Allow update. It stops a collection from '
        'swapping in new code without your say.',
  ),
  FaqEntry(
    FaqCategory.sources,
    'Why do some providers find nothing?',
    'Providers are made by third parties. Many cover one region or language, '
        'and their sites change or go offline. Try another title or another '
        'provider. Playback settings › Allowed plugins limits which providers '
        'automatic selection uses.',
  ),
  FaqEntry(
    FaqCategory.sources,
    'Does Reelish make the providers?',
    'No. Provider collections are third-party code that runs in a sandbox. '
        'Install only collections you trust.',
  ),
  FaqEntry(
    FaqCategory.library,
    'Is my history shared between my devices?',
    'Continue watching, watch history and My list are kept on each device. '
        'My list can follow your Trakt watchlist: turn on Sync My list with '
        'Trakt watchlist in Profile and account.',
  ),
  FaqEntry(
    FaqCategory.library,
    'How do I remove a title from Continue watching?',
    'Remove it from your watch history in Library. My list is not affected.',
  ),
  FaqEntry(
    FaqCategory.trakt,
    'What does Reelish do with my Trakt account?',
    'It signs you in and, if you turn it on, syncs My list with your Trakt '
        'watchlist. Your Trakt tokens are kept encrypted by the Reelish '
        'service. You can sign out everywhere or delete your Reelish account '
        'in Profile and account.',
  ),
  FaqEntry(
    FaqCategory.watchParty,
    'How does a watch party work?',
    'On a title, choose Watch together to get an 8-digit code. Friends enter '
        'it in Settings › Join a watch party. Play, pause and seeking stay in '
        'sync for up to 5 people. Everyone needs a working source on their '
        'own device.',
  ),
  FaqEntry(
    FaqCategory.updates,
    'How do I update Reelish?',
    'Reelish checks for updates on its own, or you can choose Settings › '
        'About Reelish › Check for updates. On Android it downloads the '
        'update and opens Android\'s installer; allow "Install unknown apps" '
        'for Reelish once. On Windows the update installs, or a portable copy '
        'is saved as a ZIP.',
  ),
  FaqEntry(
    FaqCategory.updates,
    'The update downloaded, but it is not in my Downloads folder.',
    'That is expected: Reelish keeps the update in its own storage and hands '
        'it straight to Android\'s installer. If the installer cannot be '
        'opened, Reelish offers Save to Downloads (Android 10 and later) so '
        'you can install it from a file manager.',
  ),
  FaqEntry(
    FaqCategory.downloads,
    'Can I download movies to watch offline?',
    'No. Reelish streams; it has no offline downloads. The only files it '
        'downloads are its own updates.',
  ),
  FaqEntry(
    FaqCategory.privacy,
    'What information does Reelish collect?',
    'Your sign-in goes through Trakt, and catalog requests through the '
        'Reelish service. On Android, usage statistics are sent only if you '
        'agree; change it anytime in Settings › Share usage statistics. The '
        'Privacy policy has the details.',
  ),
  FaqEntry(
    FaqCategory.privacy,
    'How do I delete my account?',
    'Open Settings › Profile and account and choose Delete Reelish account. '
        'Data kept on this device, such as My list and history, stays until '
        'you remove it.',
  ),
];

const troubleshootingArticles = <TroubleshootingArticle>[
  TroubleshootingArticle(
    id: 'no_streams',
    title: 'Videos do not play or no sources are found',
    summary: 'Play searches for a while, then finds nothing or fails to start.',
    causes: [
      'No collection is installed, or its providers are switched off.',
      'A provider changed its code and is paused until you allow the update.',
      'The providers do not have this title, or their sites are down.',
      'The source found does not play on this device.',
    ],
    solutions: [
      'Open Plugins: install a collection, or switch providers on.',
      'In Plugins, review "Needs attention" and choose Allow update.',
      'Try another title to see whether the problem is the title or the providers.',
      'Pick a different stream from the player\'s source list.',
    ],
    moreSteps: [
      'Check Playback settings › Allowed plugins does not exclude the providers you want.',
      'Torrent sources play only on 64-bit Android with P2P streaming on.',
    ],
    reportCategory: 'sources',
  ),
  TroubleshootingArticle(
    id: 'black_video',
    title: 'Audio plays but the picture is black',
    summary: 'You hear the video, but the screen stays black.',
    causes: [
      'The stream uses a format this device cannot decode in hardware.',
      'The source itself is broken.',
    ],
    solutions: [
      'Choose another stream from the player\'s source list; Reelish tries '
          'another player engine for some formats.',
      'Try a lower quality stream.',
    ],
    moreSteps: ['Restart Reelish and try the same stream again.'],
    reportCategory: 'playback',
  ),
  TroubleshootingArticle(
    id: 'catalog',
    title: 'Movies or episodes do not load',
    summary: 'Home or a details page says it could not load titles.',
    causes: [
      'No internet connection, or a very slow one.',
      'Your sign-in expired.',
      'The Reelish service is busy or unavailable for a moment.',
    ],
    solutions: [
      'Check your connection, then choose Retry.',
      'If it keeps failing, sign out and sign in again in Profile and account.',
    ],
    moreSteps: [
      'Titles you saved or started stay available on this device while offline.',
    ],
    reportCategory: 'catalog',
  ),
  TroubleshootingArticle(
    id: 'providers',
    title: 'Providers are unavailable',
    summary: 'Plugins shows errors, or a collection does not load.',
    causes: [
      'The collection\'s address moved or its host is down.',
      'You were offline when Reelish started.',
      'A provider is paused for review.',
    ],
    solutions: [
      'Open Plugins and try again once you are online.',
      'Choose Allow update for providers under "Needs attention".',
      'Remove a collection that no longer loads and add its new address.',
    ],
    reportCategory: 'sources',
  ),
  TroubleshootingArticle(
    id: 'subtitles',
    title: 'Subtitles do not appear',
    summary: 'No subtitles are listed, or the chosen one does not show.',
    causes: [
      'No subtitle addon is installed, or none has this title.',
      'The subtitle is out of sync with this particular stream.',
    ],
    solutions: [
      'Open Settings › Subtitle addons; choose Restore OpenSubtitles v3 if it is missing.',
      'Pick another subtitle from the player\'s subtitle menu.',
      'Try another stream: subtitles match some releases better than others.',
    ],
    reportCategory: 'subtitles',
  ),
  TroubleshootingArticle(
    id: 'update_downloads',
    title: 'The update does not appear in the Downloads folder',
    summary: 'You downloaded an update but cannot find the file.',
    causes: [
      'By design, Reelish keeps the update in its own storage and opens '
          'Android\'s installer directly.',
      'Reelish is not allowed to install unknown apps.',
    ],
    solutions: [
      'Allow "Install unknown apps" for Reelish when asked, then check for '
          'updates again from About Reelish.',
      'If the installer cannot open, choose Save to Downloads (Android 10 '
          'and later) and install the file from a file manager.',
    ],
    moreSteps: [
      'On Android TV and Google TV the setting is under Security & '
          'restrictions › Unknown sources.',
    ],
    reportCategory: 'updates',
  ),
  TroubleshootingArticle(
    id: 'crashes',
    title: 'The app crashes or freezes',
    summary: 'Reelish closes on its own or stops responding.',
    causes: [
      'Low memory on the device, often on TVs.',
      'A problem in this version of Reelish.',
    ],
    solutions: [
      'Close other apps and open Reelish again.',
      'Update to the latest version from About Reelish.',
      'Note what you did just before it happened, and report it.',
    ],
    reportCategory: 'performance',
  ),
  TroubleshootingArticle(
    id: 'trakt',
    title: 'Trakt sync problems',
    summary: 'My list and your Trakt watchlist do not match.',
    causes: [
      'Sync My list with Trakt watchlist is off.',
      'Reelish lost access to your Trakt account.',
    ],
    solutions: [
      'In Profile and account, turn on Sync My list with Trakt watchlist, '
          'then choose Sync now.',
      'If Reelish asks you to sign in again to reconnect Trakt, do so.',
    ],
    reportCategory: 'trakt',
  ),
  TroubleshootingArticle(
    id: 'buffering',
    title: 'Buffering or slow playback',
    summary: 'Playback stops to load, or starts slowly.',
    causes: [
      'A slow or busy connection.',
      'The source\'s server is slow.',
      'Torrent sources with few peers.',
    ],
    solutions: [
      'Choose another stream from the player\'s source list.',
      'Try a lower quality stream.',
      'Move closer to your Wi-Fi router, or use a wired connection on a TV.',
    ],
    reportCategory: 'playback',
  ),
];
