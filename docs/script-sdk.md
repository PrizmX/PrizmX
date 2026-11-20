# PrizmX Script SDK

PrizmX evaluates JavaScript using Apple `JavaScriptCore` (`engine: "jsc"`), with one isolated VM per run and an automatic execution timeout. Edit `.js` files in your preferred external editor (VS Code, Cursor, Zed, etc.) and import them into PrizmX via **Scripts → + → Import .js File…** or **Install from URL…**.

## Global APIs

### `$done(value)`
Completes the script and returns `value` (object, array, string, number, boolean, or null) to the caller/output drawer. Always call `$done(...)` when async work finishes.

### `$httpClient`
Makes outbound HTTP/HTTPS requests (`get`, `post`, `put`, `delete`, `head`):

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
Simple cross-run key-value storage persisted to `script-kv.json`:

```js
$persistentStore.write("token-123", "my.key");
const saved = $persistentStore.read("my.key"); // "token-123" or null
$persistentStore.write(null, "my.key");        // deletes key
```

### `$notification.post(title, subtitle, body)`
Emits a notification line to the script output console and PrizmX Events log.

### `$network` & `$environment` & `$argument`
- `$network`: `{ v4: { primaryAddress, primaryInterface }, wifi: { ssid } }`
- `$environment`: `{ engine: "jsc", app: "PrizmX", system: "macOS" | "iOS", version }`
- `$argument`: string configured in **Configure…** (undefined when empty)
- `console.log / info / warn / error`, `setTimeout`, `clearTimeout`

## Trigger Types

| Type | Behavior |
| --- | --- |
| **Script** | Manual execution from the Scripts page |
| **Cron** | Scheduled using 5-field (`*/30 * * * *`) or 6-field (`0 */30 * * * *`) cron syntax |
| **Event** | Runs when network changes (`network-changed`) |
| **HTTP Request / Response** | Requires MITM (reserved for PrizmX Pro) |
