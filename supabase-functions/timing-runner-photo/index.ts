const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS"
};

function jsonResponse(message, status) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: {
      ...corsHeaders,
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
      "X-Content-Type-Options": "nosniff"
    }
  });
}

function secretKey() {
  const json = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (json) {
    const keys = JSON.parse(json);
    return String(keys.default || Object.values(keys)[0] || "");
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
}

function storagePath(path) {
  return path.split("/").filter(Boolean).map(encodeURIComponent).join("/");
}

async function serviceRequest(path, init = {}) {
  const base = Deno.env.get("SUPABASE_URL");
  const key = secretKey();
  if (!base || !key) throw new Error("Service configuration is unavailable.");
  return fetch(`${base}${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      ...(init.headers || {})
    }
  });
}

async function serviceJson(path, init = {}) {
  const response = await serviceRequest(path, init);
  if (!response.ok) throw new Error("The runner photo lookup failed.");
  return response.json();
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "GET") return jsonResponse("Method not allowed.", 405);

  try {
    const url = new URL(request.url);
    const eventKey = (url.searchParams.get("event_key") || "").trim();
    const sessionKey = (url.searchParams.get("session_key") || "").trim();
    const bibNumber = (url.searchParams.get("bib") || "").trim();
    const eventId = eventKey.startsWith("cloud:") ? eventKey.slice(6) : "";

    if (!eventId || eventId.length > 80 || !/^[a-z0-9_-]+$/i.test(eventId)) {
      return jsonResponse("Runner photo not available.", 404);
    }
    if (!/^[0-9a-f-]{36}$/i.test(sessionKey) || !bibNumber || bibNumber.length > 40) {
      return jsonResponse("Runner photo not available.", 404);
    }

    const publishedResult = await serviceJson("/rest/v1/rpc/public_timing_runner_detail", {
      method: "POST",
      body: JSON.stringify({
        p_event_key: eventKey,
        p_session_key: sessionKey,
        p_bib_number: bibNumber
      })
    });
    if (!Array.isArray(publishedResult) || !publishedResult.length) {
      return jsonResponse("Runner photo not available.", 404);
    }

    const assignments = await serviceJson(
      `/rest/v1/rfid_assignments?select=registration_id&event_id=eq.${encodeURIComponent(eventId)}&bib_number=eq.${encodeURIComponent(bibNumber)}&is_active=eq.true&registration_id=not.is.null&limit=1`
    );
    const registrationId = String(assignments?.[0]?.registration_id || "");
    if (!registrationId) return jsonResponse("Runner photo not available.", 404);

    const registrations = await serviceJson(
      `/rest/v1/registrations?select=participant_photo_path&id=eq.${encodeURIComponent(registrationId)}&event_id=eq.${encodeURIComponent(eventId)}&payment_status=eq.approved&photo_promo_consent=is.true&voided_at=is.null&limit=1`
    );
    const photoPath = String(registrations?.[0]?.participant_photo_path || "").trim();
    if (!photoPath) return jsonResponse("Runner photo not available.", 404);

    const image = await serviceRequest(
      `/storage/v1/object/authenticated/participant-photos/${storagePath(photoPath)}`,
      { headers: { Accept: "image/*" } }
    );
    const contentType = image.headers.get("Content-Type") || "";
    if (!image.ok || !contentType.toLowerCase().startsWith("image/")) {
      return jsonResponse("Runner photo not available.", 404);
    }

    return new Response(image.body, {
      status: 200,
      headers: {
        ...corsHeaders,
        "Cache-Control": "public, max-age=3600, s-maxage=3600, stale-while-revalidate=86400",
        "Content-Type": contentType,
        "Content-Disposition": "inline",
        "X-Content-Type-Options": "nosniff"
      }
    });
  } catch (error) {
    console.error("timing-runner-photo", error);
    return jsonResponse("Runner photo not available.", 404);
  }
});
