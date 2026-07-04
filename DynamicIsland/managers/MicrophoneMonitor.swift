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
import CoreAudio
import SwiftUI
import Combine

// MARK: - CoreAudio Callback Function
// C function pointer for CoreAudio property listener
private func microphonePropertyListener(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context = inClientData else { return noErr }
    let monitor = Unmanaged<MicrophoneMonitor>.fromOpaque(context).takeUnretainedValue()
    
    DispatchQueue.main.async {
        Log.debug("MicrophoneMonitor: 📢 Microphone property changed")
        monitor.checkMicrophoneStatus()
    }

    return noErr
}

/// Fires when the system default input device changes; rebinds the running-state
/// listener to the new device so mic activity isn't missed after a device switch.
private func defaultInputDeviceChangeListener(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context = inClientData else { return noErr }
    let monitor = Unmanaged<MicrophoneMonitor>.fromOpaque(context).takeUnretainedValue()

    DispatchQueue.main.async {
        Log.debug("MicrophoneMonitor: 📢 Default input device changed")
        monitor.handleDefaultInputDeviceChanged()
    }

    return noErr
}

@MainActor
class MicrophoneMonitor: ObservableObject {
    // MARK: - Published Properties
    @Published var isMicActive: Bool = false
    @Published var activeApp: String? = nil
    @Published var isMonitoring: Bool = false
    
    // MARK: - Private Properties
    private var defaultInputDevice: AudioDeviceID = 0
    private var isListenerRegistered: Bool = false
    private var isDefaultDeviceListenerRegistered: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Configuration
    // Pure event-driven - no polling
    
    // MARK: - Initialization
    init() {
        // No initial setup needed
    }
    
    deinit {
        // Clean up listener synchronously
        // Remove property listener
        if isListenerRegistered, defaultInputDevice != 0 {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster
            )
            
            let context = Unmanaged.passUnretained(self).toOpaque()
            
            AudioObjectRemovePropertyListener(
                defaultInputDevice,
                &address,
                microphonePropertyListener,
                context
            )
        }

