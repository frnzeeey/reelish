# Avatar frames

Reelish Supporters can wear a frame around their avatar: Profile > Avatar frame,
on phone, TV and Windows. A frame follows the account to every device and shows
to others in Watch Party. The Founder has every frame, and a Founder frame of
their own. The server decides who may wear which ([avatar frames API](../backend/frames.md)).

## The collection

`lib/src/theme/avatar_frames.dart`, one `AvatarFrameStyle` per frame:

| Collection | Frame | Character | Moves |
|---|---|---|---|
| Elegant | Aurora | Northern lights | Colours turn slowly |
| Elegant | Celestial | Midnight blue with stars | No |
| Elegant | Royal | Deep violet with a gold jewel | No |
| Elegant | Rose Gold | Polished rose gold | A glint |
| Cinematic | Eclipse | Dark metal with a corona | No |
| Cinematic | Nebula | Cosmic swirl with drifting light | Colours turn slowly |
| Cinematic | Prism | Every colour, softly | Colours turn slowly |
| Cinematic | Obsidian | Black glass with a highlight | No |
| Special Edition | Supporter | Supporter gold and star | A glint |
| Special Edition | Premiere 2026 | Silver film; limited edition | A glint |
| Special Edition | Founder | Champagne laurel and crown; Founder only | Halo and glint |

Every frame is a band with a fine bezel, except the Founder's, a fine ring
carried by its laurel and crown. A frame is a separate choice from the avatar:
changing the avatar keeps the frame.

## Drawing

`AvatarFrame` (`lib/src/widgets/avatar_frame.dart`) wraps any avatar (Trakt
picture, photo, preset or initial) at any size, all in code, with no image
assets:

- Behind the avatar, painted once: a soft undertone, the band and bezel, and the
  ornaments around it (stars, particles, corona, glass, film sprockets).
- What moves, alone in its own `RepaintBoundary`: a glint, a turning band, or the
  Founder's halo. Most frames are still. One controller per frame, stopped
  under reduced motion, in the background, on a covered page and when scrolled
  out of view, with the still frame shown instead.
- In front, painted once: the Founder's laurel and crown, the Supporter star,
  the Royal jewel.
- Below 48 px only the band is drawn. Small avatars that cannot grow (phone
  Home, the Windows sidebar, the TV rail) take `AvatarFrameRim`, a fine rim in
  the frame's colour. Party avatars wear the frame still.

The Founder frame's edit button sits in the gap at the foot of its laurel; with
other frames it keeps the lower right.

## The account's frames

`AvatarFrames` (`lib/src/account/avatar_frames.dart`) reads `frames` from
`GET /me`, beside `AccountBadges` so both share one request, and keeps a copy per
account (`reelish.frames.v1.<user>`) so the frame shows at once and offline. The
copy only chooses what to draw; equipping calls `PUT /me/frame`, and the server's
answer replaces it. Signing out clears it, and another account never sees it.

## The page

`AvatarFramesScreen` (`lib/src/screens/avatar_frames_screen.dart`): a live
preview of the person's own avatar in the frame they are looking at, then the
collections in even columns. Each tile shows the frame on a quiet disc, with a
check when equipped, a lock (or the Founder's crown) when it cannot be worn, and
Limited or Collected under limited editions. The preview's button equips
("Collect and equip" for an open limited edition), removes the worn frame, or,
for someone who cannot wear it, leads to the Supporters page. The Founder frame
shows to the Founder only, and a closed limited edition only to those who
collected it.

Tests: `test/avatar_frame_test.dart`, `backend/test/frames.test.ts`.
