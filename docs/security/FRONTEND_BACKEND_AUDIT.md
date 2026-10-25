# Reelish frontend/backend boundary audit

<!-- docs-check: historical -->
> **Historical record.** This report describes the codebase when it was written. Files, names and behaviour may have changed since; current documentation starts at [docs/README.md](../README.md).

Date: 2026-10-11.

## Current architecture

Reelish has **no backend**. Everything below runs on the user's device or on
static third-party hosting.

| Component | Where it runs | What it holds |
|---|---|---|
| Flutter app (phone, tablet, TV) | Device | TMDB API key (public client key), user library, settings, approved provider script hashes, cached stream links (private file) |
| Provider scripts | Device (QuickJS sandbox) | Nothing persistent beyond their per-runtime cookie jar |
| Plugin catalog | `raw.githubusercontent.com` (`assets/data/plugins.json` on `main`) | Public listing data |
| Releases and updates | GitHub Releases plus the GitHub REST API | APK and its SHA-256 |
| Website | Netlify, static | Links to `releases/latest/download/reelish.apk`, no secrets |
| Release pipeline | GitHub Actions | Signing key, key passwords, TMDB key, symbols passphrase (Actions secrets only) |

## Logic that must not live in the client, and doesn't

- **Authorization or paid features:** none exist, so there's nothing to
  bypass.
- **Secrets that grant private access:** none in the client. The signing key
  and symbols passphrase never leave CI.
- **Update trust:** the decision is made on-device against the installed
  app's own signing certificate, which an attacker can't forge without the
  key. A server wouldn't add trust here.
- **Provider trust:** decided on the device by the user, with SHA-256 pinning
  of approved code.

## The one client-side credential: TMDB

The TMDB key is embedded and extractable (SEC-04). That's normal for TMDB
client apps, and TMDB's terms allow it. Risks: someone can use the key
against TMDB's quota, and if TMDB revokes it, every installed copy loses its
catalog until an update ships.

### Option: TMDB proxy (not recommended now; needs approval)

A small edge function (for example Cloudflare Workers or Netlify Functions)
would forward `/3/*` GET requests to TMDB with the key added server-side.
It could add a per-IP rate limit and cache responses at the edge.

| | Keep as is | Proxy |
|---|---|---|
| Key exposure | Extractable | Hidden |
| Key rotation | Needs an app release | Server-side, instant |
| Running cost and uptime | None | A service to run and pay for. If it goes down, the catalog does too |
| Privacy | Device talks to TMDB | Device talks to the proxy, which sees every title request |
| App changes | None | Base URL and allowed host; TV and phone share the code |

**Recommendation:** keep the current design. Move to the proxy only if TMDB
throttles or revokes the key. In that case the change is a new
`TmdbService.baseUrl`, which the class already accepts, plus a server
outside this repository. Per the brief, no backend migration was started.

## Other boundary observations

- **Website download toast (UX, not security):** `scripts/main.js` on the
  website shows "Downloading the latest Reelish APK…" on every click, even
  when the browser doesn't download (common on TV browsers). This can explain
  "it said downloading but nothing appeared" reports from Google TV. Change
  it to point TV users to the Downloader app. The site's source isn't in this
  repository.
- **Media playback** crosses the boundary outside the app's network policy
  (SEC-01). Closing it needs a local media proxy on the device, not a
  backend. It's a high-risk playback change and remains proposed only.