        if isDefaultDeviceListenerRegistered {
            var hwAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster
            )
            let context = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &hwAddress,
                defaultInputDeviceChangeListener,
                context
            )
        }
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring microphone usage
    func startMonitoring() {
        guard !isMonitoring else {
            Log.debug("MicrophoneMonitor: Already monitoring, skipping start")
            return
        }
        
        Log.debug("MicrophoneMonitor: 🟢 Starting microphone monitoring...")
        
        isMonitoring = true

        // Observe default-input-device changes first, so we recover (bind the
        // running-state listener) even if there is no input device right now.
        installDefaultDeviceListener()

        // Get default input device
        defaultInputDevice = getDefaultInputDevice()
        guard defaultInputDevice != 0 else {
            Log.debug("MicrophoneMonitor: ⚠️ No input device found (will bind when one appears)")
            return
        }

        Log.debug("MicrophoneMonitor: 🎤 Found input device ID: \(defaultInputDevice)")

        // Check if property exists
        let propertyExists = checkPropertyExists()
        Log.debug("MicrophoneMonitor: Property exists: \(propertyExists)")

        // Setup event listener
        setupPropertyListener()

        // Check initial state
        checkMicrophoneStatus()

        Log.debug("MicrophoneMonitor: ✅ Started monitoring (event-driven only)")
    }
    
    /// Stop monitoring microphone usage
    func stopMonitoring() {
        guard isMonitoring else {
            Log.debug("MicrophoneMonitor: Not monitoring, skipping stop")
            return
        }
        
        Log.debug("MicrophoneMonitor: 🛑 Stopping monitoring...")
        
        isMonitoring = false

        // Remove property listener
        if isListenerRegistered {
            removePropertyListener()
        }
        removeDefaultDeviceListener()

        // Reset state
        if isMicActive {
            isMicActive = false
        }
        activeApp = nil

        Log.debug("MicrophoneMonitor: ✅ Stopped monitoring")
    }
    
    /// Toggle monitoring state
    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }
    
    // MARK: - Private Methods
    
    /// Get default input device ID
    private func getDefaultInputDevice() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        
        if status != noErr {
            Log.error("MicrophoneMonitor: ⚠️ Failed to get default input device (status: \(status))")
            return 0
        }
        
        return deviceID
    }
    
    /// Check if the property exists on the device
    private func checkPropertyExists() -> Bool {
        guard defaultInputDevice != 0 else { return false }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        let hasProperty = AudioObjectHasProperty(defaultInputDevice, &address)
        Log.debug("MicrophoneMonitor: Device \(defaultInputDevice) has property: \(hasProperty)")
        
        return hasProperty
    }
    
    /// Setup CoreAudio property listener
    private func setupPropertyListener() {
        guard defaultInputDevice != 0 else { return }
        
        // Use kAudioDevicePropertyDeviceIsRunningSomewhere (tracks when device is in use anywhere)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        // Pass self as context
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        let status = AudioObjectAddPropertyListener(
            defaultInputDevice,
            &address,
            microphonePropertyListener,
            context
        )
        
        if status == noErr {
            isListenerRegistered = true
            Log.debug("MicrophoneMonitor: ✅ Property listener registered")
        } else {
            Log.error("MicrophoneMonitor: ⚠️ Failed to register property listener (status: \(status))")
        }
    }
    
    /// Remove CoreAudio property listener
    private func removePropertyListener() {
        guard defaultInputDevice != 0, isListenerRegistered else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        let status = AudioObjectRemovePropertyListener(
            defaultInputDevice,
            &address,
            microphonePropertyListener,
            context
        )
        
        if status == noErr {
            isListenerRegistered = false
            Log.debug("MicrophoneMonitor: ✅ Property listener removed")
        } else {
            Log.error("MicrophoneMonitor: ⚠️ Failed to remove property listener (status: \(status))")
        }
    }
    
    /// Install a listener for system default-input-device changes.
    private func installDefaultDeviceListener() {
        guard !isDefaultDeviceListenerRegistered else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputDeviceChangeListener,
            context
        )
        if status == noErr {
            isDefaultDeviceListenerRegistered = true
        } else {
            Log.error("MicrophoneMonitor: ⚠️ Failed to register default-device listener (status: \(status))")
        }
    }

    /// Remove the system default-input-device change listener.
    private func removeDefaultDeviceListener() {
        guard isDefaultDeviceListenerRegistered else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputDeviceChangeListener,
            context
        )
        isDefaultDeviceListenerRegistered = false
    }

    /// Re-bind the running-state listener to the new default input device.
    func handleDefaultInputDeviceChanged() {
        guard isMonitoring else { return }

        if isListenerRegistered {
            removePropertyListener()
        }

        defaultInputDevice = getDefaultInputDevice()
        if defaultInputDevice != 0 {
            Log.debug("MicrophoneMonitor: 🔁 Rebound to input device ID: \(defaultInputDevice)")
            setupPropertyListener()
            checkMicrophoneStatus()
        } else {
            // No input device anymore — clear any stale active state.
            if isMicActive { isMicActive = false }
            activeApp = nil
        }
    }

    /// Check current microphone status
    func checkMicrophoneStatus() {
        guard defaultInputDevice != 0 else { return }
        
        let isRunning = isDeviceRunning(defaultInputDevice)
        
        // Debug logging
        Log.debug("MicrophoneMonitor: 🔍 Checking... current=\(isMicActive), detected=\(isRunning)")
        
        // Update state if changed
        if isRunning != isMicActive {
            Log.debug("MicrophoneMonitor: 🔄 State change detected (\(isMicActive) -> \(isRunning))")
            
            withAnimation(.smooth) {
                isMicActive = isRunning
            }
            
            if isRunning {
                Log.debug("MicrophoneMonitor: 🎤 Microphone ACTIVE")
                // Could try to identify app here (TODO: investigate)
                activeApp = "Unknown App"
            } else {
                Log.debug("MicrophoneMonitor: ⚪ Microphone INACTIVE")
                activeApp = nil
            }
        }
    }
    
    /// Check if audio device is running
    private func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isRunning
        )
        
        if status != noErr {
            Log.error("MicrophoneMonitor: ⚠️ Failed to check device running status (status: \(status))")
            return false
        }
        
        return isRunning != 0
    }

}

// MARK: - Extensions

extension MicrophoneMonitor {
    /// Get current microphone status without async
    var currentMicStatus: Bool {
        return isMicActive
    }
    
    /// Check if monitoring is available
    var isMonitoringAvailable: Bool {
        return getDefaultInputDevice() != 0
    }
}
