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

    func test_resolve_prefersSoCWhenAvailable() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(soc: 18.5, smc: 30, batteryDischarge: 40)
        XCTAssertEqual(watts, 18.5, accuracy: 0.0001)
        XCTAssertEqual(source, .ioReport)
    }

    func test_resolve_fallsBackToSMCWhenNoSoC() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(soc: nil, smc: 22, batteryDischarge: 40)
        XCTAssertEqual(watts, 22, accuracy: 0.0001)
        XCTAssertEqual(source, .smc)
    }

    func test_resolve_fallsBackToBatteryDischargeLast() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(soc: nil, smc: nil, batteryDischarge: 40)
        XCTAssertEqual(watts, 40, accuracy: 0.0001)
        XCTAssertEqual(source, .batteryFlow)
    }

    func test_resolve_treatsZeroSoCAsNotAvailable() {
        // First sample (no delta) yields 0 W SoC — must fall through, not report 0 from IOReport.
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(soc: 0, smc: nil, batteryDischarge: 12)
        XCTAssertEqual(watts, 12, accuracy: 0.0001)
        XCTAssertEqual(source, .batteryFlow)
    }

    func test_resolve_unavailableWhenNothingPresent() {
        let (watts, source) = PowerSensorCollector.resolveSystemWatts(soc: nil, smc: nil, batteryDischarge: nil)
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
