import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_theme.dart';
import '../../widgets/tv/tv_focus.dart';

/// The places on the TV navigation rail.
enum TvDestination {
  home('Home', Symbols.home_rounded),
  movies('Movies', Symbols.movie_rounded),
  series('Series', Symbols.live_tv_rounded),
  search('Search', Symbols.search_rounded),
  library('My library', Symbols.bookmark_rounded),
  plugins('Plugins', Symbols.extension_rounded),
  settings('Settings', Symbols.settings_rounded);

  const TvDestination(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The TV interface's frame: a navigation rail on the left and the selected
/// page beside it. Moving through the rail switches pages as it goes.
///
/// Focus:
/// * Each page keeps its own focus scope, so leaving a page and coming back
///   (Right from the rail) returns to whatever was focused there last.
/// * Left from a page's leftmost control moves to the rail, which widens to
///   show its labels while it has focus.
/// * Back moves from a page to the rail, then from the rail to Home, then
///   leaves the app.
///
/// Pages are built the first time they are visited and kept afterwards;
/// pages out of view are offstage, unfocusable and run no animations.
class TvHomeShell extends StatefulWidget {
  const TvHomeShell({
    super.key,
    required this.destination,
    required this.onDestinationChanged,
    required this.pageBuilder,
  });

  final TvDestination destination;
  final ValueChanged<TvDestination> onDestinationChanged;
  final Widget Function(BuildContext context, TvDestination destination)
  pageBuilder;

  @override
  State<TvHomeShell> createState() => TvHomeShellState();
}

class TvHomeShellState extends State<TvHomeShell> {
  static const collapsedRailWidth = 84.0;
  static const expandedRailWidth = 240.0;

  final _railScope = FocusScopeNode(debugLabel: 'TV rail');
  late final Map<TvDestination, FocusNode> _railNodes = {
    for (final destination in TvDestination.values)
      destination: FocusNode(debugLabel: 'Rail ${destination.label}'),
  };
  late final Map<TvDestination, FocusScopeNode> _pageScopes = {
    for (final destination in TvDestination.values)
      destination: FocusScopeNode(debugLabel: 'TV ${destination.label}'),
  };
  late final Set<TvDestination> _visited = {widget.destination};

  /// Whether the rail has focus, which widens it. Only the rail rebuilds.
  final _railFocused = ValueNotifier(false);

  @override
  void didUpdateWidget(covariant TvHomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.destination);
    // Opened from elsewhere than the rail (such as a notice's action): the
    // page that had focus is now hidden, so focus follows to the new one.
    if (widget.destination != oldWidget.destination && !_railScope.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_railScope.hasFocus) focusPage();
      });
    }
  }

  @override
  void dispose() {
    _railScope.dispose();
    _railFocused.dispose();
    for (final node in _railNodes.values) {
      node.dispose();
    }
    for (final scope in _pageScopes.values) {
      scope.dispose();
    }
    super.dispose();
  }

  /// Focuses the rail on the selected page's entry.
  void focusRail() => _railNodes[widget.destination]!.requestFocus();

  /// Focuses the selected page where it was last focused, or its first
  /// control the first time.
  void focusPage() {
    final scope = _pageScopes[widget.destination]!;
    final remembered = scope.focusedChild;
    if (remembered != null &&
        remembered.context != null &&
        remembered.canRequestFocus) {
      remembered.requestFocus();
      return;
    }
    final first = scope.traversalDescendants.firstOrNull;
    if (first != null) {
      first.requestFocus();
    } else {
      scope.requestFocus();
    }
  }

  /// Opens [destination] and focuses its page.
  void show(TvDestination destination) {
    if (destination != widget.destination) {
      widget.onDestinationChanged(destination);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focusPage();
    });
  }

  void _onBack() {
    if (!_railScope.hasFocus) {
      focusRail();
    } else if (widget.destination != TvDestination.home) {
      widget.onDestinationChanged(TvDestination.home);
      _railNodes[TvDestination.home]!.requestFocus();
    } else {
      SystemNavigator.pop();
    }
  }

  static bool _isMove(KeyEvent event, LogicalKeyboardKey key) =>
      event is! KeyUpEvent && event.logicalKey == key;

  /// Left past a page's leftmost control goes to the rail.
  KeyEventResult _onPageKey(FocusNode node, KeyEvent event) {
    if (!_isMove(event, LogicalKeyboardKey.arrowLeft)) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus;
    // Text editing keeps Left for its caret.
    if (focused == null ||
        focused.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      return KeyEventResult.ignored;
    }
    if (!focused.focusInDirection(TraversalDirection.left)) focusRail();
    return KeyEventResult.handled;
  }

  /// Right from the rail enters the page.
  KeyEventResult _onRailKey(FocusNode node, KeyEvent event) {
    if (!_isMove(event, LogicalKeyboardKey.arrowRight)) {
      return KeyEventResult.ignored;
    }
    focusPage();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _onBack();
    },
    child: Scaffold(
      backgroundColor: GlassTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            left: collapsedRailWidth,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onPageKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final destination in TvDestination.values)
                    if (_visited.contains(destination))
                      _TvPage(
                        key: ValueKey(destination),
                        active: destination == widget.destination,
                        scope: _pageScopes[destination]!,
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
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onRailKey,
              onFocusChange: (focused) => _railFocused.value = focused,
              child: FocusScope(
                node: _railScope,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _railFocused,
                  builder: (context, expanded, _) => _TvNavigationRail(
                    expanded: expanded,
                    selected: widget.destination,
                    nodes: _railNodes,
                    onFocused: (destination) {
                      if (destination != widget.destination) {
                        widget.onDestinationChanged(destination);
                      }
                    },
                    onSelected: show,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TvPage extends StatelessWidget {
  const _TvPage({
    super.key,
    required this.active,
    required this.scope,
    required this.child,
  });

  final bool active;
  final FocusScopeNode scope;
  final Widget child;

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !active,
    child: TickerMode(
      enabled: active,
      child: ExcludeFocus(
        excluding: !active,
        child: FocusScope(node: scope, child: child),
      ),
    ),
  );
}

class _TvNavigationRail extends StatelessWidget {
  const _TvNavigationRail({
    required this.expanded,
    required this.selected,
    required this.nodes,
    required this.onFocused,
    required this.onSelected,
  });

  final bool expanded;
  final TvDestination selected;
  final Map<TvDestination, FocusNode> nodes;
  final ValueChanged<TvDestination> onFocused;
  final ValueChanged<TvDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      width: expanded
          ? TvHomeShellState.expandedRailWidth
          : TvHomeShellState.collapsedRailWidth,
      // Expanded, the rail lays a painted shade over the page instead of
      // pushing it aside, so the page never relayouts.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: expanded
              ? const [
                  GlassTheme.background,
                  Color(0xF00B0B0F),
                  Color(0xC00B0B0F),
                ]
              : const [Color(0xFF0E0E13), Color(0xFF0E0E13), Color(0xFF0E0E13)],
          stops: const [0, .7, 1],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, TvSafeArea.vertical, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 28),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/icons/reelish_icon.png',
                width: 40,
                height: 40,
                cacheWidth: (40 * MediaQuery.devicePixelRatioOf(context))
                    .round(),
              ),
            ),
          ),
          for (final destination in TvDestination.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _RailItem(
                destination: destination,
                focusNode: nodes[destination]!,
                selected: destination == selected,
                expanded: expanded,
                onFocused: () => onFocused(destination),
                onSelected: () => onSelected(destination),
              ),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.destination,
    required this.focusNode,
    required this.selected,
    required this.expanded,
    required this.onFocused,
    required this.onSelected,
  });

  final TvDestination destination;
  final FocusNode focusNode;
  final bool selected;
  final bool expanded;
  final VoidCallback onFocused;
  final VoidCallback onSelected;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.primary;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : tvFocusDuration;
    final color = _focused
        ? GlassTheme.background
        : widget.selected
        ? accent
        : Colors.white70;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.destination.label,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          if (focused) widget.onFocused();
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelected();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onSelected,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _focused
                  ? accent
                  : widget.selected
                  ? accent.withValues(alpha: .14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  widget.destination.icon,
                  fill: widget.selected || _focused ? 1 : 0,
                  color: color,
                  size: 24,
                ),
                // Labels show only while the rail is open.
                Flexible(
                  child: AnimatedOpacity(
                    duration: duration,
                    opacity: widget.expanded ? 1 : 0,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        widget.destination.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: TextStyle(
                          color: color,
                          fontSize: 15,
                          fontWeight: widget.selected || _focused
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
    );
  }
}
