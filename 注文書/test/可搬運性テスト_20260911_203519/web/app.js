"use strict";

const editableFields = [
  "宛先会社名", "出力フォルダ名", "業務内容", "工程範囲", "技術者名",
  "単価", "固定契約", "下限時間", "上限時間", "弊社責任者", "備考"
];
const requiredFields = [
  "宛先会社名", "業務内容", "工程範囲", "技術者名", "単価",
  "固定契約", "下限時間", "上限時間", "弊社責任者"
];
const detailFields = new Set(["出力フォルダ名", "工程範囲", "弊社責任者", "備考"]);
const appToken = document.querySelector('meta[name="app-token"]')?.content || "";
const state = {
  targetMonth: "", records: [], selectedIds: new Set(), dirty: false,
  busy: false, detailsVisible: true, outputPath: "", nextId: 1
};
const elements = Object.fromEntries([
  "targetMonth", "companyCount", "projectCount", "engineerCount", "searchInput",
  "dataTableBody", "emptyState", "selectAll", "selectionCount", "saveState",
  "reloadButton", "saveButton", "generateButton", "shutdownButton", "addButton",
  "duplicateButton", "deleteButton", "detailToggleButton", "bulkField", "bulkValue",
  "bulkApplyButton", "resultMessage", "resultLog", "logDetails", "openOutputButton", "toast"
].map((id) => [id === "dataTableBody" ? "tbody" : id, document.getElementById(id)]));

function makeId() { return `row-${state.nextId++}`; }
function text(value) { return value == null ? "" : String(value).trim(); }
function key(...values) { return values.map((v) => text(v).toLocaleLowerCase("ja-JP")).join("\u001f"); }

function parseNumber(value) {
  const normalized = text(value).replace(/[,￥¥\s]/g, "");
  if (!normalized || !/^-?\d+(?:\.\d+)?$/.test(normalized)) return null;
  const number = Number(normalized);
  return Number.isFinite(number) ? number : null;
}
function parseHours(value) { return parseNumber(text(value).replace(/[hHｈ時間]/g, "")); }
function safeFileName(value) {
  let safe = text(value).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/g, "");
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i.test(safe)) safe = `_${safe}`;
  return safe;
}
function roundedRate(price, hours, negative = false) {
  const amount = parseNumber(price);
  const time = parseHours(hours);
  if (amount == null || time == null || time <= 0) return "－";
  const rate = Math.floor((amount / time) / 10) * 10;
  return `${negative ? "-" : ""}${rate.toLocaleString("ja-JP")}`;
}

function newRecord() {
  const first = state.records[0];
  return {
    _id: makeId(), 宛先会社名: "", 出力フォルダ名: "", 業務内容: "",
    工程範囲: first?.工程範囲 || "上記業務とそれに伴う附帯作業", 技術者名: "", 単価: "",
    固定契約: "N", 下限時間: first?.下限時間 || "", 上限時間: first?.上限時間 || "",
    弊社責任者: first?.弊社責任者 || "", 備考: ""
  };
}

function visibleRecords() {
  const query = text(elements.searchInput.value).toLocaleLowerCase("ja-JP");
  if (!query) return state.records;
  return state.records.filter((record) =>
    [record.宛先会社名, record.出力フォルダ名, record.業務内容, record.技術者名]
      .some((value) => text(value).toLocaleLowerCase("ja-JP").includes(query))
  );
}

function setDirty(dirty = true) {
  state.dirty = dirty;
  elements.saveState.textContent = dirty ? "未保存" : "保存済み";
  elements.saveState.className = `status-badge ${dirty ? "status-dirty" : "status-saved"}`;
}
function updateActionStates() {
  if (state.busy) return;
  const selected = state.selectedIds.size > 0;
  elements.duplicateButton.disabled = !selected;
  elements.deleteButton.disabled = !selected;
  elements.bulkApplyButton.disabled = !selected || !elements.bulkField.value;
  elements.bulkValue.disabled = !elements.bulkField.value;
  elements.openOutputButton.disabled = !state.outputPath;
}
function setBusy(busy, label = "処理中") {
  state.busy = busy;
  document.body.classList.toggle("is-busy", busy);
  document.querySelectorAll("button,input,select").forEach((control) => { control.disabled = busy; });
  elements.saveState.textContent = busy ? label : (state.dirty ? "未保存" : "保存済み");
  elements.saveState.className = `status-badge ${busy ? "status-working" : (state.dirty ? "status-dirty" : "status-saved")}`;
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
  elements.resultMessage.textContent = message;
  elements.resultMessage.classList.toggle("result-error", isError);
  elements.resultLog.textContent = log;
  elements.logDetails.hidden = !log;
  elements.logDetails.open = Boolean(isError && log);
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
  if (!response.ok || !data.ok) throw new Error(data.error || "処理に失敗しました。");
  return data;
}

