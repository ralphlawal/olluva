#if DEBUG
import CoupleDomain
import CoupleLocalBackend
import CoreGraphics
import Foundation
import UIKit

/// DEBUG builds only. Runs the app on the in-memory backend so every screen
/// can be exercised without a server: for development, simulator review and
/// UI tests. Nothing here is compiled into a release build, and the app labels
/// itself as a demo wherever this is active.
///
/// Scenarios (launch argument `-demoScenario <name>`):
///   fresh     first launch; a demo partner is waiting with invitation code SAMSAM2345
///   solo      started and named, not yet paired
///   empty     paired, nothing written yet
///   paired    paired, with notes, memories, dates and a scheduled surprise
///   premium   as `paired`, with a premium partner
@MainActor
final class DemoController {
    static let partnerInviteCode = "SAMSAM2345"
    /// Stands in for an Apple ID wherever the demo backs up or restores.
    static let appleID = "demo-apple-id"

    let world: LocalWorld
    let backend: Backend
    private let local: LocalBackend
    private let partnerID: UUID
    private var partnerSession: LocalBackend
    private var worker: Task<Void, Never>?

    init(scenario: String, isUITesting: Bool, startsSignedOut: Bool = false) {
        // A little latency makes loading states visible when reviewing by hand;
        // tests run without it.
        world = LocalWorld(latency: isUITesting ? .milliseconds(20) : .milliseconds(350))
        partnerID = world.addAccount(name: "Sam")
        partnerSession = LocalBackend(world: world, signedInAs: partnerID)

        var me: UUID?
        if scenario != "fresh" {
            // Starting signed out models a new phone: the space was backed up
            // on the old one and is waiting to be restored.
            me = world.addAccount(name: "Alex", appleID: startsSignedOut ? Self.appleID : nil)
        }
        local = LocalBackend(world: world, signedInAs: startsSignedOut ? nil : me)
        backend = local.makeBackend()

        switch scenario {
        case "empty":
            if let me { world.pair(me, partnerID) }
        case "paired", "premium":
            if let me { Self.seed(world: world, me: me, partner: partnerID, premium: scenario == "premium") }
        default:
            break
        }
        if scenario == "fresh" || scenario == "solo" {
            world.addWaitingSpace(owner: partnerID, invitationCode: Self.partnerInviteCode)
        }
        startWorker()
    }

