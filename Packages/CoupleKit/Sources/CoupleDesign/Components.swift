import CoupleDomain
import SwiftUI

// MARK: - Buttons

/// The one filled button on a screen. Shows progress in place while its action
/// runs, and stays the same size so the layout does not jump.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    private let isLoading: Bool

    public init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.bodyStrong)
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView().tint(palette.onAccent)
                }
            }
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: Size.button)
            .padding(.horizontal, Space.lg)
            .background(palette.accent.opacity(isEnabled || isLoading ? 1 : 0.35), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.fade, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A full-width alternative that does not compete with the primary button.
public struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.bodyStrong)
            .foregroundStyle(palette.ink.opacity(isEnabled ? 1 : 0.4))
            .frame(maxWidth: .infinity, minHeight: Size.button)
            .padding(.horizontal, Space.lg)
            .background(palette.sunken.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Text-only action for tertiary choices and inline links.
public struct QuietButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    private let destructive: Bool

    public init(destructive: Bool = false) {
        self.destructive = destructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.calloutStrong)
            .foregroundStyle((destructive ? palette.danger : palette.accent).opacity(isEnabled ? 1 : 0.4))
            .frame(minHeight: Size.touch)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A round icon button with a guaranteed 44pt target.
public struct CircleIconButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    private let diameter: CGFloat
    private let filled: Bool

    public init(diameter: CGFloat = Size.button, filled: Bool = false) {
        self.diameter = diameter
        self.filled = filled
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Size.iconControl, weight: .medium))
            .foregroundStyle((filled ? palette.onAccent : palette.ink).opacity(isEnabled ? 1 : 0.35))
            .frame(width: max(diameter, Size.touch), height: max(diameter, Size.touch))
            .background(filled ? palette.accent : palette.sunken, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(isLoading: Bool) -> PrimaryButtonStyle { PrimaryButtonStyle(isLoading: isLoading) }
}

public extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

public extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    static var quietDestructive: QuietButtonStyle { QuietButtonStyle(destructive: true) }
}

public extension ButtonStyle where Self == CircleIconButtonStyle {
    static var circleIcon: CircleIconButtonStyle { CircleIconButtonStyle() }
    static func circleIcon(diameter: CGFloat = Size.button, filled: Bool = false) -> CircleIconButtonStyle {
        CircleIconButtonStyle(diameter: diameter, filled: filled)
    }
}

// MARK: - Fields

/// A labelled text field in the journal style: label above, a single rule
/// beneath, and the validation message in the same place every time.
public struct LabeledField<Field: View>: View {
    @Environment(\.palette) private var palette
    private let label: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let isError: Bool
    private let field: Field

    public init(
        _ label: LocalizedStringKey, message: LocalizedStringKey? = nil, isError: Bool = false,
        @ViewBuilder field: () -> Field
    ) {
        self.label = label
        self.message = message
        self.isError = isError
        self.field = field()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).overlineStyle(palette)
            field
                .font(Typo.body)
                .foregroundStyle(palette.ink)
                .frame(minHeight: Size.touch)
            Rectangle()
                .fill(isError ? palette.danger : palette.hairline)
                .frame(height: isError ? 1.5 : 1)
            if let message {
                Text(message)
                    .font(Typo.caption)
                    .foregroundStyle(isError ? palette.danger : palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Avatar

public struct AvatarView: View {
    @Environment(\.palette) private var palette
    private let initial: String
    private let image: CGImage?
    private let size: CGFloat

    public init(initial: String, image: CGImage? = nil, size: CGFloat = 44) {
        self.initial = initial
        self.image = image
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(palette.sunken)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(palette.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - States

/// Inline message for something that went wrong or needs attention. Sits in
/// the layout where the problem is, rather than interrupting with an alert.
public struct NoticeBanner: View {
    public enum Tone { case error, info, success }

    @Environment(\.palette) private var palette
    private let text: LocalizedStringKey
    private let tone: Tone
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?

    public init(_ text: LocalizedStringKey, tone: Tone = .error, actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    private var symbol: String {
        switch tone {
        case .error: "exclamationmark.circle"
        case .info: "info.circle"
        case .success: "checkmark.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .error: palette.danger
        case .info: palette.inkSecondary
        case .success: palette.success
        }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconInline, weight: .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.callout)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Typo.calloutStrong)
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// What a screen shows when there is nothing yet: one line of what this place
/// is for, one of how to begin, and the action that begins it.
public struct EmptyStateView<Actions: View>: View {
    @Environment(\.palette) private var palette
    private let symbol: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey
    private let actions: Actions

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.inkTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Typo.heading)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typo.callout)
                .foregroundStyle(palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: 420)
    }
}

/// A full-area failure with a way to try again.
public struct LoadFailureView: View {
    private let message: LocalizedStringKey
    private let retry: () -> Void

    public init(_ message: LocalizedStringKey, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        EmptyStateView(symbol: "wifi.exclamationmark", title: "Couldn’t load this", message: message) {
            Button("Try again", action: retry).buttonStyle(.secondary).frame(maxWidth: 220)
        }
    }
}

/// Placeholder block shown while content loads. Pulses gently unless Reduce
/// Motion is on, in which case it holds still.
public struct SkeletonBlock: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = Radius.chip) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(palette.sunken)
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
            }
            .accessibilityHidden(true)
    }
}

/// A brief confirmation that slides in over content and dismisses itself.
public struct ToastView: View {
    @Environment(\.palette) private var palette
    private let text: LocalizedStringKey
    private let symbol: String

    public init(_ text: LocalizedStringKey, symbol: String = "checkmark") {
        self.text = text
        self.symbol = symbol
    }

    public var body: some View {
        Label {
            Text(text).font(Typo.calloutStrong)
        } icon: {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(palette.onAccent)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(palette.accent, in: Capsule())
        .softShadow(palette)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Structure

/// A group heading: small capitals with an optional trailing action.
public struct SectionHeading<Trailing: View>: View {
    @Environment(\.palette) private var palette
    private let title: LocalizedStringKey
    private let trailing: Trailing

    public init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).overlineStyle(palette).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }
}

public struct Hairline: View {
    @Environment(\.palette) private var palette

    public init() {}

    public var body: some View {
        Rectangle().fill(palette.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// A small mark that something is a premium feature. A lock is used only where
/// tapping would otherwise appear to do nothing.
public struct PremiumMark: View {
    @Environment(\.palette) private var palette

    public init() {}

    public var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(palette.onAccent)
            .padding(4)
            .background(palette.accent, in: Circle())
            .accessibilityLabel(Text("Premium"))
    }
}

public extension View {
    /// The standard page: themed canvas behind, content inset by the gutter.
    func pageBackground(_ palette: Palette) -> some View {
        background(palette.canvas.ignoresSafeArea())
    }
}
