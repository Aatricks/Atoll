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

import SwiftUI

struct PowerStatsDetailView: View {
    @ObservedObject private var statsManager = StatsManager.shared

    private let accent = Color.yellow
    private let cardBackground = Color(nsColor: .windowBackgroundColor).opacity(0.65)

    private var metrics: PowerMetrics { statsManager.powerMetrics }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatsCard(title: String(localized: "System Power"), padding: 16, background: cardBackground, cornerRadius: 12) {
                    SystemPowerOverview(
                        current: metrics.systemWatts,
                        average: statsManager.avgPowerUsage,
                        peak: statsManager.maxPowerUsage,
                        sourceLabel: sourceLabel,
                        accent: accent
                    )
                }

                StatsCard(title: String(localized: "Battery & Adapter"), padding: 16, background: cardBackground, cornerRadius: 12) {
                    PowerBatteryCard(metrics: metrics, accent: accent)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 380, minHeight: 380)
    }

    private var sourceLabel: String {
        switch metrics.source {
        case .ioReport: return String(localized: "Apple Silicon · SoC package power")
        case .smc: return String(localized: "SMC · system total")
        case .batteryFlow: return String(localized: "Battery discharge")
        case .unavailable: return String(localized: "Unavailable")
        }
    }
}

private struct SystemPowerOverview: View {
    let current: Double
    let average: Double
    let peak: Double
    let sourceLabel: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(StatsFormatting.watts(current))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            DetailRow(color: accent.opacity(0.6), label: String(localized: "Average"), value: StatsFormatting.watts(average))
            DetailRow(color: accent.opacity(0.45), label: String(localized: "Peak"), value: StatsFormatting.watts(peak))
            DetailRow(color: nil, label: String(localized: "Source"), value: sourceLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct PowerBatteryCard: View {
    let metrics: PowerMetrics
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            DetailRow(color: stateColor, label: String(localized: "Status"), value: statusLabel)
            if let battery = metrics.batteryWatts {
                DetailRow(color: accent.opacity(0.7), label: batteryFlowLabel, value: StatsFormatting.watts(battery))
            }
            if let adapter = metrics.adapterWatts {
                DetailRow(color: Color.green.opacity(0.7), label: String(localized: "Adapter (delivering)"), value: StatsFormatting.watts(adapter))
            }
            if let rated = metrics.adapterRatedWatts, rated > 0 {
                DetailRow(color: Color.green.opacity(0.45), label: String(localized: "Adapter (rated)"), value: StatsFormatting.watts(rated))
            }
        }
    }

    private var statusLabel: String {
        if metrics.isCharging { return String(localized: "Charging") }
        if metrics.isOnAC { return String(localized: "Plugged in · not charging") }
        return String(localized: "On battery")
    }

    private var stateColor: Color {
        if metrics.isCharging { return .green }
        if metrics.isOnAC { return .yellow }
        return .orange
    }

    private var batteryFlowLabel: String {
        if metrics.isCharging { return String(localized: "Battery charge") }
        if metrics.isOnAC { return String(localized: "Battery flow") }
        return String(localized: "Battery discharge")
    }
}
