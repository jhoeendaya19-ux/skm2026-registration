const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}

function getSecretKey() {
  const keysJson = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keysJson) {
    const keys = JSON.parse(keysJson);
    return String(keys.default || Object.values(keys)[0] || "");
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
}

function getPublishableKey() {
  const keysJson = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (keysJson) {
    const keys = JSON.parse(keysJson);
    return String(keys.default || Object.values(keys)[0] || "");
  }
  return Deno.env.get("SUPABASE_ANON_KEY") || "";
}

async function supabaseRequest(path: string, init: RequestInit = {}) {
  const url = Deno.env.get("SUPABASE_URL");
  const secret = getSecretKey();
  if (!url || !secret) throw new Error("Supabase function secrets are unavailable.");
  const response = await fetch(`${url}${path}`, {
    ...init,
    headers: {
      apikey: secret,
      Authorization: `Bearer ${secret}`,
      "Content-Type": "application/json",
      ...(init.headers || {})
    }
  });
  const raw = await response.text();
  const data = raw ? JSON.parse(raw) : null;
  if (!response.ok) throw new Error(data?.message || data?.error || "Supabase request failed.");
  return data;
}

async function caller(request: Request) {
  const authorization = request.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  const url = Deno.env.get("SUPABASE_URL");
  const publishable = getPublishableKey();
  if (!token || token.startsWith("sb_") || !url || !publishable) return null;
  const response = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: publishable, Authorization: `Bearer ${token}` }
  });
  if (!response.ok) return null;
  const user = await response.json();
  const email = String(user.email || "").toLowerCase();
  if (!email) return null;
  const profiles = await supabaseRequest(`/rest/v1/admin_profiles?select=role&email=ilike.${encodeURIComponent(email)}&limit=1`);
  return { email, role: String(profiles?.[0]?.role || "") };
}

async function canAccessEvent(email: string, role: string, eventId: string) {
  if (role === "owner") return true;
  if (!["verifier", "fulfillment_staff"].includes(role)) return false;
  const eventAdmins = await supabaseRequest(
    `/rest/v1/event_admins?select=event_id&event_id=eq.${encodeURIComponent(eventId)}&email=ilike.${encodeURIComponent(email)}&role=in.(owner,verifier,fulfillment_staff)&limit=1`
  );
  if (eventAdmins?.length) return true;
  if (role !== "fulfillment_staff") return false;
  const assignments = await supabaseRequest(
    `/rest/v1/fulfillment_event_assignments?select=event_id&event_id=eq.${encodeURIComponent(eventId)}&email=ilike.${encodeURIComponent(email)}&limit=1`
  );
  return Boolean(assignments?.length);
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function multiline(value: unknown) {
  return escapeHtml(value).replace(/\r?\n/g, "<br>");
}

function senderEmail() {
  const configured = Deno.env.get("EMAIL_FROM") || "Off Ground Events <onboarding@resend.dev>";
  return configured.match(/<([^>]+)>/)?.[1] || configured;
}

function siteBaseUrl() {
  return (Deno.env.get("PUBLIC_SITE_URL") || Deno.env.get("SITE_URL") || Deno.env.get("SITE_BASE_URL") || "https://offgroundevents.com").replace(/\/$/, "");
}

async function updateMember(scheduleId: string, packageId: string, patch: Record<string, unknown>) {
  return supabaseRequest(
    `/rest/v1/race_kit_claiming_schedule_members?schedule_id=eq.${encodeURIComponent(scheduleId)}&package_id=eq.${encodeURIComponent(packageId)}`,
    { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() }) }
  );
}

async function logResult(payload: Record<string, unknown>) {
  return supabaseRequest("/rest/v1/race_kit_claiming_email_logs", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify(payload)
  });
}

