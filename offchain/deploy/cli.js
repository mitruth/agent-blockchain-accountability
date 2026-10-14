// npm run demo:deploy   (with `npm run node` running in another terminal)
//
// Optional argument: another prosumers file, e.g. node offchain/deploy/cli.js my-prosumers.json

import { deploySystem, loadConfig } from "./index.js";

deploySystem(loadConfig(process.argv[2])).catch((error) => {
  console.error(error.shortMessage ?? error.message ?? error);
  process.exit(1);
});
