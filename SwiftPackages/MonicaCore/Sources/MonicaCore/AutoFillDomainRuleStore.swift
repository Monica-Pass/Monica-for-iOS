import Foundation

/// 域名规则的持久化抽象（#40）。
///
/// 规则属于安全敏感配置：实现必须把内容存到 Keychain 或保险库加密存储里，
/// 不允许写明文 `UserDefaults`、日志或缓存文件。
public protocol AutoFillDomainRuleStoring: Sendable {
    func loadRuleSet(vaultID: String) async throws -> AutoFillDomainRuleSet?
    func saveRuleSet(_ ruleSet: AutoFillDomainRuleSet, vaultID: String) async throws
    func deleteRuleSet(vaultID: String) async throws
}

/// 仅用于测试、预览与「规则尚未加载」占位的内存实现。
public actor MemoryAutoFillDomainRuleStore: AutoFillDomainRuleStoring {
    private var storage: [String: AutoFillDomainRuleSet]

    public init(initial: [String: AutoFillDomainRuleSet] = [:]) {
        self.storage = initial
    }

    public func loadRuleSet(vaultID: String) async throws -> AutoFillDomainRuleSet? {
        storage[vaultID]
    }

    public func saveRuleSet(_ ruleSet: AutoFillDomainRuleSet, vaultID: String) async throws {
        storage[vaultID] = ruleSet
    }

    public func deleteRuleSet(vaultID: String) async throws {
        storage[vaultID] = nil
    }
}

/// 把 `AutoFillDomainRuleSet` 编码成可放进 Keychain 的二进制。
///
/// 单独抽出来是为了让 App 与 AutoFill 扩展用同一份编码逻辑；日期用 ISO8601，
/// 避免不同进程的默认日期策略不一致导致解码失败。
public enum AutoFillDomainRuleCodec {
    public static func encode(_ ruleSet: AutoFillDomainRuleSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ruleSet)
    }

    public static func decode(_ data: Data) throws -> AutoFillDomainRuleSet {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AutoFillDomainRuleSet.self, from: data)
    }
}
