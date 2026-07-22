// Nairobi Open: "you're on court" SMS sender (Africa's Talking).
//
// Where this lives: Supabase dashboard (dispatch project) -> Edge Functions
// -> Deploy a new function -> name it exactly:  nairobi-sms
// Paste this whole file as the function code and deploy.
// IMPORTANT: untick "Verify JWT" for this function; it is protected by its
// own shared token instead (the database trigger sends it, browsers never do).
//
// Secrets to set (Edge Functions -> nairobi-sms -> Secrets):
//   AT_USERNAME        your Africa's Talking username (pickleball)
//   AT_API_KEY         your Africa's Talking API key (atsk_...)
//   NAIROBI_SMS_TOKEN  the token printed when you run supabase-sms.sql
//
// The API key lives ONLY here as a secret. Never put it in index.html or in
// any SQL file; this repo is public.

Deno.serve(async (req) => {
  const expected = Deno.env.get("NAIROBI_SMS_TOKEN") || "";
  if (!expected || req.headers.get("x-nairobi-token") !== expected) {
    return new Response("forbidden", { status: 403 });
  }

  let payload;
  try {
    payload = await req.json();
  } catch (_e) {
    return new Response("bad payload", { status: 200 });
  }
  const to = (Array.isArray(payload.to) ? payload.to : [payload.to])
    .filter((n) => typeof n === "string" && n.startsWith("+254"));
  const message = typeof payload.message === "string" ? payload.message.slice(0, 320) : "";
  if (!to.length || !message) return new Response("nothing to send", { status: 200 });

  const body = new URLSearchParams({
    username: Deno.env.get("AT_USERNAME") || "",
    to: to.join(","),
    message,
  });
  const r = await fetch("https://api.africastalking.com/version1/messaging", {
    method: "POST",
    headers: {
      apiKey: Deno.env.get("AT_API_KEY") || "",
      Accept: "application/json",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });
  const text = await r.text();
  console.log("africastalking", r.status, text);
  // Always 200: the database side is fire-and-forget and must not retry.
  return new Response(text, { status: 200 });
});
