"use strict";

const SUPABASE_URL = "https://uzaxlsezfnwnlntehdwe.supabase.co";
const SUPABASE_KEY = "sb_publishable_5Sq553e_tVnLA0PDUtai4w_ZN7fx1bB";
const SESSION_KEY = "skm_bib_generator_session";
const FALLBACK_CATEGORIES = ["42K", "21K", "10K", "5K", "3K"];
const DEFAULT_LAYOUT = Object.freeze({
  number_top: 28,
  number_max_size: 35,
  nickname_top: 59,
  nickname_max_size: 16,
  text_color: "#000000"
});
const DEFAULT_10K_TEMPLATE = Object.freeze({
  event_id: "skm2026",
  category_name: "10K",
  storage_path: "/assets/bib-templates/10k-default.png",
  original_file_name: "10-0733-blank-template.png",
  image_width: 1999,
  image_height: 1529,
  ...DEFAULT_LAYOUT,
  is_bundled: true
});

const state = {
  accessToken: "",
  refreshToken: "",
  email: "",
  eventId: "skm2026",
  events: [],
  categories: [],
  productionBatches: [],
  templates: new Map(),
  runners: [],
  selected: new Set(),
  batches: [],
  activeBatch: null,
  editorCategory: "10K",
  editorDraft: { ...DEFAULT_10K_TEMPLATE },
  pendingTemplate: null,
  loading: false
};

const $ = (id) => document.getElementById(id);
const loginPanel = $("loginPanel");
const loginForm = $("loginForm");
const loginStatus = $("loginStatus");
const appStatus = $("appStatus");
const workspace = $("workspace");
const eventSelect = $("eventSelect");
const productionBatchFilter = $("productionBatchFilter");
const categoryFilter = $("categoryFilter");
const runnerSearch = $("runnerSearch");
const printStateFilter = $("printStateFilter");
const runnerRows = $("runnerRows");
const templateList = $("templateList");
const templateForm = $("templateForm");
const templateFile = $("templateFile");
const templateStatus = $("templateStatus");
const activeBatchPanel = $("activeBatchPanel");
const printRoot = $("printRoot");
const printConfirmDialog = $("printConfirmDialog");

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function setStatus(element, message = "", type = "info") {
  element.textContent = message;
  element.classList.toggle("hidden", !message);
  element.classList.toggle("error", type === "error");
  element.classList.toggle("success-message", type === "success");
}

function refreshIcons() {
  if (window.lucide) window.lucide.createIcons({ attrs: { "stroke-width": 2 } });
}

function humanDate(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return new Intl.DateTimeFormat("en-PH", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Asia/Manila"
  }).format(date);
}

function humanDateOnly(value) {
  const parts = String(value || "").split("-").map(Number);
  if (parts.length !== 3 || parts.some((part) => !Number.isFinite(part))) return "-";
  return new Intl.DateTimeFormat("en-PH", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "Asia/Manila"
  }).format(new Date(Date.UTC(parts[0], parts[1] - 1, parts[2])));
}

function slug(value) {
  return String(value || "item")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "item";
}

function normalizedCategory(value) {
  return String(value || "").trim().toUpperCase();
}

function saveSession() {
  localStorage.setItem(SESSION_KEY, JSON.stringify({
    access_token: state.accessToken,
    refresh_token: state.refreshToken,
    email: state.email
  }));
}

function clearSession() {
  state.accessToken = "";
  state.refreshToken = "";
  state.email = "";
  localStorage.removeItem(SESSION_KEY);
}

async function parseResponse(response) {
  const text = await response.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return text; }
}

function errorMessage(data, fallback) {
  if (typeof data === "string" && data.trim()) return data;
  return data?.message || data?.error_description || data?.error || data?.details || fallback;
}

async function refreshSession() {
  if (!state.refreshToken) return false;
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
    method: "POST",
    headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: state.refreshToken })
  });
  const data = await parseResponse(response);
  if (!response.ok || !data?.access_token) {
    clearSession();
    return false;
  }
  state.accessToken = data.access_token;
  state.refreshToken = data.refresh_token || state.refreshToken;
  state.email = data.user?.email || state.email;
  saveSession();
  return true;
}

async function api(path, options = {}, canRetry = true) {
  const headers = {
    apikey: SUPABASE_KEY,
    Authorization: `Bearer ${state.accessToken || SUPABASE_KEY}`,
    ...(options.headers || {})
  };
  if (typeof options.body === "string" && !headers["Content-Type"]) headers["Content-Type"] = "application/json";

  const response = await fetch(path.startsWith("http") ? path : `${SUPABASE_URL}${path}`, {
    ...options,
    headers
  });

  if (response.status === 401 && canRetry && await refreshSession()) {
    return api(path, options, false);
  }

  const data = await parseResponse(response);
  if (!response.ok) throw new Error(errorMessage(data, `Request failed (${response.status}).`));
  return data;
}

async function rpc(name, body = {}) {
  return api(`/rest/v1/rpc/${name}`, { method: "POST", body: JSON.stringify(body) });
}

async function signIn(email, password) {
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password })
  });
  const data = await parseResponse(response);
  if (!response.ok || !data?.access_token) throw new Error(errorMessage(data, "Sign in failed."));
  state.accessToken = data.access_token;
  state.refreshToken = data.refresh_token || "";
  state.email = data.user?.email || email;
  saveSession();
}

async function verifyOwner() {
  const allowed = await rpc("bib_generator_is_owner");
  if (allowed !== true) throw new Error("This generator is restricted to the owner account.");
}

