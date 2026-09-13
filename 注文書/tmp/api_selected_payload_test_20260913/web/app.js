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
  outputPath: "",
  outputRoot: "",
  nextId: 1,
  dialogConfig: null,
  dialogDirty: false,
  collapsedCompanies: new Set(),
  collapsedProjects: new Set()
};
const elements = Object.fromEntries([
  "saveState", "reloadButton", "saveButton", "generateButton", "shutdownButton",
  "addCompanyButton", "selectOutputButton", "outputRootLabel", "targetMonth", "companyCount", "projectCount", "engineerCount",
  "selectAll", "displayCount", "companyList", "emptyState", "clearSelectionButton",
  "resultMessage", "resultLog", "logDetails", "openOutputButton", "editDialog", "editForm",
  "dialogEyebrow", "dialogTitle", "dialogDescription", "dialogBody", "dialogError",
  "dialogCloseButton", "dialogCancelButton", "dialogSaveButton", "toast"
].map((id) => [id, document.getElementById(id)]));

function makeId() { return `row-${state.nextId++}`; }
function text(value) { return value == null ? "" : String(value).trim(); }
function normalizedKey(...values) { return values.map((value) => text(value).toLocaleLowerCase("ja-JP")).join("\u001f"); }
function formatMoney(value) {
  const number = parseNumber(value);
  return number == null ? "－" : `¥${number.toLocaleString("ja-JP")}`;
}
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
  const button = createButton(collapsed ? "▶" : "▼", "collapse-toggle", handler);
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
  if (!response.ok || !data.ok) throw new Error(data.error || "処理に失敗しました。");
  return data;
}

