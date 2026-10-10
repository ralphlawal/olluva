import CoupleDomain
import Foundation
import Observation
import StoreKit

/// StoreKit 2: products, purchasing, restoring, and keeping entitlement in
/// step with Apple.
///
/// Two things can make this device premium, and neither is "the app said so":
///
/// 1. `deviceEntitlement` — StoreKit has cryptographically verified, on this
///    device, a live subscription bought for this account. This covers the
///    purchaser immediately and while offline.
/// 2. The server's entitlement (held by `SessionStore`) — the backend verified
///    Apple's signature itself and recorded it. This is what extends premium
///    to the partner, and what the database enforces limits against.
@MainActor
@Observable
final class PurchaseStore {
    enum Outcome: Equatable {
        case purchased
        /// Awaiting approval (Ask to Buy, SCA). Nothing is unlocked yet.
        case pending
        case cancelled
    }

    struct Status: Equatable {
        enum State: Equatable {
            case subscribed, inGracePeriod, inBillingRetry, expired, revoked
        }

        var state: State
        var productID: String
        var expiresAt: Date?
        var willAutoRenew: Bool
    }

    private(set) var products: [Product] = []
    private(set) var productsState: LoadState = .idle
    private(set) var deviceEntitlement: Entitlement = .free
    private(set) var status: Status?
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    /// A purchase is waiting for approval outside the app.
    private(set) var hasPendingPurchase = false

    private let backend: Backend
    private let session: SessionStore
    private var updates: Task<Void, Never>?

    init(backend: Backend, session: SessionStore) {
        self.backend = backend
        self.session = session
    }

    /// Starts listening for transactions that arrive outside a purchase call:
    /// renewals, refunds, approvals, purchases made on another device.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update)
                await self?.refreshDeviceEntitlement()
            }
        }
    }

    func loadProducts() async {
        guard !productsState.isLoading else { return }
        productsState = .loading
        do {
            let loaded = try await Product.products(for: ProductConfiguration.productIDs)
            // Yearly first: it is the plan the paywall leads with.
            products = loaded.sorted {
                (ProductConfiguration.productIDs.firstIndex(of: $0.id) ?? 0) < (ProductConfiguration.productIDs.firstIndex(of: $1.id) ?? 0)
            }
            productsState = products.isEmpty ? .failed(.productsUnavailable) : .loaded
        } catch {
            Diagnostics.failure(Diagnostics.store, "loadProducts", error)
            productsState = .failed(.productsUnavailable)
        }
    }

    func purchase(_ product: Product) async throws -> Outcome {
        guard let userID = session.userID else { throw AppError.sessionExpired }
        isPurchasing = true
        defer { isPurchasing = false }

        let result: Product.PurchaseResult
        do {
            // Binds the purchase to this account, so the server can tell whose it is.
            result = try await product.purchase(options: [.appAccountToken(userID)])
        } catch {
            Diagnostics.failure(Diagnostics.store, "purchase", error)
            throw AppError.purchaseFailed
        }

        switch result {
        case .success(let verification):
            guard case .verified = verification else { throw AppError.purchaseNotVerified }
            hasPendingPurchase = false
            await process(verification)
            await refreshDeviceEntitlement()
            return .purchased
        case .pending:
            hasPendingPurchase = true
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw AppError.purchaseFailed
        }
    }

    /// Asks the App Store to sync, then re-reads entitlements. Returns whether
    /// an active subscription was found.
    func restore() async throws -> Bool {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            // The person cancelled the App Store sign-in, or it is unreachable.
            Diagnostics.failure(Diagnostics.store, "restore", error)
            throw AppError.purchaseFailed
        }
        for await entitlement in Transaction.currentEntitlements {
            await process(entitlement)
        }
        await refreshDeviceEntitlement()
        await session.refreshEntitlement()
        return deviceEntitlement.isPremium || session.serverEntitlement.isPremium
    }

    /// Handles one transaction: an unverified one is ignored outright; a
    /// verified one is handed to the server and then finished.
    private func process(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            Diagnostics.store.error("ignored a transaction that failed verification")
            return
        }
        guard ProductConfiguration.productIDs.contains(transaction.productID) else { return }
        if session.userID != nil {
            do {
                let entitlement = try await backend.entitlements.submitTransaction(jws: result.jwsRepresentation)
                session.setServerEntitlement(entitlement)
            } catch {
                // Not fatal: the purchaser is still covered by the on-device
                // verification, and this is retried on the next launch.
                Diagnostics.failure(Diagnostics.store, "submitTransaction", error)
            }
        }
        await transaction.finish()
    }

    /// Re-derives premium from what StoreKit currently vouches for.
    func refreshDeviceEntitlement() async {
        var entitlement = Entitlement.free
        var latest: Transaction?

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProductConfiguration.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  Self.belongs(transaction, to: session.userID)
            else { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            entitlement = Entitlement(isPremium: true, source: .own, expiresAt: transaction.expirationDate)
            latest = transaction
        }
        deviceEntitlement = entitlement
        status = await Self.status(for: latest)
    }

    /// A subscription bought for a different account on the same Apple ID
    /// does not unlock this one.
    private static func belongs(_ transaction: Transaction, to userID: UUID?) -> Bool {
        guard let token = transaction.appAccountToken else { return true }
        return token == userID
    }

    private static func status(for transaction: Transaction?) async -> Status? {
        guard let transaction, let statuses = try? await Product.SubscriptionInfo.status(for: transaction.subscriptionGroupID ?? "") else {
            return transaction.map {
                Status(state: .subscribed, productID: $0.productID, expiresAt: $0.expirationDate, willAutoRenew: true)
            }
        }
        guard let current = statuses.first(where: { status in
            if case .verified(let renewal) = status.transaction { return renewal.productID == transaction.productID }
            return false
        }) ?? statuses.first else { return nil }

        let state: Status.State = switch current.state {
        case .subscribed: .subscribed
        case .inGracePeriod: .inGracePeriod
        case .inBillingRetryPeriod: .inBillingRetry
        case .revoked: .revoked
        default: .expired
        }
        var willRenew = true
        if case .verified(let renewal) = current.renewalInfo { willRenew = renewal.willAutoRenew }
        return Status(state: state, productID: transaction.productID, expiresAt: transaction.expirationDate, willAutoRenew: willRenew)
    }

    /// Re-submits current entitlements after sign-in, so a subscription bought
    /// before the server knew about it is recorded for the couple.
    func syncWithServer() async {
        guard session.userID != nil else { return }
        for await entitlement in Transaction.currentEntitlements {
            await process(entitlement)
        }
        await refreshDeviceEntitlement()
    }

    func reset() {
        deviceEntitlement = .free
        status = nil
        hasPendingPurchase = false
    }
}
