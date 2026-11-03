import Foundation
import Testing
@testable import ContainerDeskApp
@testable import ContainerDeskCore

@MainActor @Suite(.serialized)
struct ContainerMetricReadoutFormattingTests {
    @Test(arguments: ["en_US", "en_GB", "de_DE", "fr_FR", "hi_IN", "ar_EG"])
    func readoutsPreserveLocalizedDigitsGroupingAndRounding(_ identifier: String) {
        let formatting = ContainerMetricReadoutFormatting()
        let locale = Locale(identifier: identifier)
        for value in [0.0, 0.001, 0.05, 0.15, 1.25, 1.35, 12.95, 999.95, 1_234.56, 12_345_678.95] {
            #expect(formatting.string(value, locale: locale) == value.formatted(.number.locale(locale).precision(.fractionLength(1))))
        }
    }

    @Test func localeChangesAndUnavailableValuesDoNotReuseStaleText() {
        let formatting = ContainerMetricReadoutFormatting()
        for identifier in ["en_US", "de_DE", "ar_EG", "en_US"] {
            let locale = Locale(identifier: identifier)
            #expect(formatting.string(nil, locale: locale) == "—")
            #expect(formatting.string(.nan, locale: locale) == "—")
            #expect(formatting.string(.infinity, locale: locale) == "—")
            #expect(formatting.string(1_234.56, locale: locale) == 1_234.56.formatted(.number.locale(locale).precision(.fractionLength(1))))
        }
    }

    @Test func preparedPointsAndUncachedHistoryValuesStayCorrectAcrossLocaleChanges() {
        let formatting = ContainerMetricReadoutFormatting()
        let points = (0..<400).map { index in
            ContainerChartPoint(date: Date(timeIntervalSince1970: Double(index)), value: Double(index) + 0.125, segment: 0)
        }
        for identifier in ["en_US", "de_DE", "en_US"] {
            let locale = Locale(identifier: identifier)
            formatting.prepare(points: points, locale: locale)
            // Include prepared values, older full-resolution misses and cache
            // eviction. The sign of zero must also survive numeric cache keys.
            for value in points.map(\.value) + [-0.0, 0.0, 999.95] {
                #expect(formatting.string(value, locale: locale) == value.formatted(.number.locale(locale).precision(.fractionLength(1))))
            }
        }
    }
}
