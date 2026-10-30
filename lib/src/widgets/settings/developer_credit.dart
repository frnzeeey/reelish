// The Settings screen's footer: the Reelish primary logo and who designed
// and developed the app, at the size of the TMDB attribution it replaces
// there. TMDB's attribution stays in Credits & attribution and under Home.

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../brand_logo.dart';

class DeveloperCreditFooter extends StatelessWidget {
  const DeveloperCreditFooter({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    // The same rhythm as TmdbAttributionFooter: rule, logo, caption text.
    padding: const EdgeInsets.only(top: 18),
    child: MergeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 36, height: 1, color: GlassTheme.border),
          const SizedBox(height: 16),
          // The logo beside the credit, as tall as its two lines; the pair
          // is centred under the rule.
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReelishPrimaryLogo(height: 32),
              SizedBox(width: AppSpace.sm),
              Flexible(child: _Credit()),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Credit extends StatelessWidget {
  const _Credit();

  @override
  Widget build(BuildContext context) => const Text.rich(
    TextSpan(
      text: 'Designed & Developed by\n',
      children: [
        TextSpan(
          text: 'HedgeByte',
          style: TextStyle(
            color: GlassTheme.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: ' · Software Engineer'),
      ],
    ),
    style: TextStyle(
      color: GlassTheme.muted,
      fontSize: AppTextSize.caption,
      height: 1.45,
    ),
  );
}
