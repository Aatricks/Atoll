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
import SwiftUI
import Observation
import Defaults
import Combine

@Observable
@MainActor
class DownloadManager {
    static let shared = DownloadManager()
    
    private(set) var isDownloading: Bool = false
    private(set) var isDownloadCompleted: Bool = false
    
    private let coordinator = DynamicIslandViewCoordinator.shared
    private var source: DispatchSourceFileSystemObject?
    // Fallback poll used only while a download is active: the directory vnode
    // source reliably fires when Safari *creates* a `.download` package but not
    // when it removes it on cancel (and writes inside the package never bubble
    // up), so an active download could otherwise never resolve.
    private var activePollTimer: DispatchSourceTimer?
    // Seconds without a write before an in-progress download is treated as
    // stalled (cancelled or paused). Long enough not to trip on a slow/bursty
    // connection; short enough that cancelling clears the indicator promptly.
    private let stalledDownloadThreshold: TimeInterval = 5.0
    // How long a stalled `.download` package (Safari leaves it on disk after a
    // cancel) is watched for a resume before we stop polling for it.
    private let abandonDownloadThreshold: TimeInterval = 90.0
    // First time each active package was seen not-progressing (for abandonment).
    private var stalledSince: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.dynamicisland.downloads.monitor", qos: .utility)
    private var completionTimer: Timer?
    private var hasPerformedInitialScan: Bool = false
    private var initialCrDownloadFiles: Set<String> = []
    private var previousAllFiles: Set<String> = []
    private var ignoredFiles: Set<String> = []
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    
    private var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
    