function setDirty(dirty = true) {
  state.dirty = dirty;
  elements.saveState.className = `save-state ${dirty ? "is-dirty" : "is-saved"}`;
  elements.saveState.lastChild.textContent = dirty ? "未更新" : "更新済み";
}
function updateActionStates() {
  if (state.busy) return;
  const count = state.selectedIds.size;
  elements.clearSelectionButton.disabled = count === 0;
  elements.openOutputButton.disabled = !state.outputPath;
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
  elements.resultMessage.textContent = message;
  elements.resultMessage.classList.toggle("is-error", isError);
  elements.resultLog.textContent = log;
  elements.logDetails.hidden = !log;
  elements.logDetails.open = Boolean(isError && log);
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

function render() {
  const records = visibleRecords();
  const companies = groupRecords(records);
  elements.companyList.replaceChildren();
  if (records.length) {
    const unifiedList = createElement("article", "unified-list");
    for (const company of companies) {
      const companyBlock = createElement("article", "company-block");
      const companyCell = createElement("header", "company-cell");
      const identity = createElement("div", "company-identity");
      const companyRecords = allCompanyRecords(company.name);
      const companyCollapseKey = companyRecords[0]?._id || company.name;
      const companyCollapsed = state.collapsedCompanies.has(companyCollapseKey);
      companyCell.dataset.recordIds = companyRecords.map((record) => record._id).join(",");
      const nameInput = createInlineControl({
        value: company.name, label: "宛先会社名", className: "company-name-input", placeholder: "会社名を入力",
        onInput: (value) => companyRecords.forEach((record) => { record.宛先会社名 = value; }),
        onCommit: (value) => {
          const conflicts = state.records.some((record) =>
            !companyRecords.includes(record) && normalizedKey(record.宛先会社名) === normalizedKey(value)
          );
          if (text(value) && conflicts) {
            companyRecords.forEach((record) => { record.宛先会社名 = company.name; });
            showToast("同じ会社名がすでに存在します。既存会社へ案件または技術者を追加してください。", true);
          }
          render();
        }
      });
      const folderInput = createInlineControl({
        value: companyFolder(company.name), label: "出力フォルダ名", className: "company-folder-input", placeholder: "空欄の場合は会社名を使用",
        onInput: (value) => {
          companyRecords.forEach((record) => { record.出力フォルダ名 = ""; });
          if (companyRecords[0]) companyRecords[0].出力フォルダ名 = value;
        }
      });
      const nameLine = createElement("div", "company-name-line");
      nameLine.append(
        createGroupSelector(companyRecords, `${company.name || "この会社"}の技術者をすべて選択`)
      );
      const companyCount = createElement("span", "count-chip", `${companyRecords.length}名`);
      const companyCollapse = createCollapseButton(companyCollapsed, `${company.name || "この会社"}の案件`, () => {
        if (companyCollapsed) state.collapsedCompanies.delete(companyCollapseKey);
        else state.collapsedCompanies.add(companyCollapseKey);
        render();
      });
      const companyNameField = createLabeledControl("会社名", nameInput, "company-name-field");
      const companyFolderField = createLabeledControl("保存先", folderInput, "company-folder-field");
      const companyActions = createElement("div", "company-actions");
      companyActions.append(
        createButton("案件を追加", "button button-secondary scope-action scope-add", () => addProject(company.name)),
        createButton("会社を削除", "button scope-delete scope-action", () => deleteCompany(company.name))
      );
      identity.append(companyCollapse, nameLine, companyNameField, companyCount, companyFolderField, companyActions);
      companyCell.append(identity);
      companyBlock.append(companyCell);

      const projectsList = createElement("div", "projects-list");
      for (const project of company.projects.values()) {
        const fullProjectRecords = allProjectRecords(company.name, project.name);
        const common = fullProjectRecords[0] || project.records[0];
        const projectCollapseKey = common._id;
        const projectCollapsed = state.collapsedProjects.has(projectCollapseKey);
        const projectBlock = createElement("section", "project-block");
        const projectCell = createElement("header", "project-cell");
        projectCell.dataset.projectAnchorId = common._id;
        projectCell.dataset.recordIds = fullProjectRecords.map((record) => record._id).join(",");
        const projectInfo = createElement("div", "project-info project-editor-grid");
        const projectBar = createElement("div", "project-bar");
        const titleRow = createElement("div", "project-title-row");
        const projectNameInput = createInlineControl({
          value: project.name, label: "業務内容", className: "project-title-input", placeholder: "案件名を入力",
          onInput: (value) => fullProjectRecords.forEach((record) => { record.業務内容 = value; }),
          onCommit: (value) => {
            const conflicts = state.records.some((record) =>
              !fullProjectRecords.includes(record) &&
              normalizedKey(record.宛先会社名) === normalizedKey(common.宛先会社名) &&
              normalizedKey(record.業務内容) === normalizedKey(value)
            );
            if (text(value) && conflicts) {
              fullProjectRecords.forEach((record) => { record.業務内容 = project.name; });
              showToast("同じ案件名がすでに存在します。既存案件へ技術者を追加してください。", true);
            }
            render();
          }
        });
        titleRow.append(
          createGroupSelector(fullProjectRecords, `${project.name || "この案件"}の技術者をすべて選択`)
        );
        const projectNameField = createLabeledControl("案件名", projectNameInput, "project-name-field");
        const projectCount = createElement("span", "count-chip", `${fullProjectRecords.length}名`);
        const projectCollapse = createCollapseButton(projectCollapsed, `${project.name || "この案件"}の詳細`, () => {
          if (projectCollapsed) state.collapsedProjects.delete(projectCollapseKey);
          else state.collapsedProjects.add(projectCollapseKey);
          render();
        });
        const commonUpdater = (field) => (value) => fullProjectRecords.forEach((record) => { record[field] = value; });
        const range = createLabeledControl("工程", createInlineControl({ value: common.工程範囲, label: "工程範囲", className: "project-wide-input", multiline: true, placeholder: "工程範囲を入力", onInput: commonUpdater("工程範囲") }), "project-range-field");
        const manager = createLabeledControl("担当者", createInlineControl({ value: common.弊社責任者, label: "弊社責任者", className: "project-manager-input", placeholder: "責任者名を入力", onInput: commonUpdater("弊社責任者") }));
        const remarks = createLabeledControl("備考", createInlineControl({ value: common.備考, label: "備考", className: "project-wide-input", multiline: true, placeholder: "必要な場合のみ入力", onInput: commonUpdater("備考") }), "project-remarks-field");
        const projectActions = createElement("div", "project-actions");
        projectActions.dataset.recordIds = fullProjectRecords.map((record) => record._id).join(",");
        projectActions.append(
          createButton("技術者を追加", "button button-secondary scope-action scope-add", () => addEngineer(company.name, project.name)),
          createButton("複製", "button button-secondary scope-action scope-duplicate", () => duplicateProjectSelection(company.name, project.name)),
          createButton("技術者を削除", "button scope-delete scope-action scope-delete-engineers", () => deleteProjectSelection(company.name, project.name)),
          createButton("案件を削除", "button scope-delete scope-action", () => deleteProject(company.name, project.name))
        );
        projectBar.append(projectCollapse, titleRow, projectNameField, projectCount, projectActions);
        const projectFields = createElement("div", "project-fields");
        projectFields.append(range, manager, remarks);
        projectFields.hidden = projectCollapsed;
        projectInfo.append(projectBar, projectFields);
        projectCell.append(projectInfo);

        const engineerWrap = createElement("div", "engineer-table-wrap");
        const engineerTable = createElement("table", "engineer-table ledger-table");
        const colgroup = document.createElement("colgroup");
        ["select-col", "engineer-col", "price-col", "contract-col", "hours-col", "over-rate-col", "deduction-rate-col"].forEach((className) => colgroup.append(createElement("col", className)));
        const thead = document.createElement("thead");
        const head = document.createElement("tr");
        ["", "技術者", "単価", "契約", "基準時間", "超過単価", "控除単価"].forEach((label) => head.append(createElement("th", "", label)));
        thead.append(head);
        const tbody = document.createElement("tbody");
        project.records.forEach((record) => tbody.append(renderEngineerRow(record)));
        engineerTable.append(colgroup, thead, tbody);
        engineerWrap.append(engineerTable);
        engineerWrap.hidden = projectCollapsed;
        projectBlock.append(projectCell, engineerWrap);
        projectsList.append(projectBlock);
      }
      projectsList.hidden = companyCollapsed;
      companyBlock.append(projectsList);
      unifiedList.append(companyBlock);
    }
    elements.companyList.append(unifiedList);
  }

  elements.emptyState.hidden = records.length > 0;
  updateMetrics(records);
  updateSelectionState();
}

function renderEngineerRow(record) {
  const row = createElement("tr", "engineer-row");
  row.dataset.rowId = record._id;
  row.classList.toggle("is-selected", state.selectedIds.has(record._id));
  const checkbox = document.createElement("input");
  checkbox.type = "checkbox";
  checkbox.className = "engineer-select";
  checkbox.checked = state.selectedIds.has(record._id);
  checkbox.setAttribute("aria-label", `${text(record.技術者名) || "技術者"}を選択`);
  checkbox.addEventListener("change", () => {
    checkbox.checked ? state.selectedIds.add(record._id) : state.selectedIds.delete(record._id);
    row.classList.toggle("is-selected", checkbox.checked);
    updateSelectionState();
  });
  const contract = text(record.固定契約).toUpperCase() === "Y" ? "Y" : "N";
  const originalName = text(record.技術者名);
  const nameInput = createInlineControl({
    value: record.技術者名, label: "技術者名", className: "engineer-name-input", placeholder: "技術者名を入力",
    onInput: (value) => { record.技術者名 = value; },
    onCommit: (value) => {
      const duplicate = allProjectRecords(record.宛先会社名, record.業務内容)
        .some((item) => item._id !== record._id && normalizedKey(item.技術者名) === normalizedKey(value));
      if (text(value) && duplicate) {
        record.技術者名 = originalName;
        showToast("同じ案件に同じ技術者名がすでに存在します。", true);
        render();
      }
    }
  });
  const priceInput = createInlineControl({
    value: formatNumberInput(record.単価), label: "単価", className: "engineer-price-input", inputMode: "decimal", placeholder: "0",
    onInput: (value) => { record.単価 = text(value).replace(/[,￥¥]/g, ""); updateInlineRates(); }
  });
  priceInput.addEventListener("blur", () => { priceInput.value = formatNumberInput(record.単価); });
  const contractInput = createInlineControl({
    value: contract, label: "契約種別", className: "engineer-contract-input",
    options: [["Y", "固定契約"], ["N", "時間精算"]],
    onInput: (value) => { record.固定契約 = value; updateInlineRates(); }
  });
  const lowerInput = createInlineControl({ value: record.下限時間, label: "下限時間", className: "engineer-hours-input", inputMode: "decimal", placeholder: "下限", onInput: (value) => { record.下限時間 = value; updateInlineRates(); } });
  const upperInput = createInlineControl({ value: record.上限時間, label: "上限時間", className: "engineer-hours-input", inputMode: "decimal", placeholder: "上限", onInput: (value) => { record.上限時間 = value; updateInlineRates(); } });
  const hoursEditor = createElement("div", "hours-editor");
  hoursEditor.append(lowerInput, createElement("span", "hours-separator", "～"), upperInput, createElement("span", "hours-unit", "h"));
  const overRate = createElement("span", "rate-value");
  const deductionRate = createElement("span", "rate-value");
  function updateInlineRates() {
    if (text(record.固定契約).toUpperCase() === "Y") {
      overRate.textContent = "－";
      deductionRate.textContent = "－";
      overRate.title = "固定契約のため時間精算なし";
      deductionRate.title = "固定契約のため時間精算なし";
      return;
    }
    overRate.textContent = roundedRate(record.単価, record.上限時間);
    deductionRate.textContent = roundedRate(record.単価, record.下限時間, true);
    overRate.removeAttribute("title");
    deductionRate.removeAttribute("title");
  }
  updateInlineRates();
  const selectCell = createElement("td", "select-cell");
  const nameCell = createElement("td", "engineer-cell");
  const priceCell = createElement("td", "price-cell");
  const contractCell = createElement("td", "contract-cell");
  const hoursCell = createElement("td", "hours-cell");
  const overRateCell = createElement("td", "rate-cell over-rate-cell");
  const deductionRateCell = createElement("td", "rate-cell deduction-rate-cell");
  selectCell.append(checkbox);
  nameCell.append(nameInput);
  priceCell.append(priceInput);
  contractCell.append(contractInput);
  hoursCell.append(hoursEditor);
  overRateCell.append(overRate);
  deductionRateCell.append(deductionRate);
  row.append(selectCell, nameCell, priceCell, contractCell, hoursCell, overRateCell, deductionRateCell);
  return row;
}

function updateMetrics(visible) {
  const companies = new Set(state.records.map((record) => text(record.宛先会社名)).filter(Boolean));
  const projects = new Set(state.records.filter((record) => text(record.宛先会社名) && text(record.業務内容)).map((record) => normalizedKey(record.宛先会社名, record.業務内容)));
  elements.companyCount.textContent = companies.size;
  elements.projectCount.textContent = projects.size;
  elements.engineerCount.textContent = state.records.length;
  elements.displayCount.textContent = `${visible.length}件を表示`;
}
function updateSelectionState() {
  const visible = visibleRecords();
  const selectedVisible = visible.filter((record) => state.selectedIds.has(record._id)).length;
  elements.selectAll.checked = visible.length > 0 && selectedVisible === visible.length;
  elements.selectAll.indeterminate = selectedVisible > 0 && selectedVisible < visible.length;
  elements.companyList.querySelectorAll(".group-select").forEach((checkbox) => {
    const ids = (checkbox.dataset.recordIds || "").split(",").filter(Boolean);
    const count = ids.filter((id) => state.selectedIds.has(id)).length;
    checkbox.checked = ids.length > 0 && count === ids.length;
    checkbox.indeterminate = count > 0 && count < ids.length;
  });
  elements.companyList.querySelectorAll(".company-cell, .project-cell").forEach((cell) => {
    const ids = (cell.dataset.recordIds || "").split(",").filter(Boolean);
    const count = ids.filter((id) => state.selectedIds.has(id)).length;
    cell.classList.toggle("is-selected", ids.length > 0 && count === ids.length);
    cell.classList.toggle("is-partially-selected", count > 0 && count < ids.length);
  });
  updateActionStates();
}

function fieldControl(definition, value) {
  let control;
  if (definition.options) {
    control = document.createElement("select");
    for (const [optionValue, label] of definition.options) {
      const option = document.createElement("option");
      option.value = optionValue;
      option.textContent = label;
      control.append(option);
    }
    control.value = value ?? "";
  } else if (definition.type === "textarea") {
    control = document.createElement("textarea");
    control.value = value ?? "";
  } else {
    control = document.createElement("input");
    control.type = "text";
    control.value = value ?? "";
    if (definition.inputMode) control.inputMode = definition.inputMode;
  }
  control.dataset.fieldName = definition.name;
  if (definition.placeholder) control.placeholder = definition.placeholder;
  if (definition.required) control.required = true;
  return control;
}

function openEditor({ eyebrow, title, description, definitions, values, saveLabel = "変更を反映", onSubmit }) {
  state.dialogConfig = { definitions, onSubmit };
  state.dialogDirty = false;
  elements.dialogEyebrow.textContent = eyebrow;
  elements.dialogTitle.textContent = title;
  elements.dialogDescription.textContent = description || "";
  elements.dialogSaveButton.textContent = saveLabel;
  elements.dialogError.hidden = true;
  elements.dialogError.textContent = "";
  elements.dialogBody.replaceChildren();
  for (const definition of definitions) {
    if (definition.section) {
      elements.dialogBody.append(createElement("h3", "dialog-section-title", definition.section));
      continue;
    }
    const label = createElement("label", `dialog-field ${definition.wide ? "is-wide" : ""}`);
    label.append(createElement("span", "", `${definition.label}${definition.required ? " *" : ""}`));
    label.append(fieldControl(definition, values[definition.name]));
    elements.dialogBody.append(label);
  }
  elements.editDialog.showModal();
  requestAnimationFrame(() => elements.dialogBody.querySelector("input,select,textarea")?.focus());
}

function requestDialogClose() {
  if (state.dialogDirty && !window.confirm("入力中の変更を破棄してもよろしいですか？")) return;
  state.dialogDirty = false;
  elements.editDialog.close();
}

function readDialogValues() {
  return Object.fromEntries([...elements.dialogBody.querySelectorAll("[data-field-name]")].map((control) => [control.dataset.fieldName, text(control.value)]));
}
function validateDialogValues(definitions, values) {
  const errors = [];
  for (const definition of definitions) {
    if (definition.name && definition.required && !text(values[definition.name])) errors.push(`「${definition.label}」を入力してください。`);
  }
  if (Object.hasOwn(values, "単価") && (/\s/.test(text(values.単価)) || parseNumber(values.単価) == null || parseNumber(values.単価) < 0)) errors.push("単価を正しく入力してください。空白は使用できません。");
  if (Object.hasOwn(values, "固定契約") && !["Y", "N"].includes(text(values.固定契約).toUpperCase())) errors.push("契約種別を選択してください。");
  if (Object.hasOwn(values, "下限時間") || Object.hasOwn(values, "上限時間")) {
    const lower = parseHours(values.下限時間), upper = parseHours(values.上限時間);
    if (lower == null || lower <= 0) errors.push("下限時間を正しく入力してください。");
    if (upper == null || upper <= 0) errors.push("上限時間を正しく入力してください。");
    if (lower != null && upper != null && lower >= upper) errors.push("下限時間は上限時間より小さくしてください。");
  }
  return [...new Set(errors)];
}

function addCompany() {
  if (state.records.some((record) => !text(record.宛先会社名))) {
    showToast("入力中の会社名を先に完成してください。", true);
    return;
  }
  const first = state.records[0] || {};
  state.records.push({
    _id: makeId(), 宛先会社名: "", 出力フォルダ名: "", 業務内容: "", 工程範囲: first.工程範囲 || "上記業務とそれに伴う附帯作業",
    技術者名: "", 単価: "", 固定契約: "N", 下限時間: first.下限時間 || "", 上限時間: first.上限時間 || "",
    弊社責任者: first.弊社責任者 || "", 備考: ""
  });
  setDirty();
  render();
  requestAnimationFrame(() => [...elements.companyList.querySelectorAll(".company-name-input")].at(-1)?.focus());
}
function addProject(companyName) {
  const companyRecords = allCompanyRecords(companyName);
  if (companyRecords.some((record) => !text(record.業務内容))) {
    showToast("入力中の案件名を先に完成してください。", true);
    return;
  }
  const first = companyRecords[0] || {};
  const record = {
    _id: makeId(), 宛先会社名: companyName, 出力フォルダ名: "", 業務内容: "",
    工程範囲: first.工程範囲 || "上記業務とそれに伴う附帯作業", 弊社責任者: first.弊社責任者 || "", 備考: "",
    技術者名: "", 単価: "", 固定契約: "N", 下限時間: first.下限時間 || "", 上限時間: first.上限時間 || ""
  };
  const lastIndex = Math.max(...companyRecords.map((item) => state.records.indexOf(item)));
  state.records.splice(lastIndex + 1, 0, record);
  setDirty();
  render();
  requestAnimationFrame(() => elements.companyList.querySelector(`[data-project-anchor-id="${CSS.escape(record._id)}"] .project-title-input`)?.focus());
}
function addEngineer(companyName, projectName) {
  const projectRecords = allProjectRecords(companyName, projectName);
  if (projectRecords.some((record) => !text(record.技術者名))) {
    showToast("入力中の技術者名を先に完成してください。", true);
    return;
  }
  const first = projectRecords[0] || {};
  const record = {
    _id: makeId(), 宛先会社名: companyName, 出力フォルダ名: "", 業務内容: projectName,
    工程範囲: first.工程範囲 || "", 弊社責任者: first.弊社責任者 || "", 備考: first.備考 || "",
    技術者名: "", 単価: first.単価 || "", 固定契約: first.固定契約 || "N", 下限時間: first.下限時間 || "", 上限時間: first.上限時間 || ""
  };
  const lastIndex = Math.max(...projectRecords.map((item) => state.records.indexOf(item)));
  state.records.splice(lastIndex + 1, 0, record);
  state.selectedIds = new Set([record._id]);
  setDirty();
  render();
  requestAnimationFrame(() => elements.companyList.querySelector(`[data-row-id="${CSS.escape(record._id)}"] .engineer-name-input`)?.focus());
}
function duplicateRecord(source) {
  if (!source) return;
  const copy = { ...source, _id: makeId(), 技術者名: "", 出力フォルダ名: "" };
  state.records.splice(state.records.indexOf(source) + 1, 0, copy);
  state.selectedIds = new Set([copy._id]);
  setDirty();
  render();
  requestAnimationFrame(() => elements.companyList.querySelector(`[data-row-id="${CSS.escape(copy._id)}"] .engineer-name-input`)?.focus());
}

function duplicateProjectSelection(companyName, projectName) {
  const selected = allProjectRecords(companyName, projectName).filter((record) => state.selectedIds.has(record._id));
  if (selected.length !== 1) return;
  duplicateRecord(selected[0]);
}

function deleteProjectSelection(companyName, projectName) {
  const selected = allProjectRecords(companyName, projectName).filter((record) => state.selectedIds.has(record._id));
  const count = selected.length;
  if (!count) return;
  if (count >= state.records.length) {
    showToast("すべての技術者は削除できません。1名以上残してください。", true);
    return;
  }
  if (!window.confirm(`「${companyName} / ${projectName}」で選択した${count}名を一覧から削除します。\n技術者がいなくなった案件・会社は一覧からなくなります。\n次回の「変更を保存」で注文データから削除されます。\n生成済みのExcel・PDFは削除されません。\n\n削除してもよろしいですか？`)) return;
  const folders = new Map(groupRecords(state.records).map((company) => [
    company.key,
    text(allCompanyRecords(company.name).find((record) => text(record.出力フォルダ名))?.出力フォルダ名)
  ]));
  const ids = new Set(selected.map((record) => record._id));
  state.records = state.records.filter((record) => !ids.has(record._id));
  for (const company of groupRecords(state.records)) {
    const preservedFolder = folders.get(company.key);
    if (preservedFolder && !company.records.some((record) => text(record.出力フォルダ名))) company.records[0].出力フォルダ名 = preservedFolder;
  }
  ids.forEach((id) => state.selectedIds.delete(id));
  setDirty();
  render();
  showToast(`${count}名を一覧から削除しました。`);
}

function deleteCompany(companyName) {
  const records = allCompanyRecords(companyName);
  if (!records.length) return;
  if (records.length >= state.records.length) {
    showToast("すべての会社は削除できません。1社以上残してください。", true);
    return;
  }
  const projectCount = new Set(records.map((record) => normalizedKey(record.業務内容))).size;
  if (!window.confirm(`「${companyName}」を一覧から削除します。\n所属する${projectCount}案件・${records.length}名も、次回の「更新」で注文データから削除されます。\n生成済みのExcel・PDFは削除されません。\n\n削除してもよろしいですか？`)) return;
  const ids = new Set(records.map((record) => record._id));
  state.records = state.records.filter((record) => !ids.has(record._id));
  ids.forEach((id) => state.selectedIds.delete(id));
  setDirty();
  render();
  showToast(`「${companyName}」を一覧から削除しました。「更新」を押すと確定します。`);
}

function deleteProject(companyName, projectName) {
  const records = allProjectRecords(companyName, projectName);
  if (!records.length) return;
  if (records.length >= state.records.length) {
    showToast("すべての案件は削除できません。1件以上残してください。", true);
    return;
  }
  const removesCompany = records.length === allCompanyRecords(companyName).length;
  const companyNote = removesCompany ? "\nこの会社の最後の案件のため、会社も一覧からなくなります。" : "";
  if (!window.confirm(`「${companyName} / ${projectName}」を一覧から削除します。\n所属する${records.length}名も、次回の「更新」で注文データから削除されます。${companyNote}\n生成済みのExcel・PDFは削除されません。\n\n削除してもよろしいですか？`)) return;
  const folder = text(allCompanyRecords(companyName).find((record) => text(record.出力フォルダ名))?.出力フォルダ名);
  const ids = new Set(records.map((record) => record._id));
  state.records = state.records.filter((record) => !ids.has(record._id));
  ids.forEach((id) => state.selectedIds.delete(id));
  const remainingCompanyRecords = allCompanyRecords(companyName);
  if (folder && remainingCompanyRecords.length && !remainingCompanyRecords.some((record) => text(record.出力フォルダ名))) {
    remainingCompanyRecords[0].出力フォルダ名 = folder;
  }
  setDirty();
  render();
  showToast(`「${projectName}」を一覧から削除しました。「更新」を押すと確定します。`);
}

function validate() {
  const errors = [];
  const invalidIds = new Set();
  const invalidCompanyIds = new Set();
  const invalidProjectIds = new Set();
  const add = (record, message) => { errors.push(message); if (record) invalidIds.add(record._id); };
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(text(state.targetMonth))) errors.push("対象年月を選択してください。");
  if (!state.records.length) errors.push("注文データが1件もありません。");
  const duplicates = new Map(), companyFolders = new Map(), projects = new Map();

  state.records.forEach((record, index) => {
    const row = index + 1;
    requiredFields.forEach((field) => {
      if (text(record[field])) return;
      add(record, `${row}行目の「${field}」が未入力です。`);
      if (field === "宛先会社名") invalidCompanyIds.add(record._id);
      if (["業務内容", "工程範囲", "弊社責任者"].includes(field)) invalidProjectIds.add(record._id);
    });
    const price = parseNumber(record.単価), lower = parseHours(record.下限時間), upper = parseHours(record.上限時間);
    if (/\s/.test(text(record.単価)) || price == null || price < 0) add(record, `${row}行目の「単価」が正しくありません。`);
    if (!["Y", "N"].includes(text(record.固定契約).toUpperCase())) add(record, `${row}行目の「固定契約」が正しくありません。`);
    if (lower == null || lower <= 0) add(record, `${row}行目の「下限時間」が正しくありません。`);
    if (upper == null || upper <= 0) add(record, `${row}行目の「上限時間」が正しくありません。`);
    if (lower != null && upper != null && lower >= upper) add(record, `${row}行目は下限時間を上限時間より小さくしてください。`);
    if (text(record.宛先会社名) && text(record.業務内容) && text(record.技術者名)) {
      const duplicateKey = normalizedKey(record.宛先会社名, record.業務内容, record.技術者名);
      if (duplicates.has(duplicateKey)) add(record, `${row}行目は${duplicates.get(duplicateKey)}行目と同じ会社・案件・技術者です。`);
      else duplicates.set(duplicateKey, row);
    }
    const companyKey = normalizedKey(record.宛先会社名);
    if (!companyFolders.has(companyKey)) companyFolders.set(companyKey, { company: text(record.宛先会社名), folders: new Map(), records: [] });
    const company = companyFolders.get(companyKey);
    if (text(record.出力フォルダ名)) company.folders.set(normalizedKey(record.出力フォルダ名), text(record.出力フォルダ名));
    company.records.push(record);
    const projectKey = normalizedKey(record.宛先会社名, record.業務内容);
    if (!projects.has(projectKey)) projects.set(projectKey, { company: text(record.宛先会社名), project: text(record.業務内容), records: [], values: new Map() });
    const project = projects.get(projectKey); project.records.push(record);
    ["工程範囲", "弊社責任者", "備考"].forEach((field) => {
      const value = text(record[field]); if (!value) return;
      if (!project.values.has(field)) project.values.set(field, new Set());
      project.values.get(field).add(normalizedKey(value));
    });
  });

  for (const company of companyFolders.values()) {
    if (company.folders.size > 1) company.records.forEach((record) => {
      add(record, `「${company.company}」の出力フォルダ名を統一してください。`);
      invalidCompanyIds.add(record._id);
    });
  }
  const folderOwners = new Map();
  for (const company of companyFolders.values()) {
    const folder = company.folders.size === 1 ? [...company.folders.values()][0] : company.company;
    const safe = safeFileName(folder);
    if (!safe) company.records.forEach((record) => {
      add(record, `「${company.company}」の出力フォルダ名に使用できる文字がありません。`);
      invalidCompanyIds.add(record._id);
    });
    else if (folderOwners.has(normalizedKey(safe)) && folderOwners.get(normalizedKey(safe)) !== company.company) company.records.forEach((record) => {
      add(record, `異なる会社の出力フォルダ名が同じ名前になります。`);
      invalidCompanyIds.add(record._id);
    });
    else folderOwners.set(normalizedKey(safe), company.company);
  }
  for (const project of projects.values()) {
    for (const [field, values] of project.values) {
      if (values.size > 1) project.records.forEach((record) => {
        add(record, `「${project.company} / ${project.project}」の${field}を統一してください。`);
        invalidProjectIds.add(record._id);
      });
    }
  }
  return { errors: [...new Set(errors)], invalidIds, invalidCompanyIds, invalidProjectIds };
}

