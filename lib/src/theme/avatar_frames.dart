// The avatar frame collection: how each frame looks, by the stable id the
// Reelish API stores (backend/src/frames.ts lists the same ids and decides who
// may wear which). Frames are drawn in code (lib/src/widgets/avatar_frame.dart),
// so they are crisp at any size and need no image assets. New frames are new
// entries here and in frames.ts; never rename an id.
import 'package:flutter/material.dart';

/// The shelf a frame sits on in the collection.
enum FrameCollection {
  elegant('Elegant'),
  cinematic('Cinematic'),
  special('Special Edition');

  const FrameCollection(this.label);
  final String label;
}

/// What a frame draws beyond its ring, once.
enum FrameOrnament {
  none,

  /// A scatter of small stars round the ring.
  stars,

  /// A fine gold inner line and a gold diamond at the top.
  crownJewel,

  /// A bright crescent of light along the upper right, like a corona.
  corona,

  /// Soft points of light drifting round the ring.
  particles,

  /// A curved highlight across the upper left, like light on black glass.
  glass,

  /// The Supporter star on a small dark disc at the top.
  supporterStar,

  /// Film sprockets round the ring.
  filmStrip,

  /// Two laurel branches rising to a crown on top: the Founder's.
  laurel,
}

/// How a frame moves, if at all. Most frames are still.
enum FrameMotion {
  none,

  /// One glint of reflected light travels the ring.
  glint,

  /// The ring's colours turn slowly round it.
  turn,

  /// Light sweeps across the laurel and crown from the upper left, a sparkle
  /// flares on the crown, then a long rest while a violet undertone
  /// breathes: the Sovereign frame's.
  sheen,
}

@immutable
class AvatarFrameStyle {
  const AvatarFrameStyle({
    required this.id,
    required this.name,
    required this.description,
    required this.collection,
    required this.colors,
    this.ornament = FrameOrnament.none,
    this.motion = FrameMotion.none,
    this.accent,
    this.founderOnly = false,
    this.limitedUntil,
  });

  /// Stored by the Reelish API; never rename one.
  final String id;
  final String name;
  final String description;
  final FrameCollection collection;

  /// The ring's colours, swept round it from three o'clock.
  final List<Color> colors;
  final FrameOrnament ornament;
  final FrameMotion motion;

  /// The ornament's colour, where it has its own.
  final Color? accent;

  /// The Founder's alone; shown to nobody else.
  final bool founderOnly;

  /// A limited edition: the last day it can be collected (UTC). Shown only;
  /// the server decides, and its window is in frames.ts.
  final DateTime? limitedUntil;

  bool get limited => limitedUntil != null;

  /// The colour that stands for the frame where only a fine rim fits.
  Color get rim => colors[colors.length ~/ 2];

  static const aurora = AvatarFrameStyle(
    id: 'aurora',
    name: 'Aurora',
    description: 'Northern lights turning slowly round you',
    collection: FrameCollection.elegant,
    colors: [
      Color(0xFF54D6C0),
      Color(0xFF34D399),
      Color(0xFF67E8F9),
      Color(0xFFA78BFA),
      Color(0xFF54D6C0),
    ],
    motion: FrameMotion.turn,
  );

  static const celestial = AvatarFrameStyle(
    id: 'celestial',
    name: 'Celestial',
    description: 'Midnight blue, scattered with stars',
    collection: FrameCollection.elegant,
    colors: [
      Color(0xFF1E3A5F),
      Color(0xFF3B5B8C),
      Color(0xFF8CCBFF),
      Color(0xFF3B5B8C),
      Color(0xFF1E3A5F),
    ],
    ornament: FrameOrnament.stars,
    accent: Color(0xFFE0F2FE),
  );

  static const royal = AvatarFrameStyle(
    id: 'royal',
    name: 'Royal',
    description: 'Deep violet, set with a gold jewel',
    collection: FrameCollection.elegant,
    colors: [
      Color(0xFF5B21B6),
      Color(0xFF7C3AED),
      Color(0xFFA78BFA),
      Color(0xFF7C3AED),
      Color(0xFF5B21B6),
    ],
    ornament: FrameOrnament.crownJewel,
    accent: Color(0xFFE9C46A),
  );

  static const roseGold = AvatarFrameStyle(
    id: 'rose_gold',
    name: 'Rose Gold',
    description: 'Polished rose gold, catching the light',
    collection: FrameCollection.elegant,
    colors: [
      Color(0xFFF7D5CB),
      Color(0xFFE8A598),
      Color(0xFFB76E79),
      Color(0xFFE8A598),
      Color(0xFFF7D5CB),
    ],
    motion: FrameMotion.glint,
  );

