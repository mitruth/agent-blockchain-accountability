// The datasets' CSVs: comma-separated, no quoted fields, a header row.

import fs from "node:fs";
import path from "node:path";

/** Every row as an object keyed by the header. A row of the wrong width throws. */
export function readCsv(file) {
  const lines = fs.readFileSync(file, "utf8").replace(/^﻿/, "").trim().split(/\r?\n/);
  const header = lines[0].split(",");
  return lines.slice(1).map((line, i) => {
    const cells = line.split(",");
    if (cells.length !== header.length) throw new Error(`${file}: row ${i + 1} has ${cells.length} cells, not ${header.length}`);
    return Object.fromEntries(header.map((h, j) => [h, cells[j]]));
  });
}

/** Writes `columns` of each row, LF line ends; returns the row count. */
export function writeCsv(file, columns, rows) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const lines = [columns.join(","), ...rows.map((r) => columns.map((c) => String(r[c])).join(","))];
  fs.writeFileSync(file, lines.join("\n") + "\n");
  return rows.length;
}
