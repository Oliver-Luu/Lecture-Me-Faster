import Foundation
import Testing
@testable import Lecture_Me_Faster

/// The Faster ↔ Most accurate slider (`AppSettings.SpeedPreset`).
@MainActor
struct SpeedPresetTests {
    @Test func theDefaultsAreBalanced() {
        #expect(AppSettings(unsaved: .init()).speedPreset == .balanced)
        // Settings saved before the slider existed land on Balanced too.
        let old = try? JSONDecoder().decode(AppSettings.Stored.self, from: Data(#"{"maxFrames":30,"transcribeInPieces":true}"#.utf8))
        #expect(old.map { AppSettings(unsaved: $0).speedPreset } == .balanced)
    }

    @Test func eachPositionSetsItsSettings() {
        let settings = AppSettings(unsaved: .init())
        settings.apply(.faster)
        #expect(settings.stored.maxFrames == 10)
        #expect(settings.stored.transcribeInPieces)
        #expect(!settings.stored.describeSlides)
        #expect(settings.speedPreset == .faster)

        settings.apply(.accurate)
        #expect(settings.stored.maxFrames == 60)
        #expect(!settings.stored.transcribeInPieces, "One pass: the same transcript every time")
        #expect(settings.stored.describeSlides)
        #expect(settings.speedPreset == .accurate)
    }

    @Test func changingOneSettingByHandIsCustom() {
        let settings = AppSettings(unsaved: .init())
        settings.stored.maxFrames = 45
        #expect(settings.speedPreset == nil)
        settings.apply(.balanced)
        #expect(settings.speedPreset == .balanced)
    }

    @Test func imagesPerRequestStayWithinTheSettingsRange() {
        for preset in AppSettings.SpeedPreset.allCases {
            #expect((5...100).contains(preset.imagesPerRequest), "The Settings stepper's range")
        }
    }
}
