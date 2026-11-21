// PrizmX progressive extension script (uses $prizmx.routeTest, $prizmx.policies, $prizmx.egress).

if (typeof $prizmx === "undefined") {
  $done({ error: "Requires PrizmX runtime" });
} else {
  var hosts = ["api.anthropic.com", "github.com", "google.com", "baidu.com"];
  var routes = hosts.map(function (host) {
    var match = $prizmx.routeTest(host, 443);
    console.log(host, "->", match.policy, "(" + match.resolvedNode + ") via", match.rule);
    return match;
  });
  var groups = $prizmx.policies();
  var egress = $prizmx.egress();
  console.log("Mode:", egress.mode, "Status:", egress.status, "Policy groups:", groups.length);
  $done({
    egress: egress,
    policyGroupCount: groups.length,
    routes: routes
  });
}
