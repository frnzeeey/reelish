// The profile card's own look: a background, a colour and an animated accent,
// chosen in Profile > Profile card and seen only by the card's owner. It
// dresses that one card and nothing else: the app theme, the accent across the
// app, the player and other people's profiles never read it. Backgrounds are
// drawn in code (lib/src/widgets/profile_card_backdrop.dart), so there are no
// assets to download or cache. Essentials and Gradients are for everyone;
// Cinematic, the effects and a colour of one's own are the supporter perk
// SupporterPerk.profileStyles. Sovereign Edition is the Founder's own card
// (FounderPerk.founderProfileCard), which no donation unlocks. New backgrounds
// are new entries here; never rename an id, as the choice is saved by it.
import 'package:flutter/material.dart';

import 'glass_theme.dart';

/// The shelf a background sits on.
enum ProfileBackdropCollection {
  essentials('Essentials'),
  gradients('Gradients'),
  cinematic('Cinematic'),

  /// The Founder's own card. Shown only to the Founder: it cannot be
  /// unlocked, so it is never offered locked.
  sovereign('Sovereign Edition');

  const ProfileBackdropCollection(this.label);
  final String label;

  /// Cinematic backgrounds are a supporter perk; the rest are for everyone.
  bool get forSupporters => this == cinematic;

  /// The Founder Collection's card (FounderPerk.founderProfileCard).
  bool get forFounder => this == sovereign;
}

/// Sovereign Edition's Golden Wine: deep wine under champagne gold. Fixed in
/// every theme, like a badge's colours, so the card means one thing.
abstract final class SovereignColors {
  /// The card's base, the darkest colour: a warm near-black.
  static const charcoal = Color(0xFF171317);

  /// Between the base and the wine, so the blend never bands.
  static const ink = Color(0xFF2A1220);
  static const wine = Color(0xFF5A263B);
  static const royalWine = Color(0xFF722F45);
  static const champagne = Color(0xFFD4AF70);
  static const antique = Color(0xFFB89555);
  static const highlight = Color(0xFFE8D4A5);

  /// Champagne gold lit from the upper left, as the Sovereign Crest is.
  static const metal = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [highlight, champagne, antique, champagne],
    stops: [0, .4, .75, 1],
  );
}

/// How a background is drawn.
enum ProfilePattern {
  /// One colour, with a faint light from the top so it is not flat.
  solid,

  /// A diagonal blend of its colours.
  gradient,

  /// A stage spotlight falling from above.
  spotlight,

  /// Two neon glows in opposite corners.
  neon,

  /// A night sky with fixed stars.
  stars,

  /// Projector light in soft rays from the upper left.
  rays,

  /// A strip of film along the foot.
  film,

  /// Large soft blots of colour, like mist.
  mesh,

  /// Sovereign Edition: wine on charcoal, a champagne hairline frame and a
  /// faint engraved laurel seal.
  sovereign,
}

/// One profile card background. [colors] starts with the base, the darkest
/// colour; the card stays dark in every theme, so its text always reads.
@immutable
class ProfileBackdropStyle {
  const ProfileBackdropStyle({
    required this.id,
    required this.name,
    required this.description,
    required this.collection,
    required this.pattern,
    required this.colors,
  });

  /// Saved on the device; never rename one.
  final String id;
  final String name;
  final String description;
  final ProfileBackdropCollection collection;
  final ProfilePattern pattern;
  final List<Color> colors;

  Color get base => colors.first;
  bool get forSupporters => collection.forSupporters;
  bool get forFounder => collection.forFounder;

