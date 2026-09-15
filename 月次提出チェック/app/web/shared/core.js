"use strict";

const appToken = document.querySelector('meta[name="app-token"]')?.content || "";
const state = {
  staff: [],
  targetMonth: "",
  folderPath: "",
  dirty: false,
  busy: false,
  nextId: 1,
  report: null,
  expanded: new Set(),
  problemOnly: false
};
const elements = Object.fromEntries([
  "saveState", "reloadButton", "saveStaffButton", "runCheckButton", "shutdownButton",
  "targetMonth", "folderPathInput", "selectFolderButton",
  "staffCount", "ngCount", "warnCount", "okCount",
  "staffBody", "staffEmpty", "staffBadge", "addStaffButton",
  "checkedInfo", "problemOnly", "resultWrap", "resultBody", "resultEmpty",
  "unmatchedSection", "unmatchedCount", "unmatchedList",
  "messageDialog", "messageTitle", "messageText", "copyMessageButton", "closeMessageButton", "dismissMessageButton",
  "resultMessage", "toast"
].map((id) => [id, document.getElementById(id)]));

function makeId() { return `staff-${state.nextId++}`; }
function text(value) { return value == null ? "" : String(value).trim(); }
function normalizeName(value) { return text(value).normalize("NFKC").replace(/\s+/g, "").toLowerCase(); }

function createElement(tag, className, content) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (content != null) node.textContent = content;
  return node;
}
function createButton(label, className, handler) {
  const button = createElement("button", className, label);
  button.type = "button";
  button.addEventListener("click", handler);
  return button;
}
function createIcon(pathData) {
  const namespace = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(namespace, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(namespace, "path");
  path.setAttribute("d", pathData);
  svg.append(path);
  return svg;
}

async function api(path, options = {}) {
  if (!appToken || appToken === "__APP_TOKEN__") throw new Error("画面の認証情報を取得できません。ツールを再起動してください。");
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: {
      "X-Check-Tool-Token": appToken,
      ...(options.body ? { "Content-Type": "application/json; charset=utf-8" } : {})
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
    cache: "no-store"
  });
  let data;
  try { data = await response.json(); }
  catch { throw new Error("ツールから正しい応答を受け取れませんでした。"); }
  if (!response.ok || !data.ok) throw new Error(data.message || data.error || "処理に失敗しました。");
  return data;
}

function setDirty(dirty = true) {
  state.dirty = dirty;
  elements.saveState.className = `save-state ${dirty ? "is-dirty" : "is-saved"}`;
  elements.saveState.lastChild.textContent = dirty ? "リスト未保存" : "保存済み";
}
function setBusy(busy, label = "処理中") {
  state.busy = busy;
  document.body.classList.toggle("is-busy", busy);
  document.documentElement.setAttribute("aria-busy", String(busy));
  document.querySelectorAll("button,input,select,textarea").forEach((control) => { control.disabled = busy; });
  elements.saveState.className = `save-state ${busy ? "is-working" : (state.dirty ? "is-dirty" : "is-saved")}`;
  elements.saveState.lastChild.textContent = busy ? label : (state.dirty ? "リスト未保存" : "保存済み");
}
function showToast(message, isError = false) {
  elements.toast.textContent = message;
  elements.toast.classList.toggle("is-error", isError);
  elements.toast.hidden = false;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { elements.toast.hidden = true; }, isError ? 6500 : 3500);
}
function showResult(message, detail = "", isError = false) {
  elements.resultMessage.textContent = [message, detail].filter(Boolean).join("\n");
  elements.resultMessage.classList.toggle("is-error", isError);
}
