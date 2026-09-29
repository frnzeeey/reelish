import 'package:flutter/material.dart';
import '../theme/glass_theme.dart';

class CategoryChip extends StatelessWidget {
  const CategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: GlassTheme.primary,
      backgroundColor: GlassTheme.surface,
      side: BorderSide(
        color: selected ? GlassTheme.primary : GlassTheme.border,
      ),
      shape: const StadiumBorder(),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      labelStyle: TextStyle(
        color: selected ? GlassTheme.background : GlassTheme.muted,
        fontSize: 12,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
    ),
  );
}