  static const all = <ProfileBackdropStyle>[
    ProfileBackdropStyle(
      id: 'graphite',
      name: 'Graphite',
      description: 'Quiet charcoal',
      collection: ProfileBackdropCollection.essentials,
      pattern: ProfilePattern.solid,
      colors: [Color(0xFF16161C), Color(0xFF24242C)],
    ),
    ProfileBackdropStyle(
      id: 'midnight',
      name: 'Midnight',
      description: 'Deep navy',
      collection: ProfileBackdropCollection.essentials,
      pattern: ProfilePattern.solid,
      colors: [Color(0xFF0E1322), Color(0xFF1A2440)],
    ),
    ProfileBackdropStyle(
      id: 'aubergine',
      name: 'Aubergine',
      description: 'Dark plum',
      collection: ProfileBackdropCollection.essentials,
      pattern: ProfilePattern.solid,
      colors: [Color(0xFF1A1220), Color(0xFF2C1E36)],
    ),
    ProfileBackdropStyle(
      id: 'pine',
      name: 'Pine',
      description: 'Evergreen night',
      collection: ProfileBackdropCollection.essentials,
      pattern: ProfilePattern.solid,
      colors: [Color(0xFF0E1A16), Color(0xFF1A2E27)],
    ),
    ProfileBackdropStyle(
      id: 'dusk',
      name: 'Dusk',
      description: 'Violet fading to night',
      collection: ProfileBackdropCollection.gradients,
      pattern: ProfilePattern.gradient,
      colors: [Color(0xFF0E0E14), Color(0xFF15111F), Color(0xFF2E1D44)],
    ),
    ProfileBackdropStyle(
      id: 'tide',
      name: 'Tide',
      description: 'Deep sea blue',
      collection: ProfileBackdropCollection.gradients,
      pattern: ProfilePattern.gradient,
      colors: [Color(0xFF0C0F14), Color(0xFF0D1822), Color(0xFF113040)],
    ),
    ProfileBackdropStyle(
      id: 'cinder',
      name: 'Cinder',
      description: 'Embers on charcoal',
      collection: ProfileBackdropCollection.gradients,
      pattern: ProfilePattern.gradient,
      colors: [Color(0xFF0F0E12), Color(0xFF1B1013), Color(0xFF3D1616)],
    ),
    ProfileBackdropStyle(
      id: 'moss',
      name: 'Moss',
      description: 'Forest after rain',
      collection: ProfileBackdropCollection.gradients,
      pattern: ProfilePattern.gradient,
      colors: [Color(0xFF0E100E), Color(0xFF121B13), Color(0xFF223019)],
    ),
    ProfileBackdropStyle(
      id: 'spotlight',
      name: 'Spotlight',
      description: 'A stage light from above',
      collection: ProfileBackdropCollection.cinematic,
      pattern: ProfilePattern.spotlight,
      colors: [Color(0xFF0C0C11), Color(0xFFF3E3C3)],
    ),
    ProfileBackdropStyle(
      id: 'neon_noir',
      name: 'Neon Noir',
      description: 'Magenta and cyan city light',
      collection: ProfileBackdropCollection.cinematic,
      pattern: ProfilePattern.neon,
      colors: [Color(0xFF0B0A12), Color(0xFFFF3DA5), Color(0xFF2EE6F0)],
    ),
    ProfileBackdropStyle(
      id: 'starlight',
      name: 'Starlight',
      description: 'A clear night sky',
      collection: ProfileBackdropCollection.cinematic,
      pattern: ProfilePattern.stars,
      colors: [Color(0xFF090D1A), Color(0xFF26335E)],
    ),
    ProfileBackdropStyle(
      id: 'projector',
      name: 'Projector',
      description: 'Light through the booth window',
      collection: ProfileBackdropCollection.cinematic,
      pattern: ProfilePattern.rays,
      colors: [Color(0xFF0E0D12), Color(0xFFFFE2A8)],
    ),
    ProfileBackdropStyle(
      id: 'film_reel',
      name: 'Film Reel',
      description: 'A strip of film in amber light',
      collection: ProfileBackdropCollection.cinematic,
      pattern: ProfilePattern.film,
      colors: [Color(0xFF111015), Color(0xFFE0A458)],
    ),
    ProfileBackdropStyle(
      id: 'northern_mist',
      name: 'Northern Mist',
      description: 'Teal and violet haze',
      collection: ProfileBackdropCollection.cinematic,
      pattern: ProfilePattern.mesh,
      colors: [
        Color(0xFF0A0E14),
        Color(0xFF1FC8A0),
        Color(0xFF7B5CFF),
        Color(0xFF2F6BFF),
      ],
    ),
    ProfileBackdropStyle(
      id: 'sovereign',
      name: 'Sovereign Edition',
      description: 'Golden laurel on deep wine',
      collection: ProfileBackdropCollection.sovereign,
      pattern: ProfilePattern.sovereign,
      colors: [
        SovereignColors.charcoal,
        SovereignColors.wine,
        SovereignColors.royalWine,
        SovereignColors.champagne,
      ],
    ),
  ];