function setSignedInView(signedIn) {
  loginPanel.classList.toggle("hidden", signedIn);
  workspace.classList.toggle("hidden", !signedIn);
  $("signOutButton").classList.toggle("hidden", !signedIn);
  $("connectionPill").textContent = signedIn ? state.email : "Signed out";
  $("connectionPill").classList.toggle("online", signedIn);
}

async function loadEvents() {
  try {
    const rows = await api("/rest/v1/events?select=id,name,status&order=created_at.desc");
    state.events = Array.isArray(rows) && rows.length ? rows : [{ id: "skm2026", name: "Sorsogon Kasanggayahan Marathon 2026" }];
  } catch {
    state.events = [{ id: "skm2026", name: "Sorsogon Kasanggayahan Marathon 2026" }];
  }
  if (!state.events.some((item) => item.id === state.eventId)) state.eventId = state.events[0].id;
  eventSelect.innerHTML = state.events.map((item) =>
    `<option value="${escapeHtml(item.id)}"${item.id === state.eventId ? " selected" : ""}>${escapeHtml(item.name || item.id)}</option>`
  ).join("");
}

async function loadCategories() {
  try {
    const rows = await api(`/rest/v1/event_categories?select=name,category_type,requires_bib_number,sort_order&event_id=eq.${encodeURIComponent(state.eventId)}&is_deleted=eq.false&order=sort_order.asc,name.asc`);
    state.categories = rows
      .filter((item) => String(item.category_type || "physical").toLowerCase() !== "virtual" && item.requires_bib_number !== false)
      .map((item) => item.name);
  } catch {
    state.categories = [];
  }
  if (!state.categories.length) state.categories = [...FALLBACK_CATEGORIES];
  state.categories = [...new Set(state.categories.map(normalizedCategory).filter(Boolean))];
  if (!state.categories.includes(state.editorCategory)) state.editorCategory = state.categories[0] || "10K";
  renderCategoryOptions();
}

async function loadTemplates() {
  const rows = await api(`/rest/v1/bib_templates?select=*&event_id=eq.${encodeURIComponent(state.eventId)}&order=category_name.asc`);
  state.templates = new Map((rows || []).map((item) => [normalizedCategory(item.category_name), normalizeTemplate(item)]));
  renderTemplateList();
  selectTemplateEditor(state.editorCategory);
}

async function loadProductionBatches() {
  const rows = await api(`/rest/v1/production_batches?select=id,batch_name,cutoff_start,cutoff_end,status,runner_count,created_at&event_id=eq.${encodeURIComponent(state.eventId)}&status=neq.cancelled&order=cutoff_end.desc,created_at.desc`);
  state.productionBatches = Array.isArray(rows) ? rows : [];
  renderProductionBatchOptions();
}

async function loadRunners() {
  const productionBatchId = productionBatchFilter.value;
  if (!productionBatchId) {
    state.runners = [];
    state.selected.clear();
    renderMetrics();
    renderRunners();
    return;
  }
  const runners = [];
  let offset = 0;
  while (true) {
    const page = await rpc("bib_generator_list_runners_v2", {
      p_event_id: state.eventId,
      p_production_batch_id: productionBatchId,
      p_limit: 500,
      p_offset: offset
    });
    if (!Array.isArray(page)) throw new Error("The runner list returned an invalid response.");
    runners.push(...page);
    if (page.length < 500) break;
    offset += page.length;
  }
  state.runners = runners;
  state.selected.clear();
  renderMetrics();
  renderRunners();
}

async function loadBatches() {
  state.batches = await api(`/rest/v1/bib_print_batches?select=id,batch_code,event_id,production_batch_id,production_batch_name,category_name,status,item_count,is_reprint,reprint_reason,created_by,created_at,printed_by,printed_at,cancelled_at&event_id=eq.${encodeURIComponent(state.eventId)}&order=created_at.desc&limit=150`) || [];
  renderBatches();
}

async function loadWorkspace(message = "Bib data refreshed.") {
  if (state.loading) return;
  state.loading = true;
  $("refreshButton").disabled = true;
  setStatus(appStatus, "Loading runner and print data...");
  try {
    await loadEvents();
    await loadCategories();
    await loadTemplates();
    await loadProductionBatches();
    await loadRunners();
    await loadBatches();
    setStatus(appStatus, message, "success");
  } catch (error) {
    setStatus(appStatus, error.message, "error");
  } finally {
    state.loading = false;
    $("refreshButton").disabled = false;
    refreshIcons();
  }
}

