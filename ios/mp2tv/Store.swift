import Foundation
import Security

/// 已配对电脑。token 存 Keychain，其余元数据存 UserDefaults。
struct PairedComputer: Codable {
    var receiverId: String
    var name: String
    var lastHost: String
    var lastPort: Int
    var fpB64: String       // 证书指纹 base64
    var invalid: Bool = false // 电脑端已解除配对
    func fp() -> Data { Data(base64Encoded: fpB64) ?? Data() }
}

enum Store {
    private static let listKey = "pairedComputers"
    private static let defaults = UserDefaults.standard

    static var senderId: String {
        if let id = defaults.string(forKey: "senderId") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "senderId")
        return id
    }

    static var smartCropDefault: Bool {
        get { defaults.object(forKey: "smartCrop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "smartCrop") }
    }

    static func list() -> [PairedComputer] {
        guard let d = defaults.data(forKey: listKey),
              let a = try? JSONDecoder().decode([PairedComputer].self, from: d) else { return [] }
        return a
    }

    static func upsert(_ c: PairedComputer) {
        var a = list()
        if let i = a.firstIndex(where: { $0.receiverId == c.receiverId }) { a[i] = c } else { a.append(c) }
        defaults.set(try? JSONEncoder().encode(a), forKey: listKey)
    }

    static func remove(_ receiverId: String) {
        defaults.set(try? JSONEncoder().encode(list().filter { $0.receiverId != receiverId }), forKey: listKey)
        deleteToken(receiverId)
    }

    // ---- Keychain ----

    static func saveToken(_ receiverId: String, _ token: Data) {
        deleteToken(receiverId)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mp2tv.\(receiverId)",
            kSecValueData as String: token,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func token(_ receiverId: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mp2tv.\(receiverId)",
            kSecReturnData as String: true
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func deleteToken(_ receiverId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "mp2tv.\(receiverId)"
        ] as CFDictionary)
    }
}
