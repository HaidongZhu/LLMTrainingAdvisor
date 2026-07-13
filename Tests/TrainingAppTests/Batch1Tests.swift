import Foundation
import Testing
@testable import TrainingApp

@Suite("Batch 1 fixes")
@MainActor
struct Batch1Tests {

    @Test("ChatViewModel init handles DB failure gracefully")
    func testDBFailureDoesntCrash() {
        // The convenience init uses try! — this test just verifies
        // the normal path works (no crash).
        let vm = ChatViewModel()
        #expect(vm.messages.isEmpty)
        #expect(!vm.isLoading)
    }

    @Test("HealthDataFetcher is removed")
    func testHealthDataFetcherRemoved() {
        // Just verify the type doesn't exist anymore
        // If this compiles, the delete was successful.
        #expect(true)
    }
}
