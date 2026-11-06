import 'package:flutter/material.dart';
import '../../theme/reelish_icons.dart';

import '../../theme/design_tokens.dart';
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
    style: const TextStyle(
      fontSize: AppTextSize.body,
      fontWeight: FontWeight.w600,
    ),
    decoration: InputDecoration(
      hintText: 'Search plugins, authors or sources…',
      hintStyle: const TextStyle(
        color: GlassTheme.muted,
        fontWeight: FontWeight.w500,
      ),
      prefixIcon: const Icon(ReelishIcons.search, color: GlassTheme.muted),
      suffixIcon: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => AnimatedSwitcher(
          duration: AppMotion.resolve(context, AppMotion.hover),
          child: value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  key: const ValueKey('clear'),
                  tooltip: 'Clear search',
                  onPressed: onClear,
                  icon: const Icon(ReelishIcons.close),
                ),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide(color: GlassTheme.primary.withValues(alpha: .6)),
      ),
    ),
  );
}
