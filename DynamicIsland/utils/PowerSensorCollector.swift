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
    let batteryWatts: Double?       // magnitude of battery flow (always >= 0)
    let isCharging: Bool
    let isOnAC: Bool
    let adapterWatts: Double?       // estimated delivered power (AdapterVoltage x Current)
    let adapterRatedWatts: Double?  // adapter's advertised wattage
    let source: PowerSource

    static let zero = PowerMetrics(
        systemWatts: 0, cpuWatts: nil, gpuWatts: nil, aneWatts: nil, dramWatts: nil,
        batteryWatts: nil, isCharging: false, isOnAC: false,
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
    private var previousSample: (samples: CFDictionary, time: TimeInterval)?

    /// Aggregate channel names in the "Energy Model" group (per `ioreg`/powermetrics).
    private let cpuEnergyChannel = "CPU Energy"
    private let gpuEnergyChannel = "GPU Energy"
    private let aneEnergyChannel = "ANE Energy"
    private let dramEnergyChannel = "DRAM Energy"

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

        let socWatts = components.total
        let smcWatts = readSMCSystemPower()
        let batteryDischarge = (battery.isOnAC || battery.batteryWatts == nil)
            ? nil
            : battery.batteryWatts.map(abs)

        let (systemWatts, source) = Self.resolveSystemWatts(
            soc: socWatts,
            smc: smcWatts,
            batteryDischarge: batteryDischarge
        )

        return PowerMetrics(
            systemWatts: systemWatts,
            cpuWatts: components.cpu,
            gpuWatts: components.gpu,
            aneWatts: components.ane,
            dramWatts: components.dram,
            batteryWatts: battery.batteryWatts.map(abs),
            isCharging: battery.isCharging,
            isOnAC: battery.isOnAC,
            adapterWatts: battery.adapterWatts,
            adapterRatedWatts: battery.adapterRatedWatts,
            source: source
        )
    }

    // MARK: - Pure helpers (unit-tested)

    /// Convert an energy delta in millijoules over a window into average watts.
    static func wattsFromEnergyDelta(milliJoules: Double, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return (milliJoules / 1000.0) / seconds // mJ -> J, then J/s = W
    }

    /// Battery power from voltage (mV) and signed amperage (mA). Sign is preserved.
    static func batteryWatts(voltageMilliVolts: Double, amperageMilliAmps: Double) -> Double {
        (voltageMilliVolts / 1000.0) * (amperageMilliAmps / 1000.0)
    }

    /// Headline resolution order: SoC package power (Apple Silicon) → SMC total (Intel) →
    /// battery discharge → unavailable. A SoC/SMC reading of exactly 0 is treated as "not
    /// yet available" so the first sample (no delta) falls through to the next source.
    static func resolveSystemWatts(soc: Double?, smc: Double?, batteryDischarge: Double?) -> (Double, PowerSource) {
        if let soc, soc > 0 { return (soc, .ioReport) }
        if let smc, smc > 0 { return (smc, .smc) }
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

    // MARK: - SMC (Intel fallback)

    private func readSMCSystemPower() -> Double? {
        guard hardware.platform == .intel else { return nil }
        // PSTR = system total power (watts) on Intel SMC.
        if let value = SMC.shared.getValue("PSTR"), value > 0, value < 1000 {
            return value
        }
        return nil
    }

    // MARK: - IOReport "Energy Model"

    private struct ComponentWatts {
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var dram: Double?
        /// Sum of whatever components were available; `nil` when none were read (no delta yet).
        var total: Double? {
            let parts = [cpu, gpu, ane, dram].compactMap { $0 }
            return parts.isEmpty ? nil : parts.reduce(0, +)
        }
    }

    private func readComponentWatts() -> ComponentWatts {
        guard let channels, let subscription else { return ComponentWatts() }
        let now = Date().timeIntervalSince1970
        guard let currentSample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return ComponentWatts()
        }
        defer { previousSample = (currentSample, now) }
        guard let previous = previousSample,
              let diff = IOReportCreateSamplesDelta(previous.samples, currentSample, nil)?.takeRetainedValue() else {
            return ComponentWatts() // first sample: establish a baseline, no power yet
        }
        let elapsed = now - previous.time
        guard elapsed > 0 else { return ComponentWatts() }

        // Sum energy (mJ) per aggregate channel, with a per-cluster fallback for CPU.
        var energy: [String: Double] = [:]
        var eCpuFallback = 0.0
        var pCpuFallback = 0.0
        for sample in iterateChannels(diff) {
            switch sample.name {
            case cpuEnergyChannel, gpuEnergyChannel, aneEnergyChannel, dramEnergyChannel:
                energy[sample.name, default: 0] += sample.value
            case "ECPU":
                eCpuFallback += sample.value
            case "PCPU":
                pCpuFallback += sample.value
            default:
                break
            }
        }

        func watts(_ key: String) -> Double? {
            guard let mJ = energy[key] else { return nil }
            return Self.wattsFromEnergyDelta(milliJoules: mJ, seconds: elapsed)
        }

        var result = ComponentWatts()
        result.cpu = watts(cpuEnergyChannel)
            ?? ((eCpuFallback + pCpuFallback) > 0
                ? Self.wattsFromEnergyDelta(milliJoules: eCpuFallback + pCpuFallback, seconds: elapsed)
                : nil)
        result.gpu = watts(gpuEnergyChannel)
        result.ane = watts(aneEnergyChannel)
        result.dram = watts(dramEnergyChannel)
        return result
    }

    private struct EnergySample {
        let name: String
        let value: Double // millijoules accumulated in the delta window
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
            let name = IOReportChannelGetChannelName(entry)?.takeUnretainedValue() as String? ?? ""
            let value = Double(IOReportSimpleGetIntegerValue(entry, 0))
            result.append(EnergySample(name: name, value: value))
        }
        return result
    }

    private func setupEnergyChannels() {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            Log.debug("PowerSensorCollector: no Energy Model channels (Intel or unsupported)", .performance)
            return
        }
        guard let copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(channel), channel) else {
            return
        }
        channels = copy
        var dictionary: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, copy, &dictionary, 0, nil)
        dictionary?.release()
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
