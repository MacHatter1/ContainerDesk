import SwiftUI

enum ContainerDeskTypography {
    static let title: Font = .title2.weight(.semibold)
    static let detailTitle: Font = .title3.weight(.semibold)
    static let sectionTitle: Font = .headline.weight(.semibold)
    static let rowTitle: Font = .body.weight(.medium)
    static let technical: Font = .callout.monospaced()
    static let caption: Font = .caption
}

enum ContainerDeskMotion {
    static let short = 0.18
    static let reveal = 0.28

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: reveal, dampingFraction: 0.84)
    }
}

struct QuietSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceHeader<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color = .accentColor
    let content: Content

    init(title: String, subtitle: String, symbol: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(ContainerDeskTypography.title).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            LinearGradient(colors: [tint.opacity(0.085), tint.opacity(0.025), .clear], startPoint: .leading, endPoint: .trailing)
                .overlay(alignment: .bottom) { Divider().opacity(0.55) }
        }
    }
}

extension WorkspaceHeader where Content == EmptyView {
    init(title: String, subtitle: String, symbol: String, tint: Color = .accentColor) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint, content: { EmptyView() })
    }
}

struct DetailTabStrip: View {
    @Binding var selection: String
    let tabs: [String]

    var body: some View {
        Picker("Details", selection: $selection) {
            ForEach(tabs, id: \.self) { tab in
                Text(tab).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Details")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccentPanel<Content: View>: View {
    let title: String?
    let symbol: String?
    let tint: Color
    let content: Content
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(title: String? = nil, symbol: String? = nil, tint: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                    Text(title).font(ContainerDeskTypography.sectionTitle)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.7)).frame(width: 3).padding(.vertical, 12)
                }
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(borderColor))
        }
    }

    private var borderColor: Color {
        colorSchemeContrast == .increased ? Color.primary.opacity(0.48) : tint.opacity(0.22)
    }
}

struct InlineNotice: View {
    enum Kind { case info, success, warning, error }
    let message: String
    var kind: Kind = .info
    var title: String?
    var onDismiss: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(message: String, kind: Kind = .info, title: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.kind = kind
        self.title = title
        self.onDismiss = onDismiss
    }

    private var color: Color {
        switch kind {
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, title == nil ? 1 : 2)
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).font(.callout.weight(.semibold)).foregroundStyle(color) }
                Text(message).font(.callout).foregroundStyle(color).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss notice")
                .accessibilityLabel("Dismiss notice")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }
}

struct FeatureEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .symbolRenderingMode(.hierarchical)
    }
}

struct NeutralPanel<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        AccentPanel(title: title, content: { content })
    }
}

struct LabeledPrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
}