function createEditor(record, field) {
  let editor;
  if (field === "固定契約") {
    editor = document.createElement("select");
    [["Y", "Y（固定契約）"], ["N", "N（時間精算）"]].forEach(([value, label]) => {
      const option = document.createElement("option");
      option.value = value; option.textContent = label; editor.append(option);
    });
    editor.value = text(record[field]).toUpperCase() === "Y" ? "Y" : "N";
  } else {
    editor = document.createElement("input");
    editor.type = "text";
    editor.value = record[field] ?? "";
    if (["単価", "下限時間", "上限時間"].includes(field)) editor.inputMode = "decimal";
  }
  editor.setAttribute("aria-label", `${field}（${text(record.技術者名) || "新しい行"}）`);
  const change = () => {
    record[field] = editor.value;
    setDirty();
    if (["単価", "固定契約", "下限時間", "上限時間"].includes(field)) updateRates(record);
    updateMetrics(); clearValidationStyles();
  };
  editor.addEventListener("input", change);
  editor.addEventListener("change", change);
  return editor;
}

function updateRates(record) {
  const row = elements.tbody.querySelector(`tr[data-row-id="${CSS.escape(record._id)}"]`);
  if (!row) return;
  const hourly = text(record.固定契約).toUpperCase() === "N";
  row.querySelector("[data-preview='over']").textContent = hourly ? roundedRate(record.単価, record.上限時間) : "－";
  row.querySelector("[data-preview='deduction']").textContent = hourly ? roundedRate(record.単価, record.下限時間, true) : "－";
}
function appendPreview(row, type, value) {
  const cell = document.createElement("td");
  cell.className = "detail-column";
  const span = document.createElement("span");
  span.className = "rate-preview"; span.dataset.preview = type; span.textContent = value;
  cell.append(span); row.append(cell);
}

function render() {
  const records = visibleRecords();
  elements.tbody.replaceChildren();
  for (const record of records) {
    const row = document.createElement("tr");
    row.dataset.rowId = record._id;
    row.classList.toggle("is-selected", state.selectedIds.has(record._id));
    const checkCell = document.createElement("td");
    checkCell.className = "check-column";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox"; checkbox.checked = state.selectedIds.has(record._id);
    checkbox.setAttribute("aria-label", `${text(record.技術者名) || "新しい行"}を選択`);
    checkbox.addEventListener("change", () => {
      checkbox.checked ? state.selectedIds.add(record._id) : state.selectedIds.delete(record._id);
      row.classList.toggle("is-selected", checkbox.checked); updateSelectionState();
    });
    checkCell.append(checkbox); row.append(checkCell);
    for (const field of editableFields) {
      const cell = document.createElement("td");
      cell.dataset.field = field;
      if (detailFields.has(field)) cell.classList.add("detail-column");
      cell.append(createEditor(record, field)); row.append(cell);
      if (field === "上限時間") {
        const hourly = text(record.固定契約).toUpperCase() === "N";
        appendPreview(row, "over", hourly ? roundedRate(record.単価, record.上限時間) : "－");
        appendPreview(row, "deduction", hourly ? roundedRate(record.単価, record.下限時間, true) : "－");
      }
    }
    elements.tbody.append(row);
  }
  elements.emptyState.hidden = records.length > 0;
  updateMetrics(); updateSelectionState();
}

function updateMetrics() {
  const companies = new Set(state.records.map((r) => text(r.宛先会社名)).filter(Boolean));
  const projects = new Set(state.records.filter((r) => text(r.宛先会社名) && text(r.業務内容)).map((r) => key(r.宛先会社名, r.業務内容)));
  elements.companyCount.textContent = companies.size;
  elements.projectCount.textContent = projects.size;
  elements.engineerCount.textContent = state.records.length;
}
function updateSelectionState() {
  const visible = visibleRecords();
  const selectedVisible = visible.filter((r) => state.selectedIds.has(r._id)).length;
  elements.selectAll.checked = visible.length > 0 && selectedVisible === visible.length;
  elements.selectAll.indeterminate = selectedVisible > 0 && selectedVisible < visible.length;
  elements.selectionCount.textContent = `${state.selectedIds.size}件選択`;
  updateActionStates();
}
function clearValidationStyles() {
  elements.tbody.querySelectorAll(".has-error").forEach((cell) => cell.classList.remove("has-error"));
}

