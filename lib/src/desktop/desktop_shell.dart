import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/resume_summary.dart';
import '../navigation/app_destination.dart';
import '../theme/glass_theme.dart';
import '../widgets/poster_image.dart';
import 'desktop_widgets.dart';
import '../widgets/brand_logo.dart';

/// The Windows interface's frame: a compact icon rail on the left and the
/// selected page beside it.
///
/// * The rail opens into a frosted panel with labels while the pointer is
///   over it or keyboard focus is inside it. Open, it lies over the page's
///   edge instead of pushing the page aside, so the page (a playing trailer,
///   a scrolled row, a loading grid) is never rebuilt or laid out again.
/// * "Keep sidebar open" pins it open beside the page instead, and is
///   remembered.
/// * Continue watching lives in the rail, between browsing and Plugins:
///   thumbnails when compact, titles and progress when open.
/// * Pages stay alive once visited, so each keeps its scroll position.
/// * Ctrl+F opens Search.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.destination,
    required this.onDestinationChanged,
    required this.pageBuilder,
    this.continueWatching,
  });

  final TvDestination destination;
  final ValueChanged<TvDestination> onDestinationChanged;
  final Widget Function(BuildContext context, TvDestination destination)
  pageBuilder;

  /// The rail's Continue watching section; none without it.
  final DesktopResumeShelf? continueWatching;

  static const collapsedWidth = 80.0;
  static const expandedWidth = 248.0;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  /// Its own key: the earlier sidebar saved "expanded" under
  /// 'reelish.desktop.sidebarExpanded' (true by default), which must not
  /// pin the new rail open. That old value is left alone and unread.
  static const _pinnedKey = 'reelish.desktop.sidebarPinned';

  bool _pinned = false;

  /// Holds focus when nothing inside does; the rail hands focus back here.
  final _shellFocus = FocusNode(debugLabel: 'Desktop shell');
  final Set<TvDestination> _visited = {};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.destination);
    SharedPreferences.getInstance().then((preferences) {
      final saved = preferences.getBool(_pinnedKey);
      if (saved != null && mounted) setState(() => _pinned = saved);
    });
  }

  @override
  void didUpdateWidget(covariant DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.destination);
  }

  @override
  void dispose() {
    _shellFocus.dispose();
    super.dispose();
  }

  void _togglePinned() {
    setState(() => _pinned = !_pinned);
    SharedPreferences.getInstance().then(
      (preferences) => preferences.setBool(_pinnedKey, _pinned),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
          widget.onDestinationChanged(TvDestination.search),
    },
    // Holds focus when nothing inside does, so the shortcut always works.
    // Never a traversal stop: it covers the window, so Tab, the arrow keys
    // and a controller's D-pad would otherwise land on it, invisibly.
    child: Focus(
      focusNode: _shellFocus,
      autofocus: true,
      skipTraversal: true,
      child: Scaffold(
        backgroundColor: GlassTheme.background,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // The page's width follows only the pin, never the hover, so
            // opening the rail costs the page nothing.
            AnimatedPositioned(
              duration: desktopMotion(context, 220),
              curve: DesktopSurfaces.curve,
              left: _pinned
                  ? DesktopShell.expandedWidth
                  : DesktopShell.collapsedWidth,
              top: 0,
              right: 0,
              bottom: 0,
              child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final destination in TvDestination.values)
                      if (_visited.contains(destination))
                        _Page(
                          key: ValueKey(destination),
                          active: destination == widget.destination,
                          child: widget.pageBuilder(context, destination),
                        ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _Sidebar(
                pinned: _pinned,
                selected: widget.destination,
                onSelected: widget.onDestinationChanged,
                onTogglePinned: _togglePinned,
                onReleaseFocus: _shellFocus.requestFocus,
                shelf: widget.continueWatching,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = desktopMotion(context, 220);
    return Offstage(
      offstage: !active,
      // Outside the TickerMode, so a page that was hidden fades back in
      // from nothing rather than from where its muted fade stopped.
      child: AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: duration,
        curve: DesktopSurfaces.curve,
        child: AnimatedSlide(
          offset: active ? Offset.zero : const Offset(0, .015),
          duration: duration,
          curve: DesktopSurfaces.curve,
          child: TickerMode(
            enabled: active,
            child: ExcludeFocus(excluding: !active, child: child),
          ),
        ),
      ),
    );
  }
}

/// The rail. Its open state (hover, focus) lives here, so the shell and its
/// pages never rebuild as the pointer comes and goes.
class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.pinned,
    required this.selected,
    required this.onSelected,
    required this.onTogglePinned,
    required this.onReleaseFocus,
    this.shelf,
  });

  final bool pinned;
  final TvDestination selected;
  final ValueChanged<TvDestination> onSelected;
  final VoidCallback onTogglePinned;

  /// Moves focus out of the rail, so it can close.
  final VoidCallback onReleaseFocus;
  final DesktopResumeShelf? shelf;

  /// A pointer passing over on its way elsewhere does not open the rail...
  static const openDelay = Duration(milliseconds: 120);

  /// ...and one that slips off its edge for a moment does not close it.
  static const closeDelay = Duration(milliseconds: 220);

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _hoverOpen = false;
  bool _focusInside = false;
  Timer? _hoverTimer;

  /// Set by "Collapse sidebar": the pointer is still on the button, so
  /// hovering does not hold the rail open again until it has left.
  bool _hoverSuppressed = false;

  bool get _open => widget.pinned || _hoverOpen || _focusInside;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void _togglePinned() {
    if (widget.pinned) {
      // Collapsing closes the rail now. Otherwise the hover (or focus) it
      // was clicked with keeps it open over the page, the click seems to do
      // nothing, and a second click pins it again.
      _hoverTimer?.cancel();
      _hoverOpen = false;
      _hoverSuppressed = true;
      if (_focusInside) widget.onReleaseFocus();
    }
    widget.onTogglePinned();
  }

  void _setHover(bool inside) {
    _hoverTimer?.cancel();
    if (inside && _hoverSuppressed) return;
    if (inside == _hoverOpen) return;
    _hoverTimer = Timer(inside ? _Sidebar.openDelay : _Sidebar.closeDelay, () {
      if (mounted) setState(() => _hoverOpen = inside);
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    // Over the page: frosted, with depth. Pinned or closed it sits flush
    // beside the page, so there is nothing behind it to blur.
    final overlay = open && !widget.pinned;
    final duration = desktopMotion(context, 220);
    final radius = BorderRadius.horizontal(
      right: Radius.circular(overlay ? 22 : 0),
    );
    // Focus left in the rail by the keyboard or a controller would hold it
    // open, and mouse clicks never move focus. So the pointer leaving the
    // rail, or a click on the page, gives focus back to the shell.
    void release() {
      if (_focusInside) widget.onReleaseFocus();
    }

    return TapRegion(
      onTapOutside: (_) => release(),
      child: MouseRegion(
        onEnter: (_) => _setHover(true),
        onExit: (_) {
          _hoverSuppressed = false;
          _setHover(false);
          release();
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          // Keyboard and controller users get the labels too.
          onFocusChange: (focused) {
            if (focused != _focusInside) setState(() => _focusInside = focused);
          },
          child: RepaintBoundary(
            child: AnimatedContainer(
              duration: duration,
              curve: DesktopSurfaces.curve,
              width: open
                  ? DesktopShell.expandedWidth
                  : DesktopShell.collapsedWidth,
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: overlay ? .5 : 0),
                    blurRadius: 36,
                    offset: const Offset(10, 0),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  // One blur, only while the rail is open over the page.
                  enabled: overlay,
                  filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                  child: AnimatedContainer(
                    duration: duration,
                    curve: DesktopSurfaces.curve,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                            GlassTheme.primary.withValues(alpha: .07),
                            overlay
                                ? const Color(0x8C111117)
                                : DesktopSurfaces.sidebar,
                          ),
                          overlay
                              ? const Color(0xB30D0D12)
                              : DesktopSurfaces.sidebar,
                        ],
                        stops: const [0, .5],
                      ),
                      border: Border(
                        right: BorderSide(
                          color: Colors.white.withValues(
                            alpha: overlay ? .1 : .06,
                          ),
                        ),
                      ),
                    ),
                    child: FocusTraversalGroup(
                      child: _FillOrScroll(
                        minHeight: widget.shelf == null
                            ? _RailContents.fixedHeight
                            : _RailContents.fixedHeight +
                                  _ResumeSection.minHeight,
                        child: _RailContents(
                          open: open,
                          pinned: widget.pinned,
                          selected: widget.selected,
                          onSelected: widget.onSelected,
                          onTogglePinned: _togglePinned,
                          shelf: widget.shelf,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailContents extends StatelessWidget {
  const _RailContents({
    required this.open,
    required this.pinned,
    required this.selected,
    required this.onSelected,
    required this.onTogglePinned,
    this.shelf,
  });

  final bool open;
  final bool pinned;
  final TvDestination selected;
  final ValueChanged<TvDestination> onSelected;
  final VoidCallback onTogglePinned;
  final DesktopResumeShelf? shelf;

  /// The mark, every destination, the divider and the pin: what must fit
  /// before Continue watching gets any room.
  static const fixedHeight = 540.0;

  @override
  Widget build(BuildContext context) {
    final duration = desktopMotion(context, 200);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The mark keeps its place; the wordmark fades in beside it.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 12, 28),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  BrandAssets.appIcon,
                  width: 40,
                  height: 40,
                  cacheWidth: (40 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                ),
              ),
              Flexible(
                child: AnimatedOpacity(
                  duration: duration,
                  opacity: open ? 1 : 0,
                  // Laid out at its full width and clipped, so the narrow
                  // compact rail cuts it off instead of overflowing.
                  child: const Padding(
                    padding: EdgeInsets.only(left: 14),
                    child: SizedBox(
                      height: 18,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: 0,
                          maxWidth: double.infinity,
                          minHeight: 0,
                          maxHeight: double.infinity,
                          child: ReelishWordmark(height: 16),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Browsing first, then Continue watching in the room left; Plugins
        // and Settings sit at the foot. The same order for Tab and the
        // arrow keys.
        for (final destination in TvDestination.values) ...[
          if (destination == TvDestination.plugins) ...[
            if (shelf case final shelf?)
              Expanded(
                child: _ResumeSection(
                  open: open,
                  shelf: shelf,
                  onSeeAll: () => onSelected(TvDestination.library),
                ),
              )
            else
              const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: Divider(
                height: 1,
                color: Colors.white.withValues(alpha: .07),
              ),
            ),
          ],
          _SidebarItem(
            destination: destination,
            selected: destination == selected,
            open: open,
            onTap: () => onSelected(destination),
          ),
        ],
        const SizedBox(height: 6),
        _PinToggle(open: open, pinned: pinned, onTap: onTogglePinned),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// Fills the sidebar's height, so its foot sits at the bottom, and scrolls
/// instead of overflowing when the window is shorter than [minHeight].
class _FillOrScroll extends StatelessWidget {
  const _FillOrScroll({required this.minHeight, required this.child});

  final double minHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: SizedBox(
        height: math.max(constraints.maxHeight, minHeight),
        child: child,
      ),
    ),
  );
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.open,
    required this.onTap,
  });

  final TvDestination destination;
  final bool selected;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  final _item = GlobalKey();
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    final selected = widget.selected;
    final duration = desktopMotion(context, 160);
    final color = selected
        ? accent
        : _hovered || _focused
        ? Colors.white
        : Colors.white70;
    // The tooltip shows only while the labels are hidden. A hidden tooltip
    // drops its wrapper, so the item is keyed to keep its state and focus
    // as the rail opens and closes around it.
    return TooltipVisibility(
      visible: !widget.open,
      child: Tooltip(
        message: widget.destination.label,
        preferBelow: false,
        verticalOffset: 0,
        margin: const EdgeInsets.only(left: DesktopShell.collapsedWidth),
        child: Padding(
          key: _item,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            onShowHoverHighlight: (value) => setState(() => _hovered = value),
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              onTap: widget.onTap,
              child: Semantics(
                button: true,
                selected: selected,
                label: widget.destination.label,
                excludeSemantics: true,
                child: AnimatedContainer(
                  duration: duration,
                  curve: DesktopSurfaces.curve,
                  height: 46,
                  decoration: BoxDecoration(
                    // Selected: a soft accent light that fades to the right,
                    // with the bar, a filled icon and a bolder label, so it
                    // never depends on colour alone. Hover is neutral, so
                    // it never reads as selected.
                    gradient: selected
                        ? LinearGradient(
                            colors: [
                              accent.withValues(alpha: _hovered ? .28 : .22),
                              accent.withValues(alpha: _hovered ? .1 : .05),
                            ],
                          )
                        : null,
                    color: selected
                        ? null
                        : _hovered
                        ? Colors.white.withValues(alpha: .07)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: _focused
                          ? GlassTheme.coralBright
                          : selected
                          ? accent.withValues(alpha: .22)
                          : Colors.transparent,
                      width: _focused ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // The active page's accent bar.
                      AnimatedContainer(
                        duration: duration,
                        width: 3,
                        height: selected ? 20 : 0,
                        margin: const EdgeInsets.only(left: 5, right: 10),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Icon(
                        widget.destination.icon,
                        size: 23,
                        fill: selected ? 1 : 0,
                        color: color,
                      ),
                      // Built only while open: a hidden label would still
                      // take clicks and screen-reader focus at the rail's
                      // edge.
                      if (widget.open)
                        Flexible(
                          child: _FadeIn(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: Text(
                                widget.destination.label,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.clip,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 15,
                                  fontWeight: selected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the rail open beside the page, or lets it close again.
class _PinToggle extends StatelessWidget {
  const _PinToggle({
    required this.open,
    required this.pinned,
    required this.onTap,
  });

  final bool open;
  final bool pinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = pinned ? 'Collapse sidebar' : 'Keep sidebar open';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                const SizedBox(width: 17),
                Icon(
                  pinned
                      ? Symbols.left_panel_close_rounded
                      : Symbols.left_panel_open_rounded,
                  size: 22,
                  color: GlassTheme.muted,
                ),
                if (open)
                  Flexible(
                    child: _FadeIn(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades [child] in once, as the rail opens around it; a short hold lets
/// the panel widen first, so a label never shows squeezed.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: desktopMotion(context, 240),
    curve: const Interval(.35, 1, curve: Curves.easeOut),
    builder: (context, opacity, child) =>
        Opacity(opacity: opacity, child: child),
    child: child,
  );
}

/// What the rail's Continue watching section shows and does: the titles
/// Home's watch history holds, and the same play flow as everywhere else.
class DesktopResumeShelf {
  const DesktopResumeShelf({
    required this.items,
    required this.summaryOf,
    required this.onResume,
    required this.onDetails,
    this.loaded = true,
  });

  /// Started titles, most recent first.
  final List<MediaItem> items;

  /// The history has been read; until then the section shows nothing,
  /// rather than a moment of "nothing started".
  final bool loaded;

  /// Where each was left ("S2 E1 · 27 min left") and how far in.
  final ResumeSummary Function(MediaItem item) summaryOf;

  /// Plays on from where the title was left.
  final ValueChanged<MediaItem> onResume;

  /// Its details page, from a right click.
  final ValueChanged<MediaItem> onDetails;

  /// Titles listed at most; the library holds the rest.
  static const maxShown = 12;
}

/// Continue watching in the rail: a heading, then the most recent titles,
/// scrolling within the room between browsing and Plugins.
class _ResumeSection extends StatelessWidget {
  const _ResumeSection({
    required this.open,
    required this.shelf,
    required this.onSeeAll,
  });

  final bool open;
  final DesktopResumeShelf shelf;
  final VoidCallback onSeeAll;

  static const _headerHeight = 36.0;

  /// The heading and one title.
  static const minHeight = 12 + _headerHeight + _ResumeTile.height;

  @override
  Widget build(BuildContext context) {
    final items = shelf.items.take(DesktopResumeShelf.maxShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
          child: Divider(height: 1, color: Colors.white.withValues(alpha: .07)),
        ),
        SizedBox(
          height: _headerHeight,
          child: open
              ? _AtOpenWidth(
                  // Starts where the thumbnails do, so the heading and the
                  // list share one edge.
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: _ResumeTile.thumbLeft,
                      right: 6,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: _FadeIn(
                            child: Text(
                              'CONTINUE WATCHING',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: Color(0x8CFFFFFF),
                                fontSize: 10,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        if (items.isNotEmpty)
                          _FadeIn(
                            child: TextButton.icon(
                              onPressed: onSeeAll,
                              iconAlignment: IconAlignment.end,
                              icon: const Icon(
                                Symbols.chevron_right_rounded,
                                size: 14,
                              ),
                              label: const Text('See all'),
                              style: TextButton.styleFrom(
                                foregroundColor: GlassTheme.coralBright,
                                visualDensity: VisualDensity.compact,
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.only(
                                  left: 6,
                                  right: 2,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                // A button style's text replaces the theme's,
                                // font included.
                                textStyle: const TextStyle(
                                  fontFamily: GlassTheme.fontFamily,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                )
              // Compact: a quiet mark, so the thumbnails read as a group.
              : const Tooltip(
                  message: 'Continue watching',
                  child: Center(
                    child: Icon(
                      Symbols.history_rounded,
                      size: 18,
                      color: GlassTheme.muted,
                    ),
                  ),
                ),
        ),
        Expanded(
          child: items.isEmpty
              ? open && shelf.loaded
                    ? const _AtOpenWidth(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            _ResumeTile.thumbLeft,
                            4,
                            20,
                            0,
                          ),
                          child: _FadeIn(
                            child: Text(
                              'Titles you start appear here, ready to pick '
                              'up where you left off.',
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: 12.5,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink()
              // No scrollbar: it would crowd the thumbnails, and the wheel
              // and Tab both scroll the list.
              : ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  // A title cut by the list's foot fades out instead of
                  // ending on a hard edge.
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Colors.white,
                        Colors.white,
                        Color(0x00FFFFFF),
                      ],
                      stops: [0, math.max(0, 1 - 22 / rect.height), 1],
                    ).createShader(rect),
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 2, bottom: 12),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return _ResumeTile(
                          key: ValueKey('resume:${item.type}:${item.id}'),
                          item: item,
                          summary: shelf.summaryOf(item),
                          open: open,
                          onResume: () => shelf.onResume(item),
                          onDetails: () => shelf.onDetails(item),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Lays [child] out at the open rail's width, clipped while the rail is
/// still widening, so it never reflows or overflows mid-animation.
class _AtOpenWidth extends StatelessWidget {
  const _AtOpenWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: DesktopShell.expandedWidth,
      maxWidth: DesktopShell.expandedWidth,
      child: child,
    ),
  );
}

/// One title: its poster with a progress line, and, while the rail is
/// open, its name and where it was left. The poster sits where the
/// destination icons do, so nothing shifts as the rail opens.
class _ResumeTile extends StatefulWidget {
  const _ResumeTile({
    super.key,
    required this.item,
    required this.summary,
    required this.open,
    required this.onResume,
    required this.onDetails,
  });

  static const height = 62.0;

  /// A square poster, centred under the rail's icons.
  static const _thumb = 44.0;

  /// The thumbnail's left edge in the rail: the tile's margin, border and
  /// inset. The heading lines up with it.
  static const thumbLeft = 12.0 + 1 + 5;

  final MediaItem item;
  final ResumeSummary summary;
  final bool open;
  final VoidCallback onResume;
  final VoidCallback onDetails;

  @override
  State<_ResumeTile> createState() => _ResumeTileState();
}

class _ResumeTileState extends State<_ResumeTile> {
  // As on the destinations: keeps state and focus while the tooltip's
  // wrapper comes and goes.
  final _tile = GlobalKey();
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final summary = widget.summary;
    final caption = summary.label.isNotEmpty
        ? summary.label
        : item.type == 'series'
        ? 'Series'
        : 'Movie';
    // A series' episode code leads its caption ("S1 E14 · 14 min left").
    final parts = caption.split(' · ');
    final episode =
        item.type == 'series' && RegExp(r'^S\d+ E\d+$').hasMatch(parts.first)
        ? parts.first
        : null;
    final rest = episode == null ? caption : parts.skip(1).join(' · ');
    final active = _hovered || _focused;
    final duration = desktopMotion(context, 180);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return TooltipVisibility(
      visible: !widget.open,
      child: Tooltip(
        message: '${item.name}\n$caption',
        preferBelow: false,
        verticalOffset: 0,
        margin: const EdgeInsets.only(left: DesktopShell.collapsedWidth),
        child: Padding(
          key: _tile,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            onShowHoverHighlight: (value) => setState(() => _hovered = value),
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onResume();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              onTap: widget.onResume,
              onSecondaryTap: widget.onDetails,
              child: Semantics(
                button: true,
                label: 'Resume ${item.name}, $caption',
                customSemanticsActions: {
                  const CustomSemanticsAction(label: 'Details'):
                      widget.onDetails,
                },
                excludeSemantics: true,
                child: AnimatedContainer(
                  duration: duration,
                  curve: DesktopSurfaces.curve,
                  height: _ResumeTile.height - 4,
                  // The whole row lights up, quietly, so it reads as one
                  // target; the focus ring is the accent, as on the
                  // destinations.
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: _hovered ? .06 : 0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _focused
                          ? GlassTheme.coralBright
                          : Colors.white.withValues(alpha: _hovered ? .06 : 0),
                      width: _focused ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Less the focus ring's extra width, so the thumbnail
                      // never moves.
                      SizedBox(width: _focused ? 4 : 5),
                      _thumbnail(context, dpr, active, duration),
                      if (widget.open)
                        Expanded(
                          child: _FadeIn(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 12,
                                right: 8,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AnimatedDefaultTextStyle(
                                    duration: duration,
                                    style: TextStyle(
                                      fontFamily: GlassTheme.fontFamily,
                                      color: active
                                          ? Colors.white
                                          : const Color(0xE0FFFFFF),
                                      fontSize: 13,
                                      height: 1.25,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    child: Text(
                                      item.name,
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        if (episode != null)
                                          TextSpan(
                                            text: episode,
                                            style: const TextStyle(
                                              color: Color(0xCCFFFFFF),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        if (episode != null && rest.isNotEmpty)
                                          const TextSpan(text: '  ·  '),
                                        if (rest.isNotEmpty)
                                          TextSpan(text: rest),
                                      ],
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: GlassTheme.muted,
                                      fontSize: 11.5,
                                      height: 1.25,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The poster, a slim progress bar along its foot, and, on hover or
  /// focus, a resume glyph over a light shade with the art eased forward.
  Widget _thumbnail(
    BuildContext context,
    double dpr,
    bool active,
    Duration duration,
  ) {
    final item = widget.item;
    final fraction = widget.summary.fraction;
    final radius = BorderRadius.circular(10);
    return Container(
      width: _ResumeTile._thumb,
      height: _ResumeTile._thumb,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      // A hairline edge keeps dark posters off the dark rail.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: Colors.white.withValues(alpha: active ? .18 : .08),
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const PosterPlaceholder(iconSize: 16),
            if (item.poster.isNotEmpty)
              AnimatedScale(
                scale: active ? 1.06 : 1,
                duration: duration,
                curve: DesktopSurfaces.curve,
                child: Image.network(
                  item.poster,
                  fit: BoxFit.cover,
                  // Above the middle: the key art, not the billing block.
                  alignment: const Alignment(0, -.4),
                  cacheWidth: posterDecodeWidth(_ResumeTile._thumb * dpr),
                  frameBuilder: posterFadeIn(context),
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            // Shade under the bar, so it reads on any artwork.
            if (fraction > 0)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0x99000000)],
                    stops: [.55, 1],
                  ),
                ),
              ),
            AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: duration,
              curve: DesktopSurfaces.curve,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .38),
                child: Center(
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: GlassTheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Symbols.play_arrow_rounded,
                      fill: 1,
                      size: 17,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            if (fraction > 0)
              Positioned(
                left: 4,
                right: 4,
                bottom: 4,
                child: _ProgressLine(fraction: fraction),
              ),
          ],
        ),
      ),
    );
  }
}

/// How far in a title is: a slim, rounded bar on a soft track.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: Container(
      height: 3,
      color: Colors.white.withValues(alpha: .28),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        // Never a sliver too thin to see.
        widthFactor: fraction.clamp(.06, 1),
        heightFactor: 1,
        child: ColoredBox(color: GlassTheme.primary),
      ),
    ),
  );
}
