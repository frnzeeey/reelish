// The Reelish Supporter Badge: one emblem for everyone who supports Reelish.
import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/reelish_icons.dart';

/// The emblem, in a warm metallic gradient that stays the same whichever
/// accent colour the viewer picked, so the badge means one thing everywhere.
class SupporterEmblem extends StatelessWidget {
  const SupporterEmblem({super.key, this.size = 20});

  final double size;

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFE3A3), Color(0xFFF5B942), Color(0xFFC98A1B)],
  );

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: gradient.createShader,
      child: Icon(ReelishIcons.supporter, size: size, color: Colors.white),
    ),
  );
}

/// The emblem with its name, on a quiet pill.
class SupporterBadge extends StatelessWidget {
  const SupporterBadge({super.key, this.tv = false, this.onTap});

  final bool tv;
  final VoidCallback? onTap;

  static const label = 'Reelish Supporter';

  @override
  Widget build(BuildContext context) {
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x1FF5B942),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: const Color(0x59F5B942)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tv ? AppSpace.sm : AppSpace.xs + 2,
          vertical: tv ? AppSpace.xxs + 2 : AppSpace.xxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SupporterEmblem(size: tv ? 22 : 16),
            const SizedBox(width: AppSpace.xxs + 2),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFFFFD98A),
                  fontSize: tv ? AppTextSize.body : AppTextSize.label,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: label,
      button: onTap != null,
      excludeSemantics: true,
      child: onTap == null
          ? pill
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: pill,
            ),
    );
  }
}