function renderCategoryOptions() {
  const current = categoryFilter.value;
  categoryFilter.innerHTML = state.categories.map((name) => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join("");
  categoryFilter.value = state.categories.includes(current) ? current : (state.categories.includes("10K") ? "10K" : state.categories[0]);
}

function renderProductionBatchOptions() {
  const current = productionBatchFilter.value;
  if (!state.productionBatches.length) {
    productionBatchFilter.innerHTML = '<option value="">No locked production batches available</option>';
    productionBatchFilter.disabled = true;
    return;
  }
  productionBatchFilter.disabled = false;
  productionBatchFilter.innerHTML = state.productionBatches.map((batch) => {
    const period = `${humanDateOnly(batch.cutoff_start)} - ${humanDateOnly(batch.cutoff_end)}`;
    const count = Number(batch.runner_count || 0).toLocaleString();
    return `<option value="${escapeHtml(batch.id)}">${escapeHtml(batch.batch_name)} | ${escapeHtml(period)} | ${count} runner${count === "1" ? "" : "s"}</option>`;
  }).join("");
  productionBatchFilter.value = state.productionBatches.some((batch) => batch.id === current)
    ? current
    : state.productionBatches[0].id;
}

function normalizeTemplate(template) {
  return {
    ...DEFAULT_LAYOUT,
    ...template,
    number_top: Number(template.number_top ?? DEFAULT_LAYOUT.number_top),
    number_max_size: Number(template.number_max_size ?? DEFAULT_LAYOUT.number_max_size),
    nickname_top: Number(template.nickname_top ?? DEFAULT_LAYOUT.nickname_top),
    nickname_max_size: Number(template.nickname_max_size ?? DEFAULT_LAYOUT.nickname_max_size),
    text_color: template.text_color || DEFAULT_LAYOUT.text_color
  };
}

function getTemplate(category, useDraft = false) {
  const normalized = normalizedCategory(category);
  if (useDraft && normalized === state.editorCategory) return normalizeTemplate(state.editorDraft);
  if (state.templates.has(normalized)) return state.templates.get(normalized);
  if (normalized === "10K" && state.eventId === "skm2026") return { ...DEFAULT_10K_TEMPLATE };
  return null;
}

function templateUrl(template) {
  const path = template?.preview_url || template?.storage_path || "";
  if (!path) return "";
  if (path.startsWith("http://") || path.startsWith("https://") || path.startsWith("blob:") || path.startsWith("/")) return path;
  return `${SUPABASE_URL}/storage/v1/object/public/site-assets/${path}`;
}

function runnerPrintState(item) {
  return item.print_state || "unprinted";
}

function renderMetrics() {
  $("eligibleCount").textContent = state.runners.length.toLocaleString();
  $("unprintedCount").textContent = state.runners.filter((item) => !item.print_state).length.toLocaleString();
  $("reservedCount").textContent = state.runners.filter((item) => item.print_state === "reserved").length.toLocaleString();
  $("printedCount").textContent = state.runners.filter((item) => item.print_state === "printed").length.toLocaleString();
}

function visibleRunners() {
  const category = normalizedCategory(categoryFilter.value);
  const query = runnerSearch.value.trim().toLowerCase();
  const printState = printStateFilter.value;
  return state.runners.filter((item) => {
    if (normalizedCategory(item.race_category) !== category) return false;
    if (printState !== "all" && runnerPrintState(item) !== printState) return false;
    if (!query) return true;
    return [item.bib_number, item.nickname, item.full_name, item.reference_number]
      .some((value) => String(value || "").toLowerCase().includes(query));
  });
}

function canSelectRunner(item) {
  if (!String(item.nickname || "").trim()) return false;
  const printState = runnerPrintState(item);
  if (printState === "reserved") return false;
  if (printState === "printed") return $("reprintToggle").checked;
  return true;
}

function renderRunners() {
  const rows = visibleRunners();
  runnerRows.innerHTML = rows.length ? rows.map((item) => {
    const printState = runnerPrintState(item);
    const selectable = canSelectRunner(item);
    const selected = state.selected.has(item.registration_id);
    const printDetail = item.print_batch_code ? `<span class="runner-reference">${escapeHtml(item.print_batch_code)}</span>` : "";
    return `<tr class="${selected ? "selected-row" : ""}" data-runner-id="${escapeHtml(item.registration_id)}">
      <td class="check-column"><input class="runner-checkbox" type="checkbox" data-runner-id="${escapeHtml(item.registration_id)}" ${selected ? "checked" : ""} ${selectable ? "" : "disabled"} aria-label="Select bib ${escapeHtml(item.bib_number)}" /></td>
      <td><strong>${escapeHtml(item.bib_number)}</strong><span class="runner-reference">${escapeHtml(item.reference_number)}</span></td>
      <td>${item.nickname ? `<strong>${escapeHtml(String(item.nickname).toUpperCase())}</strong>` : '<span class="missing-value">Missing nickname</span>'}</td>
      <td><span class="runner-name">${escapeHtml(item.full_name)}</span></td>
      <td>${escapeHtml(item.race_category)}</td>
      <td><strong>${escapeHtml(item.production_batch_name || "-")}</strong></td>
      <td><span class="state-pill ${escapeHtml(printState)}">${escapeHtml(printState)}</span>${printDetail}</td>
    </tr>`;
  }).join("") : `<tr><td colspan="7">${productionBatchFilter.value ? "No runners match these filters." : "Choose a locked production batch."}</td></tr>`;

  const selectableRows = rows.filter(canSelectRunner);
  const selectedVisible = selectableRows.filter((item) => state.selected.has(item.registration_id)).length;
  $("selectVisibleCheckbox").checked = selectableRows.length > 0 && selectedVisible === selectableRows.length;
  $("selectVisibleCheckbox").indeterminate = selectedVisible > 0 && selectedVisible < selectableRows.length;
  renderSelectionSummary();
  renderPreview();
}

function selectedRunners() {
  return state.runners.filter((item) => state.selected.has(item.registration_id));
}

function renderSelectionSummary() {
  const count = state.selected.size;
  $("selectedCount").textContent = count;
  $("sheetEstimate").textContent = `${Math.ceil(count / 2)} sheet${Math.ceil(count / 2) === 1 ? "" : "s"}`;
  const category = normalizedCategory(categoryFilter.value);
  const hasTemplate = Boolean(getTemplate(category));
  $("prepareBatchButton").disabled = count === 0 || count > 200 || !hasTemplate || !productionBatchFilter.value;
}

function selectNextRunners() {
  const desired = Math.max(1, Math.min(200, Number($("quickSelectCount").value) || 50));
  state.selected.clear();
  for (const item of visibleRunners()) {
    if (!canSelectRunner(item)) continue;
    state.selected.add(item.registration_id);
    if (state.selected.size >= desired) break;
  }
  renderRunners();
}

function clearSelectedRunners() {
  state.selected.clear();
  renderRunners();
}

function fitZone(zone, maximumPercent, minimumPercent) {
  if (!zone) return;
  const artboard = zone.closest(".bib-artboard");
  const text = zone.querySelector("span");
  if (!artboard || !text || !artboard.clientWidth) return;
  const maximum = artboard.clientWidth * (maximumPercent / 100);
  const minimum = artboard.clientWidth * (minimumPercent / 100);
  const horizontalScale = zone.classList.contains("bib-number-zone") ? 1.18 : 1.30;
  text.style.transform = `scaleX(${horizontalScale})`;
  text.style.fontSize = `${maximum}px`;
  const widthRatio = (zone.clientWidth * 0.985) / Math.max(text.scrollWidth * horizontalScale, 1);
  const heightRatio = (zone.clientHeight * 0.94) / Math.max(text.scrollHeight, 1);
  const fitted = Math.max(minimum, Math.min(maximum, maximum * Math.min(1, widthRatio, heightRatio)));
  text.style.fontSize = `${fitted}px`;
}

function fitBib(artboard) {
  const numberSize = Number(artboard.dataset.numberSize || DEFAULT_LAYOUT.number_max_size);
  const nicknameSize = Number(artboard.dataset.nicknameSize || DEFAULT_LAYOUT.nickname_max_size);
  fitZone(artboard.querySelector(".bib-number-zone"), numberSize, 10);
  fitZone(artboard.querySelector(".bib-nickname-zone"), nicknameSize, 4);
}

function fitAllBibs(root = document) {
  root.querySelectorAll(".bib-artboard").forEach(fitBib);
}

function fitPrintBibs() {
  if (!printRoot.children.length) return;
  printRoot.classList.add("print-measuring");
  void printRoot.offsetWidth;
  fitAllBibs(printRoot);
  printRoot.classList.remove("print-measuring");
}

function createBib(item, template, wrapperClass = "") {
  const wrapper = document.createElement("div");
  wrapper.className = wrapperClass || "bib-render-host";
  const artboard = document.createElement("div");
  artboard.className = "bib-artboard";
  artboard.dataset.numberSize = String(template.number_max_size);
  artboard.dataset.nicknameSize = String(template.nickname_max_size);
  artboard.style.setProperty("--number-top", `${template.number_top}%`);
  artboard.style.setProperty("--nickname-top", `${template.nickname_top}%`);
  artboard.style.setProperty("--bib-text-color", template.text_color || "#000000");
  artboard.innerHTML = `
    <img class="bib-template-image" src="${escapeHtml(templateUrl(template))}" alt="${escapeHtml(item.race_category || "Race")} bib template" />
    <div class="bib-number-zone"><span>${escapeHtml(item.bib_number || "")}</span></div>
    <div class="bib-nickname-zone"><span>${escapeHtml(String(item.nickname || "").toUpperCase())}</span></div>`;
  wrapper.appendChild(artboard);
  requestAnimationFrame(() => requestAnimationFrame(() => fitBib(artboard)));
  return wrapper;
}

function previewRunner(category) {
  const selected = selectedRunners().find((item) => normalizedCategory(item.race_category) === normalizedCategory(category));
  const first = state.runners.find((item) => normalizedCategory(item.race_category) === normalizedCategory(category));
  return selected || first || { bib_number: category === "10K" ? "10-0733" : `${category.replace("K", "")}-0001`, nickname: "JILL", race_category: category };
}

function renderPreview() {
  const category = normalizedCategory(categoryFilter.value || "10K");
  const template = getTemplate(category);
  $("previewCategory").textContent = `${category} Template`;
  $("templateState").textContent = template ? (template.is_bundled ? "Included template" : "Uploaded template") : "Template missing";
  $("templateState").classList.toggle("missing", !template);
  const frame = $("previewFrame");
  frame.innerHTML = "";
  if (!template) {
    frame.innerHTML = '<div class="bib-artboard" style="display:grid;place-items:center;color:#84202a;font-weight:800;">Upload this distance template first.</div>';
  } else {
    frame.appendChild(createBib(previewRunner(category), template));
  }
  renderSelectionSummary();
}

function renderTemplateList() {
  templateList.innerHTML = state.categories.map((category) => {
    const template = getTemplate(category);
    const label = template ? (template.is_bundled ? "Included" : "Uploaded") : "Missing";
    return `<button class="template-list-button ${state.editorCategory === category ? "active" : ""}" type="button" data-template-category="${escapeHtml(category)}">
      <span>${escapeHtml(category)}</span><small>${escapeHtml(label)}</small>
    </button>`;
  }).join("");
}

function disposePendingTemplate() {
  if (state.pendingTemplate?.previewUrl) URL.revokeObjectURL(state.pendingTemplate.previewUrl);
  state.pendingTemplate = null;
  templateFile.value = "";
}

function selectTemplateEditor(category) {
  disposePendingTemplate();
  state.editorCategory = normalizedCategory(category);
  state.editorDraft = normalizeTemplate(getTemplate(state.editorCategory) || {
    event_id: state.eventId,
    category_name: state.editorCategory,
    storage_path: "",
    ...DEFAULT_LAYOUT
  });
  $("templateEditorTitle").textContent = state.editorCategory;
  $("numberTopInput").value = state.editorDraft.number_top;
  $("numberSizeInput").value = state.editorDraft.number_max_size;
  $("nicknameTopInput").value = state.editorDraft.nickname_top;
  $("nicknameSizeInput").value = state.editorDraft.nickname_max_size;
  $("textColorInput").value = state.editorDraft.text_color;
  setStatus(templateStatus);
  renderTemplateList();
  renderTemplateEditorPreview();
}

function syncEditorDraft() {
  state.editorDraft.number_top = Number($("numberTopInput").value || DEFAULT_LAYOUT.number_top);
  state.editorDraft.number_max_size = Number($("numberSizeInput").value || DEFAULT_LAYOUT.number_max_size);
  state.editorDraft.nickname_top = Number($("nicknameTopInput").value || DEFAULT_LAYOUT.nickname_top);
  state.editorDraft.nickname_max_size = Number($("nicknameSizeInput").value || DEFAULT_LAYOUT.nickname_max_size);
  state.editorDraft.text_color = $("textColorInput").value || "#000000";
  if (state.pendingTemplate) state.editorDraft.preview_url = state.pendingTemplate.previewUrl;
  renderTemplateEditorPreview();
}

function renderTemplateEditorPreview() {
  const frame = $("templatePreview");
  frame.innerHTML = "";
  const template = normalizeTemplate(state.editorDraft);
  if (!templateUrl(template)) {
    frame.innerHTML = '<div class="bib-artboard" style="display:grid;place-items:center;color:#58708b;font-weight:800;">Choose a template image.</div>';
    return;
  }
  frame.appendChild(createBib(previewRunner(state.editorCategory), template));
}

async function inspectImageFile(file) {
  if (!file) return null;
  if (!/^image\/(png|jpeg|webp)$/i.test(file.type)) throw new Error("Use a PNG, JPG, or WebP image.");
  if (file.size > 10 * 1024 * 1024) throw new Error("The template image must be 10 MB or smaller.");
  const previewUrl = URL.createObjectURL(file);
  const dimensions = await new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight });
    image.onerror = () => reject(new Error("The selected image could not be read."));
    image.src = previewUrl;
  });
  const targetRatio = 1999 / 1529;
  const ratioDifference = Math.abs((dimensions.width / dimensions.height) - targetRatio) / targetRatio;
  if (ratioDifference > 0.02) {
    URL.revokeObjectURL(previewUrl);
    throw new Error("This image has a different shape from the bib. Export it at 1999 x 1529 or the same proportion.");
  }
  return { file, previewUrl, ...dimensions };
}