function showValidation(result) {
  if (!result.errors.length) return true;
  result.invalidIds.forEach((id) => elements.companyList.querySelector(`[data-row-id="${CSS.escape(id)}"]`)?.classList.add("has-error"));
  elements.companyList.querySelectorAll(".company-cell").forEach((cell) => {
    const ids = (cell.dataset.recordIds || "").split(",").filter(Boolean);
    if (ids.some((id) => result.invalidCompanyIds.has(id))) cell.classList.add("has-error");
  });
  elements.companyList.querySelectorAll(".project-cell").forEach((cell) => {
    const ids = (cell.dataset.recordIds || "").split(",").filter(Boolean);
    if (ids.some((id) => result.invalidProjectIds.has(id))) cell.classList.add("has-error");
  });
  const shown = result.errors.slice(0, 8), rest = result.errors.length - shown.length;
  const log = `${shown.join("\n")}${rest > 0 ? `\nほか${rest}件の入力エラーがあります。` : ""}`;
  showResult("入力内容を確認してください。", log, true);
  elements.companyList.querySelector(".has-error")?.scrollIntoView({ behavior: "smooth", block: "center" });
  showToast("赤く表示された技術者と所属情報を確認してください。", true);
  return false;
}
function payload(records = state.records) {
  return { targetMonth: text(state.targetMonth), records: records.map((record) => Object.fromEntries(fields.map((field) => [field, text(record[field])]))) };
}

