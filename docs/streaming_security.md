# Streaming network and plugin trust boundary

Provider manifests, provider scripts, and every URL they supply are untrusted
input. Installed repository URLs are user configured; manifest and script
content is fetched again when providers are used. The current repository format
has no signing key or signature verification mechanism, so a repository owner
or compromised hosting account can change executable provider code. Do not
describe installed providers as immutable or cryptographically trusted.

Provider scripts run in QuickJS with a 20 second synchronous execution timeout,
a 64 MiB runtime memory cap, at most four provider runtimes at once, and a
bounded provider search. They have no filesystem, credential, cookie, local
storage, or arbitrary Dart bindings. They receive the requested title and
episode identifiers and an empty settings object. Their
only exposed network interfaces are `fetch` and `XMLHttpRequest`, both backed by
`ProviderFetchBridge`. The bridge enforces public destination resolution,
HTTPS, bounded requests and responses, redirect validation, and concurrency
limits. Providers can still send the title identifiers they receive to any
public HTTPS host; that is part of the provider capability and should be
considered when enabling a repository.

`NetworkDestinationValidator` rejects non-public IPv4 and IPv6 destinations and
pins Dart HTTP sockets to the addresses checked before connecting. Each
redirect is validated separately. HTTPS uses the normal verified TLS handshake
and checks certificates against the original hostname while connecting to the
pinned address. This covers provider fetches and plugin metadata, TMDB,
OpenSubtitles, and subtitle downloads.

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
