const EVENT_ID = "skm2026";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS"
};

function jsonResponse(payload: unknown, status = 200, cacheControl = "no-store") {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "Cache-Control": cacheControl,
      "Content-Type": "application/json; charset=utf-8",
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

function storagePath(path: string) {
  return path.split("/").filter(Boolean).map(encodeURIComponent).join("/");
}

async function serviceRequest(path: string, init: RequestInit = {}) {
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

async function serviceJson(path: string) {
  const response = await serviceRequest(path);
  if (!response.ok) throw new Error("Runner slideshow lookup failed.");
  return response.json();
}

function normalizedDistance(category: unknown) {
  const match = String(category || "").toUpperCase().match(/(?:^|\s)(42|21|10|5|3)\s*K(?:M)?(?:\s|$)/);
  return match ? `${match[1]}K` : "";
}

function cleanText(value: unknown, maxLength: number) {
  return String(value || "").trim().slice(0, maxLength);
}

function cleanNickname(value: unknown) {
  const nickname = cleanText(value, 80);
  return /^(?:n\/?a|none|-|not applicable)$/i.test(nickname) ? "" : nickname;
}

async function listRunners(requestUrl: URL) {
  const query = new URLSearchParams({
    select: "bib_number,full_name,first_name,nickname,race_category",
    event_id: `eq.${EVENT_ID}`,
    payment_status: "eq.approved",
    voided_at: "is.null",
    is_test_registration: "eq.false",
    photo_promo_consent: "eq.true",
    participant_photo_path: "not.is.null",
    bib_number: "not.is.null",
    order: "race_category.asc,bib_number.asc",
    limit: "5000"
  });
  const rows = await serviceJson(`/rest/v1/registrations?${query.toString()}`);
  const seen = new Set<string>();
  const runners = [];

  for (const row of Array.isArray(rows) ? rows : []) {
    const bibNumber = cleanText(row.bib_number, 40);
    const distance = normalizedDistance(row.race_category);
    if (!bibNumber || !distance || seen.has(bibNumber.toLowerCase())) continue;
    seen.add(bibNumber.toLowerCase());

    const publicBase = Deno.env.get("SUPABASE_URL") || requestUrl.origin;
    const photoUrl = new URL("/functions/v1/skm2026-slideshow-feed", publicBase);
    photoUrl.searchParams.set("bib", bibNumber);
    runners.push({
      bib_number: bibNumber,
      full_name: cleanText(row.full_name, 160),
      first_name: cleanText(row.first_name, 80),
      nickname: cleanNickname(row.nickname),
      race_category: cleanText(row.race_category, 80),
      distance,
      photo_url: photoUrl.toString()
    });
  }

  return jsonResponse(
    { event_id: EVENT_ID, generated_at: new Date().toISOString(), runners },
    200,
    "public, max-age=30, s-maxage=60, stale-while-revalidate=300"
  );
}

async function runnerPhoto(bibNumber: string) {
  if (!bibNumber || bibNumber.length > 40) {
    return jsonResponse({ error: "Runner photo not available." }, 404);
  }

  const query = new URLSearchParams({
    select: "participant_photo_path",
    event_id: `eq.${EVENT_ID}`,
    bib_number: `eq.${bibNumber}`,
    payment_status: "eq.approved",
    voided_at: "is.null",
    is_test_registration: "eq.false",
    photo_promo_consent: "eq.true",
    participant_photo_path: "not.is.null",
    limit: "1"
  });
  const rows = await serviceJson(`/rest/v1/registrations?${query.toString()}`);
  const photoPath = cleanText(rows?.[0]?.participant_photo_path, 1000);
  if (!photoPath) return jsonResponse({ error: "Runner photo not available." }, 404);

  const image = await serviceRequest(
    `/storage/v1/object/authenticated/participant-photos/${storagePath(photoPath)}`,
    { headers: { Accept: "image/*" } }
  );
  const contentType = image.headers.get("Content-Type") || "";
  if (!image.ok || !contentType.toLowerCase().startsWith("image/")) {
    return jsonResponse({ error: "Runner photo not available." }, 404);
  }

  return new Response(image.body, {
    status: 200,
    headers: {
      ...corsHeaders,
      "Cache-Control": "public, max-age=86400, s-maxage=86400, stale-while-revalidate=604800",
      "Content-Type": contentType,
      "Content-Disposition": "inline",
      "X-Content-Type-Options": "nosniff"
    }
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "GET") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const url = new URL(request.url);
    const bibNumber = cleanText(url.searchParams.get("bib"), 40);
    return bibNumber ? await runnerPhoto(bibNumber) : await listRunners(url);
  } catch (error) {
    console.error("skm2026-slideshow-feed", error);
    return jsonResponse({ error: "The runner slideshow is temporarily unavailable." }, 503);
  }
});