async function loadData(confirmDiscard = false) {
  if (confirmDiscard && state.dirty && !window.confirm("更新していない変更があります。注文データを再読込してもよろしいですか？")) return;
  setBusy(true, "読込中");
  try {
    const data = await api("/api/data");
    state.targetMonth = text(data.targetMonth);
    state.records = (data.records || []).map((record) => ({ _id: makeId(), ...Object.fromEntries(fields.map((field) => [field, record[field] == null ? "" : String(record[field])])) }));
    state.selectedIds.clear();
    elements.targetMonth.value = state.targetMonth;
    setDirty(false);
    render();
    showResult("注文データを読み込みました。一覧で内容を直接入力・修正できます。");
  } catch (error) {
    showResult("注文データを読み込めませんでした。", error.message, true); showToast(error.message, true);
  } finally { setBusy(false); }
}
async function saveData(silent = false) {
  state.targetMonth = elements.targetMonth.value;
  if (!showValidation(validate())) return false;
  setBusy(true, "更新中");
  try {
    await api("/api/save", { method: "POST", body: payload() });
    setDirty(false);
    if (!silent) { showResult("注文データを更新しました。更新前のデータは backup フォルダに残しています。"); showToast("更新しました。"); }
    return true;
  } catch (error) {
    showResult("注文データを更新できませんでした。", error.message, true); showToast(error.message, true); return false;
  } finally { setBusy(false); }
}
async function generateOrders() {
  state.targetMonth = elements.targetMonth.value;
  const selectedRecords = state.records.filter((record) => state.selectedIds.has(record._id));
  if (!selectedRecords.length) {
    showToast("注文書を作成する技術者を選択してください。", true);
    showResult("技術者が選択されていません。", "一覧のチェックボックスで1名以上選択してください。", true);
    return;
  }
  if (!showValidation(validate())) return;
  const outputLabel = state.outputRoot || "既定の成果物フォルダ";
  if (!window.confirm(`選択した${selectedRecords.length}名の注文書を作成します。\n対象年月: ${state.targetMonth}\n出力先: ${outputLabel}\n\n画面の全データを主データCSVへ保存してから、選択データだけを生成処理へ渡します。よろしいですか？`)) return;
  if (!await saveData(true)) return;
  setBusy(true, "作成中"); showResult("注文書を作成しています。しばらくお待ちください。");
  try {
    const result = await api("/api/generate", { method: "POST", body: { ...payload(selectedRecords), outputRoot: state.outputRoot } });
    state.outputPath = text(result.outputPath);
    showResult(`注文書を作成しました。\n保存先: ${state.outputPath || "成果物フォルダ"}`, result.log || "");
    showToast("ExcelとPDFの作成が完了しました。");
  } catch (error) {
    state.outputPath = ""; showResult("注文書を作成できませんでした。", error.message, true); showToast(error.message, true);
  } finally { setBusy(false); }
}

