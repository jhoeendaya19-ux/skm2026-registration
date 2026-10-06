import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const MAX_BATCH = 100;

type JsonRecord = Record<string, unknown>;
type Candidate = {
  result_key: string;
  participant_id: string | null;
  reference_number: string | null;
  bib_number: string;
  runner_name: string;
  email: string;
  category_name: string;
  age_group_name: string | null;
  wave_name: string | null;
  gun_start_at: string | null;
  finish_at: string;
  gun_time: string | number | null;
  chip_time: string | number | null;
  overall_sex_place: number | null;
  age_group_sex_place: number | null;
  award_status: string | null;
  result_status: string;
  event_name: string;
  event_date: string | null;
  session_name: string;
  session_type: string;
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}

function text(value: unknown): string {
  return String(value ?? "").trim();
}

function escapeHtml(value: unknown): string {
  return text(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function validEmail(value: unknown): boolean {
  return EMAIL_RE.test(text(value).toLowerCase());
}

function maskEmail(value: unknown): string {
  const clean = text(value).toLowerCase();
  const [name, domain] = clean.split("@");
  if (!name || !domain) return "No valid email";
  return `${name.slice(0, 2)}${"*".repeat(Math.max(2, name.length - 2))}@${domain}`;
}

function secondsToClock(total: number): string {
  const safe = Math.max(0, Math.round(total));
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const seconds = safe % 60;
  return [hours, minutes, seconds].map((part) => String(part).padStart(2, "0")).join(":");
}

function duration(value: string | number | null): string {
  if (typeof value === "number") return secondsToClock(value);
  const clean = text(value);
  if (!clean) return "Not available";
  const match = clean.match(/(?:(\d+)\s+days?\s+)?(\d+):(\d+):(\d+(?:\.\d+)?)/i);
  if (!match) return clean;
  const total = Number(match[1] || 0) * 86400 + Number(match[2]) * 3600 + Number(match[3]) * 60 + Number(match[4]);
  return secondsToClock(total);
}

function finishTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-PH", {
    timeZone: "Asia/Manila",
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    hour12: true,
  }).format(date);
}

function emailAddress(raw: string): string {
  const bracketed = raw.match(/<([^>]+)>/);
  const address = text(bracketed?.[1] || raw);
  if (!validEmail(address)) throw new Error("EMAIL_FROM must contain a valid email address.");
  return address.toLowerCase();
}

function senderFor(candidate: Candidate, source: string, address: string): string {
  const name = source === "cloud" && candidate.event_name.toLowerCase().includes("sorsogon kasanggayahan")
    ? "Sorsogon Kasanggayahan Marathon 2026 Team"
    : "Off Ground Events Timing";
  return `${name} <${address}>`;
}

function resultUrl(eventKey: string, sessionKey: string): string {
  const query = new URLSearchParams({ event: eventKey, session: sessionKey });
  return `https://offgroundevents.com/timing-results?${query.toString()}`;
}

