// Node-style globals and modules that community provider scripts expect,
// written in JavaScript on top of the sandbox's own fetch bridge. Nothing
// here reaches the network or the host directly: every axios request is a
// `fetch`, so it passes NetworkDestinationValidator like any other.

/// Evaluated in each provider runtime after the fetch bridge, before the
/// provider's code. Defines `globalThis.__onfeedAxios` (returned by
/// `require('axios')`), a minimal `process` and `crypto.getRandomValues`
/// where the engine has none.
const providerNodeCompatScript = r'''
(function() {
  if (typeof globalThis.process === 'undefined') {
    // No host details: an empty environment and a generic platform.
    globalThis.process = {
      env: {},
      argv: [],
      platform: 'linux',
      version: 'v18.0.0',
      versions: {},
      browser: false,
      cwd: () => '/',
      nextTick: (callback, ...args) => Promise.resolve().then(() => callback(...args)),
    };
  }

  if (typeof globalThis.crypto === 'undefined') globalThis.crypto = {};
  if (typeof globalThis.crypto.getRandomValues !== 'function') {
    // For scripts that make nonces or ids. Not a cryptographic source:
    // QuickJS offers none, and provider scripts are untrusted anyway.
    globalThis.crypto.getRandomValues = function(array) {
      if (!ArrayBuffer.isView(array)) throw new TypeError('Expected a typed array.');
      const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
      for (let index = 0; index < bytes.length; index++) bytes[index] = Math.floor(Math.random() * 256);
      return array;
    };
  }
  if (typeof globalThis.crypto.randomUUID !== 'function') {
    globalThis.crypto.randomUUID = function() {
      const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
      return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
    };
  }

  // A subset of axios: the request shapes provider scripts use (get, post,
  // head, request, create, defaults), its response object and its errors.
  function lowerHeaders(headers) {
    const result = {};
    if (!headers) return result;
    const entries = typeof headers.forEach === 'function' && !Array.isArray(headers)
      ? (() => { const list = []; headers.forEach((value, key) => list.push([key, value])); return list; })()
      : Object.entries(headers);
    for (const [key, value] of entries) {
      const name = String(key).toLowerCase();
      // Several Set-Cookie headers arrive joined; axios gives an array.
      result[name] = name === 'set-cookie'
        ? String(value).split(/,(?=\s*[^;,=\s]+=)/).map(part => part.trim())
        : value;
    }
    return result;
  }
  function mergeHeaders(...sources) {
    const result = {};
    for (const source of sources) {
      if (!source) continue;
      for (const [key, value] of Object.entries(source)) {
        if (value === undefined || value === null) continue;
        if (['common', 'get', 'post', 'put', 'patch', 'delete', 'head'].includes(key)) continue;
        result[key] = value;
      }
    }
    return result;
  }
  function buildUrl(config) {
    let url = String(config.url || '');
    if (config.baseURL && !/^[a-z][a-z0-9+.-]*:/i.test(url)) {
      url = String(config.baseURL).replace(/\/+$/, '') + '/' + url.replace(/^\/+/, '');
    }
    const params = config.params;
    if (params && typeof params === 'object') {
      const search = params instanceof URLSearchParams ? params : new URLSearchParams();
      if (!(params instanceof URLSearchParams)) {
        for (const [key, value] of Object.entries(params)) {
          if (value === undefined || value === null) continue;
          if (Array.isArray(value)) value.forEach(item => search.append(key, String(item)));
          else search.append(key, typeof value === 'object' ? JSON.stringify(value) : String(value));
        }
      }
      const query = search.toString();
      if (query) url += (url.includes('?') ? '&' : '?') + query;
    }
    return url;
  }
  function axiosError(message, code, config, response) {
    const error = new Error(message);
    error.name = 'AxiosError';
    error.isAxiosError = true;
    error.code = code;
    error.config = config;
    if (response) error.response = response;
    error.toJSON = () => ({ message, code, status: response ? response.status : undefined });
    return error;
  }
  function create(instanceDefaults) {
    const defaults = Object.assign({ headers: {}, timeout: 0 }, instanceDefaults || {});
    async function request(configOrUrl, maybeConfig) {
      const input = typeof configOrUrl === 'string'
        ? Object.assign({}, maybeConfig || {}, { url: configOrUrl })
        : Object.assign({}, configOrUrl || {});
      const config = Object.assign({}, defaults, input);
      config.method = String(config.method || 'get').toUpperCase();
      const defaultHeaders = defaults.headers || {};
      const headers = mergeHeaders(
        defaultHeaders.common,
        defaultHeaders[config.method.toLowerCase()],
        defaultHeaders,
        input.headers,
      );
      let body = config.data;
      if (body !== undefined && body !== null && config.method !== 'GET' && config.method !== 'HEAD') {
        const hasType = Object.keys(headers).some(key => key.toLowerCase() === 'content-type');
        if (typeof body === 'object' && !(body instanceof URLSearchParams) && !(body instanceof ArrayBuffer) && !ArrayBuffer.isView(body)) {
          body = JSON.stringify(body);
          if (!hasType) headers['Content-Type'] = 'application/json';
        } else if (body instanceof URLSearchParams && !hasType) {
          headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
        }
      } else {
        body = undefined;
      }
      const url = buildUrl(config);
      const controller = new AbortController();
      let timer = null;
      let timedOut = false;
      if (config.timeout > 0) {
        timer = setTimeout(() => { timedOut = true; controller.abort(); }, config.timeout);
      }
      if (config.signal) {
        if (config.signal.aborted) controller.abort();
        else if (typeof config.signal.addEventListener === 'function') {
          config.signal.addEventListener('abort', () => controller.abort());
        }
      }
      let raw;
      try {
        raw = await fetch(url, {
          method: config.method,
          headers,
          body,
          signal: controller.signal,
          redirect: config.maxRedirects === 0 ? 'manual' : 'follow',
          maxRedirects: config.maxRedirects,
        });
      } catch (error) {
        if (timedOut) {
          throw axiosError('timeout of ' + config.timeout + 'ms exceeded', 'ECONNABORTED', config);
        }
        throw axiosError(String(error && error.message || error), 'ERR_NETWORK', config);
      } finally {
        if (timer !== null) clearTimeout(timer);
      }
      const responseType = String(config.responseType || 'json').toLowerCase();
      let data;
      if (responseType === 'arraybuffer') {
        data = await raw.arrayBuffer();
      } else {
        data = await raw.text();
        // axios parses JSON whenever the text is JSON, whatever the type.
        if (responseType === 'json' && typeof data === 'string' && data.length) {
          const trimmed = data.trim();
          if (trimmed[0] === '{' || trimmed[0] === '[') {
            try { data = JSON.parse(trimmed); } catch (_) {}
          }
        }
      }
      const response = {
        data,
        status: raw.status,
        statusText: raw.statusText || '',
        headers: lowerHeaders(raw.headers),
        config,
        request: { responseURL: raw.url, res: { responseUrl: raw.url } },
      };
      const validate = typeof config.validateStatus === 'function'
        ? config.validateStatus
        : status => status >= 200 && status < 300;
      if (!validate(raw.status)) {
        throw axiosError(
          'Request failed with status code ' + raw.status,
          raw.status >= 500 ? 'ERR_BAD_RESPONSE' : 'ERR_BAD_REQUEST',
          config,
          response,
        );
      }
      return response;
    }
    const instance = (configOrUrl, maybeConfig) => request(configOrUrl, maybeConfig);
    instance.request = request;
    instance.defaults = defaults;
    for (const method of ['get', 'delete', 'head', 'options']) {
      instance[method] = (url, config) => request(Object.assign({}, config || {}, { url, method }));
    }
    for (const method of ['post', 'put', 'patch']) {
      instance[method] = (url, data, config) => request(Object.assign({}, config || {}, { url, method, data }));
    }
    // Accepted and ignored: scripts register them, few rely on them.
    const noopManager = { use: () => 0, eject: () => {}, clear: () => {} };
    instance.interceptors = { request: noopManager, response: noopManager };
    instance.create = config => create(Object.assign({}, defaults, config || {}));
    instance.isAxiosError = value => !!(value && value.isAxiosError);
    instance.isCancel = () => false;
    instance.all = promises => Promise.all(promises);
    instance.spread = callback => values => callback(...values);
    instance.default = instance;
    instance.__esModule = true;
    return instance;
  }
  globalThis.__onfeedAxios = create();
})();
''';
