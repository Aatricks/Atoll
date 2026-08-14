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

import Defaults
import SwiftUI

/// SwiftUI view for download and installation progress.
/// Features a circular progress indicator with percentage, download speed,
/// animated phase transitions, and a gradient progress bar matching the channel color.
struct UpdateProgressView: View {
    @ObservedObject var state: UpdateUIState
    @State private var pulseScale: CGFloat = 1.0
    @State private var rotationAngle: Double = 0

    private var channel: UpdateChannel {
        Defaults[.updateChannel]
    }

    private var channelColor: Color {
        Color(channel.badgeColor)
    }

    private var progressPercent: Int {
        Int(state.progress * 100)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Circular progress indicator
            ZStack {
                // Background ring
                Circle()
                    .stroke(channelColor.opacity(0.15), lineWidth: 8)
                    .frame(width: 120, height: 120)

                // Progress ring
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                channelColor.opacity(0.4),
                                channelColor,
                            ]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: state.progress)

                // Center content
                VStack(spacing: 4) {
                    Text("\(progressPercent)%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(channelColor)
                        .contentTransition(.numericText())

                    Image(systemName: state.phase == .extracting ? "archivebox" : "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse, isActive: true)
                }
            }
            .scaleEffect(pulseScale)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseScale = 1.03
                }
            }

            // Phase label
            Text(phaseLabel)
                .font(.headline)
                .foregroundStyle(.primary)
                .animation(.easeInOut, value: state.phase)

            // Download stats
            if state.phase == .downloading {
                HStack(spacing: 16) {
                    Label {
                        Text(state.downloadSpeedString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(channelColor)
                    }

                    if state.totalBytes > 0 {
                        Text("of \(state.totalSizeString)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .transition(.opacity)
            }

            // Linear progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(channelColor.opacity(0.15))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [channelColor.opacity(0.7), channelColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * state.progress, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: state.progress)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 40)

            // Phase steps
            HStack(spacing: 0) {
                phaseStep("Download", systemImage: "arrow.down.circle.fill", isActive: state.phase == .downloading, isComplete: state.phase != .downloading && state.phase != .checking)
                stepConnector(isComplete: state.phase != .downloading)
                phaseStep("Extract", systemImage: "archivebox.fill", isActive: state.phase == .extracting, isComplete: state.phase == .readyToInstall || state.phase == .installing || state.phase == .installed)
                stepConnector(isComplete: state.phase == .installing || state.phase == .installed)
                phaseStep("Install", systemImage: "checkmark.circle.fill", isActive: state.phase == .installing || state.phase == .readyToInstall, isComplete: state.phase == .installed)
            }
            .padding(.horizontal, 40)

            Spacer()

            // Cancel button
            if state.phase == .downloading {
                Button("Cancel") {
                    state.cancelAction?()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.bottom, 20)
            }

            // Install & Relaunch button (when ready)
            if state.phase == .readyToInstall {
                Button {
                    state.updateReply?(.install)
                } label: {
                    Text("Install & Relaunch")
                        .font(.system(.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(channelColor)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 380)
        .background(.ultraThinMaterial)
    }

    private var phaseLabel: String {
        switch state.phase {
        case .downloading:    return "Downloading Update…"
        case .extracting:     return "Extracting Update…"
        case .readyToInstall: return "Ready to Install"
        case .installing:     return "Installing…"
        case .installed:      return "Update Installed!"
        default:              return state.phase.displayName
        }
    }

    @ViewBuilder
    private func phaseStep(_ label: String, systemImage: String, isActive: Bool, isComplete: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(isComplete || isActive ? channelColor : Color.secondary.opacity(0.5))
                .symbolEffect(.pulse, isActive: isActive)

            Text(label)
                .font(.caption2)
                .foregroundStyle(isActive || isComplete ? Color.primary : Color.secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stepConnector(isComplete: Bool) -> some View {
        Rectangle()
            .fill(isComplete ? channelColor.opacity(0.5) : Color.secondary.opacity(0.2))
            .frame(width: 40, height: 2)
            .padding(.bottom, 16)
    }
}

// MARK: - Preview

#Preview("Downloading") {
    UpdateProgressView(state: {
        let s = UpdateUIState()
        s.phase = .downloading
        s.progress = 0.65
        s.downloadedBytes = 15_728_640
        s.totalBytes = 24_000_000
        return s
    }())
}

#Preview("Extracting") {
    UpdateProgressView(state: {
        let s = UpdateUIState()
        s.phase = .extracting
        s.progress = 0.3
        return s
    }())
}

#Preview("Ready to Install") {
    UpdateProgressView(state: {
        let s = UpdateUIState()
        s.phase = .readyToInstall
        s.progress = 1.0
        return s
    }())
}
