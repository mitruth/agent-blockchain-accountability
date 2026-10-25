// node offchain/eval/summarize.js <report.json> [<report.json> ...]
//
// The honest replays' reports (honest-day-ahead.js) as the evaluation's
// tables (spec v0.2 section 7), in Markdown: per arm, the false positives per
// policy (submissions refused and flagged), the refused energy and its regret
// (refused volume settled at the real-time price instead of the tariff:
// decision of 25 October 2026), and S9's false-alarm interval. A submission
// two policies refuse counts for each policy and once in the total.

import fs from "node:fs";

const usd = (micro) => (micro / 1e6).toFixed(2);
const kwh = (wh) => (wh / 1000).toFixed(1);

function table(report) {
  const r = report.refused ?? { all: {}, byPolicy: {} };
  const names = [...new Set([...report.policies, ...Object.keys(report.byPolicy)])];
  const rows = names.map((name) => {
    const fp = report.byPolicy[name] ?? { rejected: 0, flagged: 0 };
    const x = r.byPolicy[name] ?? { buyWh: 0, sellWh: 0, buyRegretMicroUsd: 0, sellRegretMicroUsd: 0 };
    return `| ${name} | ${fp.rejected} | ${fp.flagged} | ${kwh(x.buyWh)} | ${kwh(x.sellWh)} | ${usd(x.buyRegretMicroUsd)} | ${usd(x.sellRegretMicroUsd)} |`;
  });
  const a = r.all;
  const pct = ((100 * report.rejected) / report.submissions).toFixed(1);
  return [
    `### ${report.arm}${report.full ? ", with S3 and S4" : ""}`,
    "",
    `${report.days} days; ${report.submissions} submissions, ${report.rejected} refused (${pct} %), ${report.flagged} flagged; ` +
      `${report.suspensions} suspensions (G1); ${report.gridEpisodes ?? 0} grid alerts; ` +
      `S9: ${report.s9Alarms?.length ?? 0} alarms, ARL₀ ${report.s9Arl0Days ?? "∞"} days.`,
    "",
    "| Policy | Refused | Flagged | Refused buy kWh | Refused sell kWh | Buy regret USD | Sell regret USD |",
    "|---|---:|---:|---:|---:|---:|---:|",
    ...rows,
    `| **Any policy** | **${report.rejected}** | **${report.flagged}** | **${kwh(a.buyWh ?? 0)}** | **${kwh(a.sellWh ?? 0)}** | ` +
      `**${usd(a.buyRegretMicroUsd ?? 0)}** | **${usd(a.sellRegretMicroUsd ?? 0)}** |`,
    "",
  ].join("\n");
}

const files = process.argv.slice(2);
if (!files.length) {
  console.error("usage: node offchain/eval/summarize.js <report.json> ...");
  process.exit(2);
}
console.log(files.map((f) => table(JSON.parse(fs.readFileSync(f, "utf8")))).join("\n"));
