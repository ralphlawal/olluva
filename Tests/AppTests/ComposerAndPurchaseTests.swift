import CoupleDomain
import CoupleLocalBackend
import PencilKit
import StoreKit
import StoreKitTest
import UIKit
import XCTest
@testable import CoupleNotes

@MainActor
final class ComposerModelTests: XCTestCase {
    private var directory: URL!
    private var storage: DraftStorage!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        storage = DraftStorage(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(_ mode: ComposerRequest.Mode = .new) -> ComposerModel {
        ComposerModel(request: ComposerRequest(mode: mode), storage: storage)
    }

    private func photoData(width: Int = 1600, height: Int = 1200) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.9)!
    }

    func testAnEmptyNoteCannotBeSent() {
        let model = model()
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.canSend)
        model.setBody("   \n")
        XCTAssertFalse(model.canSend)
        model.setBody("hi")
        XCTAssertTrue(model.canSend)
    }

    func testTheCharacterLimitIsEnforced() {
        let model = model()
        model.setBody(String(repeating: "a", count: 400))
        XCTAssertEqual(model.content.body.count, Validation.noteBodyLimit)
        XCTAssertEqual(model.remainingCharacters, 0)
        XCTAssertTrue(model.canSend)
    }

    func testOutgoingTextIsTrimmed() {
        let model = model()
        model.setBody("  see you soon \n")
        XCTAssertEqual(model.outgoing().content.body, "see you soon")
    }

    func testChoosingDarkPaperKeepsTheWritingLegible() {
        let model = model()
        XCTAssertEqual(model.content.style.ink, "plum")
        model.setPaper(Paper.find("midnight"))
        XCTAssertEqual(model.content.style.ink, Ink.lightID, "dark ink on dark paper would be unreadable")
        model.setPaper(Paper.find("cream"))
        XCTAssertEqual(model.content.style.ink, Ink.defaultID)

        // A deliberate, still-legible choice is left alone.
        model.content.style.ink = "rose"
        model.setPaper(Paper.find("blush"))
        XCTAssertEqual(model.content.style.ink, "rose")
    }

    func testStickersAreCappedAndKeptOnTheCard() {
        let model = model()
        let heart = Sticker.find("heart")!
        for _ in 0..<(Validation.maximumStickers + 3) { model.addSticker(heart) }
        XCTAssertEqual(model.content.style.stickers.count, Validation.maximumStickers)
        XCTAssertFalse(model.canAddSticker)

        let id = model.content.style.stickers[0].id
        model.updateSticker(id) {
            $0.x = 4
            $0.y = -2
            $0.scale = 50
        }
        let moved = model.content.style.stickers[0]
        XCTAssertLessThanOrEqual(moved.x, 0.96)
        XCTAssertGreaterThanOrEqual(moved.y, 0.04)
        XCTAssertLessThanOrEqual(moved.scale, 2.6)

        model.selectedSticker = id
        model.removeSticker(id)
        XCTAssertEqual(model.content.style.stickers.count, Validation.maximumStickers - 1)
        XCTAssertNil(model.selectedSticker, "removing the selected sticker clears the selection")
    }

    func testATemplateFillsAnEmptyNoteButNeverOverwritesWords() {
        let model = model()
        let template = NoteTemplate.all[0]
        model.apply(template, openingLine: "Good morning, you.")
        XCTAssertEqual(model.content.body, "Good morning, you.")
        XCTAssertEqual(model.content.style.paper, template.style.paper)

        model.setBody("My own words")
        model.apply(NoteTemplate.all[1], openingLine: "Thinking of you.")
        XCTAssertEqual(model.content.body, "My own words")
    }

    func testAPhotoIsCroppedResizedAndReadyToUpload() async throws {
        let model = model()
        await model.setPhoto(from: photoData(width: 4000, height: 3000))
        XCTAssertNil(model.photoError)
        XCTAssertTrue(model.hasPhoto)
        XCTAssertTrue(model.canSend, "a photo alone is a note")

        let outgoing = model.outgoing()
        let data = try XCTUnwrap(outgoing.photo)
        XCTAssertLessThanOrEqual(data.count, MediaPath.maximumMediaBytes)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), CGFloat(ImagePipeline.notePhotoPixels))
        // Framed layout: cropped to the frame's shape.
        XCTAssertEqual(image.size.width / image.size.height, model.photoAspect, accuracy: 0.02)

        model.setPhotoLayout(.full)
        let square = try XCTUnwrap(UIImage(data: try XCTUnwrap(model.outgoing().photo)))
        XCTAssertEqual(square.size.width / square.size.height, 1, accuracy: 0.02)

        model.removePhoto()
        XCTAssertFalse(model.hasPhoto)
        XCTAssertNil(model.outgoing().photo)
    }

    func testSomethingThatIsNotAnImageIsRefused() async {
        let model = model()
        await model.setPhoto(from: Data("this is not an image".utf8))
        XCTAssertEqual(model.photoError, .mediaUnreadable)
        XCTAssertFalse(model.hasPhoto)
    }

    func testADrawingIsRenderedToAFixedSizeTransparentPNG() throws {
        let model = model()
        model.canvasSide = 320
        XCTAssertNil(model.renderedDrawing(), "nothing drawn, nothing to upload")

        let ink = PKInk(.pen, color: .black)
        let points = stride(from: 40.0, through: 280.0, by: 40.0).map {
            PKStrokePoint(location: CGPoint(x: $0, y: $0), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: 0)
        }
        model.drawing = PKDrawing(strokes: [PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        XCTAssertTrue(model.hasDrawing)
        XCTAssertTrue(model.canSend, "a drawing alone is a note")

        let png = try XCTUnwrap(model.renderedDrawing())
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)
        XCTAssertNotEqual(image.alphaInfo, .none, "the paper must show through")

        model.clearDrawing()
        XCTAssertFalse(model.hasDrawing)
    }

    func testADraftSurvivesClosingTheComposer() async throws {
        let first = model()
        first.setBody("Half a thought")
        first.setPaper(Paper.find("lilac"))
        first.addSticker(Sticker.find("star")!)
        await first.setPhoto(from: photoData())
        first.saveDraftNow()

        let reopened = model()
        XCTAssertEqual(reopened.content.body, "Half a thought")
        XCTAssertEqual(reopened.content.style.paper, "lilac")
        XCTAssertEqual(reopened.content.style.stickers.count, 1)
        XCTAssertTrue(reopened.hasPhoto)
        XCTAssertTrue(reopened.canRepositionPhoto, "the original is kept so the crop can still be changed")
        XCTAssertNotNil(reopened.outgoing().photo)

        reopened.discardDraft()
        XCTAssertTrue(model().isEmpty)
    }

    func testEditingAnExistingNoteNeverTouchesTheDraft() {
        let draft = model()
        draft.setBody("my draft")
        draft.saveDraftNow()

        let note = Note(id: UUID(), coupleID: UUID(), authorID: UUID(), body: "sent note", createdAt: Date())
        let editing = model(.edit(note))
        XCTAssertEqual(editing.content.body, "sent note")
        editing.setBody("sent note, edited")
        editing.saveDraftNow()
        editing.discardDraft()

        XCTAssertEqual(model().content.body, "my draft")
    }

    func testASurpriseStartsWithAValidDeliveryTime() throws {
        let model = model(.surprise)
        let deliverAt = try XCTUnwrap(model.deliverAt)
        try ScheduleRules.validate(deliverAt: deliverAt, now: Date())
    }
}

