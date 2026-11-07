// The badges an account can carry. Each has its own emblem, colours and words,
// and shares only the pill they sit on. The colours stay the same whichever
// accent the viewer picked, so a badge means one thing everywhere.
import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/reelish_icons.dart';

/// An emblem drawn in its badge's gradient.
class _Emblem extends StatelessWidget {
  const _Emblem({
    required this.icon,
    required this.gradient,
    required this.size,
  });

  final IconData icon;
  final Gradient gradient;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: gradient.createShader,
      child: Icon(icon, size: size, color: Colors.white),
    ),
  );
}

/// The emblem and name on a quiet pill.
class _BadgePill extends StatelessWidget {
  const _BadgePill({
    required this.emblem,
    required this.label,
    required this.ink,
    required this.fill,
    required this.outline,
    required this.tv,
    this.letterSpacing,
  });

  final Widget emblem;
  final String label;
  final Color ink;
  final Color fill;
  final Color outline;
  final bool tv;
  final double? letterSpacing;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      border: Border.all(color: outline),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tv ? AppSpace.sm : AppSpace.xs + 2,
        vertical: tv ? AppSpace.xxs + 2 : AppSpace.xxs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          emblem,
          const SizedBox(width: AppSpace.xxs + 2),
          // A badge's name is never cut short: it shrinks to fit a narrow
          // card instead.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: ink,
                  fontSize: tv ? AppTextSize.body : AppTextSize.label,
                  fontWeight: FontWeight.w700,
                  letterSpacing: letterSpacing,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The Reelish crown, in violet.
class FounderEmblem extends StatelessWidget {
  const FounderEmblem({super.key, this.size = 20});

  final double size;

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE6DBFF), Color(0xFFB79CF7), Color(0xFF8460E8)],
  );

  @override
  Widget build(BuildContext context) =>
      _Emblem(icon: ReelishIcons.founder, gradient: gradient, size: size);
}

/// The identity of the person who created Reelish. It belongs to one account,
/// and grants no permission of any kind.
class FounderBadge extends StatelessWidget {
  const FounderBadge({super.key, this.tv = false});

  final bool tv;

  static const label = 'REELISH FOUNDER';
  static const title = 'Founder & Developer';
  static const description = 'The original creator and developer of Reelish.';

  /// The colour of [title] where it sits by the name.
  static const ink = Color(0xFFCDBBFF);

  @override
  Widget build(BuildContext context) => Tooltip(
    message: description,
    child: Semantics(
      label: '$title. $description',
      excludeSemantics: true,
      child: _BadgePill(
        emblem: FounderEmblem(size: tv ? 22 : 16),
        label: label,
        ink: ink,
        fill: const Color(0x1F9B7BEF),
        outline: const Color(0x599B7BEF),
        tv: tv,
        letterSpacing: .6,
      ),
    ),
  );
}

/// The Supporter emblem, in warm gold.
class SupporterEmblem extends StatelessWidget {
  const SupporterEmblem({super.key, this.size = 20});

  final double size;

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFE3A3), Color(0xFFF5B942), Color(0xFFC98A1B)],
  );

  @override
  Widget build(BuildContext context) =>
      _Emblem(icon: ReelishIcons.supporter, gradient: gradient, size: size);
}

/// One badge for everyone who supports Reelish.
class SupporterBadge extends StatelessWidget {
  const SupporterBadge({super.key, this.tv = false, this.onTap});

  final bool tv;
  final VoidCallback? onTap;

  static const label = 'Reelish Supporter';

  @override
  Widget build(BuildContext context) {
    final pill = _BadgePill(
      emblem: SupporterEmblem(size: tv ? 22 : 16),
      label: label,
      ink: const Color(0xFFFFD98A),
      fill: const Color(0x1FF5B942),
      outline: const Color(0x59F5B942),
      tv: tv,
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
