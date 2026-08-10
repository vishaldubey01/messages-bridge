import AppKit
import Contacts
import CoreServices
import Darwin
import Foundation
import ScriptingBridge
import SQLite3

private let maxRequestBytes = 64 * 1024
private let maxResponseBytes = 32 * 1024 * 1024
private let maxAttachmentBytes = 20 * 1024 * 1024
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct BridgeRequest: Decodable {
    let operation: String
    let name: String?
    let sinceDays: Int?
    let limit: Int?
    let attachmentID: String?
    let groupID: String?
    let text: String?
}

private struct ContactIdentity {
    let displayName: String
    let phones: [String]
    let emails: [String]
}

private struct MessageRecord {
    let messageID: Int64
    let timestamp: String
    let direction: String
    let sender: String
    let text: String
    let service: String
    let attachments: [AttachmentMetadata]
}

private struct AttachmentMetadata {
    let id: String
    let name: String
    let mimeType: String
    let byteCount: Int64
    let available: Bool

    var payload: [String: Any] {
        [
            "attachmentID": id,
            "name": name,
            "mimeType": mimeType,
            "byteCount": byteCount,
            "available": available,
        ]
    }
}

private struct AttachmentFileRecord {
    let storedPath: String
    let transferName: String
    let mimeType: String
    let byteCount: Int64
}

private struct GroupConversation {
    let chatID: Int64
    let id: String
    let storedName: String
    let lastActivity: Int64
}

private struct SendTarget {
    let chatID: String
    let displayName: String
    let conversationType: String
}

private enum SendingPolicy: Int {
    case off = 0
    case confirmEach = 1
    case automatic = 2

    var label: String {
        switch self {
        case .off: return "off"
        case .confirmEach: return "confirm-each"
        case .automatic: return "automatic"
        }
    }
}

private enum BridgeFailure: Error {
    case message(String, code: String)

    var payload: [String: Any] {
        switch self {
        case let .message(message, code):
            return ["ok": false, "error": code, "message": message]
        }
    }
}

private final class AutomationErrorCapture: NSObject, SBApplicationDelegate {
    var lastError: Error?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        lastError = error
        return nil
    }
}

private final class MessagesSender {
    private let messagesBundleID = "com.apple.MobileSMS"

    func authorizationStatus(prompt: Bool) -> OSStatus {
        if prompt {
            let activate = { NSApp.activate(ignoringOtherApps: true) }
            if Thread.isMainThread {
                activate()
            } else {
                DispatchQueue.main.sync(execute: activate)
            }
        }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: messagesBundleID)
        guard let address = descriptor.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, prompt)
    }

    func authorizationLabel() -> String {
        let status = authorizationStatus(prompt: false)
        if status == noErr { return "authorized" }
        if status == errAEEventWouldRequireUserConsent { return "notDetermined" }
        if status == errAEEventNotPermitted { return "denied" }
        return "unknown"
    }

    func sendText(_ text: String, to target: SendTarget) throws {
        let authorization = authorizationStatus(prompt: true)
        guard authorization == noErr else {
            let message = authorization == errAEEventNotPermitted
                ? "Automation access to Messages was denied. Enable Messages Bridge in System Settings > Privacy & Security > Automation."
                : "Messages Bridge could not obtain Automation access to Messages (error \(authorization))."
            throw BridgeFailure.message(message, code: "automation_access_denied")
        }
        guard let application = SBApplication(bundleIdentifier: messagesBundleID) else {
            throw BridgeFailure.message("The Messages app is unavailable.", code: "messages_unavailable")
        }
        let capture = AutomationErrorCapture()
        application.delegate = capture
        application.sendMode = AESendMode(kAEWaitReply)
        application.timeout = 60 * 60
        guard let chats = application.value(forKey: "chats") as? SBElementArray,
              let chat = chats.object(withID: target.chatID) as? SBObject else {
            throw BridgeFailure.message(
                "The selected Messages conversation is no longer available.",
                code: "send_target_unavailable"
            )
        }
        let selector = NSSelectorFromString("send:to:")
        guard application.responds(to: selector) else {
            throw BridgeFailure.message("This version of Messages does not expose text sending.", code: "send_unsupported")
        }
        _ = application.perform(selector, with: text, with: chat)
        if let error = capture.lastError ?? application.lastError() ?? chat.lastError() {
            throw BridgeFailure.message(error.localizedDescription, code: "send_failed")
        }
    }
}

private final class MessagesStore {
    private let contacts = CNContactStore()
    private let databasePath: String

    init() {
        databasePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }

    func status() -> [String: Any] {
        let contactsAuthorization = contactsAuthorizationLabel()
        var database: OpaquePointer?
        let code = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if database != nil { sqlite3_close(database) } }
        if code == SQLITE_OK {
            return [
                "ok": true,
                "running": true,
                "databaseReadable": true,
                "mode": "sqlite-read-only",
                "attachmentsEnabled": true,
                "groupsEnabled": true,
                "contactsAuthorization": contactsAuthorization,
                "sendingEnabled": false,
            ]
        }
        return [
            "ok": false,
            "running": true,
            "databaseReadable": false,
            "contactsAuthorization": contactsAuthorization,
            "error": "full_disk_access_required",
            "message": "Grant Full Disk Access to Messages Bridge (not Codex) in System Settings > Privacy & Security, then relaunch Messages Bridge.",
            "sqliteCode": Int(code),
        ]
    }

    func readThread(name: String, sinceDays: Int, limit: Int) throws -> [String: Any] {
        let selected = try selectedContact(name: name)

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)

        let chatIDs = try oneToOneChatIDs(database: database, contact: selected)
        let records = try fetchMessages(
            database: database,
            chatIDs: chatIDs,
            senderNames: senderNames(for: selected),
            fallbackSender: selected.displayName,
            sinceDays: sinceDays,
            limit: limit
        )
        return [
            "ok": true,
            "contact": selected.displayName,
            "conversationType": "direct",
            "sinceDays": sinceDays,
            "limit": limit,
            "count": records.count,
            "attachmentsIncluded": true,
            "mode": "sqlite-read-only",
            "messages": records.map {
                [
                    "timestamp": $0.timestamp,
                    "direction": $0.direction,
                    "sender": $0.sender,
                    "text": $0.text,
                    "service": $0.service,
                    "attachments": $0.attachments.map(\.payload),
                ]
            },
        ]
    }

    func listGroups(sinceDays: Int, limit: Int) throws -> [String: Any] {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        let contactNames = try contactNamesByHandle()

        let groups = try recentGroups(database: database, sinceDays: sinceDays, limit: limit)
        let handles = try handlesForChats(database: database, chatIDs: groups.map(\.chatID))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payloads: [[String: Any]] = groups.map { group in
            let participantHandles = handles[group.chatID] ?? []
            let participants = participantHandles.map { contactNames[normalizedHandleKey($0)] ?? $0 }
            return [
                "groupID": group.id,
                "name": groupDisplayName(storedName: group.storedName, participants: participants),
                "participants": participants,
                "participantCount": participants.count,
                "lastActivity": formatter.string(from: dateFromMessagesValue(group.lastActivity)),
            ]
        }
        return [
            "ok": true,
            "conversationType": "group",
            "sinceDays": sinceDays,
            "limit": limit,
            "count": payloads.count,
            "groups": payloads,
            "mode": "sqlite-read-only",
        ]
    }

    func readGroup(groupID: String, sinceDays: Int, limit: Int) throws -> [String: Any] {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        let contactNames = try contactNamesByHandle()

        let group = try groupConversation(database: database, groupID: groupID)
        let participantHandles = try handlesForChats(database: database, chatIDs: [group.chatID])[group.chatID] ?? []
        let participants = participantHandles.map { contactNames[normalizedHandleKey($0)] ?? $0 }
        let groupName = groupDisplayName(storedName: group.storedName, participants: participants)
        let records = try fetchMessages(
            database: database,
            chatIDs: [group.chatID],
            senderNames: senderNames(for: participantHandles, contactNames: contactNames),
            fallbackSender: nil,
            sinceDays: sinceDays,
            limit: limit
        )
        return [
            "ok": true,
            "conversationType": "group",
            "groupID": group.id,
            "name": groupName,
            "participants": participants,
            "sinceDays": sinceDays,
            "limit": limit,
            "count": records.count,
            "attachmentsIncluded": true,
            "mode": "sqlite-read-only",
            "messages": records.map {
                [
                    "timestamp": $0.timestamp,
                    "direction": $0.direction,
                    "sender": $0.sender,
                    "text": $0.text,
                    "service": $0.service,
                    "attachments": $0.attachments.map(\.payload),
                ]
            },
        ]
    }

    func readAttachment(name: String, attachmentID: String) throws -> [String: Any] {
        let selected = try selectedContact(name: name)

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)

        let chatIDs = try oneToOneChatIDs(database: database, contact: selected)
        guard let record = try attachmentFile(
            database: database,
            chatIDs: chatIDs,
            attachmentID: attachmentID
        ) else {
            throw BridgeFailure.message(
                "That attachment was not found in \(selected.displayName)'s one-to-one conversation.",
                code: "attachment_not_found"
            )
        }
        return try attachmentPayload(
            record: record,
            attachmentID: attachmentID,
            context: ["contact": selected.displayName, "conversationType": "direct"]
        )
    }

    func readGroupAttachment(groupID: String, attachmentID: String) throws -> [String: Any] {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        let contactNames = try contactNamesByHandle()

        let group = try groupConversation(database: database, groupID: groupID)
        let participantHandles = try handlesForChats(database: database, chatIDs: [group.chatID])[group.chatID] ?? []
        let participants = participantHandles.map { contactNames[normalizedHandleKey($0)] ?? $0 }
        let groupName = groupDisplayName(storedName: group.storedName, participants: participants)
        guard let record = try attachmentFile(
            database: database,
            chatIDs: [group.chatID],
            attachmentID: attachmentID
        ) else {
            throw BridgeFailure.message(
                "That attachment was not found in the selected group conversation.",
                code: "attachment_not_found"
            )
        }
        return try attachmentPayload(
            record: record,
            attachmentID: attachmentID,
            context: [
                "conversationType": "group",
                "groupID": group.id,
                "name": groupName,
            ]
        )
    }

    func directSendTarget(name: String) throws -> SendTarget {
        let selected = try selectedContact(name: name)
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)

        let chatIDs = try oneToOneChatIDs(database: database, contact: selected)
        let chatID = try mostRecentChatGUID(database: database, chatIDs: chatIDs)
        return SendTarget(
            chatID: chatID,
            displayName: selected.displayName,
            conversationType: "direct"
        )
    }

    func groupSendTarget(groupID: String) throws -> SendTarget {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openCode == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw BridgeFailure.message(
                "Messages Bridge cannot open chat.db. Grant Full Disk Access to Messages Bridge, then relaunch it.",
                code: "full_disk_access_required"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY", nil, nil, nil)

        let contactNames = try contactNamesByHandle()
        let group = try groupConversation(database: database, groupID: groupID)
        let participantHandles = try handlesForChats(database: database, chatIDs: [group.chatID])[group.chatID] ?? []
        let participants = participantHandles.map { contactNames[normalizedHandleKey($0)] ?? $0 }
        return SendTarget(
            chatID: group.id,
            displayName: groupDisplayName(storedName: group.storedName, participants: participants),
            conversationType: "group"
        )
    }

    private func attachmentPayload(
        record: AttachmentFileRecord,
        attachmentID: String,
        context: [String: Any]
    ) throws -> [String: Any] {
        let fileURL = try safeAttachmentURL(storedPath: record.storedPath)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw BridgeFailure.message("The attachment is not a regular file.", code: "attachment_unavailable")
        }
        let fileSize = values.fileSize ?? Int(record.byteCount)
        guard fileSize >= 0, fileSize <= maxAttachmentBytes else {
            throw BridgeFailure.message(
                "The attachment is larger than the 20 MB read limit.",
                code: "attachment_too_large"
            )
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= maxAttachmentBytes else {
            throw BridgeFailure.message(
                "The attachment is larger than the 20 MB read limit.",
                code: "attachment_too_large"
            )
        }
        let displayName = record.transferName.isEmpty ? fileURL.lastPathComponent : record.transferName
        var result: [String: Any] = [
            "ok": true,
            "attachmentID": attachmentID,
            "name": displayName,
            "mimeType": record.mimeType.isEmpty ? "application/octet-stream" : record.mimeType,
            "byteCount": data.count,
            "dataBase64": data.base64EncodedString(),
            "mode": "file-read-only",
        ]
        for (key, value) in context {
            result[key] = value
        }
        return result
    }

    private func selectedContact(name: String) throws -> ContactIdentity {
        let identities = try resolveContacts(name: name)
        guard !identities.isEmpty else {
            throw BridgeFailure.message("No Contacts match found for \(name).", code: "contact_not_found")
        }

        let exactMatches = identities.filter {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let selected: ContactIdentity
        if exactMatches.count == 1 {
            selected = exactMatches[0]
        } else if identities.count == 1 {
            selected = identities[0]
        } else {
            let names = identities.prefix(10).map(\.displayName)
            throw BridgeFailure.message(
                "The name is ambiguous. Matching contacts: \(names.joined(separator: ", ")). Use the exact Contacts name.",
                code: "ambiguous_contact"
            )
        }

        return selected
    }

    private func oneToOneChatIDs(database: OpaquePointer, contact: ContactIdentity) throws -> [Int64] {
        let handleIDs = try matchingHandleIDs(database: database, contact: contact)
        guard !handleIDs.isEmpty else {
            throw BridgeFailure.message(
                "No Messages conversation was found for \(contact.displayName)'s phone numbers or email addresses.",
                code: "conversation_not_found"
            )
        }

        let chatIDs = try oneToOneChatIDs(database: database, handleIDs: handleIDs)
        guard !chatIDs.isEmpty else {
            throw BridgeFailure.message(
                "No one-to-one Messages conversation was found for \(contact.displayName). Group conversations are intentionally excluded.",
                code: "conversation_not_found"
            )
        }
        return chatIDs
    }

    private func resolveContacts(name: String) throws -> [ContactIdentity] {
        try ensureContactsAccess()

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let matches = try contacts.unifiedContacts(matching: predicate, keysToFetch: keys)
        return matches.compactMap { contact in
            let displayName = contactDisplayName(contact)
            guard !displayName.isEmpty else { return nil }
            return ContactIdentity(
                displayName: displayName,
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { String($0.value) }
            )
        }
    }

    private func ensureContactsAccess() throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            return
        }
        if status == .notDetermined {
            if Thread.isMainThread {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                DispatchQueue.main.sync {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            var accessError: Error?
            contacts.requestAccess(for: .contacts) { allowed, error in
                granted = allowed
                accessError = error
                semaphore.signal()
            }
            semaphore.wait()
            if let accessError {
                throw BridgeFailure.message(accessError.localizedDescription, code: "contacts_access_failed")
            }
            if !granted {
                throw BridgeFailure.message(
                    "Contacts access was denied. Enable Contacts access for Messages Bridge in System Settings.",
                    code: "contacts_access_denied"
                )
            }
            return
        }

        throw BridgeFailure.message(
            "Contacts access is not authorized for Messages Bridge. Enable it in System Settings > Privacy & Security > Contacts.",
            code: "contacts_access_denied"
        )
    }

    private func contactsAuthorizationLabel() -> String {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return "authorized" }
        if status == .notDetermined { return "notDetermined" }
        if status == .denied { return "denied" }
        if status == .restricted { return "restricted" }
        return "unknown"
    }

    private func contactDisplayName(_ contact: CNContact) -> String {
        // Build from explicitly fetched properties. CNContactFormatter may access
        // additional properties and raise CNPropertyNotFetchedException.
        let personName = [contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return personName.isEmpty ? contact.organizationName : personName
    }

    private func senderNames(for contact: ContactIdentity) -> [String: String] {
        var results: [String: String] = [:]
        for value in contact.phones + contact.emails {
            results[normalizedHandleKey(value)] = contact.displayName
        }
        return results
    }

    private func senderNames(for handles: [String], contactNames: [String: String]) -> [String: String] {
        var results: [String: String] = [:]
        for handle in handles {
            let key = normalizedHandleKey(handle)
            results[key] = contactNames[key] ?? handle
        }
        return results
    }

    private func contactNamesByHandle() throws -> [String: String] {
        try ensureContactsAccess()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var candidates: [String: Set<String>] = [:]
        try contacts.enumerateContacts(with: request) { contact, _ in
            let displayName = self.contactDisplayName(contact)
            guard !displayName.isEmpty else { return }
            for phone in contact.phoneNumbers {
                candidates[normalizedHandleKey(phone.value.stringValue), default: []].insert(displayName)
            }
            for email in contact.emailAddresses {
                candidates[normalizedHandleKey(String(email.value)), default: []].insert(displayName)
            }
        }
        var resolved: [String: String] = [:]
        for (key, names) in candidates where names.count == 1 {
            resolved[key] = names.first
        }
        return resolved
    }

    private func recentGroups(
        database: OpaquePointer,
        sinceDays: Int,
        limit: Int
    ) throws -> [GroupConversation] {
        let sql = """
            SELECT c.ROWID,
                   COALESCE(c.guid, ''),
                   COALESCE(c.display_name, ''),
                   MAX(m.date)
            FROM chat AS c
            JOIN chat_handle_join AS participants ON participants.chat_id = c.ROWID
            JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE m.date >= ?
              AND c.guid IS NOT NULL
              AND c.guid != ''
            GROUP BY c.ROWID
            HAVING COUNT(DISTINCT participants.handle_id) > 1
            ORDER BY MAX(m.date) DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "group_list_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        let threshold = Date().addingTimeInterval(-Double(sinceDays) * 86_400).timeIntervalSinceReferenceDate
        sqlite3_bind_int64(statement, 1, Int64(threshold * 1_000_000_000))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [GroupConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(GroupConversation(
                chatID: sqlite3_column_int64(statement, 0),
                id: columnString(statement, 1),
                storedName: columnString(statement, 2),
                lastActivity: sqlite3_column_int64(statement, 3)
            ))
        }
        return results
    }

    private func groupConversation(
        database: OpaquePointer,
        groupID: String
    ) throws -> GroupConversation {
        let sql = """
            SELECT c.ROWID,
                   COALESCE(c.guid, ''),
                   COALESCE(c.display_name, ''),
                   COALESCE(MAX(m.date), 0)
            FROM chat AS c
            JOIN chat_handle_join AS participants ON participants.chat_id = c.ROWID
            LEFT JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            LEFT JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE c.guid = ?
            GROUP BY c.ROWID
            HAVING COUNT(DISTINCT participants.handle_id) > 1
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "group_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        _ = groupID.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BridgeFailure.message(
                "No group conversation matched that group ID. List recent groups again.",
                code: "group_not_found"
            )
        }
        return GroupConversation(
            chatID: sqlite3_column_int64(statement, 0),
            id: columnString(statement, 1),
            storedName: columnString(statement, 2),
            lastActivity: sqlite3_column_int64(statement, 3)
        )
    }

    private func handlesForChats(
        database: OpaquePointer,
        chatIDs: [Int64]
    ) throws -> [Int64: [String]] {
        guard !chatIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let sql = """
            SELECT chj.chat_id, COALESCE(h.id, '')
            FROM chat_handle_join AS chj
            JOIN handle AS h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            ORDER BY chj.chat_id, h.ROWID
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "group_participants_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        for (index, chatID) in chatIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatID)
        }
        var results: [Int64: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let handle = columnString(statement, 1)
            if !handle.isEmpty {
                results[sqlite3_column_int64(statement, 0), default: []].append(handle)
            }
        }
        return results
    }

    private func groupDisplayName(storedName: String, participants: [String]) -> String {
        let trimmed = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let visible = participants.prefix(4).joined(separator: ", ")
        return visible.isEmpty ? "Unnamed group" : visible
    }

    private func matchingHandleIDs(database: OpaquePointer, contact: ContactIdentity) throws -> [Int64] {
        let sql = "SELECT ROWID, id FROM handle WHERE id IS NOT NULL"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "handle_query_failed")
        }
        defer { sqlite3_finalize(statement) }

        var results: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let value = columnString(statement, 1)
            if contact.emails.contains(where: { normalizedEmail($0) == normalizedEmail(value) })
                || contact.phones.contains(where: { phoneMatches($0, value) }) {
                results.append(sqlite3_column_int64(statement, 0))
            }
        }
        return results
    }

    private func oneToOneChatIDs(database: OpaquePointer, handleIDs: [Int64]) throws -> [Int64] {
        let placeholders = Array(repeating: "?", count: handleIDs.count).joined(separator: ",")
        let sql = """
            SELECT target.chat_id
            FROM chat_handle_join AS target
            JOIN (
              SELECT chat_id, COUNT(*) AS participant_count
              FROM chat_handle_join
              GROUP BY chat_id
            ) AS counts ON counts.chat_id = target.chat_id
            WHERE target.handle_id IN (\(placeholders))
              AND counts.participant_count = 1
            GROUP BY target.chat_id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "chat_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        for (index, handleID) in handleIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), handleID)
        }
        var chatIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chatIDs.append(sqlite3_column_int64(statement, 0))
        }
        return chatIDs
    }

    private func mostRecentChatGUID(database: OpaquePointer, chatIDs: [Int64]) throws -> String {
        guard !chatIDs.isEmpty else {
            throw BridgeFailure.message("No one-to-one conversation is available for sending.", code: "conversation_not_found")
        }
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let sql = """
            SELECT COALESCE(c.guid, ''), COALESCE(MAX(m.date), 0)
            FROM chat AS c
            LEFT JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            LEFT JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE c.ROWID IN (\(placeholders))
              AND c.guid IS NOT NULL
              AND c.guid != ''
            GROUP BY c.ROWID
            ORDER BY MAX(m.date) DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "send_target_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        for (index, chatID) in chatIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), chatID)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BridgeFailure.message("No one-to-one conversation is available for sending.", code: "conversation_not_found")
        }
        let guid = columnString(statement, 0)
        guard !guid.isEmpty else {
            throw BridgeFailure.message("The selected conversation has no Messages chat identifier.", code: "send_target_unavailable")
        }
        return guid
    }

    private func fetchMessages(
        database: OpaquePointer,
        chatIDs: [Int64],
        senderNames: [String: String],
        fallbackSender: String?,
        sinceDays: Int,
        limit: Int
    ) throws -> [MessageRecord] {
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let sql = """
            SELECT m.ROWID,
                   m.text,
                   m.attributedBody,
                   m.is_from_me,
                   m.date,
                   COALESCE(h.id, ''),
                   COALESCE(m.service, c.service_name, '')
            FROM message AS m
            JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            JOIN chat AS c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle AS h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders))
              AND m.date >= ?
            ORDER BY m.date DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "message_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        for chatID in chatIDs {
            sqlite3_bind_int64(statement, bindIndex, chatID)
            bindIndex += 1
        }
        let threshold = Date().addingTimeInterval(-Double(sinceDays) * 86_400).timeIntervalSinceReferenceDate
        sqlite3_bind_int64(statement, bindIndex, Int64(threshold * 1_000_000_000))
        sqlite3_bind_int(statement, bindIndex + 1, Int32(limit))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var records: [MessageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqlite3_column_int64(statement, 0)
            let plainText = optionalColumnString(statement, 1)
            let attributed = columnData(statement, 2)
            let text = decodedMessageText(plainText: plainText, attributedBody: attributed)
            let fromMe = sqlite3_column_int(statement, 3) != 0
            let rawDate = sqlite3_column_int64(statement, 4)
            let handle = columnString(statement, 5)
            let service = columnString(statement, 6)
            let sender = senderNames[normalizedHandleKey(handle)]
                ?? fallbackSender
                ?? (handle.isEmpty ? "Unknown participant" : handle)
            records.append(MessageRecord(
                messageID: messageID,
                timestamp: formatter.string(from: dateFromMessagesValue(rawDate)),
                direction: fromMe ? "outgoing" : "incoming",
                sender: fromMe ? "Me" : sender,
                text: text,
                service: service,
                attachments: []
            ))
        }
        let attachments = try attachmentMetadata(database: database, messageIDs: records.map(\.messageID))
        let completed = records.map { record in
            MessageRecord(
                messageID: record.messageID,
                timestamp: record.timestamp,
                direction: record.direction,
                sender: record.sender,
                text: record.text,
                service: record.service,
                attachments: attachments[record.messageID] ?? []
            )
        }
        return Array(completed.reversed())
    }

    private func attachmentMetadata(
        database: OpaquePointer,
        messageIDs: [Int64]
    ) throws -> [Int64: [AttachmentMetadata]] {
        guard !messageIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ",")
        let sql = """
            SELECT maj.message_id,
                   COALESCE(a.guid, ''),
                   COALESCE(a.transfer_name, ''),
                   COALESCE(a.filename, ''),
                   COALESCE(a.mime_type, ''),
                   COALESCE(a.total_bytes, 0)
            FROM message_attachment_join AS maj
            JOIN attachment AS a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            ORDER BY maj.message_id, a.ROWID
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "attachment_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        for (index, messageID) in messageIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), messageID)
        }

        var results: [Int64: [AttachmentMetadata]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqlite3_column_int64(statement, 0)
            let attachmentID = columnString(statement, 1)
            guard !attachmentID.isEmpty else { continue }
            let transferName = columnString(statement, 2)
            let storedPath = columnString(statement, 3)
            let displayName = transferName.isEmpty
                ? URL(fileURLWithPath: storedPath).lastPathComponent
                : transferName
            let metadata = AttachmentMetadata(
                id: attachmentID,
                name: displayName,
                mimeType: columnString(statement, 4),
                byteCount: sqlite3_column_int64(statement, 5),
                available: (try? safeAttachmentURL(storedPath: storedPath))
                    .map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
            )
            results[messageID, default: []].append(metadata)
        }
        return results
    }

    private func attachmentFile(
        database: OpaquePointer,
        chatIDs: [Int64],
        attachmentID: String
    ) throws -> AttachmentFileRecord? {
        let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
        let sql = """
            SELECT COALESCE(a.filename, ''),
                   COALESCE(a.transfer_name, ''),
                   COALESCE(a.mime_type, ''),
                   COALESCE(a.total_bytes, 0)
            FROM attachment AS a
            JOIN message_attachment_join AS maj ON maj.attachment_id = a.ROWID
            JOIN chat_message_join AS cmj ON cmj.message_id = maj.message_id
            WHERE cmj.chat_id IN (\(placeholders))
              AND a.guid = ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, code: "attachment_query_failed")
        }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        for chatID in chatIDs {
            sqlite3_bind_int64(statement, bindIndex, chatID)
            bindIndex += 1
        }
        _ = attachmentID.withCString {
            sqlite3_bind_text(statement, bindIndex, $0, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return AttachmentFileRecord(
            storedPath: columnString(statement, 0),
            transferName: columnString(statement, 1),
            mimeType: columnString(statement, 2),
            byteCount: sqlite3_column_int64(statement, 3)
        )
    }

    private func safeAttachmentURL(storedPath: String) throws -> URL {
        guard !storedPath.isEmpty else {
            throw BridgeFailure.message("The attachment is not downloaded on this Mac.", code: "attachment_unavailable")
        }
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let expandedPath: String
        if storedPath.hasPrefix("~/") {
            expandedPath = homeURL.appendingPathComponent(String(storedPath.dropFirst(2))).path
        } else {
            expandedPath = storedPath
        }
        let rootURL = homeURL
            .appendingPathComponent("Library/Messages/Attachments", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileURL = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix(rootURL.path + "/") else {
            throw BridgeFailure.message(
                "The attachment path is outside the Messages attachments directory.",
                code: "attachment_path_rejected"
            )
        }
        return fileURL
    }

    private func decodedMessageText(plainText: String?, attributedBody: Data?) -> String {
        if let plainText, !plainText.isEmpty { return plainText }
        guard let attributedBody, !attributedBody.isEmpty else {
            return "[Attachment]"
        }
        if let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: attributedBody),
           !attributed.string.isEmpty {
            return attributed.string
        }
        if let legacy = NSUnarchiver(forReadingWith: attributedBody) {
            let object = legacy.decodeObject()
            if let attributed = object as? NSAttributedString, !attributed.string.isEmpty {
                return attributed.string
            }
            if let string = object as? NSString, string.length > 0 {
                return string as String
            }
        }
        return "[Message body uses an unsupported local encoding]"
    }

    private func databaseError(_ database: OpaquePointer, code: String) -> BridgeFailure {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite error"
        return .message(message, code: code)
    }
}

