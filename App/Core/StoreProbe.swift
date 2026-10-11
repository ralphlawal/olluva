#if DEBUG
import CoupleDomain
import StoreKit

/// Development aid behind the `-probeProducts` launch argument: asks the store
/// for the products every way it can and traces what comes back, so a device
/// that gets nothing can be told apart from one that is misconfigured.
/// Identifiers and states only.
final class StoreProbe: NSObject, SKProductsRequestDelegate {
    static let shared = StoreProbe()
    private var request: SKProductsRequest?

    func run() {
        Diagnostics.trace("probe: canMakePayments \(AppStore.canMakePayments)")
        let request = SKProductsRequest(productIdentifiers: Set(ProductConfiguration.productIDs))
        request.delegate = self
        self.request = request
        request.start()
        Task {
            do {
                let result = try await AppTransaction.shared
                switch result {
                case .verified(let app), .unverified(let app, _):
                    Diagnostics.trace("probe: app transaction environment \(app.environment.rawValue) bundle \(app.bundleID)")
                }
            } catch {
                Diagnostics.trace("probe: app transaction failed: \(String(describing: error))")
            }
            for id in ProductConfiguration.productIDs {
                let found = (try? await Product.products(for: [id]).count) ?? -1
                Diagnostics.trace("probe: \(id) -> \(found)")
            }
        }
    }

    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        Diagnostics.trace("probe: legacy request valid \(response.products.map(\.productIdentifier)) invalid \(response.invalidProductIdentifiers)")
    }

    func request(_ request: SKRequest, didFailWithError error: Error) {
        Diagnostics.trace("probe: legacy request failed: \(String(describing: error))")
    }
}
#endif
