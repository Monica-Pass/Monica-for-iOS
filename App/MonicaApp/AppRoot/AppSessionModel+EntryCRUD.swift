import Foundation
import MonicaCore
import MonicaStorage

// slice C3: EntryCRUD 域（笔记 / 卡片 / 身份 / Passkey / SSH / API 令牌 / Wi-Fi / 条码 / 附件条目 CRUD），从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    func createNoteEntry(projectTitle: String) throws {
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
            let entry = try entryRepository.createNoteEntry(
                projectID: project.id,
                draft: LocalNoteEntryDraft(title: noteTitle, body: noteBody)
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: project.id)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .note,
                itemID: entry.id,
                itemTitle: entry.title
            )
            completeNoteDraftCommit(noteID: entry.id, body: entry.body)
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectNoteEntryForEditing(_ entry: LocalNoteEntry) {
        recordUserActivity()
        editingNoteEntryID = entry.id
        editingNoteTitle = entry.title
        editingNoteBody = entry.body
        editingNoteFavorite = entry.favorite
    }

    func updateSelectedNoteEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateNoteEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalNoteEntryDraft(title: editingNoteTitle, body: editingNoteBody)
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            selectNoteEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .note,
                itemID: entry.id,
                itemTitle: entry.title
            )
            completeNoteDraftCommit(noteID: entry.id, body: entry.body)
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedNoteFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setNoteEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            selectNoteEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedNoteEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingNoteTitle
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: entryID)
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            clearEditingNoteEntry()
            if let store = noteDraftStore {
                try? store.deleteDraft(draftID: AppNoteDraftPolicy.draftID(noteID: entryID))
            }
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .note,
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

    func restoreNoteEntry(_ entry: LocalNoteEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreNoteEntry(
                projectID: projectID,
                entryID: entry.id
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .note,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createCardEntry(projectTitle: String) throws {
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
            let entry = try entryRepository.createCardEntry(
                projectID: project.id,
                draft: LocalCardEntryDraft(
                    title: cardTitle,
                    cardholderName: cardholderName,
                    number: cardNumber,
                    expiryMonth: cardExpiryMonth,
                    expiryYear: cardExpiryYear,
                    cvv: cardCVV,
                    issuer: cardIssuer,
                    network: cardNetwork,
                    iban: cardIBAN,
                    swiftCode: cardSwiftCode,
                    billingAddress: cardBillingAddress,
                    cardArtwork: cardArtwork,
                    notes: cardNotes
                )
            )
            cardNumber = ""
            cardCVV = ""
            cardEntries = try entryRepository.listCardEntries(projectID: project.id)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .card,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            cardNumber = ""
            cardCVV = ""
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectCardEntryForEditing(_ entry: LocalCardEntry) {
        recordUserActivity()
        editingCardEntryID = entry.id
        editingCardTitle = entry.title
        editingCardholderName = entry.cardholderName
        editingCardNumber = entry.number
        editingCardExpiryMonth = entry.expiryMonth
        editingCardExpiryYear = entry.expiryYear
        editingCardCVV = entry.cvv
        editingCardIssuer = entry.issuer
        editingCardNetwork = entry.network
        editingCardIBAN = entry.iban
        editingCardSwiftCode = entry.swiftCode
        editingCardBillingAddress = entry.billingAddress
        editingCardArtwork = entry.cardArtwork
        editingCardNotes = entry.notes
        editingCardFavorite = entry.favorite
    }

    func updateSelectedCardEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateCardEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalCardEntryDraft(
                    title: editingCardTitle,
                    cardholderName: editingCardholderName,
                    number: editingCardNumber,
                    expiryMonth: editingCardExpiryMonth,
                    expiryYear: editingCardExpiryYear,
                    cvv: editingCardCVV,
                    issuer: editingCardIssuer,
                    network: editingCardNetwork,
                    iban: editingCardIBAN,
                    swiftCode: editingCardSwiftCode,
                    billingAddress: editingCardBillingAddress,
                    cardArtwork: editingCardArtwork,
                    notes: editingCardNotes
                )
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            selectCardEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .card,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedCardFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setCardEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            selectCardEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedCardEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingCardTitle
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: entryID)
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            clearEditingCardEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .card,
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

    func restoreCardEntry(_ entry: LocalCardEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreCardEntry(
                projectID: projectID,
                entryID: entry.id
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .card,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createIdentityEntry(projectTitle: String) throws {
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
            let entry = try entryRepository.createIdentityEntry(
                projectID: project.id,
                draft: LocalIdentityEntryDraft(
                    title: identityTitle,
                    documentType: identityDocumentType,
                    fullName: identityFullName,
                    documentNumber: identityDocumentNumber,
                    issuer: identityIssuer,
                    country: identityCountry,
                    issueDate: identityIssueDate,
                    expiryDate: identityExpiryDate,
                    notes: identityNotes
                )
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: project.id)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .identity,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectIdentityEntryForEditing(_ entry: LocalIdentityEntry) {
        recordUserActivity()
        editingIdentityEntryID = entry.id
        editingIdentityTitle = entry.title
        editingIdentityDocumentType = entry.documentType
        editingIdentityFullName = entry.fullName
        editingIdentityDocumentNumber = entry.documentNumber
        editingIdentityIssuer = entry.issuer
        editingIdentityCountry = entry.country
        editingIdentityIssueDate = entry.issueDate
        editingIdentityExpiryDate = entry.expiryDate
        editingIdentityNotes = entry.notes
        editingIdentityFavorite = entry.favorite
    }

    func updateSelectedIdentityEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateIdentityEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalIdentityEntryDraft(
                    title: editingIdentityTitle,
                    documentType: editingIdentityDocumentType,
                    fullName: editingIdentityFullName,
                    documentNumber: editingIdentityDocumentNumber,
                    issuer: editingIdentityIssuer,
                    country: editingIdentityCountry,
                    issueDate: editingIdentityIssueDate,
                    expiryDate: editingIdentityExpiryDate,
                    notes: editingIdentityNotes
                )
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            selectIdentityEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .identity,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedIdentityFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setIdentityEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            selectIdentityEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedIdentityEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingIdentityTitle
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: entryID)
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            clearEditingIdentityEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .identity,
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

    func restoreIdentityEntry(_ entry: LocalIdentityEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreIdentityEntry(
                projectID: projectID,
                entryID: entry.id
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .identity,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createPasskeyEntry(projectTitle: String) throws {
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
            let entry = try entryRepository.createPasskeyEntry(
                projectID: project.id,
                draft: LocalPasskeyEntryDraft(
                    title: passkeyTitle,
                    relyingPartyID: try normalizedPasskeyRelyingPartyID(passkeyRelyingPartyID),
                    username: passkeyUsername,
                    userHandle: passkeyUserHandle,
                    credentialID: passkeyCredentialID,
                    publicKeyCOSE: passkeyPublicKeyCOSE,
                    privateKeyReference: passkeyPrivateKeyReference,
                    notes: passkeyNotes
                )
            )
            passkeyPrivateKeyReference = ""
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: project.id)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectPasskeyEntryForEditing(_ entry: LocalPasskeyEntry) {
        recordUserActivity()
        editingPasskeyEntryID = entry.id
        editingPasskeyTitle = entry.title
        editingPasskeyRelyingPartyID = entry.relyingPartyID
        editingPasskeyUsername = entry.username
        editingPasskeyUserHandle = entry.userHandle
        editingPasskeyCredentialID = entry.credentialID
        editingPasskeyPublicKeyCOSE = entry.publicKeyCOSE
        editingPasskeyPrivateKeyReference = entry.privateKeyReference
        editingPasskeyNotes = entry.notes
        editingPasskeyFavorite = entry.favorite
    }

    func updateSelectedPasskeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updatePasskeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalPasskeyEntryDraft(
                    title: editingPasskeyTitle,
                    relyingPartyID: try normalizedPasskeyRelyingPartyID(editingPasskeyRelyingPartyID),
                    username: editingPasskeyUsername,
                    userHandle: editingPasskeyUserHandle,
                    credentialID: editingPasskeyCredentialID,
                    publicKeyCOSE: editingPasskeyPublicKeyCOSE,
                    privateKeyReference: editingPasskeyPrivateKeyReference,
                    notes: editingPasskeyNotes
                )
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            selectPasskeyEntryForEditing(entry)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedPasskeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setPasskeyEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            selectPasskeyEntryForEditing(updated)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedPasskeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingPasskeyTitle
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: entryID)
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            clearEditingPasskeyEntry()
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .passkey,
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

    func restorePasskeyEntry(_ entry: LocalPasskeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restorePasskeyEntry(
                projectID: projectID,
                entryID: entry.id
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .passkey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createSshKeyEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSshKeyEntry(
                projectID: project.id,
                draft: LocalSshKeyEntryDraft(
                    title: sshKeyTitle,
                    username: sshKeyUsername,
                    host: sshKeyHost,
                    publicKey: sshKeyPublicKey,
                    privateKeyReference: sshKeyPrivateKeyReference,
                    passphraseHint: sshKeyPassphraseHint,
                    notes: sshKeyNotes
                )
            )
            sshKeyPrivateKeyReference = ""
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: project.id)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectSshKeyEntryForEditing(_ entry: LocalSshKeyEntry) {
        recordUserActivity()
        editingSshKeyEntryID = entry.id
        editingSshKeyTitle = entry.title
        editingSshKeyUsername = entry.username
        editingSshKeyHost = entry.host
        editingSshKeyPublicKey = entry.publicKey
        editingSshKeyPrivateKeyReference = entry.privateKeyReference
        editingSshKeyPassphraseHint = entry.passphraseHint
        editingSshKeyNotes = entry.notes
        editingSshKeyFavorite = entry.favorite
    }

    func updateSelectedSshKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            // #154：算法、位数与指纹是生成器写入的只读元数据，编辑其它字段时原样保留，
            // 避免手工修改标题就把「Ed25519 / 256 位 / SHA256:…」抹掉。
            let currentEntry = sshKeyEntries.first(where: { $0.id == entryID })
            let entry = try entryRepository.updateSshKeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSshKeyEntryDraft(
                    title: editingSshKeyTitle,
                    username: editingSshKeyUsername,
                    host: editingSshKeyHost,
                    publicKey: editingSshKeyPublicKey,
                    privateKeyReference: editingSshKeyPrivateKeyReference,
                    passphraseHint: editingSshKeyPassphraseHint,
                    notes: editingSshKeyNotes,
                    algorithm: currentEntry?.algorithm ?? "",
                    keySize: currentEntry?.keySize ?? 0,
                    fingerprint: currentEntry?.fingerprint ?? ""
                )
            )
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            selectSshKeyEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSshKeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSshKeyEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            selectSshKeyEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSshKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSshKeyTitle
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: entryID)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            clearEditingSshKeyEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .sshKey,
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

    func restoreSshKeyEntry(_ entry: LocalSshKeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSshKeyEntry(projectID: projectID, entryID: entry.id)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .sshKey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createApiTokenEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createApiTokenEntry(
                projectID: project.id,
                draft: LocalApiTokenEntryDraft(
                    title: apiTokenTitle,
                    issuer: apiTokenIssuer,
                    accountName: apiTokenAccountName,
                    token: apiTokenToken,
                    scopes: apiTokenScopes,
                    expiresAt: apiTokenExpiresAt,
                    notes: apiTokenNotes
                )
            )
            apiTokenToken = ""
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: project.id)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .apiToken,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectApiTokenEntryForEditing(_ entry: LocalApiTokenEntry) {
        recordUserActivity()
        editingApiTokenEntryID = entry.id
        editingApiTokenTitle = entry.title
        editingApiTokenIssuer = entry.issuer
        editingApiTokenAccountName = entry.accountName
        editingApiTokenToken = entry.token
        editingApiTokenScopes = entry.scopes
        editingApiTokenExpiresAt = entry.expiresAt
        editingApiTokenNotes = entry.notes
        editingApiTokenFavorite = entry.favorite
    }

    func updateSelectedApiTokenEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateApiTokenEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalApiTokenEntryDraft(
                    title: editingApiTokenTitle,
                    issuer: editingApiTokenIssuer,
                    accountName: editingApiTokenAccountName,
                    token: editingApiTokenToken,
                    scopes: editingApiTokenScopes,
                    expiresAt: editingApiTokenExpiresAt,
                    notes: editingApiTokenNotes
                )
            )
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            selectApiTokenEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .apiToken,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedApiTokenFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setApiTokenEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            selectApiTokenEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedApiTokenEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingApiTokenTitle
            try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: entryID)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            clearEditingApiTokenEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .apiToken,
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

    func restoreApiTokenEntry(_ entry: LocalApiTokenEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreApiTokenEntry(projectID: projectID, entryID: entry.id)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .apiToken,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createWifiEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createWifiEntry(
                projectID: project.id,
                draft: LocalWifiEntryDraft(
                    title: wifiTitle,
                    ssid: wifiSSID,
                    securityType: wifiSecurityType,
                    password: wifiPassword,
                    hidden: wifiHidden,
                    notes: wifiNotes
                )
            )
            wifiPassword = ""
            wifiEntries = try entryRepository.listWifiEntries(projectID: project.id)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .wifi,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectWifiEntryForEditing(_ entry: LocalWifiEntry) {
        recordUserActivity()
        editingWifiEntryID = entry.id
        editingWifiTitle = entry.title
        editingWifiSSID = entry.ssid
        editingWifiSecurityType = entry.securityType
        editingWifiPassword = entry.password
        editingWifiHidden = entry.hidden
        editingWifiNotes = entry.notes
        editingWifiFavorite = entry.favorite
    }

    func updateSelectedWifiEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateWifiEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalWifiEntryDraft(
                    title: editingWifiTitle,
                    ssid: editingWifiSSID,
                    securityType: editingWifiSecurityType,
                    password: editingWifiPassword,
                    hidden: editingWifiHidden,
                    notes: editingWifiNotes
                )
            )
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            selectWifiEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .wifi,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedWifiFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setWifiEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            selectWifiEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedWifiEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingWifiTitle
            try entryRepository.deleteWifiEntry(projectID: projectID, entryID: entryID)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            clearEditingWifiEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .wifi,
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

    func restoreWifiEntry(_ entry: LocalWifiEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreWifiEntry(projectID: projectID, entryID: entry.id)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .wifi,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createBarcodeEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createBarcodeEntry(
                projectID: project.id,
                draft: LocalBarcodeEntryDraft(
                    title: barcodeTitle,
                    symbology: barcodeSymbology,
                    payload: barcodePayload,
                    label: barcodeLabel,
                    notes: barcodeNotes
                )
            )
            barcodePayload = ""
            barcodeEntries = try entryRepository.listBarcodeEntries(projectID: project.id)
            deletedBarcodeEntries = try entryRepository.listDeletedBarcodeEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .barcode,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectBarcodeEntryForEditing(_ entry: LocalBarcodeEntry) {
        recordUserActivity()
        editingBarcodeEntryID = entry.id
        editingBarcodeTitle = entry.title
        editingBarcodeSymbology = entry.symbology
        editingBarcodePayload = entry.payload
        editingBarcodeLabel = entry.label
        editingBarcodeNotes = entry.notes
        editingBarcodeFavorite = entry.favorite
    }

    func updateSelectedBarcodeEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingBarcodeEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateBarcodeEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalBarcodeEntryDraft(
                    title: editingBarcodeTitle,
                    symbology: editingBarcodeSymbology,
                    payload: editingBarcodePayload,
                    label: editingBarcodeLabel,
                    notes: editingBarcodeNotes
                )
            )
            barcodeEntries = try entryRepository.listBarcodeEntries(projectID: projectID)
            deletedBarcodeEntries = try entryRepository.listDeletedBarcodeEntries(projectID: projectID)
            selectBarcodeEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .barcode,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedBarcodeFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingBarcodeEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setBarcodeEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            barcodeEntries = try entryRepository.listBarcodeEntries(projectID: projectID)
            selectBarcodeEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedBarcodeEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingBarcodeEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingBarcodeTitle
            try entryRepository.deleteBarcodeEntry(projectID: projectID, entryID: entryID)
            barcodeEntries = try entryRepository.listBarcodeEntries(projectID: projectID)
            deletedBarcodeEntries = try entryRepository.listDeletedBarcodeEntries(projectID: projectID)
            clearEditingBarcodeEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .barcode,
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

    func restoreBarcodeEntry(_ entry: LocalBarcodeEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreBarcodeEntry(projectID: projectID, entryID: entry.id)
            barcodeEntries = try entryRepository.listBarcodeEntries(projectID: projectID)
            deletedBarcodeEntries = try entryRepository.listDeletedBarcodeEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .barcode,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteAttachmentEntry(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: entry.id)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: entry.id,
                itemTitle: entry.fileName
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(entry.fileName)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreAttachmentEntry(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreAttachmentMetadata(projectID: projectID, attachmentID: entry.id)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .attachmentRef,
                itemID: restored.id,
                itemTitle: restored.fileName
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.fileName)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }
}