async function uploadTemplateFile(pending) {
  const filePath = `bib-templates/${slug(state.eventId)}/${slug(state.editorCategory)}/${Date.now()}-${crypto.randomUUID()}-${slug(pending.file.name)}`;
  await api(`/storage/v1/object/site-assets/${filePath}`, {
    method: "POST",
    headers: {
      "Content-Type": pending.file.type,
      "Cache-Control": "31536000",
      "x-upsert": "false"
    },
    body: pending.file
  });
  return filePath;
}

async function saveTemplate(event) {
  event.preventDefault();
  syncEditorDraft();
  setStatus(templateStatus, "Saving template...");
  const submitButton = templateForm.querySelector('button[type="submit"]');
  submitButton.disabled = true;
  try {
    let storagePath = state.editorDraft.storage_path;
    let originalName = state.editorDraft.original_file_name || "";
    let imageWidth = state.editorDraft.image_width || null;
    let imageHeight = state.editorDraft.image_height || null;
    if (state.pendingTemplate) {
      storagePath = await uploadTemplateFile(state.pendingTemplate);
      originalName = state.pendingTemplate.file.name;
      imageWidth = state.pendingTemplate.width;
      imageHeight = state.pendingTemplate.height;
    }
    if (!storagePath) throw new Error("Choose a template image before saving.");

    const payload = {
      event_id: state.eventId,
      category_name: state.editorCategory,
      storage_path: storagePath,
      original_file_name: originalName,
      image_width: imageWidth,
      image_height: imageHeight,
      number_top: Number(state.editorDraft.number_top),
      number_max_size: Number(state.editorDraft.number_max_size),
      nickname_top: Number(state.editorDraft.nickname_top),
      nickname_max_size: Number(state.editorDraft.nickname_max_size),
      text_color: state.editorDraft.text_color,
      updated_by: state.email,
      updated_at: new Date().toISOString()
    };
    const rows = await api("/rest/v1/bib_templates?on_conflict=event_id,category_name", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=representation" },
      body: JSON.stringify([payload])
    });
    const saved = normalizeTemplate(rows?.[0] || payload);
    state.templates.set(state.editorCategory, saved);
    disposePendingTemplate();
    state.editorDraft = { ...saved };
    renderTemplateList();
    renderTemplateEditorPreview();
    renderPreview();
    setStatus(templateStatus, `${state.editorCategory} template saved.`, "success");
  } catch (error) {
    setStatus(templateStatus, error.message, "error");
  } finally {
    submitButton.disabled = false;
    refreshIcons();
  }
}

