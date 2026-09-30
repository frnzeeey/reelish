import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/javascript_runtime.dart';
import 'package:http/http.dart' as http;

import 'network_target_policy.dart';

/// Supplies provider scripts with fetch and XMLHttpRequest backed by Dart's
/// HTTP client. Keeping the bridge here avoids flutter_js's polling XHR
/// extension, which loses response status/headers and leaves a timer per VM.
class ProviderFetchBridge {
  static const _maxConcurrentRequests = 4;
  static const _maxRequestBodyBytes = 2 * 1024 * 1024;
  static const _maxResponseBodyBytes = 2 * 1024 * 1024;

  ProviderFetchBridge(
    this.runtime, [
    this._testClient,
    NetworkDestinationValidator? validator,
  ]) : _validator = validator ?? NetworkDestinationValidator() {
    final setup = runtime.evaluate(_polyfill);
    if (setup.isError) throw StateError(setup.stringResult);
    runtime.onMessage('OnfeedFetch', _onFetch);
    runtime.onMessage('OnfeedCancel', _onCancel);
    runtime.onMessage('OnfeedTimer', _onTimer);
  }

  final JavascriptRuntime runtime;
  final http.Client? _testClient;
  final NetworkDestinationValidator _validator;
  bool _active = true;
  int _activeRequests = 0;
  final Queue<Map<String, dynamic>> _queuedRequests = Queue();
  final _ProviderCookieJar _cookies = _ProviderCookieJar();
  final Map<int, Timer> _timers = {};
  final Set<int> _cancelledRequests = {};

