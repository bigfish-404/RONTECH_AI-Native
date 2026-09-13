"use strict";

function collapseAll() {
  const companies = groupRecords(state.records);
  state.collapsedCompanies = new Set(companies.map((company) => company.key));
  state.collapsedProjects = new Set(companies.flatMap((company) =>
    [...company.projects.values()].map((project) => normalizedKey(company.name, project.name))
  ));
  render();
}

function expandAll() {
  state.collapsedCompanies.clear();
  state.collapsedProjects.clear();
  render();
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
      const companyCollapseKey = normalizedKey(company.name);
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
            showToast("同じ会社名がすでに存在します。既存の会社に案件または技術者を追加してください。", true);
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
      companyActions.dataset.companyName = company.name;
      companyActions.dataset.recordIds = companyRecords.map((record) => record._id).join(",");
      companyActions.append(
        createButton("案件を追加", "button button-secondary scope-action scope-add", () => addProject(company.name)),
        createButton("案件を削除", "button scope-delete scope-action scope-delete-project", () => deleteSelectedProject(company.name))
      );
      identity.append(companyCollapse, nameLine, companyNameField, companyCount, companyFolderField, companyActions);
      companyCell.append(identity);
      companyBlock.append(companyCell);

      const projectsList = createElement("div", "projects-list");
      for (const project of company.projects.values()) {
        const fullProjectRecords = allProjectRecords(company.name, project.name);
        const common = fullProjectRecords[0] || project.records[0];
        const projectCollapseKey = normalizedKey(company.name, project.name);
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
              showToast("同じ案件名がすでに存在します。既存の案件に技術者を追加してください。", true);
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
          createButton("複製", "button button-secondary scope-action scope-duplicate", () => duplicateProjectSelection(company.name, project.name)),
          createButton("技術者を追加", "button button-secondary scope-action scope-add", () => addEngineer(company.name, project.name)),
          createButton("技術者を削除", "button scope-delete scope-action scope-delete-engineers", () => deleteProjectSelection(company.name, project.name))
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
  updateMetrics();
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

function updateMetrics() {
  const companies = new Set(state.records.map((record) => text(record.宛先会社名)).filter(Boolean));
  const projects = new Set(state.records.filter((record) => text(record.宛先会社名) && text(record.業務内容)).map((record) => normalizedKey(record.宛先会社名, record.業務内容)));
  elements.companyCount.textContent = companies.size;
  elements.projectCount.textContent = projects.size;
  elements.engineerCount.textContent = state.records.length;
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