function emailHtml(candidate: Candidate, eventKey: string, sessionKey: string): string {
  const divisionRank = candidate.overall_sex_place ? `#${candidate.overall_sex_place}` : "Not ranked";
  const ageRank = candidate.age_group_sex_place ? `#${candidate.age_group_sex_place}` : "Not ranked";
  const award = candidate.award_status || "Finisher";
  const leaderboard = resultUrl(eventKey, sessionKey);
  return `<!doctype html>
<html><body style="margin:0;background:#f3f7fb;font-family:Arial,sans-serif;color:#102b50">
  <div style="max-width:620px;margin:0 auto;padding:28px 16px">
    <div style="background:#102b50;color:#fff;padding:22px 26px;border-radius:8px 8px 0 0">
      <div style="font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#cfe0f2">Final timing result</div>
      <h1 style="font-size:24px;margin:8px 0 0">${escapeHtml(candidate.event_name)}</h1>
    </div>
    <div style="background:#fff;border:1px solid #cfe0f2;border-top:0;padding:26px;border-radius:0 0 8px 8px">
      <p style="font-size:17px;margin-top:0">Congratulations, <strong>${escapeHtml(candidate.runner_name)}</strong>.</p>
      <p>Your finalized race result is shown below.</p>
      <table role="presentation" style="width:100%;border-collapse:collapse;margin:22px 0">
        <tr><td style="padding:9px;border-bottom:1px solid #e3ebf4;color:#52657d">Bib</td><td style="padding:9px;border-bottom:1px solid #e3ebf4;text-align:right;font-weight:bold">${escapeHtml(candidate.bib_number)}</td></tr>
        <tr><td style="padding:9px;border-bottom:1px solid #e3ebf4;color:#52657d">Category</td><td style="padding:9px;border-bottom:1px solid #e3ebf4;text-align:right;font-weight:bold">${escapeHtml(candidate.category_name)}</td></tr>
        <tr><td style="padding:9px;border-bottom:1px solid #e3ebf4;color:#52657d">Gun time</td><td style="padding:9px;border-bottom:1px solid #e3ebf4;text-align:right;font-weight:bold">${escapeHtml(duration(candidate.gun_time))}</td></tr>
        <tr><td style="padding:9px;border-bottom:1px solid #e3ebf4;color:#52657d">Finish recorded</td><td style="padding:9px;border-bottom:1px solid #e3ebf4;text-align:right;font-weight:bold">${escapeHtml(finishTime(candidate.finish_at))}</td></tr>
        <tr><td style="padding:9px;border-bottom:1px solid #e3ebf4;color:#52657d">Sex division rank</td><td style="padding:9px;border-bottom:1px solid #e3ebf4;text-align:right;font-weight:bold">${escapeHtml(divisionRank)}</td></tr>
        <tr><td style="padding:9px;border-bottom:1px solid #e3ebf4;color:#52657d">Age-group rank</td><td style="padding:9px;border-bottom:1px solid #e3ebf4;text-align:right;font-weight:bold">${escapeHtml(ageRank)}</td></tr>
        <tr><td style="padding:9px;color:#52657d">Result</td><td style="padding:9px;text-align:right;font-weight:bold">${escapeHtml(award)}</td></tr>
      </table>
      <p style="font-size:13px;color:#52657d">This email was released after the timing session was finalized by race staff. View the published result at <a href="${escapeHtml(leaderboard)}" style="color:#1169b4">offgroundevents.com/timing-results</a>.</p>
    </div>
  </div>
</body></html>`;
}

async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes)).map((item) => item.toString(16).padStart(2, "0")).join("");
}

async function fetchJson(url: string, init: RequestInit): Promise<unknown> {
  const response = await fetch(url, init);
  const raw = await response.text();
  let parsed: unknown = null;
  try {
    parsed = raw ? JSON.parse(raw) : null;
  } catch {
    parsed = raw;
  }
  if (!response.ok) {
    const record = parsed && typeof parsed === "object" ? parsed as JsonRecord : {};
    throw new Error(text(record.message || record.error_description || record.error || parsed || response.statusText));
  }
  return parsed;
}

function serviceHeaders(serviceKey: string): Record<string, string> {
  return {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };
}

function userHeaders(publishableKey: string, authorization: string): Record<string, string> {
  return {
    apikey: publishableKey,
    Authorization: authorization,
    "Content-Type": "application/json",
  };
}

async function caller(supabaseUrl: string, publishableKey: string, serviceKey: string, authorization: string) {
  const user = await fetchJson(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: publishableKey, Authorization: authorization },
  }) as JsonRecord;
  const id = text(user.id);
  const email = text(user.email).toLowerCase();
  if (!id || !email) throw new Error("The staff login could not be verified.");
  const query = new URLSearchParams({ id: `eq.${id}`, select: "role,email", limit: "1" });
  const rows = await fetchJson(`${supabaseUrl}/rest/v1/admin_profiles?${query}`, {
    headers: serviceHeaders(serviceKey),
  }) as JsonRecord[];
  const role = text(rows?.[0]?.role);
  if (!new Set(["owner", "timing_staff"]).has(role)) {
    throw new Error("Only the owner or authorized timing staff can send final race results.");
  }
  return { id, email, role };
}

async function rpcRows(
  supabaseUrl: string,
  publishableKey: string,
  authorization: string,
  name: string,
  payload: JsonRecord,
): Promise<JsonRecord[]> {
  return await fetchJson(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: userHeaders(publishableKey, authorization),
    body: JSON.stringify(payload),
  }) as JsonRecord[];
}

