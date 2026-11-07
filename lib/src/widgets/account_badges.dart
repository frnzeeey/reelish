// The badges an account can carry, as identity capsules. Every capsule shares
// one geometry (CapsuleMetrics): height, padding, emblem size and type. Each
// badge has its own emblem, colours and finish, so Founder and Supporter are
// told apart by more than their words. The colours stay the same whichever
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

/// The geometry every identity capsule shares, so badges line up beside a
/// name and with each other on every interface.
abstract final class CapsuleMetrics {
  static double height(bool tv) => tv ? 34 : 26;
  static double emblem(bool tv) => tv ? 18 : 14;
  static double text(bool tv) => tv ? AppTextSize.body : AppTextSize.label;
  static double padding(bool tv) => tv ? AppSpace.md : 10;
  static const gap = 6.0;
}

/// An emblem and a name in a fully rounded capsule. [fill] is a gradient so a
/// badge can carry a finish of its own; [onTap] makes the whole capsule a
/// button, with a focus ring for the remote and keyboard.
class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.emblem,
    required this.label,
    required this.ink,
    required this.fill,
    required this.outline,
    required this.tv,
    required this.semantics,
    this.onTap,
  });

  final Widget emblem;
  final String label;
  final Color ink;
  final Gradient fill;
  final Color outline;
  final bool tv;
  final String semantics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final shape = StadiumBorder(side: BorderSide(color: outline));
    final body = SizedBox(
      height: CapsuleMetrics.height(tv),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: CapsuleMetrics.padding(tv)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            emblem,
            const SizedBox(width: CapsuleMetrics.gap),
            // A badge's name is never cut short: it shrinks to fit instead.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: ink,
                    fontSize: CapsuleMetrics.text(tv),
                    fontWeight: FontWeight.w700,
                    letterSpacing: .2,
                    height: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: semantics,
      button: onTap != null,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: ShapeDecoration(gradient: fill, shape: shape),
          child: onTap == null
              ? body
              : InkWell(
                  onTap: onTap,
                  customBorder: const StadiumBorder(),
                  focusColor: ink.withValues(alpha: .18),
                  hoverColor: ink.withValues(alpha: .08),
                  child: body,
                ),
        ),
      ),
    );
  }
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
  const FounderBadge({super.key, this.tv = false, this.onTap});

  final bool tv;
  final VoidCallback? onTap;

  static const label = 'REELISH FOUNDER';
  static const title = 'Founder & Developer';
  static const description = 'The original creator and developer of Reelish.';

  /// The colour of [title] where it sits by the name.
  static const ink = Color(0xFFCDBBFF);

  @override
  Widget build(BuildContext context) => Tooltip(
    message: description,
    child: _Capsule(
      emblem: FounderEmblem(size: CapsuleMetrics.emblem(tv) + 2),
      label: title,
      ink: const Color(0xFFE6DCFF),
      // Deep violet into a lighter one: the Founder's finish, which no other
      // badge has.
      fill: const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Color(0x528460E8), Color(0x249B7BEF)],
      ),
      outline: const Color(0x80B79CF7),
      tv: tv,
      semantics: '$title. $description',
      onTap: onTap,
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
  const SupporterBadge({
    super.key,
    this.tv = false,
    this.onTap,
    this.short = false,
  });

  final bool tv;
  final VoidCallback? onTap;

  /// "Supporter" rather than "Reelish Supporter", beside a name.
  final bool short;

  static const label = 'Reelish Supporter';
  static const shortLabel = 'Supporter';

  @override
  Widget build(BuildContext context) => _Capsule(
    emblem: SupporterEmblem(size: CapsuleMetrics.emblem(tv) + 2),
    label: short ? shortLabel : label,
    ink: const Color(0xFFFFDC92),
    // A flat warm tint: plainer than the Founder's finish, on purpose.
    fill: const LinearGradient(colors: [Color(0x26F5B942), Color(0x26F5B942)]),
    outline: const Color(0x66F5B942),
    tv: tv,
    semantics: label,
    onTap: onTap,
  );
}
