// npm run demo:match                         the current electricity session
// node offchain/matcher/cli.js 0x...         a given session

import { loadDeployment, read } from "../chain/index.js";
import { runMatcher } from "./index.js";

const ELECTRICITY = 0;

try {
  const deployment = loadDeployment();
  const session =
    process.argv[2] ?? (await read(deployment.contracts.manager, "MarketManager", "currentSession", [ELECTRICITY]));
  await runMatcher(deployment, session);
} catch (error) {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
}