async function timingWorkspace(supabaseUrl: string, publishableKey: string, authorization: string): Promise<JsonRecord[]> {
  return await rpcRows(supabaseUrl, publishableKey, authorization, "admin_timing_email_sessions", {});
}

async function candidatesFor(
  supabaseUrl: string,
  publishableKey: string,
  authorization: string,
  source: string,
  body: JsonRecord,
): Promise<Candidate[]> {
  if (source === "cloud") {
    const eventId = text(body.event_id);
    const sessionId = text(body.session_id);
    if (!eventId || !sessionId) throw new Error("Choose a finalized official or test session first.");
    return await rpcRows(supabaseUrl, publishableKey, authorization, "admin_timing_result_email_candidates", {
      p_event_id: eventId,
      p_session_id: sessionId,
    }) as Candidate[];
  }
  const eventKey = text(body.event_key);
  const sessionKey = text(body.session_key);
  if (!eventKey.startsWith("local:") || !sessionKey) throw new Error("Choose a finalized local test session first.");
  return await rpcRows(supabaseUrl, publishableKey, authorization, "admin_local_timing_result_email_candidates", {
    p_event_key: eventKey,
    p_session_key: sessionKey,
  }) as Candidate[];
}

async function sentKeys(supabaseUrl: string, serviceKey: string, eventKey: string, sessionKey: string): Promise<Set<string>> {
  const query = new URLSearchParams({
    event_key: `eq.${eventKey}`,
    session_key: `eq.${sessionKey}`,
    status: "eq.sent",
    select: "result_key",
  });
  const rows = await fetchJson(`${supabaseUrl}/rest/v1/timing_result_email_logs?${query}`, {
    headers: serviceHeaders(serviceKey),
  }) as JsonRecord[];
  return new Set((rows || []).map((row) => text(row.result_key)));
}

