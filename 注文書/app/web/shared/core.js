"use strict";

const fields = [
  "宛先会社名", "出力フォルダ名", "業務内容", "工程範囲", "技術者名",
  "単価", "固定契約", "下限時間", "上限時間", "弊社責任者", "備考"
];
const requiredFields = [
  "宛先会社名", "業務内容", "工程範囲", "技術者名", "単価",
  "固定契約", "下限時間", "上限時間", "弊社責任者"
];
const appToken = document.querySelector('meta[name="app-token"]')?.content || "";
const state = {
  targetMonth: "",
  records: [],
  selectedIds: new Set(),
  dirty: false,
  busy: false,
  outputRoot: "",
  nextId: 1,
  initialized: false,
  collapsedCompanies: new Set(),
  collapsedProjects: new Set()
};
const elements = Object.fromEntries([
  "saveState", "reloadButton", "saveButton", "generateButton", "shutdownButton",
  "addCompanyButton", "deleteCompanyButton",
  "selectOutputButton", "outputRootInput", "targetMonth", "companyCount", "projectCount", "engineerCount",
  "selectAll", "companyList", "emptyState", "clearSelectionButton", "collapseAllButton", "expandAllButton",
  "resultMessage", "toast"
].map((id) => [id, document.getElementById(id)]));

function makeId() { return `row-${state.nextId++}`; }
function text(value) { return value == null ? "" : String(value).trim(); }
function normalizedKey(...values) { return values.map((value) => text(value).toLocaleLowerCase("ja-JP")).join("\u001f"); }
function formatNumberInput(value) {
  const number = parseNumber(value);
  return number == null ? text(value) : number.toLocaleString("ja-JP", { maximumFractionDigits: 20 });
}
function parseNumber(value) {
  const normalized = text(value).replace(/[,￥¥\s]/g, "");
  if (!normalized || !/^-?\d+(?:\.\d+)?$/.test(normalized)) return null;
  const number = Number(normalized);
  return Number.isFinite(number) ? number : null;
}
function parseHours(value) { return parseNumber(text(value).replace(/[hHｈ時間]/g, "")); }
function roundedRate(price, hours, negative = false) {
  const amount = parseNumber(price);
  const time = parseHours(hours);
  if (amount == null || time == null || time <= 0) return "－";
  const rate = Math.floor((amount / time) / 10) * 10;
  return `${negative ? "-" : ""}¥${rate.toLocaleString("ja-JP")}`;
}
function safeFileName(value) {
  let safe = text(value).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/g, "");
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i.test(safe)) safe = `_${safe}`;
  return safe;
}

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
function createCollapseButton(collapsed, label, handler) {
  const button = createButton("", `collapse-toggle ${collapsed ? "is-collapsed" : "is-expanded"}`, handler);
  button.setAttribute("aria-label", `${label}を${collapsed ? "展開" : "折りたたむ"}`);
  button.setAttribute("aria-expanded", String(!collapsed));
  button.title = button.getAttribute("aria-label");
  return button;
}
function createInlineControl({ value, label, className = "", options, multiline = false, inputMode, placeholder = "", onInput, onCommit }) {
  let control;
  if (options) {
    control = document.createElement("select");
    options.forEach(([optionValue, optionLabel]) => {
      const option = document.createElement("option");
      option.value = optionValue;
      option.textContent = optionLabel;
      control.append(option);
    });
    control.value = value;
  } else if (multiline) {
    control = document.createElement("textarea");
    control.rows = 1;
    control.value = value ?? "";
  } else {
    control = document.createElement("input");
    control.type = "text";
    control.value = value ?? "";
    if (inputMode) control.inputMode = inputMode;
  }
  control.className = `inline-control ${className}`.trim();
  control.setAttribute("aria-label", label);
  control.title = label;
  if (placeholder && !options) control.placeholder = placeholder;
  const resizeMultiline = () => {
    if (!multiline) return;
    control.style.height = "auto";
    control.style.height = `${Math.min(Math.max(control.scrollHeight, 28), 120)}px`;
  };
  control.addEventListener("input", () => { resizeMultiline(); onInput?.(control.value); setDirty(); });
  control.addEventListener("change", () => { onInput?.(control.value); onCommit?.(control.value); });
  if (multiline) requestAnimationFrame(resizeMultiline);
  return control;
}
function createLabeledControl(label, control, className = "") {
  const wrapper = createElement("label", `inline-field ${className}`.trim());
  wrapper.append(createElement("span", "inline-label", label), control);
  return wrapper;
}
function createGroupSelector(records, label) {
  const checkbox = document.createElement("input");
  const ids = records.map((record) => record._id);
  const selectedCount = ids.filter((id) => state.selectedIds.has(id)).length;
  checkbox.type = "checkbox";
  checkbox.className = "group-select";
  checkbox.dataset.recordIds = ids.join(",");
  checkbox.checked = ids.length > 0 && selectedCount === ids.length;
  checkbox.indeterminate = selectedCount > 0 && selectedCount < ids.length;
  checkbox.setAttribute("aria-label", label);
  checkbox.title = label;
  checkbox.addEventListener("change", () => {
    ids.forEach((id) => checkbox.checked ? state.selectedIds.add(id) : state.selectedIds.delete(id));
    render();
  });
  return checkbox;
}