  void dispose() {
    _active = false;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  void _onCancel(dynamic raw) {
    if (raw is Map) {
      final id = int.tryParse('${raw['id']}');
      if (id != null) {
        _cancelledRequests.add(id);
        final queuedCount = _queuedRequests.length;
        _queuedRequests.removeWhere((request) => '${request['id']}' == '$id');
        if (_queuedRequests.length != queuedCount) {
          _cancelledRequests.remove(id);
        }
      }
    }
  }

  void _onTimer(dynamic raw) {
    if (!_active || raw is! Map) return;
    final id = int.tryParse('${raw['id']}');
    if (id == null) return;
    if (raw['action'] == 'clear') {
      _timers.remove(id)?.cancel();
      return;
    }
    if (_timers.length >= 64 || _timers.containsKey(id)) return;
    final delay = (raw['delay'] is num ? (raw['delay'] as num).toInt() : 0)
        .clamp(0, 30000);
    final interval = raw['interval'] == true;
    void fire() {
      if (!_active || !_timers.containsKey(id)) return;
      if (!interval) _timers.remove(id);
      runtime.evaluate('globalThis.__onfeedTimerFire($id);');
    }

    _timers[id] = interval
        ? Timer.periodic(
            Duration(milliseconds: delay < 1 ? 1 : delay),
            (_) => fire(),
          )
        : Timer(Duration(milliseconds: delay), fire);
  }

  void _onFetch(dynamic request) {
    if (!_active || request is! Map) return;
    final data = Map<String, dynamic>.from(request);
    if (_activeRequests >= _maxConcurrentRequests) {
      if (_queuedRequests.length >= 32) {
        _reject(data['id'], 'Provider request limit reached.');
      } else {
        _queuedRequests.addLast(data);
      }
      return;
    }
    _startFetch(data);
  }

  void _startFetch(Map<String, dynamic> data) {
    final id = int.tryParse('${data['id']}');
    if (id != null && _cancelledRequests.remove(id)) return;
    _activeRequests++;
    unawaited(_fetch(data));
  }

  Future<void> _fetch(Map<String, dynamic> data) async {
    final id = data['id'];
    final requestId = int.tryParse('$id');
    try {
      final uri = Uri.parse('${data['url'] ?? ''}');
      var method = '${data['method'] ?? 'GET'}'.toUpperCase();
      if (!const {
        'GET',
        'HEAD',
        'POST',
        'PUT',
        'PATCH',
        'DELETE',
        'OPTIONS',
      }.contains(method)) {
        throw const FormatException('Provider HTTP method is not allowed.');
      }
      final headers = data['headers'];
      final requestHeaders = <String, String>{};
      if (headers is Map) {
        requestHeaders.addAll(
          headers.map((key, value) => MapEntry('$key', '$value')),
        );
      }
      if (!requestHeaders.keys.any(
        (key) => key.toLowerCase() == 'accept-encoding',
      )) {
        requestHeaders['Accept-Encoding'] = 'gzip, deflate';
      }
      final body = data['body'];
      List<int>? requestBody;
      if (body != null && method != 'GET' && method != 'HEAD') {
        final encoded = data['bodyBase64'];
        requestBody = encoded is String
            ? base64Decode(encoded)
            : utf8.encode(body is String ? body : jsonEncode(body));
        if (requestBody.length > _maxRequestBodyBytes) {
          throw const FormatException('Provider request body is too large.');
        }
      }

      final maxRedirects = data['followRedirects'] == false
          ? 0
          : (data['maxRedirects'] is num
                ? (data['maxRedirects'] as num).toInt().clamp(0, 5)
                : 5);
      var current = uri;
      Uri? redirectReferer;
      late http.Response response;
      late (List<int>, Map<String, String>) decodedResponse;
      var redirectCount = 0;
      var retriedWithoutCompression = false;
      while (true) {
        final cookie = _cookies.headerFor(current);
        if (cookie.isNotEmpty &&
            !requestHeaders.keys.any((key) => key.toLowerCase() == 'cookie')) {
          requestHeaders['Cookie'] = cookie;
        }
        if (redirectReferer != null &&
            !requestHeaders.keys.any((key) => key.toLowerCase() == 'referer')) {
          requestHeaders['Referer'] = redirectReferer.toString();
        }
        final request = http.Request(method, current)
          ..followRedirects = false
          ..headers.addAll(requestHeaders);
        if (requestBody != null) request.bodyBytes = requestBody;
        response = await _validator.sendForBytes(
          request,
          allowedSchemes: const {'https'},
          maxRequestBytes: _maxRequestBodyBytes,
          maxResponseBytes: _maxResponseBodyBytes,
          timeout: const Duration(seconds: 20),
          testClient: _testClient,
          // HttpClient's automatic gzip decoder can fail before we receive
          // response headers, leaving provider scripts with an opaque stream
          // error. Keep the wire bytes intact and decode below so we can
          // retry malformed/unsupported compression with identity encoding.
          autoUncompress: false,
        );
        _cookies.absorb(current, response.headers);
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null || redirectCount >= maxRedirects) {
            throw const FormatException('Invalid provider redirect.');
          }
          final next = await _validator.validateRedirect(
            current,
            location,
            allowedSchemes: const {'https'},
          );
          final sameOrigin =
              current.scheme == next.scheme &&
              current.host.toLowerCase() == next.host.toLowerCase() &&
              current.port == next.port;
          if (!sameOrigin) {
            requestHeaders.removeWhere(
              (name, _) =>
                  !const {'accept', 'user-agent'}.contains(name.toLowerCase()),
            );
          }
          if ((response.statusCode == 303 && method != 'HEAD') ||
              ((response.statusCode == 301 || response.statusCode == 302) &&
                  method != 'GET' &&
                  method != 'HEAD')) {
            method = 'GET';
            requestBody = null;
            requestHeaders.removeWhere(
              (name, _) =>
                  name.toLowerCase() == 'content-length' ||
                  name.toLowerCase() == 'content-type',
            );
          }
          redirectReferer = current;
          current = next;
          redirectCount++;
          continue;
        }

        try {
          decodedResponse = _decodeContentEncoding(
            response.bodyBytes,
            response.headers,
          );
        } on FormatException {
          final encoding = response.headers['content-encoding']
              ?.trim()
              .toLowerCase();
          final canRetryUncompressed =
              !retriedWithoutCompression &&
              (method == 'GET' || method == 'HEAD') &&
              encoding != null &&
              encoding.isNotEmpty &&
              encoding != 'identity';
          if (!canRetryUncompressed) rethrow;
          // Some origins send malformed or unsupported compressed data. Retry
          // through the same validated redirect path with compression disabled.
          retriedWithoutCompression = true;
          requestHeaders['Accept-Encoding'] = 'identity';
          continue;
        }
        break;
      }
      final bytes = decodedResponse.$1;
      if (!_active ||
          (requestId != null && _cancelledRequests.contains(requestId))) {
        return;
      }
      final responseUrl = response.request?.url ?? current;
      final payload = {
        'status': response.statusCode,
        'statusText':
            response.reasonPhrase ?? _reasonPhrase(response.statusCode),
        'url': responseUrl.toString(),
        'originalUrl': uri.toString(),
        'headers': decodedResponse.$2,
        // Keep the response bytes intact across the Dart/QuickJS bridge.
        // `text()` decodes them on demand; `arrayBuffer()` stays binary-safe.
        'bodyBase64': base64Encode(bytes),
        'bodyText': _decodeText(bytes, response.headers['content-type']),
      };
      runtime.evaluate(
        'globalThis.__onfeedFetchResolve(${jsonEncode(id)}, ${jsonEncode(payload)});',
      );
    } catch (error) {
      if (!_active ||
          (requestId != null && _cancelledRequests.contains(requestId))) {
        return;
      }
      _reject(id, error.toString());
    } finally {
      _activeRequests--;
      if (_active && _queuedRequests.isNotEmpty) {
        _startFetch(_queuedRequests.removeFirst());
      }
      if (requestId != null) _cancelledRequests.remove(requestId);
    }
  }

  static String _decodeText(List<int> bytes, String? contentType) {
    final charset = RegExp(
      r"""charset\s*=\s*["']?([^;"']+)""",
      caseSensitive: false,
    ).firstMatch(contentType ?? '')?.group(1)?.trim().toLowerCase();
    if (charset == null || charset == 'utf-8' || charset == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (charset == 'iso-8859-1' ||
        charset == 'latin1' ||
        charset == 'windows-1252') {
      return latin1.decode(bytes);
    }
    // Dart's standard codecs do not include arbitrary legacy encodings.
    // Preserve bytes in the payload regardless; unknown text encodings use UTF-8.
    return utf8.decode(bytes, allowMalformed: true);
  }

  static (List<int>, Map<String, String>) _decodeContentEncoding(
    List<int> bytes,
    Map<String, String> rawHeaders,
  ) {
    final headers = Map<String, String>.of(rawHeaders);
    final encoding = headers['content-encoding']?.trim().toLowerCase();
    if (encoding == null || encoding.isEmpty || encoding == 'identity') {
      return (bytes, Map.unmodifiable(headers));
    }
    List<int> decoded;
    if (encoding == 'gzip' || encoding == 'x-gzip') {
      decoded = gzip.decode(bytes);
    } else if (encoding == 'deflate') {
      try {
        decoded = zlib.decode(bytes);
      } on FormatException {
        decoded = ZLibDecoder(raw: true).convert(bytes);
      }
    } else if (encoding == 'br') {
      throw const FormatException(
        'Provider response uses Brotli encoding, which this runtime cannot decode.',
      );
    } else {
      throw FormatException(
        'Unsupported provider content encoding: $encoding.',
      );
    }
    if (decoded.length > _maxResponseBodyBytes) {
      throw const FormatException(
        'HTTP response is too large after decompression.',
      );
    }
    headers.remove('content-encoding');
    headers.remove('content-length');
    return (decoded, Map.unmodifiable(headers));
  }

  void _reject(dynamic id, String message) {
    if (!_active) return;
    runtime.evaluate(
      'globalThis.__onfeedFetchReject(${jsonEncode(id)}, ${jsonEncode(message)});',
    );
  }

  static String _reasonPhrase(int status) => switch (status) {
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    204 => 'No Content',
    301 => 'Moved Permanently',
    302 => 'Found',
    304 => 'Not Modified',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    408 => 'Request Timeout',
    429 => 'Too Many Requests',
    500 => 'Internal Server Error',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Timeout',
    _ => '',
  };

  static const _polyfill = r'''
    (function() {
      // Provider scripts commonly use Node's Buffer for base64-encoded API
      // URLs. QuickJS does not provide Buffer, so supply the subset used by
      // providers without relying on browser or Node globals.
      if (typeof globalThis.Buffer === 'undefined') {
        const base64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        function bytesFromBase64(value) {
          const input = String(value).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
          const output = [];
          let accumulator = 0;
          let bitCount = 0;
          for (let index = 0; index < input.length; index++) {
            const character = input[index];
            if (character === '=') break;
            const digit = base64Chars.indexOf(character);
            if (digit < 0) continue;
            accumulator = (accumulator << 6) | digit;
            bitCount += 6;
            if (bitCount >= 8) {
              bitCount -= 8;
              output.push((accumulator >> bitCount) & 255);
            }
          }
          return output;
        }
        function bytesFromHex(value) {
          const input = String(value);
          const output = [];
          for (let index = 0; index + 1 < input.length; index += 2) {
            if (!/^[0-9a-f]{2}$/i.test(input.slice(index, index + 2))) break;
            output.push(parseInt(input.slice(index, index + 2), 16));
          }
          return output;
        }
        function bytesFromUtf8(value) {
          const escaped = encodeURIComponent(String(value));
          const output = [];
          for (let index = 0; index < escaped.length; index++) {
            if (escaped[index] === '%') {
              output.push(parseInt(escaped.slice(index + 1, index + 3), 16));
              index += 2;
            } else {
              output.push(escaped.charCodeAt(index));
            }
          }
          return output;
        }
        function encodeBase64(bytes) {
          let output = '';
          for (let index = 0; index < bytes.length; index += 3) {
            const first = bytes[index] & 255;
            const hasSecond = index + 1 < bytes.length;
            const hasThird = index + 2 < bytes.length;
            const second = hasSecond ? bytes[index + 1] & 255 : 0;
            const third = hasThird ? bytes[index + 2] & 255 : 0;
            output += base64Chars[first >> 2];
            output += base64Chars[((first & 3) << 4) | (second >> 4)];
            output += hasSecond ? base64Chars[((second & 15) << 2) | (third >> 6)] : '=';
            output += hasThird ? base64Chars[third & 63] : '=';
          }
          return output;
        }
        function makeBuffer(bytes) {
          const output = new Uint8Array(bytes);
          Object.defineProperty(output, '_onfeedBuffer', { value: true });
          Object.defineProperty(output, 'toString', {
            value: function(encoding) {
              const format = String(encoding || 'utf8').toLowerCase();
              if (format === 'base64' || format === 'base64url') {
                const result = encodeBase64(this);
                return format === 'base64url'
                  ? result.replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
                  : result;
              }
              if (format === 'hex') {
                return Array.from(this).map(byte => byte.toString(16).padStart(2, '0')).join('');
              }
              if (format === 'ascii' || format === 'latin1' || format === 'binary') {
                return Array.from(this, byte => String.fromCharCode(format === 'ascii' ? byte & 127 : byte)).join('');
              }
              const escaped = Array.from(this, byte => '%' + byte.toString(16).padStart(2, '0')).join('');
              try { return decodeURIComponent(escaped); }
              catch (_) { return Array.from(this, byte => String.fromCharCode(byte)).join(''); }
            }
          });
          return output;
        }
        const BufferCompat = function(value, encoding) {
          return BufferCompat.from(value, encoding);
        };
        BufferCompat.from = function(value, encoding) {
          if (typeof value === 'string') {
            const format = String(encoding || 'utf8').toLowerCase();
            if (format === 'base64' || format === 'base64url') return makeBuffer(bytesFromBase64(value));
            if (format === 'hex') return makeBuffer(bytesFromHex(value));
            if (format === 'ascii' || format === 'latin1' || format === 'binary') {
              return makeBuffer(Array.from(value, character => character.charCodeAt(0) & 255));
            }
            return makeBuffer(bytesFromUtf8(value));
          }
          if (value instanceof ArrayBuffer) return makeBuffer(new Uint8Array(value));
          if (ArrayBuffer.isView(value)) return makeBuffer(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
          if (Array.isArray(value)) return makeBuffer(value);
          throw new TypeError('The first argument must be a string, Buffer, ArrayBuffer, or array.');
        };
        BufferCompat.alloc = function(size, fill) {
          const output = makeBuffer(new Uint8Array(Math.max(0, Number(size) || 0)));
          if (fill != null) output.fill(typeof fill === 'number' ? fill : BufferCompat.from(fill)[0] || 0);
          return output;
        };
        BufferCompat.allocUnsafe = BufferCompat.alloc;
        BufferCompat.isBuffer = value => !!(value && value._onfeedBuffer === true);
        BufferCompat.byteLength = (value, encoding) => BufferCompat.from(String(value), encoding).length;
        BufferCompat.concat = function(values, totalLength) {
          const buffers = values.map(value => BufferCompat.from(value));
          const length = totalLength == null
            ? buffers.reduce((sum, buffer) => sum + buffer.length, 0)
            : Math.max(0, Number(totalLength) || 0);
          const output = BufferCompat.alloc(length);
          let offset = 0;
          for (const buffer of buffers) {
            const count = Math.min(buffer.length, length - offset);
            if (count <= 0) break;
            output.set(buffer.subarray(0, count), offset);
            offset += count;
          }
          return output;
        };
        globalThis.Buffer = BufferCompat;
      }
      let nextFetchId = 0;
      const pendingFetches = Object.create(null);
      let nextTimerId = 0;
      const providerTimers = Object.create(null);
      function normalizeHeaders(input) {
        const output = {};
        if (!input) return output;
        if (typeof input.forEach === 'function') {
          input.forEach((value, key) => output[String(key).toLowerCase()] = String(value));
        } else if (Array.isArray(input)) {
          input.forEach(pair => output[String(pair[0]).toLowerCase()] = String(pair[1]));
        } else {
          Object.keys(input).forEach(key => output[key.toLowerCase()] = String(input[key]));
        }
        return output;
      }
      globalThis.Headers = function(initial) {
        this._values = normalizeHeaders(initial);
      };
      globalThis.Headers.prototype.get = function(name) {
        return this._values[String(name).toLowerCase()] ?? null;
      };
      globalThis.Headers.prototype.has = function(name) {
        return Object.prototype.hasOwnProperty.call(this._values, String(name).toLowerCase());
      };
      globalThis.Headers.prototype.set = function(name, value) {
        this._values[String(name).toLowerCase()] = String(value);
      };
      globalThis.Headers.prototype.append = function(name, value) {
        const key = String(name).toLowerCase();
        this._values[key] = this._values[key] ? this._values[key] + ', ' + String(value) : String(value);
      };
      globalThis.Headers.prototype.delete = function(name) {
        delete this._values[String(name).toLowerCase()];
      };
      globalThis.Headers.prototype.forEach = function(callback) {
        Object.keys(this._values).forEach(key => callback(this._values[key], key));
      };
      globalThis.Headers.prototype.entries = function() {
        return Object.entries(this._values)[Symbol.iterator]();
      };
      globalThis.Headers.prototype.keys = function() {
        return Object.keys(this._values)[Symbol.iterator]();
      };
      globalThis.Headers.prototype.values = function() {
        return Object.values(this._values)[Symbol.iterator]();
      };
      globalThis.Headers.prototype[Symbol.iterator] = globalThis.Headers.prototype.entries;
      if (typeof globalThis.URLSearchParams === 'undefined') {
        globalThis.URLSearchParams = function(input) {
          this._onChange = arguments[1] || null;
          this._pairs = [];
          if (input && typeof input === 'object' && !(input instanceof globalThis.URLSearchParams)) {
            if (Array.isArray(input)) {
              input.forEach(pair => this._pairs.push([String(pair[0]), String(pair[1])]));
            } else {
              Object.keys(input).forEach(key => {
                const values = Array.isArray(input[key]) ? input[key] : [input[key]];
                values.forEach(value => this._pairs.push([key, String(value)]));
              });
            }
            return;
          }
          const raw = input == null ? '' : String(input).replace(/^\?/, '');
          raw.split('&').filter(Boolean).forEach(part => {
            const index = part.indexOf('=');
            const decode = value => decodeURIComponent(value.replace(/\+/g, ' '));
            this._pairs.push([
              decode(index < 0 ? part : part.slice(0, index)),
              decode(index < 0 ? '' : part.slice(index + 1))
            ]);
          });
        };
        globalThis.URLSearchParams.prototype.get = function(name) {
          const pair = this._pairs.find(entry => entry[0] === String(name));
          return pair ? pair[1] : null;
        };
        globalThis.URLSearchParams.prototype.getAll = function(name) {
          return this._pairs.filter(entry => entry[0] === String(name)).map(entry => entry[1]);
        };
        globalThis.URLSearchParams.prototype.has = function(name) {
          return this._pairs.some(entry => entry[0] === String(name));
        };
        globalThis.URLSearchParams.prototype.set = function(name, value) {
          this.delete(name);
          this.append(name, value);
        };
        globalThis.URLSearchParams.prototype.append = function(name, value) {
          this._pairs.push([String(name), String(value)]);
          if (this._onChange) this._onChange(this.toString());
        };
        globalThis.URLSearchParams.prototype.delete = function(name) {
          this._pairs = this._pairs.filter(entry => entry[0] !== String(name));
          if (this._onChange) this._onChange(this.toString());
        };
        globalThis.URLSearchParams.prototype.forEach = function(callback) {
          this._pairs.forEach(pair => callback(pair[1], pair[0], this));
        };
        globalThis.URLSearchParams.prototype.toString = function() {
          const encode = value => encodeURIComponent(value).replace(/%20/g, '+');
          return this._pairs.map(pair => encode(pair[0]) + '=' + encode(pair[1])).join('&');
        };
        globalThis.URLSearchParams.prototype.entries = function() {
          return this._pairs[Symbol.iterator]();
        };
        globalThis.URLSearchParams.prototype[Symbol.iterator] = globalThis.URLSearchParams.prototype.entries;
      }
      if (typeof globalThis.URL === 'undefined') {
        globalThis.URL = function(input, base) {
          let raw = String(input);
          if (!/^[a-z][a-z0-9+.-]*:/i.test(raw)) {
            if (base == null) throw new TypeError('Invalid URL');
            const baseUrl = base instanceof globalThis.URL ? base.href : String(base);
            const baseParts = /^([a-z][a-z0-9+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(baseUrl);
            if (!baseParts) throw new TypeError('Invalid base URL');
            if (raw.startsWith('//')) raw = baseParts[1] + raw;
            else if (raw.startsWith('/')) raw = baseParts[1] + '//' + baseParts[2] + raw;
            else if (raw.startsWith('?')) raw = baseParts[1] + '//' + baseParts[2] + (baseParts[3] || '/') + raw;
            else if (raw.startsWith('#')) raw = baseParts[1] + '//' + baseParts[2] + (baseParts[3] || '/') + (baseParts[4] || '') + raw;
            else {
              const directory = (baseParts[3] || '/').replace(/[^/]*$/, '');
              raw = baseParts[1] + '//' + baseParts[2] + directory + raw;
            }
          }
          const match = /^([a-z][a-z0-9+.-]*:)(?:\/\/([^/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(raw);
          if (!match) throw new TypeError('Invalid URL');
          this.protocol = match[1].toLowerCase();
          this.host = match[2] || '';
          this.hostname = this.host.split(':')[0];
          this.port = this.host.indexOf(':') < 0 ? '' : this.host.slice(this.host.lastIndexOf(':') + 1);
          this.pathname = match[3] || (this.host ? '/' : '');
          this._search = match[4] || '';
          this.hash = match[5] || '';
          this.origin = this.host ? this.protocol + '//' + this.host : 'null';
          this._refresh = () => {
            this.href = this.protocol + (this.host ? '//' + this.host : '') + this.pathname + this._search + this.hash;
          };
          Object.defineProperty(this, 'search', {
            get: () => this._search,
            set: value => {
              this._search = value ? (String(value).startsWith('?') ? String(value) : '?' + value) : '';
              this._refresh();
            }
          });
          this.searchParams = new globalThis.URLSearchParams(this._search, value => {
            this._search = value ? '?' + value : '';
            this._refresh();
          });
          this._refresh();
        };
        globalThis.URL.prototype.toString = function() { return this.href; };
        globalThis.URL.prototype.toJSON = function() { return this.href; };
      }
      if (typeof globalThis.AbortController === 'undefined') {
        globalThis.AbortController = function() {
          const listeners = [];
          this.signal = {
            aborted: false,
            addEventListener: (name, callback) => { if (name === 'abort') listeners.push(callback); },
            removeEventListener: (name, callback) => {
              const index = listeners.indexOf(callback);
              if (index >= 0) listeners.splice(index, 1);
            }
          };
          this.abort = () => {
            if (this.signal.aborted) return;
            this.signal.aborted = true;
            listeners.forEach(callback => callback());
          };
        };
      }
      if (typeof globalThis.TextEncoder === 'undefined') {
        globalThis.TextEncoder = function() {};
        globalThis.TextEncoder.prototype.encode = function(value) {
          return Buffer.from(String(value), 'utf8');
        };
      }
      if (typeof globalThis.TextDecoder === 'undefined') {
        globalThis.TextDecoder = function(encoding) {
          this.encoding = String(encoding || 'utf-8').toLowerCase();
        };
        globalThis.TextDecoder.prototype.decode = function(input) {
          const bytes = input == null ? new Uint8Array(0) :
            (input instanceof ArrayBuffer ? new Uint8Array(input) :
              new Uint8Array(input.buffer, input.byteOffset || 0, input.byteLength));
          if (this.encoding === 'latin1' || this.encoding === 'iso-8859-1' || this.encoding === 'windows-1252') {
            return Array.from(bytes, byte => String.fromCharCode(byte)).join('');
          }
          const escaped = Array.from(bytes, byte => '%' + byte.toString(16).padStart(2, '0')).join('');
          try { return decodeURIComponent(escaped); }
          catch (_) { return Buffer.from(bytes).toString('utf8'); }
        };
      }
      if (typeof globalThis.Request === 'undefined') {
        globalThis.Request = function(input, init) {
          init = init || {};
          const base = typeof input === 'string' || input instanceof URL ?
            { url: String(input) } : input;
          this.url = base.url || String(base);
          this.method = String(init.method || base.method || 'GET').toUpperCase();
          this.headers = new Headers(init.headers || base.headers || {});
          this.body = init.body == null ? (base.body == null ? null : base.body) : init.body;
          this.signal = init.signal || base.signal || null;
        };
      }
      function makeHeaders(input) {
        const normalized = {};
        Object.keys(input || {}).forEach(key => normalized[key.toLowerCase()] = input[key]);
        return {
          get: name => normalized[String(name).toLowerCase()] ?? null,
          has: name => Object.prototype.hasOwnProperty.call(normalized, String(name).toLowerCase()),
          keys: () => Object.keys(normalized)[Symbol.iterator](),
          values: () => Object.values(normalized)[Symbol.iterator](),
          entries: () => Object.entries(normalized)[Symbol.iterator](),
          forEach: callback => Object.keys(normalized).forEach(key => callback(normalized[key], key)),
          [Symbol.iterator]: () => Object.entries(normalized)[Symbol.iterator]()
        };
      }
      if (typeof globalThis.atob !== 'function') {
        globalThis.atob = value => {
          const binary = Buffer.from(String(value), 'base64');
          return Array.from(binary, byte => String.fromCharCode(byte)).join('');
        };
      }
      if (typeof globalThis.btoa !== 'function') {
        globalThis.btoa = value => Buffer.from(String(value), 'binary').toString('base64');
      }
      function bytesFromBase64(value) {
        if (typeof atob !== 'function') {
          throw new Error('Base64 decoder is unavailable.');
        }
        const binary = atob(String(value || ''));
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
        return bytes;
      }
      function copyToArrayBuffer(bytes) {
        const buffer = new ArrayBuffer(bytes.length);
        const view = new Uint8Array(buffer);
        for (let index = 0; index < bytes.length; index++) view[index] = bytes[index];
        return buffer;
      }
      function makeResponse(payload) {
        const bodyBytes = bytesFromBase64(payload.bodyBase64);
        const body = String(payload.bodyText ?? '');
        const headers = new Headers(payload.headers || {});
        return {
          ok: payload.status >= 200 && payload.status < 300,
          status: payload.status,
          statusText: payload.statusText || '',
          url: payload.url || '',
          redirected: payload.url !== payload.originalUrl,
          headers,
          type: 'basic',
          bodyUsed: false,
          text: () => Promise.resolve(body),
          json: () => {
            try { return Promise.resolve(JSON.parse(body)); }
            catch (error) { return Promise.reject(error); }
          },
          arrayBuffer: () => Promise.resolve(copyToArrayBuffer(bodyBytes)),
          blob: () => Promise.resolve({
            size: bodyBytes.byteLength,
            type: headers.get('content-type') || '',
            arrayBuffer: () => Promise.resolve(copyToArrayBuffer(bodyBytes)),
            text: () => Promise.resolve(body)
          }),
          clone: () => makeResponse(payload)
        };
      }
      globalThis.__onfeedFetchResolve = (id, payload) => {
        const pending = pendingFetches[id];
        if (!pending) return;
        delete pendingFetches[id];
        pending.resolve(makeResponse(payload));
      };
      globalThis.__onfeedFetchReject = (id, message) => {
        const pending = pendingFetches[id];
        if (!pending) return;
        delete pendingFetches[id];
        pending.reject(new Error(message));
      };
      globalThis.fetch = function(input, init) {
        init = init || {};
        const request = typeof input === 'string' || input instanceof URL
          ? { url: String(input) }
          : { url: String(input.url), method: input.method, headers: input.headers, body: input.body, signal: input.signal };
        const bodyValue = init.body == null ? (request.body == null ? null : request.body) : init.body;
        const requestHeaders = normalizeHeaders(init.headers || request.headers);
        const isFormUrlEncoded = bodyValue instanceof URLSearchParams;
        if (isFormUrlEncoded && !Object.keys(requestHeaders).some(key => key.toLowerCase() === 'content-type')) {
          requestHeaders['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
        }
        const binaryBody = bodyValue instanceof ArrayBuffer || ArrayBuffer.isView(bodyValue);
        const bodyBytes = binaryBody
          ? (bodyValue instanceof ArrayBuffer
              ? new Uint8Array(bodyValue)
              : new Uint8Array(bodyValue.buffer, bodyValue.byteOffset, bodyValue.byteLength))
          : null;
        const id = ++nextFetchId;
        const signal = init.signal || request.signal;
        return new Promise((resolve, reject) => {
          pendingFetches[id] = { resolve, reject };
          if (signal) {
            if (signal.aborted) {
              delete pendingFetches[id];
              reject(new Error('The operation was aborted.'));
              return;
            }
            signal.addEventListener('abort', () => {
              if (!pendingFetches[id]) return;
              delete pendingFetches[id];
              sendMessage('OnfeedCancel', JSON.stringify({ id }));
              reject(new Error('The operation was aborted.'));
            });
          }
          sendMessage('OnfeedFetch', JSON.stringify({
            id,
            url: request.url,
            method: init.method || request.method || 'GET',
            headers: requestHeaders,
            body: bodyValue == null ? null : (binaryBody ? '[binary]' : (isFormUrlEncoded ? bodyValue.toString() : String(bodyValue))),
            bodyBase64: binaryBody ? Buffer.from(bodyBytes).toString('base64') : null,
            followRedirects: init.redirect !== 'manual',
            maxRedirects: init.maxRedirects
          }));
        });
      };
      globalThis.__onfeedTimerFire = id => {
        const entry = providerTimers[id];
        if (!entry) return;
        if (!entry.interval) delete providerTimers[id];
        entry.callback(...entry.args);
      };
      function scheduleProviderTimer(callback, delay, interval, args) {
        if (typeof callback !== 'function') throw new TypeError('Timer callback must be a function.');
        const id = ++nextTimerId;
        providerTimers[id] = { callback, args, interval };
        sendMessage('OnfeedTimer', JSON.stringify({ id, delay: Number(delay) || 0, interval }));
        return id;
      }
      function clearProviderTimer(id) {
        delete providerTimers[id];
        sendMessage('OnfeedTimer', JSON.stringify({ id: Number(id), action: 'clear' }));
      }
      globalThis.setTimeout = (callback, delay, ...args) => scheduleProviderTimer(callback, delay, false, args);
      globalThis.setInterval = (callback, delay, ...args) => scheduleProviderTimer(callback, delay, true, args);
      globalThis.clearTimeout = clearProviderTimer;
      globalThis.clearInterval = clearProviderTimer;
      globalThis.XMLHttpRequest = function() {
        this.readyState = 0;
        this.status = 0;
        this.statusText = '';
        this.responseURL = '';
        this.responseText = '';
        this.response = null;
        this.responseType = '';
        this.onreadystatechange = null;
        this.onload = null;
        this.onerror = null;
        this.onabort = null;
        this.ontimeout = null;
        this.timeout = 0;
        this._headers = {};
        this._responseHeaders = {};
        this._controller = null;
        this._aborted = false;
        this._timedOut = false;
        this._timeoutId = null;
      };
      globalThis.XMLHttpRequest.DONE = 4;
      globalThis.XMLHttpRequest.prototype.open = function(method, url) {
        this._method = method;
        this._url = String(url);
        this.readyState = 1;
        if (this.onreadystatechange) this.onreadystatechange();
      };
      globalThis.XMLHttpRequest.prototype.setRequestHeader = function(key, value) {
        this._headers[key] = value;
      };
      globalThis.XMLHttpRequest.prototype.getAllResponseHeaders = function() {
        return Object.keys(this._responseHeaders).map(key => key + ': ' + this._responseHeaders[key] + '\r\n').join('');
      };
      globalThis.XMLHttpRequest.prototype.getResponseHeader = function(name) {
        return this._responseHeaders[String(name).toLowerCase()] || null;
      };
      globalThis.XMLHttpRequest.prototype.send = function(body) {
        const xhr = this;
        xhr._controller = new AbortController();
        if (xhr.timeout > 0) {
          xhr._timeoutId = setTimeout(() => {
            xhr._timedOut = true;
            xhr.abort();
            if (xhr.ontimeout) xhr.ontimeout();
          }, xhr.timeout);
        }
        fetch(xhr._url, {
          method: xhr._method,
          headers: xhr._headers,
          body,
          signal: xhr._controller.signal
        }).then(response => {
          xhr.status = response.status;
          xhr.statusText = response.statusText;
          xhr.responseURL = response.url;
          response.headers.forEach((value, key) => xhr._responseHeaders[key] = value);
          if (xhr.responseType === 'arraybuffer') return response.arrayBuffer();
          if (xhr.responseType === 'blob') return response.blob();
          return response.text();
        }).then(value => {
          if (typeof value === 'string') xhr.responseText = value;
          if (xhr.responseType === 'json') xhr.response = JSON.parse(value);
          else xhr.response = value;
          if (xhr._timeoutId != null) clearTimeout(xhr._timeoutId);
          xhr.readyState = 4;
          if (xhr.onreadystatechange) xhr.onreadystatechange();
          if (xhr.onload) xhr.onload();
        }).catch(error => {
          if (xhr._timeoutId != null) clearTimeout(xhr._timeoutId);
          if (xhr._aborted || xhr._timedOut) return;
          xhr.readyState = 4;
          if (xhr.onreadystatechange) xhr.onreadystatechange();
          if (xhr.onerror) xhr.onerror(error);
        });
      };
      globalThis.XMLHttpRequest.prototype.abort = function() {
        if (this.readyState === 0 || this.readyState === 4) return;
        this._aborted = true;
        if (this._controller) this._controller.abort();
        if (this._timeoutId != null) clearTimeout(this._timeoutId);
        this.readyState = 0;
        if (!this._timedOut && this.onabort) this.onabort();
      };
    })();
  ''';
}

