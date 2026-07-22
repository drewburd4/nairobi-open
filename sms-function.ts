// Nairobi Open: SMS relay Edge Function.
// Deploy in the Supabase dashboard as "nairobi-sms" with Verify JWT OFF
// (requests are authenticated by the shared secret instead).
//
// Secrets to set on the function:
//   AT_USERNAME         Africa's Talking app username (pickleball)
//   AT_API_KEY          Africa's Talking API key (dashboard only, never in the repo)
//   NAIROBI_SMS_SECRET  the sms_shared_secret printed by supabase-sms.sql
//   AT_API_HOST         optional; set to https://api.sandbox.africastalking.com
//                       (with AT_USERNAME=sandbox) for sandbox testing
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
    const secret = Deno.env.get("NAIROBI_SMS_SECRET") ?? "";
    if (!secret || req.headers.get("x-nairobi-secret") !== secret) {
      return new Response("forbidden", { status: 403 });
    }

    const { to, message, log_id } = await req.json();
    if (!Array.isArray(to) || to.length === 0 || typeof message !== "string" || message.length > 300) {
      return new Response("bad request", { status: 400 });
    }
    const clean = to.filter((n: unknown) => typeof n === "string" && /^\+\d{10,14}$/.test(n)).slice(0, 8);
    if (clean.length === 0) return new Response("no valid recipients", { status: 400 });

    const host = Deno.env.get("AT_API_HOST") || "https://api.africastalking.com";
    const body = new URLSearchParams({
      username: Deno.env.get("AT_USERNAME") ?? "",
      to: clean.join(","),
      message,
    });
    const r = await fetch(host + "/version1/messaging", {
      method: "POST",
      headers: {
        apiKey: Deno.env.get("AT_API_KEY") ?? "",
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: body.toString(),
    });
    const providerText = await r.text();

    // Best-effort: record the outcome on the log row.
    if (typeof log_id === "string" && /^[0-9a-f-]{36}$/.test(log_id)) {
      const url = Deno.env.get("SUPABASE_URL");
      const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      if (url && key) {
        await fetch(`${url}/rest/v1/nairobi_sms_log?id=eq.${log_id}`, {
          method: "PATCH",
          headers: {
            apikey: key,
            Authorization: `Bearer ${key}`,
            "Content-Type": "application/json",
            Prefer: "return=minimal",
          },
          body: JSON.stringify({
            status: r.ok ? "sent" : "failed",
            provider_response: providerText.slice(0, 500),
          }),
        }).catch(() => {});
      }
    }

    return new Response(r.ok ? "ok" : "provider error", { status: r.ok ? 200 : 502 });
  } catch (_e) {
    return new Response("error", { status: 500 });
  }
});
