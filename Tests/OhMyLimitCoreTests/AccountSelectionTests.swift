import Foundation
import Testing
@testable import OhMyLimitCore

@MainActor
struct AccountSelectionTests {
    @Test func selectionSurvivesRefreshReorderingAndNewAccounts() {
        let first = UUID(), second = UUID(), added = UUID()
        let selection = AccountSelection()
        selection.reconcile(accountIDs: [first, second])
        selection.select(second)

        selection.reconcile(accountIDs: [second, first, added])

        #expect(selection.selectedID == second)
    }

    @Test func removedSelectionFallsBackToFirstRemainingAccount() {
        let first = UUID(), second = UUID()
        let selection = AccountSelection(selectedID: second)

        selection.reconcile(accountIDs: [first])

        #expect(selection.selectedID == first)
    }

    @Test func emptyAccountsClearSelectionAndReconnectSelectsNewAccount() {
        let removed = UUID(), added = UUID()
        let selection = AccountSelection(selectedID: removed)
        selection.reconcile(accountIDs: [])
        #expect(selection.selectedID == nil)

        selection.reconcile(accountIDs: [added])

        #expect(selection.selectedID == added)
    }

    @Test func explicitNewAccountSelectionTakesPrecedence() {
        let first = UUID(), added = UUID()
        let selection = AccountSelection(selectedID: first)
        selection.select(added)

        selection.reconcile(accountIDs: [first, added])

        #expect(selection.selectedID == added)
    }
}
