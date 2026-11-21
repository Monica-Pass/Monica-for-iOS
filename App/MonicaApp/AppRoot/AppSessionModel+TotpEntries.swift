import Foundation
import MonicaCore
import MonicaStorage

// slice C1: TotpEntries 域（验证码条目 CRUD、导入、生成与进度、卡片样式偏好），从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    var filteredTotpEntries: [LocalTotpEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = totpSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            totpEntries,
            query: query,
            favoritesOnly: showFavoriteTotpEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.accountName.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - 验证码卡片进度条（#155）

    /// 把「偏好 + 系统减弱动态效果」解析成卡片实际渲染规则。
    func totpCardStylePolicy(reduceMotion: Bool) -> TotpCardStylePolicy {
        TotpCardStylePolicy(preferences: totpCardPreferences, reduceMotion: reduceMotion)
    }

    func updateTotpCardPreferences(_ preferences: TotpProgressPreferences) {
        totpCardPreferences = preferences
        totpCardPreferenceStore.savePreferences(preferences)
        recordUserActivity()
    }

    func restoreDefaultTotpCardPreferences() {
        updateTotpCardPreferences(.default)
    }

    func createTotpEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try createOrReuseVaultProject(title: projectTitle, entryRepository: entryRepository)
                activeProject = project
            }
            let entry = try entryRepository.createTotpEntry(
                projectID: project.id,
                draft: try advancedTotpDraft(
                    title: totpTitle,
                    secret: totpSecret,
                    issuer: totpIssuer,
                    accountName: totpAccountName,
                    period: totpPeriod,
                    digits: totpDigits,
                    algorithm: totpAlgorithm,
                    otpType: OtpType(storageValue: totpOtpType),
                    counter: totpCounter,
                    iconName: totpIconName
                )
            )
            totpSecret = ""
            totpCounter = 0
            totpEntries = try entryRepository.listTotpEntries(projectID: project.id)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .totp,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importTotpURI(_ value: String) throws {
        try importTotpURI(value, source: .manualURI)
    }

    func importScannedTotpQRCode(_ value: String) throws {
        try importTotpURI(value, source: .scannedQRCode)
    }

    func importTotpURI(_ value: String, source: TotpImportSource) throws {
        recordUserActivity()

        do {
            let draft = try TotpURIParser.parse(value)
            guard let period = UInt32(exactly: draft.period) else {
                throw TotpError.invalidPeriod
            }
            guard let digits = UInt32(exactly: draft.digits) else {
                throw TotpError.invalidDigits
            }

            totpTitle = draft.title
            totpSecret = draft.secret
            totpIssuer = draft.issuer
            totpAccountName = draft.accountName
            totpPeriod = period
            totpDigits = digits
            totpAlgorithm = draft.algorithm.rawValue
            totpOtpType = draft.otpType.rawValue
            totpCounter = draft.counter
            totpIconName = ""
            totpImportURI = ""
            entryOperationState = .succeeded(String(localized: "已导入 \(draft.title)"))
        } catch {
            entryOperationState = .failed(readableTotpImportErrorMessage(for: error, source: source))
            throw error
        }
    }

    func readableTotpImportErrorMessage(for error: Error, source: TotpImportSource) -> String {
        guard let totpError = error as? TotpError else {
            return error.localizedDescription
        }

        switch (source, totpError) {
        case (.scannedQRCode, .invalidURI):
            return String(localized: "扫描到的二维码不是 TOTP 设置码。")
        case (.manualURI, .invalidURI):
            return String(localized: "请输入有效的 otpauth:// TOTP 设置 URI。")
        case (.scannedQRCode, .invalidSecret):
            return String(localized: "扫描到的二维码包含无效的 TOTP 密钥。")
        case (.manualURI, .invalidSecret):
            return String(localized: "TOTP 设置 URI 包含无效密钥。")
        case (.scannedQRCode, .invalidDigits):
            return String(localized: "扫描到的二维码使用了不支持的 TOTP 位数。")
        case (.manualURI, .invalidDigits):
            return String(localized: "TOTP 设置 URI 使用了不支持的位数。")
        case (.scannedQRCode, .invalidPeriod):
            return String(localized: "扫描到的二维码使用了不支持的 TOTP 周期。")
        case (.manualURI, .invalidPeriod):
            return String(localized: "TOTP 设置 URI 使用了不支持的周期。")
        case (.scannedQRCode, .invalidAlgorithm):
            return String(localized: "扫描到的二维码使用了不支持的 TOTP 算法。")
        case (.manualURI, .invalidAlgorithm):
            return String(localized: "TOTP 设置 URI 使用了不支持的算法。")
        case (.scannedQRCode, .missingCounter):
            return String(localized: "扫描到的二维码缺少 HOTP 计数器。")
        case (.manualURI, .missingCounter):
            return String(localized: "HOTP 设置 URI 缺少 counter 参数。")
        case (.scannedQRCode, .invalidCounter):
            return String(localized: "扫描到的二维码包含无效的 HOTP 计数器。")
        case (.manualURI, .invalidCounter):
            return String(localized: "HOTP 设置 URI 的 counter 参数无效。")
        case (.scannedQRCode, .uriTooLong):
            return String(localized: "扫描到的二维码内容过长。")
        case (.manualURI, .uriTooLong):
            return String(localized: "TOTP 设置 URI 过长。")
        }
    }

    func selectTotpEntryForEditing(_ entry: LocalTotpEntry) {
        recordUserActivity()
        editingTotpEntryID = entry.id
        editingTotpTitle = entry.title
        editingTotpSecret = entry.secret
        editingTotpIssuer = entry.issuer
        editingTotpAccountName = entry.accountName
        editingTotpPeriod = entry.period
        editingTotpDigits = entry.digits
        editingTotpAlgorithm = entry.algorithm
        editingTotpOtpType = OtpType(storageValue: entry.otpType).rawValue
        editingTotpCounter = entry.counter
        editingTotpIconName = entry.iconName
        editingTotpFavorite = entry.favorite
    }

    func updateSelectedTotpEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateTotpEntry(
                projectID: projectID,
                entryID: entryID,
                draft: try advancedTotpDraft(
                    title: editingTotpTitle,
                    secret: editingTotpSecret,
                    issuer: editingTotpIssuer,
                    accountName: editingTotpAccountName,
                    period: editingTotpPeriod,
                    digits: editingTotpDigits,
                    algorithm: editingTotpAlgorithm,
                    otpType: OtpType(storageValue: editingTotpOtpType),
                    counter: editingTotpCounter,
                    iconName: editingTotpIconName
                )
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            selectTotpEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .totp,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedTotpFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setTotpEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            selectTotpEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedTotpEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingTotpTitle
            try entryRepository.deleteTotpEntry(projectID: projectID, entryID: entryID)
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            clearEditingTotpEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .totp,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
            haptics.play(.error)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            haptics.play(.error)
            throw error
        }
    }

    func restoreTotpEntry(_ entry: LocalTotpEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreTotpEntry(
                projectID: projectID,
                entryID: entry.id
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .totp,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func totpCode(for entry: LocalTotpEntry, at date: Date = Date()) throws -> String {
        switch OtpType(storageValue: entry.otpType) {
        case .totp:
            return try TotpGenerator.generate(
                secret: entry.secret,
                algorithm: totpAlgorithm(from: entry.algorithm),
                digits: Int(entry.digits),
                period: Int(entry.period),
                timestamp: date.timeIntervalSince1970
            )
        case .hotp:
            return try HotpGenerator.generate(
                secret: entry.secret,
                algorithm: totpAlgorithm(from: entry.algorithm),
                digits: Int(entry.digits),
                counter: entry.counter
            )
        }
    }

    func totpTimeRemaining(for entry: LocalTotpEntry, at date: Date = Date()) -> Int {
        guard OtpType(storageValue: entry.otpType) == .totp else {
            return 0
        }
        let period = max(Int(entry.period), 1)
        let elapsed = Int(date.timeIntervalSince1970) % period
        return elapsed == 0 ? period : period - elapsed
    }

    func clearEditingTotpEntry() {
        editingTotpEntryID = nil
        editingTotpTitle = ""
        editingTotpSecret = ""
        editingTotpIssuer = ""
        editingTotpAccountName = ""
        editingTotpPeriod = 30
        editingTotpDigits = 6
        editingTotpAlgorithm = "SHA1"
        editingTotpFavorite = false
    }

    func totpAlgorithm(from value: String) -> TotpAlgorithm {
        TotpAlgorithm(rawValue: value.uppercased()) ?? .sha1
    }
}
