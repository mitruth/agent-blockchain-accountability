// chain: everything the off-chain programs share to talk to the local node.
//
//   client.js      the node connection and the test keys
//   contracts.js   compiled contracts; deploy, send, read; decoded reverts
//   time.js        the node's clock, and moving it forward
//   deployment.js  deployments/local.json
//   units.js       Wh and EUR

export { ROOT } from "./paths.js";
export { publicClient, key, wallet } from "./client.js";
export { artifact, abi, deploy, send, read, calldata, selector, events, explain } from "./contracts.js";
export { now, warpTo } from "./time.js";
export { DEPLOYMENT_FILE, saveDeployment, loadDeployment } from "./deployment.js";
export { EUR, price, eur, kWh } from "./units.js";
