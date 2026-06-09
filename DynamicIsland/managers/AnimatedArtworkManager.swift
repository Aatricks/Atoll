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
import MusicKit

actor AnimatedArtworkManager {
    static let shared = AnimatedArtworkManager()

    private var cachedSongID: String?
    private var cachedVideoURL: URL?
    private var cachedKey: String?

    func fetchAnimatedArtworkURL(title: String, artist: String) async -> URL? {
        let key = "\(title)|\(artist)"
        if key == cachedKey, let url = cachedVideoURL {
            return url
        }

        guard await requestMusicAuthorization() else { return nil }

        guard let songID = await searchSongID(title: title, artist: artist) else {
            return nil
        }

        guard let videoURL = await fetchEditorialVideoURL(songID: songID) else {
            return nil
        }

        cachedKey = key
        cachedSongID = songID
        cachedVideoURL = videoURL
        return videoURL
    }

    func clearCache() {
        cachedKey = nil
        cachedSongID = nil
        cachedVideoURL = nil
    }

    // MARK: - MusicKit Authorization

    private func requestMusicAuthorization() async -> Bool {
        let status = MusicAuthorization.currentStatus
        if status == .authorized { return true }

        let newStatus = await MusicAuthorization.request()
        return newStatus == .authorized
    }

    // MARK: - Song Search

    private func searchSongID(title: String, artist: String) async -> String? {
        let term = "\(title) \(artist)"
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 5

        do {
            let response = try await request.response()
            let normalizedTitle = title.lowercased()
            let normalizedArtist = artist.lowercased()

            let match = response.songs.first(where: {
                $0.title.lowercased() == normalizedTitle &&
                $0.artistName.lowercased() == normalizedArtist
            }) ?? response.songs.first(where: {
                $0.title.lowercased() == normalizedTitle
            }) ?? response.songs.first

            guard let song = match else { return nil }
            return song.id.rawValue
        } catch {
            Log.error("[AnimatedArtworkManager] Search failed: \(error)")
            return nil
        }
    }

    // MARK: - Editorial Video Fetch

    private func fetchEditorialVideoURL(songID: String) async -> URL? {
        let storefront: String
        if let code = try? await MusicDataRequest.currentCountryCode {
            storefront = code
        } else {
            storefront = "us"
        }

        return await fetchEditorialVideoURLFallback(songID: songID, storefront: storefront)
    }

    private func fetchEditorialVideoURLFallback(songID: String, storefront: String) async -> URL? {
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/songs/\(songID)?extend=editorialVideo") else {
            return nil
        }

        do {
            let request = MusicDataRequest(urlRequest: URLRequest(url: url))
            let response = try await request.response()

            guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let data = json["data"] as? [[String: Any]],
                  let first = data.first,
                  let attributes = first["attributes"] as? [String: Any],
                  let editorialVideo = attributes["editorialVideo"] as? [String: Any]
            else { return nil }

            if let motionTall = editorialVideo["motionTallVideo3x4"] as? [String: Any],
               let videoURLString = motionTall["video"] as? String,
               let videoURL = URL(string: videoURLString) {
                return videoURL
            }

            if let motionSquare = editorialVideo["motionSquareVideo1x1"] as? [String: Any],
               let videoURLString = motionSquare["video"] as? String,
               let videoURL = URL(string: videoURLString) {
                return videoURL
            }

            let hlsPattern = try? NSRegularExpression(pattern: "https://mvod\\.itunes\\.apple\\.com[^\"]+\\.m3u8")
            let jsonString = String(data: response.data, encoding: .utf8) ?? ""
            let range = NSRange(jsonString.startIndex..., in: jsonString)
            if let match = hlsPattern?.firstMatch(in: jsonString, range: range),
               let matchRange = Range(match.range, in: jsonString) {
                return URL(string: String(jsonString[matchRange]))
            }

            return nil
        } catch {
            Log.error("[AnimatedArtworkManager] Editorial video fetch failed: \(error)")
            return nil
        }
    }
}