/// A provider-runtime-local cookie jar. Each bridge belongs to one isolated
/// QuickJS context, so cookies never cross provider boundaries.
class _ProviderCookieJar {
  final Map<String, _ProviderCookie> _values = {};

  String headerFor(Uri uri) {
    final now = DateTime.now();
    _values.removeWhere(
      (_, cookie) =>
          cookie.expiresAt != null && !cookie.expiresAt!.isAfter(now),
    );
    final host = uri.host.toLowerCase();
    final path = uri.path.isEmpty ? '/' : uri.path;
    final matching =
        _values.values
            .where(
              (cookie) =>
                  (host == cookie.domain ||
                      (cookie.hostOnly == false &&
                          host.endsWith('.${cookie.domain}'))) &&
                  (path == cookie.path ||
                      path.startsWith(
                        cookie.path.endsWith('/')
                            ? cookie.path
                            : '${cookie.path}/',
                      )) &&
                  (!cookie.secure || uri.scheme.toLowerCase() == 'https'),
            )
            .toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length));
    final parts = <String>[];
    var bytes = 0;
    for (final cookie in matching) {
      final part = '${cookie.name}=${cookie.value}';
      if (bytes + part.length + (parts.isEmpty ? 0 : 2) > 8192) break;
      parts.add(part);
      bytes += part.length + (parts.length == 1 ? 0 : 2);
    }
    return parts.join('; ');
  }

  void absorb(Uri uri, Map<String, String> headers) {
    final raw = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'set-cookie')
        .map((entry) => entry.value)
        .expand((value) => value.split(RegExp(r',(?=\s*[^;,=\s]+\s*=)')));
    for (final line in raw) {
      final parts = line.split(';');
      if (parts.isEmpty) continue;
      final pair = parts.first.trim();
      final equals = pair.indexOf('=');
      if (equals <= 0) continue;
      final name = pair.substring(0, equals).trim();
      final value = pair.substring(equals + 1).trim();
      if (name.length > 256 ||
          value.length > 4096 ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9a-zA-Z-]+$").hasMatch(name)) {
        continue;
      }
      var domain = uri.host.toLowerCase();
      var hostOnly = true;
      var path = _defaultPath(uri.path);
      var secure = false;
      DateTime? expiresAt;
      var remove = value.isEmpty;
      for (final attribute in parts.skip(1)) {
        final index = attribute.indexOf('=');
        final key = (index < 0 ? attribute : attribute.substring(0, index))
            .trim()
            .toLowerCase();
        final attributeValue = index < 0
            ? ''
            : attribute.substring(index + 1).trim();
        if (key == 'domain') {
          final candidate = attributeValue.toLowerCase().replaceFirst(
            RegExp(r'^\.'),
            '',
          );
          final host = uri.host.toLowerCase();
          const knownPublicSuffixes = {
            'com',
            'net',
            'org',
            'edu',
            'gov',
            'uk',
            'co.uk',
            'org.uk',
            'ac.uk',
            'com.au',
            'net.au',
            'org.au',
            'co.jp',
            'co.nz',
          };
          if (candidate.isEmpty ||
              !candidate.contains('.') ||
              knownPublicSuffixes.contains(candidate) ||
              !(host == candidate || host.endsWith('.$candidate'))) {
            remove = true;
            domain = '';
          } else {
            domain = candidate;
            hostOnly = false;
          }
        } else if (key == 'path') {
          if (attributeValue.startsWith('/')) path = attributeValue;
        } else if (key == 'secure') {
          secure = true;
        } else if (key == 'max-age') {
          final seconds = int.tryParse(attributeValue);
          if (seconds != null) {
            expiresAt = DateTime.now().add(Duration(seconds: seconds));
            if (seconds <= 0) remove = true;
          }
        } else if (key == 'expires') {
          if (expiresAt == null) {
            try {
              expiresAt = HttpDate.parse(attributeValue);
            } on FormatException {
              // Ignore malformed expiry attributes.
            }
          }
        }
      }
      if (domain.isEmpty) continue;
      final key = '$domain|$path|$name';
      if (remove || (expiresAt != null && !expiresAt.isAfter(DateTime.now()))) {
        _values.remove(key);
      } else {
        if (_values.length >= 256 && !_values.containsKey(key)) {
          _values.remove(_values.keys.first);
        }
        _values[key] = _ProviderCookie(
          name,
          value,
          domain,
          path,
          secure,
          hostOnly,
          expiresAt,
        );
      }
    }
  }

  static String _defaultPath(String path) {
    if (!path.startsWith('/') || path == '/') return '/';
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
}

class _ProviderCookie {
  const _ProviderCookie(
    this.name,
    this.value,
    this.domain,
    this.path,
    this.secure,
    this.hostOnly,
    this.expiresAt,
  );
  final String name, value, domain, path;
  final bool secure, hostOnly;
  final DateTime? expiresAt;
}
