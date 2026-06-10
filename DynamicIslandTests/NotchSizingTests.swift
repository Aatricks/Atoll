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

/// On notched MacBooks the area below the notch is an exact 16:10 region of the
/// native panel (MBA 13/15: 64 px notch, MBP 14/16: 74 px). macOS reports
/// `safeAreaInsets.top` anchored to the 2x mode, so on non-integer scaled
/// resolutions (e.g. "looks like 1470×956" on a 2560×1664 panel) the reported
/// inset (32 pt) is smaller than the physical notch (36.75 pt). These tests
/// cover the conversion that closes that gap.
final class NotchSizingTests: XCTestCase {

    // MacBook Air 13" panel, non-integer scaled mode (default "1470×956").
    func test_macbookAir13_scaledMode_yieldsPhysicalNotchHeight() {
        let height = physicalNotchHeightPoints(
            nativePanelPixelSize: CGSize(width: 2560, height: 1664),
            pointWidth: 1470
        )
        // 64 px × 1470/2560 = 36.75 → ceil = 37
        XCTAssertEqual(height, 37)
    }

    // MacBook Air 13" panel, exact 2x mode ("1280×832") — must match the
    // system-reported 32 pt so existing setups don't change.
    func test_macbookAir13_nativeRetinaMode_matchesReportedInset() {
        let height = physicalNotchHeightPoints(
            nativePanelPixelSize: CGSize(width: 2560, height: 1664),
            pointWidth: 1280
        )
        XCTAssertEqual(height, 32)
    }

    // MacBook Pro 14" panel, default exact 2x mode ("1512×982").
    func test_macbookPro14_defaultMode() {
        let height = physicalNotchHeightPoints(
            nativePanelPixelSize: CGSize(width: 3024, height: 1964),
            pointWidth: 1512
        )
        // 74 px × 0.5 = 37
        XCTAssertEqual(height, 37)
    }

    // MacBook Pro 16" panel, "More Space" scaled mode ("2056×1329").
    func test_macbookPro16_moreSpaceMode() {
        let height = physicalNotchHeightPoints(
            nativePanelPixelSize: CGSize(width: 3456, height: 2234),
            pointWidth: 2056
        )
        // 74 px × 2056/3456 = 44.02 → ceil = 45
        XCTAssertEqual(height, 45)
    }

    // A plain 16:10 panel has no notch rows above the main area.
    func test_notchlessPanel_returnsNil() {
        let height = physicalNotchHeightPoints(
            nativePanelPixelSize: CGSize(width: 2560, height: 1600),
            pointWidth: 1280
        )
        XCTAssertNil(height)
    }

    // A panel that is not 16:10-below-notch (e.g. 3:2) must not be treated as
    // notched — the derived "notch" would be implausibly large.
    func test_nonSixteenByTenPanel_returnsNil() {
        let height = physicalNotchHeightPoints(
            nativePanelPixelSize: CGSize(width: 2256, height: 1504),
            pointWidth: 1128
        )
        XCTAssertNil(height)
    }

    func test_invalidInputs_returnNil() {
        XCTAssertNil(physicalNotchHeightPoints(nativePanelPixelSize: .zero, pointWidth: 1470))
        XCTAssertNil(physicalNotchHeightPoints(nativePanelPixelSize: CGSize(width: 2560, height: 1664), pointWidth: 0))
    }
}
