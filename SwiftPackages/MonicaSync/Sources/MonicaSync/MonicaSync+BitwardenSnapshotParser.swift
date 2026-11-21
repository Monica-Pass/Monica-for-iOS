// MARK: - Bitwarden 保险库快照解析（snapshot JSON → BitwardenSyncSnapshot）

import Foundation

enum BitwardenVaultSyncSnapshotParser {
    static func parse(_ data: Data, fallbackAccountLabel: String, vaultKey: BitwardenVaultKey? = nil) throws -> BitwardenSyncSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BitwardenSyncProviderError.invalidResponse
        }
        let profile = dictionary(root, "profile", "Profile")
        let folders = array(root, "folders", "Folders")
        let collections = array(root, "collections", "Collections")
        let ciphers = array(root, "ciphers", "Ciphers")
        let sends = array(root, "sends", "Sends")
        let folderItems = folders.compactMap { folder -> BitwardenSyncFolder? in
            guard let id = string(folder, "id", "Id"), !id.isEmpty else { return nil }
            return BitwardenSyncFolder(
                remoteID: id,
                name: decryptedString(folder, "name", "Name", key: vaultKey) ?? "",
                updatedAt: date(string(folder, "revisionDate", "RevisionDate"))
            )
        }
        let folderNamesByID = Dictionary(uniqueKeysWithValues: folderItems.map { ($0.remoteID, $0.name) })
        let collectionItems = collections.compactMap { collection -> BitwardenSyncCollection? in
            guard let id = string(collection, "id", "Id"), !id.isEmpty else { return nil }
            return BitwardenSyncCollection(
                remoteID: id,
                name: decryptedString(collection, "name", "Name", key: vaultKey) ?? "",
                organizationID: string(collection, "organizationId", "OrganizationId"),
                isDefault: bool(collection, "default", "Default") ?? false
            )
        }
        let collectionNamesByID = Dictionary(uniqueKeysWithValues: collectionItems.map { ($0.remoteID, $0.name) })
        let items = ciphers.compactMap { cipher -> BitwardenSyncItem? in
            guard let id = string(cipher, "id", "Id"), !id.isEmpty else { return nil }
            let effectiveKey: BitwardenVaultKey?
            if let vaultKey,
               let itemKey = string(cipher, "key", "Key"),
               !itemKey.isEmpty {
                effectiveKey = try? BitwardenCrypto.decryptSymmetricKey(itemKey, key: vaultKey)
            } else {
                effectiveKey = vaultKey
            }
            let folderID = string(cipher, "folderId", "FolderId")
            let collectionIDs = stringArray(cipher, "collectionIds", "CollectionIds")
            let collectionNames = collectionIDs
                .compactMap { collectionNamesByID[$0] }
                .filter { !$0.isEmpty }
            let login = dictionary(cipher, "login", "Login")
            let card = dictionary(cipher, "card", "Card")
            let identity = dictionary(cipher, "identity", "Identity")
            let sshKey = dictionary(cipher, "sshKey", "SshKey", "SSHKey")
            let customFields = customFields(cipher, key: effectiveKey)
            let customFieldItems = customFieldItems(cipher, key: effectiveKey)
            let fido2Credential = array(login, "fido2Credentials", "Fido2Credentials").first ?? [:]
            let type = int(cipher, "type", "Type") ?? 1
            let kind = itemKind(
                for: type,
                hasFido2Credential: !fido2Credential.isEmpty,
                hasLegacySshKeyFields: hasLegacySshKeyFields(customFields)
            )
            let firstURI = array(login, "uris", "Uris").first
            let attachments = array(cipher, "attachments", "Attachments").compactMap { attachment -> BitwardenSyncAttachment? in
                guard let attachmentID = string(attachment, "id", "Id"), !attachmentID.isEmpty else { return nil }
                return BitwardenSyncAttachment(
                    remoteID: attachmentID,
                    cipherRemoteID: id,
                    fileName: decryptedString(attachment, "fileName", "FileName", key: effectiveKey) ?? "",
                    encryptedKey: string(attachment, "key", "Key"),
                    byteCount: int(attachment, "size", "Size") ?? 0
                )
            }
            let notes = decryptedString(cipher, "notes", "Notes", key: effectiveKey)
            return BitwardenSyncItem(
                remoteID: id,
                kind: kind,
                title: decryptedString(cipher, "name", "Name", key: effectiveKey) ?? "",
                username: decryptedString(login, "username", "Username", key: effectiveKey) ?? identityUsername(cipher, key: effectiveKey),
                url: firstURI.flatMap { decryptedString($0, "uri", "Uri", key: effectiveKey) } ?? "",
                password: decryptedString(login, "password", "Password", key: effectiveKey),
                totpSecret: decryptedString(login, "totp", "Totp", key: effectiveKey),
                notes: notes,
                folderID: folderID,
                folderName: folderID.flatMap { folderNamesByID[$0] },
                collectionNames: collectionNames,
                organizationID: string(cipher, "organizationId", "OrganizationId"),
                collectionIDs: collectionIDs,
                customFields: customFieldItems,
                attachments: attachments,
                attachmentByteCount: byteCount(array(cipher, "attachments", "Attachments")),
                updatedAt: date(string(cipher, "revisionDate", "RevisionDate")),
                favorite: bool(cipher, "favorite", "Favorite") ?? false,
                deletedAt: date(string(cipher, "deletedDate", "DeletedDate")),
                cardholderName: decryptedString(card, "cardholderName", "CardholderName", key: effectiveKey) ?? "",
                cardNumber: decryptedString(card, "number", "Number", key: effectiveKey) ?? "",
                cardExpiryMonth: decryptedString(card, "expMonth", "ExpMonth", key: effectiveKey) ?? "",
                cardExpiryYear: decryptedString(card, "expYear", "ExpYear", key: effectiveKey) ?? "",
                cardCode: decryptedString(card, "code", "Code", key: effectiveKey) ?? "",
                cardBrand: decryptedString(card, "brand", "Brand", key: effectiveKey) ?? "",
                identityFullName: identityFullName(identity, key: effectiveKey),
                identityDocumentNumber: decryptedString(identity, "passportNumber", "PassportNumber", key: effectiveKey)
                    ?? decryptedString(identity, "licenseNumber", "LicenseNumber", key: effectiveKey)
                    ?? "",
                identityIssuer: decryptedString(identity, "company", "Company", key: effectiveKey) ?? "",
                identityCountry: decryptedString(identity, "country", "Country", key: effectiveKey) ?? "",
                passkeyRelyingPartyID: decryptedString(fido2Credential, "rpId", "RpId", key: effectiveKey) ?? "",
                passkeyRelyingPartyName: decryptedString(fido2Credential, "rpName", "RpName", key: effectiveKey) ?? "",
                passkeyCredentialID: decryptedString(fido2Credential, "credentialId", "CredentialId", key: effectiveKey) ?? "",
                passkeyUserHandle: decryptedString(fido2Credential, "userHandle", "UserHandle", key: effectiveKey) ?? "",
                passkeyPublicKeyCOSE: passkeyMetadataValue("publicKeyCOSE", notes: notes),
                passkeyPrivateKeyReference: decryptedString(fido2Credential, "keyValue", "KeyValue", key: effectiveKey) ?? "",
                passkeyPublicKeyAlgorithm: decryptedString(fido2Credential, "keyAlgorithm", "KeyAlgorithm", key: effectiveKey) ?? "",
                passkeyCounter: decryptedString(fido2Credential, "counter", "Counter", key: effectiveKey) ?? "",
                passkeyDiscoverable: passkeyBoolean(decryptedString(fido2Credential, "discoverable", "Discoverable", key: effectiveKey)),
                passkeyCreationDate: string(fido2Credential, "creationDate", "CreationDate") ?? "",
                sshPublicKey: decryptedString(sshKey, "publicKey", "PublicKey", key: effectiveKey)
                    ?? sshPublicKey(from: customFields),
                sshPrivateKey: decryptedString(sshKey, "privateKey", "PrivateKey", key: effectiveKey)
                    ?? sshPrivateKey(from: customFields),
                sshKeyFingerprint: decryptedString(sshKey, "keyFingerprint", "KeyFingerprint", "fingerprint", "Fingerprint", key: effectiveKey)
                    ?? sshFingerprint(from: customFields)
            )
        }
        let sendItems = sends.compactMap { send -> BitwardenSendSyncItem? in
            guard let id = string(send, "id", "Id"), !id.isEmpty else { return nil }
            let text = dictionary(send, "text", "Text")
            let file = dictionary(send, "file", "File")
            let sendKey: BitwardenVaultKey?
            if let vaultKey,
               let encryptedKey = string(send, "key", "Key"),
               !encryptedKey.isEmpty,
               let keyMaterial = try? BitwardenCrypto.decrypt(encryptedKey, key: vaultKey) {
                sendKey = try? BitwardenCrypto.deriveSendKey(keyMaterial)
            } else {
                sendKey = vaultKey
            }
            let fileName = decryptedString(file, "fileName", "FileName", key: sendKey)
            return BitwardenSendSyncItem(
                remoteID: id,
                title: decryptedString(send, "name", "Name", key: sendKey) ?? fileName ?? "",
                body: decryptedString(text, "text", "Text", key: sendKey) ?? fileName ?? "",
                notes: decryptedString(send, "notes", "Notes", key: sendKey),
                expiresAt: string(send, "expirationDate", "ExpirationDate") ?? "",
                maxViews: int(send, "maxAccessCount", "MaxAccessCount") ?? 1,
                attachmentByteCount: byteCount([file]),
                updatedAt: date(string(send, "revisionDate", "RevisionDate"))
            )
        }
        return BitwardenSyncSnapshot(
            accountLabel: accountLabel(profile: profile, fallback: fallbackAccountLabel),
            revision: string(profile, "securityStamp", "SecurityStamp") ?? "",
            premiumSource: premiumSource(profile: profile),
            folders: folderItems,
            collections: collectionItems,
            items: items,
            sends: sendItems
        )
    }

    private static func premiumSource(profile: [String: Any]) -> BitwardenSyncSnapshot.PremiumSource {
        if bool(profile, "premiumFromOrganization", "PremiumFromOrganization") == true {
            return .organization
        }
        if bool(profile, "premium", "Premium") == true {
            return .account
        }
        return .none
    }

    private static func itemKind(
        for type: Int,
        hasFido2Credential: Bool = false,
        hasLegacySshKeyFields: Bool = false
    ) -> BitwardenSyncItemKind {
        switch type {
        case 2:
            .secureNote
        case 3:
            .card
        case 4:
            .identity
        case 5:
            .sshKey
        default:
            if hasLegacySshKeyFields {
                .sshKey
            } else {
                hasFido2Credential ? .passkey : .login
            }
        }
    }

    private static func customFields(_ cipher: [String: Any], key: BitwardenVaultKey?) -> [String: String] {
        array(cipher, "fields", "Fields").reduce(into: [String: String]()) { result, field in
            guard let name = decryptedString(field, "name", "Name", key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return
            }
            let value = decryptedString(field, "value", "Value", key: key) ?? ""
            result[name] = value
            result[name.lowercased()] = value
        }
    }

    /// 带类型的自定义字段列表（供只读展示与字段级合并使用）。
    /// Monica 自己写入的 `monica_*` 兼容字段不重复展示。
    private static func customFieldItems(_ cipher: [String: Any], key: BitwardenVaultKey?) -> [BitwardenSyncCustomField] {
        array(cipher, "fields", "Fields").compactMap { field -> BitwardenSyncCustomField? in
            guard let name = decryptedString(field, "name", "Name", key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  !name.lowercased().hasPrefix("monica_") else {
                return nil
            }
            let rawType = int(field, "type", "Type") ?? 0
            let type: BitwardenSyncCustomFieldType = switch rawType {
            case 1: .hidden
            case 2: .boolean
            default: .text
            }
            return BitwardenSyncCustomField(
                name: name,
                value: decryptedString(field, "value", "Value", key: key) ?? "",
                type: type
            )
        }
    }

    private static func hasLegacySshKeyFields(_ fields: [String: String]) -> Bool {
        let loginType = customFieldValue(fields, "monica_login_type")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return loginType.compare("SSH_KEY", options: .caseInsensitive) == .orderedSame
            || !sshPublicKey(from: fields).isEmpty
            || !sshPrivateKey(from: fields).isEmpty
            || !sshFingerprint(from: fields).isEmpty
    }

    private static func sshPublicKey(from fields: [String: String]) -> String {
        let namedValue = customFieldValue(
            fields,
            "monica_ssh_public_key",
            "publicKey",
            "public_key",
            "public key",
            "public-key",
            "ssh public key",
            "ssh_public_key"
        )
        return nonBlank(namedValue) ?? fields.values.first(where: looksLikeSshPublicKey) ?? ""
    }

    private static func sshPrivateKey(from fields: [String: String]) -> String {
        let namedValue = customFieldValue(
            fields,
            "monica_ssh_private_key",
            "privateKey",
            "private_key",
            "private key",
            "private-key",
            "ssh private key",
            "ssh_private_key"
        )
        return nonBlank(namedValue) ?? fields.values.first(where: looksLikeSshPrivateKey) ?? ""
    }

    private static func sshFingerprint(from fields: [String: String]) -> String {
        let namedValue = customFieldValue(
            fields,
            "monica_ssh_fingerprint",
            "keyFingerprint",
            "key_fingerprint",
            "key fingerprint",
            "key-fingerprint",
            "fingerprint",
            "ssh fingerprint",
            "ssh_fingerprint"
        )
        return nonBlank(namedValue) ?? fields.values.first(where: looksLikeSshFingerprint) ?? ""
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func customFieldValue(_ fields: [String: String], _ names: String...) -> String {
        for name in names {
            if let value = fields[name] ?? fields[name.lowercased()] {
                return value
            }
        }
        return ""
    }

    private static func looksLikeSshPublicKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("ssh-rsa ")
            || trimmed.hasPrefix("ssh-ed25519 ")
            || trimmed.hasPrefix("ecdsa-sha2-")
            || trimmed.hasPrefix("ssh-dss ")
    }

    private static func looksLikeSshPrivateKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("BEGIN OPENSSH PRIVATE KEY")
            || trimmed.contains("BEGIN RSA PRIVATE KEY")
            || trimmed.contains("BEGIN EC PRIVATE KEY")
            || trimmed.contains("BEGIN DSA PRIVATE KEY")
            || trimmed.contains("BEGIN PRIVATE KEY")
    }

    private static func looksLikeSshFingerprint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("SHA256:")
            || trimmed.hasPrefix("MD5:")
    }

    private static func identityUsername(_ cipher: [String: Any], key: BitwardenVaultKey?) -> String {
        let identity = dictionary(cipher, "identity", "Identity")
        return decryptedString(identity, "username", "Username", key: key)
            ?? decryptedString(identity, "email", "Email", key: key)
            ?? ""
    }

    private static func identityFullName(_ identity: [String: Any], key: BitwardenVaultKey?) -> String {
        [
            decryptedString(identity, "title", "Title", key: key) ?? "",
            decryptedString(identity, "firstName", "FirstName", key: key) ?? "",
            decryptedString(identity, "middleName", "MiddleName", key: key) ?? "",
            decryptedString(identity, "lastName", "LastName", key: key) ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func decryptedString(_ json: [String: Any], _ keys: String..., key: BitwardenVaultKey?) -> String? {
        let rawValue = keys.lazy.compactMap { string(json, $0) }.first
        guard let rawValue else { return nil }
        guard BitwardenCipherString.isCipherString(rawValue) else {
            return rawValue
        }
        guard let key else { return nil }
        return try? BitwardenCrypto.decryptString(rawValue, key: key)
    }

    private static func passkeyBoolean(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "false", "0", "no":
            false
        default:
            true
        }
    }

    private static func passkeyMetadataValue(_ key: String, notes: String?) -> String {
        guard let notes,
              notes.contains("[Monica Passkey Metadata]") else {
            return ""
        }
        let lines = notes.components(separatedBy: .newlines)
        guard let markerIndex = lines.firstIndex(of: "[Monica Passkey Metadata]") else {
            return ""
        }
        let prefix = "\(key):"
        return lines.dropFirst(markerIndex + 1)
            .first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) }
            .map { line in
                let value = line.dropFirst(prefix.count)
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
    }

    private static func accountLabel(profile: [String: Any], fallback: String) -> String {
        let name = string(profile, "name", "Name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        let email = string(profile, "email", "Email")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty {
            return email
        }
        return fallback
    }

    private static func byteCount(_ values: [[String: Any]]) -> Int {
        values.reduce(0) { partial, value in
            partial + (int(value, "size", "Size") ?? 0)
        }
    }

    private static func dictionary(_ json: [String: Any], _ keys: String...) -> [String: Any] {
        for key in keys {
            if let value = json[key] as? [String: Any] {
                return value
            }
        }
        return [:]
    }

    private static func array(_ json: [String: Any], _ keys: String...) -> [[String: Any]] {
        for key in keys {
            if let value = json[key] as? [[String: Any]] {
                return value
            }
        }
        return []
    }

    private static func stringArray(_ json: [String: Any], _ keys: String...) -> [String] {
        for key in keys {
            if let values = json[key] as? [String] {
                return values
            }
            if let values = json[key] as? [Any] {
                return values.compactMap { value in
                    if let stringValue = value as? String {
                        return stringValue
                    }
                    if let number = value as? NSNumber {
                        return number.stringValue
                    }
                    return nil
                }
            }
        }
        return []
    }

    private static func string(_ json: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                return value
            }
            if let number = json[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func int(_ json: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = json[key] as? Int {
                return value
            }
            if let value = json[key] as? Double {
                return Int(value)
            }
            if let value = json[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    private static func bool(_ json: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = json[key] as? Bool {
                return value
            }
            if let value = json[key] as? NSNumber {
                return value.boolValue
            }
            if let value = json[key] as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
