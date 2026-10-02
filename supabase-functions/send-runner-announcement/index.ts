const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

type JsonRecord = Record<string, unknown>;

function reply(body: JsonRecord, status = 200) {
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
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      ...(init.headers || {})
    }
  });
  const raw = await response.text();
  let data: unknown = null;
  try { data = raw ? JSON.parse(raw) : null; } catch (_) { data = raw; }
  if (!response.ok) {
    const detail = typeof data === "object" && data
      ? String((data as JsonRecord).message || (data as JsonRecord).error || "")
      : String(data || "");
    throw new Error(detail || "Database request failed.");
  }
  return data;
}

async function dbAll(path: string) {
  const rows: JsonRecord[] = [];
  const pageSize = 1000;
  for (let offset = 0; ; offset += pageSize) {
    const page = await db(path, { headers: { Range: `${offset}-${offset + pageSize - 1}` } });
    const items = Array.isArray(page) ? page as JsonRecord[] : [];
    rows.push(...items);
    if (items.length < pageSize) break;
  }
  return rows;
}

async function caller(request: Request) {
  const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const base = Deno.env.get("SUPABASE_URL");
  const key = publishableKey();
  if (!token || token.startsWith("sb_") || !base || !key) return null;
  const response = await fetch(`${base}/auth/v1/user`, {
    headers: { apikey: key, Authorization: `Bearer ${token}` }
  });
  if (!response.ok) return null;
  const user = await response.json();
  const email = String(user.email || "").trim().toLowerCase();
  if (!email) return null;
  const profiles = await db(`/rest/v1/admin_profiles?select=role&email=ilike.${encodeURIComponent(email)}&limit=1`);
  return { email, role: String((profiles as JsonRecord[])?.[0]?.role || "") };
}

async function eventAssignment(email: string, eventId: string) {
  const rows = await db(
    `/rest/v1/event_admins?select=role&event_id=eq.${encodeURIComponent(eventId)}&email=ilike.${encodeURIComponent(email)}&limit=1`
  );
  return String((rows as JsonRecord[])?.[0]?.role || "");
}

async function canSend(actor: { email: string; role: string }, eventId: string) {
  if (actor.role === "owner") return true;
  return ["owner", "verifier"].includes(await eventAssignment(actor.email, eventId));
}

