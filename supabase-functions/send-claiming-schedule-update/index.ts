const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" }
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

function publishableKey() {
  const json = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (json) {
    const keys = JSON.parse(json);
    return String(keys.default || Object.values(keys)[0] || "");
  }
  return Deno.env.get("SUPABASE_ANON_KEY") || "";
}

async function db(path: string, init: RequestInit = {}) {
  const base = Deno.env.get("SUPABASE_URL");
  const key = secretKey();
  if (!base || !key) throw new Error("Supabase function secrets are unavailable.");
  const response = await fetch(base + path, {
    ...init,
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json", ...(init.headers || {}) }
  });
  const text = await response.text();
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) throw new Error(data?.message || data?.error || "Database request failed.");
  return data;
}

async function actor(request: Request) {
  const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const base = Deno.env.get("SUPABASE_URL");
  if (!token || token.startsWith("sb_") || !base) return null;
  const response = await fetch(`${base}/auth/v1/user`, {
    headers: { apikey: publishableKey(), Authorization: `Bearer ${token}` }
  });
  if (!response.ok) return null;
  const user = await response.json();
  const email = String(user.email || "").toLowerCase();
  if (!email) return null;
  const profiles = await db(`/rest/v1/admin_profiles?select=role&email=ilike.${encodeURIComponent(email)}&limit=1`);
  return { email, role: String(profiles?.[0]?.role || "") };
}

async function authorized(email: string, role: string, eventId: string) {
  if (role === "owner") return true;
  if (!["verifier", "fulfillment_staff"].includes(role)) return false;
  const admins = await db(
    `/rest/v1/event_admins?select=event_id&event_id=eq.${encodeURIComponent(eventId)}&email=ilike.${encodeURIComponent(email)}&role=in.(owner,verifier,fulfillment_staff)&limit=1`
  );
  if (admins?.length) return true;
  if (role !== "fulfillment_staff") return false;
  const assignments = await db(
    `/rest/v1/fulfillment_event_assignments?select=event_id&event_id=eq.${encodeURIComponent(eventId)}&email=ilike.${encodeURIComponent(email)}&limit=1`
  );
  return Boolean(assignments?.length);
}

const esc = (value: unknown) => String(value ?? "")
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
const lines = (value: unknown) => esc(value).replace(/\r?\n/g, "<br>");

function senderEmail() {
  const from = Deno.env.get("EMAIL_FROM") || "Off Ground Events <onboarding@resend.dev>";
  return from.match(/<([^>]+)>/)?.[1] || from;
}

