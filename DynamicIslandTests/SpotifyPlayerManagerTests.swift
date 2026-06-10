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

/// Records playback-transfer calls so tests can observe the manager's queue recovery.
private final class RecordingAPI: SpotifyAPI {
    var transferred: (devices: [String], play: Bool)?
    var transferCount = 0
    var transferError: Error?
    func currentUserPlaylists(limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyPlaylist> { .init(items: [], next: nil, total: 0) }
    func playlistTracks(playlistID: String, limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyTrack> { .init(items: [], next: nil, total: 0) }
    func savedTracks(limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyTrack> { .init(items: [], next: nil, total: 0) }
    func recentlyPlayed(limit: Int) async throws -> [SpotifyPlayHistoryItem] { [] }
    func search(query: String, types: [SpotifySearchType], limit: Int) async throws -> SpotifySearchResponse { .init(playlists: nil, albums: nil, tracks: nil) }
    func availableDevices() async throws -> [SpotifyDevice] { [] }
    func startPlayback(contextURI: String?, uris: [String]?, offsetURI: String?, deviceID: String?) async throws {}
    func setShuffle(_ on: Bool, deviceID: String?) async throws {}
    func transferPlayback(deviceIDs: [String], play: Bool) async throws {
        transferCount += 1
        if let e = transferError { throw e }
        transferred = (deviceIDs, play)
    }
}

@MainActor
final class SpotifyPlayerManagerTests: XCTestCase {
    private var api: RecordingAPI!
    private var manager: SpotifyPlayerManager!

    override func setUp() {
        super.setUp()
        api = RecordingAPI()
        manager = SpotifyPlayerManager(api: api)
    }

    private func makeReady(device: String = "atoll-dev") {
        manager.handle(["type": "ready", "device_id": device])
    }

    private func loadTrack(_ name: String = "Song") {
        manager.handle(["type": "state", "paused": true, "track": name, "artist": "A",
                        "duration": 200_000.0, "position": 0.0])
    }

    private func awaitRecovery() async {
        await manager.recoveryTask?.value
    }

    // MARK: - Transport on an empty queue recovers the session instead of failing

    func test_resume_withoutLoadedQueue_pullsSessionOntoDevice() async {
        makeReady()
        manager.resume()
        await awaitRecovery()
        XCTAssertEqual(api.transferred?.devices, ["atoll-dev"],
                       "resume on an empty SDK queue must transfer the session here, not eval JS that fails with 'no list was loaded'")
        XCTAssertEqual(api.transferred?.play, true)
    }

    func test_togglePlay_withoutLoadedQueue_pullsSessionOntoDevice() async {
        makeReady()
        manager.togglePlay()
        await awaitRecovery()
        XCTAssertEqual(api.transferred?.devices, ["atoll-dev"])
    }

    func test_nextTrack_withoutLoadedQueue_pullsSessionOntoDevice() async {
        makeReady()
        manager.nextTrack()
        await awaitRecovery()
        XCTAssertEqual(api.transferred?.devices, ["atoll-dev"])
    }

    func test_resume_withLoadedQueue_doesNotTransfer() async {
        makeReady()
        loadTrack()
        manager.resume()
        await awaitRecovery()
        XCTAssertNil(api.transferred, "with a queue loaded, transport goes straight to the SDK player")
    }

    func test_transport_withoutDevice_doesNotTransfer() async {
        manager.resume()   // never became ready: nowhere to transfer to
        await awaitRecovery()
        XCTAssertNil(api.transferred)
    }

    // MARK: - The SDK's "no list was loaded" playback error self-heals

    func test_playbackError_noListLoaded_recoversInsteadOfShowingError() async {
        makeReady()
        manager.handle(["type": "error", "kind": "playback",
                        "message": "Cannot perform operation; no list was loaded."])
        await awaitRecovery()
        XCTAssertEqual(api.transferred?.devices, ["atoll-dev"])
        XCTAssertNil(manager.statusMessage, "a recoverable SDK hiccup should not surface as a user-facing error")
    }

    func test_playbackError_noListLoaded_withoutDevice_showsStatusMessage() async {
        manager.handle(["type": "error", "kind": "playback",
                        "message": "Cannot perform operation; no list was loaded."])
        await awaitRecovery()
        XCTAssertNil(api.transferred, "no device to recover onto")
        XCTAssertNotNil(manager.statusMessage, "when recovery is impossible the error must not vanish silently")
    }

    func test_playbackError_other_showsStatusMessage() async {
        makeReady()
        manager.handle(["type": "error", "kind": "playback", "message": "Track restricted."])
        await awaitRecovery()
        XCTAssertNotNil(manager.statusMessage)
        XCTAssertNil(api.transferred)
    }

    func test_recoveryFailure_showsStatusMessage() async {
        makeReady()
        api.transferError = SpotifyAPIError.http(404)
        manager.resume()
        await awaitRecovery()
        XCTAssertNotNil(manager.statusMessage, "if the session can't be recovered the user needs to know")
    }

    func test_stop_clearsTrackState_soRestartStartsFromEmptyQueue() {
        makeReady()
        loadTrack()
        manager.stop()
        XCTAssertNil(manager.currentTrack,
                     "a reconnected SDK session starts with an empty queue; stale track state would mask that and route transport to doomed JS calls")
        XCTAssertNil(manager.currentTrackURI)
    }

    func test_recovery_isNotSpammedByRepeatedTransport() async {
        makeReady()
        manager.resume()
        manager.resume()
        manager.togglePlay()
        await awaitRecovery()
        XCTAssertEqual(api.transferCount, 1, "rapid transport taps must coalesce into one recovery attempt")
    }
}
