# Streaming network and plugin trust boundary

Provider manifests, provider scripts, and every URL they supply are untrusted
input. Installed repository URLs are user configured; manifest and script
content is fetched again when providers are used. The current repository format
has no signing key or signature verification mechanism, so a repository owner
or compromised hosting account can change executable provider code. Do not
describe installed providers as immutable or cryptographically trusted.

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
to the MediaKit adapter on Android. HLS and DASH format hints are carried into
the `video_player` API; MediaKit/libmpv still performs the actual URL probing
on Android. Current playback still uses one engine per platform:
MediaKit/libmpv on Android and Flutter's registered video player on other
platforms. The `PlayerEngine` interface is a Dart coordination boundary; it
does not currently provide an Android Media3 engine or engine failover.

Android's app-wide `usesCleartextTraffic` override is removed. Android's
cleartext policy cannot safely enumerate dynamically discovered provider
domains. HTTP media URLs remain eligible after public-address preflight because
some providers require them. The player is MediaKit/libmpv native networking,
not the Dart HTTP client: DNS is checked before handing over a stream, but the
native engine may resolve the hostname again and follows playlist and media
redirects internally. Those later native requests are not pinned or validated
by the Dart policy. Torrent tracker URLs also receive DNS preflight, but the
native torrent engine's peer and DHT networking is outside this boundary.

Consequently, cleartext restrictions and DNS pinning are strongest for Dart
HTTP paths. HTTP playback behavior and enforcement of Android's cleartext
policy by the bundled native media/torrent libraries require on-device
verification. A controlled native proxy or player integration would be needed
to validate every media playlist segment and redirect without relying on the
native engine's resolver.
