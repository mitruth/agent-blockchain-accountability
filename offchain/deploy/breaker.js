// The session circuit breaker G1's configuration (spec v0.2 section 5), from
// prosumers.json's "agentPolicies.breaker": two sliding windows, rejected and
// flagged submissions, and the cooldown after which a suspended account is
// reinstated (0: only the owner reinstates). The ABI encoding of
// SessionBreaker.Config.

import { encodeAbiParameters } from "viem";

const SLIDING = 0;

const WINDOW = {
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" },
    { name: "step", type: "uint32" },
    { name: "buckets", type: "uint16" },
    { name: "anchor", type: "uint40" },
    { name: "cap", type: "uint64" },
    { name: "rate", type: "uint64" },
    { name: "initial", type: "uint64" },
  ],
};

export const BREAKER_CONFIG = {
  type: "tuple",
  components: [{ ...WINDOW, name: "rejects" }, { ...WINDOW, name: "flags" }, { name: "cooldownSeconds", type: "uint32" }],
};

const sliding = (bucketSeconds, windowSeconds, cap) => {
  if (windowSeconds % bucketSeconds !== 0) throw new Error("breaker: the bucket must divide the window");
  return { kind: SLIDING, step: bucketSeconds, buckets: windowSeconds / bucketSeconds, anchor: 0, cap: BigInt(cap), rate: 0n, initial: 0n };
};

/**
 * The configuration from its JSON form. The spec's defaults: at most 10
 * rejections an hour in 5-minute buckets, 30 flags a day in hourly buckets,
 * no automatic reinstatement.
 */
export function breakerConfigOf(b = {}) {
  return {
    rejects: sliding((b.rejectsBucketMinutes ?? 5) * 60, (b.rejectsMinutes ?? 60) * 60, b.maxRejects ?? 10),
    flags: sliding((b.flagsBucketHours ?? 1) * 3600, (b.flagsHours ?? 24) * 3600, b.maxFlags ?? 30),
    cooldownSeconds: (b.cooldownMinutes ?? 0) * 60,
  };
}

export function encodeBreakerConfig(config) {
  return encodeAbiParameters([BREAKER_CONFIG], [config]);
}
