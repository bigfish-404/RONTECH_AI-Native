"use strict";

const CELL_KEYS = ["kinmuSubmit", "kotsuSubmit", "kinmuMonth", "kotsuMonth", "place", "dates"];
const RESULT_COLUMN_COUNT = 10;
const ICON_PATHS = {
  remove: "M6 6l12 12M18 6 6 18",
  message: "M4.75 6.25a1.5 1.5 0 0 1 1.5-1.5h11.5a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H10l-4.25 3.5v-3.5a1.5 1.5 0 0 1-1-1.5v-8.5Z"
};
const CALENDAR_LEGEND = [
  ["match", "出社・申請あり"],
  ["missing", "出社・申請なし"],
  ["extra", "出社日以外の申請"],
  ["remote", "在宅"],
  ["place-empty", "勤務場所未記入"]
];

function createBadge(cell) {
  const status = cell?.status || "none";
  const label = text(cell?.text) || "—";
  const badge = createElement("span", `badge badge-${status}`, label);
  badge.title = status === "none" ? "判定できません" : `${STATUS_LABELS[status]}：${label}`;
  return badge;
}

function reportStatusByName() {
  const statuses = new Map();
  (state.report?.results || []).forEach((result) => statuses.set(normalizeName(result.name), result.overall));
  return statuses;
}

function renderMetrics() {
  const results = state.report?.results || [];
  const count = (status) => String(results.filter((result) => result.overall === status).length);
  elements.staffCount.textContent = String(state.report ? results.length : state.staff.length);
  elements.ngCount.textContent = state.report ? count("ng") : "–";
  elements.warnCount.textContent = state.report ? count("warn") : "–";
  elements.okCount.textContent = state.report ? count("ok") : "–";
}

function renderStaff() {
  const statuses = reportStatusByName();
  const rows = state.staff.map((person, index) => {
    const row = createElement("tr", "staff-row");
    row.dataset.id = person._id;

    const status = statuses.get(normalizeName(person.氏名));
    const noCell = createElement("td", "staff-no-cell", String(index + 1));
    const dot = createElement("span", `status-dot${status ? ` is-${status}` : ""}`);
    dot.title = status ? `前回のチェック：${VERDICT_LABELS[status]}` : "未チェック";
    noCell.append(dot);

    const nameInput = document.createElement("input");
    nameInput.type = "text";
    nameInput.className = "staff-name-input";
    nameInput.value = person.氏名;
    nameInput.placeholder = "氏名（フルネーム）";
    nameInput.autocomplete = "off";
    nameInput.spellcheck = false;
    nameInput.setAttribute("aria-label", `${index + 1}人目の氏名`);
    nameInput.addEventListener("input", () => { person.氏名 = nameInput.value; setDirty(); });
    nameInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.isComposing && index === state.staff.length - 1) addStaff();
    });
    const nameCell = createElement("td", "staff-name-cell");
    nameCell.append(nameInput);

    const passLabel = createElement("label", "pass-toggle");
    const passInput = document.createElement("input");
    passInput.type = "checkbox";
    passInput.checked = Boolean(person.定期券);
    passInput.setAttribute("aria-label", `${text(person.氏名) || `${index + 1}人目`}は定期券`);
    passInput.addEventListener("change", () => { person.定期券 = passInput.checked; setDirty(); });
    passLabel.append(passInput);
    const passCell = createElement("td", "pass-cell");
    passCell.append(passLabel);

    const removeButton = createButton("", "icon-button", () => removeStaff(person._id));
    removeButton.append(createIcon(ICON_PATHS.remove));
    removeButton.setAttribute("aria-label", `${text(person.氏名) || `${index + 1}人目`}を削除`);
    removeButton.title = "削除";
    const removeCell = createElement("td", "remove-cell");
    removeCell.append(removeButton);

    row.append(noCell, nameCell, passCell, removeCell);
    return row;
  });
  elements.staffBody.replaceChildren(...rows);
  elements.staffEmpty.hidden = state.staff.length > 0;
  elements.staffBadge.textContent = `${state.staff.length}名`;
  renderMetrics();
}