    /// Stands in for the server's scheduler, and makes the demo partner feel
    /// alive: notes get read, and occasionally answered.
    private func startWorker() {
        worker = Task { [world] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                world.deliverDueScheduledMessages()
            }
        }
    }

    /// The demo partner accepts the invitation shown on the invite screen.
    func simulatePartnerJoining(code: String) async {
        let joiner = LocalBackend(world: world, signedInAs: partnerID)
        // Sam may be waiting in a space of their own; accepting closes it.
        try? await joiner.acceptInvitation(code: code)
    }

    /// The demo partner reads the latest note and reacts to it.
    func simulatePartnerSeeing(noteID: UUID) async {
        try? await Task.sleep(for: .seconds(2))
        try? await partnerSession.markSeen(noteID: noteID)
        try? await Task.sleep(for: .seconds(2))
        try? await partnerSession.setReaction(noteID: noteID, kind: .love)
    }

    func simulatePartnerNote() async {
        world.deliverNote(from: partnerID, content: NoteContent(
            body: "Just saw the sunset from the train. Wish you were here.",
            style: NoteStyle(paper: "blush", ink: "rose", typeface: .hand)
        ))
    }

    func setOffline(_ offline: Bool) {
        world.setFailure(offline ? .offline : nil)
    }

    func setPartnerPremium(_ premium: Bool) {
        world.setPremium(premium, for: partnerID)
    }

    // MARK: - Seed content

    private static func seed(world: LocalWorld, me: UUID, partner: UUID, premium: Bool) {
        let now = Date()
        let calendar = Calendar.current
        func ago(days: Int = 0, hours: Int = 0) -> Date {
            now.addingTimeInterval(-Double(days * 86_400 + hours * 3_600))
        }

        let couple = world.pair(me, partner, pairedAt: ago(days: 412))

        // Yesterday's question, answered by both and opened; and today's, which
        // the partner has already answered.
        world.answerTogether(as: me, "When you met me off the train with an umbrella.")
        world.answerTogether(as: partner, "The pancakes on Sunday. You remembered the lemon.")
        world.revealTogether(as: me)
        world.ageTogether(days: 1)
        world.answerTogether(as: partner, "Dancing in the kitchen while the pasta boiled over.")
        if premium { world.setPremium(true, for: partner) }

        world.deliverNote(from: partner, content: NoteContent(
            body: "You left your scarf here. I’m keeping it hostage until Friday.",
            style: NoteStyle(paper: "lined", ink: "ocean", typeface: .hand)
        ), at: ago(days: 6), seen: true)
        world.deliverNote(from: me, content: NoteContent(
            body: "Counter-offer: scarf for dinner. I’ll cook.",
            style: NoteStyle(paper: "cream", ink: "plum", typeface: .serif)
        ), at: ago(days: 6, hours: -2), seen: true)

        let photoPath = MediaPath.photo(coupleID: couple)
        if let photo = samplePhoto() { world.storeMedia(photo, at: photoPath) }
        let trip = world.deliverNote(from: partner, content: NoteContent(
            body: "Found our bench.",
            style: NoteStyle(paper: "cream", ink: "graphite", typeface: .hand, photoLayout: .framed),
            photoPath: photoPath
        ), at: ago(days: 3), seen: true)

        let mine = world.deliverNote(from: me, content: NoteContent(
            body: "Good luck today. You’ve got this.",
            style: NoteStyle(
                paper: "lilac", ink: "plum", typeface: .serif,
                stickers: [StickerPlacement(sticker: "star", x: 0.8, y: 0.2, scale: 1, rotation: 12)]
            )
        ), at: ago(hours: 20), seen: true)
        if let mine { world.setReaction(.love, on: mine.id, by: partner) }

        world.deliverNote(from: partner, content: NoteContent(
            body: "Thinking about you between meetings. Dinner at ours tonight?",
            style: NoteStyle(
                paper: "blush", ink: "rose", typeface: .hand,
                stickers: [StickerPlacement(sticker: "heart", x: 0.82, y: 0.84, scale: 0.9, rotation: -10)]
            )
        ), at: ago(hours: 1))

        func day(_ date: Date) -> DayDate { DayDate(date, calendar: calendar) }
        if let trip {
            world.addMemory(Memory(
                id: UUID(), coupleID: couple, createdBy: me, kind: .note, caption: "The bench by the river",
                content: trip.content, sourceNoteID: trip.id, occurredOn: day(trip.createdAt), createdAt: ago(days: 3)
            ))
        }
        world.addMemory(Memory(
            id: UUID(), coupleID: couple, createdBy: partner, kind: .moment, title: "Moved in together",
            caption: "Forty-one boxes and one very confused cat.", occurredOn: day(ago(days: 120)), createdAt: ago(days: 120)
        ))
        world.addMemory(Memory(
            id: UUID(), coupleID: couple, createdBy: me, kind: .moment, title: "First trip",
            caption: "Lisbon, in the rain.", occurredOn: day(ago(days: 300)), createdAt: ago(days: 300)
        ))
        world.addMemory(Memory(
            id: UUID(), coupleID: couple, createdBy: me, kind: .moment, title: "The night we met",
            occurredOn: day(ago(days: 412)), createdAt: ago(days: 400)
        ))

        let today = calendar.dateComponents([.year, .month, .day], from: now)
        let anniversary = calendar.date(byAdding: .day, value: 9, to: now) ?? now
        let parts = calendar.dateComponents([.month, .day], from: anniversary)
        world.addDate(ImportantDate(
            coupleID: couple, createdBy: me, title: "Anniversary", kind: .anniversary,
            startsOn: DayDate(year: (today.year ?? 2026) - 2, month: parts.month ?? 1, day: parts.day ?? 1),
            remindDaysBefore: [0, 7]
        ))
        let birthday = calendar.date(byAdding: .day, value: 41, to: now) ?? now
        let birthdayParts = calendar.dateComponents([.month, .day], from: birthday)
        world.addDate(ImportantDate(
            coupleID: couple, createdBy: me, title: "Sam’s birthday", kind: .birthday,
            startsOn: DayDate(year: 1995, month: birthdayParts.month ?? 1, day: birthdayParts.day ?? 1),
            remindDaysBefore: [0, 1, 7]
        ))
    }

    /// A drawn stand-in photograph, so no real image ships in the binary.
    private static func samplePhoto() -> Data? {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1), UIColor(red: 0.80, green: 0.62, blue: 0.74, alpha: 1), UIColor(red: 0.38, green: 0.36, blue: 0.56, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.55, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(red: 1, green: 0.93, blue: 0.78, alpha: 0.95).setFill()
            cg.fillEllipse(in: CGRect(x: 760, y: 250, width: 190, height: 190))
            UIColor(red: 0.20, green: 0.18, blue: 0.32, alpha: 1).setFill()
            let hills = UIBezierPath()
            hills.move(to: CGPoint(x: 0, y: 640))
            hills.addCurve(to: CGPoint(x: 1200, y: 600), controlPoint1: CGPoint(x: 380, y: 480), controlPoint2: CGPoint(x: 820, y: 720))
            hills.addLine(to: CGPoint(x: 1200, y: 900))
            hills.addLine(to: CGPoint(x: 0, y: 900))
            hills.close()
            hills.fill()
            UIColor(red: 0.13, green: 0.11, blue: 0.22, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 420, y: 650, width: 300, height: 22), cornerRadius: 6).fill()
            UIBezierPath(rect: CGRect(x: 450, y: 672, width: 16, height: 70)).fill()
            UIBezierPath(rect: CGRect(x: 674, y: 672, width: 16, height: 70)).fill()
            UIBezierPath(roundedRect: CGRect(x: 420, y: 590, width: 300, height: 18), cornerRadius: 6).fill()
        }.jpegData(compressionQuality: 0.8)
    }
}
#endif
