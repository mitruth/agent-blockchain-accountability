// sensor: a prosumer's trusted meter reporting what it measured in a slot.
//
// The prosumer contract accepts the report only from the sensor the operator
// registered for it, and only after the slot has been delivered. Settlement
// follows: committed net export against measured net export, a penalty above
// the settlement rule's tolerance.
//
// The values reported here come from the caller. This is where a real meter
// feed would be connected.

import { read, send, events } from "../chain/index.js";

/** The prosumer's commitment for `slot` (absolute slot number): bought, sold, paid, received, collateral. */
export function commitmentOf(deployment, name, slot) {
  return read(deployment.prosumers[name].prosumer, "Prosumer", "commitmentOf", [slot]);
}

/** Report the measured export and import (Wh) of prosumer `name` for `slot`. Returns the `Settled` event's fields. */
export async function report(deployment, name, slot, exportedWh, importedWh) {
  const p = deployment.prosumers[name];
  const receipt = await send(p.sensor.keyIndex, p.prosumer, "Prosumer", "settle", [slot, exportedWh, importedWh]);
  return events(receipt, "Prosumer", "Settled")[0].args;
}
