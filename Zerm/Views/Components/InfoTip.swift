import SwiftUI

/// The small info icon that explains a setting, with an optional link to the full
/// documentation page for it.
struct InfoTip: View {
    // Content configuration
    var message: String
    var learnMoreLink: URL?

    // Appearance customization
    var iconName: String = "info.circle.fill"
    var iconSize: Image.Scale = .medium
    var iconColor: Color = .primary
    var width: CGFloat = 280

    // State
    @State private var isShowingTip: Bool = false
    @State private var isHovering: Bool = false

    var body: some View {
        // A Button rather than a tap gesture on an Image: that is what gives keyboard
        // activation, VoiceOver and a pointer cursor, none of which a bare gesture has.
        Button {
            isShowingTip.toggle()
        } label: {
            Image(systemName: iconName)
                .imageScale(iconSize)
                .foregroundColor(iconColor)
                .fontWeight(.semibold)
                .opacity(isHovering ? 1 : 0.75)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("More information")
        .accessibilityHint(message)
        .help(message)
        .popover(isPresented: $isShowingTip, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Its own control, so the rest of the popover is just text. Previously the
                // tap handler sat on the whole body, and any tap anywhere opened the link.
                if let learnMoreLink {
                    Link(destination: learnMoreLink) {
                        HStack(spacing: 4) {
                            Text("Learn more")
                            Image(systemName: "arrow.up.right")
                                .imageScale(.small)
                        }
                        .font(.callout.weight(.medium))
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        isShowingTip = false
                    })
                }
            }
            .frame(width: width, alignment: .leading)
            .padding(14)
        }
    }
}

// MARK: - Convenience initializers

extension InfoTip {
    /// Creates an InfoTip with just a message
    init(_ message: String) {
        self.message = message
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a learn more link
    init(_ message: String, learnMoreURL: String) {
        self.message = message
        self.learnMoreLink = URL(string: learnMoreURL)
    }

    /// Creates an InfoTip linking to a documentation page.
    init(_ message: String, doc: Links.Doc) {
        self.message = message
        self.learnMoreLink = Links.doc(doc)
    }
}