function enabledForEmail(event: JsonRecord) {
  const modules = event.enabled_modules as JsonRecord | null;
  return !modules || modules.email !== false;
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function lower(value: unknown) {
  return cleanText(value).toLowerCase();
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

function supportEmail() {
  return Deno.env.get("SUPPORT_EMAIL") || "support@offgroundevents.com";
}

function formatList(values: Set<string>) {
  const items = [...values].filter(Boolean).sort((a, b) => a.localeCompare(b));
  if (items.length <= 1) return items[0] || "Runner";
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(", ")}, and ${items.at(-1)}`;
}

function replacePlaceholders(template: string, recipient: JsonRecord) {
  return template
    .replaceAll("{{name}}", cleanText(recipient.runner_name))
    .replaceAll("{{reference}}", cleanText(recipient.reference_number))
    .replaceAll("{{category}}", cleanText(recipient.race_category));
}

function validEmail(value: unknown) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanText(value));
}

function normalizeFilters(input: JsonRecord) {
  const status = cleanText(input.status || "approved");
  const group = cleanText(input.group || "all");
  const participantFormat = cleanText(input.participant_format || "all");
  const source = cleanText(input.source || "all");
  const sex = cleanText(input.sex || "all");
  const registrationType = cleanText(input.registration_type || "live");
  if (!["approved", "pending", "approved_or_pending", "needs_correction"].includes(status)) {
    throw new Error("Choose a valid approval status.");
  }
  if (!["all", "standard", "student"].includes(group)) throw new Error("Choose a valid registration group.");
  if (!["all", "physical", "virtual"].includes(participantFormat)) throw new Error("Choose a valid participation format.");
  if (!["all", "online", "onsite", "at_school", "skm_onsite"].includes(source)) throw new Error("Choose a valid registration source.");
  if (!["all", "male", "female"].includes(sex)) throw new Error("Choose a valid sex filter.");
  if (!["live", "test", "all"].includes(registrationType)) throw new Error("Choose a valid registration type.");
  return {
    event_id: cleanText(input.event_id),
    status,
    group,
    participant_format: participantFormat,
    category: cleanText(input.category),
    source,
    sex,
    school_id: cleanText(input.school_id),
    registration_type: registrationType,
    search: cleanText(input.search).slice(0, 120)
  };
}

function statusMatches(filter: string, source: "standard" | "student", status: unknown) {
  const value = lower(status);
  const approved = source === "standard" ? value === "approved" : value === "active";
  const pending = source === "standard" ? value.startsWith("pending_") : value === "pending_payment";
  const correction = source === "standard" && value === "needs_correction";
  if (filter === "approved") return approved;
  if (filter === "pending") return pending;
  if (filter === "approved_or_pending") return approved || pending;
  return correction;
}

function statusLabel(source: "standard" | "student", status: unknown) {
  const value = lower(status);
  if ((source === "standard" && value === "approved") || (source === "student" && value === "active")) return "Approved";
  if ((source === "standard" && value.startsWith("pending_")) || (source === "student" && value === "pending_payment")) return "Pending approval";
  return "Needs correction";
}

type RecipientAccumulator = {
  recipient_email: string;
  names: Set<string>;
  references: Set<string>;
  categories: Set<string>;
  registration_ids: string[];
  student_registration_ids: string[];
};

async function selectRecipients(rawFilters: JsonRecord) {
  const filters = normalizeFilters(rawFilters);
  if (!filters.event_id) throw new Error("Choose an event first.");
  if (filters.group === "student" && filters.event_id !== "skm2026") {
    throw new Error("Student registrations belong to SKM2026 only.");
  }

  const categories = await dbAll(
    `/rest/v1/event_categories?select=id,name,category_type&event_id=eq.${encodeURIComponent(filters.event_id)}&is_deleted=eq.false`
  );
  const categoryById = new Map(categories.map((row) => [String(row.id), row]));
  const categoryTypeByName = new Map(categories.map((row) => [lower(row.name), lower(row.category_type || "physical")]));
  const records: JsonRecord[] = [];

  if (filters.group !== "student" && !filters.school_id) {
    const rows = await dbAll(
      `/rest/v1/registrations?select=id,full_name,email,reference_number,race_category,category_id,sex,payment_status,registration_channel,is_test_registration,voided_at&event_id=eq.${encodeURIComponent(filters.event_id)}&voided_at=is.null&email=not.is.null`
    );
    for (const row of rows) {
      if (!validEmail(row.email) || !statusMatches(filters.status, "standard", row.payment_status)) continue;
      if (filters.registration_type === "live" && row.is_test_registration === true) continue;
      if (filters.registration_type === "test" && row.is_test_registration !== true) continue;
      if (filters.category && lower(row.race_category) !== lower(filters.category)) continue;
      if (filters.source !== "all" && lower(row.registration_channel || "online") !== filters.source) continue;
      if (filters.sex !== "all" && lower(row.sex) !== filters.sex) continue;
      const category = categoryById.get(String(row.category_id || ""));
      const categoryType = lower(category?.category_type || categoryTypeByName.get(lower(row.race_category)) || (lower(row.race_category).includes("virtual") ? "virtual" : "physical"));
      if (filters.participant_format !== "all" && categoryType !== filters.participant_format) continue;
      const haystack = lower(`${row.full_name} ${row.reference_number} ${row.email}`);
      if (filters.search && !haystack.includes(lower(filters.search))) continue;
      records.push({
        source_kind: "standard", id: row.id, name: row.full_name, email: row.email,
        reference_number: row.reference_number, race_category: row.race_category,
        status_label: statusLabel("standard", row.payment_status)
      });
    }
  }

  if (filters.event_id === "skm2026" && filters.group !== "standard" && filters.registration_type !== "test") {
    const rows = await dbAll(
      "/rest/v1/student_registrations?select=id,first_name,last_name,email,reference_number,distance,sex,status,registration_origin,school_id&email=not.is.null"
    );
    for (const row of rows) {
      if (!validEmail(row.email) || !statusMatches(filters.status, "student", row.status)) continue;
      if (filters.category && lower(row.distance) !== lower(filters.category)) continue;
      if (filters.source !== "all" && lower(row.registration_origin || "at_school") !== filters.source) continue;
      if (filters.sex !== "all" && lower(row.sex) !== filters.sex) continue;
      if (filters.participant_format === "virtual") continue;
      if (filters.school_id && String(row.school_id || "") !== filters.school_id) continue;
      const name = cleanText(`${row.first_name || ""} ${row.last_name || ""}`);
      const haystack = lower(`${name} ${row.reference_number} ${row.email}`);
      if (filters.search && !haystack.includes(lower(filters.search))) continue;
      records.push({
        source_kind: "student", id: row.id, name, email: row.email,
        reference_number: row.reference_number, race_category: row.distance,
        status_label: statusLabel("student", row.status)
      });
    }
  }

  const recipientMap = new Map<string, RecipientAccumulator>();
  for (const record of records) {
    const key = lower(record.email);
    let recipient = recipientMap.get(key);
    if (!recipient) {
      recipient = {
        recipient_email: cleanText(record.email), names: new Set(), references: new Set(), categories: new Set(),
        registration_ids: [], student_registration_ids: []
      };
      recipientMap.set(key, recipient);
    }
    recipient.names.add(cleanText(record.name));
    recipient.references.add(cleanText(record.reference_number));
    recipient.categories.add(cleanText(record.race_category));
    if (record.source_kind === "student") recipient.student_registration_ids.push(String(record.id));
    else recipient.registration_ids.push(String(record.id));
  }

  const recipients = [...recipientMap.values()].map((item) => ({
    recipient_email: item.recipient_email,
    runner_name: formatList(item.names),
    reference_number: [...item.references].filter(Boolean).sort().join(", "),
    race_category: [...item.categories].filter(Boolean).sort().join(", "),
    registration_ids: item.registration_ids,
    student_registration_ids: item.student_registration_ids
  })).sort((a, b) => a.runner_name.localeCompare(b.runner_name));

  const categoryCounts = new Map<string, number>();
  const statusCounts = new Map<string, number>();
  for (const row of records) {
    const category = cleanText(row.race_category) || "Unspecified";
    const status = cleanText(row.status_label);
    categoryCounts.set(category, (categoryCounts.get(category) || 0) + 1);
    statusCounts.set(status, (statusCounts.get(status) || 0) + 1);
  }

  return {
    filters,
    recipients,
    registration_count: records.length,
    categories: [...categoryCounts].map(([label, count]) => ({ label, count })).sort((a, b) => a.label.localeCompare(b.label)),
    statuses: [...statusCounts].map(([label, count]) => ({ label, count }))
  };
}

async function accessibleEvents(actor: { email: string; role: string }) {
  const allEvents = await dbAll("/rest/v1/events?select=id,name,status,enabled_modules,brand_config,event_date_value&order=event_date_value.desc.nullslast,name.asc");
  if (actor.role === "owner") return allEvents.filter(enabledForEmail);
  const assignments = await dbAll(
    `/rest/v1/event_admins?select=event_id,role&email=ilike.${encodeURIComponent(actor.email)}`
  );
  const allowed = new Set(assignments.filter((row) => ["owner", "verifier"].includes(String(row.role))).map((row) => String(row.event_id)));
  return allEvents.filter((event) => allowed.has(String(event.id)) && enabledForEmail(event));
}

async function workspace(actor: { email: string; role: string }, requestedEventId: string) {
  const events = await accessibleEvents(actor);
  if (!events.length) throw new Error("This account does not have announcement access for any event.");
  const selected = events.find((event) => String(event.id) === requestedEventId) || events[0];
  const eventId = String(selected.id);
  const [categories, campaigns, schools] = await Promise.all([
    dbAll(`/rest/v1/event_categories?select=id,name,category_type,sort_order&event_id=eq.${encodeURIComponent(eventId)}&is_deleted=eq.false&order=sort_order.asc,name.asc`),
    dbAll(`/rest/v1/runner_email_campaigns?select=id,event_id,subject,status,recipient_count,sent_count,failed_count,skipped_count,created_by,created_at,completed_at&event_id=eq.${encodeURIComponent(eventId)}&order=created_at.desc&limit=25`),
    eventId === "skm2026" ? dbAll("/rest/v1/student_schools?select=id,name&active=eq.true&order=name.asc") : Promise.resolve([])
  ]);
  return { events, selected_event: selected, categories, schools, campaigns, actor: { email: actor.email } };
}

async function insertRows(path: string, rows: JsonRecord[], size = 400) {
  for (let offset = 0; offset < rows.length; offset += size) {
    await db(path, {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify(rows.slice(offset, offset + size))
    });
  }
}

async function createCampaign(actor: { email: string; role: string }, payload: JsonRecord) {
  const subject = cleanText(payload.subject).replace(/[\r\n]+/g, " ");
  const bodyText = cleanText(payload.body_text);
  const closingText = cleanText(payload.closing_text);
  if (subject.length < 3 || subject.length > 180) throw new Error("The subject must contain 3 to 180 characters.");
  if (bodyText.length < 10 || bodyText.length > 8000) throw new Error("The message must contain 10 to 8,000 characters.");
  if (closingText.length < 2 || closingText.length > 1000) throw new Error("The closing must contain 2 to 1,000 characters.");
  const selected = await selectRecipients((payload.filters || {}) as JsonRecord);
  if (!(await canSend(actor, selected.filters.event_id))) throw new Error("You are not authorized to email this event.");
  if (!selected.recipients.length) throw new Error("No eligible recipients match these filters.");

  const inserted = await db("/rest/v1/runner_email_campaigns", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({
      event_id: selected.filters.event_id,
      subject,
      body_text: bodyText,
      closing_text: closingText,
      filters: selected.filters,
      status: "ready",
      recipient_count: selected.recipients.length,
      created_by: actor.email
    })
  }) as JsonRecord[];
  const campaign = inserted?.[0];
  if (!campaign?.id) throw new Error("The email campaign could not be created.");
  try {
    await insertRows("/rest/v1/runner_email_campaign_recipients", selected.recipients.map((recipient) => ({
      campaign_id: campaign.id,
      ...recipient
    })));
  } catch (error) {
    await db(`/rest/v1/runner_email_campaigns?id=eq.${campaign.id}`, { method: "DELETE" }).catch(() => null);
    throw error;
  }
  return { campaign_id: campaign.id, recipient_count: selected.recipients.length };
}

async function loadCampaign(actor: { email: string; role: string }, campaignId: string) {
  if (!/^[0-9a-f-]{36}$/i.test(campaignId)) throw new Error("A valid campaign ID is required.");
  const rows = await db(`/rest/v1/runner_email_campaigns?select=*&id=eq.${campaignId}&limit=1`) as JsonRecord[];
  const campaign = rows?.[0];
  if (!campaign) throw new Error("Email campaign not found.");
  if (!(await canSend(actor, String(campaign.event_id)))) throw new Error("You are not authorized to send this campaign.");
  return campaign;
}

async function refreshCampaignCounts(campaignId: string) {
  const recipients = await dbAll(
    `/rest/v1/runner_email_campaign_recipients?select=email_status&campaign_id=eq.${campaignId}`
  );
  const counts = { pending: 0, sending: 0, sent: 0, failed: 0, skipped: 0 };
  recipients.forEach((row) => {
    const key = String(row.email_status) as keyof typeof counts;
    if (key in counts) counts[key] += 1;
  });
  const unfinished = counts.pending + counts.sending;
  const status = unfinished ? "sending" : counts.failed ? "completed_with_errors" : "completed";
  await db(`/rest/v1/runner_email_campaigns?id=eq.${campaignId}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      status,
      sent_count: counts.sent,
      failed_count: counts.failed,
      skipped_count: counts.skipped,
      completed_at: unfinished ? null : new Date().toISOString(),
      updated_at: new Date().toISOString()
    })
  });
  return { ...counts, status, more: counts.pending > 0 };
}