function renderReport() {
  const report = state.report;
  renderMetrics();
  elements.resultWrap.hidden = !report;
  elements.resultEmpty.hidden = Boolean(report);
  if (!report) {
    elements.checkedInfo.textContent = "";
    elements.resultBody.replaceChildren();
    elements.unmatchedSection.hidden = true;
    return;
  }
  elements.checkedInfo.textContent = `${formatMonthLabel(report.targetMonth)}分 ／ ${report.checkedAt} 時点 ／ ファイル ${report.fileCount}件`;

  const rows = [];
  report.results.forEach((result, index) => {
    if (state.problemOnly && result.overall === "ok") return;
    const expanded = state.expanded.has(index);
    rows.push(buildResultRow(result, index, expanded, report.targetMonth));
    if (expanded) rows.push(buildDetailRow(result, report.targetMonth));
  });
  if (!rows.length) {
    const row = createElement("tr", "result-empty-row");
    const cell = createElement("td", "", "問題のある人はいません。");
    cell.colSpan = RESULT_COLUMN_COUNT;
    row.append(cell);
    rows.push(row);
  }
  elements.resultBody.replaceChildren(...rows);
  renderUnmatched(report.unmatchedFiles);
}

function buildResultRow(result, index, expanded, targetMonth) {
  const row = createElement("tr", `result-row is-${result.overall}${expanded ? " is-expanded" : ""}`);
  const toggle = () => {
    if (state.expanded.has(index)) state.expanded.delete(index);
    else state.expanded.add(index);
    renderReport();
  };

  const toggleCell = createElement("td", "toggle-cell");
  const toggleButton = createButton("", `collapse-toggle ${expanded ? "is-expanded" : "is-collapsed"}`, (event) => {
    event.stopPropagation();
    toggle();
  });
  toggleButton.setAttribute("aria-expanded", String(expanded));
  toggleButton.setAttribute("aria-label", `${result.name}さんの詳細を${expanded ? "閉じる" : "開く"}`);
  toggleCell.append(toggleButton);

  const nameCell = createElement("th", "name-cell");
  nameCell.scope = "row";
  nameCell.append(createElement("span", "person-name", result.name));
  if (result.commuterPass) nameCell.append(createElement("span", "pass-tag", "定期券"));
  row.append(toggleCell, nameCell);

  CELL_KEYS.forEach((key) => {
    const cell = createElement("td", "status-cell");
    cell.append(createBadge(result.cells[key]));
    row.append(cell);
  });

  const verdictCell = createElement("td", "verdict-cell");
  verdictCell.append(createElement("span", `verdict verdict-${result.overall}`, VERDICT_LABELS[result.overall]));
  const messageCell = createElement("td", "message-cell");
  if (buildMessage(result, targetMonth)) {
    const button = createButton("連絡文", "button message-button", (event) => {
      event.stopPropagation();
      openMessage(result, targetMonth);
    });
    button.prepend(createIcon(ICON_PATHS.message));
    button.setAttribute("aria-label", `${result.name}さんへの連絡文を作成`);
    messageCell.append(button);
  } else {
    messageCell.append(createElement("span", "muted-dash", "—"));
  }
  row.append(verdictCell, messageCell);
  row.addEventListener("click", toggle);
  return row;
}