    init() {
        requestDownloadsPermissionIfNeeded()
        startMonitoringIfNeeded()
        
        Defaults.publisher(.enableDownloadListener)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.startMonitoringIfNeeded()
                }
            }
            .store(in: &cancellables)
    }
    
    private func startMonitoringIfNeeded() {
        if Defaults[.enableDownloadListener] {
            startMonitoring()
        } else {
            stopMonitoring()
            updateDownloadingState(isActive: false)
        }
    }
    
    private func startMonitoring() {
        guard source == nil, let downloadsDirectory else { return }
        
        hasPerformedInitialScan = false
        initialCrDownloadFiles.removeAll()
        previousAllFiles.removeAll()
        ignoredFiles.removeAll()
        stalledSince.removeAll()
        isDownloading = false

        let path = downloadsDirectory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        
        src.setEventHandler { [weak self] in
            self?.scanDownloadsDirectory()
        }
        
        src.setCancelHandler {
            close(fd)
        }
        
        source = src
        src.resume()
        
        scanDownloadsDirectory()
    }
    
    private func stopMonitoring() {
        source?.cancel()
        source = nil
        stopActivePolling()

        hasPerformedInitialScan = false
        initialCrDownloadFiles.removeAll()
        ignoredFiles.removeAll()
        stalledSince.removeAll()
        isDownloading = false
    }

    /// Poll the Downloads directory while a download is in flight. Cheap because
    /// it only runs during an active download; it stops as soon as the download
    /// completes or is cancelled.
    private func startActivePolling() {
        guard activePollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.scanDownloadsDirectory()
        }
        activePollTimer = timer
        timer.resume()
    }

    private func stopActivePolling() {
        activePollTimer?.cancel()
        activePollTimer = nil
    }
    
    private func scanDownloadsDirectory() {
        guard let downloadsDirectory else { return }

        let crDownloadFiles: Set<String>
        let allFiles: Set<String>
        var activity: [String: Date] = [:]

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: downloadsDirectory,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
            )

            let inProgress = contents.filter {
                let ext = $0.pathExtension.lowercased()
                return ext == "crdownload" || ext == "download"
            }

            crDownloadFiles = Set(inProgress.map { $0.lastPathComponent })
            allFiles = Set(contents.map { $0.lastPathComponent })

            // Record the most recent write time for each in-progress item. Safari
            // leaves the `.download` package on disk when a download is cancelled,
            // so "still present" can't tell active from cancelled — but an active
            // download's data file keeps being written while a cancelled one's
            // mtime freezes. This lets us detect a stalled/cancelled download.
            for url in inProgress {
                activity[url.lastPathComponent] = latestWriteDate(of: url)
            }
        } catch {
            return
        }

        Task { @MainActor in
            self.processDownloadFiles(crDownloadFiles, allFiles: allFiles, activity: activity)
        }
    }

    /// Newest modification date among a download item's contents (for a `.download`
    /// package, the partial data file inside; for a flat file, the file itself).
    private func latestWriteDate(of url: URL) -> Date {
        let ownDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), !children.isEmpty else {
            return ownDate ?? .distantPast
        }
        let childDates = children.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return ([ownDate].compactMap { $0 } + childDates).max() ?? .distantPast
    }
    
    private func processDownloadFiles(_ crDownloadFiles: Set<String>, allFiles: Set<String>, activity: [String: Date]) {

        if !hasPerformedInitialScan {
            hasPerformedInitialScan = true
            initialCrDownloadFiles = crDownloadFiles
            previousAllFiles = allFiles
            ignoredFiles = crDownloadFiles
            isDownloading = false
            return
        }

        let disappearedFiles = initialCrDownloadFiles.subtracting(crDownloadFiles)
        let newRegularFiles = allFiles.subtracting(previousAllFiles).subtracting(crDownloadFiles)

        initialCrDownloadFiles = crDownloadFiles
        previousAllFiles = allFiles

        let now = Date()
        var activeFiles = crDownloadFiles.subtracting(ignoredFiles)

        // A package is "progressing" if it was written to recently. Safari leaves
        // the `.download` package on disk when a download is cancelled/paused, so
        // presence alone can't distinguish active from stopped — recent writes can.
        func progressing(_ name: String) -> Bool {
            guard let last = activity[name] else { return false }
            return now.timeIntervalSince(last) <= stalledDownloadThreshold
        }

        // Track how long each active package has been stalled; abandon (ignore)
        // one that has been stalled too long so we don't poll forever after a
        // real cancel, while still catching a resume within the window.
        for name in activeFiles {
            if progressing(name) {
                stalledSince[name] = nil
            } else if stalledSince[name] == nil {
                stalledSince[name] = now
            }
        }
        stalledSince = stalledSince.filter { activeFiles.contains($0.key) }
        let abandoned = Set(stalledSince.filter { now.timeIntervalSince($0.value) > abandonDownloadThreshold }.keys)
        if !abandoned.isEmpty {
            ignoredFiles.formUnion(abandoned)
            abandoned.forEach { stalledSince[$0] = nil }
            activeFiles.subtract(abandoned)
        }

        let hasActiveDownloads = !activeFiles.isEmpty
        let hasProgressing = activeFiles.contains(where: progressing)

        if isDownloading {
            if !hasActiveDownloads {
                // Package gone: completed (final file appeared) vs cancelled.
                if !newRegularFiles.isEmpty || disappearedFiles.isEmpty {
                    Log.debug("[DownloadManager] -> COMPLETED", .debug)
                    if !isDownloadCompleted {
                        updateDownloadingState(isActive: false)
                    }
                } else {
                    Log.debug("[DownloadManager] -> CANCELLED (package removed)", .debug)
                    closeDownloadViewImmediately()
                }
            } else if !hasProgressing {
                // Package present but not being written → cancelled or paused. Hide
                // the indicator but keep polling: a resume restarts the writes.
                Log.debug("[DownloadManager] -> PAUSED/CANCELLED (no recent writes)", .debug)
                closeDownloadViewImmediately()
            }
        } else if hasProgressing {
            // Fresh writes with the indicator hidden → a new download OR a resume.
            Log.debug("[DownloadManager] -> START/RESUME", .debug)
            updateDownloadingState(isActive: true)
        }

        // Keep polling while any active package exists so a resume is caught;
        // stop once everything is gone or abandoned.
        if hasActiveDownloads {
            startActivePolling()
        } else {
            stopActivePolling()
        }
    }
    
    private func requestDownloadsPermissionIfNeeded() {
        guard let downloadsDirectory else { return }
        _ = try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)
    }
    
    private func updateDownloadingState(isActive: Bool) {
        completionTimer?.invalidate()
        completionTimer = nil
        
        if isActive {
            isDownloadCompleted = false
            
            if !isDownloading {
                withAnimation(.smooth) {
                    isDownloading = true
                }
                coordinator.toggleExpandingView(
                    status: true,
                    type: .download,
                    value: 0,
                    browser: .chromium
                )
            }
            
        } else {
            if isDownloading {
                withAnimation(.smooth) {
                    isDownloadCompleted = true
                }
                
                completionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.closeDownloadView()
                    }
                }
            }
        }
    }
    
    private func closeDownloadView() {
        withAnimation(.smooth) {
            isDownloading = false
            isDownloadCompleted = false
        }

        coordinator.toggleExpandingView(
            status: false,
            type: .download,
            value: 0,
            browser: .chromium
        )
    }
    
    private func closeDownloadViewImmediately() {
        completionTimer?.invalidate()
        completionTimer = nil

        withAnimation(.smooth) {
            isDownloading = false
            isDownloadCompleted = false
        }
        
        coordinator.toggleExpandingView(
            status: false,
            type: .download,
            value: 0,
            browser: .chromium
        )
    }
}
