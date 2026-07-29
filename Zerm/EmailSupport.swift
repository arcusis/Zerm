import Foundation
import SwiftUI
import AppKit

struct EmailSupport {
    @MainActor
    static func generateSupportEmailURL() -> URL? {
        let subject = "Zerm Support Request"
        let systemInfo = SystemInfoService.shared.getSystemInfoString()

        let body = """

        ------------------------
        ✨ **SCREEN RECORDING HIGHLY RECOMMENDED** ✨
        ▶️ Create a quick screen recording showing the issue!
        ▶️ It helps me understand and fix the problem much faster.

        📝 ISSUE DETAILS:
        - What steps did you take before the issue occurred?
        - What did you expect to happen?
        - What actually happened instead?


        ## 📋 COMMON ISSUES:
        Check out our Common Issues page before sending an email: \(Links.docString(.commonIssues))
        ------------------------

        System Information:
        \(systemInfo)


        """
        
        // This used to open a mail draft addressed to the upstream VoiceInk maintainer's
        // personal address, so every Zerm support report — including the attached system
        // information — was being sent to an unrelated person. Zerm's actual support
        // channel is its issue tracker.
        var components = URLComponents(string: "https://github.com/arcusis/Zerm/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url ?? Links.issues
    }
    
    @MainActor
    static func openSupportEmail() {
        if let emailURL = generateSupportEmailURL() {
            NSWorkspace.shared.open(emailURL)
        }
    }
    
    
}