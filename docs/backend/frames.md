# Avatar frames (server)

`backend/src/frames.ts` decides which avatar frame an account wears and which it
may equip. The frame is part of the account, not the device: it follows the
account to every device, and the server re-checks it every time it is read, so
neither edited local data nor a forged request can wear a frame.

## The catalog

`frames` lists every frame by its stable id (the app draws the same ids,
`lib/src/theme/avatar_frames.dart`; `test/avatar_frame_test.dart` checks both
sides list them). Never rename an id.

| Access | Frames | Who |
|---|---|---|
| `supporter` | `aurora`, `celestial`, `royal`, `rose_gold`, `eclipse`, `nebula`, `prism`, `obsidian`, `supporter` | The `avatar_frames` perk: supporters, and the Founder ([entitlements](entitlements.md)) |
| `supporter`, limited | `premiere_2026` (collectable 1 November 2026 to 1 February 2027) | Supporters who collected it, and the Founder |
| `founder` | `founder` (laurel and crown) | The Founder only |

The Founder may wear every frame, including limited editions after their window
and any frame added later, through the entitlement, never a list.

## Limited editions

A limited edition has a `limited: {from, until}` window. Wearing it while the
window is open collects it: a row in `collected_frames`. After the window it can
no longer be collected, but those who collected it keep it as long as they have
the perk. To add one, give it an id, a window and a design in the app.

## Storage

Migration `0010_avatar_frames.sql`:

- `users.avatar_frame`: the chosen frame's id. `NULL` is the default (the
  Sovereign frame, id `founder`, for the Founder, none for everyone else); `'none'` is a choice of
  no frame.
- `collected_frames (user_id, frame_id, collected_at)`: limited editions
  collected; deleted with the account.

## Reading and changing it

- `GET /me` returns `frames: {equipped, available, collected}`. `equipped` is the
  chosen frame only while the account may still wear it, so a lapsed entitlement
  simply shows no frame and the choice returns if support does. An unknown or
  retired id shows none.
- `PUT /me/frame {frame: id | null}` wears a frame or none (`null` is always
  allowed). It refuses with 400 `unknown_frame`, 403 `founder_only` or
  `supporter_required`, and 409 `frame_unavailable` for a closed edition not
  collected. Rate limited with the sync limiter.

## Watch Party

When an account joins a room, the Worker reads its equipped frame (as above) and
passes it to the room in `X-Party-Frame`, as it does `X-Party-Founder`. The room
keeps it on the socket and includes `frame` in `participants`. Nothing a client
sends sets it: the header is built by the Worker, and `hello` cannot change it.

Tests: `backend/test/frames.test.ts`, `backend/test/watch-party.test.ts`.
