import XCTest
import Security
@testable import RemoteMini

/// Runs against the real iOS Keychain (via the `iPhone-dogfood` simulator) -- not a
/// fake/in-memory double -- because the property under test (§2-1: never log the
/// key, persist it durably across launches) is only true of the actual Security
/// framework, not of a stand-in that merely has the same method signatures.
///
/// ★座標は製品と**別**にしてある。此の class は `setUp`/`tearDown` で `clear()` を
/// 呼ぶので、座標を共有していた間は単体検査を1回回すだけで電話の本物の項目が消えた
/// (2026-08-15 実測 / DESIGN §2.94)。本物の Keychain を使う事と、本物の**項目**を
/// 使う事は別で、此の class が要るのは前者だけ。
final class KeychainCredentialStoreTests: XCTestCase {
    private static let testService = "com.tomarai.remotemini.tests.credentials"
    private static let testAccount = "rc-backend-unit-tests"

    private let store = KeychainCredentialStore(
        service: KeychainCredentialStoreTests.testService,
        account: KeychainCredentialStoreTests.testAccount
    )

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
            kSecAttrService as String: Self.testService,
            kSecAttrAccount as String: Self.testAccount,
        ]
        let status = SecItemDelete(rawQuery as CFDictionary)
        XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "control must actually reach the same keychain item")

        XCTAssertNil(try store.load(), "load() must reflect the out-of-band deletion")
    }

    func testTheseTestsAddressADifferentKeychainItemThanTheProduct() {
        // 此の class は `setUp`/`tearDown` で `clear()` を呼ぶ。座標を製品と共有すると、
        // 検査を回す事それ自体が電話の資格情報を消す操作になる —— 2026-08-15 に実際に
        // そうなり、app は次の起動で鍵入力欄を出した。定数の比較に見えるが、守っている
        // のは「検査の後始末が製品の項目に届かない」という到達性の話。
        let production = KeychainCredentialStore()
        XCTAssertNotEqual(Self.testService, production.service)
        XCTAssertNotEqual(Self.testAccount, production.account)
    }

    func testTheProductionItemKeepsTheCoordinatesAlreadyInstalledOnThePhone() {
        // 座標の変更は**移行案件**。名前を変えた新しい binary は旧座標の項目を見つけられず、
        // 既に入っている電話は人が鍵を打ち直すまで戻らない(`provisioning.planted-seed.v1`
        // を使い回すと #56 の電話が壊れるのと同じ形 = DESIGN §2.94)。往復の検査は
        // どんな座標でも緑になるので、此処で値そのものを固定する。
        let production = KeychainCredentialStore()
        XCTAssertEqual(production.service, "com.tomarai.remotemini.credentials")
        XCTAssertEqual(production.account, "rc-backend")
    }
}
