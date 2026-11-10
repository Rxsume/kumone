import SwiftUI
import Testing
@testable import KumoneCore

/// Coverage for the P3 3/3 deep-appearance hex helpers
/// (`DesignSystem/ColorHex.swift`): "#RRGGBB" parsing and the
/// `rgbHexString` round-trip. Pure logic — no UI, no network.
@Suite("Appearance hex colors")
struct AppearanceHexTests {

    @Test("Parses #RRGGBB and bare RRGGBB")
    func parsesHex() {
        let red = Color(hex: "#EC4949")
        #expect(red != nil)
        #expect(red?.rgbHexString == "#EC4949")
        #expect(Color(hex: "EC4949")?.rgbHexString == "#EC4949")
    }

    @Test("Rejects malformed hex")
    func rejectsMalformedHex() {
        #expect(Color(hex: "") == nil)
        #expect(Color(hex: "#FFF") == nil)
        #expect(Color(hex: "#GGGGGG") == nil)
        #expect(Color(hex: "#EC494") == nil)
        #expect(Color(hex: "not a color") == nil)
    }

    @Test("Round-trips through rgbHexString")
    func roundTrips() {
        for hex in ["#000000", "#FFFFFF", "#123456", "#ABCDEF"] {
            #expect(Color(hex: hex)?.rgbHexString == hex)
        }
    }

    @Test("Lowercase hex parses and normalises to uppercase")
    func lowercaseNormalises() {
        #expect(Color(hex: "#ec4949")?.rgbHexString == "#EC4949")
    }
}