function validate(requireRecords = true) {
  const errors = [];
  const invalid = new Map();
  const addError = (index, field, message) => {
    errors.push(message);
    if (index >= 0) {
      if (!invalid.has(index)) invalid.set(index, new Set());
      invalid.get(index).add(field);
    }
  };
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(text(state.targetMonth))) errors.push("対象年月を選択してください。");
  if (requireRecords && state.records.length === 0) errors.push("注文データが1件もありません。");
  const duplicates = new Map();
  const foldersByCompany = new Map();
  const projectCommon = new Map();

  state.records.forEach((record, index) => {
    const row = index + 1;
    requiredFields.forEach((field) => { if (!text(record[field])) addError(index, field, `${row}行目の「${field}」が未入力です。`); });
    const contract = text(record.固定契約).toUpperCase();
    if (contract !== "Y" && contract !== "N") addError(index, "固定契約", `${row}行目の「固定契約」は Y または N を選択してください。`);
    if (/\s/.test(text(record.単価))) addError(index, "単価", `${row}行目の「単価」に空白があります。`);
    const price = parseNumber(record.単価);
    if (price == null || price < 0) addError(index, "単価", `${row}行目の「単価」が正しくありません。`);
    const lower = parseHours(record.下限時間), upper = parseHours(record.上限時間);
    if (lower == null || lower <= 0) addError(index, "下限時間", `${row}行目の「下限時間」が正しくありません。`);
    if (upper == null || upper <= 0) addError(index, "上限時間", `${row}行目の「上限時間」が正しくありません。`);
    if (lower != null && upper != null && lower >= upper) {
      addError(index, "下限時間", `${row}行目は下限時間を上限時間より小さくしてください。`);
      if (!invalid.has(index)) invalid.set(index, new Set()); invalid.get(index).add("上限時間");
    }
    if (text(record.宛先会社名) && text(record.業務内容) && text(record.技術者名)) {
      const duplicateKey = key(record.宛先会社名, record.業務内容, record.技術者名);
      if (duplicates.has(duplicateKey)) addError(index, "技術者名", `${row}行目は${duplicates.get(duplicateKey)}行目と同じ会社・業務内容・技術者名です。`);
      else duplicates.set(duplicateKey, row);
    }
    const company = text(record.宛先会社名), folder = text(record.出力フォルダ名), project = text(record.業務内容);
    if (company && folder) {
      const companyKey = key(company);
      if (!foldersByCompany.has(companyKey)) foldersByCompany.set(companyKey, { company, values: new Map(), rows: [] });
      foldersByCompany.get(companyKey).values.set(key(folder), folder); foldersByCompany.get(companyKey).rows.push(index);
    }
    if (company && project) {
      const projectKey = key(company, project);
      if (!projectCommon.has(projectKey)) projectCommon.set(projectKey, { company, project, fields: new Map() });
      ["工程範囲", "弊社責任者", "備考"].forEach((field) => {
        const value = text(record[field]); if (!value) return;
        const fields = projectCommon.get(projectKey).fields;
        if (!fields.has(field)) fields.set(field, new Map());
        if (!fields.get(field).has(key(value))) fields.get(field).set(key(value), []);
        fields.get(field).get(key(value)).push(index);
      });
    }
  });

  for (const item of foldersByCompany.values()) {
    if (item.values.size <= 1) continue;
    errors.push(`「${item.company}」の出力フォルダ名を統一してください。`);
    item.rows.forEach((index) => { if (!invalid.has(index)) invalid.set(index, new Set()); invalid.get(index).add("出力フォルダ名"); });
  }
  const folderOwners = new Map();
  [...new Set(state.records.map((r) => text(r.宛先会社名)).filter(Boolean))].forEach((company) => {
    const item = foldersByCompany.get(key(company));
    const folder = item?.values.size === 1 ? [...item.values.values()][0] : company;
    const safeFolder = safeFileName(folder);
    if (!safeFolder) errors.push(`「${company}」の出力フォルダ名に使用できる文字がありません。`);
    else if (folderOwners.has(key(safeFolder)) && folderOwners.get(key(safeFolder)) !== company) errors.push(`異なる会社の出力フォルダ名が同じ名前になります: ${folderOwners.get(key(safeFolder))} / ${company}`);
    else folderOwners.set(key(safeFolder), company);
  });
  for (const item of projectCommon.values()) {
    for (const [field, values] of item.fields) {
      if (values.size <= 1) continue;
      errors.push(`同じ会社・業務内容の「${field}」を統一してください: ${item.company} / ${item.project}`);
      for (const rows of values.values()) rows.forEach((index) => { if (!invalid.has(index)) invalid.set(index, new Set()); invalid.get(index).add(field); });
    }
  }
  return { errors: [...new Set(errors)], invalid };
}