final class ImagePipelineTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.cgImage!
    }

    func testCenteredRectKeepsTheRequestedShapeInsideTheImage() {
        let wide = image(width: 2000, height: 1000)
        XCTAssertEqual(ImagePipeline.centeredRect(in: wide, aspect: 1), CGRect(x: 500, y: 0, width: 1000, height: 1000))
        let tall = image(width: 1000, height: 2000)
        XCTAssertEqual(ImagePipeline.centeredRect(in: tall, aspect: 2), CGRect(x: 0, y: 750, width: 1000, height: 500))
    }

    func testCroppingClampsToTheImageAndRespectsTheSizeLimit() throws {
        let source = image(width: 3000, height: 3000)
        let data = try XCTUnwrap(ImagePipeline.croppedJPEG(source, rect: CGRect(x: -500, y: -500, width: 9000, height: 9000), maxPixel: 800))
        let result = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(result.size, CGSize(width: 800, height: 800))
        XCTAssertNil(ImagePipeline.croppedJPEG(source, rect: CGRect(x: 5000, y: 5000, width: 10, height: 10), maxPixel: 800))
    }

    func testAvatarsAreSmallSquares() throws {
        let original = UIImage(cgImage: image(width: 3000, height: 2000)).jpegData(compressionQuality: 1)!
        let avatar = try XCTUnwrap(ImagePipeline.avatarJPEG(from: original))
        XCTAssertLessThanOrEqual(avatar.count, MediaPath.maximumAvatarBytes)
        XCTAssertEqual(UIImage(data: avatar)?.size, CGSize(width: 400, height: 400))
        XCTAssertNil(ImagePipeline.avatarJPEG(from: Data("nope".utf8)))
    }

    func testReEncodingRemovesLocationMetadata() throws {
        // Build a JPEG that carries GPS coordinates, as a camera photo would.
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 38.72, kCGImagePropertyGPSLongitude: 9.14]
        CGImageDestinationAddImage(destination, image(width: 800, height: 600), [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        func hasGPS(_ data: Data) -> Bool {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyGPSDictionary] != nil
        }
        XCTAssertTrue(hasGPS(output as Data), "the fixture should contain a location")

        let editing = try XCTUnwrap(ImagePipeline.editingImage(from: output as Data))
        let sent = try XCTUnwrap(ImagePipeline.croppedJPEG(
            editing, rect: CGRect(x: 0, y: 0, width: editing.width, height: editing.height), maxPixel: 1400
        ))
        XCTAssertFalse(hasGPS(sent), "what is uploaded must not say where the photo was taken")
    }
}

