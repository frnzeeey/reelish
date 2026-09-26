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
      selectedColor: GlassTheme.cyan,
      backgroundColor: const Color(0xFF141A25),
      side: BorderSide(color: selected ? GlassTheme.cyan : GlassTheme.border),
      shape: const StadiumBorder(),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      labelStyle: TextStyle(
        color: selected ? const Color(0xFF07110F) : Colors.white70,
        fontSize: 12,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
    ),
  );
}
