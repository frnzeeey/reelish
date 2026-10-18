import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../navigation/app_destination.dart';
import '../theme/glass_theme.dart';
import 'desktop_widgets.dart';

/// The Windows interface's frame: the Android TV-style sidebar on the left,
/// refined for a mouse and keyboard, and the selected page beside it.
///
/// * The sidebar is either compact (icons, with tooltips) or expanded
///   (icons and labels); the toggle at its foot switches, and the choice is
///   remembered.
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

  static const collapsedWidth = 84.0;
  static const expandedWidth = 236.0;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  static const _expandedKey = 'reelish.desktop.sidebarExpanded';

  bool _expanded = true;
  final Set<TvDestination> _visited = {};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.destination);
    SharedPreferences.getInstance().then((preferences) {
      final saved = preferences.getBool(_expandedKey);
      if (saved != null && mounted) setState(() => _expanded = saved);
    });
  }

  @override
  void didUpdateWidget(covariant DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.destination);
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    SharedPreferences.getInstance().then(
      (preferences) => preferences.setBool(_expandedKey, _expanded),
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
      autofocus: true,
      skipTraversal: true,
      child: Scaffold(
        backgroundColor: GlassTheme.background,
        body: Row(
          children: [
            _Sidebar(
              expanded: _expanded,
              selected: widget.destination,
              onSelected: widget.onDestinationChanged,
              onToggle: _toggle,
            ),
            Expanded(
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
  Widget build(BuildContext context) => Offstage(
    offstage: !active,
    child: TickerMode(
      enabled: active,
      child: ExcludeFocus(excluding: !active, child: child),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.expanded,
    required this.selected,
    required this.onSelected,
    required this.onToggle,
  });

  final bool expanded;
  final TvDestination selected;
  final ValueChanged<TvDestination> onSelected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final duration = desktopMotion(context, 200);
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      width: expanded
          ? DesktopShell.expandedWidth
          : DesktopShell.collapsedWidth,
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F15),
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: .06)),
        ),
      ),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 26, 12, 30),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.asset(
                      'assets/icons/reelish_icon.png',
                      width: 40,
                      height: 40,
                      cacheWidth: (40 * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                    ),
                  ),
                  Flexible(
                    child: AnimatedOpacity(
                      duration: duration,
                      opacity: expanded ? 1 : 0,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: 'reel'),
                              TextSpan(
                                text: 'ish',
                                style: TextStyle(color: Color(0xFFFF7889)),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final destination in TvDestination.values)
              _SidebarItem(
                destination: destination,
                selected: destination == selected,
                expanded: expanded,
                onTap: () => onSelected(destination),
              ),
            const Spacer(),
            _SidebarToggle(expanded: expanded, onTap: onToggle),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  final TvDestination destination;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
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
    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
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
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              height: 46,
              decoration: BoxDecoration(
                color: selected
                    ? accent.withValues(alpha: _hovered ? .22 : .16)
                    : _hovered
                    ? Colors.white.withValues(alpha: .07)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _focused ? GlassTheme.coralBright : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  // The active page's accent bar.
                  AnimatedContainer(
                    duration: duration,
                    width: 3,
                    height: selected ? 20 : 0,
                    margin: const EdgeInsets.only(left: 4, right: 9),
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
                  Flexible(
                    child: AnimatedOpacity(
                      duration: duration,
                      opacity: widget.expanded ? 1 : 0,
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
    );
    return widget.expanded
        ? item
        : Tooltip(
            message: widget.destination.label,
            preferBelow: false,
            verticalOffset: 0,
            margin: const EdgeInsets.only(left: DesktopShell.collapsedWidth),
            child: item,
          );
  }
}

class _SidebarToggle extends StatelessWidget {
  const _SidebarToggle({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: Tooltip(
      message: expanded ? 'Collapse sidebar' : 'Expand sidebar',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          height: 42,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Icon(
                expanded
                    ? Symbols.left_panel_close_rounded
                    : Symbols.left_panel_open_rounded,
                size: 22,
                color: GlassTheme.muted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