/// Runs real StoreKit 2 purchases against the bundled StoreKit configuration.
/// Requires a development-signed build; see `setUp`.
/// Server-side verification is not part of this: the in-memory backend never
/// grants anything from a submitted transaction, which is asserted below.
@MainActor
final class PurchaseStoreTests: XCTestCase {
    private var storeSession: SKTestSession!
    private var fixture: Fixture!
    private var session: SessionStore!
    private var purchases: PurchaseStore!

    override func setUp() async throws {
        storeSession = try SKTestSession(configurationFileNamed: "Products")
        storeSession.disableDialogs = true
        storeSession.clearTransactions()
        storeSession.resetToDefaultState()

        fixture = Fixture()
        session = SessionStore(backend: fixture.backend)
        await session.start(isMissingBackend: false)
        purchases = PurchaseStore(backend: fixture.backend, session: session)
        await purchases.refreshDeviceEntitlement()

        // StoreKit's local test service only serves apps that are "installed
        // for development", which requires signing with a development team.
        // Without one (DEVELOPMENT_TEAM unset) it refuses the configuration and
        // no products load. Skip rather than fail: the code is not at fault,
        // and a skip is reported as a skip, not as a pass.
        await purchases.loadProducts()
        try XCTSkipUnless(
            purchases.productsState == .loaded,
            "StoreKit testing is unavailable: set DEVELOPMENT_TEAM in Config/Secrets.xcconfig and re-run."
        )
    }

    override func tearDown() async throws {
        storeSession.clearTransactions()
        fixture.cleanUp()
    }