async function selectOutputFolder() {
  setBusy(true, "選択中");
  try {
    const result = await api("/api/select-output-folder", { method: "POST", body: { currentPath: state.outputRoot } });
    if (result.cancelled) return;
    state.outputRoot = text(result.path);
    elements.outputRootLabel.textContent = state.outputRoot;
    elements.outputRootLabel.title = state.outputRoot;
    showToast("出力先を変更しました。");
  } catch (error) {
    showToast(error.message, true);
  } finally { setBusy(false); }
}

elements.editForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const config = state.dialogConfig;
  if (!config) return;
  const values = readDialogValues();
  const errors = validateDialogValues(config.definitions, values);
  if (errors.length) {
    elements.dialogError.textContent = errors.join("\n"); elements.dialogError.hidden = false; return;
  }
  try {
    config.onSubmit(values);
    state.dialogDirty = false;
    elements.editDialog.close();
    setDirty();
    render();
  } catch (error) {
    elements.dialogError.textContent = error.message; elements.dialogError.hidden = false;
  }
});
elements.dialogBody.addEventListener("input", () => { state.dialogDirty = true; });
elements.dialogBody.addEventListener("change", () => { state.dialogDirty = true; });
elements.dialogCloseButton.addEventListener("click", requestDialogClose);
elements.dialogCancelButton.addEventListener("click", requestDialogClose);
elements.editDialog.addEventListener("cancel", (event) => { event.preventDefault(); requestDialogClose(); });
elements.addCompanyButton.addEventListener("click", addCompany);
elements.targetMonth.addEventListener("change", () => { state.targetMonth = elements.targetMonth.value; setDirty(); });
elements.selectAll.addEventListener("change", () => {
  visibleRecords().forEach((record) => elements.selectAll.checked ? state.selectedIds.add(record._id) : state.selectedIds.delete(record._id));
  render();
});
elements.clearSelectionButton.addEventListener("click", () => { state.selectedIds.clear(); render(); });
elements.selectOutputButton.addEventListener("click", selectOutputFolder);
elements.reloadButton.addEventListener("click", () => loadData(true));
elements.saveButton.addEventListener("click", () => saveData(false));
elements.generateButton.addEventListener("click", generateOrders);
elements.openOutputButton.addEventListener("click", async () => {
  try { await api("/api/open-output", { method: "POST", body: { path: state.outputPath } }); }
  catch (error) { showToast(error.message, true); }
});
elements.shutdownButton.addEventListener("click", async () => {
  const question = state.dirty ? "更新していない変更があります。このまま終了してもよろしいですか？" : "注文書作成ツールを終了します。よろしいですか？";
  if (!window.confirm(question)) return;
  setBusy(true, "終了中");
  try { await api("/api/shutdown", { method: "POST" }); showResult("注文書作成ツールを終了しました。この画面を閉じてください。"); }
  catch (error) { showResult("終了処理でエラーが発生しました。", error.message, true); }
});
window.addEventListener("beforeunload", (event) => { if (state.dirty || state.dialogDirty) { event.preventDefault(); event.returnValue = ""; } });

loadData();
