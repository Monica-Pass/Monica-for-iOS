import Foundation
import MonicaStorage
import SwiftUI

// 账单地址与支付账户都属于卡包条目：字段里带有收件人、账户号、IBAN 等个人信息，
// 因此全部随条目走 MDBX 加密 payload，不写入 UserDefaults、日志或明文索引。
// 关联关系只用稳定 entryID（卡片的 id、地址的 id），展示名改了也不会断链。

// MARK: - 表单状态

struct BillingAddressFormState: Equatable {
    var title = ""
    var fullName = ""
    var streetAddress = ""
    var apartment = ""
    var city = ""
    var stateProvince = ""
    var postalCode = ""
    var country = ""
    var phone = ""
    var notes = ""
    var linkedCardIDs: [String] = []

    init() {}

    init(entry: LocalBillingAddressEntry) {
        title = entry.title
        fullName = entry.fullName
        streetAddress = entry.streetAddress
        apartment = entry.apartment
        city = entry.city
        stateProvince = entry.stateProvince
        postalCode = entry.postalCode
        country = entry.country
        phone = entry.phone
        notes = entry.notes
        linkedCardIDs = entry.linkedCardIDs
    }

    var draft: LocalBillingAddressEntryDraft {
        LocalBillingAddressEntryDraft(
            title: title,
            fullName: fullName,
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country,
            phone: phone,
            notes: notes,
            linkedCardIDs: linkedCardIDs
        )
    }

    var previewAddress: String {
        BillingAddressLines.singleLine(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        )
    }
}

struct PaymentAccountFormState: Equatable {
    var title = ""
    var kind: LocalPaymentAccountKind = .bankAccount
    var provider = ""
    var accountName = ""
    var accountHolderName = ""
    var iban = ""
    var swiftBIC = ""
    var routingNumber = ""
    var accountNumber = ""
    var currency = ""
    var notes = ""
    var linkedCardID = ""
    var billingAddressID = ""

    init() {}

    init(entry: LocalPaymentAccountEntry) {
        title = entry.title
        kind = entry.kind
        provider = entry.provider
        accountName = entry.accountName
        accountHolderName = entry.accountHolderName
        iban = entry.iban
        swiftBIC = entry.swiftBIC
        routingNumber = entry.routingNumber
        accountNumber = entry.accountNumber
        currency = entry.currency
        notes = entry.notes
        linkedCardID = entry.linkedCardID ?? ""
        billingAddressID = entry.billingAddressID ?? ""
    }

    var draft: LocalPaymentAccountEntryDraft {
        LocalPaymentAccountEntryDraft(
            title: title,
            kind: kind,
            provider: provider,
            accountName: accountName,
            accountHolderName: accountHolderName,
            iban: iban,
            swiftBIC: swiftBIC,
            routingNumber: routingNumber,
            accountNumber: accountNumber,
            currency: currency,
            notes: notes,
            linkedCardID: linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines),
            billingAddressID: billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var maskedAccountNumber: String {
        BillingFieldValidator.maskedAccountNumber(accountNumber.isEmpty ? iban : accountNumber)
    }
}

// MARK: - 会话逻辑

extension AppSessionModel {
    // MARK: 列表