async function finalEligibility(campaign: JsonRecord, recipients: JsonRecord[]) {
  const standardIds = recipients.flatMap((row) => Array.isArray(row.registration_ids) ? row.registration_ids.map(String) : []);
  const studentIds = recipients.flatMap((row) => Array.isArray(row.student_registration_ids) ? row.student_registration_ids.map(String) : []);
  const [standardRows, studentRows] = await Promise.all([
    standardIds.length ? dbAll(`/rest/v1/registrations?select=id,event_id,email,payment_status,voided_at&id=in.(${standardIds.join(",")})`) : Promise.resolve([]),
    studentIds.length ? dbAll(`/rest/v1/student_registrations?select=id,email,status&id=in.(${studentIds.join(",")})`) : Promise.resolve([])
  ]);
  const standard = new Map(standardRows.map((row) => [String(row.id), row]));
  const students = new Map(studentRows.map((row) => [String(row.id), row]));
  return (recipient: JsonRecord) => {
    const email = lower(recipient.recipient_email);
    const standardValid = (Array.isArray(recipient.registration_ids) ? recipient.registration_ids : []).some((id) => {
      const row = standard.get(String(id));
      return row && String(row.event_id) === String(campaign.event_id) && !row.voided_at
        && !["rejected"].includes(lower(row.payment_status)) && lower(row.email) === email;
    });
    const studentValid = String(campaign.event_id) === "skm2026"
      && (Array.isArray(recipient.student_registration_ids) ? recipient.student_registration_ids : []).some((id) => {
        const row = students.get(String(id));
        return row && !["rejected", "void", "voided"].includes(lower(row.status)) && lower(row.email) === email;
      });
    return standardValid || studentValid;
  };
}

