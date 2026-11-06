// A development screen showing every Reelish icon side by side, for checking
// the set after changing it. Its own entry point, so nothing in the app
// reaches it and release builds leave it out:
//
//   flutter run -d windows -t lib/icon_gallery.dart
import 'package:flutter/material.dart';

import 'src/theme/glass_theme.dart';
import 'src/theme/reelish_icons.dart';

void main() => runApp(const IconGalleryApp());

class IconGalleryApp extends StatelessWidget {
  const IconGalleryApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Reelish icons',
    debugShowCheckedModeBanner: false,
    theme: GlassTheme.dark,
    home: const IconGalleryScreen(),
  );
}

/// Every icon, with its name, at any size, on a dark or light surface, in
/// white or the accent, and with its solid form beside it.
class IconGalleryScreen extends StatefulWidget {
  const IconGalleryScreen({super.key});

  @override
  State<IconGalleryScreen> createState() => _IconGalleryScreenState();
}

class _IconGalleryScreenState extends State<IconGalleryScreen> {
  double _size = 32;
  bool _light = false;
  bool _accent = false;
  bool _solidOnly = false;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final names = ReelishIcons.all.keys.where((name) {
      if (_solidOnly && !name.endsWith('Filled')) return false;
      return name.toLowerCase().contains(_query.toLowerCase());
    }).toList();
    final surface = _light ? const Color(0xFFF4F4F6) : GlassTheme.background;
    final ink = _light ? const Color(0xFF16161C) : Colors.white;
    final color = _accent ? GlassTheme.primary : ink;
    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        title: Text('${names.length} of ${ReelishIcons.all.length} icons'),
        actions: [
          _Toggle('Light', _light, (on) => setState(() => _light = on)),
          _Toggle('Accent', _accent, (on) => setState(() => _accent = on)),
          _Toggle('Solid', _solidOnly, (on) => setState(() => _solidOnly = on)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    style: TextStyle(color: ink),
                    decoration: const InputDecoration(
                      hintText: 'Search names',
                      prefixIcon: Icon(ReelishIcons.search),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                const SizedBox(width: 16),
                Text('${_size.round()} px', style: TextStyle(color: ink)),
                SizedBox(
                  width: 220,
                  child: Slider(
                    value: _size,
                    min: 12,
                    max: 72,
                    divisions: 60,
                    onChanged: (value) => setState(() => _size = value),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _size + 88,
                mainAxisExtent: _size + 64,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: names.length,
              itemBuilder: (context, index) => _IconCell(
                name: names[index],
                size: _size,
                color: color,
                labelColor: ink.withValues(alpha: 0.65),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.label, this.value, this.onChanged);

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}

class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.name,
    required this.size,
    required this.color,
    required this.labelColor,
  });

  final String name;
  final double size;
  final Color color;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    final icon = ReelishIcons.all[name]!;
    final solid = ReelishIcons.filled(icon);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: size, color: color),
            if (solid != icon) ...[
              const SizedBox(width: 6),
              Icon(solid, size: size, color: color),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: labelColor, fontSize: 11),
        ),
      ],
    );
  }
}
