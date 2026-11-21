// Quantumult X compatible script (uses $task.fetch, $prefs, $notify, btoa/atob).
// Runs in PrizmX via built-in QX compatibility shims without modification.

var prev = $prefs.valueForKey("qx.lastIP");
$task.fetch({ url: "https://api.ipify.org?format=json", method: "GET" })
  .then(function (resp) {
    var parsed = JSON.parse(resp.body);
    var encoded = btoa(parsed.ip || "");
    var decoded = atob(encoded);
    $prefs.setValueForKey(decoded, "qx.lastIP");
    $notify("QX IP Check", "Current Exit IP", decoded + (prev ? " (prev: " + prev + ")" : ""));
    console.log("QX status:", resp.statusCode, "ip:", decoded);
    $done({ ip: decoded, previous: prev || null, statusCode: resp.statusCode });
  })
  .catch(function (err) {
    console.error("QX fetch failed:", err && err.error ? err.error : err);
    $done({ ok: false, error: String(err && err.error ? err.error : err) });
  });