private final class SocketServer {
    private let requestHandler: (BridgeRequest) -> [String: Any]
    private var listener: Int32 = -1
    private var running = false
    let path = "/tmp/messages-bridge-\(geteuid()).sock"

    init(requestHandler: @escaping (BridgeRequest) -> [String: Any]) {
        self.requestHandler = requestHandler
    }

    func start() throws {
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw BridgeFailure.message("Could not create local socket.", code: "socket_failed")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    strlcpy(destination, source, 104)
                }
            }
        }
        guard copied < 104 else {
            close(listener)
            throw BridgeFailure.message("Local socket path is too long.", code: "socket_failed")
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(listener)
            throw BridgeFailure.message("Could not bind the local socket.", code: "socket_failed")
        }
        chmod(path, S_IRUSR | S_IWUSR)
        guard listen(listener, 8) == 0 else {
            close(listener)
            unlink(path)
            throw BridgeFailure.message("Could not listen on the local socket.", code: "socket_failed")
        }
        running = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listener >= 0 { close(listener) }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if running { usleep(50_000) }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            writeResponse(["ok": false, "error": "unauthorized_peer", "message": "The caller is not the signed-in user."], to: client)
            return
        }

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while requestData.count < maxRequestBytes {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            requestData.append(buffer, count: count)
            if requestData.contains(0x0A) { break }
        }
        guard requestData.count <= maxRequestBytes,
              let line = requestData.split(separator: 0x0A, maxSplits: 1).first,
              let request = try? JSONDecoder().decode(BridgeRequest.self, from: Data(line)) else {
            writeResponse(["ok": false, "error": "invalid_request", "message": "The bridge request was invalid."], to: client)
            return
        }
        writeResponse(requestHandler(request), to: client)
    }

    private func writeResponse(_ payload: [String: Any], to client: Int32) {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload),
              data.count <= maxResponseBytes else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(client, base.advanced(by: sent), data.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let readsEnabledKey = "persistentReadsEnabled"
    private let sendingPolicyKey = "sendingPolicy"
    private let integrationsShownKey = "integrationsWindowShownV1"
    private let store = MessagesStore()
    private let sender = MessagesSender()
    private var server: SocketServer?
    private var statusItem: NSStatusItem?
    private var integrationsWindow: IntegrationsWindowController?
    private var statusMenuItem: NSMenuItem?
    private var readingMenuItem: NSMenuItem?
    private var readingOnItem: NSMenuItem?
    private var readingOffItem: NSMenuItem?
    private var sendingMenuItem: NSMenuItem?
    private var sendingOffItem: NSMenuItem?
    private var sendingConfirmItem: NSMenuItem?
    private var sendingAutomaticItem: NSMenuItem?

    private var readsEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: readsEnabledKey) != nil else { return true }
        return defaults.bool(forKey: readsEnabledKey)
    }

    private var sendingPolicy: SendingPolicy {
        SendingPolicy(rawValue: UserDefaults.standard.integer(forKey: sendingPolicyKey)) ?? .off
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        let server = SocketServer { [weak self] request in
            self?.handle(request) ?? ["ok": false, "error": "bridge_unavailable", "message": "Messages Bridge is unavailable."]
        }
        self.server = server
        do {
            try server.start()
        } catch {
            showAlert(title: "Messages Bridge could not start", message: String(describing: error))
            NSApp.terminate(nil)
            return
        }
        if !UserDefaults.standard.bool(forKey: integrationsShownKey) {
            UserDefaults.standard.set(true, forKey: integrationsShownKey)
            DispatchQueue.main.async { [weak self] in self?.showIntegrations() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let symbol = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "Messages Bridge"
        ) ?? NSImage(systemSymbolName: "link", accessibilityDescription: "Messages Bridge") {
            symbol.isTemplate = true
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            item.button?.image = symbol.withSymbolConfiguration(configuration)
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleProportionallyDown
            item.button?.title = ""
        } else {
            item.button?.title = "↔"
        }
        item.button?.toolTip = "Messages Bridge"
        let menu = NSMenu()
        menu.delegate = self
        let heading = NSMenuItem(title: "Messages Bridge", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let status = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(.separator())

        let reading = NSMenuItem(title: "Reading", action: nil, keyEquivalent: "")
        let readingMenu = NSMenu()
        let readingOn = NSMenuItem(title: "On", action: #selector(setReadingOn), keyEquivalent: "")
        readingOn.target = self
        readingMenu.addItem(readingOn)
        readingOnItem = readingOn
        let readingOff = NSMenuItem(title: "Off", action: #selector(setReadingOff), keyEquivalent: "")
        readingOff.target = self
        readingMenu.addItem(readingOff)
        readingOffItem = readingOff
        menu.setSubmenu(readingMenu, for: reading)
        menu.addItem(reading)
        readingMenuItem = reading

        let sending = NSMenuItem(title: "Sending", action: nil, keyEquivalent: "")
        let sendingMenu = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(setSendingOff), keyEquivalent: "")
        off.target = self
        sendingMenu.addItem(off)
        sendingOffItem = off
        let confirm = NSMenuItem(title: "Ask Before Sending", action: #selector(setSendingConfirmEach), keyEquivalent: "")
        confirm.target = self
        sendingMenu.addItem(confirm)
        sendingConfirmItem = confirm
        let automatic = NSMenuItem(title: "Send Automatically", action: #selector(setSendingAutomatic), keyEquivalent: "")
        automatic.target = self
        sendingMenu.addItem(automatic)
        sendingAutomaticItem = automatic
        menu.setSubmenu(sendingMenu, for: sending)
        menu.addItem(sending)
        sendingMenuItem = sending

        menu.addItem(.separator())
        let check = NSMenuItem(title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let integrations = NSMenuItem(title: "Integrations…", action: #selector(showIntegrations), keyEquivalent: ",")
        integrations.target = self
        menu.addItem(integrations)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Messages Bridge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        refreshReadingMenu()
        refreshSendingMenu()
        refreshMenuStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshReadingMenu()
        refreshSendingMenu()
        refreshMenuStatus()
    }

    @objc private func setReadingOn() {
        setReadingEnabled(true)
    }

    @objc private func setReadingOff() {
        setReadingEnabled(false)
    }

    private func setReadingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: readsEnabledKey)
        refreshReadingMenu()
        refreshMenuStatus()
    }

    private func refreshReadingMenu() {
        readingOnItem?.state = readsEnabled ? .on : .off
        readingOffItem?.state = readsEnabled ? .off : .on
        readingMenuItem?.title = "Reading: \(readsEnabled ? "On" : "Off")"
    }

    @objc private func setSendingOff() {
        setSendingPolicy(.off)
    }

    @objc private func setSendingConfirmEach() {
        setSendingPolicy(.confirmEach)
    }

    @objc private func setSendingAutomatic() {
        guard sendingPolicy != .automatic else { return }
        let alert = NSAlert()
        alert.messageText = "Send without asking each time?"
        alert.informativeText = "Connected AI tools will be able to send messages without another Messages Bridge confirmation. You can change this at any time."
        alert.addButton(withTitle: "Send Automatically")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setSendingPolicy(.automatic)
    }

    private func setSendingPolicy(_ policy: SendingPolicy) {
        UserDefaults.standard.set(policy.rawValue, forKey: sendingPolicyKey)
        refreshSendingMenu()
        refreshMenuStatus()
    }

    private func refreshSendingMenu() {
        let policy = sendingPolicy
        sendingOffItem?.state = policy == .off ? .on : .off
        sendingConfirmItem?.state = policy == .confirmEach ? .on : .off
        sendingAutomaticItem?.state = policy == .automatic ? .on : .off
        let summary: String
        switch policy {
        case .off: summary = "Off"
        case .confirmEach: summary = "Ask"
        case .automatic: summary = "Automatic"
        }
        sendingMenuItem?.title = "Sending: \(summary)"
    }

    private func refreshMenuStatus() {
        let result = store.status()
        let readable = result["databaseReadable"] as? Bool == true
        let contactsReady = result["contactsAuthorization"] as? String == "authorized"
        let sendingReady = sendingPolicy == .off || sender.authorizationLabel() == "authorized"
        let ready = readable && contactsReady && sendingReady
        statusMenuItem?.title = ready ? "Ready" : "Needs attention"
        let symbolName = ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        statusMenuItem?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    @objc private func checkPermissions() {
        let result = store.status()
        let readable = result["databaseReadable"] as? Bool == true
        let contactsAuthorization = result["contactsAuthorization"] as? String ?? "unknown"
        let automationAuthorization = sender.authorizationLabel()
        let contactsReady = contactsAuthorization == "authorized"
        let sendingReady = automationAuthorization == "authorized"
        let overallReady = readable && contactsReady && (sendingPolicy == .off || sendingReady)

        let messagesLine = "Messages: \(readable ? "Ready" : "Needs Full Disk Access")"
        let contactsLine = "Contacts: \(contactsReady ? "Ready" : "Needs access")"
        let sendingLine: String
        switch automationAuthorization {
        case "authorized": sendingLine = "Sending: Ready"
        case "notDetermined": sendingLine = "Sending: Will ask the first time you send"
        case "denied": sendingLine = "Sending: Blocked in System Settings"
        default: sendingLine = "Sending: Status unavailable"
        }
        showAlert(
            title: overallReady ? "Messages Bridge is ready" : "Some permissions need attention",
            message: [messagesLine, contactsLine, sendingLine].joined(separator: "\n")
        )
    }

    @objc private func showIntegrations() {
        if integrationsWindow == nil {
            integrationsWindow = IntegrationsWindowController()
        }
        integrationsWindow?.showAndRefresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handle(_ request: BridgeRequest) -> [String: Any] {
        switch request.operation {
        case "status":
            var result = store.status()
            result["persistentReadsEnabled"] = readsEnabled
            result["sendingEnabled"] = sendingPolicy != .off
            result["sendingPolicy"] = sendingPolicy.label
            result["sendingTransport"] = "apple-events"
            result["automationAuthorization"] = sender.authorizationLabel()
            return result
        case "read_thread":
            guard readsEnabled else {
                return ["ok": false, "error": "reads_disabled", "message": "Set Reading to On in the Messages Bridge menu."]
            }
            guard let rawName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
                return ["ok": false, "error": "invalid_name", "message": "A contact name is required."]
            }
            guard rawName.count <= 200,
                  !rawName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return ["ok": false, "error": "invalid_name", "message": "The contact name contains unsupported characters."]
            }
            let days = min(max(request.sinceDays ?? 30, 1), 3650)
            let limit = min(max(request.limit ?? 100, 1), 500)
            do {
                return try store.readThread(name: rawName, sinceDays: days, limit: limit)
            } catch let failure as BridgeFailure {
                return failure.payload
            } catch {
                return ["ok": false, "error": "read_failed", "message": error.localizedDescription]
            }
        case "list_groups":
            guard readsEnabled else {
                return ["ok": false, "error": "reads_disabled", "message": "Set Reading to On in the Messages Bridge menu."]
            }
            let days = min(max(request.sinceDays ?? 30, 1), 3650)
            let limit = min(max(request.limit ?? 50, 1), 100)
            do {
                return try store.listGroups(sinceDays: days, limit: limit)
            } catch let failure as BridgeFailure {
                return failure.payload
            } catch {
                return ["ok": false, "error": "group_list_failed", "message": error.localizedDescription]
            }
        case "read_group":
            guard readsEnabled else {
                return ["ok": false, "error": "reads_disabled", "message": "Set Reading to On in the Messages Bridge menu."]
            }
            guard let groupID = request.groupID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !groupID.isEmpty,
                  groupID.count <= 512,
                  !groupID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return ["ok": false, "error": "invalid_group_id", "message": "A valid group ID is required."]
            }
            let days = min(max(request.sinceDays ?? 30, 1), 3650)
            let limit = min(max(request.limit ?? 100, 1), 500)
            do {
                return try store.readGroup(groupID: groupID, sinceDays: days, limit: limit)
            } catch let failure as BridgeFailure {
                return failure.payload
            } catch {
                return ["ok": false, "error": "group_read_failed", "message": error.localizedDescription]
            }
        case "read_attachment":
            guard readsEnabled else {
                return ["ok": false, "error": "reads_disabled", "message": "Set Reading to On in the Messages Bridge menu."]
            }
            guard let rawName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty,
                  rawName.count <= 200,
                  !rawName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return ["ok": false, "error": "invalid_name", "message": "A valid contact name is required."]
            }
            guard let attachmentID = request.attachmentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !attachmentID.isEmpty,
                  attachmentID.count <= 256,
                  !attachmentID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return ["ok": false, "error": "invalid_attachment_id", "message": "A valid attachment ID is required."]
            }
            do {
                return try store.readAttachment(name: rawName, attachmentID: attachmentID)
            } catch let failure as BridgeFailure {
                return failure.payload
            } catch {
                return ["ok": false, "error": "attachment_read_failed", "message": error.localizedDescription]
            }
        case "read_group_attachment":
            guard readsEnabled else {
                return ["ok": false, "error": "reads_disabled", "message": "Set Reading to On in the Messages Bridge menu."]
            }
            guard let groupID = request.groupID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !groupID.isEmpty,
                  groupID.count <= 512,
                  !groupID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return ["ok": false, "error": "invalid_group_id", "message": "A valid group ID is required."]
            }
            guard let attachmentID = request.attachmentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !attachmentID.isEmpty,
                  attachmentID.count <= 256,
                  !attachmentID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return ["ok": false, "error": "invalid_attachment_id", "message": "A valid attachment ID is required."]
            }
            do {
                return try store.readGroupAttachment(groupID: groupID, attachmentID: attachmentID)
            } catch let failure as BridgeFailure {
                return failure.payload
            } catch {
                return ["ok": false, "error": "attachment_read_failed", "message": error.localizedDescription]
            }
        case "send_text", "send_group_text":
            guard sendingPolicy != .off else {
                return [
                    "ok": false,
                    "error": "sending_disabled",
                    "message": "Set Sending to Ask or Automatic in the Messages Bridge menu."
                ]
            }
            guard let text = request.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 4_000,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                return ["ok": false, "error": "invalid_text", "message": "Message text must contain 1 to 4,000 characters."]
            }
            do {
                let target: SendTarget
                if request.operation == "send_text" {
                    guard let rawName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawName.isEmpty,
                          rawName.count <= 200,
                          !rawName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        return ["ok": false, "error": "invalid_name", "message": "A valid contact name is required."]
                    }
                    target = try store.directSendTarget(name: rawName)
                } else {
                    guard let groupID = request.groupID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !groupID.isEmpty,
                          groupID.count <= 512,
                          !groupID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        return ["ok": false, "error": "invalid_group_id", "message": "A valid group ID is required."]
                    }
                    target = try store.groupSendTarget(groupID: groupID)
                }
                guard approveSendIfNeeded(target: target, text: text) else {
                    return ["ok": false, "error": "send_cancelled", "message": "The send was cancelled in Messages Bridge."]
                }
                try sender.sendText(text, to: target)
                return [
                    "ok": true,
                    "acceptedByMessages": true,
                    "conversationType": target.conversationType,
                    "target": target.displayName,
                    "characterCount": text.count,
                    "sendingPolicy": sendingPolicy.label,
                    "message": "Messages accepted the send request; delivery is not guaranteed."
                ]
            } catch let failure as BridgeFailure {
                return failure.payload
            } catch {
                return ["ok": false, "error": "send_failed", "message": error.localizedDescription]
            }
        default:
            return ["ok": false, "error": "unsupported_operation", "message": "The requested operation is not supported."]
        }
    }

    private func approveSendIfNeeded(target: SendTarget, text: String) -> Bool {
        if sendingPolicy == .automatic { return true }
        guard sendingPolicy == .confirmEach else { return false }
        var approved = false
        let present = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Send message to \(target.displayName)?"
            alert.informativeText = text
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            approved = alert.runModal() == .alertFirstButtonReturn
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.sync(execute: present)
        }
        return approved
    }

    private func showAlert(title: String, message: String) {
        let present = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        if Thread.isMainThread { present() } else { DispatchQueue.main.async(execute: present) }
    }
}

