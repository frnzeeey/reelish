# Streaming network and plugin trust boundary

Provider manifests, provider scripts, and every URL they supply are untrusted
input. Installed repository URLs are user configured; manifest and script
content is fetched again when providers are used. The current repository format
has no signing key or signature verification mechanism, so a repository owner
or compromised hosting account can change executable provider code. Do not
describe installed providers as immutable or cryptographically trusted.

Reelish pins provider code by SHA-256 instead (trust on first use). The first
version of each script that is downloaded is recorded and runs. If a later
download differs, that provider is paused and the Plugins screen lists the
repository under "Needs attention" until the viewer chooses **Allow update**.
This doesn't prove who wrote the code, but it stops a repository from
silently swapping in new code. Removing a repository forgets its approvals.

Provider scripts run in an isolated QuickJS runtime with a 20 second
synchronous execution limit and a 64 MiB runtime memory cap. The provider
scheduler has four workers, but only two QuickJS runtimes can be active
simultaneously (a configured JS heap ceiling of 128 MiB, plus native/runtime
overhead). Provider script downloads and asynchronous `getStreams` calls are
bounded to 20 seconds each, and a discovery is bounded to 60 seconds. Provider
HTTP has at most four concurrent
requests per runtime, a 20 second request timeout, and 2 MiB request/response
limits. These limits are configuration bounds, not device benchmark results.

Providers have no filesystem, credential store, local storage, or arbitrary
Dart bindings. They receive the requested title and episode identifiers and an
empty settings object. Their only exposed network interfaces are `fetch` and
`XMLHttpRequest`, both backed by `ProviderFetchBridge`. The bridge enforces
public destination resolution, HTTPS, bounded requests and responses, redirect
validation, and runtime-local cookie storage (cookies are not shared between
provider runtimes). Response bytes remain binary-safe through `arrayBuffer()`;
`text()` and `json()` decode on demand. Gzip and deflate responses are decoded;
Brotli responses fail explicitly because the current Dart runtime has no
bundled Brotli decoder. Abort signals stop result delivery, while the bounded
Dart HTTP operation itself may continue until its request timeout. Providers
can still send the title identifiers they receive to any public HTTPS host;
that is part of the provider capability and should be considered when enabling
a repository.

`NetworkDestinationValidator` rejects non-public IPv4 and IPv6 destinations and
pins Dart HTTP sockets to the addresses checked before connecting. Each
redirect is validated separately. HTTPS uses the normal verified TLS handshake
and checks certificates against the original hostname while connecting to the
pinned address. This covers provider fetches and plugin metadata, TMDB,
OpenSubtitles, and subtitle downloads.

Provider results pass through `StreamNormalizer`, `StreamValidator`, and
`SourcePreparer` before native playback. Provider-supplied media headers are
preserved in the canonical source and passed through `VideoPlayerController`
to the engine. HLS and DASH format hints are carried into the `video_player`
API. On Android, HTTPS sources open on Media3 first. Other schemes, torrents
(through the streamer's loopback URL), and sources Media3 cannot decode open on
MediaKit/libmpv. Other platforms use Flutter's registered video player.

Android's app-wide `usesCleartextTraffic` override is removed. Android's
cleartext policy cannot safely enumerate dynamically discovered provider
domains. Media3 follows that policy; libmpv uses its own network stack and
does not. HTTP media URLs remain eligible on libmpv after public-address
preflight because some providers require them.

## Accepted risk: native media requests (SEC-01)

`SourcePreparer` checks that a stream's host resolves to public addresses
before the URL is handed to a native engine. After that, Media3 and libmpv do
their own networking: they resolve the hostname again and follow HTTP
redirects and HLS/DASH playlist entries (variant playlists, segments, keys)
without the Dart destination policy. The torrent engine's peer, tracker and
DHT traffic is also outside it.

So a hostile provider, or a compromised stream host, could make the player
send requests to a private or local address on the viewer's network (a
router admin page, a local service). Such a request carries no Reelish data
beyond the URL and the provider's own headers. The response is fed to a
media decoder, not shown or returned to the provider, so the risk is blind
request forgery against the local network, not data theft.

This is accepted for now. Closing it needs every native media request routed
through an in-app validating proxy. That adds latency and battery use to
playback, and risks breaking providers that rely on redirects or unusual
playlists. Mitigations in place:

- Every URL a provider returns is checked for scheme and public destination
  before playback, so a provider cannot point the player straight at a
  private address.
- Provider scripts can only make network requests through the validating
  fetch bridge.
- Provider code is pinned by hash and changed code needs approval (see
  above), which limits a repository's ability to start sending hostile
  results silently.
- Install only repositories you trust.

Revisit this if Reelish ever handles credentials, or runs on networks where
local services must be protected (managed or enterprise devices).
