"use strict";

// Pure formatting helpers: the check results table text and the staff-facing message template.

const STATUS_LABELS = { ok: "OK", ng: "NG", warn: "注意", skip: "対象外", none: "—" };
const VERDICT_LABELS = { ok: "OK", ng: "NG", warn: "注意" };
const CATEGORY_LABELS = { office: "出社", remote: "在宅", off: "休み", placeEmpty: "勤務場所未記入", unknown: "勤務表なし" };
const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];
const TARGET_LABELS = { kinmu: "勤務表", kotsu: "交通費申請書" };

function asArray(value) {
  if (Array.isArray(value)) return value;
  return value == null ? [] : [value];
}

function normalizeReport(report) {
  if (!report) return null;
  const results = asArray(report.results).map((result) => ({
    ...result,
    issues: asArray(result.issues).map((issue) => ({
      ...issue,
      days: asArray(issue.days),
      rows: asArray(issue.rows),
      files: asArray(issue.files),
      options: asArray(issue.options)
    })),
    calendar: asArray(result.calendar),
    files: result.files || { kinmu: "", kotsu: "" },
    cells: result.cells || {}
  }));
  return { ...report, results, unmatchedFiles: asArray(report.unmatchedFiles) };
}

function parseTargetMonth(targetMonth) {
  const match = /^(\d{4})-(\d{2})$/.exec(String(targetMonth || ""));
  return match ? { year: Number(match[1]), month: Number(match[2]) } : null;
}
function formatMonthLabel(targetMonth) {
  const parsed = parseTargetMonth(targetMonth);
  return parsed ? `${parsed.year}年${parsed.month}月` : "";
}
function weekdayOf(targetMonth, day) {
  const parsed = parseTargetMonth(targetMonth);
  return parsed ? new Date(parsed.year, parsed.month - 1, day).getDay() : 0;
}
function formatDay(targetMonth, day) {
  const parsed = parseTargetMonth(targetMonth);
  if (!parsed) return `${day}日`;
  return `${parsed.month}/${day}(${WEEKDAYS[weekdayOf(targetMonth, day)]})`;
}
function formatDayList(targetMonth, days) {
  return asArray(days).map((day) => formatDay(targetMonth, typeof day === "object" ? day.day : day)).join("、");
}
function formatExtraDays(targetMonth, days) {
  return asArray(days).map((day) => `${formatDay(targetMonth, day.day)}（${CATEGORY_LABELS[day.category] || day.category}）`).join("、");
}
function formatRows(rows, key) {
  return asArray(rows).map((row) => `${row.row}行目「${row[key]}」`).join("、");
}
function formatPlaceValues(targetMonth, days) {
  return asArray(days).map((day) => `${formatDay(targetMonth, day.day)}「${day.value}」`).join("、");
}

// Text shown to the checker in the expanded detail row.
function issueSummary(issue, targetMonth) {
  const target = TARGET_LABELS[issue.target] || "";
  switch (issue.code) {
    case "KINMU_MISSING": return "勤務表が見つかりません。";
    case "KOTSU_MISSING": return "交通費申請書が見つかりません。";
    case "KINMU_DUPLICATE":
    case "KOTSU_DUPLICATE": return `${target}が${asArray(issue.files).length}件あります。更新日時が新しい「${issue.used}」をチェックしました。`;
    case "KINMU_READ_ERROR":
    case "KOTSU_READ_ERROR": return `${target}「${issue.file}」を読み込めません。${issue.error || ""}`;
    case "KINMU_MONTH_MISMATCH": return `勤務表の年月が${issue.actual}です（対象は${issue.expected}）。`;
    case "KINMU_MONTH_UNREADABLE": return "勤務表の年（A1）・月（D1）を読み取れません。";
    case "KOTSU_MONTH_EMPTY": return "申請年月（H4）が空欄です。";
    case "KOTSU_MONTH_UNREADABLE": return `申請年月「${issue.actual}」を読み取れません。`;
    case "KOTSU_MONTH_MISMATCH": return `申請年月が${issue.actual}です（対象は${issue.expected}）。`;
    case "FILE_MONTH_MISMATCH": return `${target}のファイル名の年月が${issue.actual}です：${issue.file}`;
    case "NAME_MISMATCH": return `${issue.target === "kinmu" ? "勤務表の氏名欄" : "交通費申請書の申請者欄"}が「${issue.actual}」です。`;
    case "PLACE_EMPTY": return `出勤・退勤があるのに勤務場所が空欄の日：${formatDayList(targetMonth, issue.days)}`;
    case "PLACE_INVALID": return `勤務場所がリストにない値の日：${formatPlaceValues(targetMonth, issue.days)}（リスト：${asArray(issue.options).join("・")}）`;
    case "CLAIM_EXTRA": return `出社日ではないのに交通費を申請している日：${formatExtraDays(targetMonth, issue.days)}`;
    case "CLAIM_MISSING": return `出社日なのに交通費を申請していない日：${formatDayList(targetMonth, issue.days)}`;
    case "CLAIM_DATE_INVALID": return `日付を読み取れない行：${formatRows(issue.rows, "text")}`;
    case "CLAIM_OUT_OF_MONTH": return `対象月以外の日付：${formatRows(issue.rows, "date")}`;
    case "COMMUTER_ROW": return `交通費申請書に定期券の行が${issue.count}行あります。人員リストで定期券にチェックするか確認してください。`;
    default: return issue.code;
  }
}

