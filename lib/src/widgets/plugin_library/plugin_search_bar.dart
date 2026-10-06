import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_theme.dart';

class PluginSearchBar extends StatelessWidget {
  const PluginSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    focusNode: focusNode,
    onChanged: onChanged,
    textInputAction: TextInputAction.search,
    autocorrect: false,
    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    decoration: InputDecoration(
      hintText: 'Search plugins, authors or sources…',
      hintStyle: const TextStyle(
        color: GlassTheme.muted,
        fontWeight: FontWeight.w500,
      ),
      prefixIcon: const Icon(Symbols.search_rounded, color: GlassTheme.muted),
      suffixIcon: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  key: const ValueKey('clear'),
                  tooltip: 'Clear search',
                  onPressed: onClear,
                  icon: const Icon(Symbols.close_rounded),
                ),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: GlassTheme.primary.withValues(alpha: .6)),
      ),
    ),
  );
}
