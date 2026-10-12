import Coach
import Models
import SwiftUI

/// A coaching session that can be given a name.
enum NamedSession: Identifiable {
    case review(CoachReview)
    case conversation(CoachConversation)

    var id: UUID {
        switch self {
        case .review(let review): review.uuid
        case .conversation(let conversation): conversation.uuid
        }
    }

    var currentName: String {
        switch self {
        case .review(let review): review.title
        case .conversation(let conversation): conversation.title
        }
    }
}

extension CoachReview {
    /// The review's name, or its date when it has none.
    var displayTitle: String {
        title.isEmpty ? date.formatted(.dateTime.weekday(.wide).day().month()) : title
    }
}

extension View {
    /// Presents a prompt to rename the given session; set the binding to show it.
    func renameSession(_ session: Binding<NamedSession?>) -> some View {
        modifier(RenameSessionModifier(session: session))
    }
}

private struct RenameSessionModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Binding var session: NamedSession?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } })) {
                TextField("Name", text: $name)
                Button("Save", action: save)
                Button("Cancel", role: .cancel) {}
            } message: {
                if case .review = session {
                    Text("Leave it empty to list this review by its date.")
                }
            }
            .onChange(of: session?.id) {
                name = session?.currentName ?? ""
            }
    }

    private func save() {
        switch session {
        case .review(let review): SessionTitle.rename(review, to: name)
        case .conversation(let conversation): SessionTitle.rename(conversation, to: name)
        case nil: break
        }
        environment.saveChanges()
    }
}
