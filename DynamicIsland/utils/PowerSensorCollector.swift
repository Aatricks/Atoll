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

import Foundation
import IOKit

/// Where the headline `systemWatts` value came from, in priority order.
enum PowerSource: String, Equatable {
    case ioReport       // Apple Silicon SoC package power (CPU+GPU+ANE+DRAM)
    case smc            // Intel system total power (SMC PSTR)
    case batteryFlow    // last resort: battery discharge rate
    case unavailable
}

/// A single power snapshot. `systemWatts` is the headline number plotted in the graph;
/// the optional fields feed the detail popover and may be `nil` when the platform does not
/// expose them. Battery/adapter come from `AppleSmartBattery`; component watts from IOReport.
struct PowerMetrics: Equatable {
    let systemWatts: Double         // headline → main graph
    let cpuWatts: Double?
    let gpuWatts: Double?
    let aneWatts: Double?
    let dramWatts: Double?
    let displayWatts: Double?       // internal display ("DISP"); external is excluded
    let batteryWatts: Double?       // magnitude of battery flow (always >= 0)
    let isCharging: Bool
    let isOnAC: Bool
    let adapterWatts: Double?       // estimated delivered power (AdapterVoltage x Current)
    let adapterRatedWatts: Double?  // adapter's advertised wattage
    let source: PowerSource

    static let zero = PowerMetrics(
        systemWatts: 0, cpuWatts: nil, gpuWatts: nil, aneWatts: nil, dramWatts: nil,
        displayWatts: nil, batteryWatts: nil, isCharging: false, isOnAC: false,
        adapterWatts: nil, adapterRatedWatts: nil, source: .unavailable
    )
}

/// Reads instantaneous power draw. Primary source is the IOReport "Energy Model" group on
/// Apple Silicon (energy accumulates in millijoules per channel; power = Δenergy / Δtime),
/// mirroring the IOReport usage already proven in `CPUSensorCollector`. Battery charge/
/// discharge flow and adapter delivery come from the `AppleSmartBattery` IORegistry node.
/// Intel Macs fall back to the SMC `PSTR` key.
final class PowerSensorCollector {
    private let hardware = AppleHardwareInfo.shared
    private var channels: CFMutableDictionary?
    private var subscription: IOReportSubscriptionRef?
    /// Per-component cumulative energy (joules) and timestamp from the previous sample. Power is
    /// the difference of these monotonic counters over elapsed time — the approach used by Stats.
    /// We deliberately do NOT use IOReportCreateSamplesDelta: on some chips (e.g. M5) it returns
    /// 0 for the CPU channels, while reading the raw cumulative counter and diffing it works.
    private var previousEnergy: [String: Double]?
    private var previousEnergyTime: TimeInterval?

    init() {
        setupEnergyChannels()
    }

    deinit {
        if let subscription {
            IOReportCreateSamples(subscription, nil, nil) // best-effort flush
        }
    }

    // MARK: - Public API

