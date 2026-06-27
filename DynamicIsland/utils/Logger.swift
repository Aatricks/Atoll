/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
import OSLog
import SwiftUI
import Defaults

enum LogCategory: String {
    case lifecycle = "🔄"
    case memory = "💾"
    case performance = "⚡️"
    case ui = "🎨"
    case network = "🌐"
    case error = "❌"
    case warning = "⚠️"
    case success = "✅"
    case debug = "🔍"
    case extensions = "🧩"

    var osCategoryName: String {
        switch self {
        case .lifecycle: return "lifecycle"
        case .memory: return "memory"
        case .performance: return "performance"
        case .ui: return "ui"
        case .network: return "network"
        case .error: return "error"
        case .warning: return "warning"
        case .success: return "success"
        case .debug: return "debug"
        case .extensions: return "extensions"
        }
    }

    var defaultLevel: LogLevel {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .success, .ui, .network, .lifecycle, .memory, .performance, .extensions: return .info
        case .debug: return .debug
        }
    }
}

/// Battery-conscious logging over the unified logging system.
///
/// `debug`/`info`/`notice` are compiled out of Release builds entirely — the `@autoclosure`
/// message is never even constructed — so chatty diagnostics cost nothing in shipping
/// builds (no string formatting, no syscall, no disk write). `error`/`fault` stay in Release
/// but go through `os_log`, which is far cheaper than `NSLog` (deferred formatting, no
/// per-call lock) and whose output the system manages and reads on demand.
///
/// Prefer this over `NSLog`/`print`. Use Swift interpolation; mark only non-sensitive
/// values, never tokens or response bodies.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ebullioscopic.Atoll"

    private static func handle(_ category: LogCategory) -> OSLog {
        OSLog(subsystem: subsystem, category: category.osCategoryName)
    }

    @inline(__always)
    static func debug(_ message: @autoclosure () -> String, _ category: LogCategory = .debug) {
        #if DEBUG
        os_log("%{public}@", log: handle(category), type: .debug, message())
        #endif
    }

    @inline(__always)
    static func info(_ message: @autoclosure () -> String, _ category: LogCategory = .debug) {
        #if DEBUG
        os_log("%{public}@", log: handle(category), type: .info, message())
        #endif
    }

    /// Real problems. Kept in Release.
    @inline(__always)
    static func error(_ message: @autoclosure () -> String, _ category: LogCategory = .error) {
        os_log("%{public}@", log: handle(category), type: .error, message())
    }

    /// Programmer errors / "should never happen". Kept in Release.
    @inline(__always)
    static func fault(_ message: @autoclosure () -> String, _ category: LogCategory = .error) {
        os_log("%{public}@", log: handle(category), type: .fault, message())
    }
}

struct Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ebullioscopic.Atoll"
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `message` is an `@autoclosure`, so in Release (where the body is compiled out) the
    /// string is never built — existing `Logger.log("…\(x)…", category:)` call sites keep
    /// working unchanged but cost nothing in shipping builds.
    static func log(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        #if DEBUG
        let configuredLevel = Defaults[.logLevel]
        if configuredLevel == .none || category.defaultLevel.rawValue > configuredLevel.rawValue {
            return
        }
        let fileName = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let entry = "\(category.rawValue) [\(timestamp)] [\(fileName):\(line)] \(function) - \(message())"
        os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category.osCategoryName), type: .debug, entry)
        Swift.print(entry)
        #endif
    }

    static func trackMemory(
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        #if DEBUG
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024.0 / 1024.0
            log(String(format: "Memory used: %.2f MB", usedMB),
                category: .memory,
                file: file,
                function: function,
                line: line)
        }
        #endif
    }
}

extension View {
    func trackLifecycle(_ identifier: String) -> some View {
        self.modifier(ViewLifecycleTracker(identifier: identifier))
    }
}

struct ViewLifecycleTracker: ViewModifier {
    let identifier: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                Logger.log("\(identifier) appeared", category: .lifecycle)
                Logger.trackMemory()
            }
            .onDisappear {
                Logger.log("\(identifier) disappeared", category: .lifecycle)
                Logger.trackMemory()
            }
    }
}

// Global overrides to filter scattered print and NSLog statements throughout the app
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let configuredLevel = Defaults[.logLevel]
    if configuredLevel == .none { return }
    
    let message = items.map { "\($0)" }.joined(separator: separator)
    let lowerMessage = message.lowercased()
    
    let isError = message.contains("❌") || lowerMessage.contains("error") || lowerMessage.contains("failed")
    let isWarning = message.contains("⚠️") || lowerMessage.contains("warning")
    
    let simulatedLevel: LogLevel = isError ? .error : (isWarning ? .warning : .debug)
    
    if simulatedLevel.rawValue > configuredLevel.rawValue { return }
    
    Swift.print(message, terminator: terminator)
}

public func NSLog(_ format: String, _ args: CVarArg...) {
    let configuredLevel = Defaults[.logLevel]
    if configuredLevel == .none { return }
    
    let message = String(format: format, arguments: args)
    let lowerMessage = message.lowercased()
    
    let isError = message.contains("❌") || lowerMessage.contains("error") || lowerMessage.contains("failed")
    let isWarning = message.contains("⚠️") || lowerMessage.contains("warning")
    
    let simulatedLevel: LogLevel = isError ? .error : (isWarning ? .warning : .debug)
    
    if simulatedLevel.rawValue > configuredLevel.rawValue { return }
    
    Foundation.NSLog("%@", message)
}
