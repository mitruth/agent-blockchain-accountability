// The verifier must be able to disagree (spec 8). Each tampering below changes
// one figure of a history the verifier accepted; it must reject every one.

import { verifyWindow } from "./verify.js";

const clone = (history) => ({ id: history.id, events: history.events.map((e) => ({ ...e })) });

const TAMPERINGS = [
  {
    name: "an admission reported as a refusal",
    applies: (e) => e.type === "admitted",
    tamper: (e) => {
      e.type = "refused";
    },
  },
  {
    name: "a refusal reported as an admission",
    applies: (e) => e.type === "refused",
    tamper: (e) => {
      e.type = "admitted";
    },
  },
  {
    name: "a count one unit off",
    applies: (e) => e.type === "admitted" && e.usedBefore > 0n,
    tamper: (e) => {
      e.usedBefore -= 1n;
    },
  },
  {
    name: "a credit given back that should not have been, or the reverse",
    applies: (e) => e.type === "credited" && e.amount > 0n,
    tamper: (e) => {
      e.credited = e.credited === 0n ? e.amount : 0n;
    },
  },
  {
    name: "an observation one unit off",
    applies: (e) => e.type === "observed",
    tamper: (e) => {
      e.used += 1n;
    },
  },
];

/**
 * Tamper with accepted histories, one figure at a time, and check the verifier
 * notices. Returns [{ name, tried, caught }].
 */
export function selfTest(histories) {
  const accepted = histories.filter((h) => !verifyWindow(h).disagreement);
  return TAMPERINGS.map(({ name, applies, tamper }) => {
    let tried = 0;
    let caught = 0;
    for (const history of accepted) {
      const index = history.events.findIndex(applies);
      if (index < 0) continue;
      const copy = clone(history);
      tamper(copy.events[index]);
      tried++;
      if (verifyWindow(copy).disagreement) caught++;
    }
    return { name, tried, caught };
  });
}