    func readPower() -> PowerMetrics {
        let battery = readBattery()
        let components = readComponentWatts()

        // Component power: prefer IOReport "Energy Model"; fall back to SMC keys (as Stats does)
        // for whatever that group doesn't expose on a given chip (CPU is 0 in Energy Model here).
        let cpu = positive(components.cpu) ?? readSMC(Self.cpuPowerKeys)
        let gpu = positive(components.gpu) ?? readSMC(Self.gpuPowerKeys)
        let ane = positive(components.ane)
        let dram = positive(components.dram) ?? readSMC(Self.dramPowerKeys)
        let display = positive(components.display)

        // Headline: true system total from SMC "PSTR" if present, else the sum of components,
        // else battery discharge (on battery), else unavailable.
        let smcSystem = readSMC(Self.systemPowerKeys)
        let socSum = sumPositive([cpu, gpu, ane, dram])
        let batteryDischarge = (battery.isOnAC || battery.batteryWatts == nil)
            ? nil
            : battery.batteryWatts.map(abs)

        let (systemWatts, source) = Self.resolveSystemWatts(
            smcSystem: smcSystem,
            socSum: socSum,
            batteryDischarge: batteryDischarge
        )

        return PowerMetrics(
            systemWatts: systemWatts,
            cpuWatts: cpu,
            gpuWatts: gpu,
            aneWatts: ane,
            dramWatts: dram,
            displayWatts: display,
            batteryWatts: battery.batteryWatts.map(abs),
            isCharging: battery.isCharging,
            isOnAC: battery.isOnAC,
            adapterWatts: battery.adapterWatts,
            adapterRatedWatts: battery.adapterRatedWatts,
            source: source
        )
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private func sumPositive(_ values: [Double?]) -> Double? {
        let parts = values.compactMap { $0 }.filter { $0 > 0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Convert an energy delta in millijoules over a window into average watts.
    static func wattsFromEnergyDelta(milliJoules: Double, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return (milliJoules / 1000.0) / seconds // mJ -> J, then J/s = W
    }

    /// Convert a raw IOReport energy value to joules using its unit label. IOReport channels
    /// report energy in different units per channel (mJ, µJ, nJ); assuming one unit for all
    /// of them inflates or deflates the result by orders of magnitude.
    static func joules(fromRaw raw: Double, unit: String) -> Double {
        switch unit.lowercased() {
        case "mj": return raw / 1_000
        case "uj", "µj": return raw / 1_000_000
        case "nj": return raw / 1_000_000_000
        case "j": return raw
        default: return raw / 1_000 // assume millijoules when unlabeled
        }
    }

    /// Average watts from a raw energy delta in `unit` over `seconds`.
    static func watts(fromRaw raw: Double, unit: String, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return joules(fromRaw: raw, unit: unit) / seconds
    }

    /// Battery power from voltage (mV) and signed amperage (mA). Sign is preserved.
    static func batteryWatts(voltageMilliVolts: Double, amperageMilliAmps: Double) -> Double {
        (voltageMilliVolts / 1000.0) * (amperageMilliAmps / 1000.0)
    }

    /// Headline resolution order: SMC "System Total" (the truest whole-machine figure, like
    /// Stats' `PSTR`) → sum of per-component package power → battery discharge → unavailable.
    /// A reading of exactly 0 is treated as "not available" so empty sources fall through.
    static func resolveSystemWatts(smcSystem: Double?, socSum: Double?, batteryDischarge: Double?) -> (Double, PowerSource) {
        if let smcSystem, smcSystem > 0 { return (smcSystem, .smc) }
        if let socSum, socSum > 0 { return (socSum, .ioReport) }
        if let batteryDischarge, batteryDischarge > 0 { return (batteryDischarge, .batteryFlow) }
        return (0, .unavailable)
    }

    // MARK: - Battery / adapter (AppleSmartBattery)

    private struct BatteryReading {
        var batteryWatts: Double?
        var isCharging: Bool
        var isOnAC: Bool
        var adapterWatts: Double?
        var adapterRatedWatts: Double?
    }

    private func readBattery() -> BatteryReading {
        var reading = BatteryReading(batteryWatts: nil, isCharging: false, isOnAC: false,
                                     adapterWatts: nil, adapterRatedWatts: nil)
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return reading }
        defer { IOObjectRelease(service) }
        guard let props = di_getIOProperties(service) else { return reading }

        reading.isCharging = boolValue(props["IsCharging"])
        reading.isOnAC = boolValue(props["ExternalConnected"])

        if let voltage = doubleValue(props["Voltage"]),
           let amperage = doubleValue(props["Amperage"]) {
            reading.batteryWatts = Self.batteryWatts(voltageMilliVolts: voltage, amperageMilliAmps: amperage)
        }

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            reading.adapterRatedWatts = doubleValue(adapter["Watts"])
            if let aVoltage = doubleValue(adapter["AdapterVoltage"]),
               let aCurrent = doubleValue(adapter["Current"]) {
                reading.adapterWatts = (aVoltage / 1000.0) * (aCurrent / 1000.0)
            }
        }
        return reading
    }

    // MARK: - SMC power keys (per exelban/Stats Modules/Sensors/values.swift)

    /// Whole-machine power. `PSTR` ("System Total") is the headline figure when present.
    static let systemPowerKeys = ["PSTR", "PMTR"]
    /// CPU package power. Tried in order; first sane reading wins.
    static let cpuPowerKeys = ["PCPC", "PCTR", "PCPT", "PCPR", "PC0C", "PCAM"]
    /// GPU power (used only if IOReport "GPU Energy" is unavailable on this chip).
    static let gpuPowerKeys = ["PG0R", "PG0C", "PGTR"]
    static let dramPowerKeys = ["PC3C", "PMTR"]

    /// First SMC key in `keys` that returns a finite, plausible wattage (0 < w < 1000).
    private func readSMC(_ keys: [String]) -> Double? {
        for key in keys {
            if let value = SMC.shared.getValue(key), value.isFinite, value > 0, value < 1000 {
                return value
            }
        }
        return nil
    }

    // MARK: - IOReport "Energy Model"

    private struct ComponentWatts {
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var dram: Double?
        var display: Double?
        /// Sum of whatever components were available; `nil` when none were read (no delta yet).
        var total: Double? {
            let parts = [cpu, gpu, ane, dram, display].compactMap { $0 }
            return parts.isEmpty ? nil : parts.reduce(0, +)
        }
    }

    private func readComponentWatts() -> ComponentWatts {
        guard let subscription, let channels else { return ComponentWatts() }
        let now = Date().timeIntervalSince1970
        guard let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return ComponentWatts()
        }

        // Read the CUMULATIVE energy counter (joules) per component bucket and diff successive
        // reads ourselves — Stats' method. (IOReportCreateSamplesDelta zeroes CPU on some chips.)
        // CPU prefers the "CPU Energy" aggregate, else per-cluster "ECPU"/"PCPU". Internal
        // display is "DISP" (external "DISPEXT" is excluded).
        let samples = iterateChannels(sample)
        var energy: [String: Double] = [:]
        for s in samples {
            guard s.group == "Energy Model" else { continue } // the merged subscription also carries CPU/GPU stats
            let name = s.name
            let joules = Self.joules(fromRaw: s.value, unit: s.unit)
            if name.hasSuffix("CPU Energy") { energy["cpu", default: 0] += joules }
            else if name.hasSuffix("GPU Energy") { energy["gpu", default: 0] += joules }
            else if name.hasPrefix("ANE") { energy["ane", default: 0] += joules }
            else if name.hasPrefix("DRAM") { energy["dram", default: 0] += joules }
            else if name.hasPrefix("DISPEXT") { /* external display, not the laptop screen */ }
            else if name.hasPrefix("DISP") { energy["display", default: 0] += joules }
            else if name == "ECPU" || name == "PCPU" { energy["cpuCluster", default: 0] += joules }
        }

        defer { previousEnergy = energy; previousEnergyTime = now }
        guard let prev = previousEnergy, let prevTime = previousEnergyTime else {
            return ComponentWatts() // first sample: establish a baseline, no power yet
        }
        let elapsed = now - prevTime
        // Discard out-of-range windows: a tiny interval divides by ~0; a huge one means
        // monitoring was paused. The defer re-baselines either way, so the next tick recovers.
        guard elapsed >= 0.2, elapsed <= 10 else { return ComponentWatts() }

        // Power = Δ(cumulative joules) / elapsed. A 0 reading → nil so the SMC fallback applies.
        func watts(_ key: String) -> Double? {
            guard let cur = energy[key], let p = prev[key] else { return nil }
            let w = (cur - p) / elapsed
            return w > 0 ? w : nil
        }

        var result = ComponentWatts()
        result.cpu = watts("cpu") ?? watts("cpuCluster")
        result.gpu = watts("gpu")
        result.ane = watts("ane")
        result.dram = watts("dram")
        result.display = watts("display")
        return result
    }

