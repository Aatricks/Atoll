/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest
@testable import Atoll

/// Covers the pure math behind `PowerSensorCollector`: energy→watts conversion, battery
/// voltage×amperage power, and the headline source-resolution order. The IOReport / SMC /
/// IORegistry reads themselves are environment-dependent and verified live, not here.
final class PowerSensorCollectorTests: XCTestCase {

    // MARK: - Energy delta → watts

    func test_wattsFromEnergyDelta_convertsMilliJoulesPerSecond() {
        // 2000 mJ over 2 s = 1 J/s = 1 W
        XCTAssertEqual(PowerSensorCollector.wattsFromEnergyDelta(milliJoules: 2000, seconds: 2), 1.0, accuracy: 0.0001)
        // 15000 mJ over 1 s = 15 W
        XCTAssertEqual(PowerSensorCollector.wattsFromEnergyDelta(milliJoules: 15000, seconds: 1), 15.0, accuracy: 0.0001)
    }

    func test_wattsFromEnergyDelta_guardsAgainstNonPositiveInterval() {
        XCTAssertEqual(PowerSensorCollector.wattsFromEnergyDelta(milliJoules: 5000, seconds: 0), 0)
        XCTAssertEqual(PowerSensorCollector.wattsFromEnergyDelta(milliJoules: 5000, seconds: -1), 0)
    }

    // MARK: - Unit-aware energy conversion

    func test_joules_scalesByUnitLabel() {
        XCTAssertEqual(PowerSensorCollector.joules(fromRaw: 5000, unit: "mJ"), 5.0, accuracy: 1e-9)
        XCTAssertEqual(PowerSensorCollector.joules(fromRaw: 5_000_000, unit: "uJ"), 5.0, accuracy: 1e-9)
        XCTAssertEqual(PowerSensorCollector.joules(fromRaw: 5_000_000, unit: "µJ"), 5.0, accuracy: 1e-9)
        XCTAssertEqual(PowerSensorCollector.joules(fromRaw: 5_000_000_000, unit: "nJ"), 5.0, accuracy: 1e-6)
        XCTAssertEqual(PowerSensorCollector.joules(fromRaw: 5, unit: "J"), 5.0, accuracy: 1e-9)
        // Unlabeled defaults to millijoules.
        XCTAssertEqual(PowerSensorCollector.joules(fromRaw: 5000, unit: ""), 5.0, accuracy: 1e-9)
    }

    func test_watts_fromRaw_scalesUnitThenDividesByTime() {
        // 10,000,000 nJ over 1 s = 0.01 J/s = 0.01 W — the nJ-vs-mJ bug would report 10,000 W.
        XCTAssertEqual(PowerSensorCollector.watts(fromRaw: 10_000_000, unit: "nJ", seconds: 1), 0.01, accuracy: 1e-6)
        // 20,000 mJ over 2 s = 10 W
        XCTAssertEqual(PowerSensorCollector.watts(fromRaw: 20_000, unit: "mJ", seconds: 2), 10.0, accuracy: 1e-6)
        XCTAssertEqual(PowerSensorCollector.watts(fromRaw: 5000, unit: "mJ", seconds: 0), 0)
    }

    // MARK: - Battery voltage × amperage

    func test_batteryWatts_dischargeIsNegative_chargeIsPositive() {
        // 12.0 V (12000 mV) discharging at 3.0 A (-3000 mA) → -36 W
        XCTAssertEqual(
            PowerSensorCollector.batteryWatts(voltageMilliVolts: 12000, amperageMilliAmps: -3000),
            -36.0, accuracy: 0.0001
        )
        // 12.0 V charging at 2.0 A (+2000 mA) → +24 W
        XCTAssertEqual(
            PowerSensorCollector.batteryWatts(voltageMilliVolts: 12000, amperageMilliAmps: 2000),
            24.0, accuracy: 0.0001
        )
    }

    func test_batteryWatts_zeroFlowWhenIdle() {
        XCTAssertEqual(
            PowerSensorCollector.batteryWatts(voltageMilliVolts: 12595, amperageMilliAmps: 0),
            0, accuracy: 0.0001
        )
    }

    // MARK: - Headline resolution order

    func test_resolve_prefersSMCSystemTotal() {
        // SMC "System Total" is the truest whole-machine figure — it wins over the partial SoC sum.
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(smcSystem: 30, socSum: 18.5, batteryDischarge: 40)
        XCTAssertEqual(watts, 30, accuracy: 0.0001)
        XCTAssertEqual(source, .smc)
    }

    func test_resolve_fallsBackToSoCSumWhenNoSMC() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(smcSystem: nil, socSum: 18.5, batteryDischarge: 40)
        XCTAssertEqual(watts, 18.5, accuracy: 0.0001)
        XCTAssertEqual(source, .ioReport)
    }

    func test_resolve_fallsBackToBatteryDischargeLast() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(smcSystem: nil, socSum: nil, batteryDischarge: 40)
        XCTAssertEqual(watts, 40, accuracy: 0.0001)
        XCTAssertEqual(source, .batteryFlow)
    }

    func test_resolve_treatsZeroAsNotAvailable() {
        // First sample (no delta) yields 0 W — must fall through, not report 0.
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(smcSystem: 0, socSum: 0, batteryDischarge: 12)
        XCTAssertEqual(watts, 12, accuracy: 0.0001)
        XCTAssertEqual(source, .batteryFlow)
    }

    func test_resolve_unavailableWhenNothingPresent() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(smcSystem: nil, socSum: nil, batteryDischarge: nil)
        XCTAssertEqual(watts, 0)
        XCTAssertEqual(source, .unavailable)
    }

    // MARK: - PowerMetrics.zero

    func test_zeroMetrics_isStableAndEquatable() {
        XCTAssertEqual(PowerMetrics.zero, PowerMetrics.zero)
        XCTAssertEqual(PowerMetrics.zero.systemWatts, 0)
        XCTAssertEqual(PowerMetrics.zero.source, .unavailable)
        XCTAssertNil(PowerMetrics.zero.cpuWatts)
        XCTAssertNil(PowerMetrics.zero.batteryWatts)
        XCTAssertFalse(PowerMetrics.zero.isCharging)
        XCTAssertFalse(PowerMetrics.zero.isOnAC)
    }
}