async function kitIsClaimed(scheduleId: string, packageId: string) {
  const [packages, members] = await Promise.all([
    supabaseRequest(`/rest/v1/fulfillment_packages?select=released_at&id=eq.${encodeURIComponent(packageId)}&limit=1`),
    supabaseRequest(
      `/rest/v1/race_kit_claiming_schedule_members?select=claimed_at&schedule_id=eq.${encodeURIComponent(scheduleId)}&package_id=eq.${encodeURIComponent(packageId)}&limit=1`
    )
  ]);
  return Boolean(packages?.[0]?.released_at || members?.[0]?.claimed_at);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const resendKey = Deno.env.get("RESEND_API_KEY");
    if (!resendKey) throw new Error("RESEND_API_KEY is not configured.");
    const actor = await caller(request);
    if (!actor) return jsonResponse({ error: "Sign in again before sending schedule emails." }, 401);

    const body = await request.json();
    const scheduleId = String(body.schedule_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(scheduleId)) throw new Error("A valid schedule ID is required.");

    const schedules = await supabaseRequest(
      `/rest/v1/race_kit_claiming_schedules?select=*&id=eq.${encodeURIComponent(scheduleId)}&limit=1`
    );
    const schedule = schedules?.[0];
    if (!schedule || schedule.status !== "released") throw new Error("The released claiming schedule was not found.");
    if (!(await canAccessEvent(actor.email, actor.role, schedule.event_id))) {
      return jsonResponse({ error: "You are not authorized to send this claiming schedule." }, 403);
    }

    const members = await supabaseRequest(
      `/rest/v1/race_kit_claiming_schedule_members?select=*&schedule_id=eq.${encodeURIComponent(scheduleId)}&email_status=in.(pending,failed,skipped,sending)&order=created_at.asc`
    );
    if (!members?.length) return jsonResponse({ ok: true, sent: 0, failed: 0, skipped: 0, message: "No unsent emails remain." });

    const packageFilter = members.map((member: Record<string, unknown>) => String(member.package_id)).join(",");
    const packages = await supabaseRequest(
      `/rest/v1/fulfillment_packages?select=id,registration_id,reference_number,runner_name,runner_email,race_category,bib_number,claiming_city,claim_token,released_at&id=in.(${packageFilter})`
    );
    const packageMap = new Map(packages.map((pkg: Record<string, unknown>) => [String(pkg.id), pkg]));
    const registrationFilter = packages.map((pkg: Record<string, unknown>) => String(pkg.registration_id)).join(",");
    const registrations = registrationFilter ? await supabaseRequest(
      `/rest/v1/registrations?select=id,medical_clearance_required,medical_clearance_status&id=in.(${registrationFilter})`
    ) : [];
    const registrationMap = new Map(registrations.map((registration: Record<string, unknown>) => [String(registration.id), registration]));
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const supportEmail = Deno.env.get("SUPPORT_EMAIL") || "support@offgroundevents.com";

    let sent = 0;
    let failed = 0;
    let skipped = 0;

    async function sendOne(member: Record<string, unknown>) {
      const packageId = String(member.package_id);
      const pkg = packageMap.get(packageId) as Record<string, unknown> | undefined;
      if (!pkg || !pkg.runner_email || !pkg.claim_token) {
        skipped += 1;
        const error = !pkg ? "Fulfillment package not found." : !pkg.runner_email ? "Runner email is missing." : "Digital claim stub is missing.";
        await updateMember(scheduleId, packageId, { email_status: "skipped", email_error: error, email_attempts: Number(member.email_attempts || 0) + 1 });
        await logResult({ event_id: schedule.event_id, schedule_id: scheduleId, package_id: packageId, registration_id: member.registration_id, recipient_email: pkg?.runner_email || null, status: "skipped", error_message: error, sent_by: actor.email });
        return;
      }
      if (member.claimed_at || pkg.released_at || await kitIsClaimed(scheduleId, packageId)) {
        skipped += 1;
        const error = "Race kit already claimed; claiming schedule email not sent.";
        await updateMember(scheduleId, packageId, {
          email_status: "skipped", email_error: error,
          email_attempts: Number(member.email_attempts || 0) + 1
        });
        await logResult({
          event_id: schedule.event_id, schedule_id: scheduleId, package_id: packageId,
          registration_id: member.registration_id, recipient_email: pkg.runner_email,
          status: "skipped", error_message: error, sent_by: actor.email
        });
        return;
      }

      await updateMember(scheduleId, packageId, { email_status: "sending", email_error: null, email_attempts: Number(member.email_attempts || 0) + 1 });
      const token = String(pkg.claim_token);
      const stubUrl = `${siteBaseUrl()}/claim?token=${encodeURIComponent(token)}&mode=claim`;
      const qrUrl = `${supabaseUrl}/functions/v1/fulfillment-qr?token=${encodeURIComponent(token)}&kind=claim`;
      const name = escapeHtml(pkg.runner_name);
      const reference = escapeHtml(pkg.reference_number);
      const bib = escapeHtml(pkg.bib_number || "-");
      const category = escapeHtml(pkg.race_category || "-");
      const registration = registrationMap.get(String(pkg.registration_id)) as Record<string, unknown> | undefined;
      const bringMedicalCertificate = ["21K", "42K"].includes(String(pkg.race_category || "").toUpperCase())
        && Boolean(registration?.medical_clearance_required)
        && String(registration?.medical_clearance_status || "").toLowerCase() !== "approved";
      const venue = multiline(schedule.venue);
      const details = multiline(schedule.schedule_details);
      const city = escapeHtml(schedule.claiming_city);
      const html = `
        <div style="font-family:Arial,sans-serif;color:#122033;line-height:1.6;max-width:680px;margin:auto;">
          <h2 style="color:#0f5ea8;">Your Race Kit Claiming Schedule</h2>
          <p>Hello ${name},</p>
          <p>Your Sorsogon Kasanggayahan Marathon 2026 race kit has passed quality control and is scheduled for release.</p>
          <div style="border:1px solid #d9e8f5;background:#f7fbff;padding:18px;margin:20px 0;">
            <p style="margin:0 0 10px;"><strong>Date and Time</strong><br>${details}</p>
            <p style="margin:0 0 10px;"><strong>Venue</strong><br>${venue}</p>
            <p style="margin:0;"><strong>Claiming Site</strong><br>${city}</p>
          </div>
          <p><strong>Runner:</strong> ${name}<br><strong>Reference:</strong> ${reference}<br><strong>Bib:</strong> ${bib}<br><strong>Category:</strong> ${category}</p>
          <p>Please present your Digital Claim Stub and a valid government-issued ID. An authorized representative may claim for you but must present a valid ID and comply with the organizer's verification requirements.</p>
          ${bringMedicalCertificate ? '<p style="border:1px solid #e7c66b;background:#fff8e5;padding:14px;"><strong>Medical certificate required at claiming:</strong> Our records do not show an approved online medical clearance. Please bring your completed, doctor-signed fitness-to-run certificate to the race kit claiming venue. A public or private doctor may sign it. Staff will check and receive it before your kit is released.</p>' : ''}
          <p style="text-align:center;margin:24px 0;"><a href="${stubUrl}"><img src="${qrUrl}" width="260" height="260" alt="Digital Claim Stub QR" style="width:260px;max-width:100%;height:auto;border:1px solid #d9e8f5;padding:8px;background:#fff;"></a></p>
          <p style="text-align:center;"><a href="${stubUrl}" style="display:inline-block;background:#0f5ea8;color:#fff;text-decoration:none;font-weight:700;padding:12px 18px;border-radius:6px;">Open Digital Claim Stub</a></p>
          <p>Please claim only during the schedule above. Keep this email for reference.</p>
          <p>Thank you,<br><strong>Sorsogon Kasanggayahan Marathon 2026 Team</strong></p>
          <hr style="border:0;border-top:1px solid #d9e8f5;margin:24px 0 14px;">
          <p style="color:#52677c;font-size:13px;">System-generated email. For assistance, contact <a href="mailto:${escapeHtml(supportEmail)}">${escapeHtml(supportEmail)}</a>.</p>
        </div>`;

      try {
        const response = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${resendKey}`,
            "Idempotency-Key": `claiming-schedule/${scheduleId}/${packageId}`
          },
          body: JSON.stringify({
            from: `Sorsogon Kasanggayahan Marathon 2026 Team <${senderEmail()}>`,
            to: [pkg.runner_email],
            reply_to: supportEmail,
            subject: `Your Race Kit Claiming Schedule - ${pkg.reference_number}`,
            html
          })
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(result?.message || "Resend rejected the email.");
        sent += 1;
        await updateMember(scheduleId, packageId, { email_status: "sent", email_sent_at: new Date().toISOString(), resend_email_id: result.id || null, email_error: null });
        await logResult({ event_id: schedule.event_id, schedule_id: scheduleId, package_id: packageId, registration_id: member.registration_id, recipient_email: pkg.runner_email, status: "sent", resend_email_id: result.id || null, sent_by: actor.email });
      } catch (error) {
        failed += 1;
        const message = error instanceof Error ? error.message : String(error);
        await updateMember(scheduleId, packageId, { email_status: "failed", email_error: message });
        await logResult({ event_id: schedule.event_id, schedule_id: scheduleId, package_id: packageId, registration_id: member.registration_id, recipient_email: pkg.runner_email, status: "failed", error_message: message, sent_by: actor.email });
      }
    }

    for (let index = 0; index < members.length; index += 8) {
      await Promise.all(members.slice(index, index + 8).map(sendOne));
    }

    return jsonResponse({ ok: failed === 0, schedule_id: scheduleId, sent, failed, skipped, total: members.length });
  } catch (error) {
    return jsonResponse({ error: error instanceof Error ? error.message : String(error) }, 400);
  }
});
