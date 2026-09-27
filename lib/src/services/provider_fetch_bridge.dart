import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_js/javascript_runtime.dart';
import 'package:http/http.dart' as http;

/// Supplies provider scripts with fetch and XMLHttpRequest backed by Dart's
/// HTTP client. Keeping the bridge here avoids flutter_js's polling XHR
/// extension, which loses response status/headers and leaves a timer per VM.
class ProviderFetchBridge {
  static const _maxConcurrentRequests = 4;
  static const _maxRequestBodyBytes = 2 * 1024 * 1024;
  static const _maxResponseBodyBytes = 2 * 1024 * 1024;

  ProviderFetchBridge(this.runtime, this.client) {
    final setup = runtime.evaluate(_polyfill);
    if (setup.isError) throw StateError(setup.stringResult);
    runtime.onMessage('OnfeedFetch', _onFetch);
  }

  final JavascriptRuntime runtime;
  final http.Client client;
  bool _active = true;
  int _activeRequests = 0;
  final Queue<Map<String, dynamic>> _queuedRequests = Queue();

  void dispose() => _active = false;

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
    _activeRequests++;
    unawaited(_fetch(data));
  }

  Future<void> _fetch(Map<String, dynamic> data) async {
    final id = data['id'];
    try {
      final uri = Uri.parse('${data['url'] ?? ''}');
      if (!uri.hasAuthority || !{'http', 'https'}.contains(uri.scheme)) {
        throw const FormatException('fetch requires an HTTP or HTTPS URL.');
      }
      final method = '${data['method'] ?? 'GET'}'.toUpperCase();
      final request = http.Request(method, uri);
      final headers = data['headers'];
      if (headers is Map) {
        request.headers.addAll(
          headers.map((key, value) => MapEntry('$key', '$value')),
        );
      }
      final body = data['body'];
      if (body != null && method != 'GET' && method != 'HEAD') {
        final requestBody = body is String ? body : jsonEncode(body);
        if (utf8.encode(requestBody).length > _maxRequestBodyBytes) {
          throw const FormatException('Provider request body is too large.');
        }
        request.body = requestBody;
      }
      request.followRedirects = data['followRedirects'] != false;
      final maxRedirects = data['maxRedirects'];
      request.maxRedirects = maxRedirects is num
          ? maxRedirects.toInt().clamp(0, 5).toInt()
          : 5;

      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 55));
      final responseBytes = BytesBuilder(copy: false);
      var responseSize = 0;
      await for (final chunk in streamed.stream.timeout(
        const Duration(seconds: 55),
      )) {
        responseSize += chunk.length;
        if (responseSize > _maxResponseBodyBytes) {
          throw const FormatException('Provider response is too large.');
        }
        responseBytes.add(chunk);
      }
      final bytes = responseBytes.takeBytes();
      if (!_active) return;
      // IOClient keeps `request.url` as the original URL. Its response also
      // implements BaseResponseWithUrl, which contains the final redirect URL.
      final responseUrl = streamed is http.BaseResponseWithUrl
          ? (streamed as http.BaseResponseWithUrl).url
          : streamed.request?.url ?? uri;
      final response = {
        'status': streamed.statusCode,
        'statusText': _reasonPhrase(streamed.statusCode),
        'url': responseUrl.toString(),
        'originalUrl': uri.toString(),
        'headers': streamed.headers,
        'body': utf8.decode(bytes, allowMalformed: true),
      };
      runtime.evaluate(
        'globalThis.__onfeedFetchResolve(${jsonEncode(id)}, ${jsonEncode(response)});',
      );
    } catch (error) {
      if (!_active) return;
      _reject(id, error.toString());
    } finally {
      _activeRequests--;
      if (_active && _queuedRequests.isNotEmpty) {
        _startFetch(_queuedRequests.removeFirst());
      }
    }
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
      function normalizeHeaders(input) {
        const output = {};
        if (!input) return output;
        if (typeof input.forEach === 'function') {
          input.forEach((value, key) => output[String(key)] = String(value));
        } else if (Array.isArray(input)) {
          input.forEach(pair => output[String(pair[0])] = String(pair[1]));
        } else {
          Object.keys(input).forEach(key => output[key] = String(input[key]));
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
      function makeResponse(payload) {
        const body = String(payload.body ?? '');
        return {
          ok: payload.status >= 200 && payload.status < 300,
          status: payload.status,
          statusText: payload.statusText || '',
          url: payload.url || '',
          redirected: payload.url !== payload.originalUrl,
          headers: makeHeaders(payload.headers),
          text: () => Promise.resolve(body),
          json: () => {
            try { return Promise.resolve(JSON.parse(body)); }
            catch (error) { return Promise.reject(error); }
          },
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
          : { url: String(input.url), method: input.method, headers: input.headers };
        const id = ++nextFetchId;
        return new Promise((resolve, reject) => {
          pendingFetches[id] = { resolve, reject };
          sendMessage('OnfeedFetch', JSON.stringify({
            id,
            url: request.url,
            method: init.method || request.method || 'GET',
            headers: normalizeHeaders(init.headers || request.headers),
            body: init.body == null ? null : String(init.body),
            followRedirects: init.redirect !== 'manual',
            maxRedirects: init.maxRedirects
          }));
        });
      };
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
        this._headers = {};
        this._responseHeaders = {};
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
        fetch(xhr._url, { method: xhr._method, headers: xhr._headers, body }).then(response => {
          xhr.status = response.status;
          xhr.statusText = response.statusText;
          xhr.responseURL = response.url;
          response.headers.forEach((value, key) => xhr._responseHeaders[key] = value);
          return response.text();
        }).then(text => {
          xhr.responseText = text;
          xhr.response = xhr.responseType === 'json' ? JSON.parse(text) : text;
          xhr.readyState = 4;
          if (xhr.onreadystatechange) xhr.onreadystatechange();
          if (xhr.onload) xhr.onload();
        }).catch(error => {
          xhr.readyState = 4;
          if (xhr.onreadystatechange) xhr.onreadystatechange();
          if (xhr.onerror) xhr.onerror(error);
        });
      };
      globalThis.XMLHttpRequest.prototype.abort = function() {};
    })();
  ''';
}
