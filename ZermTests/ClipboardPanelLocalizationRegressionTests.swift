import Foundation
import Testing

struct ClipboardPanelLocalizationRegressionTests {
    @Test func clipboardPanelLabelsResolveInEnglishAndHebrew() throws {
        let englishPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let hebrewPath = try #require(Bundle.main.path(forResource: "he", ofType: "lproj"))
        let englishBundle = try #require(Bundle(path: englishPath))
        let hebrewBundle = try #require(Bundle(path: hebrewPath))
        let labels = [
            (key: "Commands", english: "Commands", hebrew: "פקודות"),
            (key: "Toggle Sidebar", english: "Toggle Sidebar", hebrew: "הצגה או הסתרה של סרגל הצד"),
            (key: "Sort clipboard history", english: "Sort clipboard history", hebrew: "מיון היסטוריית הלוח"),
            (key: "Type to search…", english: "Type to search…", hebrew: "הקלידו לחיפוש…"),
            (key: "Move Window", english: "Move Window", hebrew: "הזזת החלון"),
            (key: "Paste on Click", english: "Paste on Click", hebrew: "הדבקה בלחיצה")
        ]

        for label in labels {
            let english = String(
                localized: String.LocalizationValue(label.key),
                bundle: englishBundle,
                locale: Locale(identifier: "en")
            )
            let hebrew = String(
                localized: String.LocalizationValue(label.key),
                bundle: hebrewBundle,
                locale: Locale(identifier: "he")
            )

            #expect(english == label.english, "Unexpected English value for \(label.key)")
            #expect(hebrew == label.hebrew, "Unexpected Hebrew value for \(label.key)")
            #expect(hebrew != english, "Hebrew fell back to English for \(label.key)")
        }
    }
}