function showValidation(validation) {
  if (validation.errors.length && text(elements.searchInput.value)) {
    elements.searchInput.value = "";
    render();
  }
  const hasHiddenError = [...validation.invalid.values()].some((fields) => [...fields].some((field) => detailFields.has(field)));
  if (hasHiddenError && !state.detailsVisible) {
    state.detailsVisible = true;
    document.body.classList.remove("hide-details");
    elements.detailToggleButton.textContent = "詳細項目を隠す";
    elements.detailToggleButton.setAttribute("aria-pressed", "true");
  }
  clearValidationStyles();
  for (const [index, fields] of validation.invalid) {
    const record = state.records[index];
    const row = elements.tbody.querySelector(`tr[data-row-id="${CSS.escape(record._id)}"]`);
    fields.forEach((field) => row?.querySelector(`[data-field="${CSS.escape(field)}"]`)?.classList.add("has-error"));
  }
  if (!validation.errors.length) return true;
  const shown = validation.errors.slice(0, 8), rest = validation.errors.length - shown.length;
  showResult("入力内容を確認してください。", `${shown.join("\n")}${rest > 0 ? `\nほか${rest}件の入力エラーがあります。` : ""}`, true);
  showToast("赤い欄を確認してください。", true);
  const firstError = elements.tbody.querySelector("td.has-error input, td.has-error select");
  if (firstError) {
    firstError.scrollIntoView({ block: "center", inline: "center" });
    firstError.focus({ preventScroll: true });
  }
  return false;
}
function payload() {
  return { targetMonth: text(state.targetMonth), records: state.records.map((r) => Object.fromEntries(editableFields.map((field) => [field, text(r[field])]))) };
}

async function loadData(confirmDiscard = false) {
  if (confirmDiscard && state.dirty && !window.confirm("保存していない変更があります。CSVから再読込してもよろしいですか？")) return;
  setBusy(true, "読込中");
  try {
    const data = await api("/api/data");
    state.targetMonth = text(data.targetMonth);
    state.records = (data.records || []).map((record) => ({ _id: makeId(), ...Object.fromEntries(editableFields.map((field) => [field, record[field] == null ? "" : String(record[field])])) }));
    state.selectedIds.clear(); elements.targetMonth.value = state.targetMonth; elements.searchInput.value = "";
    setDirty(false); render(); showResult("CSVを読み込みました。内容を確認してから注文書を作成してください。");
  } catch (error) {
    showResult("CSVを読み込めませんでした。", error.message, true); showToast(error.message, true);
  } finally { setBusy(false); }
}

async function saveData(silentSuccess = false) {
  state.targetMonth = elements.targetMonth.value;
  if (!showValidation(validate(true))) return false;
  setBusy(true, "保存中");
  try {
    await api("/api/save", { method: "POST", body: payload() }); setDirty(false);
    if (!silentSuccess) { showResult("CSVに保存しました。保存前のCSVは backup フォルダに残しています。"); showToast("CSVに保存しました。"); }
    return true;
  } catch (error) {
    showResult("CSVに保存できませんでした。", error.message, true); showToast(error.message, true); return false;
  } finally { setBusy(false); }
}

async function generateOrders() {
  state.targetMonth = elements.targetMonth.value;
  if (!showValidation(validate(true))) return;
  if (!window.confirm(`${state.targetMonth} の内容をCSVに保存してから、注文書を作成します。よろしいですか？`)) return;
  if (!await saveData(true)) return;
  setBusy(true, "作成中"); showResult("注文書を作成しています。しばらくお待ちください。");
  try {
    const result = await api("/api/generate", { method: "POST" });
    state.outputPath = text(result.outputPath);
    showResult(`注文書を作成しました。\n保存先: ${state.outputPath || "成果物フォルダ"}`, result.log || "");
    showToast("注文書の作成が完了しました。");
  } catch (error) {
    state.outputPath = ""; showResult("注文書を作成できませんでした。", error.message, true); showToast(error.message, true);
  } finally { setBusy(false); }
}

