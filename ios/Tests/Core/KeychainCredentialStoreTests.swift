import XCTest
import Security
@testable import RemoteMini

/// Runs against the real iOS Keychain (via the `iPhone-dogfood` simulator) -- not a
/// fake/in-memory double -- because the property under test (§2-1: never log the
/// key, persist it durably across launches) is only true of the actual Security
/// framework, not of a stand-in that merely has the same method signatures.
final class KeychainCredentialStoreTests: XCTestCase {
    private let store = KeychainCredentialStore()

    override func setUpWithError() throws {
        try store.clear()
    }

    override func tearDownWithError() throws {
        try store.clear()
    }

    func testLoadWithNothingStoredReturnsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let credentials = Credentials(baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "unit-test-fixture-key-not-real")
        try store.save(credentials)

        XCTAssertEqual(try store.load(), credentials)
    }

    func testSavingTwiceOverwritesRatherThanDuplicating() throws {
        let first = Credentials(baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "fixture-key-one")
        let second = Credentials(baseURL: URL(string: "https://unit-test-2.invalid")!, apiKey: "fixture-key-two")
        try store.save(first)
        try store.save(second)

        XCTAssertEqual(try store.load(), second)
    }

    func testClearRemovesTheStoredValue() throws {
        try store.save(Credentials(baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "fixture-key"))
        try store.clear()

        XCTAssertNil(try store.load())
    }

    func testClearOnAnAlreadyEmptyStoreDoesNotThrow() {
        XCTAssertNoThrow(try store.clear())
    }

    func testLoadReflectsAnOutOfBandDeletionProvingItReadsTheRealKeychain() throws {
        // Negative control for "this class is secretly an in-memory cache and never
        // really calls the Security framework": delete the item via the raw
        // Security API, bypassing `KeychainCredentialStore` entirely, then confirm
        // `load()` sees the deletion. A cache-backed fake would still return the
        // saved value here, because it never persisted anywhere an out-of-band
        // delete could reach.
        let credentials = Credentials(baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "fixture-key")
        try store.save(credentials)
        XCTAssertEqual(try store.load(), credentials)

        let rawQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tomarai.remotemini.credentials",
            kSecAttrAccount as String: "rc-backend",
        ]
        let status = SecItemDelete(rawQuery as CFDictionary)
        XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "control must actually reach the same keychain item")

        XCTAssertNil(try store.load(), "load() must reflect the out-of-band deletion")
    }
}
