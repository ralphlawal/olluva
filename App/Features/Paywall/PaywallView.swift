import CoupleDesign
import CoupleDomain
import StoreKit
import SwiftUI

// Screen: Premium
// Purpose: explain honestly what Premium adds and let someone buy it.
// Primary action: subscribe to the selected plan.
// Layouts weighed: a full-bleed hero with a countdown and a pre-selected
// "best value" banner (the dark-pattern template), a comparison table (dense,
// and the free column reads as a list of things withheld), and a short plain
// list of what you get followed by the plans at their real prices. The plain
// list is used. There is no urgency, no fake discount, and the close button is
// where close buttons go. Prices and terms come from the App Store, never
// from text typed into the app.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Product?
    @State private var action = ActionState()
    @State private var notice: LocalizedStringKey?
    @State private var showingManage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Premium, for both of you")
                            .font(Typo.display)
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("One subscription covers your whole space. If either of you subscribes, you both get everything.")
                            .font(Typo.body)
                            .foregroundStyle(palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    features

                    if app.entitlement.isPremium {
                        currentStatus
                    } else {
                        plans
                    }

                    if let error = action.error { NoticeBanner(error.message) }
                    if let notice { NoticeBanner(notice, tone: .info) }

                    footer
                }
                .padding(Space.gutter)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .pageBackground(palette)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Close"))
                    .accessibilityIdentifier("paywall.close")
                }
            }
            .manageSubscriptionsSheet(isPresented: $showingManage)
        }
        .task {
            if app.purchases.products.isEmpty { await app.purchases.loadProducts() }
            selected = selected ?? app.purchases.products.first
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(ProductConfiguration.Feature.allCases, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: Size.iconControl))
                        .foregroundStyle(palette.accent)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(Typo.bodyStrong).foregroundStyle(palette.ink)
                        Text(feature.detail).font(Typo.callout).foregroundStyle(palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var plans: some View {
        switch app.purchases.productsState {
        case .idle, .loading:
            VStack(spacing: Space.sm) {
                SkeletonBlock(cornerRadius: Radius.field).frame(height: 68)
                SkeletonBlock(cornerRadius: Radius.field).frame(height: 68)
            }
        case .failed(let error):
            NoticeBanner(error.message, tone: .info, actionTitle: "Try again") {
                Task {
                    await app.purchases.loadProducts()
                    selected = app.purchases.products.first
                }
            }
            .accessibilityIdentifier("paywall.unavailable")
        case .loaded:
            VStack(spacing: Space.sm) {
                ForEach(app.purchases.products, id: \.id) { product in
                    PlanRow(product: product, isSelected: selected?.id == product.id) {
                        Haptics.selection()
                        selected = product
                    }
                }
                Button(action: purchase) {
                    Text(selected.map { "Subscribe for \($0.displayPrice)" } ?? "Subscribe")
                }
                .buttonStyle(.primary(isLoading: app.purchases.isPurchasing))
                .disabled(selected == nil || app.purchases.isPurchasing)
                .padding(.top, Space.xs)
                .accessibilityIdentifier("paywall.subscribe")
            }
        }
    }

    private var currentStatus: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            switch app.entitlement.source {
            case .partner:
                NoticeBanner("\(app.session.partner?.displayName ?? "Your partner")’s subscription covers your space. There’s nothing you need to buy.", tone: .success)
            default:
                NoticeBanner(ownStatusText, tone: app.purchases.status?.state == .inGracePeriod ? .error : .success)
                Button("Manage subscription") { showingManage = true }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("paywall.manage")
            }
        }
        .accessibilityIdentifier("paywall.active")
    }

    private var ownStatusText: LocalizedStringKey {
        guard let status = app.purchases.status else { return "You have Premium." }
        let date = status.expiresAt.map { $0.formatted(date: .long, time: .omitted) } ?? ""
        switch status.state {
        case .inGracePeriod:
            return "There’s a problem with your payment. Update it in your Apple ID settings to keep Premium."
        case .subscribed where status.willAutoRenew:
            return "You have Premium. It renews on \(date)."
        default:
            return "You have Premium until \(date). It won’t renew."
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !app.entitlement.isPremium {
                Text("Payment is charged to your Apple ID. Subscriptions renew automatically at the price shown unless cancelled at least 24 hours before the end of the period. Manage or cancel any time in your Apple ID settings.")
                    .font(Typo.caption)
                    .foregroundStyle(palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.md) {
                Button("Restore purchases", action: restore)
                    .disabled(app.purchases.isRestoring)
                    .accessibilityIdentifier("paywall.restore")
                Link("Terms", destination: AppLinks.terms)
                Link("Privacy", destination: AppLinks.privacy)
            }
            .font(Typo.calloutStrong)
            .foregroundStyle(palette.accent)
            .frame(minHeight: Size.touch)
        }
    }

    private func purchase() {
        guard let selected else { return }
        notice = nil
        action.run {
            switch try await app.purchases.purchase(selected) {
            case .purchased:
                Haptics.success()
                await app.session.refreshEntitlement()
            case .pending:
                notice = "Your purchase is waiting for approval. Premium unlocks as soon as it’s approved."
            case .cancelled:
                break
            }
        }
    }

    private func restore() {
        notice = nil
        action.run {
            let found = try await app.purchases.restore()
            notice = found ? "Your Premium has been restored." : "We couldn’t find a subscription to restore for this Apple ID."
        }
    }
}