async function kitIsClaimed(scheduleId: string, packageId: string) {
  const [packages, members] = await Promise.all([
    db(`/rest/v1/fulfillment_packages?select=released_at&id=eq.${encodeURIComponent(packageId)}&limit=1`),
    db(
      `/rest/v1/race_kit_claiming_schedule_members?select=claimed_at&schedule_id=eq.${encodeURIComponent(scheduleId)}&package_id=eq.${encodeURIComponent(packageId)}&limit=1`
    )
  ]);
  return Boolean(packages?.[0]?.released_at || members?.[0]?.claimed_at);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply({ error: "Method not allowed." }, 405);
  try {
    const sender = await actor(request);
    if (!sender) return reply({ error: "Sign in again before sending this update." }, 401);
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey) throw new Error("RESEND_API_KEY is not configured.");
    const body = await request.json();
    const updateId = String(body.update_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(updateId)) throw new Error("A valid update ID is required.");
    const updates = await db(`/rest/v1/race_kit_claiming_updates?select=*&id=eq.${encodeURIComponent(updateId)}&limit=1`);
    const update = updates?.[0];
    if (!update) throw new Error("Schedule update not found.");
    if (!(await authorized(sender.email, sender.role, update.event_id))) {
      return reply({ error: "Not authorized to send this schedule update." }, 403);
    }
    const retryFailed = body.retry_failed === true;
    const targetStatus = retryFailed ? "failed" : "pending";
    const recipients = await db(
      `/rest/v1/race_kit_claiming_update_recipients?select=*&update_id=eq.${encodeURIComponent(updateId)}&email_status=eq.${targetStatus}&order=created_at.asc&limit=50`
    );
    if (!recipients?.length) return reply({ ok: true, sent: 0, failed: 0, skipped: 0, more: false });

    const packageIds = recipients.map((row: Record<string, unknown>) => String(row.package_id)).join(",");
    const packages = await db(
      `/rest/v1/fulfillment_packages?select=id,runner_name,reference_number,claim_token,runner_email,released_at&id=in.(${packageIds})`
    );
    const packageMap = new Map(packages.map((pkg: Record<string, unknown>) => [String(pkg.id), pkg]));
    const scheduleIds = [...new Set(recipients.map((row: Record<string, unknown>) => String(row.schedule_id)))].join(",");
    const schedules = await db(
      `/rest/v1/race_kit_claiming_schedules?select=id,claiming_city,venue,schedule_details,status&id=in.(${scheduleIds})`
    );
    const scheduleMap = new Map(schedules.map((row: Record<string, unknown>) => [String(row.id), row]));
    const oldScheduleMap = new Map((update.old_schedules || []).map((row: Record<string, unknown>) => [String(row.id), row]));
    const baseUrl = (Deno.env.get("PUBLIC_SITE_URL") || Deno.env.get("SITE_URL") || "https://offgroundevents.com").replace(/\/$/, "");
    const supportEmail = Deno.env.get("SUPPORT_EMAIL") || "support@offgroundevents.com";
    let sent = 0, failed = 0, skipped = 0;

    async function sendOne(row: Record<string, unknown>) {
      const id = String(row.id);
      const pkg = packageMap.get(String(row.package_id)) as Record<string, unknown> | undefined;
      const schedule = scheduleMap.get(String(row.schedule_id)) as Record<string, unknown> | undefined;
      const previous = oldScheduleMap.get(String(row.schedule_id)) as Record<string, unknown> | undefined;
      const email = String(row.recipient_email || "").trim();
      if (!pkg || !schedule || !email) {
        skipped++;
        await db(`/rest/v1/race_kit_claiming_update_recipients?id=eq.${id}`, {
          method: "PATCH", body: JSON.stringify({ email_status: "skipped", email_error: "Runner, schedule, or email missing.", updated_at: new Date().toISOString() })
        });
        return;
      }
      if (pkg.released_at || await kitIsClaimed(String(row.schedule_id), String(row.package_id))) {
        skipped++;
        await db(`/rest/v1/race_kit_claiming_update_recipients?id=eq.${id}`, {
          method: "PATCH", body: JSON.stringify({
            email_status: "skipped", email_error: "Race kit already claimed; claiming update not sent.",
            updated_at: new Date().toISOString()
          })
        });
        return;
      }
      await db(`/rest/v1/race_kit_claiming_update_recipients?id=eq.${id}`, {
        method: "PATCH", body: JSON.stringify({
          email_status: "sending", email_attempts: Number(row.email_attempts || 0) + 1,
          email_error: null, updated_at: new Date().toISOString()
        })
      });
      const title = update.change_type === "cancellation" ? "Race Kit Claiming Schedule Cancelled"
        : update.change_type === "change" ? "Race Kit Claiming Schedule Changed" : "Race Kit Claiming Update";
      const currentSchedule = update.change_type === "cancellation"
        ? "<p><strong>The previous schedule is cancelled. Please do not report to the venue on that schedule. We will send a new schedule separately.</strong></p>"
        : `<p><strong>Claiming city:</strong> ${esc(schedule.claiming_city)}<br><strong>Venue:</strong> ${lines(schedule.venue)}<br><strong>Date and time:</strong><br>${lines(schedule.schedule_details)}</p>`;
      const oldSchedule = update.change_type === "change" && previous
        ? `<p style="color:#5c6b7b;"><strong>Previous schedule:</strong> ${lines(previous.venue)}; ${lines(previous.schedule_details)}</p>`
        : "";
      const stubUrl = pkg.claim_token ? `${baseUrl}/claim?token=${encodeURIComponent(String(pkg.claim_token))}&mode=claim` : "";
      const html = `<div style="font-family:Arial,sans-serif;color:#132438;line-height:1.6;max-width:680px;margin:auto;">
        <h2 style="color:#0f5ea8;">${title}</h2>
        <p>Hello ${esc(pkg.runner_name)},</p>
        <p>This update applies to your SKM 2026 race kit claiming schedule for reference <strong>${esc(pkg.reference_number)}</strong>.</p>
        <div style="border:1px solid #d9e8f5;background:#f7fbff;padding:18px;margin:20px 0;">${oldSchedule}${currentSchedule}</div>
        <p>${lines(update.message)}</p>
        ${stubUrl ? `<p>Your <a href="${stubUrl}">Digital Claim Stub</a> remains available.</p>` : ""}
        <p>Thank you,<br><strong>Sorsogon Kasanggayahan Marathon 2026 Team</strong></p>
        <p style="color:#52677c;font-size:13px;">For assistance, contact <a href="mailto:${esc(supportEmail)}">${esc(supportEmail)}</a>.</p>
      </div>`;
      try {
        const response = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${resendKey}`,
            "Idempotency-Key": `claiming-update/${updateId}/${row.package_id}`
          },
          body: JSON.stringify({
            from: `Sorsogon Kasanggayahan Marathon 2026 Team <${senderEmail()}>`,
            to: [email], reply_to: supportEmail,
            subject: `${title} - ${pkg.reference_number}`, html
          })
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(result?.message || "Resend rejected the email.");
        sent++;
        await db(`/rest/v1/race_kit_claiming_update_recipients?id=eq.${id}`, {
          method: "PATCH", body: JSON.stringify({
            email_status: "sent", email_sent_at: new Date().toISOString(),
            resend_email_id: result.id || null, email_error: null, updated_at: new Date().toISOString()
          })
        });
      } catch (error) {
        failed++;
        await db(`/rest/v1/race_kit_claiming_update_recipients?id=eq.${id}`, {
          method: "PATCH", body: JSON.stringify({
            email_status: "failed", email_error: error instanceof Error ? error.message : String(error),
            updated_at: new Date().toISOString()
          })
        });
      }
    }

    for (let index = 0; index < recipients.length; index += 8) {
      await Promise.all(recipients.slice(index, index + 8).map(sendOne));
    }
    const moreRows = await db(
      `/rest/v1/race_kit_claiming_update_recipients?select=id&update_id=eq.${encodeURIComponent(updateId)}&email_status=eq.${targetStatus}&limit=1`
    );
    return reply({ ok: failed === 0, update_id: updateId, sent, failed, skipped, more: Boolean(moreRows?.length) });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : String(error) }, 400);
  }
});