  static const eclipse = AvatarFrameStyle(
    id: 'eclipse',
    name: 'Eclipse',
    description: 'Dark metal with a corona of light',
    collection: FrameCollection.cinematic,
    colors: [
      Color(0xFF1A1A22),
      Color(0xFF3A3A48),
      Color(0xFF0E0E14),
      Color(0xFF3A3A48),
      Color(0xFF1A1A22),
    ],
    ornament: FrameOrnament.corona,
    accent: Color(0xFFFFF4DC),
  );

  static const nebula = AvatarFrameStyle(
    id: 'nebula',
    name: 'Nebula',
    description: 'A cosmic swirl with drifting light',
    collection: FrameCollection.cinematic,
    colors: [
      Color(0xFF7C3AED),
      Color(0xFFEC4899),
      Color(0xFF3B82F6),
      Color(0xFF8B5CF6),
      Color(0xFF7C3AED),
    ],
    ornament: FrameOrnament.particles,
    motion: FrameMotion.turn,
    accent: Color(0xFFFCE7F3),
  );

  static const prism = AvatarFrameStyle(
    id: 'prism',
    name: 'Prism',
    description: 'Every colour, softly turning',
    collection: FrameCollection.cinematic,
    colors: [
      Color(0xFFFF9AAE),
      Color(0xFFFFD27A),
      Color(0xFF8FF0B5),
      Color(0xFF7FC8FF),
      Color(0xFFC9A0FF),
      Color(0xFFFF9AAE),
    ],
    motion: FrameMotion.turn,
  );

  static const obsidian = AvatarFrameStyle(
    id: 'obsidian',
    name: 'Obsidian',
    description: 'Black glass with a clean highlight',
    collection: FrameCollection.cinematic,
    colors: [
      Color(0xFF0A0A0F),
      Color(0xFF2A2A35),
      Color(0xFF050507),
      Color(0xFF2A2A35),
      Color(0xFF0A0A0F),
    ],
    ornament: FrameOrnament.glass,
    accent: Color(0xFFFFFFFF),
  );

  static const supporter = AvatarFrameStyle(
    id: 'supporter',
    name: 'Supporter',
    description: 'The Reelish Supporter gold and star',
    collection: FrameCollection.special,
    colors: [
      Color(0xFFFFE3A3),
      Color(0xFFF5B942),
      Color(0xFFC98A1B),
      Color(0xFFF5B942),
      Color(0xFFFFE3A3),
    ],
    ornament: FrameOrnament.supporterStar,
    motion: FrameMotion.glint,
    accent: Color(0xFFFFD98A),
  );

  /// The first limited edition, for the launch of avatar frames.
  static final premiere2026 = AvatarFrameStyle(
    id: 'premiere_2026',
    name: 'Premiere 2026',
    description: 'Silver film for the premiere of avatar frames',
    collection: FrameCollection.special,
    colors: const [
      Color(0xFFF1F1F4),
      Color(0xFFB9BCC6),
      Color(0xFF7D818E),
      Color(0xFFB9BCC6),
      Color(0xFFF1F1F4),
    ],
    ornament: FrameOrnament.filmStrip,
    motion: FrameMotion.glint,
    accent: const Color(0xFF15151C),
    // Collectable until 1 February 2027 (frames.ts); the last day shown.
    limitedUntil: DateTime.utc(2027, 1, 31),
  );

  /// The Founder's frame, Sovereign: champagne gold, laurel and crown. Its id
  /// stays 'founder', as the Reelish API stores it.
  static const founder = AvatarFrameStyle(
    id: 'founder',
    name: 'Sovereign',
    description: 'Champagne laurel and crown, for the creator of Reelish',
    collection: FrameCollection.special,
    colors: [
      Color(0xFFD6B779),
      Color(0xFFB08D50),
      Color(0xFFD6B779),
      Color(0xFFF3DCA7),
      Color(0xFFD6B779),
    ],
    ornament: FrameOrnament.laurel,
    motion: FrameMotion.sheen,
    founderOnly: true,
  );

  /// Every frame, in the order the collection shows them.
  static final all = [
    aurora,
    celestial,
    royal,
    roseGold,
    eclipse,
    nebula,
    prism,
    obsidian,
    supporter,
    premiere2026,
    founder,
  ];

  /// The frame stored as [id]; null for none, or an id this app does not
  /// know (a retired frame, or one from a newer app).
  static AvatarFrameStyle? byId(String? id) {
    if (id == null) return null;
    for (final style in all) {
      if (style.id == id) return style;
    }
    return null;
  }
}
