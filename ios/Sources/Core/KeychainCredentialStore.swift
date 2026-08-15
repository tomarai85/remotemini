import Foundation
import Security

/// iOS Keychain storage for `Credentials` (spec §2-1).
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` deliberately: no iCloud
/// Keychain sync, so losing the phone does not spread the key to every device
/// signed into the same Apple ID (DESIGN §6 treats phone loss as the primary
/// threat). `ThisDeviceOnly` is the mechanism that enforces "no sync" -- it is not
/// merely a stricter unlock requirement.
final class KeychainCredentialStore: CredentialStore {
    /// 電話に実際に入っている項目の座標。**製品側は誰も引数を渡さない** ——
    /// 注入口を開けたのは検査の為だけで、理由は観測値:
    /// `KeychainCredentialStoreTests` は `setUp`/`tearDown` で `clear()` を呼ぶので、
    /// 座標を製品と共有していた間、単体検査を1回回すと**電話の本物の資格情報が消えた**
    /// (2026-08-15 実測。app は次の起動で鍵入力欄を出した = DESIGN §2.94 の引き金)。
    ///
    /// 此の2つの値を変えるのは**移行案件**。既に入っている電話の項目は旧座標に残り、
    /// 新しい binary からは見えないので、人が鍵を打ち直すまで戻らない
    /// (`provisioning.rejected-seed.v1` へ鍵名を新設したのと同じ形の危険)。
    static let productionService = "com.tomarai.remotemini.credentials"
    static let productionAccount = "rc-backend"

    let service: String
    let account: String

    init(
        service: String = KeychainCredentialStore.productionService,
        account: String = KeychainCredentialStore.productionAccount
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.malformedStoredValue }
        return try Self.decode(data)
    }

    func save(_ credentials: Credentials) throws {
        let data = try Self.encode(credentials)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func encode(_ credentials: Credentials) throws -> Data {
        try JSONEncoder().encode(Wire(baseURL: credentials.baseURL.absoluteString, apiKey: credentials.apiKey))
    }

    private static func decode(_ data: Data) throws -> Credentials {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard let url = URL(string: wire.baseURL) else { throw KeychainError.malformedStoredValue }
        return Credentials(baseURL: url, apiKey: wire.apiKey)
    }

    private struct Wire: Codable {
        let baseURL: String
        let apiKey: String
    }
}
