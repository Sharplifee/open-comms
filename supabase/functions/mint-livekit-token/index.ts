// Mints a LiveKit token for one squad.
//
// The LiveKit API secret lives here and never ships inside the app, where
// anybody could pull it out of the binary and mint themselves a token for any
// room they liked.
//
// The membership check is the point of this function. Without it the join code
// is not actually the gate on audio: anyone who learned a squad's UUID could
// mint a token directly and walk past the code, the rate limiter and the block
// list in one step.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const { squadId, deviceId, displayName } = await req.json();
    if (!squadId || !deviceId) {
      return json({ error: "squadId and deviceId are required" }, 400);
    }

    const db = createClient(SUPABASE_URL, SERVICE_KEY);

    // Are they actually in this squad, and is the squad still live?
    const { data: member } = await db
      .from("squad_members")
      .select("device_id")
      .eq("squad_id", squadId)
      .eq("device_id", deviceId)
      .maybeSingle();

    if (!member) return json({ error: "not a member of this line" }, 403);

    const { data: squad } = await db
      .from("squads")
      .select("id, ended_at, expires_at")
      .eq("id", squadId)
      .maybeSingle();

    if (!squad || squad.ended_at || new Date(squad.expires_at) < new Date()) {
      return json({ error: "that line has ended" }, 410);
    }

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

    return json({ token });
  } catch (error) {
    return json({ error: String(error) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