    func testProductsLoadWithRealPricesYearlyFirst() async {
        XCTAssertFalse(purchases.deviceEntitlement.isPremium)
        await purchases.loadProducts()
        XCTAssertEqual(purchases.productsState, .loaded)
        XCTAssertEqual(purchases.products.map(\.id), ProductConfiguration.productIDs)
        XCTAssertEqual(purchases.products.first?.displayPrice.isEmpty, false)
    }

    func testPurchasingUnlocksPremiumOnThisDeviceFromAVerifiedTransaction() async throws {
        await purchases.loadProducts()
        let product = try XCTUnwrap(purchases.products.first)

        let outcome = try await purchases.purchase(product)
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(purchases.deviceEntitlement.isPremium)
        XCTAssertEqual(purchases.deviceEntitlement.source, .own)
        XCTAssertNotNil(purchases.deviceEntitlement.expiresAt)

        // The transaction is bound to this account.
        var tokens: [UUID?] = []
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement { tokens.append(transaction.appAccountToken) }
        }
        XCTAssertEqual(tokens, [fixture.me])

        // The demo backend cannot verify Apple's signature, so the "server"
        // entitlement must still be free: nothing was granted by assertion.
        XCTAssertEqual(session.serverEntitlement, .free)
    }

    func testAnExpiredSubscriptionStopsUnlockingPremium() async throws {
        await purchases.loadProducts()
        _ = try await purchases.purchase(try XCTUnwrap(purchases.products.last))
        XCTAssertTrue(purchases.deviceEntitlement.isPremium)

        try storeSession.expireSubscription(productIdentifier: ProductConfiguration.monthlyProductID)
        await purchases.refreshDeviceEntitlement()
        XCTAssertFalse(purchases.deviceEntitlement.isPremium)
    }

    func testARefundRevokesPremium() async throws {
        await purchases.loadProducts()
        _ = try await purchases.purchase(try XCTUnwrap(purchases.products.first))
        let transaction = try XCTUnwrap(storeSession.allTransactions().first)
        try storeSession.refundTransaction(identifier: transaction.identifier)
        await purchases.refreshDeviceEntitlement()
        XCTAssertFalse(purchases.deviceEntitlement.isPremium)
    }

    func testAFailingStoreReportsAnErrorAndGrantsNothing() async throws {
        await purchases.loadProducts()
        storeSession.failTransactionsEnabled = true
        storeSession.failureError = .unknown
        do {
            _ = try await purchases.purchase(try XCTUnwrap(purchases.products.first))
            XCTFail("a failed purchase must throw")
        } catch {
            XCTAssertEqual(error as? AppError, .purchaseFailed)
        }
        XCTAssertFalse(purchases.deviceEntitlement.isPremium)
    }

    func testAPurchaseAwaitingApprovalUnlocksNothingYet() async throws {
        await purchases.loadProducts()
        storeSession.askToBuyEnabled = true
        let outcome = try await purchases.purchase(try XCTUnwrap(purchases.products.first))
        XCTAssertEqual(outcome, .pending)
        XCTAssertTrue(purchases.hasPendingPurchase)
        XCTAssertFalse(purchases.deviceEntitlement.isPremium)
    }

    func testAPurchaseMadeForADifferentAccountDoesNotUnlockThisOne() async throws {
        await purchases.loadProducts()
        _ = try await purchases.purchase(try XCTUnwrap(purchases.products.first))
        XCTAssertTrue(purchases.deviceEntitlement.isPremium)

        // Same Apple ID, different app account signs in on this phone.
        let other = fixture.world.addAccount(name: "Other")
        let otherSession = SessionStore(backend: LocalBackend(world: fixture.world, signedInAs: other).makeBackend())
        await otherSession.start(isMissingBackend: false)
        let otherPurchases = PurchaseStore(backend: fixture.backend, session: otherSession)
        await otherPurchases.refreshDeviceEntitlement()
        XCTAssertFalse(otherPurchases.deviceEntitlement.isPremium)
    }
}