    var filteredBillingAddressEntries: [LocalBillingAddressEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = billingAddressSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return billingAddressEntries.enumerated()
            .filter { _, entry in
                guard !showFavoriteBillingAddressEntriesOnly || entry.favorite else {
                    return false
                }
                guard !query.isEmpty else {
                    return true
                }
                return entry.searchableText.localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                if lhs.element.favorite != rhs.element.favorite {
                    return lhs.element.favorite
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var filteredPaymentAccountEntries: [LocalPaymentAccountEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = paymentAccountSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return paymentAccountEntries.enumerated()
            .filter { _, entry in
                guard !showFavoritePaymentAccountEntriesOnly || entry.favorite else {
                    return false
                }
                guard !query.isEmpty else {
                    return true
                }
                return entry.searchableText.localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                if lhs.element.favorite != rhs.element.favorite {
                    return lhs.element.favorite
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 账单地址可以挂在任意多张银行卡上；卡片条目本身没有扩展列，因此关系存地址一侧。
    var billingLinkableCardEntries: [LocalCardEntry] {
        cardEntries
    }

    var billingLinkableAddressEntries: [LocalBillingAddressEntry] {
        billingAddressEntries
    }

    // MARK: 温和校验提示

    var billingAddressCreateWarnings: [String] {
        billingAddressWarnings(for: billingAddressForm)
    }

    var billingAddressEditWarnings: [String] {
        billingAddressWarnings(for: editingBillingAddressForm)
    }

    var paymentAccountCreateWarnings: [String] {
        paymentAccountWarnings(for: paymentAccountForm)
    }

    var paymentAccountEditWarnings: [String] {
        paymentAccountWarnings(for: editingPaymentAccountForm)
    }

    func billingAddressWarnings(for form: BillingAddressFormState) -> [String] {
        var warnings: [String] = []
        if let issue = BillingFieldValidator.postalCodeIssue(form.postalCode) {
            warnings.append(billingFieldWarningTitle(for: issue, field: String(localized: "邮编")))
        }
        return warnings
    }

    func paymentAccountWarnings(for form: PaymentAccountFormState) -> [String] {
        var warnings: [String] = []
        if let issue = BillingFieldValidator.ibanIssue(form.iban) {
            warnings.append(billingFieldWarningTitle(for: issue, field: "IBAN"))
        }
        if let issue = BillingFieldValidator.swiftBICIssue(form.swiftBIC) {
            warnings.append(billingFieldWarningTitle(for: issue, field: "SWIFT/BIC"))
        }
        if let issue = BillingFieldValidator.routingNumberIssue(form.routingNumber) {
            warnings.append(billingFieldWarningTitle(for: issue, field: String(localized: "路由号")))
        }
        if let issue = BillingFieldValidator.currencyIssue(form.currency) {
            warnings.append(billingFieldWarningTitle(for: issue, field: String(localized: "币种")))
        }
        return warnings
    }

    private func billingFieldWarningTitle(for issue: BillingFieldValidationIssue, field: String) -> String {
        let detail: String
        switch issue {
        case .ibanCharacters:
            detail = String(localized: "只包含字母和数字")
        case .ibanLength:
            detail = String(localized: "长度通常在 15–34 位之间")
        case .ibanChecksum:
            detail = String(localized: "校验位对不上，请再确认一遍")
        case .swiftCharacters:
            detail = String(localized: "只包含字母和数字")
        case .swiftLength:
            detail = String(localized: "通常是 8 位或 11 位")
        case .routingNumberFormat:
            detail = String(localized: "只包含字母、数字、空格或连字符，且不超过 34 位")
        case .postalCodeFormat:
            detail = String(localized: "只包含字母、数字、空格或连字符，且不超过 16 位")
        case .currencyFormat:
            detail = String(localized: "通常是 3 位字母，例如 CNY、USD")
        }
        return String(localized: "\(field)格式可能不正确：\(detail)")
    }

    // MARK: 账单地址 CRUD

    func createBillingAddressEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createBillingAddressEntry(
                projectID: project.id,
                draft: billingAddressForm.draft
            )
            billingAddressForm = BillingAddressFormState()
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .billingAddress,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectBillingAddressEntryForEditing(_ entry: LocalBillingAddressEntry) {
        recordUserActivity()
        editingBillingAddressEntryID = entry.id
        editingBillingAddressForm = BillingAddressFormState(entry: entry)
        editingBillingAddressFavorite = entry.favorite
    }

    func updateSelectedBillingAddressEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject,
                  let entryID = editingBillingAddressEntryID else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let entry = try entryRepository.updateBillingAddressEntry(
                projectID: project.id,
                entryID: entryID,
                draft: editingBillingAddressForm.draft
            )
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            editingBillingAddressForm = BillingAddressFormState(entry: entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .billingAddress,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedBillingAddressFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject,
                  let entryID = editingBillingAddressEntryID else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let entry = try entryRepository.setBillingAddressEntryFavorite(
                projectID: project.id,
                entryID: entryID,
                favorite: favorite
            )
            editingBillingAddressFavorite = entry.favorite
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedBillingAddressEntry() throws {
        recordUserActivity()
        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject,
                  let entryID = editingBillingAddressEntryID else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let title = billingAddressEntries.first { $0.id == entryID }?.title ?? ""
            try entryRepository.deleteBillingAddressEntry(projectID: project.id, entryID: entryID)
            clearEditingBillingAddressEntry()
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .billingAddress,
                itemID: entryID,
                itemTitle: title
            )
            entryOperationState = .succeeded(title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreBillingAddressEntry(_ entry: LocalBillingAddressEntry) throws {
        recordUserActivity()
        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let restored = try entryRepository.restoreBillingAddressEntry(projectID: project.id, entryID: entry.id)
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .billingAddress,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(restored.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingBillingAddressEntry() {
        editingBillingAddressEntryID = nil
        editingBillingAddressForm = BillingAddressFormState()
        editingBillingAddressFavorite = false
    }

    func presentEditEditor(for entry: LocalBillingAddressEntry) {
        selectBillingAddressEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .billingAddress, entryID: entry.id))
    }

    // MARK: 支付账户 CRUD

    func createPaymentAccountEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createPaymentAccountEntry(
                projectID: project.id,
                draft: paymentAccountForm.draft
            )
            paymentAccountForm = PaymentAccountFormState()
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .paymentAccount,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectPaymentAccountEntryForEditing(_ entry: LocalPaymentAccountEntry) {
        recordUserActivity()
        editingPaymentAccountEntryID = entry.id
        editingPaymentAccountForm = PaymentAccountFormState(entry: entry)
        editingPaymentAccountFavorite = entry.favorite
    }

    func updateSelectedPaymentAccountEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject,
                  let entryID = editingPaymentAccountEntryID else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let entry = try entryRepository.updatePaymentAccountEntry(
                projectID: project.id,
                entryID: entryID,
                draft: editingPaymentAccountForm.draft
            )
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            editingPaymentAccountForm = PaymentAccountFormState(entry: entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .paymentAccount,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedPaymentAccountFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject,
                  let entryID = editingPaymentAccountEntryID else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let entry = try entryRepository.setPaymentAccountEntryFavorite(
                projectID: project.id,
                entryID: entryID,
                favorite: favorite
            )
            editingPaymentAccountFavorite = entry.favorite
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedPaymentAccountEntry() throws {
        recordUserActivity()
        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject,
                  let entryID = editingPaymentAccountEntryID else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let title = paymentAccountEntries.first { $0.id == entryID }?.title ?? ""
            try entryRepository.deletePaymentAccountEntry(projectID: project.id, entryID: entryID)
            clearEditingPaymentAccountEntry()
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .paymentAccount,
                itemID: entryID,
                itemTitle: title
            )
            entryOperationState = .succeeded(title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restorePaymentAccountEntry(_ entry: LocalPaymentAccountEntry) throws {
        recordUserActivity()
        do {
            guard let entryRepository = activeEntryRepository,
                  let project = activeProject else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let restored = try entryRepository.restorePaymentAccountEntry(projectID: project.id, entryID: entry.id)
            try refreshBillingEntryLists(projectID: project.id, entryRepository: entryRepository)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .paymentAccount,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(restored.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingPaymentAccountEntry() {
        editingPaymentAccountEntryID = nil
        editingPaymentAccountForm = PaymentAccountFormState()
        editingPaymentAccountFavorite = false
    }

    func presentEditEditor(for entry: LocalPaymentAccountEntry) {
        selectPaymentAccountEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .paymentAccount, entryID: entry.id))
    }

    func refreshBillingEntryLists(projectID: String, entryRepository: LocalVaultEntryRepository) throws {
        billingAddressEntries = try entryRepository.listBillingAddressEntries(projectID: projectID)
        deletedBillingAddressEntries = try entryRepository.listDeletedBillingAddressEntries(projectID: projectID)
        paymentAccountEntries = try entryRepository.listPaymentAccountEntries(projectID: projectID)
        deletedPaymentAccountEntries = try entryRepository.listDeletedPaymentAccountEntries(projectID: projectID)
    }

    // MARK: 详情页

    func billingAddressDetailRows(for entry: LocalBillingAddressEntry) -> [AppExtensionCapabilityRow] {
        var rows: [AppExtensionCapabilityRow] = [
            billingDetailRow(id: "title", title: String(localized: "标题"), value: entry.title)
        ]
        if !entry.fullName.isEmpty {
            rows.append(billingDetailRow(id: "fullName", title: String(localized: "收件人"), value: entry.fullName))
        }
        if !entry.addressLines.isEmpty {
            rows.append(billingDetailRow(
                id: "address",
                title: String(localized: "地址"),
                value: entry.formattedAddress
            ))
        }
        if !entry.phone.isEmpty {
            rows.append(billingDetailRow(
                id: "phone",
                title: String(localized: "电话"),
                value: sensitivePreviewValue(entry.phone, category: .otherSecret, entryID: entry.id)
            ))
        }
        rows.append(billingDetailRow(
            id: "linkedCards",
            title: String(localized: "关联银行卡"),
            value: billingLinkedCardsDescription(for: entry)
        ))
        if !entry.notes.isEmpty {
            rows.append(billingDetailRow(
                id: "notes",
                title: String(localized: "备注"),
                value: sensitivePreviewValue(entry.notes, category: .noteBody, entryID: entry.id)
            ))
        }
        return rows
    }

    func billingAddressDetailSecrets(for entry: LocalBillingAddressEntry) -> [String: String] {
        var secrets: [String: String] = [:]
        if !entry.fullName.isEmpty {
            secrets["fullName"] = entry.fullName
        }
        if !entry.phone.isEmpty {
            secrets["phone"] = entry.phone
        }
        if !entry.notes.isEmpty {
            secrets["notes"] = entry.notes
        }
        return secrets
    }

    func paymentAccountDetailRows(for entry: LocalPaymentAccountEntry) -> [AppExtensionCapabilityRow] {
        var rows: [AppExtensionCapabilityRow] = [
            billingDetailRow(id: "title", title: String(localized: "标题"), value: entry.title),
            billingDetailRow(id: "kind", title: String(localized: "账户类型"), value: entry.kind.displayName)
        ]
        if !entry.provider.isEmpty {
            rows.append(billingDetailRow(id: "provider", title: String(localized: "机构/钱包"), value: entry.provider))
        }
        if !entry.accountName.isEmpty {
            rows.append(billingDetailRow(
                id: "accountName",
                title: String(localized: "账户名"),
                value: sensitivePreviewValue(entry.accountName, category: .otherSecret, entryID: entry.id)
            ))
        }
        if !entry.accountHolderName.isEmpty {
            rows.append(billingDetailRow(id: "holder", title: String(localized: "持有人"), value: entry.accountHolderName))
        }
        if !entry.iban.isEmpty {
            rows.append(billingDetailRow(
                id: "iban",
                title: "IBAN",
                value: sensitivePreviewValue(entry.iban, category: .otherSecret, entryID: entry.id)
            ))
        }
        if !entry.swiftBIC.isEmpty {
            rows.append(billingDetailRow(id: "swift", title: "SWIFT/BIC", value: entry.swiftBIC))
        }
        if !entry.routingNumber.isEmpty {
            rows.append(billingDetailRow(
                id: "routing",
                title: String(localized: "路由号"),
                value: sensitivePreviewValue(entry.routingNumber, category: .otherSecret, entryID: entry.id)
            ))
        }
        if !entry.accountNumber.isEmpty {
            rows.append(billingDetailRow(
                id: "accountNumber",
                title: String(localized: "账号"),
                value: sensitivePreviewValue(entry.accountNumber, category: .otherSecret, entryID: entry.id)
            ))
        }
        if !entry.currency.isEmpty {
            rows.append(billingDetailRow(id: "currency", title: String(localized: "币种"), value: entry.currency))
        }
        rows.append(billingDetailRow(
            id: "billingAddress",
            title: String(localized: "账单地址"),
            value: paymentBillingAddressDescription(for: entry)
        ))
        rows.append(billingDetailRow(
            id: "linkedCard",
            title: String(localized: "关联银行卡"),
            value: paymentLinkedCardDescription(for: entry)
        ))
        if !entry.notes.isEmpty {
            rows.append(billingDetailRow(
                id: "notes",
                title: String(localized: "备注"),
                value: sensitivePreviewValue(entry.notes, category: .noteBody, entryID: entry.id)
            ))
        }
        return rows
    }

    func paymentAccountDetailSecrets(for entry: LocalPaymentAccountEntry) -> [String: String] {
        var secrets: [String: String] = [:]
        if !entry.accountName.isEmpty {
            secrets["accountName"] = entry.accountName
        }
        if !entry.iban.isEmpty {
            secrets["iban"] = entry.iban
        }
        if !entry.routingNumber.isEmpty {
            secrets["routing"] = entry.routingNumber
        }
        if !entry.accountNumber.isEmpty {
            secrets["accountNumber"] = entry.accountNumber
        }
        if !entry.notes.isEmpty {
            secrets["notes"] = entry.notes
        }
        return secrets
    }

    func billingLinkedCardsDescription(for entry: LocalBillingAddressEntry) -> String {
        guard !entry.linkedCardIDs.isEmpty else {
            return String(localized: "未关联")
        }
        let linked = entry.linkedCards(in: cardEntries)
        let missingCount = entry.missingLinkedCardIDs(in: cardEntries).count
        if linked.isEmpty {
            return String(localized: "关联的银行卡已删除")
        }
        let titles = linked.map(\.title).joined(separator: "、")
        if missingCount > 0 {
            return String(localized: "\(titles)（另有 \(missingCount) 张银行卡已删除）")
        }
        return titles
    }

    func paymentBillingAddressDescription(for entry: LocalPaymentAccountEntry) -> String {
        switch entry.billingAddressReferenceStatus(in: billingAddressEntries) {
        case .none:
            return String(localized: "未关联")
        case .missing:
            return String(localized: "关联的账单地址已删除")
        case .linked:
            return entry.billingAddress(in: billingAddressEntries)?.title ?? String(localized: "关联的账单地址已删除")
        }
    }

    func paymentLinkedCardDescription(for entry: LocalPaymentAccountEntry) -> String {
        switch entry.linkedCardReferenceStatus(in: cardEntries) {
        case .none:
            return String(localized: "未关联")
        case .missing:
            return String(localized: "关联的银行卡已删除")
        case .linked:
            return entry.linkedCard(in: cardEntries)?.title ?? String(localized: "关联的银行卡已删除")
        }
    }

    /// 卡片详情里反查这张卡被哪些账单地址引用，方便确认关联是否一致。
    func billingAddresses(linkedTo card: LocalCardEntry) -> [LocalBillingAddressEntry] {
        billingAddressEntries.filter { $0.linkedCardIDs.contains(card.id) }
    }

    private func billingDetailRow(id: String, title: String, value: String) -> AppExtensionCapabilityRow {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppExtensionCapabilityRow(
            id: id,
            title: title,
            value: trimmed.isEmpty ? String(localized: "空") : trimmed,
            detail: "",
            systemImage: ""
        )
    }
}

// MARK: - Editor fields

struct BillingAddressEditorFields: View {
    @Bindable var session: AppSessionModel
    let isAdding: Bool

    private var form: Binding<BillingAddressFormState> {
        isAdding ? $session.billingAddressForm : $session.editingBillingAddressForm
    }

    private var warnings: [String] {
        isAdding ? session.billingAddressCreateWarnings : session.billingAddressEditWarnings
    }

    var body: some View {
        VStack(spacing: 18) {
            BillingFormField(icon: "folder.fill", title: String(localized: "标题 *"), text: form.title)
            BillingFormField(icon: "person.fill", title: String(localized: "收件人"), text: form.fullName)
            BillingFormField(icon: "house.fill", title: String(localized: "地址行 1"), text: form.streetAddress)
            BillingFormField(icon: "building.2.fill", title: String(localized: "地址行 2 / 房间号"), text: form.apartment)
            BillingFormField(icon: "mappin.and.ellipse", title: String(localized: "城市"), text: form.city)
            BillingFormField(icon: "map.fill", title: String(localized: "省 / 州"), text: form.stateProvince)
            BillingFormField(icon: "number", title: String(localized: "邮编"), text: form.postalCode)
                .textInputAutocapitalization(.characters)
            BillingFormField(icon: "globe", title: String(localized: "国家 / 地区"), text: form.country)
            BillingFormField(icon: "phone.fill", title: String(localized: "电话"), text: form.phone)
                .keyboardType(.phonePad)
            BillingCardReferenceEditor(
                selection: form.linkedCardIDs,
                entries: session.billingLinkableCardEntries
            )
            BillingFormField(icon: "note.text", title: String(localized: "备注"), text: form.notes)
            BillingValidationWarnings(warnings: warnings)
            Text("地址与税号只做格式提示，不校验真实有效性；各国地址格式差异不会被拒绝保存。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PaymentAccountEditorFields: View {
    @Bindable var session: AppSessionModel
    let isAdding: Bool

    private var form: Binding<PaymentAccountFormState> {
        isAdding ? $session.paymentAccountForm : $session.editingPaymentAccountForm
    }

    private var warnings: [String] {
        isAdding ? session.paymentAccountCreateWarnings : session.paymentAccountEditWarnings
    }

    var body: some View {
        VStack(spacing: 18) {
            BillingFormField(icon: "folder.fill", title: String(localized: "标题 *"), text: form.title)
            BillingPaymentKindPicker(selection: form.kind)
            BillingFormField(icon: "building.columns.fill", title: String(localized: "机构 / 钱包"), text: form.provider)
            BillingFormField(icon: "person.text.rectangle.fill", title: String(localized: "账户名"), text: form.accountName)
            BillingFormField(icon: "person.fill", title: String(localized: "持有人"), text: form.accountHolderName)
            BillingSecureFormField(icon: "number", title: "IBAN", text: form.iban)
            BillingSecureFormField(icon: "arrow.left.arrow.right", title: "SWIFT/BIC", text: form.swiftBIC)
            BillingSecureFormField(icon: "point.3.connected.trianglepath.dotted", title: String(localized: "路由号 / 清算号"), text: form.routingNumber)
            BillingSecureFormField(icon: "creditcard.fill", title: String(localized: "账号"), text: form.accountNumber)
            BillingFormField(icon: "coloncurrencysign.circle.fill", title: String(localized: "币种（3 位字母）"), text: form.currency)
            BillingCardPicker(selection: form.linkedCardID, entries: session.billingLinkableCardEntries)
            BillingAddressPicker(selection: form.billingAddressID, entries: session.billingLinkableAddressEntries)
            BillingFormField(icon: "note.text", title: String(localized: "备注"), text: form.notes)
            BillingValidationWarnings(warnings: warnings)
            Text("IBAN、路由号与账号只做格式提示，不按任何单一国家的规则拒绝保存；账户内容随条目加密存储，详情页默认掩码显示。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BillingValidationWarnings: View {
    let warnings: [String]

    var body: some View {
        if warnings.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Text("以上只是格式提示，不影响保存。")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BillingPaymentKindPicker: View {
    @Binding var selection: LocalPaymentAccountKind

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "wallet.pass.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            Picker(String(localized: "账户类型"), selection: $selection) {
                ForEach(LocalPaymentAccountKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

/// 一张卡可以被多个地址挂在身上，所以这里用可多选的勾选列表。
struct BillingCardReferenceEditor: View {
    @Binding var selection: [String]
    let entries: [LocalCardEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "关联银行卡"), systemImage: "creditcard.and.123")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            if entries.isEmpty {
                Text("还没有银行卡，可先在卡包里添加。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ForEach(entries) { entry in
                    Button {
                        toggle(entry.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(entry.id) ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AndroidParityPalette.textPrimary)
                                Text(entry.issuer.isEmpty ? entry.network : entry.issuer)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AndroidParityPalette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 52)
                        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(localized: "关联银行卡 \(entry.title)")))
                    .accessibilityValue(Text(selection.contains(entry.id) ? String(localized: "已选中") : String(localized: "未选中")))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String) {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            selection.append(id)
        }
    }
}

struct BillingCardPicker: View {
    @Binding var selection: String
    let entries: [LocalCardEntry]

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "creditcard.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            Picker(String(localized: "关联银行卡"), selection: $selection) {
                Text(String(localized: "不关联")).tag("")
                ForEach(entries) { entry in
                    Text(entry.title).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

struct BillingAddressPicker: View {
    @Binding var selection: String
    let entries: [LocalBillingAddressEntry]

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "house.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            Picker(String(localized: "账单地址"), selection: $selection) {
                Text(String(localized: "不关联")).tag("")
                ForEach(entries) { entry in
                    Text(entry.title).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

struct BillingFormField: View {
    let icon: String
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            TextField(title, text: $text)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

struct BillingSecureFormField: View {
    let icon: String
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            SecureField(title, text: $text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

// MARK: - List and detail accessories

struct AndroidBillingAddressListCard: View {
    let entry: LocalBillingAddressEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "house.fill",
            title: entry.title,
            primary: entry.fullName,
            secondary: entry.addressSummary,
            favorite: entry.favorite
        )
    }
}

struct AndroidPaymentAccountListCard: View {
    let entry: LocalPaymentAccountEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "wallet.pass.fill",
            title: entry.title,
            primary: entry.provider.isEmpty ? entry.kind.displayName : entry.provider,
            secondary: entry.kind == .bankAccount ? entry.accountName : entry.kind.displayName,
            favorite: entry.favorite
        )
    }
}
