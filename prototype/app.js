const $ = (id) => document.getElementById(id);
function pct(x) { return Math.round(x * 100) + "%"; }
async function send(path, body) {
  const r = await fetch(path, { method: "POST", body: JSON.stringify(body) });
  return r.json();
}

// --- Screenshot -> Jev schema -> local maths ---
let shotB64 = "", shotURL = "", lastSchema = {};
function setShot(dataURL) {
  shotURL = dataURL;
  shotB64 = dataURL.split(",")[1] || "";
  $("shot").src = dataURL;
  $("shot").hidden = false;
  $("scan").disabled = !shotB64;
  $("scanNote").textContent = "Screenshot ready. Read it with Jev, or just type the spot below.";
}
function shrink(img) {
  const w = img.naturalWidth || img.videoWidth, h = img.naturalHeight || img.videoHeight;
  const scale = Math.min(1, 1024 / w);
  const c = document.createElement("canvas");
  c.width = Math.round(w * scale);
  c.height = Math.round(h * scale);
  c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
  setShot(c.toDataURL("image/jpeg", 0.82));
}
function updateBar(data) {
  $("bar").hidden = false;
  const size = data.fraction ? ` ${data.fraction}x pot — put in ${data.amount}` : data.action === "CALL" ? ` ${data.amount}` : "";
  $("barAction").textContent = data.action + size;
  $("barFigs").innerHTML =
    `<span>Win <b>${pct(data.equity)}</b></span><span>Need <b>${pct(data.needed)}</b></span>` +
    `<span>Call EV <b>${data.ev_call >= 0 ? "+" : ""}${data.ev_call.toFixed(0)}</b></span>` +
    `<span>Hand <b>${data.hand}${data.draw ? " + " + data.draw : ""}</b></span>` +
    (data.outs ? `<span>Outs <b>~${data.outs}</b></span>` : "") +
    (data.spr ? `<span>SPR <b>${data.spr}</b></span>` : "") +
    `<span>vs <b>${data.villain} range</b></span>`;
  $("barWhy").textContent = data.why + (data.chart ? " " + data.chart : "");
  $("barStatus").textContent = `${data.method} · ${data.samples} hands`;
}
async function analyseNow() {
  const data = await send("/api/analyse", { hero: $("fHero").value, board: $("fBoard").value,
    pot: Number($("fPot").value), to_call: Number($("fCall").value), opponents: Number($("fOpp").value),
    stack: $("fStack").value ? Number($("fStack").value) : null });
  if (data.error) { $("verdict").textContent = data.error; $("bar").hidden = false; $("barAction").textContent = data.error; return null; }
  updateBar(data);
  const size = data.fraction ? ` ${data.fraction}x pot — put in ${data.amount}` : data.action === "CALL" ? ` ${data.amount}` : "";
  $("verdict").innerHTML = `<b style="font-size:22px">${data.action}${size}</b><br>` +
    `${data.why}<br>Hand: ${data.hand}${data.draw ? " + " + data.draw : ""}. Win chance ${pct(data.equity)}, ` +
    `need ${pct(data.needed)}, calling earns ${data.ev_call >= 0 ? "+" : ""}${data.ev_call.toFixed(1)} on average.` +
    `${data.spr ? ` Stack-to-pot (SPR): ${data.spr}.` : ""} Maths: ${data.method} vs ${data.villain} range (${data.samples} hands${data.se ? `, ±${(data.se * 196).toFixed(1)}%` : ""}). ${data.chart || ""}<br>Available to you: ${data.available.join(" / ")}`;
  $("sizes").textContent = "All pot sizes: " + data.sizes.map((s) => `${s.label} = ${s.amount}`).join(" · ");
  return data;
}
$("analyse").addEventListener("click", analyseNow);

async function scanNow() {
  $("scanNote").textContent = "Asking Jev…";
  const data = await send("/api/scan", { image: shotB64, format: "jpeg" });
  if (data.error) { $("scanNote").textContent = data.error + " You can still type the spot by hand below."; return null; }
  const s = data.schema;
  lastSchema = s;
  if (s.hero.length) $("fHero").value = s.hero.join("");
  if (s.board.length || !s.street_cards) $("fBoard").value = s.board.join("");
  const low = Object.entries(s.confidence || {}).filter(([, v]) => v !== null && v < 0.7).map(([k]) => k);
  $("schemaNote").textContent = `Jev read: hero ${s.hero.join(" ") || "?"}, board ${s.board.join(" ") || "none"}, ` +
    `${s.hero_turn > 0.5 ? "your turn, " : ""}${s.facing_bet > 0.5 ? "facing a bet. " : "no bet faced. "}` +
    (low.length ? `Check these carefully (Jev unsure): ${low.join(", ")}. ` : " ") +
    "Now type pot / to call from the pot crop below and press Get my action.";
  $("scanNote").textContent = "Schema filled. Confirm every card before trusting it.";
  if (s.pot_box && shotURL) {
    const img = new Image();
    img.onload = () => {
      const b = s.pot_box, c = $("crop"), x = c.getContext("2d");
      c.width = Math.max(1, (b.right - b.left) * img.naturalWidth);
      c.height = Math.max(1, (b.bottom - b.top) * img.naturalHeight);
      x.drawImage(img, b.left * img.naturalWidth, b.top * img.naturalHeight, c.width, c.height, 0, 0, c.width, c.height);
      c.hidden = false;
    };
    img.src = shotURL;
  }
  if ($("fPot").value) { $("barStatus").textContent = "working out the play…"; await analyseNow(); }
  else { $("bar").hidden = false; $("barAction").textContent = "Type the pot (and to-call) — then I give the exact play"; }
  return s;
}
$("scan").addEventListener("click", scanNow);

