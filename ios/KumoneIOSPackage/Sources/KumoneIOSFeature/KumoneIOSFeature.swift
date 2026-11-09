@_exported import KumoneCore
// Bilibili video module (vendored CiliCiliKit, GPL-3.0-only). Phase 1
// only wires the build: no CiliCili UI is rendered yet; the first
// real import sites land with the video feed in phase 3. The import
// keeps the module in this target's link, so CI proves it compiles.
import CiliCiliKit
import SwiftUI