async function processCampaign(actor: { email: string; role: string }, campaignId: string) {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) throw new Error("RESEND_API_KEY is not configured.");
  const campaign = await loadCampaign(actor, campaignId);
  const eventRows = await db(`/rest/v1/events?select=id,name,brand_config&id=eq.${encodeURIComponent(String(campaign.event_id))}&limit=1`) as JsonRecord[];
  const event = eventRows?.[0];
  if (!event) throw new Error("The campaign event no longer exists.");

  const staleBefore = encodeURIComponent(new Date(Date.now() - 10 * 60 * 1000).toISOString());
  await db(`/rest/v1/runner_email_campaign_recipients?campaign_id=eq.${campaignId}&email_status=eq.sending&updated_at=lt.${staleBefore}`, {
    method: "PATCH", body: JSON.stringify({ email_status: "pending", error_message: "Recovered after an interrupted send.", updated_at: new Date().toISOString() })
  });
  const recipients = await db(
    `/rest/v1/runner_email_campaign_recipients?select=*&campaign_id=eq.${campaignId}&email_status=eq.pending&order=created_at.asc&limit=40`
  ) as JsonRecord[];
  if (!recipients.length) return await refreshCampaignCounts(campaignId);

  if (!campaign.started_at) {
    await db(`/rest/v1/runner_email_campaigns?id=eq.${campaignId}`, {
      method: "PATCH", body: JSON.stringify({ status: "sending", started_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    });
  }
  const eligible = await finalEligibility(campaign, recipients);
  const brand = (event.brand_config || {}) as JsonRecord;
  const accentCandidate = cleanText(brand.primary_color || brand.primaryColor);
  const accent = /^#[0-9a-f]{6}$/i.test(accentCandidate) ? accentCandidate : "#0f5ea8";
  const eventName = cleanText(event.name || "Off Ground Event");
  const support = supportEmail();

  async function updateRecipient(id: string, patch: JsonRecord) {
    return db(`/rest/v1/runner_email_campaign_recipients?id=eq.${id}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() })
    });
  }

  async function sendOne(recipient: JsonRecord) {
    const id = String(recipient.id);
    if (!eligible(recipient)) {
      await updateRecipient(id, {
        email_status: "skipped",
        attempt_count: Number(recipient.attempt_count || 0) + 1,
        error_message: "Registration was voided, rejected, removed, or its email address changed before sending."
      });
      return;
    }
    await updateRecipient(id, {
      email_status: "sending",
      attempt_count: Number(recipient.attempt_count || 0) + 1,
      error_message: null
    });
    const subject = replacePlaceholders(String(campaign.subject), recipient).replace(/[\r\n]+/g, " ").slice(0, 180);
    const body = multiline(replacePlaceholders(String(campaign.body_text), recipient));
    const closing = multiline(replacePlaceholders(String(campaign.closing_text), recipient));
    const html = `<div style="font-family:Arial,sans-serif;color:#162435;line-height:1.65;max-width:680px;margin:0 auto;">
      <div style="border-top:6px solid ${accent};padding:26px 4px 8px;">
        <p style="font-size:13px;letter-spacing:0;text-transform:uppercase;color:#607286;margin:0 0 18px;">${escapeHtml(eventName)}</p>
        <p>Hello ${escapeHtml(recipient.runner_name)},</p>
        <div style="font-size:16px;">${body}</div>
        <p style="margin-top:28px;">${closing}</p>
      </div>
      <hr style="border:0;border-top:1px solid #dbe4ec;margin:24px 0 14px;">
      <p style="color:#64768a;font-size:12px;">You are receiving this announcement because this email address is linked to a ${escapeHtml(eventName)} registration (${escapeHtml(recipient.reference_number)}). For assistance, contact <a href="mailto:${escapeHtml(support)}">${escapeHtml(support)}</a>.</p>
    </div>`;
    try {
      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${resendKey}`,
          "Idempotency-Key": `runner-announcement/${campaignId}/${id}`
        },
        body: JSON.stringify({
          from: `${eventName} Team <${senderEmail()}>`,
          to: [recipient.recipient_email],
          reply_to: support,
          subject,
          html
        })
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result?.message || "The email provider rejected this message.");
      await updateRecipient(id, {
        email_status: "sent",
        sent_at: new Date().toISOString(),
        resend_email_id: result?.id || null,
        error_message: null
      });
    } catch (error) {
      await updateRecipient(id, {
        email_status: "failed",
        error_message: error instanceof Error ? error.message : String(error)
      });
    }
  }

  for (let offset = 0; offset < recipients.length; offset += 6) {
    await Promise.all(recipients.slice(offset, offset + 6).map(sendOne));
  }
  return await refreshCampaignCounts(campaignId);
}