    private struct EnergySample {
        let group: String
        let name: String
        let unit: String
        let value: Double // raw cumulative energy counter in `unit` (since boot)
    }

    private func iterateChannels(_ data: CFDictionary) -> [EnergySample] {
        let key = "IOReportChannels" as CFString
        var rawValue: UnsafeRawPointer?
        let found = withUnsafeMutablePointer(to: &rawValue) { pointer -> Bool in
            CFDictionaryGetValueIfPresent(data, Unmanaged.passUnretained(key).toOpaque(), pointer)
        }
        guard found, let rawValue else { return [] }
        let array = unsafeBitCast(rawValue, to: CFArray.self)
        var result: [EnergySample] = []
        for index in 0..<CFArrayGetCount(array) {
            let element = CFArrayGetValueAtIndex(array, index)
            let entry = unsafeBitCast(element, to: CFDictionary.self)
            let group = IOReportChannelGetGroup(entry)?.takeUnretainedValue() as String? ?? ""
            let name = IOReportChannelGetChannelName(entry)?.takeUnretainedValue() as String? ?? ""
            let unit = IOReportChannelGetUnitLabel(entry)?.takeUnretainedValue() as String? ?? ""
            let value = Double(IOReportSimpleGetIntegerValue(entry, 0))
            result.append(EnergySample(group: group, name: name, unit: unit.trimmingCharacters(in: .whitespaces), value: value))
        }
        return result
    }

    private func setupEnergyChannels() {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            Log.debug("PowerSensorCollector: no Energy Model channels (Intel or unsupported)", .performance)
            return
        }
        guard let copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channel) else { return }
        channels = copy
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, copy, &subscribed, 0, nil)
        subscribed?.release()
    }

    // MARK: - IORegistry value coercion

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
