# PrizmX Script SDK

PrizmX evaluates JavaScript using Apple `JavaScriptCore` (`engine: "jsc"`) with one isolated VM per run and an automatic execution timeout. Edit `.js` files in your preferred external editor (VS Code, Cursor, Zed, etc.) and import them via **Scripts → + → Import .js File…** or **Install from URL…**.

---

## 1. Third-Party Compatible APIs (Surge / Stash / Loon / Quantumult X)

### `$done(value)`
Completes the script and returns `value` (object, array, string, number, boolean, or null). Always call `$done(...)` when async work finishes.

### `$httpClient`
Outbound HTTP/HTTPS requests (`get`, `post`, `put`, `patch`, `delete`, `head`, `options`):

```js
$httpClient.get("https://ipwho.is/", function (error, response, data) {
  if (error) {
    $done({ ok: false, error: String(error) });
    return;
  }
  $done({ status: response.status, body: data });
});

$httpClient.post({
  url: "https://httpbin.org/post",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ hello: "prizmx" }),
  timeout: 8
}, function (error, response, data) {
  $done({ status: response && response.status });
});
```

### `$persistentStore`
Key-value storage persisted across runs in `script-kv.json`:

```js
$persistentStore.write("token-123", "my.key");
const saved = $persistentStore.read("my.key"); // "token-123" or null
$persistentStore.write(null, "my.key");        // deletes key
```

### `$notification.post(title, subtitle, body)`
Emits a notification line to the script output panel and PrizmX Events log.

### Quantumult X Compatibility Shims
Non-MITM Quantumult X scripts run directly via built-in shims:
- `$prefs.valueForKey(key)` / `$prefs.setValueForKey(value, key)` / `$prefs.removeValueForKey(key)`
- `$notify(title, subtitle, body)`
- `$task.fetch({ url, method, headers, body })` (returns a Promise resolving to `{ statusCode, headers, body }`)

### Standard Globals
- `$network`: `{ v4: { primaryAddress, primaryInterface }, wifi: { ssid } }`
- `$environment`: `{ engine: "jsc", app: "PrizmX", system: "macOS" | "iOS", version }`
- `$argument`: string configured in **Configure…** (undefined when empty)
- `console.log / info / warn / error`, `setTimeout`, `clearTimeout`, `btoa`, `atob`

---

## 2. PrizmX Extensions (`$prizmx`)

Use feature detection (`if (typeof $prizmx !== "undefined")`) to progressively enhance scripts for PrizmX while keeping third-party compatibility:

### `$prizmx.routeTest(host, port = 443)`
Evaluates which rule, policy group, and resolved outbound node `host:port` would hit under the active profile + enabled modules:

```js
const r = $prizmx.routeTest("api.anthropic.com", 443);
// { host: "api.anthropic.com", port: 443, rule: "DOMAIN-SUFFIX,anthropic.com,AI", policy: "AI", resolvedNode: "US-01" }
```

### `$prizmx.policies()` & `$prizmx.selectPolicy(group, member)`
Inspects policy groups and switches a `select` group live (ideal for `network-changed` scripts):

```js
if ($network.wifi && $network.wifi.ssid === "OfficeWiFi") {
  $prizmx.selectPolicy("Proxy", "DIRECT");
}
$done({ groups: $prizmx.policies().length });
```

### `$prizmx.egress()`
Returns current outbound state snapshot `{ mode, status }`.

---

## 3. Trigger Types

| Type | Behavior |
| --- | --- |
| **Script** | On-demand diagnostic or utility script (run via right-click → **Test**) |
| **Cron** | Scheduled automatically using 5-field (`*/30 * * * *`) or 6-field (`0 */30 * * * *`) syntax |
| **Event** | Triggered automatically when network link changes (`network-changed`) |
| **HTTP Request / Response** | Requires MITM (reserved for PrizmX Pro) |