function addRow() {
  const record = newRecord(); state.records.push(record); elements.searchInput.value = "";
  state.selectedIds.clear(); state.selectedIds.add(record._id); setDirty(); render();
  requestAnimationFrame(() => elements.tbody.querySelector(`tr[data-row-id="${CSS.escape(record._id)}"] [data-field="宛先会社名"] input`)?.focus());
}
function duplicateSelected() {
  const copies = [];
  state.records = state.records.flatMap((record) => {
    if (!state.selectedIds.has(record._id)) return [record];
    const copy = { ...record, _id: makeId() };
    copies.push(copy);
    return [record, copy];
  });
  if (!copies.length) return;
  state.records.push(...copies); state.selectedIds = new Set(copies.map((r) => r._id)); elements.searchInput.value = "";
  setDirty(); render(); showToast(`${copies.length}件を複製しました。技術者名などを変更してください。`);
}
function deleteSelected() {
  const count = state.selectedIds.size;
  if (!count || !window.confirm(`選択した${count}件を一覧から削除します。\nCSVに反映するには「CSVに保存」を押してください。\n\n続けてもよろしいですか？`)) return;
  state.records = state.records.filter((r) => !state.selectedIds.has(r._id)); state.selectedIds.clear();
  setDirty(); render(); showToast(`${count}件を一覧から削除しました。`);
}

function configureBulkValue() {
  const field = elements.bulkField.value, old = elements.bulkValue;
  let replacement;
  if (field === "固定契約") {
    replacement = document.createElement("select");
    [["Y", "Y（固定契約）"], ["N", "N（時間精算）"]].forEach(([value, label]) => {
      const option = document.createElement("option"); option.value = value; option.textContent = label; replacement.append(option);
    });
  } else {
    replacement = document.createElement("input"); replacement.type = "text";
    replacement.placeholder = field ? "変更後の値" : "変更する項目を選択";
    if (["単価", "下限時間", "上限時間"].includes(field)) replacement.inputMode = "decimal";
  }
  replacement.id = "bulkValue"; replacement.disabled = !field; old.replaceWith(replacement); elements.bulkValue = replacement; updateActionStates();
}
function applyBulkEdit() {
  const field = elements.bulkField.value;
  if (!field || !state.selectedIds.size || !window.confirm(`選択した${state.selectedIds.size}件の「${field}」を一括変更します。よろしいですか？`)) return;
  state.records.filter((r) => state.selectedIds.has(r._id)).forEach((r) => { r[field] = elements.bulkValue.value; });
  setDirty(); render(); showToast(`${state.selectedIds.size}件を一括変更しました。`);
}
async function openOutput() {
  if (!state.outputPath) return;
  try { await api("/api/open-output", { method: "POST", body: { path: state.outputPath } }); }
  catch (error) { showToast(error.message, true); }
}
async function shutdown() {
  const question = state.dirty ? "保存していない変更があります。このまま終了してもよろしいですか？" : "注文書作成ツールを終了します。よろしいですか？";
  if (!window.confirm(question)) return;
  setBusy(true, "終了中");
  try { await api("/api/shutdown", { method: "POST" }); showResult("注文書作成ツールを終了しました。この画面を閉じてください。"); }
  catch (error) { showResult("終了処理でエラーが発生しました。", error.message, true); }
}

elements.targetMonth.addEventListener("change", () => { state.targetMonth = elements.targetMonth.value; setDirty(); });
elements.searchInput.addEventListener("input", () => { state.selectedIds.clear(); render(); });
elements.selectAll.addEventListener("change", () => { visibleRecords().forEach((r) => elements.selectAll.checked ? state.selectedIds.add(r._id) : state.selectedIds.delete(r._id)); render(); });
elements.reloadButton.addEventListener("click", () => loadData(true));
elements.saveButton.addEventListener("click", () => saveData(false));
elements.generateButton.addEventListener("click", generateOrders);
elements.shutdownButton.addEventListener("click", shutdown);
elements.addButton.addEventListener("click", addRow);
elements.duplicateButton.addEventListener("click", duplicateSelected);
elements.deleteButton.addEventListener("click", deleteSelected);
elements.detailToggleButton.addEventListener("click", () => {
  state.detailsVisible = !state.detailsVisible; document.body.classList.toggle("hide-details", !state.detailsVisible);
  elements.detailToggleButton.textContent = state.detailsVisible ? "詳細項目を隠す" : "詳細項目を表示";
  elements.detailToggleButton.setAttribute("aria-pressed", String(state.detailsVisible));
});
elements.bulkField.addEventListener("change", configureBulkValue);
elements.bulkApplyButton.addEventListener("click", applyBulkEdit);
elements.openOutputButton.addEventListener("click", openOutput);
window.addEventListener("beforeunload", (event) => { if (state.dirty) { event.preventDefault(); event.returnValue = ""; } });

loadData();
