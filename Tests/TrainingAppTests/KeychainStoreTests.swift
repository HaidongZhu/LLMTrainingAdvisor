import Foundation
import Testing
@testable import TrainingApp

@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {
    private let account = "test_keychain_key"

    private func cleanup() {
        KeychainStore.delete(forKey: account)
    }

    @Test("save then read returns the same value")
    func testSaveRead() {
        cleanup()
        let ok = KeychainStore.save("sk-abc123", forKey: account)
        #expect(ok)
        #expect(KeychainStore.read(forKey: account) == "sk-abc123")
        cleanup()
    }

    @Test("read on missing key returns nil")
    func testReadMissing() {
        cleanup()
        #expect(KeychainStore.read(forKey: account) == nil)
    }

    @Test("save overwrites existing value")
    func testOverwrite() {
        cleanup()
        KeychainStore.save("old", forKey: account)
        KeychainStore.save("new", forKey: account)
        #expect(KeychainStore.read(forKey: account) == "new")
        cleanup()
    }

    @Test("delete removes the value")
    func testDelete() {
        cleanup()
        KeychainStore.save("to-delete", forKey: account)
        #expect(KeychainStore.delete(forKey: account))
        #expect(KeychainStore.read(forKey: account) == nil)
    }

    @Test("delete on missing key is not an error")
    func testDeleteMissing() {
        cleanup()
        #expect(KeychainStore.delete(forKey: account))
    }
}