function buildDetailRow(result, targetMonth) {
  const row = createElement("tr", "detail-row");
  const cell = createElement("td");
  cell.colSpan = RESULT_COLUMN_COUNT;
  const detail = createElement("div", "detail");

  const files = createElement("div", "detail-files");
  [["勤務表", result.files.kinmu], ["交通費", result.files.kotsu]].forEach(([label, fileName]) => {
    const item = createElement("span", "detail-file");
    item.append(createElement("strong", "", label), createElement("span", fileName ? "" : "is-missing", fileName || "ファイルなし"));
    files.append(item);
  });
  detail.append(files);

  if (result.issues.length) {
    const section = createElement("section", "detail-section");
    section.append(createElement("h4", "", "指摘事項"));
    const list = createElement("ul", "issue-list");
    result.issues.forEach((issue) => {
      const item = createElement("li", "issue-item");
      item.append(createBadge({ status: issue.severity, text: STATUS_LABELS[issue.severity] }), createElement("span", "issue-text", issueSummary(issue, targetMonth)));
      list.append(item);
    });
    section.append(list);
    detail.append(section);
  } else {
    detail.append(createElement("p", "detail-ok", "指摘事項はありません。"));
  }

  if (result.calendar.length) detail.append(buildCalendar(result, targetMonth));
  cell.append(detail);
  row.append(cell);
  return row;
}

function calendarDayState(entry, compared) {
  if (entry.category === "office") {
    if (!compared) return ["office", "出社"];
    return entry.claimed ? ["match", "出社"] : ["missing", "申請なし"];
  }
  if (entry.category === "placeEmpty") return ["place-empty", "未記入"];
  if (entry.claimed) return compared ? ["extra", "申請あり"] : ["claim", "申請"];
  if (entry.category === "remote") return ["remote", "在宅"];
  return ["off", ""];
}

function buildCalendar(result, targetMonth) {
  // The comparison only ran when both workbooks were read for a person without a 定期券.
  const compared = Boolean(result.files.kinmu) && !result.commuterPass && ["ok", "ng"].includes(result.cells.dates?.status);
  const section = createElement("section", "detail-section");
  section.append(createElement("h4", "", compared ? "日付照合（勤務表 × 交通費申請書）" : "勤務表の出勤状況"));
  const grid = createElement("div", "calendar");
  result.calendar.forEach((entry) => {
    const [dayState, caption] = calendarDayState(entry, compared);
    const weekday = weekdayOf(targetMonth, entry.day);
    const weekendClass = weekday === 0 ? " is-sun" : weekday === 6 ? " is-sat" : "";
    const day = createElement("div", `calendar-day state-${dayState}${weekendClass}`);
    day.append(
      createElement("span", "day-number", String(entry.day)),
      createElement("span", "day-week", WEEKDAYS[weekday]),
      createElement("span", "day-caption", caption)
    );
    day.title = `${formatDay(targetMonth, entry.day)} ${CATEGORY_LABELS[entry.category] || ""}${entry.claimed ? "・交通費申請あり" : ""}`;
    grid.append(day);
  });
  section.append(grid);

  if (compared) {
    const legend = createElement("ul", "calendar-legend");
    CALENDAR_LEGEND.forEach(([dayState, label]) => {
      const item = createElement("li");
      item.append(createElement("span", `legend-swatch calendar-day state-${dayState}`), createElement("span", "", label));
      legend.append(item);
    });
    section.append(legend);
  }
  return section;
}

function renderUnmatched(files) {
  elements.unmatchedSection.hidden = files.length === 0;
  elements.unmatchedCount.textContent = `${files.length}件`;
  elements.unmatchedList.replaceChildren(...files.map((file) => {
    const item = createElement("li");
    const reason = file.reason === "unknownKind"
      ? "勤務表・交通費申請書のどちらか判別できません"
      : "人員リストにある氏名が含まれていません";
    item.append(createElement("span", "unmatched-name", file.name), createElement("span", "unmatched-reason", reason));
    return item;
  }));
}

function openMessage(result, targetMonth) {
  elements.messageTitle.textContent = `${result.name}さんへの連絡文`;
  elements.messageText.value = buildMessage(result, targetMonth);
  elements.copyMessageButton.textContent = "コピー";
  elements.messageDialog.showModal();
  elements.messageText.scrollTop = 0;
  elements.copyMessageButton.focus();
}
