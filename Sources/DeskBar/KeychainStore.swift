import Foundation
import Security

/// Small generic-password Keychain wrapper. It never logs credentials or includes them in errors.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "com.deskbar.credentials") {
        self.service = service
    }

    func save(_ data: Data, for account: String) throws {
        try validate(account: account)

        let lookup = baseQuery(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var addQuery = lookup
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError(status: retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func save(_ secret: String, for account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.invalidSecret
        }
        try save(data, for: account)
    }

    func readData(for account: String) throws -> Data? {
        try validate(account: account)

        var query = baseQuery(account: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    func readString(for account: String) throws -> String? {
        guard let data = try readData(for: account) else { return nil }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidSecret
        }
        return secret
    }

    func delete(for account: String) throws {
        try validate(account: account)

        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }

    private func validate(account: String) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError.invalidIdentifier
        }
    }
}

enum KeychainError: Error, LocalizedError, Sendable {
    case invalidIdentifier
    case invalidSecret
    case operationFailed(status: OSStatus)

    init(status: OSStatus) {
        self = .operationFailed(status: status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "The Keychain service and account identifiers must not be empty."
        case .invalidSecret:
            "The credential could not be encoded or decoded."
        case let .operationFailed(status):
            "The Keychain operation failed (status \(status))."
        }
    }
}
