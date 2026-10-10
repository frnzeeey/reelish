import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../platform/device_capabilities.dart';
import '../../theme/glass_theme.dart';

/// Shared timing for TV focus motion: quick enough to follow a held D-pad.
const tvFocusDuration = Duration(milliseconds: 160);

/// Space kept clear along the edges of a TV screen. Many TVs overscan, and
/// Android TV design guidance keeps content inside about 5% of each edge.
abstract final class TvSafeArea {
  static const horizontal = 48.0;
  static const vertical = 27.0;
}

/// A remote-friendly target: Select (D-pad center, Enter) or a tap activates
/// it, and focus shows as a slight scale-up, a coral ring and a soft glow.
///
/// With [scrollAlignment] set, gaining focus scrolls every enclosing
/// [Scrollable] so the target sits at that alignment (0 = start edge), which
/// keeps the focused card in a stable position as the D-pad moves through a
/// row. Only the focused target paints its glow, so a row costs no more to
/// draw than its posters.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    required this.onSelect,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.borderRadius = 14,
    this.focusScale = 1.06,
    this.scrollAlignment,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onSelect;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final double borderRadius;
  final double focusScale;
  final double? scrollAlignment;
  final String? semanticLabel;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (_focused != focused) setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
    final alignment = widget.scrollAlignment;
    if (focused && alignment != null) {
      Scrollable.ensureVisible(
        context,
        alignment: alignment,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : tvFocusDuration;
    final onSelect = widget.onSelect;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _onFocusChange,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onSelect?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: onSelect,
          child: AnimatedScale(
            scale: _focused ? widget.focusScale : 1,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: _focused
                    ? [
                        BoxShadow(
                          color: GlassTheme.primary.withValues(alpha: .42),
                          blurRadius: 22,
                          spreadRadius: 1,
                        ),
                      ]
                    : const [],
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: _focused ? GlassTheme.coralBright : Colors.transparent,
                  width: 3,
                ),
              ),
              child: ClipRRect(borderRadius: radius, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gives every dialog and sheet a focused control as it opens on TV. A
/// remote has no pointer, so a dialog with nothing focused shows no cursor
/// at all. The first control in reading order is chosen, which in Material
/// dialogs is the leftmost action (Cancel, Later, Not now), so Select never
/// confirms something by accident. Routes that focus a control themselves
/// (autofocus, a dropdown menu's selected item) are left alone.
class TvPopupFocusObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _focusFirst(route, attempts: 3);
  }

  void _focusFirst(PopupRoute<dynamic> route, {required int attempts}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!route.isActive) return;
      final context = route.subtreeContext;
      final scope = context == null
          ? null
          : Focus.maybeOf(
              context,
              scopeOk: true,
              createDependency: false,
            )?.nearestScope;
      if (context == null || scope == null) {
        // Not built yet: try again on the next frame.
        if (attempts > 1) _focusFirst(route, attempts: attempts - 1);
        return;
      }
      // Autofocus is applied in a microtask after the frame; checking in a
      // later microtask leaves a route's own autofocus in place.
      scheduleMicrotask(() {
        if (!route.isActive || scope.focusedChild != null) return;
        final primary = FocusManager.instance.primaryFocus;
        if (primary != null && primary.ancestors.contains(scope)) return;
        if (!context.mounted) return;
        final first = FocusTraversalGroup.maybeOf(
          context,
        )?.findFirstFocus(scope);
        if (first != null && first != scope) first.requestFocus();
      });
    });
  }
}

/// Keeps a phone-sized screen readable on a TV: centered, no wider than
/// [maxWidth]. A pass-through on phones and tablets.
class TvReadableWidth extends StatelessWidget {
  const TvReadableWidth({super.key, required this.child, this.maxWidth = 820});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!DeviceCapabilities.isTv) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Gives a slider remote-friendly keys on TV: Left/Right change its value
/// and Up/Down move focus on. (Flutter's default lets Up/Down change a
/// slider too, which would trap the remote on it.) A pass-through elsewhere.
///
/// This is applied per slider rather than app-wide: app-wide directional
/// navigation also makes disabled controls focusable, and Material draws no
/// focus on a disabled control, so focus would vanish onto it.
class TvSliderNavigation extends StatelessWidget {
  const TvSliderNavigation({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DeviceCapabilities.isTv) return child;
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(navigationMode: NavigationMode.directional),
      child: child,
    );
  }
}

/// Lets the D-pad read content that has nothing to focus, such as a long
/// document: Up and Down move focus as usual when there is somewhere to go,
/// and otherwise scroll by most of a screen. A pass-through off TV.
class TvKeyScroll extends StatefulWidget {
  const TvKeyScroll({super.key, this.controller, required this.builder});

