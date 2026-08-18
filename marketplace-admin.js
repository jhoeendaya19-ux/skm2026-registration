(() => {
  "use strict";

  const MP_URL = "https://uzaxlsezfnwnlntehdwe.supabase.co";
  const MP_KEY = "sb_publishable_5Sq553e_tVnLA0PDUtai4w_ZN7fx1bB";
  const MP_STATUSES = [
    "pending_payment_verification", "paid", "processing", "ready_for_fulfillment",
    "attached_to_race_kit", "shipped", "completed", "cancelled", "declined"
  ];
  const MP_STATUS_LABELS = {
    pending_payment_verification: "Pending payment verification",
    paid: "Paid",
    processing: "Processing",
    ready_for_fulfillment: "Ready for fulfillment",
    attached_to_race_kit: "Attached to race kit",
    shipped: "Shipped",
    completed: "Completed",
    cancelled: "Cancelled",
    declined: "Declined"
  };
  const MP_TYPE_LABELS = { non_apparel: "Non-apparel", shirt: "Shirt", singlet: "Singlet", windbreaker: "Windbreaker" };
  const mp = { loaded: false, loading: false, orders: [], products: [], emailLogs: [], settings: null, currentOrder: null, currentImagePath: "" };
  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
  const php = (value) => `PHP ${Number(value || 0).toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const selectedEvent = () => byId("eventSelector")?.value || localStorage.getItem("skm_selected_event") || "skm2026";
  const currentEmail = () => byId("adminEmail")?.textContent?.trim() || "";
  const currentRole = () => byId("adminRole")?.textContent?.trim() || "";
  const publicAsset = (path) => !path ? "" : /^https?:/i.test(path) ? path : `${MP_URL}/storage/v1/object/public/site-assets/${path}`;
  const formatDate = (value) => value ? new Date(value).toLocaleString("en-PH", { dateStyle: "medium", timeStyle: "short" }) : "-";
  const statusLabel = (value) => MP_STATUS_LABELS[value] || String(value || "-").replaceAll("_", " ");

  function setMessage(node, message = "", type = "info") {
    if (!node) return;
    node.textContent = message;
    node.className = message ? `status visible ${type}` : "status";
  }

  async function refreshAccessToken() {
    const refreshToken = localStorage.getItem("skm_admin_refresh") || "";
    if (!refreshToken) throw new Error("Your admin session expired. Please sign in again.");
    const response = await fetch(`${MP_URL}/auth/v1/token?grant_type=refresh_token`, {
      method: "POST",
      headers: { apikey: MP_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: refreshToken })
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.access_token) throw new Error(data.error_description || "Your admin session expired. Please sign in again.");
    localStorage.setItem("skm_admin_token", data.access_token);
    if (data.refresh_token) localStorage.setItem("skm_admin_refresh", data.refresh_token);
    return data.access_token;
  }

  async function request(path, options = {}, retry = true) {
    const token = localStorage.getItem("skm_admin_token") || "";
    const headers = { apikey: MP_KEY, Authorization: `Bearer ${token}`, ...(options.headers || {}) };
    if (options.body && !(options.body instanceof Blob) && !(options.body instanceof File) && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
    const response = await fetch(`${MP_URL}${path}`, { ...options, headers });
    if (response.status === 401 && retry) {
      await refreshAccessToken();
      return request(path, options, false);
    }
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!response.ok) throw new Error(data?.message || data?.error || data?.hint || String(data || `Request failed (${response.status}).`));
    return data;
  }

  function switchMarketplacePane(name) {
    document.querySelectorAll("[data-marketplace-tab]").forEach((button) => button.classList.toggle("active", button.dataset.marketplaceTab === name));
    document.querySelectorAll("[data-marketplace-pane]").forEach((pane) => pane.classList.toggle("active", pane.dataset.marketplacePane === name));
  }

  async function loadMarketplace(force = false) {
    if (mp.loading || (mp.loaded && !force)) return;
    if (!["owner", "verifier"].includes(currentRole())) return;
    mp.loading = true;
    setMessage(byId("marketplaceStatus"), "Loading Marketplace data...");
    try {
      const eventId = encodeURIComponent(selectedEvent());
      const [settingsRows, products, orders, emailLogs] = await Promise.all([
        request(`/rest/v1/marketplace_settings?select=*&event_id=eq.${eventId}`),
        request(`/rest/v1/marketplace_products?select=*&event_id=eq.${eventId}&order=sort_order.asc,name.asc`),
        request(`/rest/v1/marketplace_orders?select=*,marketplace_order_items(*)&event_id=eq.${eventId}&order=created_at.desc`),
        request(`/rest/v1/marketplace_email_logs?select=*&event_id=eq.${eventId}&order=created_at.desc`)
      ]);
      mp.settings = settingsRows?.[0] || null;
      mp.products = products || [];
      mp.orders = orders || [];
      mp.emailLogs = emailLogs || [];
      renderSettings();
      renderProducts();
      renderOrders();
      mp.loaded = true;
      setMessage(byId("marketplaceStatus"));
    } catch (error) {
      setMessage(byId("marketplaceStatus"), `${error.message} Run SQL file 99 in Supabase if Marketplace has not been installed.`, "error");
    } finally { mp.loading = false; }
  }

  function filteredOrders() {
    const query = (byId("marketplaceOrderSearch")?.value || "").trim().toLowerCase();
    const status = byId("marketplaceOrderStatus")?.value || "";
    return mp.orders.filter((order) => {
      if (status && order.status !== status) return false;
      if (!query) return true;
      return [order.order_number, order.full_name, order.email, order.runner_reference, order.contact_number]
        .some((value) => String(value || "").toLowerCase().includes(query));
    });
  }

  function renderOrderMetrics() {
    const active = mp.orders.filter((order) => !["cancelled", "declined"].includes(order.status));
    const paid = active.filter((order) => !["pending_payment_verification"].includes(order.status));
    const cards = [
      ["Total orders", mp.orders.length],
      ["Pending verification", mp.orders.filter((order) => order.status === "pending_payment_verification").length],
      ["Submitted value", php(active.reduce((sum, order) => sum + Number(order.total_amount || 0), 0))],
      ["Verified value", php(paid.reduce((sum, order) => sum + Number(order.total_amount || 0), 0))]
    ];
    byId("marketplaceOrderMetrics").innerHTML = cards.map(([label, value]) => `<div class="marketplace-order-metric"><span>${esc(label)}</span><strong>${esc(value)}</strong></div>`).join("");
  }

  function renderOrders() {
    renderOrderMetrics();
    const rows = filteredOrders();
    byId("marketplaceOrderRows").innerHTML = rows.length ? rows.map((order) => `
      <tr>
        <td><strong>${esc(order.order_number)}</strong>${order.runner_reference ? `<br><small>${esc(order.runner_reference)}</small>` : ""}</td>
        <td><strong>${esc(order.full_name)}</strong><br><small>${esc(order.email)}</small></td>
        <td>${esc(order.fulfillment_method === "attach_to_race_kit" ? "Race kit attachment" : "J&T shipping")}</td>
        <td><strong>${esc(php(order.total_amount))}</strong></td>
        <td>${esc(String(order.payment_method || "").toUpperCase())}<br><small>${esc(order.payment_reference)}</small></td>
        <td><span class="marketplace-status-pill ${esc(order.status)}">${esc(statusLabel(order.status))}</span></td>
        <td>${esc(formatDate(order.created_at))}</td>
        <td><button class="small-btn" type="button" data-marketplace-open-order="${esc(order.id)}">Open</button></td>
      </tr>`).join("") : `<tr><td colspan="8">No Marketplace orders match the filters.</td></tr>`;
  }

  function addressText(order) {
    return [order.street_address, order.barangay_name, order.city_name, order.province_name, order.region_name, order.zip_code].filter(Boolean).join(", ");
  }

  function openOrder(orderId) {
    const order = mp.orders.find((item) => item.id === orderId);
    if (!order) return;
    mp.currentOrder = order;
    byId("marketplaceOrderDialogTitle").textContent = order.order_number;
    byId("marketplaceOrderDialogSubtitle").textContent = `${order.full_name} · ${statusLabel(order.status)}`;
    const facts = [
      ["Customer", order.full_name], ["Email", order.email], ["Contact", order.contact_number],
      ["Customer type", order.customer_type === "runner" ? "Registered runner" : "Non-runner"],
      ["Runner reference", order.runner_reference || "-"],
      ["Fulfillment", order.fulfillment_method === "attach_to_race_kit" ? "Include with race kit" : "Ship via J&T"],
      ["Shipping batch", order.fulfillment_method === "jt_shipping" ? (order.next_shipping_batch_date || "Not scheduled") : "Race-kit claiming schedule"],
      ["Delivery address", addressText(order) || "Race-kit claiming destination"],
      ["Payment", `${String(order.payment_method || "").toUpperCase()} · ${order.payment_reference}`],
      ["Total", php(order.total_amount)],
      ["Courier / tracking", order.courier ? `${order.courier} · ${order.tracking_number || "-"}` : "-"]
    ];
    const itemRows = (order.marketplace_order_items || []).map((item) => `<tr><td>${esc(item.product_name)}</td><td>${esc(MP_TYPE_LABELS[item.apparel_type] || "Non-apparel")}</td><td>${esc(item.variant || "-")}</td><td>${esc(item.quantity)}</td><td>${esc(php(item.unit_price))}</td><td>${esc(php(item.line_total))}</td></tr>`).join("");
    byId("marketplaceOrderDetail").innerHTML = `<div class="marketplace-order-grid">${facts.map(([label, value]) => `<div class="marketplace-order-fact"><span>${esc(label)}</span><strong>${esc(value)}</strong></div>`).join("")}</div><div class="marketplace-order-items table-wrap"><table><thead><tr><th>Product</th><th>Type</th><th>Size / variant</th><th>Qty</th><th>Unit price</th><th>Line total</th></tr></thead><tbody>${itemRows || '<tr><td colspan="6">No order lines found.</td></tr>'}</tbody></table></div>`;
    byId("marketplaceReviewStatus").innerHTML = MP_STATUSES.map((status) => `<option value="${status}" ${status === order.status ? "selected" : ""}>${esc(statusLabel(status))}</option>`).join("");
    byId("marketplaceReviewNote").value = order.admin_note || "";
    byId("marketplaceCourier").value = order.courier || "J&T Express";
    byId("marketplaceTrackingNumber").value = order.tracking_number || "";
    const canShip = order.fulfillment_method === "jt_shipping" && !["pending_payment_verification", "cancelled", "declined", "completed"].includes(order.status);
    byId("marketplaceMarkShipped").disabled = !canShip;
    byId("marketplaceMarkShipped").title = order.fulfillment_method === "attach_to_race_kit" ? "This order will be released with the runner's race kit." : canShip ? "" : "Verify payment before marking this order shipped.";
    const orderClosed = ["cancelled", "declined", "completed"].includes(order.status);
    byId("marketplaceCancelOrder").disabled = orderClosed;
    byId("marketplaceDeclineOrder").disabled = orderClosed;
    const emailRows = mp.emailLogs.filter((entry) => entry.order_id === order.id);
    byId("marketplaceEmailHistory").innerHTML = emailRows.length ? emailRows.map((entry) => `<div class="marketplace-email-row"><div><strong>${esc(String(entry.email_type || "").replaceAll("_", " "))}</strong><span>${esc(entry.recipient)} · ${esc(formatDate(entry.sent_at || entry.created_at))}</span></div><span class="marketplace-status-pill ${entry.status === "sent" ? "paid" : "cancelled"}">${esc(entry.status)}</span>${entry.subject ? `<small>${esc(entry.subject)}</small>` : ""}${entry.error_message ? `<small class="marketplace-email-error">${esc(entry.error_message)}</small>` : ""}</div>`).join("") : "No Marketplace emails recorded yet.";
    setMessage(byId("marketplaceOrderDialogStatus"));
    byId("marketplaceOrderDialog").showModal();
  }

  async function sendMarketplaceEmail(emailType, orderId) {
    return request("/functions/v1/send-marketplace-email", {
      method: "POST",
      body: JSON.stringify({ type: emailType, email_type: emailType, order_id: orderId })
    });
  }

  async function refreshOpenOrder(orderId) {
    await loadMarketplace(true);
    const updated = mp.orders.find((order) => order.id === orderId);
    if (updated) openOrder(updated.id);
    return updated;
  }

  async function verifyPayment() {
    const order = mp.currentOrder;
    if (!order || !confirm(`Verify payment for ${order.order_number} and email the customer that production has started?`)) return;
    const button = byId("marketplaceVerifyPayment");
    button.disabled = true;
    setMessage(byId("marketplaceOrderDialogStatus"), "Verifying payment and preparing the production email...");
    let statusSaved = false;
    try {
      await request("/rest/v1/rpc/admin_mark_marketplace_payment_verified", {
        method: "POST",
        body: JSON.stringify({ p_order_id: order.id, p_admin_note: byId("marketplaceReviewNote").value.trim() })
      });
      statusSaved = true;
      const emailResult = await sendMarketplaceEmail("payment_verified", order.id);
      await refreshOpenOrder(order.id);
      setMessage(byId("marketplaceOrderDialogStatus"), emailResult?.skipped_duplicate ? "Payment was already verified and this email had already been sent." : "Payment verified. The customer was emailed that the items are now in production.", "success");
    } catch (error) {
      if (statusSaved) await refreshOpenOrder(order.id).catch(() => null);
      setMessage(byId("marketplaceOrderDialogStatus"), statusSaved ? `Payment was verified, but the email was not sent: ${error.message}` : error.message, "error");
    } finally { button.disabled = false; }
  }

  async function markShipped() {
    const order = mp.currentOrder;
    if (!order) return;
    const courier = byId("marketplaceCourier").value.trim();
    const trackingNumber = byId("marketplaceTrackingNumber").value.trim();
    if (!courier || !trackingNumber) return setMessage(byId("marketplaceOrderDialogStatus"), "Enter both the courier and tracking number before marking this order shipped.", "error");
    if (!confirm(`Mark ${order.order_number} shipped through ${courier} and email tracking number ${trackingNumber} to the customer?`)) return;
    const button = byId("marketplaceMarkShipped");
    button.disabled = true;
    setMessage(byId("marketplaceOrderDialogStatus"), "Marking the order shipped and preparing the tracking email...");
    let statusSaved = false;
    try {
      await request("/rest/v1/rpc/admin_mark_marketplace_shipped", {
        method: "POST",
        body: JSON.stringify({ p_order_id: order.id, p_courier: courier, p_tracking_number: trackingNumber, p_admin_note: byId("marketplaceReviewNote").value.trim() })
      });
      statusSaved = true;
      const emailResult = await sendMarketplaceEmail("order_shipped", order.id);
      await refreshOpenOrder(order.id);
      setMessage(byId("marketplaceOrderDialogStatus"), emailResult?.skipped_duplicate ? "The order was already marked shipped and its shipping email had already been sent." : "Order marked shipped. The courier and tracking email was sent to the customer.", "success");
    } catch (error) {
      if (statusSaved) await refreshOpenOrder(order.id).catch(() => null);
      setMessage(byId("marketplaceOrderDialogStatus"), statusSaved ? `The order was marked shipped, but the email was not sent: ${error.message}` : error.message, "error");
    } finally { button.disabled = false; }
  }

  async function saveOrderStatus() {
    if (!mp.currentOrder) return;
    const nextStatus = byId("marketplaceReviewStatus").value;
    if (["paid", "processing"].includes(nextStatus)) return verifyPayment();
    if (nextStatus === "shipped") return markShipped();
    if (["cancelled", "declined"].includes(nextStatus)) return closeOrder(nextStatus);
    const button = byId("marketplaceSaveOrderStatus");
    button.disabled = true;
    setMessage(byId("marketplaceOrderDialogStatus"), "Saving order status...");
    try {
      await request("/rest/v1/rpc/admin_update_marketplace_order", { method: "POST", body: JSON.stringify({ p_order_id: mp.currentOrder.id, p_status: nextStatus, p_admin_note: byId("marketplaceReviewNote").value.trim() }) });
      await loadMarketplace(true);
      const updated = mp.orders.find((order) => order.id === mp.currentOrder.id);
      if (updated) openOrder(updated.id);
      setMessage(byId("marketplaceOrderDialogStatus"), "Order status saved.", "success");
    } catch (error) {
      button.disabled = false;
      setMessage(byId("marketplaceOrderDialogStatus"), error.message, "error");
    }
  }

  async function closeOrder(disposition) {
    const order = mp.currentOrder;
    if (!order) return;
    const action = disposition === "declined" ? "decline" : "cancel";
    const reason = prompt(`Reason to ${action} ${order.order_number}:`, byId("marketplaceReviewNote").value.trim());
    if (reason === null) return;
    if (!reason.trim()) return setMessage(byId("marketplaceOrderDialogStatus"), `Enter a reason before you ${action} this order.`, "error");
    if (!confirm(`${action === "decline" ? "Decline" : "Cancel"} ${order.order_number}? This removes it from active Marketplace totals and restores tracked product stock.`)) return;
    const button = disposition === "declined" ? byId("marketplaceDeclineOrder") : byId("marketplaceCancelOrder");
    button.disabled = true;
    setMessage(byId("marketplaceOrderDialogStatus"), `${action === "decline" ? "Declining" : "Cancelling"} order...`);
    try {
      await request("/rest/v1/rpc/admin_update_marketplace_order", {
        method: "POST",
        body: JSON.stringify({ p_order_id: order.id, p_status: disposition, p_admin_note: reason.trim() })
      });
      await refreshOpenOrder(order.id);
      setMessage(byId("marketplaceOrderDialogStatus"), `Order ${disposition}. It is excluded from active totals.`, "success");
    } catch (error) {
      button.disabled = false;
      setMessage(byId("marketplaceOrderDialogStatus"), error.message, "error");
    }
  }

  function normalizeMarketplaceProofPath(rawPath) {
    let value = String(rawPath || "").trim();
    if (!value) return "";
    try { if (/^https?:/i.test(value)) value = new URL(value).pathname; } catch {}
    try { value = decodeURIComponent(value); } catch {}
    value = value.split("?")[0].replace(/^\/+/, "");
    const markers = [
      "storage/v1/object/sign/payment-proofs/",
      "storage/v1/object/public/payment-proofs/",
      "storage/v1/object/authenticated/payment-proofs/",
      "object/sign/payment-proofs/",
      "object/public/payment-proofs/",
      "payment-proofs/"
    ];
    for (const marker of markers) {
      const index = value.indexOf(marker);
      if (index >= 0) return value.slice(index + marker.length).replace(/^\/+/, "");
    }
    return value;
  }

  async function openPaymentProof() {
    const path = normalizeMarketplaceProofPath(mp.currentOrder?.payment_proof_path);
    if (!path) return setMessage(byId("marketplaceOrderDialogStatus"), "This order has no payment proof path.", "error");
    const viewer = window.open("", "_blank");
    if (viewer) {
      viewer.document.write('<p style="font-family:sans-serif;padding:20px">Preparing secure payment proof...</p>');
      viewer.opener = null;
    }
    try {
      const encodedPath = path.split("/").map(encodeURIComponent).join("/");
      const result = await request(`/storage/v1/object/sign/payment-proofs/${encodedPath}`, { method: "POST", body: JSON.stringify({ expiresIn: 300 }) });
      const signed = result?.signedURL || result?.signedUrl;
      if (!signed) throw new Error("Supabase did not return a signed proof link.");
      const fileUrl = /^https?:/i.test(signed) ? signed : signed.startsWith("/storage/v1") ? `${MP_URL}${signed}` : `${MP_URL}/storage/v1${signed.startsWith("/") ? "" : "/"}${signed}`;
      if (viewer) viewer.location.href = fileUrl; else location.href = fileUrl;
    } catch (error) { if (viewer) viewer.close(); setMessage(byId("marketplaceOrderDialogStatus"), error.message, "error"); }
  }

  function printOrderLabel() {
    const order = mp.currentOrder;
    if (!order) return;
    const items = (order.marketplace_order_items || []).map((item) => `<tr><td>${esc(item.product_name)}</td><td>${esc(item.variant || "-")}</td><td>${esc(item.quantity)}</td></tr>`).join("");
    const destination = order.fulfillment_method === "attach_to_race_kit" ? `ATTACH TO RACE KIT${order.runner_reference ? ` · ${order.runner_reference}` : ""}` : `J&T · ${addressText(order)}`;
    const popup = window.open("", "_blank", "width=520,height=760");
    if (!popup) return setMessage(byId("marketplaceOrderDialogStatus"), "Allow pop-ups to print the fulfillment label.", "error");
    popup.document.write(`<!doctype html><html><head><title>${esc(order.order_number)}</title><style>@page{size:100mm 150mm;margin:4mm}*{box-sizing:border-box}body{width:92mm;margin:0;font-family:Arial,sans-serif;color:#000}.controls{margin-bottom:8px}.label{border:2px solid #000;padding:4mm}.brand{font-size:18px;font-weight:900;border-bottom:3px solid #000;padding-bottom:2mm}.order{font-size:24px;font-weight:900;margin:3mm 0}.name{font-size:20px;font-weight:900;margin-bottom:2mm}.fact{border-top:1px solid #000;padding:2mm 0;font-size:12px;overflow-wrap:anywhere}table{width:100%;border-collapse:collapse;margin-top:3mm;font-size:12px}th,td{border:1px solid #000;padding:2mm;text-align:left}th:last-child,td:last-child{text-align:center;width:12mm}.footer{margin-top:3mm;border-top:2px solid #000;padding-top:2mm;font-size:10px}@media print{.controls{display:none}}</style></head><body><div class="controls"><button onclick="window.print()">Print 100 x 150 mm Label</button></div><section class="label"><div class="brand">SKM 2026 MARKETPLACE</div><div class="order">${esc(order.order_number)}</div><div class="name">${esc(order.full_name)}</div><div class="fact"><strong>FULFILLMENT:</strong> ${esc(destination)}</div><div class="fact"><strong>CONTACT:</strong> ${esc(order.contact_number)}</div><table><thead><tr><th>ITEM</th><th>SIZE / VARIANT</th><th>QTY</th></tr></thead><tbody>${items}</tbody></table><div class="footer">Payment status: ${esc(statusLabel(order.status))}<br>Checked by: ____________________ &nbsp; Date: __________</div></section></body></html>`);
    popup.document.close();
  }

  function renderProducts() {
    const body = byId("marketplaceProductRows");
    body.innerHTML = mp.products.length ? mp.products.map((product) => `
      <tr>
        <td><div class="marketplace-product-cell">${product.image_path ? `<img class="marketplace-product-thumb" src="${esc(publicAsset(product.image_path))}" alt="">` : ""}<div><strong>${esc(product.name)}</strong><br><small>${esc(product.sku)}</small></div></div></td>
        <td>${esc(MP_TYPE_LABELS[product.apparel_type] || "Non-apparel")}</td>
        <td>${esc(php(product.price))}</td><td>${esc(Number(product.discount_percent || 0))}%</td>
        <td>${product.stock_quantity == null ? "Open" : esc(product.stock_quantity)}</td>
        <td>${product.is_active ? '<span class="marketplace-status-pill paid">Active</span>' : '<span class="marketplace-status-pill cancelled">Inactive</span>'}</td>
        <td><div class="actions"><button class="small-btn" type="button" data-marketplace-edit-product="${esc(product.id)}">Edit</button><button class="small-btn ghost-btn" type="button" data-marketplace-delete-product="${esc(product.id)}">Delete</button></div></td>
      </tr>`).join("") : '<tr><td colspan="7">No products yet. Use the form to add the first item.</td></tr>';
  }

  function resetProductForm() {
    byId("marketplaceProductForm").reset();
    byId("marketplaceProductId").value = "";
    byId("marketplaceProductActive").checked = true;
    byId("marketplaceProductDiscount").value = "0";
    byId("marketplaceProductOrder").value = "0";
    byId("marketplaceProductType").value = "non_apparel";
    byId("marketplaceProductFormTitle").textContent = "Add Product";
    byId("marketplaceCancelProductEdit").classList.add("hidden");
    byId("marketplaceProductImagePreview").textContent = "No product image selected.";
    mp.currentImagePath = "";
  }

  function editProduct(productId) {
    const product = mp.products.find((item) => item.id === productId);
    if (!product) return;
    byId("marketplaceProductId").value = product.id;
    byId("marketplaceProductSku").value = product.sku || "";
    byId("marketplaceProductName").value = product.name || "";
    byId("marketplaceProductType").value = product.apparel_type || "non_apparel";
    byId("marketplaceProductPrice").value = product.price ?? "";
    byId("marketplaceProductDiscount").value = product.discount_percent ?? 0;
    byId("marketplaceProductStock").value = product.stock_quantity ?? "";
    byId("marketplaceProductVariants").value = (product.variants || []).join(", ");
    byId("marketplaceProductOrder").value = product.sort_order ?? 0;
    byId("marketplaceProductDescription").value = product.description || "";
    byId("marketplaceProductActive").checked = Boolean(product.is_active);
    mp.currentImagePath = product.image_path || "";
    byId("marketplaceProductImagePreview").innerHTML = mp.currentImagePath ? `<img src="${esc(publicAsset(mp.currentImagePath))}" alt="Current product image">` : "No product image selected.";
    byId("marketplaceProductFormTitle").textContent = `Edit ${product.name}`;
    byId("marketplaceCancelProductEdit").classList.remove("hidden");
    byId("marketplaceProductForm").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  async function uploadProductImage(file) {
    if (!file) return mp.currentImagePath;
    if (file.size > 8 * 1024 * 1024) throw new Error("Product images must not exceed 8 MB.");
    const safe = file.name.replace(/[^a-zA-Z0-9._-]/g, "-");
    const path = `marketplace/${selectedEvent()}/${Date.now()}-${safe}`;
    await request(`/storage/v1/object/site-assets/${path.split("/").map(encodeURIComponent).join("/")}`, { method: "POST", headers: { "Content-Type": file.type || "application/octet-stream", "x-upsert": "false" }, body: file });
    return path;
  }

  async function saveProduct(event) {
    event.preventDefault();
    const form = event.currentTarget;
    if (!form.reportValidity()) return;
    const submit = form.querySelector('button[type="submit"]');
    submit.disabled = true;
    setMessage(byId("marketplaceStatus"), "Saving Marketplace product...");
    try {
      const imagePath = await uploadProductImage(byId("marketplaceProductImage").files[0]);
      const stockText = byId("marketplaceProductStock").value.trim();
      const payload = {
        event_id: selectedEvent(), sku: byId("marketplaceProductSku").value.trim().toUpperCase(), name: byId("marketplaceProductName").value.trim(),
        description: byId("marketplaceProductDescription").value.trim(), apparel_type: byId("marketplaceProductType").value,
        price: Number(byId("marketplaceProductPrice").value), discount_percent: Number(byId("marketplaceProductDiscount").value || 0),
        stock_quantity: stockText === "" ? null : Number(stockText), is_active: byId("marketplaceProductActive").checked,
        image_path: imagePath || null, variants: byId("marketplaceProductVariants").value.split(",").map((value) => value.trim()).filter(Boolean),
        sort_order: Number(byId("marketplaceProductOrder").value || 0), updated_at: new Date().toISOString()
      };
      const productId = byId("marketplaceProductId").value;
      if (productId) await request(`/rest/v1/marketplace_products?id=eq.${encodeURIComponent(productId)}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
      else await request("/rest/v1/marketplace_products", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
      resetProductForm();
      await loadMarketplace(true);
      switchMarketplacePane("products");
      setMessage(byId("marketplaceStatus"), "Marketplace product saved.", "success");
    } catch (error) { setMessage(byId("marketplaceStatus"), error.message, "error"); }
    finally { submit.disabled = false; }
  }

  async function deleteProduct(productId) {
    const product = mp.products.find((item) => item.id === productId);
    if (!product || !confirm(`Delete ${product.name}? Existing order lines will remain in historical orders.`)) return;
    try {
      await request(`/rest/v1/marketplace_products?id=eq.${encodeURIComponent(productId)}`, { method: "DELETE" });
      await loadMarketplace(true);
      switchMarketplacePane("products");
      setMessage(byId("marketplaceStatus"), "Product deleted. Existing order history was preserved.", "success");
    } catch (error) { setMessage(byId("marketplaceStatus"), error.message, "error"); }
  }

  function renderSettings() {
    const settings = mp.settings || {};
    byId("marketplaceStoreTitle").value = settings.store_title || "SKM 2026 Marketplace";
    byId("marketplaceStoreSubtitle").value = settings.store_subtitle || "Official Sorsogon Kasanggayahan Marathon merchandise.";
    byId("marketplaceShippingFee").value = settings.shipping_fee ?? 150;
    byId("marketplaceShippingStart").value = settings.shipping_batch_start_date || "2026-09-10";
    byId("marketplaceShippingInterval").value = settings.shipping_batch_interval_days ?? 10;
    byId("marketplaceStoreActive").checked = Boolean(settings.is_active);
    byId("marketplaceRunnerAttachment").checked = settings.allow_runner_kit_attachment !== false;
    byId("marketplaceSaleActive").checked = Boolean(settings.storewide_sale_active);
    byId("marketplaceSaleName").value = settings.storewide_sale_name || "";
    byId("marketplaceSalePercent").value = settings.storewide_discount_percent ?? 0;
    byId("marketplacePaymentInstructions").value = settings.payment_instructions || "Pay the exact amount, then upload a clear screenshot of the receipt with the payment reference visible.";
  }

  async function saveSettings(event) {
    event.preventDefault();
    const payload = {
      event_id: selectedEvent(), is_active: byId("marketplaceStoreActive").checked,
      store_title: byId("marketplaceStoreTitle").value.trim(), store_subtitle: byId("marketplaceStoreSubtitle").value.trim(),
      shipping_fee: Number(byId("marketplaceShippingFee").value || 0), allow_runner_kit_attachment: byId("marketplaceRunnerAttachment").checked,
      shipping_batch_start_date: byId("marketplaceShippingStart").value || "2026-09-10", shipping_batch_interval_days: Number(byId("marketplaceShippingInterval").value || 10),
      storewide_sale_active: byId("marketplaceSaleActive").checked, storewide_sale_name: byId("marketplaceSaleName").value.trim(),
      storewide_discount_percent: Number(byId("marketplaceSalePercent").value || 0), payment_instructions: byId("marketplacePaymentInstructions").value.trim(),
      updated_at: new Date().toISOString(), updated_by: currentEmail()
    };
    try {
      if (mp.settings) await request(`/rest/v1/marketplace_settings?event_id=eq.${encodeURIComponent(selectedEvent())}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
      else await request("/rest/v1/marketplace_settings", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
      await loadMarketplace(true);
      switchMarketplacePane("settings");
      setMessage(byId("marketplaceStatus"), "Marketplace settings saved. The public store will use them immediately.", "success");
    } catch (error) { setMessage(byId("marketplaceStatus"), error.message, "error"); }
  }

  function initialize() {
    const mainTab = document.querySelector('[data-admin-tab="marketplace"]');
    if (!mainTab || !byId("marketplacePanel")) return;
    window.setTimeout(() => {
      if (!["owner", "verifier"].includes(currentRole())) mainTab.classList.add("hidden");
    }, 700);
    mainTab.addEventListener("click", () => loadMarketplace());
    document.querySelectorAll("[data-marketplace-tab]").forEach((button) => button.addEventListener("click", () => switchMarketplacePane(button.dataset.marketplaceTab)));
    byId("marketplaceRefreshOrders").addEventListener("click", () => loadMarketplace(true));
    byId("marketplaceOrderSearch").addEventListener("input", renderOrders);
    byId("marketplaceOrderStatus").addEventListener("change", renderOrders);
    byId("marketplaceOrderRows").addEventListener("click", (event) => { const button = event.target.closest("[data-marketplace-open-order]"); if (button) openOrder(button.dataset.marketplaceOpenOrder); });
    byId("marketplaceCloseOrder").addEventListener("click", () => byId("marketplaceOrderDialog").close());
    byId("marketplaceSaveOrderStatus").addEventListener("click", saveOrderStatus);
    byId("marketplaceVerifyPayment").addEventListener("click", verifyPayment);
    byId("marketplaceMarkShipped").addEventListener("click", markShipped);
    byId("marketplaceCancelOrder").addEventListener("click", () => closeOrder("cancelled"));
    byId("marketplaceDeclineOrder").addEventListener("click", () => closeOrder("declined"));
    byId("marketplaceOpenProof").addEventListener("click", openPaymentProof);
    byId("marketplacePrintLabel").addEventListener("click", printOrderLabel);
    byId("marketplaceProductForm").addEventListener("submit", saveProduct);
    byId("marketplaceCancelProductEdit").addEventListener("click", resetProductForm);
    byId("marketplaceProductRows").addEventListener("click", (event) => {
      const edit = event.target.closest("[data-marketplace-edit-product]");
      const remove = event.target.closest("[data-marketplace-delete-product]");
      if (edit) editProduct(edit.dataset.marketplaceEditProduct);
      if (remove) deleteProduct(remove.dataset.marketplaceDeleteProduct);
    });
    byId("marketplaceProductImage").addEventListener("change", (event) => {
      const file = event.target.files[0];
      if (!file) return;
      const url = URL.createObjectURL(file);
      byId("marketplaceProductImagePreview").innerHTML = `<img src="${esc(url)}" alt="Selected product image">`;
    });
    byId("marketplaceSettingsForm").addEventListener("submit", saveSettings);
    byId("eventSelector")?.addEventListener("change", () => { mp.loaded = false; mp.currentOrder = null; if (document.querySelector('[data-admin-tab="marketplace"]')?.classList.contains("active")) loadMarketplace(true); });
  }

  initialize();
})();
