// Surge / Stash / Loon compatible script (uses $httpClient, $persistentStore, $notification, $argument).

var target = (typeof $argument === "string" && $argument.trim())
  ? $argument.trim()
  : "https://www.gstatic.com/generate_204";

var started = Date.now();
$httpClient.get({ url: target, timeout: 8 }, function (err, resp) {
  var elapsed = Date.now() - started;
  if (err) {
    console.error("Probe failed:", err);
    $done({ ok: false, target: target, error: String(err) });
    return;
  }
  var count = Number($persistentStore.read("surge.probeCount") || "0") + 1;
  $persistentStore.write(String(count), "surge.probeCount");
  $notification.post("Latency Check", target, "HTTP " + resp.status + " in " + elapsed + "ms");
  console.log("Run #" + count + ":", target, "HTTP", resp.status, elapsed + "ms");
  $done({ ok: true, run: count, status: resp.status, ms: elapsed, target: target });
});
