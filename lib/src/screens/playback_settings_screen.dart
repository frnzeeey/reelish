import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/playback_settings.dart';
import '../navigation/app_transitions.dart';
import '../services/accent_settings_controller.dart';
import '../services/playback_settings_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/tv/tv_focus.dart';
import 'app_information_screens.dart';
import 'credits_screen.dart';
import 'legal_information_screen.dart';
import 'subtitle_addons_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.onPlaybackSettings,
    required this.onAppearanceSettings,
    required this.accentSettings,
  });

  final VoidCallback onPlaybackSettings;
  final VoidCallback onAppearanceSettings;
  final AccentSettingsController accentSettings;

  void _open(BuildContext context, WidgetBuilder builder) => Navigator.of(
    context,
  ).push(AppPageRoute<void>(context: context, builder: builder));

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Settings',
    subtitle: 'Make Reelish work the way you like.',
    bottomClearance: SettingsMetrics.dockClearance,
    children: [
      SettingsSection(
        label: 'GENERAL',
        children: [
          AnimatedBuilder(
            animation: accentSettings,
            builder: (context, _) => SettingsTile(
              icon: Symbols.palette_rounded,
              title: 'Appearance',
              description: 'Accent color for highlights and controls',
              value: accentSettings.value.label,
              onTap: onAppearanceSettings,
            ),
          ),
        ],
      ),
      SettingsSection(
        label: 'PLAYBACK',
        children: [
          SettingsTile(
            icon: Symbols.play_circle_rounded,
            title: 'Playback',
            description: 'Player, stream selection, subtitles and P2P',
            onTap: onPlaybackSettings,
          ),
          SettingsTile(
            icon: Symbols.closed_caption_rounded,
            title: 'Subtitle addons',
            description: 'Stremio subtitle sources searched while you watch',
            onTap: () => _open(context, (_) => const SubtitleAddonsScreen()),
          ),
        ],
      ),
      SettingsSection(
        label: 'ABOUT & INFORMATION',
        children: [
          // No version here: this tab is built during Home startup, which
          // must not wait on a platform call. About reads it on demand.
          SettingsTile(
            icon: Symbols.info_rounded,
            title: 'About Reelish',
            description: 'Version, build and updates',
            onTap: () => _open(context, (_) => const AboutScreen()),
          ),
          SettingsTile(
            icon: Symbols.handshake_rounded,
            title: 'Credits & attribution',
            description: 'TMDB, third-party services and acknowledgments',
            onTap: () => _open(context, (_) => const CreditsScreen()),
          ),
          SettingsTile(
            icon: Symbols.code_rounded,
            title: 'Open-source licenses',
            description: 'Licenses for Flutter, packages and fonts',
            onTap: () => showAppLicenses(context),
          ),
        ],
      ),
      SettingsSection(
        label: 'LEGAL',
        children: [
          SettingsTile(
            icon: Symbols.shield_rounded,
            title: 'Privacy policy',
            description:
                'What stays on your device and what is sent to services',
            onTap: () => _open(
              context,
              (_) =>
                  const LegalInformationScreen(document: LegalDocument.privacy),
            ),
          ),
          SettingsTile(
            icon: Symbols.gavel_rounded,
            title: 'Terms of use',
            description: 'Rules for using the app, add-ons and media sources',
            onTap: () => _open(
              context,
              (_) =>
                  const LegalInformationScreen(document: LegalDocument.terms),
            ),
          ),
        ],
      ),
      SettingsSection(
        label: 'SUPPORT',
        children: [
          SettingsTile(
            icon: Symbols.favorite_rounded,
            title: 'Support development',
            description: 'Optional help with development and server costs',
            onTap: () =>
                _open(context, (_) => const SupportDevelopmentScreen()),
          ),
        ],
      ),
    ],
  );
}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({
    super.key,
    required this.controller,
    required this.onBack,
  });

  final AccentSettingsController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Appearance',
    subtitle: 'Choose the accent used across the app.',
    icon: Symbols.palette_rounded,
    onBack: onBack,
    children: [
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) => SettingsSection(
          label: 'ACCENT COLOR',
          description: 'Used for highlights, selections and controls.',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const spacing = 8.0;
                  final itemWidth = (constraints.maxWidth - spacing * 3) / 4;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final accent in GlassTheme.accents)
                        _AccentChoice(
                          accent: accent,
                          selected: accent.id == controller.value.id,
                          width: itemWidth,
                          onTap: () => controller.update(accent),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _AccentChoice extends StatelessWidget {
  const _AccentChoice({
    required this.accent,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  final AccentPalette accent;
  final bool selected;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '${accent.label} accent color',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: width,
        height: 72,
        decoration: BoxDecoration(
          color: selected
              ? accent.primary.withValues(alpha: .12)
              : GlassTheme.elevatedSurface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected ? accent.primary : GlassTheme.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 23,
                  height: 23,
                  decoration: BoxDecoration(
                    color: accent.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.primary.withValues(alpha: .35),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        color: GlassTheme.background,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.primary),
                      ),
                      child: Icon(
                        Symbols.check_rounded,
                        size: 10,
                        color: accent.bright,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              accent.label,
              style: TextStyle(
                color: selected ? accent.bright : GlassTheme.textPrimary,
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class PlaybackSettingsScreen extends StatelessWidget {
  const PlaybackSettingsScreen({
    super.key,
    required this.controller,
    required this.plugins,
    required this.onBack,
  });

  final PlaybackSettingsController controller;
  final List<({String id, String name, String repository})> plugins;
  final VoidCallback onBack;

  Future<void> _save(PlaybackSettings value) => controller.update(value);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final settings = controller.value;
      return SettingsPage(
        title: 'Playback',
        subtitle: 'Fine tune streams, subtitles and controls.',
        icon: Symbols.play_circle_rounded,
        onBack: onBack,
        children: [
          _section('PLAYER', [
            _switchRow(
              'Loading overlay',
              'Show a loading indicator until the first video frame appears.',
              settings.showLoadingOverlay,
              (value) => _save(settings.copyWith(showLoadingOverlay: value)),
            ),
            _switchRow(
              'Show loading status',
              'Display the player connection status while video initializes.',
              settings.showLoadingStatus,
              (value) => _save(settings.copyWith(showLoadingStatus: value)),
            ),
            _switchRow(
              'Pause overlay',
              'When paused, show the title artwork, details and synopsis with a large play button.',
              settings.pauseOverlay,
              (value) => _save(settings.copyWith(pauseOverlay: value)),
            ),
            _switchRow(
              'Touch gestures',
              'Use double taps to seek and vertical swipes to adjust brightness or volume.',
              settings.touchGestures,
              (value) => _save(settings.copyWith(touchGestures: value)),
            ),
            _switchRow(
              'Hold to speed',
              'Temporarily increase playback speed while pressing and holding the video.',
              settings.holdToSpeed,
              (value) => _save(settings.copyWith(holdToSpeed: value)),
            ),
            _choiceRow(
              'Hold speed',
              'Playback speed while the video surface is held.',
              _speedLabel(settings.holdSpeed),
              enabled: settings.holdToSpeed,
              () async {
                final value = await _choose<double>(
                  context,
                  'Hold speed',
                  const [1.5, 2.0, 2.5, 3.0],
                  settings.holdSpeed,
                  label: _speedLabel,
                );
                if (value != null) {
                  await _save(settings.copyWith(holdSpeed: value));
                }
              },
            ),
            _choiceRow(
              'Default playback speed',
              'Starting speed for newly opened videos. In-player speed changes stay with the current video.',
              _speedLabel(settings.defaultPlaybackSpeed),
              () async {
                const speeds = [.5, .75, 1.0, 1.25, 1.5, 2.0];
                final value = await _choose<double>(
                  context,
                  'Default playback speed',
                  speeds,
                  settings.defaultPlaybackSpeed,
                  label: _speedLabel,
                );
                if (value != null) {
                  await _save(settings.copyWith(defaultPlaybackSpeed: value));
                }
              },
            ),
            _choiceRow(
              'Preferred video quality',
              'Preferred resolution for new videos when the stream exposes selectable video tracks.',
              _qualityLabel(settings.preferredVideoHeight),
              () async {
                const heights = [0, 480, 720, 1080, 1440, 2160];
                final value = await _choose<int>(
                  context,
                  'Preferred video quality',
                  heights,
                  settings.preferredVideoHeight,
                  label: _qualityLabel,
                );
                if (value != null) {
                  await _save(settings.copyWith(preferredVideoHeight: value));
                }
              },
            ),
          ]),
          _section('STREAM AUTO-PLAY', [
            _switchRow(
              'Auto stream selection',
              'Play the first available stream automatically. Turn off to choose from results.',
              settings.autoStreamSelection,
              (value) => _save(settings.copyWith(autoStreamSelection: value)),
            ),
            _sliderRow(
              'Stream selection timeout',
              'Wait for more provider results before opening the stream picker.',
              settings.streamSelectionTimeoutSeconds.toDouble(),
              min: 1,
              max: 15,
              divisions: 14,
              valueLabel: '${settings.streamSelectionTimeoutSeconds}s',
              onChanged: (value) => _save(
                settings.copyWith(streamSelectionTimeoutSeconds: value.round()),
              ),
            ),
            _choiceRow(
              'Allowed plugins',
              'Choose which installed providers can return streams.',
              _providerSummary(settings.allowedProviderIds),
              () => _chooseProviders(context, settings),
            ),
          ]),
          _section('DECODER', [
            _infoRow(
              'Decoder configuration',
              'Platform managed',
              'Android uses Media3 with a MediaKit fallback; other platforms use their registered video_player backend. These adapters do not expose decoder, renderer, Dolby Vision, or tunneled playback controls.',
            ),
          ]),
          _section('SKIP SEGMENTS', [
            _infoRow(
              'Intro and outro detection',
              'Unavailable in this build',
              'Episode data and stream providers do not supply intro or outro timestamps, so automatic segment skipping is unavailable.',
            ),
          ]),
          _section('NEXT EPISODE', [
            _switchRow(
              'Auto-play next episode',
              'Start the next episode when the configured playback threshold is reached.',
              settings.autoPlayNextEpisode,
              (value) => _save(settings.copyWith(autoPlayNextEpisode: value)),
            ),
            _sliderRow(
              'Next episode threshold',
              'Percentage of the current episode used to offer the next one.',
              settings.nextEpisodeThresholdPercent.toDouble(),
              min: 50,
              max: 100,
              divisions: 50,
              valueLabel: '${settings.nextEpisodeThresholdPercent}%',
              onChanged: (value) => _save(
                settings.copyWith(nextEpisodeThresholdPercent: value.round()),
              ),
            ),
            _infoRow(
              'Binge group options',
              'Unavailable in this build',
              'The episode catalog has no binge-group metadata or grouping behavior to configure.',
            ),
          ]),
          _section('SUBTITLE AND AUDIO', [
            _choiceRow(
              'Preferred audio language',
              'Select the first matching audio track when available.',
              _languageLabel(settings.preferredAudioLanguage, device: true),
              () => _chooseLanguage(
                context,
                'Preferred audio language',
                settings.preferredAudioLanguage,
                (value) => settings.copyWith(preferredAudioLanguage: value),
                includeDevice: true,
              ),
            ),
            _choiceRow(
              'Secondary audio language',
              'Fallback audio language when the preferred language is unavailable.',
              _languageLabel(settings.secondaryAudioLanguage),
              () => _chooseLanguage(
                context,
                'Secondary audio language',
                settings.secondaryAudioLanguage,
                (value) => settings.copyWith(secondaryAudioLanguage: value),
              ),
            ),
            _choiceRow(
              'Preferred subtitle language',
              'Choose the subtitle language to select automatically.',
              _languageLabel(settings.preferredSubtitleLanguage),
              () => _chooseLanguage(
                context,
                'Preferred subtitle language',
                settings.preferredSubtitleLanguage,
                (value) => settings.copyWith(preferredSubtitleLanguage: value),
              ),
            ),
            _choiceRow(
              'Secondary subtitle language',
              'Fallback subtitle language.',
              _languageLabel(settings.secondarySubtitleLanguage),
              () => _chooseLanguage(
                context,
                'Secondary subtitle language',
                settings.secondarySubtitleLanguage,
                (value) => settings.copyWith(secondarySubtitleLanguage: value),
              ),
            ),
            _switchRow(
              'Strip SDH subtitles',
              'Hide subtitles marked for sound descriptions or closed captions.',
              settings.stripSdhSubtitles,
              (value) => _save(settings.copyWith(stripSdhSubtitles: value)),
            ),
            _switchRow(
              'Use forced subtitles',
              'Prefer forced subtitles matching the selected audio language.',
              settings.useForcedSubtitles,
              (value) => _save(settings.copyWith(useForcedSubtitles: value)),
            ),
            _switchRow(
              'Show only preferred languages',
              'Filter the subtitle picker to your preferred subtitle languages.',
              settings.showOnlyPreferredLanguages,
              (value) =>
                  _save(settings.copyWith(showOnlyPreferredLanguages: value)),
            ),
            _choiceRow(
              'Subtitle addons',
              'Stremio subtitle addons searched while you watch.',
              'Manage',
              () => Navigator.of(context).push(
                AppPageRoute<void>(
                  context: context,
                  builder: (_) => const SubtitleAddonsScreen(),
                ),
              ),
            ),
          ]),
          _section('SUBTITLE RENDERING', [
            _sliderRow(
              'Subtitle size',
              'Text size for external SRT and WebVTT subtitles.',
              settings.subtitleSize,
              min: 12,
              max: 36,
              divisions: 24,
              valueLabel: '${settings.subtitleSize.round()} sp',
              onChanged: (value) =>
                  _save(settings.copyWith(subtitleSize: value)),
            ),
            _sliderRow(
              'Subtitle position',
              'Raise or lower subtitles. Also adjustable while '
                  'watching, from the player settings.',
              settings.subtitlePosition,
              min: PlaybackSettings.subtitlePositionMin,
              max: PlaybackSettings.subtitlePositionMax,
              divisions: 25,
              valueLabel: subtitlePositionLabel(settings.subtitlePosition),
              onChanged: (value) =>
                  _save(settings.copyWith(subtitlePosition: value)),
            ),
            _switchRow(
              'Bold',
              'Use a heavier subtitle font weight.',
              settings.subtitleBold,
              (value) => _save(settings.copyWith(subtitleBold: value)),
            ),
            _colorRow(
              context,
              'Text color',
              Color(settings.subtitleTextColor),
              (color) =>
                  _save(settings.copyWith(subtitleTextColor: color.toARGB32())),
            ),
            _colorRow(
              context,
              'Background color',
              Color(settings.subtitleBackgroundColor),
              (color) => _save(
                settings.copyWith(subtitleBackgroundColor: color.toARGB32()),
              ),
              allowTransparent: true,
            ),
            _switchRow(
              'Outline',
              'Draw a contrasting border around subtitle text.',
              settings.subtitleOutline,
              (value) => _save(settings.copyWith(subtitleOutline: value)),
            ),
            _colorRow(
              context,
              'Outline color',
              Color(settings.subtitleOutlineColor),
              (color) => _save(
                settings.copyWith(subtitleOutlineColor: color.toARGB32()),
              ),
            ),
            _infoRow(
              'ASS / SSA rendering',
              'External SRT and WebVTT only',
              'The app currently renders text cues itself. libass styles and animations are not available in this player adapter.',
            ),
          ]),
          _section('P2P STREAMING', [
            _switchRow(
              'P2P streaming',
              'Allow torrent sources from installed providers on Android.',
              settings.p2pStreaming,
              (value) => _save(settings.copyWith(p2pStreaming: value)),
            ),
            _actionRow(
              'Clear torrent cache',
              'Remove files stored by torrent playback.',
              'Clear',
              () => _confirmClearTorrentCache(context),
            ),
            _infoRow(
              'Torrent cache limit',
              '5 GB, checked at launch',
              'Torrent data is deleted automatically the next time Reelish starts once it uses more than 5 GB. Clear torrent cache frees the space sooner.',
            ),
          ]),
          _section('STREAM SELECTION', [
            _switchRow(
              'Reuse last link',
              'Try the last working stream for this title while its cache is valid.',
              settings.reuseLastLink,
              (value) => _save(settings.copyWith(reuseLastLink: value)),
            ),
            _choiceRow(
              'Last link cache duration',
              'Forget saved stream links after this period.',
              _durationLabel(settings.lastLinkCacheHours),
              () async {
                final value = await _choose<int>(
                  context,
                  'Last link cache duration',
                  const [6, 12, 24, 48, 72, 168],
                  settings.lastLinkCacheHours,
                  label: _durationLabel,
                );
                if (value != null) {
                  await _save(settings.copyWith(lastLinkCacheHours: value));
                }
              },
            ),
          ]),
        ],
      );
    },
  );

  Widget _section(String title, List<Widget> children) =>
      SettingsSection(label: title, children: children);

  Widget _switchRow(
    String title,
    String description,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SettingsSwitchTile(
    title: title,
    description: description,
    value: value,
    onChanged: onChanged,
  );

  Widget _choiceRow(
    String title,
    String description,
    String value,
    VoidCallback onTap, {
    bool enabled = true,
  }) => SettingsTile(
    title: title,
    description: description,
    value: value,
    onTap: onTap,
    enabled: enabled,
  );

  Widget _infoRow(String title, String value, String description) =>
      SettingsTile(title: title, description: description, value: value);

  Widget _actionRow(
    String title,
    String description,
    String action,
    VoidCallback onTap,
  ) => SettingsTile(
    title: title,
    description: description,
    trailing: TextButton(onPressed: onTap, child: Text(action)),
  );

  Widget _sliderRow(
    String title,
    String description,
    double value, {
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
  }) => SettingsSliderTile(
    title: title,
    description: description,
    value: value,
    min: min,
    max: max,
    divisions: divisions,
    valueLabel: valueLabel,
    onChanged: onChanged,
  );

  Widget _colorRow(
    BuildContext context,
    String title,
    Color color,
    ValueChanged<Color> onSelected, {
    bool allowTransparent = false,
  }) => SettingsTile(
    title: title,
    value: color.a == 0
        ? 'Transparent'
        : '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
    trailing: Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white38),
      ),
    ),
    onTap: () async {
      final initial = HSVColor.fromColor(color.a == 0 ? Colors.white : color);
      var hue = initial.hue;
      var saturation = initial.saturation;
      var brightness = initial.value;
      var alpha = allowTransparent ? initial.alpha : 1.0;
      final chosen = await showDialog<Color>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final preview = HSVColor.fromAHSV(
              alpha,
              hue,
              saturation,
              brightness,
            ).toColor();
            return AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 44,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: preview,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white38),
                      ),
                    ),
                    _colorSlider(
                      'Hue',
                      hue,
                      0,
                      360,
                      color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                      onChanged: (value) => setDialogState(() => hue = value),
                    ),
                    _colorSlider(
                      'Saturation',
                      saturation,
                      0,
                      1,
                      color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                      onChanged: (value) =>
                          setDialogState(() => saturation = value),
                    ),
                    _colorSlider(
                      'Brightness',
                      brightness,
                      0,
                      1,
                      color: HSVColor.fromAHSV(1, hue, saturation, 1).toColor(),
                      onChanged: (value) =>
                          setDialogState(() => brightness = value),
                    ),
                    if (allowTransparent)
                      _colorSlider(
                        'Opacity',
                        alpha,
                        0,
                        1,
                        onChanged: (value) =>
                            setDialogState(() => alpha = value),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, preview),
                  child: const Text('Choose'),
                ),
              ],
            );
          },
        ),
      );
      if (chosen != null) onSelected(chosen);
    },
  );

  Widget _colorSlider(
    String label,
    double value,
    double min,
    double max, {
    Color? color,
    required ValueChanged<double> onChanged,
  }) => Row(
    children: [
      SizedBox(width: 82, child: Text(label)),
      if (color != null)
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      Expanded(
        child: TvSliderNavigation(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: max > 1 ? 36 : 20,
            onChanged: onChanged,
          ),
        ),
      ),
    ],
  );

  Future<void> _chooseLanguage(
    BuildContext context,
    String title,
    String current,
    PlaybackSettings Function(String) update, {
    bool includeDevice = false,
  }) async {
    final options = <String>[
      if (includeDevice) 'device',
      '',
      'en',
      'es',
      'fr',
      'de',
      'it',
      'pt',
      'ja',
      'ko',
      'zh',
      'ar',
      'ru',
    ];
    final value = await _choose<String>(
      context,
      title,
      options,
      current,
      label: (value) => _languageLabel(value, device: includeDevice),
    );
    if (value != null) await _save(update(value));
  }

  Future<T?> _choose<T>(
    BuildContext context,
    String title,
    List<T> options,
    T current, {
    String Function(T)? label,
  }) => showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (context) => Material(
      color: GlassTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        side: BorderSide(color: GlassTheme.border),
      ),
      child: SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final option in options)
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                selected: option == current,
                selectedColor: GlassTheme.coralBright,
                title: Text(label?.call(option) ?? '$option'),
                trailing: option == current
                    ? Icon(Symbols.check_rounded, color: GlassTheme.primary)
                    : null,
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _chooseProviders(
    BuildContext context,
    PlaybackSettings settings,
  ) async {
    final initial = settings.allowedProviderIds == null
        ? plugins.map((plugin) => plugin.id).toSet()
        : Set<String>.of(settings.allowedProviderIds!);
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (context) {
        final values = Set<String>.of(initial);
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Allowed plugins'),
            content: SizedBox(
              width: 420,
              child: plugins.isEmpty
                  ? const Text('Install a provider plugin first.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final plugin in plugins)
                          CheckboxListTile(
                            value: values.contains(plugin.id),
                            title: Text(plugin.name),
                            subtitle: Text(plugin.repository),
                            onChanged: (checked) => setState(() {
                              if (checked == true) {
                                values.add(plugin.id);
                              } else {
                                values.remove(plugin.id);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, <String>{'__all__'}),
                child: const Text('All enabled'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, values),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    final all = plugins.map((plugin) => plugin.id).toSet();
    final allSelected =
        selected.contains('__all__') || selected.containsAll(all);
    await _save(
      settings.copyWith(
        allowedProviderIds: allSelected ? null : selected,
        clearAllowedProviderIds: allSelected,
      ),
    );
  }

  Future<void> _confirmClearTorrentCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear torrent cache?'),
        content: const Text(
          'This removes cached torrent files stored by Reelish.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final clearedNow = await controller.clearTorrentCache();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              clearedNow
                  ? 'Torrent cache cleared.'
                  : 'A torrent played this session, so the cache will be cleared the next time Reelish starts.',
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not clear the torrent cache.')),
        );
      }
    }
  }

  String _providerSummary(Set<String>? ids) {
    if (ids == null) return 'All enabled plugins';
    if (ids.isEmpty) return 'None selected';
    return '${ids.length} selected';
  }

  String _languageLabel(String value, {bool device = false}) => switch (value) {
    'device' when device => 'Device language',
    '' => 'None',
    'en' => 'English',
    'es' => 'Spanish',
    'fr' => 'French',
    'de' => 'German',
    'it' => 'Italian',
    'pt' => 'Portuguese',
    'ja' => 'Japanese',
    'ko' => 'Korean',
    'zh' => 'Chinese',
    'ar' => 'Arabic',
    'ru' => 'Russian',
    _ => value,
  };

  String _qualityLabel(int height) => height == 0 ? 'Auto' : '${height}p';

  /// `2.0` reads as "2×" and `1.25` as "1.25×".
  String _speedLabel(double speed) =>
      '${speed == speed.roundToDouble() ? speed.toInt() : speed}×';

  String _durationLabel(int hours) => hours >= 24
      ? '${hours ~/ 24} day${hours >= 48 ? 's' : ''}'
      : '$hours hours';
}
