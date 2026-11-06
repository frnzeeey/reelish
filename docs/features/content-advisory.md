# Content advisory

A small card at the top left of the player, shown briefly when a movie or
episode starts: the title's age rating, and any content descriptors a rating
board attached to it.

## How it works

| Piece | Where |
|---|---|
| Parsing, country choice, descriptor mapping | `lib/src/models/content_advisory.dart` |
| Fetching | `TmdbService.contentAdvisory`, started by `HomeScreen._resolveAndOpenPlayer` next to the details request |
| Timing and the card | `ContentAdvisoryController`, `ContentAdvisoryOverlay` in `lib/src/widgets/player/content_advisory_overlay.dart` |
| Gateway routes | `/movie/{id}/release_dates`, `/tv/{id}/content_ratings` in `backend/src/tmdb/allowlist.ts` |

These are separate requests, not additions to the details request, because a
gateway that does not know a new `append_to_response` value refuses the whole
request. A gateway without the two routes answers 404, and the title simply
has no advisory.

## What TMDB really has

Measured on 49 popular titles (25 movies, 24 series) through the gateway in
November 2026:

| | Movies | Series |
|---|---|---|
| Rating in the US and UK | 25 | 24 |
| Rating in the Philippines | 26 of the 49 together | |
| Any descriptor | 20 | 1 |
| Descriptor from the US or UK | 0 | 0 |

- **Age ratings are reliable and nearly universal.** TMDB's data is
  community-maintained, but ratings are widely checked.
- **Descriptors are real rating-board labels, but sparse.** They come from
  boards such as Germany's FSK, the Dutch Kijkwijzer and Brazil's ClassInd.
  A US viewer's `R` has none of its own.
- **Series have effectively none,** and TMDB has no rating at all for an
  episode, so an episode shows its series' rating.
- **Keywords are not used.** They are user tags, not rating decisions. Genres
  are not used either.

## Rules

Age ratings and descriptors are different facts, and the card keeps them
apart:

1. The rating comes from the viewer's country, then the US, then the UK. A
   rating from outside the viewer's country shows its code (`TV-MA · US`).
2. Descriptors come from one board only, never merged. The rating's own board
   is tried first, then the Netherlands, Germany, Brazil, South Africa, Canada,
   Finland and Turkey, stopping at the first with a usable value.
3. Descriptors from another board say so: `From the rating in Germany (16)`.
4. With no descriptors the heading is **AGE RATING**; **CONTENT ADVISORY**
   appears only with real descriptors.
5. Only values in `_words` and `_letters` are shown, mapped to Reelish's
   categories. Unknown or vague ones (`Negative examples`, `Criminal Acts`,
   `Injury`) are left out. Nothing is inferred from a rating.
6. With no rating and no descriptors, nothing shows. `NR` and similar count as
   no rating.

A descriptor list says what one board noted, not everything in the title, and
another country's release can be cut differently. No smoking category exists
because no data for one was found.

## Behaviour

- Shows at the first frame. Playback never waits for it: an advisory that
  arrives within 12 seconds of the first frame still shows, and a later one is
  dropped.
- Stays 6 seconds (`ContentAdvisoryController.displayFor`).
- Once per player session. Source and engine switches, retries, pausing and
  the controls appearing do not bring it back. Pausing or tapping it ends it.
- Each episode opens a new player (see
  [playback lifecycle](../playback/playback-lifecycle.md#switching-episodes)),
  so each gets its own card, from a cached response.
- Sits below the top bar while the controls show and moves up when they hide.
  In a Watch Party it also clears the party badge.
- Takes no focus (`ExcludeFocus`), so the remote and keyboard are unaffected.
  A screen reader hears it once as one label. Not shown in picture in picture.
- No blur: a live `BackdropFilter` over video costs too much for one short
  card. Text keeps at least 4.5:1 contrast even over a white frame.

## Deployment

The two gateway routes must reach production before the card can appear for
release users. Until then the app works as before, with no card.

## Testing

`test/content_advisory_test.dart` covers parsing, timing and the card.
`windows_player_ui_test` plays a real clip and checks the keyboard under the
card and that it does not return after a pause.