  static ProfileBackdropStyle? byId(String? id) {
    for (final style in all) {
      if (style.id == id) return style;
    }
    return null;
  }
}

/// A gentle animation on the card. Supporter perk. It stays still under
/// reduced motion, on TV hardware, in the background, on a covered page and
/// when the card is scrolled away.
enum ProfileEffect {
  none('None', 'A still card'),
  drift('Drift', 'Soft lights wander slowly across the card'),
  sheen('Sheen', 'A light passes over the card now and then');

  const ProfileEffect(this.label, this.description);
  final String label;
  final String description;

  static ProfileEffect byName(Object? name) {
    for (final effect in values) {
      if (effect.name == name) return effect;
    }
    return none;
  }
}

/// The card's look as chosen: a background ([ProfileBackdropStyle.id]), a
/// colour ([AccentPalette.id]: a preset, or `custom:rrggbb`) and an effect.
/// Null parts keep the card as it has always been: the app theme's backdrop
/// (or Classic's accent glow) and the app's accent.
@immutable
class ProfileStyle {
  const ProfileStyle({
    this.backdrop,
    this.color,
    this.effect = ProfileEffect.none,
  });

  static const standard = ProfileStyle();

  final String? backdrop;
  final String? color;
  final ProfileEffect effect;

  ProfileBackdropStyle? get backdropStyle =>
      ProfileBackdropStyle.byId(backdrop);

  /// The chosen colour, or null to follow the theme and the app's accent.
  AccentPalette? get palette => AccentPalette.fromId(color);

  /// A colour of one's own rather than a preset: a supporter perk, whatever
  /// value it holds, so typing a colour never reaches past the presets.
  bool get hasCustomColor =>
      color?.startsWith(AccentPalette.customPrefix) ?? false;

  bool get isStandard =>
      backdrop == null && color == null && effect == ProfileEffect.none;

  /// Whether any part needs [SupporterPerk.profileStyles].
  bool get needsPerk =>
      (backdropStyle?.forSupporters ?? false) ||
      hasCustomColor ||
      effect != ProfileEffect.none;

  /// The Founder's Sovereign Edition card, which needs
  /// FounderPerk.founderProfileCard whatever else the account has.
  bool get needsFounderPerk => backdropStyle?.forFounder ?? false;

  /// What shows for an account with or without the perks: without [perk],
  /// the supporter parts fall back to the standard card and the free parts
  /// stay; without [founder], so does Sovereign Edition. [founder] defaults
  /// to false, so a caller that forgets it never shows the Founder's card.
  /// The saved choice is untouched, so it returns if the perk does.
  ProfileStyle allowed({required bool perk, bool founder = false}) {
    final style = backdropStyle;
    final showBackdrop =
        style != null &&
        (style.forFounder ? founder : !style.forSupporters || perk);
    return ProfileStyle(
      backdrop: showBackdrop ? backdrop : null,
      color: hasCustomColor && !perk ? null : color,
      effect: perk ? effect : ProfileEffect.none,
    );
  }

  ProfileStyle withBackdrop(String? id) =>
      ProfileStyle(backdrop: id, color: color, effect: effect);
  ProfileStyle withColor(String? id) =>
      ProfileStyle(backdrop: backdrop, color: id, effect: effect);
  ProfileStyle withEffect(ProfileEffect value) =>
      ProfileStyle(backdrop: backdrop, color: color, effect: value);

  /// Only what was chosen; null for the standard card.
  Map<String, Object?>? toJson() => isStandard
      ? null
      : {
          'backdrop': ?backdrop,
          'color': ?color,
          if (effect != ProfileEffect.none) 'effect': effect.name,
        };

  /// Read defensively: unknown ids, malformed colours and anything else
  /// unexpected are dropped, part by part, and never fail the profile.
  static ProfileStyle fromJson(Object? json) {
    if (json is! Map) return standard;
    final backdrop = json['backdrop'], color = json['color'];
    return ProfileStyle(
      backdrop:
          backdrop is String && ProfileBackdropStyle.byId(backdrop) != null
          ? backdrop
          : null,
      color: color is String && AccentPalette.fromId(color) != null
          ? color
          : null,
      effect: ProfileEffect.byName(json['effect']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileStyle &&
      other.backdrop == backdrop &&
      other.color == color &&
      other.effect == effect;

  @override
  int get hashCode => Object.hash(backdrop, color, effect);
}