async function prepareBatch() {
  const runners = selectedRunners();
  if (!runners.length) return;
  const productionBatch = state.productionBatches.find((batch) => batch.id === productionBatchFilter.value);
  if (!productionBatch) {
    setStatus(appStatus, "Choose the locked production batch being packed.", "error");
    return;
  }
  if (runners.some((runner) => runner.production_batch_id !== productionBatch.id)) {
    setStatus(appStatus, "The selection contains a runner from another production batch. Refresh and select again.", "error");
    return;
  }
  const reprint = $("reprintToggle").checked;
  const reason = $("reprintReason").value.trim();
  if (reprint && runners.some((item) => item.print_state === "printed") && reason.length < 5) {
    setStatus(appStatus, "Enter a clear reason for the reprint.", "error");
    return;
  }
  if (!getTemplate(runners[0].race_category)) {
    setStatus(appStatus, `Upload the ${runners[0].race_category} template first.`, "error");
    return;
  }
  const confirmed = window.confirm(`Reserve ${runners.length} ${runners[0].race_category} bib${runners.length === 1 ? "" : "s"} for ${productionBatch.batch_name}?`);
  if (!confirmed) return;
  $("prepareBatchButton").disabled = true;
  setStatus(appStatus, "Preparing print batch...");
  try {
    const created = await rpc("bib_generator_create_batch_v2", {
      p_event_id: state.eventId,
      p_production_batch_id: productionBatch.id,
      p_registration_ids: runners.map((item) => item.registration_id),
      p_allow_reprint: reprint,
      p_reprint_reason: reason || null
    });
    await openBatch(created.batch_id, created);
    await loadRunners();
    await loadBatches();
    setStatus(appStatus, `${created.batch_code} prepared with ${created.item_count} bibs.`, "success");
    activeBatchPanel.scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (error) {
    setStatus(appStatus, error.message, "error");
  } finally {
    renderSelectionSummary();
  }
}

async function openBatch(batchId, context = {}) {
  const batch = await rpc("bib_generator_get_batch", { p_batch_id: batchId });
  const ledgerBatch = state.batches.find((item) => item.id === batchId) || {};
  state.activeBatch = { ...ledgerBatch, ...batch, ...context };
  renderActiveBatch();
}

function renderActiveBatch() {
  const batch = state.activeBatch;
  activeBatchPanel.classList.toggle("hidden", !batch);
  if (!batch) return;
  $("activeBatchTitle").textContent = batch.batch_code;
  $("activeBatchStatus").textContent = batch.status;
  $("activeBatchStatus").className = `status-badge ${batch.status}`;
  $("activeBatchSummary").innerHTML = `
    <span><strong>${escapeHtml(batch.production_batch_name || "Legacy / not recorded")}</strong> production batch</span>
    <span><strong>${escapeHtml(batch.category_name)}</strong> distance</span>
    <span><strong>${Number(batch.item_count).toLocaleString()}</strong> bibs</span>
    <span><strong>${Math.ceil(Number(batch.item_count) / 2)}</strong> folio sheets</span>
    <span>Prepared ${escapeHtml(humanDate(batch.created_at))}</span>
    ${batch.is_reprint ? `<span><strong>Reprint:</strong> ${escapeHtml(batch.reprint_reason || "Recorded override")}</span>` : ""}`;
  const prepared = batch.status === "prepared";
  $("printBatchButton").classList.toggle("hidden", !prepared);
  $("confirmPrintedButton").classList.toggle("hidden", !prepared);
  $("cancelBatchButton").classList.toggle("hidden", !prepared);
  if (prepared) renderPrintRoot();
  refreshIcons();
}

function renderPrintRoot() {
  printRoot.innerHTML = "";
  const batch = state.activeBatch;
  if (!batch?.items?.length) return;
  const template = getTemplate(batch.category_name);
  if (!template) return;
  for (let index = 0; index < batch.items.length; index += 2) {
    const sheet = document.createElement("section");
    sheet.className = "print-sheet";
    sheet.appendChild(createBib(batch.items[index], template, "print-bib"));
    if (batch.items[index + 1]) sheet.appendChild(createBib(batch.items[index + 1], template, "print-bib"));
    else {
      const placeholder = document.createElement("div");
      placeholder.className = "print-bib-placeholder";
      sheet.appendChild(placeholder);
    }
    printRoot.appendChild(sheet);
  }
  requestAnimationFrame(() => requestAnimationFrame(fitPrintBibs));
}

async function waitForPrintImages() {
  const images = [...printRoot.querySelectorAll("img")];
  await Promise.all(images.map(async (image) => {
    if (image.complete && image.naturalWidth) return;
    if (image.decode) {
      try { await image.decode(); return; } catch { /* use load fallback */ }
    }
    await new Promise((resolve) => {
      image.addEventListener("load", resolve, { once: true });
      image.addEventListener("error", resolve, { once: true });
    });
  }));
}

async function printActiveBatch() {
  if (!state.activeBatch || state.activeBatch.status !== "prepared") return;
  const template = getTemplate(state.activeBatch.category_name);
  if (!template) {
    setStatus(appStatus, `The ${state.activeBatch.category_name} template is missing.`, "error");
    return;
  }
  renderPrintRoot();
  setStatus(appStatus, "Preparing full-resolution print pages...");
  printRoot.classList.add("print-measuring");
  try {
    await waitForPrintImages();
    fitAllBibs(printRoot);
  } finally {
    printRoot.classList.remove("print-measuring");
  }
  setStatus(appStatus);
  window.print();
  if (typeof printConfirmDialog.showModal === "function") printConfirmDialog.showModal();
}

async function confirmActiveBatchPrinted() {
  if (!state.activeBatch || state.activeBatch.status !== "prepared") return;
  const button = $("confirmPrintedButton");
  button.disabled = true;
  setStatus(appStatus, "Recording printed bibs...");
  try {
    const result = await rpc("bib_generator_mark_printed", { p_batch_id: state.activeBatch.id });
    state.activeBatch.status = "printed";
    state.activeBatch.printed_at = result.printed_at;
    renderActiveBatch();
    await loadRunners();
    await loadBatches();
    setStatus(appStatus, `${result.batch_code} marked printed. These runners are now protected from duplicate printing.`, "success");
  } catch (error) {
    setStatus(appStatus, error.message, "error");
  } finally {
    button.disabled = false;
  }
}

async function cancelActiveBatch() {
  if (!state.activeBatch || state.activeBatch.status !== "prepared") return;
  if (!window.confirm(`Cancel ${state.activeBatch.batch_code} and release its ${state.activeBatch.item_count} reserved bibs?`)) return;
  setStatus(appStatus, "Cancelling prepared batch...");
  try {
    const result = await rpc("bib_generator_cancel_batch", { p_batch_id: state.activeBatch.id });
    state.activeBatch = null;
    activeBatchPanel.classList.add("hidden");
    printRoot.innerHTML = "";
    await loadRunners();
    await loadBatches();
    setStatus(appStatus, `${result.batch_code} cancelled. Its runners are available again.`, "success");
  } catch (error) {
    setStatus(appStatus, error.message, "error");
  }
}

function renderBatches() {
  const body = $("batchRows");
  body.innerHTML = state.batches.length ? state.batches.map((batch) => `
    <tr>
      <td><span class="batch-code">${escapeHtml(batch.batch_code)}</span><span class="runner-reference">${escapeHtml(batch.created_by)}</span></td>
      <td>${escapeHtml(batch.production_batch_name || "Legacy / not recorded")}</td>
      <td>${escapeHtml(batch.category_name)}</td>
      <td>${Number(batch.item_count).toLocaleString()}</td>
      <td>${batch.is_reprint ? '<span class="state-pill reserved">Reprint</span>' : "Original"}</td>
      <td><span class="state-pill ${escapeHtml(batch.status === "prepared" ? "reserved" : batch.status)}">${escapeHtml(batch.status)}</span></td>
      <td>${escapeHtml(humanDate(batch.created_at))}</td>
      <td>${escapeHtml(humanDate(batch.printed_at))}</td>
      <td><div class="batch-actions">${batch.status === "prepared" ? `<button class="secondary" type="button" data-resume-batch="${escapeHtml(batch.id)}"><i data-lucide="play"></i><span>Resume</span></button>` : "-"}</div></td>
    </tr>`).join("") : '<tr><td colspan="9">No print batches yet.</td></tr>';
  refreshIcons();
}

function switchTab(tabName) {
  document.querySelectorAll(".tab").forEach((button) => button.classList.toggle("active", button.dataset.tab === tabName));
  document.querySelectorAll(".tab-panel").forEach((panel) => panel.classList.toggle("active", panel.dataset.panel === tabName));
}

async function handleLogin(event) {
  event.preventDefault();
  const button = loginForm.querySelector('button[type="submit"]');
  button.disabled = true;
  setStatus(loginStatus, "Signing in...");
  try {
    await signIn($("emailInput").value.trim(), $("passwordInput").value);
    await verifyOwner();
    setSignedInView(true);
    await loadWorkspace("Connected to SKM runner data.");
    $("passwordInput").value = "";
    setStatus(loginStatus);
  } catch (error) {
    clearSession();
    setSignedInView(false);
    setStatus(loginStatus, error.message, "error");
  } finally {
    button.disabled = false;
  }
}

function signOut() {
  clearSession();
  state.runners = [];
  state.productionBatches = [];
  state.batches = [];
  state.activeBatch = null;
  setSignedInView(false);
  setStatus(loginStatus, "Signed out.");
}

function startLocalPreviewMode() {
  const isLocal = ["127.0.0.1", "localhost"].includes(window.location.hostname);
  const previewMode = new URLSearchParams(window.location.search).get("demo");
  if (!isLocal || !["1", "print"].includes(previewMode)) return false;
  state.email = "local-layout-preview";
  state.categories = [...FALLBACK_CATEGORIES];
  state.productionBatches = [{
    id: "demo-production-1",
    batch_name: "Batch 1 - July 1-14",
    cutoff_start: "2026-07-01",
    cutoff_end: "2026-07-14",
    status: "in_production",
    runner_count: 2
  }];
  state.templates = new Map();
  state.runners = [
    { registration_id: "demo-1", reference_number: "SKM2026-733", bib_number: "10-0733", nickname: "JILL", full_name: "SAMPLE, JILL RUNNER", race_category: "10K", production_batch_id: "demo-production-1", production_batch_name: "Batch 1 - July 1-14", print_state: null },
    { registration_id: "demo-2", reference_number: "SKM2026-734", bib_number: "10-0734", nickname: "ALEXANDER-JAMES", full_name: "SAMPLE, ALEXANDER JAMES", race_category: "10K", production_batch_id: "demo-production-1", production_batch_name: "Batch 1 - July 1-14", print_state: null }
  ];
  setSignedInView(true);
  $("connectionPill").textContent = "Local preview";
  renderCategoryOptions();
  renderProductionBatchOptions();
  renderMetrics();
  renderRunners();
  renderTemplateList();
  selectTemplateEditor("10K");
  setStatus(appStatus, "Local layout preview. Database actions are disabled.");
  $("prepareBatchButton").disabled = true;
  if (previewMode === "print") {
    state.activeBatch = {
      id: "local-preview-batch",
      batch_code: "BIB-LOCAL-PREVIEW",
      event_id: "skm2026",
      production_batch_id: "demo-production-1",
      production_batch_name: "Batch 1 - July 1-14",
      category_name: "10K",
      status: "prepared",
      item_count: 2,
      created_at: new Date().toISOString(),
      items: state.runners.map((item) => ({
        registration_id: item.registration_id,
        bib_number: item.bib_number,
        nickname: item.nickname,
        full_name: item.full_name,
        race_category: item.race_category
      }))
    };
    renderPrintRoot();
    document.body.classList.add("local-print-preview");
  }
  return true;
}

async function restoreSavedSession() {
  try {
    const saved = JSON.parse(localStorage.getItem(SESSION_KEY) || "null");
    if (!saved?.access_token) return;
    state.accessToken = saved.access_token;
    state.refreshToken = saved.refresh_token || "";
    state.email = saved.email || "";
    await verifyOwner();
    setSignedInView(true);
    await loadWorkspace("Session restored. Bib data is current.");
  } catch {
    if (await refreshSession()) {
      try {
        await verifyOwner();
        setSignedInView(true);
        await loadWorkspace("Session restored. Bib data is current.");
        return;
      } catch { /* clear below */ }
    }
    clearSession();
    setSignedInView(false);
  }
}

loginForm.addEventListener("submit", handleLogin);
$("signOutButton").addEventListener("click", signOut);
$("refreshButton").addEventListener("click", () => loadWorkspace());
$("refreshBatchesButton").addEventListener("click", async () => {
  try { await loadBatches(); } catch (error) { setStatus(appStatus, error.message, "error"); }
});

eventSelect.addEventListener("change", async () => {
  state.eventId = eventSelect.value;
  state.activeBatch = null;
  activeBatchPanel.classList.add("hidden");
  await loadWorkspace("Event changed.");
});

document.querySelectorAll(".tab").forEach((button) => button.addEventListener("click", () => switchTab(button.dataset.tab)));

[categoryFilter, printStateFilter].forEach((element) => element.addEventListener("change", () => {
  state.selected.clear();
  renderRunners();
}));
productionBatchFilter.addEventListener("change", async () => {
  state.selected.clear();
  const selectedBatch = state.productionBatches.find((batch) => batch.id === productionBatchFilter.value);
  setStatus(appStatus, selectedBatch ? `Loading ${selectedBatch.batch_name}...` : "Choose a locked production batch.");
  try {
    await loadRunners();
    setStatus(appStatus, selectedBatch ? `${selectedBatch.batch_name} loaded.` : "", "success");
  } catch (error) {
    setStatus(appStatus, error.message, "error");
  }
});
runnerSearch.addEventListener("input", renderRunners);

runnerRows.addEventListener("change", (event) => {
  const checkbox = event.target.closest(".runner-checkbox");
  if (!checkbox) return;
  if (checkbox.checked) {
    if (state.selected.size >= 200) {
      checkbox.checked = false;
      setStatus(appStatus, "A batch is limited to 200 bibs.", "error");
      return;
    }
    state.selected.add(checkbox.dataset.runnerId);
  } else {
    state.selected.delete(checkbox.dataset.runnerId);
  }
  renderRunners();
});

$("selectVisibleCheckbox").addEventListener("change", (event) => {
  const selectable = visibleRunners().filter(canSelectRunner);
  if (event.target.checked) {
    for (const item of selectable) {
      if (state.selected.size >= 200) break;
      state.selected.add(item.registration_id);
    }
  } else {
    selectable.forEach((item) => state.selected.delete(item.registration_id));
  }
  renderRunners();
});

$("selectNextButton").addEventListener("click", selectNextRunners);
$("clearSelectionButton").addEventListener("click", clearSelectedRunners);
$("reprintToggle").addEventListener("change", (event) => {
  $("reprintReasonWrap").classList.toggle("hidden", !event.target.checked);
  if (!event.target.checked) {
    state.runners.filter((item) => item.print_state === "printed").forEach((item) => state.selected.delete(item.registration_id));
  }
  renderRunners();
});
$("prepareBatchButton").addEventListener("click", prepareBatch);
$("printBatchButton").addEventListener("click", printActiveBatch);
$("confirmPrintedButton").addEventListener("click", confirmActiveBatchPrinted);
$("cancelBatchButton").addEventListener("click", cancelActiveBatch);

templateList.addEventListener("click", (event) => {
  const button = event.target.closest("[data-template-category]");
  if (button) selectTemplateEditor(button.dataset.templateCategory);
});

templateFile.addEventListener("change", async () => {
  const file = templateFile.files[0];
  if (!file) return;
  if (state.pendingTemplate?.previewUrl) URL.revokeObjectURL(state.pendingTemplate.previewUrl);
  state.pendingTemplate = null;
  try {
    state.pendingTemplate = await inspectImageFile(file);
    state.editorDraft.preview_url = state.pendingTemplate.previewUrl;
    state.editorDraft.image_width = state.pendingTemplate.width;
    state.editorDraft.image_height = state.pendingTemplate.height;
    renderTemplateEditorPreview();
    setStatus(templateStatus, `${file.name} ready (${state.pendingTemplate.width} x ${state.pendingTemplate.height}).`, "success");
  } catch (error) {
    templateFile.value = "";
    setStatus(templateStatus, error.message, "error");
  }
});

["numberTopInput", "numberSizeInput", "nicknameTopInput", "nicknameSizeInput", "textColorInput"]
  .forEach((id) => $(id).addEventListener("input", syncEditorDraft));
templateForm.addEventListener("submit", saveTemplate);
$("resetCalibrationButton").addEventListener("click", () => {
  $("numberTopInput").value = DEFAULT_LAYOUT.number_top;
  $("numberSizeInput").value = DEFAULT_LAYOUT.number_max_size;
  $("nicknameTopInput").value = DEFAULT_LAYOUT.nickname_top;
  $("nicknameSizeInput").value = DEFAULT_LAYOUT.nickname_max_size;
  $("textColorInput").value = DEFAULT_LAYOUT.text_color;
  syncEditorDraft();
});

$("batchRows").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-resume-batch]");
  if (!button) return;
  try {
    await openBatch(button.dataset.resumeBatch);
    switchTab("runners");
    activeBatchPanel.scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (error) {
    setStatus(appStatus, error.message, "error");
  }
});

$("dialogConfirmPrinted").addEventListener("click", () => {
  setTimeout(confirmActiveBatchPrinted, 0);
});

window.addEventListener("beforeprint", () => {
  fitPrintBibs();
});

window.addEventListener("resize", () => fitAllBibs(document));

refreshIcons();
renderCategoryOptions();
renderPreview();
renderTemplateList();
selectTemplateEditor("10K");
if (!startLocalPreviewMode()) restoreSavedSession();