  /// The scroll view's controller; one is created on TV when null.
  final ScrollController? controller;
  final Widget Function(BuildContext context, ScrollController? controller)
  builder;

  @override
  State<TvKeyScroll> createState() => _TvKeyScrollState();
}

class _TvKeyScrollState extends State<TvKeyScroll> {
  ScrollController? _own;

  ScrollController get _controller =>
      widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null &&
        focused.focusInDirection(
          down ? TraversalDirection.down : TraversalDirection.up,
        )) {
      return KeyEventResult.handled;
    }
    final controller = _controller;
    if (!controller.hasClients) return KeyEventResult.ignored;
    final position = controller.position;
    final target =
        (position.pixels + (down ? 1 : -1) * position.viewportDimension * .7)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return KeyEventResult.ignored;
    controller.animateTo(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceCapabilities.isTv) {
      return widget.builder(context, widget.controller);
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: widget.builder(context, _controller),
    );
  }
}

/// A text field for the remote. Focusing it with the D-pad does not open the
/// keyboard (which would pop up whenever focus passed over it, and leave the
/// D-pad moving a caret it cannot leave). Select opens [TvTextEntryDialog],
/// where the system TV keyboard edits the text; closing it returns focus
/// here.
class TvTextField extends StatelessWidget {
  const TvTextField({
    super.key,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.onSubmitted,
    this.icon = Symbols.edit_rounded,
    this.title,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.done,
    this.focusNode,
    this.autofocus = false,
  });

  final String value;
  final String hint;

  /// Called on every edit, for live search; [onSubmitted] when the keyboard's
  /// action key is pressed.
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final IconData icon;

  /// Heading of the entry dialog; defaults to [hint].
  final String? title;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final FocusNode? focusNode;
  final bool autofocus;

  Future<void> _edit(BuildContext context) async {
    final result = await TvTextEntryDialog.show(
      context,
      title: title ?? hint,
      initialValue: value,
      hint: hint,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
    );
    if (result != null) onSubmitted?.call(result);
  }

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    autofocus: autofocus,
    focusScale: 1.02,
    borderRadius: 16,
    semanticLabel: value.isEmpty ? hint : '$hint: $value',
    onSelect: () => _edit(context),
    child: Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      color: GlassTheme.surface,
      child: Row(
        children: [
          Icon(icon, color: GlassTheme.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              value.isEmpty ? hint : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                color: value.isEmpty
                    ? GlassTheme.muted
                    : GlassTheme.textPrimary,
                fontWeight: value.isEmpty ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Icon(Symbols.keyboard_rounded, color: GlassTheme.muted),
        ],
      ),
    ),
  );
}

/// Text entry for TV: a dialog whose field opens the system keyboard as soon
/// as it appears. Returns the text when the keyboard's action key or Done is
/// pressed, or null on Cancel or Back.
///
/// Once the keyboard is dismissed, Up and Down leave the field for the
/// dialog's buttons; a text field would otherwise keep them as caret moves,
/// leaving the remote with no way out.
class TvTextEntryDialog extends StatefulWidget {
  const TvTextEntryDialog({
    super.key,
    required this.title,
    required this.initialValue,
    required this.hint,
    required this.keyboardType,
    required this.textInputAction,
    this.onChanged,
  });

  final String title;
  final String initialValue;
  final String hint;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    String initialValue = '',
    String hint = '',
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.done,
    ValueChanged<String>? onChanged,
  }) => showDialog<String>(
    context: context,
    builder: (_) => TvTextEntryDialog(
      title: title,
      initialValue: initialValue,
      hint: hint,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
    ),
  );

  @override
  State<TvTextEntryDialog> createState() => _TvTextEntryDialogState();
}

class _TvTextEntryDialogState extends State<TvTextEntryDialog> {
  late final _controller = TextEditingController(text: widget.initialValue)
    ..selection = TextSelection.collapsed(offset: widget.initialValue.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  KeyEventResult _leaveField(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      (FocusManager.instance.primaryFocus ?? node).focusInDirection(
        TraversalDirection.down,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      (FocusManager.instance.primaryFocus ?? node).focusInDirection(
        TraversalDirection.up,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: GlassTheme.elevatedSurface,
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _leaveField,
        child: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          autocorrect: widget.keyboardType != TextInputType.url,
          decoration: InputDecoration(hintText: widget.hint),
          onChanged: widget.onChanged,
          onSubmitted: (_) => _submit(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Done')),
    ],
  );
}
