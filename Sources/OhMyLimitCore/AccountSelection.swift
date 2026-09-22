import Combine
import Foundation

@MainActor
public final class AccountSelection: ObservableObject {
    @Published public private(set) var selectedID: UUID?

    public init(selectedID: UUID? = nil) {
        self.selectedID = selectedID
    }

    public func select(_ id: UUID) {
        guard selectedID != id else { return }
        selectedID = id
    }

    public func reconcile(accountIDs: [UUID]) {
        if let selectedID, accountIDs.contains(selectedID) { return }
        guard selectedID != accountIDs.first else { return }
        selectedID = accountIDs.first
    }
}