// --- Watch: pick a window once, Jev change-gate does the rest ---
let watchTimer = null, watchStream = null, watchVideo = null;
$("watch").addEventListener("click", async () => {
  if (watchTimer) {
    clearInterval(watchTimer); watchTimer = null;
    watchStream.getTracks().forEach((t) => t.stop());
    $("watch").textContent = "Watch table (auto)";
    $("scanNote").textContent = "Watching stopped.";
    $("barStatus").textContent = "not watching";
    return;
  }
  try {
    $("bar").hidden = false;
    $("barStatus").textContent = "pick your poker window…";
    $("barAction").textContent = "In the picker, choose the Chrome window/tab with your game";
    watchStream = await navigator.mediaDevices.getDisplayMedia({ video: true });
    watchVideo = document.createElement("video");
    watchVideo.srcObject = watchStream;
    await watchVideo.play();
    $("watch").textContent = "Stop watching";
    $("scanNote").textContent = "Watching: Jev checks for a board change every 3 seconds, and only re-reads the table when something changed.";
    const tick = async () => {
      shrink(watchVideo);
      if (!lastSchema.hero) { await scanNow(); return; }
      const prev = { hero: lastSchema.hero, board: lastSchema.board, pot: $("fPot").value };
      const d = await send("/api/detect", { image: shotB64, format: "jpeg", prev });
      if (d.error) { $("scanNote").textContent = d.error; return; }
      $("scanNote").textContent = `Watching… board change ${Math.round((d.board_changed || 0) * 100)}%, new hand ${Math.round((d.hero_changed || 0) * 100)}%, pot change ${Math.round((d.pot_changed || 0) * 100)}%${d.hero_turn > 0.5 ? " — your turn" : ""}.`;
      $("barStatus").textContent = d.hero_turn > 0.5 ? "your turn" : "watching";
      if ((d.pot_changed || 0) > 0.75) { $("fPot").classList.add("flash"); $("fCall").classList.add("flash"); }
      else { $("fPot").classList.remove("flash"); $("fCall").classList.remove("flash"); }
      if (d.changed) await scanNow();
    };
    watchTimer = setInterval(tick, 3000);
    tick();
  } catch (e) { $("scanNote").textContent = "Screen sharing was cancelled or is not allowed here."; }
});

// --- Pinned bar: draggable here, always-on-top via Document PiP in Chrome ---
(() => {
  let drag = null;
  $("barGrip").addEventListener("pointerdown", (e) => {
    const r = $("bar").getBoundingClientRect();
    drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
    $("bar").style.transform = "none";
  });
  addEventListener("pointermove", (e) => {
    if (!drag) return;
    $("bar").style.left = (e.clientX - drag.dx) + "px";
    $("bar").style.top = (e.clientY - drag.dy) + "px";
  });
  addEventListener("pointerup", () => { drag = null; });
})();
$("pin").addEventListener("click", async () => {
  $("bar").hidden = false;
  if (!window.documentPictureInPicture) {
    $("barWhy").textContent = "This browser has no always-on-top bar (Chrome has it). The bar above is pinned in this tab and draggable instead.";
    return;
  }
  try {
    const pip = await documentPictureInPicture.requestWindow({ width: 640, height: 190 });
    const style = document.createElement("style");
    style.textContent = `body{margin:0;background:#0b130f;color:#eef3ef;font:15px/1.4 -apple-system,"Segoe UI",sans-serif}
      #bar{position:static;width:auto;transform:none;box-shadow:none;border:none;padding:10px 14px}
      #barAction{font-size:26px;font-weight:800;color:#e8c468;line-height:1.2} #barFigs{display:flex;gap:14px;flex-wrap:wrap}
      #barFigs b{color:#e8c468} #barGrip{color:#9db5a8;font-size:12px;text-transform:uppercase;letter-spacing:.08em;display:flex;justify-content:space-between}
      .note{color:#9db5a8;font-size:13px}`;
    pip.document.head.append(style);
    pip.document.body.append($("bar"));
    pip.addEventListener("pagehide", () => document.querySelector("main").prepend($("bar")));
  } catch (e) { $("barWhy").textContent = "Pinning was cancelled. The draggable bar in this tab still works."; }
});
