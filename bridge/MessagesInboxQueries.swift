import Foundation
import SQLite3

struct RecentConversationRow {
    let chatID: Int64
    let chatGUID: String
    let storedName: String
    let service: String
    let lastActivity: Int64
    let unreadCount: Int
}

struct UnreadInboxRow {
    let messageID: Int64
    let rawDate: Int64
    let plainText: String?
    let attributedBody: Data?
    let senderHandle: String
    let service: String
    let chatID: Int64
    let chatGUID: String
    let storedName: String
}

struct UnreadInboxPage {
    let rows: [UnreadInboxRow]
    let hasMore: Bool
}

private struct InboxQueryFailure: LocalizedError {
    let operation: String
    let message: String

    var errorDescription: String? { "\(operation) failed: \(message)" }
}

enum MessagesInboxQueries {
    static func recentConversations(
        database: OpaquePointer,
        sinceDays: Int,
        limit: Int,
        now: Date = Date()
    ) throws -> [RecentConversationRow] {
        let sql = """
            SELECT c.ROWID,
                   COALESCE(c.guid, ''),
                   COALESCE(c.display_name, ''),
                   COALESCE(c.service_name, ''),
                   MAX(m.date),
                   SUM(CASE
                       WHEN m.is_from_me = 0 AND COALESCE(m.is_read, 0) = 0 THEN 1
                       ELSE 0
                   END)
            FROM chat AS c
            JOIN chat_message_join AS cmj ON cmj.chat_id = c.ROWID
            JOIN message AS m ON m.ROWID = cmj.message_id
            WHERE m.date >= ?
            GROUP BY c.ROWID
            ORDER BY MAX(m.date) DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw queryFailure(database, operation: "Recent conversation query")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, threshold(sinceDays: sinceDays, now: now))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var rows: [RecentConversationRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw queryFailure(database, operation: "Recent conversation query")
            }
            rows.append(RecentConversationRow(
                chatID: sqlite3_column_int64(statement, 0),
                chatGUID: string(statement, column: 1),
                storedName: string(statement, column: 2),
                service: string(statement, column: 3),
                lastActivity: sqlite3_column_int64(statement, 4),
                unreadCount: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return rows
    }

    static func unreadMessages(
        database: OpaquePointer,
        sinceDays: Int,
        limit: Int,
        cursorRawDate: Int64?,
        cursorMessageID: Int64?,
        now: Date = Date()
    ) throws -> UnreadInboxPage {
        let hasCursor = cursorRawDate != nil && cursorMessageID != nil
        let cursorClause = hasCursor
            ? "AND (m.date < ? OR (m.date = ? AND m.ROWID < ?))"
            : ""
        let sql = """
            SELECT m.ROWID,
                   m.date,
                   m.text,
                   m.attributedBody,
                   COALESCE(h.id, ''),
                   COALESCE(m.service, c.service_name, ''),
                   c.ROWID,
                   COALESCE(c.guid, ''),
                   COALESCE(c.display_name, '')
            FROM message AS m
            JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
            JOIN chat AS c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle AS h ON h.ROWID = m.handle_id
            WHERE m.date >= ?
              AND m.is_from_me = 0
              AND COALESCE(m.is_read, 0) = 0
              \(cursorClause)
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw queryFailure(database, operation: "Unread inbox query")
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        sqlite3_bind_int64(statement, bindIndex, threshold(sinceDays: sinceDays, now: now))
        bindIndex += 1
        if let cursorRawDate, let cursorMessageID {
            sqlite3_bind_int64(statement, bindIndex, cursorRawDate)
            sqlite3_bind_int64(statement, bindIndex + 1, cursorRawDate)
            sqlite3_bind_int64(statement, bindIndex + 2, cursorMessageID)
            bindIndex += 3
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit + 1))

        var rows: [UnreadInboxRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw queryFailure(database, operation: "Unread inbox query")
            }
            rows.append(UnreadInboxRow(
                messageID: sqlite3_column_int64(statement, 0),
                rawDate: sqlite3_column_int64(statement, 1),
                plainText: optionalString(statement, column: 2),
                attributedBody: data(statement, column: 3),
                senderHandle: string(statement, column: 4),
                service: string(statement, column: 5),
                chatID: sqlite3_column_int64(statement, 6),
                chatGUID: string(statement, column: 7),
                storedName: string(statement, column: 8)
            ))
        }
        let hasMore = rows.count > limit
        return UnreadInboxPage(rows: Array(rows.prefix(limit)), hasMore: hasMore)
    }

    private static func threshold(sinceDays: Int, now: Date) -> Int64 {
        let date = now.addingTimeInterval(-Double(sinceDays) * 86_400)
        return Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    private static func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func optionalString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return string(statement, column: column)
    }

    private static func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: bytes, count: count)
    }

    private static func queryFailure(_ database: OpaquePointer, operation: String) -> InboxQueryFailure {
        InboxQueryFailure(operation: operation, message: String(cString: sqlite3_errmsg(database)))
    }
}
