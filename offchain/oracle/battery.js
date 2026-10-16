// A battery, as its BMS sees it: the energy stored and the discharge odometer,
// in whole Wh. Two ways to drive it:
//
//   new Battery(settings).step(netWh)   a simple model: charge a surplus,
//                                        discharge to cover a shortfall,
//                                        within power, charge limits and
//                                        efficiencies
//   replayArm(settings, slots)           what an honest controller arm did,
//                                        slot by slot, from data/arms/
//
// The odometer counts energy taken out of the cells (the house receives that
// times the discharge efficiency). The arms' cycle count is the same figure
// over the capacity, so a policy on cycles (S4) reads the arms' cycles.
//
// Integer rounding always errs towards the battery holding less: what is
// stored rounds down, what is drawn rounds up.

const BPS = 10_000;

/**
 * @param s { batteryCapacityWh, batteryPowerW, etaChargeBps, etaDischargeBps,
 *            socMinBps, socMaxBps, socInitialBps }, as in data/homes/homes.csv
 *            and data/arms/.../settings.csv
 * @param slotSeconds the slot length
 */
export class Battery {
  constructor(s, slotSeconds) {
    this.capacityWh = Number(s.batteryCapacityWh);
    this.etaCharge = Number(s.etaChargeBps);
    this.etaDischarge = Number(s.etaDischargeBps);
    this.minWh = Math.ceil((this.capacityWh * Number(s.socMinBps)) / BPS);
    this.maxWh = Math.floor((this.capacityWh * Number(s.socMaxBps)) / BPS);
    this.slotLimitWh = Math.floor((Number(s.batteryPowerW) * slotSeconds) / 3600);
    this.socWh = Math.floor((this.capacityWh * Number(s.socInitialBps)) / BPS);
    this.odometerWh = 0;
  }

  /** Take up to `houseWh` from the house; returns what was taken. */
  charge(houseWh) {
    let taken = Math.min(houseWh, this.slotLimitWh);
    let stored = Math.floor((taken * this.etaCharge) / BPS);
    const room = Math.max(0, this.maxWh - this.socWh);
    if (stored > room) {
      stored = room;
      taken = Math.ceil((room * BPS) / this.etaCharge);
    }
    this.socWh += stored;
    return taken;
  }

  /** Give up to `houseWh` to the house; returns what was given. */
  discharge(houseWh) {
    let given = Math.min(houseWh, this.slotLimitWh);
    let drawn = Math.ceil((given * BPS) / this.etaDischarge);
    const available = Math.max(0, this.socWh - this.minWh);
    if (drawn > available) {
      drawn = available;
      given = Math.floor((drawn * this.etaDischarge) / BPS);
    }
    this.socWh -= drawn;
    this.odometerWh += drawn;
    return given;
  }

  /**
   * One slot of the simple model. `netWh` is the house's surplus (positive)
   * or shortfall (negative) before the battery. Returns what the battery
   * took or gave, and what is left for the grid: positive to export.
   */
  step(netWh) {
    if (netWh >= 0) {
      const charged = this.charge(netWh);
      return { chargedWh: charged, dischargedWh: 0, gridWh: netWh - charged };
    }
    const discharged = this.discharge(-netWh);
    return { chargedWh: 0, dischargedWh: discharged, gridWh: netWh + discharged };
  }

  /** What the BMS would sign now. */
  state() {
    return { socWh: this.socWh, dischargeOdometerWh: this.odometerWh };
  }
}

/**
 * An arm's battery at the start of each slot, from its step log
 * (data/arms/<home>/<year>/<arm>-...-30min.csv). The log gives the state of
 * charge after each slot and the energy discharged to the house; the start of
 * slot i is the end of slot i - 1, and of slot 0 the initial state.
 * @returns [{ socWh, dischargeOdometerWh }], one per slot
 */
export function replayArm(settings, slots) {
  const capacityWh = Number(settings.batteryCapacityWh);
  const eta = Number(settings.etaDischargeBps);
  let socWh = Math.floor((capacityWh * Number(settings.socInitialBps)) / BPS);
  let odometerWh = 0;
  return slots.map((s) => {
    const atStart = { socWh, dischargeOdometerWh: odometerWh };
    socWh = Math.floor((capacityWh * Number(s.socBps)) / BPS);
    odometerWh += Math.ceil((Number(s.dischargeWh) * BPS) / eta);
    return atStart;
  });
}