// One line of the message sent to the staff member. An empty string keeps the issue out of the message.
function adviceLine(issue, targetMonth) {
  const monthLabel = formatMonthLabel(targetMonth);
  switch (issue.code) {
    case "KINMU_MISSING": return "勤務表がまだ提出されていません。提出をお願いします。";
    case "KOTSU_MISSING": return "交通費申請書がまだ提出されていません。提出をお願いします。";
    case "KINMU_READ_ERROR": return "提出された勤務表を開けませんでした。ファイルを確認して再提出してください。";
    case "KOTSU_READ_ERROR": return "提出された交通費申請書を開けませんでした。ファイルを確認して再提出してください。";
    case "KINMU_MONTH_MISMATCH": return `勤務表の年月が「${issue.actual}」になっています。「${issue.expected}」に修正してください。`;
    case "KINMU_MONTH_UNREADABLE": return `勤務表の年・月の欄を読み取れません。「${monthLabel}」になっているか確認してください。`;
    case "KOTSU_MONTH_EMPTY": return `申請年月が入力されていません。「${issue.expected}」を入力してください。`;
    case "KOTSU_MONTH_UNREADABLE": return `申請年月「${issue.actual}」を読み取れません。「${issue.expected}」と入力してください。`;
    case "KOTSU_MONTH_MISMATCH": return `申請年月が「${issue.actual}」になっています。「${issue.expected}」に修正してください。`;
    case "FILE_MONTH_MISMATCH": return `ファイル名の年月が「${issue.actual}」になっています。「${monthLabel}」に直してください。`;
    case "NAME_MISMATCH": return `${issue.target === "kinmu" ? "氏名欄" : "申請者欄"}が「${issue.actual}」になっています。ご自身の氏名に直してください。`;
    case "PLACE_EMPTY": return `次の日は出勤・退勤が入力されていますが、勤務場所が空欄です。リストから選んでください：${formatDayList(targetMonth, issue.days)}`;
    case "PLACE_INVALID": return `次の日の勤務場所がリストにない値になっています。リスト（${asArray(issue.options).join("・")}）から選んでください：${formatPlaceValues(targetMonth, issue.days)}`;
    case "CLAIM_EXTRA": return `次の日は勤務表では出社日になっていませんが、交通費が申請されています：${formatExtraDays(targetMonth, issue.days)}`;
    case "CLAIM_MISSING": return `次の日は勤務表では出社日ですが、交通費が申請されていません：${formatDayList(targetMonth, issue.days)}`;
    case "CLAIM_DATE_INVALID": return `日付を読み取れない行があります：${formatRows(issue.rows, "text")}。「9/10」のように入力してください。`;
    case "CLAIM_OUT_OF_MONTH": return `${monthLabel}以外の日付が入力されています：${formatRows(issue.rows, "date")}`;
    default: return "";
  }
}

function buildMessage(result, targetMonth) {
  const groups = { kinmu: [], kotsu: [] };
  const issues = asArray(result.issues);
  issues.forEach((issue) => {
    const line = adviceLine(issue, targetMonth);
    if (line) groups[issue.target === "kotsu" ? "kotsu" : "kinmu"].push(line);
  });
  // The count line only helps when the numbers really differ; equal counts with swapped days read as a contradiction.
  const counts = result.dayCounts;
  if (counts && counts.office !== counts.claim && issues.some((issue) => issue.code === "CLAIM_EXTRA" || issue.code === "CLAIM_MISSING")) {
    groups.kotsu.push(`出社日数と交通費の申請日数が一致していません（出社 ${counts.office}日 / 申請 ${counts.claim}日）。`);
  }
  if (!groups.kinmu.length && !groups.kotsu.length) return "";

  const lines = [
    `${result.name}さん`,
    "",
    "お疲れさまです。",
    `${formatMonthLabel(targetMonth)}分の勤務表・交通費申請書を確認しました。`,
    "以下の点について、ご対応をお願いします。"
  ];
  if (groups.kinmu.length) lines.push("", "【勤務表】", ...groups.kinmu.map((line) => `・${line}`));
  if (groups.kotsu.length) lines.push("", "【交通費申請書】", ...groups.kotsu.map((line) => `・${line}`));
  lines.push("", "よろしくお願いいたします。");
  return lines.join("\n");
}

if (typeof module !== "undefined") {
  module.exports = { normalizeReport, formatDay, formatMonthLabel, issueSummary, adviceLine, buildMessage };
}
