import 'package:flutter/material.dart';
import '../../models/stream_source.dart';
import '../../theme/glass_theme.dart';
import '../glass_box.dart';

class StreamSelectorSheet extends StatelessWidget {
  const StreamSelectorSheet({
    super.key,
    required this.streams,
    required this.selected,
    this.status,
  });
  final List<StreamSource> streams;
  final StreamSource selected;
  final String? status;
  static Future<StreamSource?> show(
    BuildContext context,
    List<StreamSource> streams,
    StreamSource selected, {
    String? status,
  }) => showModalBottomSheet<StreamSource>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => StreamSelectorSheet(
      streams: streams,
      selected: selected,
      status: status,
    ),
  );
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: GlassBox(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose stream',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            if (status?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(
                status!,
                style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in streams)
                    ListTile(
                      leading: Icon(
                        s.url == selected.url
                            ? Icons.radio_button_checked
                            : Icons.play_circle_outline,
                        color: s.url == selected.url ? GlassTheme.cyan : null,
                      ),
                      title: Text(s.name),
                      subtitle: Text(
                        '${s.providerName}${s.description.isEmpty ? '' : ' · ${s.description}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, s),
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