async function retryFailed(actor: { email: string; role: string }, campaignId: string) {
  await loadCampaign(actor, campaignId);
  await db(`/rest/v1/runner_email_campaign_recipients?campaign_id=eq.${campaignId}&email_status=eq.failed`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({ email_status: "pending", error_message: null, updated_at: new Date().toISOString() })
  });
  await db(`/rest/v1/runner_email_campaigns?id=eq.${campaignId}`, {
    method: "PATCH",
    body: JSON.stringify({ status: "ready", completed_at: null, updated_at: new Date().toISOString() })
  });
  return { ok: true };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply({ error: "Method not allowed." }, 405);
  try {
    const actor = await caller(request);
    if (!actor) return reply({ error: "Sign in again to use runner announcements." }, 401);
    const body = await request.json().catch(() => ({})) as JsonRecord;
    const action = cleanText(body.action);
    if (action === "workspace") return reply(await workspace(actor, cleanText(body.event_id)));
    if (action === "preview") {
      const filters = (body.filters || {}) as JsonRecord;
      if (!(await canSend(actor, cleanText(filters.event_id)))) return reply({ error: "You are not authorized to email this event." }, 403);
      const selected = await selectRecipients(filters);
      return reply({
        filters: selected.filters,
        unique_recipient_count: selected.recipients.length,
        registration_count: selected.registration_count,
        categories: selected.categories,
        statuses: selected.statuses,
        sample: selected.recipients.slice(0, 20).map((row) => ({
          runner_name: row.runner_name,
          recipient_email: row.recipient_email.replace(/^(.{2}).*(@.*)$/, "$1***$2"),
          reference_number: row.reference_number,
          race_category: row.race_category
        }))
      });
    }
    if (action === "create") return reply(await createCampaign(actor, body), 201);
    if (action === "process") return reply(await processCampaign(actor, cleanText(body.campaign_id)));
    if (action === "retry_failed") return reply(await retryFailed(actor, cleanText(body.campaign_id)));
    return reply({ error: "Unknown announcement action." }, 400);
  } catch (error) {
    console.error(error);
    return reply({ error: error instanceof Error ? error.message : String(error) }, 400);
  }
});