async function api(path, options = {}) {
  if (!appToken || appToken === "__APP_TOKEN__") throw new Error("画面の認証情報を取得できません。ツールを再起動してください。");
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: {
      "X-Order-Tool-Token": appToken,
      ...(options.body ? { "Content-Type": "application/json; charset=utf-8" } : {})
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
    cache: "no-store"
  });
  let data;
  try { data = await response.json(); }
  catch { throw new Error("サーバーから正しい応答を受け取れませんでした。"); }
  if (!response.ok || !data.ok) throw new Error(data.message || data.error || "処理に失敗しました。");
  return data;
}

function setDirty(dirty = true) {
  state.dirty = dirty;
  elements.saveState.className = `save-state ${dirty ? "is-dirty" : "is-saved"}`;
  elements.saveState.lastChild.textContent = dirty ? "未更新" : "更新済み";
}
function selectionScope() {
  const selected = state.records.filter((record) => state.selectedIds.has(record._id));
  const companies = new Map();
  selected.forEach((record) => {
    companies.set(normalizedKey(record.宛先会社名), text(record.宛先会社名));
  });
  const company = companies.size === 1 ? [...companies.values()][0] : "";
  const fullCompany = company && selected.length === allCompanyRecords(company).length;
  return { company, fullCompany };
}
function updateActionStates() {
  if (state.busy) return;
  const count = state.selectedIds.size;
  const scope = selectionScope();
  elements.clearSelectionButton.disabled = count === 0;
  elements.deleteCompanyButton.disabled = !scope.fullCompany;
  elements.companyList.querySelectorAll(".company-actions").forEach((actions) => {
    const companyIds = new Set((actions.dataset.recordIds || "").split(",").filter(Boolean));
    const selected = state.records.filter((record) => companyIds.has(record._id) && state.selectedIds.has(record._id));
    const projectNames = new Map(selected.map((record) => [normalizedKey(record.業務内容), text(record.業務内容)]));
    const projectName = projectNames.size === 1 ? [...projectNames.values()][0] : "";
    const deleteProjectButton = actions.querySelector(".scope-delete-project");
    if (deleteProjectButton) {
      deleteProjectButton.disabled = !projectName || selected.length !== allProjectRecords(actions.dataset.companyName, projectName).length;
    }
  });
  elements.companyList.querySelectorAll(".project-actions").forEach((actions) => {
    const ids = (actions.dataset.recordIds || "").split(",").filter(Boolean);
    const selectedCount = ids.filter((id) => state.selectedIds.has(id)).length;
    const duplicateButton = actions.querySelector(".scope-duplicate");
    const deleteEngineersButton = actions.querySelector(".scope-delete-engineers");
    if (duplicateButton) duplicateButton.disabled = selectedCount !== 1;
    if (deleteEngineersButton) deleteEngineersButton.disabled = selectedCount === 0;
  });
}
function setBusy(busy, label = "処理中") {
  state.busy = busy;
  document.body.classList.toggle("is-busy", busy);
  document.documentElement.setAttribute("aria-busy", String(busy));
  document.querySelectorAll("button,input,select,textarea").forEach((control) => { control.disabled = busy; });
  elements.saveState.className = `save-state ${busy ? "is-working" : (state.dirty ? "is-dirty" : "is-saved")}`;
  elements.saveState.lastChild.textContent = busy ? label : (state.dirty ? "未更新" : "更新済み");
  if (!busy) updateActionStates();
}
function showToast(message, isError = false) {
  elements.toast.textContent = message;
  elements.toast.classList.toggle("is-error", isError);
  elements.toast.hidden = false;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { elements.toast.hidden = true; }, isError ? 6500 : 3500);
}
function showResult(message, log = "", isError = false) {
  elements.resultMessage.textContent = [message, log].filter(Boolean).join("\n");
  elements.resultMessage.classList.toggle("is-error", isError);
}

function visibleRecords() {
  return state.records;
}
function groupRecords(records) {
  const companies = new Map();
  for (const record of records) {
    const companyKey = normalizedKey(record.宛先会社名);
    if (!companies.has(companyKey)) {
      companies.set(companyKey, { key: companyKey, name: text(record.宛先会社名), projects: new Map(), records: [] });
    }
    const company = companies.get(companyKey);
    company.records.push(record);
    const projectKey = normalizedKey(record.業務内容);
    if (!company.projects.has(projectKey)) {
      company.projects.set(projectKey, { key: projectKey, name: text(record.業務内容), records: [] });
    }
    company.projects.get(projectKey).records.push(record);
  }
  return [...companies.values()];
}
function allCompanyRecords(companyName) {
  const companyKey = normalizedKey(companyName);
  return state.records.filter((record) => normalizedKey(record.宛先会社名) === companyKey);
}
function allProjectRecords(companyName, projectName) {
  const companyKey = normalizedKey(companyName), projectKey = normalizedKey(projectName);
  return state.records.filter((record) => normalizedKey(record.宛先会社名) === companyKey && normalizedKey(record.業務内容) === projectKey);
}
function companyFolder(companyName) {
  return text(allCompanyRecords(companyName).find((record) => text(record.出力フォルダ名))?.出力フォルダ名) || text(companyName);
}
