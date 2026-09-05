// Opens a line in ONE round trip: create or join the squad, then mint the
// LiveKit token, and return both.
//
// It used to be two calls from the phone — create_squad, wait, then
// mint-livekit-token, wait — with a modal spinner over the app for the whole
// journey. Two round trips to a server in another region is most of a second
// before LiveKit has even been dialled, and there is nothing in the first
// answer the phone needs except the id it immediately hands back. Doing both
// here removes a full round trip and the app opens the line straight away.
//
// The LiveKit API secret lives here and never ships inside the app, where
// anybody could pull it out of the binary and mint themselves a token for any
// room they liked. The membership check still applies: this function performs
// the join through the same rate-limited, block-aware RPC the app used to
// call, and only mints a token if that RPC said yes.
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.1/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const LIVEKIT_KEY = Deno.env.get("LIVEKIT_API_KEY")!;
const LIVEKIT_SECRET = Deno.env.get("LIVEKIT_API_SECRET")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const { code, deviceId, displayName, create: creating, name } = await req.json();
    if (!code || !deviceId) return json({ error: "code and deviceId are required" }, 400);

    const db = createClient(SUPABASE_URL, SERVICE_KEY);

    // Forward the caller's address so the rate limiter sees the phone, not
    // this function. Without it every attempt would look like one client.
    const forwarded = req.headers.get("x-forwarded-for") ?? "";

    const rpc = creating ? "create_squad" : "join_squad";
    const args = creating
      ? { p_code: code, p_name: name ?? "Squad", p_device_id: deviceId, p_display_name: displayName ?? "Someone" }
      : { p_code: code, p_device_id: deviceId, p_display_name: displayName ?? "Someone" };

    const { data, error } = await db.rpc(rpc, args, {
      head: false,
      get: false,
    }).select().maybeSingle();

    if (error) return json({ error: error.message }, 500);
    const row = data as Record<string, unknown> | null;
    if (!row) return json({ error: "no answer from the line" }, 500);

    const outcome = String(row.r_outcome ?? "");
    if (outcome !== "ok") {
      // Hand the outcome straight back so the app can say the right thing.
      return json({
        outcome,
        retryAfter: Number(row.r_retry_after ?? 0),
        forwardedFor: forwarded ? true : false,
      }, 200);
    }

    const squadId = String(row.r_squad_id);

    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(LIVEKIT_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );

    const token = await create({ alg: "HS256", typ: "JWT" }, {
      iss: LIVEKIT_KEY,
      sub: deviceId,
      name: displayName ?? "Someone",
      nbf: getNumericDate(0),
      exp: getNumericDate(60 * 60 * 6),
      video: {
        room: `opencomms-${squadId}`,
        roomJoin: true,
        canPublish: true,
        canSubscribe: true,
        // No video anywhere in this app, so the grant does not include it.
        canPublishData: true,
      },
    }, key);

    return json({
      outcome: "ok",
      squadId,
      squadName: row.r_squad_name ?? name ?? "Squad",
      joinCode: row.r_join_code ?? code,
      isCreator: Boolean(row.r_is_creator),
      token,
    });
  } catch (error) {
    return json({ error: String(error) }, 500);
  }
});
