import SwiftUI

struct CompactHeroSection: View {
    let icon: String
    /// Already localized by the caller.
    let title: String
    let description: String
    var maxDescriptionWidth: CGFloat? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.system(size: 22, weight: .bold))
                Text(verbatim: description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: maxDescriptionWidth)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
