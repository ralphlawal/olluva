import SwiftUI
import WidgetKit

@main
struct NotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        LatestNoteWidget()
        LockScreenNoteWidget()
    }
}
