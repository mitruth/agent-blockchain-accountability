// deployments/local.json: every address and key index of the local system.
// It replaces the database of the earlier projects; it is git-ignored and
// rewritten on every deployment.

import fs from "node:fs";
import path from "node:path";
import { ROOT } from "./paths.js";

/** DEPLOYMENT_FILE in the environment points elsewhere, e.g. for a second node. */
export const DEPLOYMENT_FILE = process.env.DEPLOYMENT_FILE ?? path.join(ROOT, "deployments", "local.json");

export function saveDeployment(data) {
  fs.mkdirSync(path.dirname(DEPLOYMENT_FILE), { recursive: true });
  fs.writeFileSync(DEPLOYMENT_FILE, JSON.stringify(data, null, 2) + "\n");
}

export function loadDeployment() {
  if (!fs.existsSync(DEPLOYMENT_FILE)) throw new Error("No deployment. Run: npm run demo:deploy");
  return JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8"));
}