private func normalizedEmail(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func phoneDigits(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
}

private func normalizedHandleKey(_ value: String) -> String {
    if value.contains("@") {
        return "email:\(normalizedEmail(value))"
    }
    let digits = phoneDigits(value)
    if digits.count >= 10 {
        return "phone:\(digits.suffix(10))"
    }
    return "handle:\(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

private func phoneMatches(_ left: String, _ right: String) -> Bool {
    let lhs = phoneDigits(left)
    let rhs = phoneDigits(right)
    guard !lhs.isEmpty, !rhs.isEmpty else { return false }
    if lhs == rhs { return true }
    if lhs.count >= 10, rhs.count >= 10 { return lhs.suffix(10) == rhs.suffix(10) }
    return false
}

private func columnString(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let bytes = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: bytes)
}

private func optionalColumnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return columnString(statement, index)
}

private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
          let bytes = sqlite3_column_blob(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return Data(bytes: bytes, count: count)
}

private func dateFromMessagesValue(_ raw: Int64) -> Date {
    let seconds: Double
    if abs(raw) > 10_000_000_000 {
        seconds = Double(raw) / 1_000_000_000
    } else {
        seconds = Double(raw)
    }
    return Date(timeIntervalSinceReferenceDate: seconds)
}

@main
private struct MessagesBridgeApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
