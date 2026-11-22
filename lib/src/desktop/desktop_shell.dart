import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/reelish_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/social/together_screen.dart';
import '../navigation/app_destination.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../widgets/ambient_backdrop.dart';
import 'desktop_widgets.dart';
import '../widgets/brand_logo.dart';
import '../widgets/count_badge.dart';
import '../widgets/avatar_frame.dart';
import '../widgets/profile_avatar.dart';

/// The Windows interface's frame: a floating navigation rail on the left
/// and the selected page beside it.
///
/// * The rail is a rounded panel held [inset] off the window's edges. It
///   shows icons only, and opens into a labelled, frosted panel while the
///   pointer rests on it or keyboard focus is inside it. Open, it lies over
///   the page's edge instead of pushing the page aside, so the page (a
///   playing trailer, a scrolled row, a loading grid) is never rebuilt or
///   laid out again.
/// * "Keep sidebar open" pins it open beside the page instead, and is
///   remembered.
/// * The rail is navigation only: browsing, then your library and friends,
///   then Plugins, Settings and Profile at its foot. Continue watching is
///   on Home, with the content.
/// * Pages stay alive once visited, so each keeps its scroll position.
/// * Ctrl+F opens Search.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.destination,
    required this.onDestinationChanged,
    required this.pageBuilder,
  });

  final TvDestination destination;
  final ValueChanged<TvDestination> onDestinationChanged;
  final Widget Function(BuildContext context, TvDestination destination)
  pageBuilder;

  /// The gap between the floating rail and the window's edges.
  static const inset = AppSpace.sm;

  /// The rail panel's width, compact and open.
  static const collapsedWidth = 72.0;
  static const expandedWidth = 232.0;

  /// Where the page starts: the rail and its gap from the window edge.
  static const collapsedExtent = inset + collapsedWidth;
  static const expandedExtent = inset + expandedWidth;

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
            // The theme's soft light, behind everything.
            const AmbientBackdrop(),
            // The page's width follows only the pin, never the hover, so
            // opening the rail costs the page nothing.
            AnimatedPositioned(
              duration: desktopMotion(context, 220),
              curve: DesktopSurfaces.curve,
              left: _pinned
                  ? DesktopShell.expandedExtent
                  : DesktopShell.collapsedExtent,
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
              left: DesktopShell.inset,
              top: DesktopShell.inset,
              bottom: DesktopShell.inset,
              child: _Sidebar(
                pinned: _pinned,
                selected: widget.destination,
                onSelected: widget.onDestinationChanged,
                onTogglePinned: _togglePinned,
                onReleaseFocus: _shellFocus.requestFocus,
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
  });

  final bool pinned;
  final TvDestination selected;
  final ValueChanged<TvDestination> onSelected;
  final VoidCallback onTogglePinned;

  /// Moves focus out of the rail, so it can close.
  final VoidCallback onReleaseFocus;

  /// A pointer passing over on its way elsewhere does not open the rail...
  static const openDelay = Duration(milliseconds: 120);

  /// ...and one that slips off its edge for a moment does not close it.
  static const closeDelay = Duration(milliseconds: 220);

  /// The floating panel's corners.
  static const radius = AppRadius.xl;

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
    // Over the page: frosted, with more depth. Compact or pinned it is a
    // quiet, solid panel; there is nothing behind it worth blurring.
    final overlay = open && !widget.pinned;
    final duration = desktopMotion(context, 220);
    final dark = GlassTheme.surfaces.brightness == Brightness.dark;
    final radius = BorderRadius.circular(_Sidebar.radius);
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
              // Soft, warm depth: enough to float, never a hard edge.
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: overlay ? (dark ? .45 : .14) : (dark ? .22 : .06),
                    ),
                    blurRadius: overlay ? 40 : 20,
                    offset: Offset(overlay ? 8 : 0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  // One blur, only while the rail is open over the page.
                  enabled: overlay,
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: AnimatedContainer(
                    duration: duration,
                    curve: DesktopSurfaces.curve,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      color: overlay
                          ? Color.lerp(
                              DesktopSurfaces.sidebar,
                              GlassTheme.surface,
                              .35,
                            )!.withValues(alpha: .78)
                          : DesktopSurfaces.sidebar,
                      border: Border.all(
                        color: GlassTheme.textPrimary.withValues(
                          alpha: overlay ? .12 : .07,
                        ),
                      ),
                    ),
                    child: FocusTraversalGroup(
                      child: _FillOrScroll(
                        minHeight: _RailContents.fixedHeight,
                        child: _RailContents(
                          open: open,
                          pinned: widget.pinned,
                          selected: widget.selected,
                          onSelected: widget.onSelected,
                          onTogglePinned: _togglePinned,
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
  });

  final bool open;
  final bool pinned;
  final TvDestination selected;
  final ValueChanged<TvDestination> onSelected;
  final VoidCallback onTogglePinned;

  /// Browsing, then your own places, then (at the foot) the app's.
  static const _browse = [
    TvDestination.home,
    TvDestination.movies,
    TvDestination.series,
    TvDestination.search,
  ];
  static const _yours = [TvDestination.library, TvDestination.together];
  static const _foot = [
    TvDestination.plugins,
    TvDestination.settings,
    TvDestination.profile,
  ];

  /// The mark, every destination, the dividers and the pin: below this
  /// height the rail scrolls rather than overflowing.
  static const fixedHeight =
      _brandHeight +
      _SidebarItem.extent * 9 +
      _Divider.extent * 2 +
      _PinToggle.extent;

  static const _brandHeight = 84.0;

  @override
  Widget build(BuildContext context) {
    assert(
      {..._browse, ..._yours, ..._foot}.length == TvDestination.values.length,
      'Every destination needs a place in the rail.',
    );
    final duration = desktopMotion(context, 200);
    Widget item(TvDestination destination) => _SidebarItem(
      destination: destination,
      selected: destination == selected,
      open: open,
      onTap: () => onSelected(destination),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The mark keeps its place, centred in the compact rail; the
        // wordmark fades in beside it.
        SizedBox(
          height: _brandHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: 18, right: 12),
            child: Row(
              children: [
                // In the accent colour, as phone Home's. Not read out: the
                // wordmark says it.
                ExcludeSemantics(
                  child: AccentAppIcon(
                    key: ValueKey(GlassTheme.accent.id),
                    size: 36,
                    radius: 10,
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
                            child: ReelishWordmark(height: 15),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // The same order for Tab and the arrow keys.
        for (final destination in _browse) item(destination),
        const _Divider(),
        for (final destination in _yours) item(destination),
        const Spacer(),
        const _Divider(),
        for (final destination in _foot) item(destination),
        _PinToggle(open: open, pinned: pinned, onTap: onTogglePinned),
      ],
    );
  }
}

/// A hairline between the rail's groups, inset to the items' edges.
class _Divider extends StatelessWidget {
  const _Divider();

  static const extent = 17.0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
    child: Divider(
      height: 1,
      color: GlassTheme.textPrimary.withValues(alpha: .08),
    ),
  );
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

  static const _height = 44.0;
  static const _gap = 3.0;

  /// The height one item takes in the rail, gaps included.
  static const extent = _height + _gap * 2;

  /// Centres the icon in the compact rail, so it never moves as the rail
  /// opens: the rail's width, less the item's margins and the icon.
  static const iconInset =
      (DesktopShell.collapsedWidth - _margin * 2 - _icon) / 2;
  static const _margin = 10.0;
  static const _icon = 22.0;

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
        ? GlassTheme.textPrimary
        : GlassTheme.textPrimary.withValues(alpha: .66);
    final icon = selected
        ? ReelishIcons.filled(widget.destination.icon)
        : widget.destination.icon;
    // The tooltip shows only while the labels are hidden. A hidden tooltip
    // drops its wrapper, so the item is keyed to keep its state and focus
    // as the rail opens and closes around it.
    return TooltipVisibility(
      visible: !widget.open,
      child: Tooltip(
        message: widget.destination.label,
        preferBelow: false,
        verticalOffset: 0,
        margin: const EdgeInsets.only(left: DesktopShell.collapsedExtent),
        child: Padding(
          key: _item,
          padding: const EdgeInsets.symmetric(
            horizontal: _SidebarItem._margin,
            vertical: _SidebarItem._gap,
          ),
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
                  height: _SidebarItem._height,
                  // Selected: a soft accent pill, a filled icon and a bolder
                  // label, so it never depends on colour alone. Hover is
                  // neutral, so it never reads as selected.
                  decoration: BoxDecoration(
                    color: selected
                        ? accent.withValues(alpha: _hovered ? .2 : .14)
                        : GlassTheme.textPrimary.withValues(
                            alpha: _hovered ? .06 : 0,
                          ),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  // The focus ring sits on top, so it never moves the icon.
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: _focused
                        ? Border.all(color: GlassTheme.coralBright, width: 2)
                        : null,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: _SidebarItem.iconInset),
                      SizedBox.square(
                        dimension: _SidebarItem._icon,
                        child: Center(child: _icon(icon, color, selected)),
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
                                  color: selected
                                      ? GlassTheme.textPrimary
                                      : color,
                                  fontSize: AppTextSize.body,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
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

  Widget _icon(IconData icon, Color color, bool selected) =>
      switch (widget.destination) {
        // Profile shows whose it is.
        TvDestination.profile => const SizedBox.square(
          dimension: _SidebarItem._icon,
          child: AvatarFrameRim(
            child: MyProfileAvatar(size: _SidebarItem._icon),
          ),
        ),
        // What is new with friends, on the icon so it shows with the rail
        // closed too.
        TvDestination.together => TogetherUpdates(
          builder: (context, count) => CountBadge(
            count: count,
            child: Icon(icon, size: _SidebarItem._icon, color: color),
          ),
        ),
        _ => Icon(icon, size: _SidebarItem._icon, color: color),
      };
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

  static const _height = 40.0;

  /// Its height in the rail, with the room under it.
  static const extent = 6 + _height + 14;

  @override
  Widget build(BuildContext context) {
    final label = pinned ? 'Collapse sidebar' : 'Keep sidebar open';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _SidebarItem._margin,
        6,
        _SidebarItem._margin,
        14,
      ),
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: SizedBox(
            height: _height,
            child: Row(
              children: [
                const SizedBox(width: _SidebarItem.iconInset),
                Icon(
                  pinned ? ReelishIcons.panelClose : ReelishIcons.panelOpen,
                  size: _SidebarItem._icon,
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
                          style: TextStyle(
                            color: GlassTheme.muted,
                            fontSize: AppTextSize.bodySmall,
                            fontWeight: FontWeight.w500,
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
