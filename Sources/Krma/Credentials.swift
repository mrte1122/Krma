import Foundation
import Security

enum Keychain {
    enum Item: String {
        case refreshToken = "refresh-token"
        case accessToken = "access-token"
    }

    private static let service = "Krma"

    private static func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    static func load(_ item: Item) -> String? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func save(_ value: String, _ item: Item) -> Bool {
        delete(item)
        var q = query(item)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ item: Item) {
        SecItemDelete(query(item) as CFDictionary)
    }
}
