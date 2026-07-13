import Testing
@testable import Zerm

struct LanguagePreferenceTests {

    @Test func autoNormalizesToNilApiLanguage() {
        let defaults = UserDefaults(suiteName: "zerm.tests.language.\(UUID().uuidString)")!
        defaults.set("auto", forKey: LanguagePreference.defaultsKey)
        #expect(LanguagePreference.apiLanguage(defaults: defaults) == nil)
        #expect(LanguagePreference.isAuto(defaults: defaults))
    }

    @Test func englishCodeIsPassedThrough() {
        let defaults = UserDefaults(suiteName: "zerm.tests.language.\(UUID().uuidString)")!
        defaults.set("en", forKey: LanguagePreference.defaultsKey)
        #expect(LanguagePreference.apiLanguage(defaults: defaults) == "en")
        #expect(LanguagePreference.selectedCode(defaults: defaults) == "en")
    }

    @Test func deepgramAutoBecomesMultiForNova3() {
        #expect(DeepgramProvider.resolvedLanguage(nil, model: "nova-3") == "multi")
        #expect(DeepgramProvider.resolvedLanguage("auto", model: "nova-3") == "multi")
        #expect(DeepgramProvider.resolvedLanguage("en", model: "nova-3") == "en")
        #expect(DeepgramProvider.resolvedLanguage(nil, model: "nova-3-medical") == nil)
    }
}
