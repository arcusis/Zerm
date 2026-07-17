import SwiftUI

/// Inline warning shown on a model card when the model is a stretch (orange) or
/// too heavy to install (red) for this Mac.
struct HardwareFitNotice: View {
    let fit: HardwareCapability.ModelFit

    var body: some View {
        switch fit {
        case .good:
            EmptyView()
        case .heavy(let reason):
            notice(icon: "exclamationmark.triangle.fill", color: .orange,
                   title: "Heavy for this Mac", detail: reason)
        case .tooHeavy(let reason):
            notice(icon: "xmark.octagon.fill", color: .red,
                   title: "Not supported on this Mac", detail: reason)
        }
    }

    private func notice(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Color(.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}
