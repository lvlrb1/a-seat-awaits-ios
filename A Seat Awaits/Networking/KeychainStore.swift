//
//  KeychainStore.swift
//  A Seat Awaits
//
//  Minimal Keychain wrapper for persisting the Supabase auth session
//  securely across launches. Stored as a single JSON blob under one account.
//

import Foundation
import Security

/// Stores and retrieves a small `Codable` value in the Keychain. Stateless
/// infrastructure — `nonisolated` so the Supabase `actor` can build and use it
/// without tripping the project's default-MainActor isolation.
nonisolated struct KeychainStore {
    let service: String
    let account: String

    init(service: String = "com.aseatawaits.app", account: String = "supabase.session") {
        self.service = service
        self.account = account
    }

    func save<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