async function upsertLogs(supabaseUrl: string, serviceKey: string, rows: JsonRecord[]): Promise<void> {
  if (!rows.length) return;
  const query = new URLSearchParams({ on_conflict: "event_key,session_key,result_key" });
  await fetchJson(`${supabaseUrl}/rest/v1/timing_result_email_logs?${query}`, {
    method: "POST",
    headers: { ...serviceHeaders(serviceKey), Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(rows),
  });
}

function categorySummary(candidates: Candidate[]): JsonRecord[] {
  const counts = new Map<string, number>();
  for (const candidate of candidates) {
    const category = text(candidate.category_name) || "Open";
    counts.set(category, (counts.get(category) || 0) + 1);
  }
  return [...counts.entries()]
    .sort(([a], [b]) => a.localeCompare(b, undefined, { numeric: true }))
    .map(([label, count]) => ({ label, count }));
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const publishableKey = Deno.env.get("SB_PUBLISHABLE_KEY")?.trim()
      || Deno.env.get("SUPABASE_ANON_KEY")?.trim()
      || requiredEnv("SUPABASE_ANON_KEY");
    const authorization = request.headers.get("Authorization") || "";
    if (!authorization.startsWith("Bearer ")) return json({ error: "Sign in before using final result emails." }, 401);

    const operator = await caller(supabaseUrl, publishableKey, serviceKey, authorization);
    const body = await request.json() as JsonRecord;
    const action = text(body.action).toLowerCase();
    if (action === "workspace") {
      const sessions = await timingWorkspace(supabaseUrl, publishableKey, authorization);
      return json({ ok: true, actor: operator, sessions });
    }
    if (!new Set(["preview", "send"]).has(action)) throw new Error("Invalid final result email action.");

    const source = text(body.source).toLowerCase();
    if (!new Set(["cloud", "local"]).has(source)) throw new Error("Invalid timing result source.");
    const eventKey = source === "cloud" ? `cloud:${text(body.event_id)}` : text(body.event_key);
    const sessionKey = source === "cloud" ? text(body.session_id) : text(body.session_key);
    const sessions = await timingWorkspace(supabaseUrl, publishableKey, authorization);
    const selectedSession = sessions.find((row) =>
      text(row.source) === source && text(row.event_key) === eventKey && text(row.session_key) === sessionKey
    );
    if (!selectedSession) throw new Error("This timing session is not finalized or is not assigned to your account.");

    const allCandidates = await candidatesFor(supabaseUrl, publishableKey, authorization, source, body);
    const category = text(body.category);
    const candidates = category
      ? allCandidates.filter((candidate) => text(candidate.category_name).toLowerCase() === category.toLowerCase())
      : allCandidates;
    const alreadySent = await sentKeys(supabaseUrl, serviceKey, eventKey, sessionKey);
    const valid = candidates.filter((candidate) => validEmail(candidate.email));
    const missingEmail = candidates.filter((candidate) => !text(candidate.email)).length;
    const invalidEmail = candidates.filter((candidate) => text(candidate.email) && !validEmail(candidate.email)).length;
    const unsent = valid.filter((candidate) => !alreadySent.has(candidate.result_key));
    const summary = {
      ok: true,
      action,
      source,
      session: selectedSession,
      finished: candidates.length,
      eligible: valid.length,
      unsent: unsent.length,
      already_sent: valid.length - unsent.length,
      missing_email: missingEmail,
      invalid_email: invalidEmail,
      categories: categorySummary(allCandidates),
      sample: unsent.slice(0, 12).map((candidate) => ({
        runner_name: candidate.runner_name,
        bib_number: candidate.bib_number,
        category_name: candidate.category_name,
        gun_time: duration(candidate.gun_time),
        recipient_email: maskEmail(candidate.email),
      })),
    };
    if (action === "preview" || unsent.length === 0) return json(summary);

    const resendKey = requiredEnv("RESEND_API_KEY");
    const fromAddress = emailAddress(requiredEnv("EMAIL_FROM"));
    const batch = unsent.slice(0, MAX_BATCH);
    const now = new Date().toISOString();
    const eventId = source === "cloud" ? text(body.event_id) : null;
    const raceSessionId = source === "cloud" ? text(body.session_id) : null;
    const baseLogs = batch.map((candidate) => ({
      event_key: eventKey,
      session_key: sessionKey,
      result_key: candidate.result_key,
      event_id: eventId,
      race_session_id: raceSessionId,
      participant_id: candidate.participant_id,
      recipient_email: candidate.email.toLowerCase(),
      status: "pending",
      provider_message_id: null,
      error_message: null,
      sent_by_email: operator.email,
      sent_at: null,
      updated_at: now,
    }));
    await upsertLogs(supabaseUrl, serviceKey, baseLogs);

    const messages = batch.map((candidate) => ({
      from: senderFor(candidate, source, fromAddress),
      to: [candidate.email.toLowerCase()],
      subject: `Your Final ${candidate.event_name} Result - Bib ${candidate.bib_number}`,
      html: emailHtml(candidate, eventKey, sessionKey),
    }));
    const keyHash = await digest(`${eventKey}|${sessionKey}|${batch.map((row) => row.result_key).join("|")}`);
    let resendPayload: JsonRecord;
    try {
      resendPayload = await fetchJson("https://api.resend.com/emails/batch", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${resendKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": `timing-results-${keyHash}`,
        },
        body: JSON.stringify(messages),
      }) as JsonRecord;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      await upsertLogs(supabaseUrl, serviceKey, baseLogs.map((row) => ({
        ...row,
        status: "failed",
        error_message: errorMessage.slice(0, 1000),
        updated_at: new Date().toISOString(),
      })));
      return json({ ...summary, sent: 0, failed: batch.length, remaining_unsent: unsent.length, error: errorMessage }, 502);
    }

    const providerRows = Array.isArray(resendPayload.data) ? resendPayload.data as JsonRecord[] : [];
    const sentAt = new Date().toISOString();
    await upsertLogs(supabaseUrl, serviceKey, baseLogs.map((row, index) => ({
      ...row,
      status: "sent",
      provider_message_id: text(providerRows[index]?.id) || null,
      sent_at: sentAt,
      updated_at: sentAt,
    })));

    return json({
      ...summary,
      sent: batch.length,
      failed: 0,
      remaining_unsent: Math.max(0, unsent.length - batch.length),
      batch_limit: MAX_BATCH,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return json({ error: message }, 400);
  }
});