struct PlanRow: View {
    @Environment(\.palette) private var palette
    let product: Product
    let isSelected: Bool
    let select: () -> Void

    private var period: String {
        guard let unit = product.subscription?.subscriptionPeriod else { return "" }
        return unit.formatted(product.subscriptionPeriodFormatStyle)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? palette.accent : palette.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).font(Typo.bodyStrong).foregroundStyle(palette.ink)
                    Text(product.description).font(Typo.caption).foregroundStyle(palette.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Space.xs)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice).font(Typo.bodyStrong).foregroundStyle(palette.ink)
                    Text("per \(period)").font(Typo.caption).foregroundStyle(palette.inkSecondary)
                }
            }
            .padding(Space.md)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .strokeBorder(isSelected ? palette.accent : palette.hairline, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paywall.plan.\(product.id)")
    }
}

extension ProductConfiguration.Feature {
    var symbol: String {
        switch self {
        case .themes: "paintpalette"
        case .papers: "doc.richtext"
        case .stickers: "face.smiling"
        case .drawingTools: "pencil.and.outline"
        case .effects: "sparkles"
        case .scheduled: "gift"
        case .memories: "book.closed"
        case .templates: "rectangle.on.rectangle.angled"
        case .widgetStyles: "square.grid.2x2"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .themes: "More themes, and your own accent colour"
        case .papers: "Every paper, ink and lettering"
        case .stickers: "All six sticker packs"
        case .drawingTools: "Six more brushes, in any colour"
        case .effects: "Notes that open with a flourish"
        case .scheduled: "Plan many surprises at once"
        case .memories: "A much bigger scrapbook"
        case .templates: "Templates for special occasions"
        case .widgetStyles: "Extra widget styles"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .themes: "Four more looks for your shared space."
        case .papers: "Gradient and patterned papers, four more inks, four more styles of lettering."
        case .stickers: "Over sixty stickers. Free includes a few from each pack."
        case .drawingTools: "Fountain pen, fine liner, watercolour, crayon, marker and pencil."
        case .effects: "Hearts, confetti or sparkles when your partner opens it."
        case .scheduled: "Up to \(ProductConfiguration.premium.pendingScheduledMessages) waiting at a time. Free includes \(ProductConfiguration.free.pendingScheduledMessages)."
        case .memories: "Keep up to \(ProductConfiguration.premium.memories) memories. Free includes \(ProductConfiguration.free.memories)."
        case .templates: "Anniversary, birthday, date night and more."
        case .widgetStyles: "Print and Bold, as well as the two free styles."
        }
    }
}
